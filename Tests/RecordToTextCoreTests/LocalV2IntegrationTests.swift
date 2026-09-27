import Foundation
import XCTest
@testable import RecordToTextCore

/// End-to-end exercise of the phase 0 seam, with the real Python helper on the
/// other side of the contract.
///
/// The unit tests prove each half agrees on vectors. This proves they agree on a
/// live process: Swift freezes a plan, a Python writer commits leaves into it
/// using the shipped `qwen_asr_local_checkpoint` store, and Swift then verifies
/// and renders exactly what that writer produced. A drift in key names, integer
/// encoding or coverage rules shows up here and nowhere else.
final class LocalV2IntegrationTests: XCTestCase {

    private var root: URL!
    private var paths: ApplicationPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-v2-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RecordToTextCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private static var resources: URL {
        repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("RecordToTextApp")
            .appendingPathComponent("Resources")
    }

    private func resolve(_ name: String) throws -> URL {
        for candidate in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw XCTSkip("\(name) is required for the local v2 integration test")
    }

    /// A stand-in for `qwen_asr_mlx_runner.py` that keeps every real code path
    /// except model loading: `--report-runtime` is delegated verbatim, and leaf
    /// commits go through the shipped `qwen_asr_local_checkpoint` store.
    ///
    /// Only inference is faked. Faking the checkpoint writer too would make this
    /// test agree with itself instead of with the helper.
    private func writeFakeHelper(modelCache: URL) throws -> URL {
        let directory = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("qwen_asr_mlx_runner.py")
        let body = """
        import json
        import sys
        from pathlib import Path

        sys.path.insert(0, \(Self.resources.path.pythonLiteral))
        import qwen_asr_local_checkpoint as checkpoint
        import qwen_asr_mlx_runner as real

        if "--report-runtime" in sys.argv:
            sys.exit(real.main())

        def transcribe(request):
            block = request.get("checkpointV2")
            if block is None:
                real.emit("error", code="invalid_request", message="no checkpointV2", recoverable=False)
                sys.exit(2)

            real.validate_checkpoint_v2(block)
            mode_path = Path(__file__).with_name("mode.txt")
            mode = mode_path.read_text() if mode_path.exists() else "speech"
            _identity, identity_digest = checkpoint.load_identity(Path(block["directory"]))
            manifest = checkpoint.load_manifest(Path(block["directory"]), identity_digest=identity_digest)
            plan = checkpoint.find_root_plan(manifest, block["rootID"])
            class Audio:
                def __init__(self, start, count): self.start, self.count = start, count
                def __len__(self): return self.count
                def __getitem__(self, key):
                    # The token-limit recursion slices with open ends, so both
                    # bounds have to default the way a real array would.
                    begin = 0 if key.start is None else key.start
                    end = self.count if key.stop is None else key.stop
                    return Audio(self.start + begin, end - begin)
            class Result:
                generation_tokens = 7
                def __init__(self, text): self.text = text
            class Capped:
                generation_tokens = 16384
                def __init__(self, text): self.text = text
            class Model:
                def generate(self, span, **kwargs):
                    log = Path(__file__).with_name("generates.txt")
                    with log.open("a") as f:
                        f.write(str(span.start) + "\\n")
                    if mode == "fail-second" and plan["order"] == 1:
                        raise RuntimeError("injected second-root failure")
                    if mode == "split-then-fail":
                        call = len(log.read_text().split())
                        if call == 1:
                            return Capped("頂滿")
                        if call == 2:
                            return Result("left@%d" % span.start)
                        raise RuntimeError("injected right-child failure")
                    silent = mode == "all-silence" or (mode == "middle-silence" and plan["order"] == 1)
                    return Result("" if silent else "leaf@%d" % span.start)
            real.transcribe_v2(
                request=request, block=block, model=Model(), generation_arguments={"max_tokens":16384},
                sample_rate=16000, maximum_tokens=16384, min_split_seconds=30,
                audio=Audio(plan["startSample"], plan["endSample"]-plan["startSample"]),
                prompt=request["prompt"], terms=request["terms"], output=Path(request["outputPath"]), started=0,
            )
            return
        real.transcribe = transcribe
        sys.exit(real.main())
        """
        try body.write(to: helper, atomically: true, encoding: .utf8)
        return helper
    }

    private func makeEngine(modelID: String, revision: String,
                            detector: (any SilenceDetectionServicing)? = nil,
                            maximumRootSeconds: Double = 1200) async throws -> TranscriptionEngine {
        let ffmpeg = try resolve("ffmpeg")
        let ffprobe = try resolve("ffprobe")
        let python = try resolve("python3")
        let helper = try writeFakeHelper(modelCache: paths.models)

        let snapshotDirectory = LocalModelManifestStore.snapshotDirectory(
            cacheDirectory: paths.models,
            modelID: modelID,
            revision: revision
        )
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )
        try Data("fake-weights".utf8).write(
            to: snapshotDirectory.appendingPathComponent("weights.safetensors")
        )

        let openCC = root.appendingPathComponent("opencc-stub")
        try """
        #!/usr/bin/python3
        import sys, shutil
        shutil.copyfile(sys.argv[sys.argv.index('-i')+1], sys.argv[sys.argv.index('-o')+1])
        """.write(to: openCC, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: openCC.path)

        return TranscriptionEngine(
            cloudNetworkEnvironment: .init(),
            runtime: ResolvedRuntime(
                python: python,
                ffmpeg: ffmpeg,
                ffprobe: ffprobe,
                opencc: openCC,
                helper: helper,
                isDeveloperRuntime: true
            ),
            paths: paths,
            runner: ProcessRunner(),
            maximumASRSegmentDuration: maximumRootSeconds,
            silenceDetectionService: detector
        )
    }

    private func makeJob(
        modelID: String,
        revision: String?,
        source: URL,
        terms: [String] = ["詞庫"],
        silence: Bool = false,
        slice: TranscriptionSourceSlice? = nil
    ) -> TranscriptionJob {
        TranscriptionJob(
            sourcePath: source.path,
            snapshot: JobSnapshot(
                modelID: modelID,
                modelRevision: revision,
                glossaryID: nil,
                glossaryName: nil,
                terms: terms,
                prompt: "會議逐字稿",
                outputLocationMode: .fixedDirectory,
                outputDirectory: root.path,
                keepRawTranscript: false,
                backendType: .localQwen,
                localSilenceAwareSegmentation: silence
            ),
            sourceSlice: slice
        )
    }

    private func synthesizeWAV(seconds: Int, at url: URL) async throws {
        let ffmpeg = try resolve("ffmpeg")
        _ = try await ProcessRunner().run(
            executableURL: ffmpeg,
            arguments: [
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=\(seconds)",
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                "-y", url.path,
            ],
            timeout: 60
        )
    }

    // MARK: The contract

    /// The whole phase 0 chain, on one real root, with a real Python writer.
    func testAFrozenPlanSurvivesARealHelperWritingIntoIt() async throws {
        let modelID = "mlx-community/Qwen3-ASR-0.6B-8bit"
        let revision = "rev-integration"
        let engine = try await makeEngine(modelID: modelID, revision: revision)

        let source = root.appendingPathComponent("interview.wav")
        try await synthesizeWAV(seconds: 5, at: source)

        let working = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)

        let job = makeJob(modelID: modelID, revision: revision, source: source)
        var logs: [String] = []
        let reported = try await engine.prepareLocalCheckpointV2(
            job: job,
            offline: true,
            sourceURL: source,
            workingDirectory: working,
            update: { update in
                if case let .log(_, message) = update { logs.append(message) }
            }
        )
        let preparation = try XCTUnwrap(reported, "the real helper must be v2-eligible")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: working.appendingPathComponent(
                    LocalSourceVerification.snapshotFileName
                ).path
            ),
            "the snapshot must exist before any decode reads it"
        )
        // The prompt is non-empty and the fake helper reports whatever the real
        // `static_capability()` finds, so the channel is one of the three.
        XCTAssertTrue(
            [LocalPromptChannel.systemPrompt, LocalPromptChannel.context, LocalPromptChannel.none]
                .contains(LocalPromptChannel.resolve(prompt: job.snapshot.prompt,
                                                     capability: preparation.runtime.capability))
        )

        let normalized = working.appendingPathComponent("normalized.wav")
        try await synthesizeWAV(seconds: 5, at: normalized)
        let measurement = try await LocalRootMeasurer.measure(
            wavURL: normalized,
            expectedSeconds: 5
        )
        let workStart = try LocalAudioCoordinates.quantize(seconds: 0)

        let plan = try engine.freezeLocalCheckpointV2(
            preparation: preparation,
            job: job,
            allowMissingPrompt: false,
            recoveryDirectory: paths.tempRecovery.appendingPathComponent(job.id.uuidString),
            workStartSample: workStart,
            normalizedSampleCount: measurement.sampleCount,
            rootSources: [
                LocalRootSource(
                    order: 0,
                    audioURL: normalized,
                    sampleCount: measurement.sampleCount,
                    pcmSHA256: measurement.pcmSHA256
                )
            ],
            outputLocatorHint: root.path,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            update: { _ in }
        )

        // Frozen on disk, and readable by the Python side without a model.
        let layout = plan.layout
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.identityURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.manifestURL.path))
        XCTAssertEqual(plan.roots.count, 1)
        XCTAssertEqual(plan.roots[0].startSample, workStart)
        XCTAssertEqual(plan.roots[0].endSample, workStart + measurement.sampleCount)

        let block = engine.localCheckpointV2Block(plan: plan, rootOrder: 0)
        XCTAssertEqual(block.promptChannel, plan.identity.inference.promptChannel)
        XCTAssertEqual(block.audioStartSample, workStart)

        // Before the helper writes anything, the root is not verifiable.
        XCTAssertThrowsError(try engine.verifyLocalCheckpointV2Root(plan: plan, rootOrder: 0))

        try await runFakeHelper(engine: engine, block: block, audioURL: normalized)

        let outcome = try engine.verifyLocalCheckpointV2Root(plan: plan, rootOrder: 0)
        XCTAssertEqual(outcome, LocalRootOutcome.completed)

        let merged = try engine.mergeLocalCheckpointV2(plan: plan)
        XCTAssertFalse(merged.containsGaps)
        XCTAssertTrue(merged.text.hasPrefix("[00:00:00 - 00:00:05]"), merged.text)
        XCTAssertTrue(merged.text.contains("leaf@0"), merged.text)
        XCTAssertEqual(merged.lastRenderedEndSample, plan.roots[0].endSample)
        XCTAssertFalse(logs.isEmpty)
    }

    /// §7: a checkpoint written under one identity must not be reused under
    /// another. Changing the glossary changes the inference digest, and the
    /// planner has to refuse rather than quietly re-plan over committed leaves.
    func testChangingTheGlossaryRefusesToReuseAFrozenPlan() async throws {
        let modelID = "mlx-community/Qwen3-ASR-0.6B-8bit"
        let revision = "rev-integration"
        let engine = try await makeEngine(modelID: modelID, revision: revision)

        let source = root.appendingPathComponent("interview.wav")
        try await synthesizeWAV(seconds: 3, at: source)
        let working = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let recovery = paths.tempRecovery.appendingPathComponent(UUID().uuidString)

        let normalized = working.appendingPathComponent("normalized.wav")
        try await synthesizeWAV(seconds: 3, at: normalized)
        let measurement = try await LocalRootMeasurer.measure(
            wavURL: normalized,
            expectedSeconds: 3
        )
        let sources = [
            LocalRootSource(
                order: 0,
                audioURL: normalized,
                sampleCount: measurement.sampleCount,
                pcmSHA256: measurement.pcmSHA256
            )
        ]

        func freeze(terms: [String]) async throws -> LocalV2Plan {
            let job = makeJob(
                modelID: modelID, revision: revision, source: source, terms: terms
            )
            let reported = try await engine.prepareLocalCheckpointV2(
                job: job,
                offline: true,
                sourceURL: source,
                workingDirectory: working,
                update: { _ in }
            )
            let preparation = try XCTUnwrap(reported)
            return try engine.freezeLocalCheckpointV2(
                preparation: preparation,
                job: job,
                allowMissingPrompt: false,
                recoveryDirectory: recovery,
                workStartSample: 0,
                normalizedSampleCount: measurement.sampleCount,
                rootSources: sources,
                outputLocatorHint: root.path,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                update: { _ in }
            )
        }

        let first = try await freeze(terms: ["詞庫"])
        try await runFakeHelper(
            engine: engine,
            block: engine.localCheckpointV2Block(plan: first, rootOrder: 0),
            audioURL: normalized
        )
        XCTAssertEqual(
            try engine.verifyLocalCheckpointV2Root(plan: first, rootOrder: 0),
            LocalRootOutcome.completed
        )

        // A second freeze over the same recovery directory, with different terms.
        await XCTAssertThrowsErrorAsync(try await freeze(terms: ["另一個詞庫"])) { error in
            guard case .frozenIdentityChanged = error as? LocalPlannerError else {
                return XCTFail("expected frozenIdentityChanged, got \(error)")
            }
        }
        // The committed evidence is untouched by the refusal.
        XCTAssertEqual(
            try engine.verifyLocalCheckpointV2Root(plan: first, rootOrder: 0),
            LocalRootOutcome.completed
        )
    }

    /// §4: a model with no verifiable content manifest must not produce a v2
    /// checkpoint at all. Degrading to v1 here is refusing cross-run reuse, not
    /// skipping verification.
    func testAnUnpinnedModelProducesNoV2Checkpoint() async throws {
        let modelID = "mlx-community/Qwen3-ASR-0.6B-8bit"
        let engine = try await makeEngine(modelID: modelID, revision: "rev-integration")

        let source = root.appendingPathComponent("interview.wav")
        try await synthesizeWAV(seconds: 2, at: source)
        let working = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)

        // Unpinned: no revision means no verifiable content manifest.
        let job = makeJob(modelID: modelID, revision: nil, source: source)

        var logs: [String] = []
        let preparation = try await engine.prepareLocalCheckpointV2(
            job: job,
            offline: true,
            sourceURL: source,
            workingDirectory: working,
            update: { update in
                if case let .log(_, message) = update { logs.append(message) }
            }
        )
        XCTAssertNil(preparation)
        XCTAssertTrue(
            logs.contains { $0.contains("manifest") },
            "the reason must be told to the user, not silently dropped: \(logs)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: working.appendingPathComponent(
                    LocalSourceVerification.snapshotFileName
                ).path
            ),
            "an ineligible run must not copy the source"
        )
    }

    /// A helper that is not the MLX runner cannot honour the v2 contract, so no
    /// checkpoint is written. This is what keeps the mock-based pipeline
    /// self-test on the v1 path.
    func testANonMLXHelperStaysOnTheV1Path() async throws {
        let python = try resolve("python3")
        let ffmpeg = try resolve("ffmpeg")
        let helper = root.appendingPathComponent("qwen_asr_transformers_runner.py")
        try "raise SystemExit(0)\n".write(to: helper, atomically: true, encoding: .utf8)
        let engine = TranscriptionEngine(
            runtime: ResolvedRuntime(
                python: python, ffmpeg: ffmpeg, ffprobe: ffmpeg, opencc: python,
                helper: helper, isDeveloperRuntime: true
            ),
            paths: paths,
            runner: ProcessRunner()
        )
        let source = root.appendingPathComponent("interview.wav")
        try await synthesizeWAV(seconds: 2, at: source)
        let working = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)

        var logs: [String] = []
        let preparation = try await engine.prepareLocalCheckpointV2(
            job: makeJob(
                modelID: "mlx-community/Qwen3-ASR-0.6B-8bit",
                revision: "rev-integration",
                source: source
            ),
            offline: true,
            sourceURL: source,
            workingDirectory: working,
            update: { update in
                if case let .log(_, message) = update { logs.append(message) }
            }
        )
        XCTAssertNil(preparation)
        XCTAssertTrue(logs.contains { $0.contains("v2") }, "\(logs)")
    }

    // MARK: Phase 1.1 — real backend/engine, stub inference and detector

    private final class Detector: SilenceDetectionServicing {
        var calls = 0
        let result: [DetectedSilence]
        let error: Error?
        init(_ result: [DetectedSilence] = [], error: Error? = nil) {
            self.result = result; self.error = error
        }
        func detect(sourceURL: URL, startSeconds: Double, durationSeconds: Double) async throws -> [DetectedSilence] {
            calls += 1
            if let error { throw error }
            return result
        }
    }

    private func mode(_ value: String) throws {
        try value.write(to: root.appendingPathComponent("helper/mode.txt"), atomically: true, encoding: .utf8)
    }

    private var generated: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("helper/generates.txt"))) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func testWholeSilentRootBetweenSpeechRootsPublishesThroughRealBackend() async throws {
        let detector = Detector([DetectedSilence(startSeconds: 120, endSeconds: 240)])
        let engine = try await makeEngine(modelID: "fixture", revision: "rev", detector: detector, maximumRootSeconds: 120)
        try mode("middle-silence")
        let source = root.appendingPathComponent("three.wav")
        try await synthesizeWAV(seconds: 360, at: source)
        let job = makeJob(modelID: "fixture", revision: "rev", source: source, silence: true)
        let result = try await engine.run(job: job, offline: true, allowMissingPrompt: true, update: { _ in })
        let text = try String(contentsOf: result.outputURL)
        XCTAssertTrue(text.contains("leaf@0"), text)
        XCTAssertTrue(text.contains("leaf@3840000"), text)
        XCTAssertFalse(text.contains("缺少"), text)
        XCTAssertFalse(result.containsSkippedAudio)
        XCTAssertEqual(detector.calls, 1)
        XCTAssertEqual(generated, ["0", "1920000", "3840000"])
    }

    func testAllSilentWorkKeepsEvidenceButDoesNotPublishEmptyTranscript() async throws {
        let detector = Detector([DetectedSilence(startSeconds: 0, endSeconds: 6)])
        let engine = try await makeEngine(modelID: "fixture", revision: "rev", detector: detector, maximumRootSeconds: 3)
        try mode("all-silence")
        let source = root.appendingPathComponent("silence.wav")
        try await synthesizeWAV(seconds: 6, at: source)
        let job = makeJob(modelID: "fixture", revision: "rev", source: source, silence: true)
        do {
            _ = try await engine.run(job: job, offline: true, allowMissingPrompt: true, update: { _ in })
            XCTFail("all-silence work must not publish")
        } catch { XCTAssertEqual((error as? PipelineExecutionError)?.underlying as? LocalMergeError, .noSpeechContent) }
        let layout = LocalCheckpointLayout(recoveryDirectory: paths.tempRecovery.appendingPathComponent(job.id.uuidString))
        let manifest = try XCTUnwrap(LocalCheckpointPlanner.loadFrozenManifest(layout: layout))
        for rootPlan in manifest.roots {
            let state = try LocalCheckpointValidator.loadRootState(at: layout.stateURL(rootID: rootPlan.rootID))
            XCTAssertTrue(state.nodes.allSatisfy { $0.state == .verifiedSilence })
        }
    }

    func testDetectorFailureFallsBackOnceAndLogsMeasuredCost() async throws {
        let detector = Detector(error: NSError(domain: "detector", code: 1))
        let engine = try await makeEngine(modelID: "fixture", revision: "rev", detector: detector)
        let source = root.appendingPathComponent("fallback.wav")
        try await synthesizeWAV(seconds: 3, at: source)
        let job = makeJob(modelID: "fixture", revision: "rev", source: source, silence: true)
        var warnings: [String] = []; var logs: [String] = []
        var frozen: LocalCheckpointManifest?
        _ = try await engine.run(job: job, offline: true, allowMissingPrompt: true, persistCompletion: { _ in
            frozen = try? LocalCheckpointPlanner.loadFrozenManifest(layout: LocalCheckpointLayout(recoveryDirectory: self.paths.tempRecovery.appendingPathComponent(job.id.uuidString)))
            return true
        }, update: {
            if case let .warning(code, _) = $0 { warnings.append(code) }
            if case let .log(_, message) = $0 { logs.append(message) }
        })
        XCTAssertEqual(warnings.filter { $0 == "local_silence_scan_failed" }.count, 1)
        XCTAssertTrue(logs.contains { $0.contains("silence_scan_count=1") && $0.contains("fallback_reason=detector_error") })
        XCTAssertEqual(frozen?.plannerVersion, LocalPlannerStrategy.fixed)
        XCTAssertNil(frozen?.silencePlanDigest)
        XCTAssertEqual(detector.calls, 1)
    }

    func testDetectorCancellationAndIdentityErrorsStopBeforeInference() async throws {
        let errors: [Error] = [CancellationError(), LocalSourceIdentityError.sourceChanged(path: "fixture"), LocalCheckpointError.invalidField(field: "fixture", reason: "invalid")]
        let source = root.appendingPathComponent("failure.wav")
        try await synthesizeWAV(seconds: 3, at: source)
        for error in errors {
            let detector = Detector(error: error)
            let engine = try await makeEngine(modelID: "fixture", revision: "rev", detector: detector)
            let job = makeJob(modelID: "fixture", revision: "rev", source: source, silence: true)
            var fallbacks = 0
            do {
                _ = try await engine.run(job: job, offline: true, allowMissingPrompt: true, update: {
                    if case .warning(code: "local_silence_scan_failed", message: _) = $0 { fallbacks += 1 }
                })
                XCTFail("must stop")
            } catch let actual {
                XCTAssertEqual(String(describing: type(of: (actual as? PipelineExecutionError)?.underlying ?? actual)), String(describing: type(of: error)))
            }
            XCTAssertEqual(fallbacks, 0)
            XCTAssertEqual(detector.calls, 1)
            XCTAssertTrue(generated.isEmpty)
            let layout = LocalCheckpointLayout(recoveryDirectory: paths.tempRecovery.appendingPathComponent(job.id.uuidString))
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.manifestURL.path))
        }
    }

    func testFrozenPlanSurvivesBothSettingChangesWithoutRescanningOrRegeneratingCompletedRoot() async throws {
        for enabled in [true, false] {
            let detector = Detector()
            let engine = try await makeEngine(modelID: "fixture", revision: "rev", detector: detector, maximumRootSeconds: 3)
            try mode("fail-second")
            let source = root.appendingPathComponent("resume-\(enabled).wav")
            try await synthesizeWAV(seconds: 6, at: source)
            var job = makeJob(modelID: "fixture", revision: "rev", source: source, silence: enabled)
            do { _ = try await engine.run(job: job, offline: true, allowMissingPrompt: true, update: { _ in }); XCTFail("injected failure") } catch {}
            let layout = LocalCheckpointLayout(recoveryDirectory: paths.tempRecovery.appendingPathComponent(job.id.uuidString))
            let manifestBytes = try Data(contentsOf: layout.manifestURL)
            let manifest = try XCTUnwrap(LocalCheckpointPlanner.loadFrozenManifest(layout: layout))
            let stateBytes = try Data(contentsOf: layout.stateURL(rootID: manifest.roots[0].rootID))
            XCTAssertEqual(detector.calls, enabled ? 1 : 0)
            XCTAssertEqual(manifest.plannerVersion, enabled ? LocalPlannerStrategy.silence : LocalPlannerStrategy.fixed)
            let resumeDetector = Detector(error: NSError(domain: "must-not-scan", code: 1))
            let resumedEngine = try await makeEngine(modelID: "fixture", revision: "rev", detector: resumeDetector, maximumRootSeconds: 3)
            try mode("speech")
            job.snapshot = makeJob(modelID: "fixture", revision: "rev", source: source, silence: !enabled).snapshot
            let generateCount = generated.count
            var resumedBytes: Data?; var resumedState: Data?
            _ = try await resumedEngine.run(job: job, offline: true, allowMissingPrompt: true, persistCompletion: { _ in
                resumedBytes = try? Data(contentsOf: layout.manifestURL)
                resumedState = try? Data(contentsOf: layout.stateURL(rootID: manifest.roots[0].rootID))
                return true
            }, update: { _ in })
            XCTAssertEqual(resumeDetector.calls, 0)
            XCTAssertEqual(resumedBytes, manifestBytes)
            XCTAssertEqual(resumedState, stateBytes)
            XCTAssertEqual(Array(generated.dropFirst(generateCount)), ["48000"])
        }
    }

    func testNonzeroSliceRendersOneGroupAcrossTwoRoots() async throws {
        let detector = Detector([DetectedSilence(startSeconds: 1189, endSeconds: 1191)])
        let engine = try await makeEngine(modelID: "fixture", revision: "rev", detector: detector)
        let source = root.appendingPathComponent("slice.wav")
        try await synthesizeWAV(seconds: 1215, at: source)
        let job = makeJob(modelID: "fixture", revision: "rev", source: source, silence: true,
                          slice: TranscriptionSourceSlice(startSeconds: 5, durationSeconds: 1210, partIndex: 1, partCount: 2))
        let result = try await engine.run(job: job, offline: true, allowMissingPrompt: true, update: { _ in })
        let text = try String(contentsOf: result.outputURL)
        XCTAssertTrue(text.hasPrefix("[00:00:05 - 00:10:05]"), text)
        XCTAssertEqual(text.components(separatedBy: "[00:10:05 - 00:20:05]").count - 1, 1)
        XCTAssertTrue(text.contains("leaf@\(1195 * 16000)"), text)
        XCTAssertTrue(text.contains("[00:20:05 - 00:20:15]"), text)
        XCTAssertEqual(detector.calls, 1)
    }

    /// H4: a scan that succeeds and finds nothing is a legal empty set — not a
    /// failure, not a reason to scan again, and not `truncated` (which §3.7
    /// reserves for a dropped interval list). The persisted plan has to say so
    /// unambiguously, because the helper reads it and would otherwise take legal
    /// midpoints for the same reason it takes them when no plan exists at all.
    func testASuccessfulEmptyScanPersistsAValidEmptyPlanAndAResumeDoesNotRescan() async throws {
        let detector = Detector([])
        let engine = try await makeEngine(
            modelID: "fixture", revision: "rev", detector: detector, maximumRootSeconds: 3
        )
        try mode("fail-second")
        let source = root.appendingPathComponent("quiet.wav")
        try await synthesizeWAV(seconds: 6, at: source)
        var job = makeJob(modelID: "fixture", revision: "rev", source: source, silence: true)

        var logs: [String] = []
        var warnings: [String] = []
        do {
            _ = try await engine.run(job: job, offline: true, allowMissingPrompt: true, update: {
                if case let .log(_, message) = $0 { logs.append(message) }
                if case let .warning(code, _) = $0 { warnings.append(code) }
            })
            XCTFail("the injected second-root failure must stop the run")
        } catch {}

        XCTAssertEqual(detector.calls, 1)
        XCTAssertFalse(
            warnings.contains("local_silence_scan_failed"),
            "finding no silence is not a scan failure: \(warnings)"
        )
        XCTAssertTrue(
            logs.contains { $0.contains("0 段靜音、0 個候選切點") },
            "the log must distinguish an empty result from a failed scan: \(logs)"
        )

        let layout = LocalCheckpointLayout(
            recoveryDirectory: paths.tempRecovery.appendingPathComponent(job.id.uuidString)
        )
        let manifestBytes = try Data(contentsOf: layout.manifestURL)
        let manifest = try XCTUnwrap(LocalCheckpointPlanner.loadFrozenManifest(layout: layout))
        XCTAssertEqual(manifest.plannerVersion, LocalPlannerStrategy.silence)
        let digest = try XCTUnwrap(manifest.silencePlanDigest)
        XCTAssertEqual(
            manifest.roots.map { [$0.startSample, $0.endSample] },
            [[0, 48_000], [48_000, 96_000]],
            "with no candidates the boundaries stay on the fixed grid"
        )

        // The production loader accepts the empty plan as evidence-bearing, and
        // it really is empty rather than truncated.
        let identity = try LocalCheckpointValidator.loadIdentity(at: layout.identityURL).document
        let verified = try XCTUnwrap(
            LocalSilenceValidation.load(layout: layout, manifest: manifest, identity: identity)
        )
        XCTAssertEqual(verified.digest, digest)
        XCTAssertTrue(verified.plan.intervals.isEmpty)
        XCTAssertFalse(verified.plan.truncated)
        XCTAssertTrue(verified.plan.enabled)
        XCTAssertEqual(verified.plan.coveredStartSample, manifest.workStartSample)
        XCTAssertEqual(verified.plan.coveredEndSample, manifest.workEndSample)
        XCTAssertEqual(verified.plan.scanCount, 1)

        // Resume: a detector that would fail if it were ever called.
        let resumeDetector = Detector(error: NSError(domain: "must-not-scan", code: 1))
        let resumed = try await makeEngine(
            modelID: "fixture", revision: "rev", detector: resumeDetector, maximumRootSeconds: 3
        )
        try mode("speech")
        job.snapshot = makeJob(
            modelID: "fixture", revision: "rev", source: source, silence: true
        ).snapshot
        var resumedBytes: Data?
        let result = try await resumed.run(
            job: job, offline: true, allowMissingPrompt: true,
            // Read inside the callback: a successful run cleans up its recovery
            // directory, so afterwards there is nothing left to compare.
            persistCompletion: { _ in
                resumedBytes = try? Data(contentsOf: layout.manifestURL)
                return true
            },
            update: { _ in }
        )
        XCTAssertEqual(resumeDetector.calls, 0, "a frozen plan is never re-scanned")
        XCTAssertEqual(detector.calls, 1)
        XCTAssertEqual(resumedBytes, manifestBytes)
        let text = try String(contentsOf: result.outputURL)
        XCTAssertTrue(text.contains("leaf@0"), text)
        XCTAssertTrue(text.contains("leaf@48000"), text)
    }

    /// H4: a token-limit split whose right child failed. Recovery must not mean
    /// replanning — the parent is already `split` on disk carrying both
    /// children's boundaries, so the resume re-runs only the half that never
    /// finished and keeps the text the first half proved. The split parent's own
    /// truncated text must never reach the published transcript.
    func testAFailedRightChildResumesWithoutReplanningOrRegeneratingTheLeft() async throws {
        let detector = Detector([])
        let engine = try await makeEngine(modelID: "fixture", revision: "rev", detector: detector)
        try mode("split-then-fail")
        let source = root.appendingPathComponent("long.wav")
        try await synthesizeWAV(seconds: 120, at: source)
        var job = makeJob(modelID: "fixture", revision: "rev", source: source, silence: true)
        do {
            _ = try await engine.run(job: job, offline: true, allowMissingPrompt: true, update: { _ in })
            XCTFail("the injected right-child failure must stop the run")
        } catch {}

        let layout = LocalCheckpointLayout(
            recoveryDirectory: paths.tempRecovery.appendingPathComponent(job.id.uuidString)
        )
        let manifestBytes = try Data(contentsOf: layout.manifestURL)
        let manifest = try XCTUnwrap(LocalCheckpointPlanner.loadFrozenManifest(layout: layout))
        XCTAssertEqual(manifest.roots.count, 1)
        let stateURL = layout.stateURL(rootID: manifest.roots[0].rootID)
        let state = try LocalCheckpointValidator.loadRootState(at: stateURL)
        let nodesByID = Dictionary(uniqueKeysWithValues: state.nodes.map { ($0.nodeID, $0) })
        let parent = try XCTUnwrap(state.nodes.first { $0.state == .split })
        XCTAssertEqual(parent.childrenIDs.count, 2)
        let left = try XCTUnwrap(nodesByID[parent.childrenIDs[0]])
        let right = try XCTUnwrap(nodesByID[parent.childrenIDs[1]])
        XCTAssertEqual(left.state, .completed)
        XCTAssertEqual(left.result?.text, "left@0")
        XCTAssertEqual([left.startSample, left.endSample], [0, 960_000])
        XCTAssertEqual(right.state, .pending)
        XCTAssertEqual(
            try LocalCheckpointValidator.validate(
                rootState: state,
                plan: manifest.roots[0],
                manifest: manifest,
                silence: nil
            ),
            .incomplete,
            "a pending child is a hole, not a finished root"
        )

        let resumeDetector = Detector(error: NSError(domain: "must-not-scan", code: 1))
        let resumed = try await makeEngine(modelID: "fixture", revision: "rev", detector: resumeDetector)
        try mode("speech")
        job.snapshot = makeJob(modelID: "fixture", revision: "rev", source: source, silence: true).snapshot
        let generateCount = generated.count
        var resumedManifest: Data?
        var resumedState: Data?
        let result = try await resumed.run(
            job: job, offline: true, allowMissingPrompt: true,
            persistCompletion: { _ in
                resumedManifest = try? Data(contentsOf: layout.manifestURL)
                resumedState = try? Data(contentsOf: stateURL)
                return true
            },
            update: { _ in }
        )
        XCTAssertEqual(resumeDetector.calls, 0, "a frozen plan is never re-scanned")
        XCTAssertEqual(
            resumedManifest, manifestBytes,
            "the plan bytes, planID and display groups must survive a resume untouched"
        )
        XCTAssertEqual(
            Array(generated.dropFirst(generateCount)), ["960000"],
            "only the unfinished right half is transcribed again"
        )
        let finalState = try JSONDecoder().decode(
            LocalRootState.self, from: try XCTUnwrap(resumedState)
        )
        let finalNodes = Dictionary(uniqueKeysWithValues: finalState.nodes.map { ($0.nodeID, $0) })
        XCTAssertEqual(finalNodes[left.nodeID], left, "the committed left half is not rewritten")
        XCTAssertEqual(finalNodes[right.nodeID]?.state, .completed)

        let text = try String(contentsOf: result.outputURL)
        XCTAssertTrue(text.contains("left@0"), text)
        XCTAssertTrue(text.contains("leaf@960000"), text)
        XCTAssertFalse(text.contains("頂滿"), "a split parent's truncated text must not be published")
        XCTAssertFalse(result.containsSkippedAudio, text)
    }

    // MARK: Helper driver

    private func runFakeHelper(
        engine: TranscriptionEngine,
        block: ASRCheckpointV2,
        audioURL: URL
    ) async throws {
        let requestURL = root.appendingPathComponent("request-\(UUID().uuidString).json")
        let request = ASRRequest(
            jobID: "integration",
            audioPath: audioURL.path,
            outputPath: root.appendingPathComponent("out-\(UUID().uuidString).txt").path,
            modelID: "mlx-community/Qwen3-ASR-0.6B-8bit",
            modelRevision: "rev-integration",
            language: "Chinese",
            prompt: "會議逐字稿",
            terms: ["詞庫"],
            modelCacheDirectory: paths.models.path,
            offline: true,
            checkpointV2: block
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(request).write(to: requestURL)

        let helper = root.appendingPathComponent("helper").appendingPathComponent("qwen_asr_mlx_runner.py")
        let result = try await ProcessRunner().run(
            executableURL: try resolve("python3"),
            arguments: [helper.path, "--request-json", requestURL.path, "--events-jsonl", "-"],
            // The shim imports the real Resources modules; without this the test
            // leaves __pycache__ inside the signed-resource directory.
            environment: [
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONUTF8": "1",
                "PYTHONUNBUFFERED": "1",
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "HOME": ProcessInfo.processInfo.environment["HOME"] ?? root.path,
                "TMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? root.path,
            ],
            requireSuccess: false,
            timeout: 120
        )
        guard result.terminationStatus == 0 else {
            // A failing helper is a broken contract, not a missing dependency.
            // Skipping here would let the whole phase 0 seam pass while untested.
            XCTFail("""
            fake helper exited \(result.terminationStatus)
            stdout: \(result.standardOutputText)
            stderr: \(result.standardErrorText)
            """)
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: Self.resources.appendingPathComponent("__pycache__").path
            ),
            "the test must not leave bytecode in the resource directory"
        )
    }
}

extension String {
    /// A Python string literal, so the generated shim cannot be broken by a
    /// path containing a quote or a backslash.
    fileprivate var pythonLiteral: String {
        "\"" + replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ messageHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        messageHandler(error)
    }
}
