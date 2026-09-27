import Foundation
import XCTest
@testable import RecordToTextCore

/// Phase 0 acceptance for the pieces that sit between the frozen checkpoint
/// contract and the published transcript: the merger, the runtime identity
/// probe, root measurement, and the recovery allowlist.
///
/// The schema/planner/validator half of phase 0 lives in `LocalCheckpointV2Tests`.
final class LocalV2PipelineTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-v2-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Seam rule shared with the Python helper

    /// Vectors captured by running `join_transcript_parts` in
    /// `qwen_asr_chunking.py`. The merged transcript is published by Swift but
    /// the per-root diagnostic file is written by Python, so any drift here
    /// shows up as two different transcripts for the same audio.
    func testJoinTranscriptPartsMatchesPythonVectors() {
        let vectors: [([String], String)] = [
            (["今天", "天氣", "很好"], "今天天氣很好"),
            (["今天", "OK", "天氣"], "今天 OK 天氣"),
            (["hello", "world"], "hello world"),
            (["hello", "，", "world"], "hello，world"),
            (["", "甲", "", "乙"], "甲乙"),
            (["  甲  ", "  乙  "], "甲 乙"),
            (["A1", "B2"], "A1 B2"),
            (["會議", "結束。"], "會議結束。"),
            (["中文", "，標點"], "中文，標點"),
            (["   "], ""),
            ([], ""),
        ]
        for (parts, expected) in vectors {
            XCTAssertEqual(
                LocalTranscriptMerger.joinTranscriptParts(parts),
                expected,
                "parts=\(parts)"
            )
        }
    }

    /// Python indexes `str` by code point; Swift's `Character` is a grapheme
    /// cluster. A leading combining mark must be seen as U+0301, not fused with
    /// whatever precedes it, or the separator rule diverges on real ASR output.
    func testWordSeparatorRuleIsCodePointBasedNotGraphemeBased() {
        let parts = ["甲", "\u{0301}x"]
        XCTAssertEqual(LocalTranscriptMerger.joinTranscriptParts(parts), "甲 \u{0301}x")
        XCTAssertTrue(LocalTranscriptMerger.needsWordSeparator(left: "甲", right: "\u{0301}x"))
        XCTAssertFalse(LocalTranscriptMerger.needsWordSeparator(left: "甲", right: "乙"))
        XCTAssertFalse(LocalTranscriptMerger.needsWordSeparator(left: "甲", right: "，乙"))
        XCTAssertFalse(LocalTranscriptMerger.needsWordSeparator(left: "", right: "甲"))
    }

    func testGapMarkerIsRenderedFromTheMeasuredSpan() {
        // 3 s at 16 kHz. The number in the marker comes from the span, never
        // from prose stored on the leaf.
        XCTAssertEqual(
            LocalTranscriptMerger.gapMarker(startSample: 16_000, endSample: 64_000),
            "【此處約缺少 3 秒：模型達到 token 上限，已跳過此片段】"
        )
    }

    // MARK: Rendering

    private func group(_ start: Int64, _ end: Int64, id: String = "g") -> LocalDisplayGroup {
        LocalDisplayGroup(groupID: id, startSample: start, endSample: end)
    }

    private func leaf(
        _ start: Int64,
        _ end: Int64,
        _ state: LocalNodeState = .completed,
        _ text: String = "",
        id: String? = nil
    ) -> LocalMergedLeaf {
        LocalMergedLeaf(
            nodeID: id ?? "leaf-\(start)-\(end)",
            startSample: start,
            endSample: end,
            state: state,
            text: text
        )
    }

    /// The spec forbids deriving a heading from `segmentIndex * 1200`. A sliced
    /// job starts mid-recording, so the first heading must carry the offset.
    func testHeadingsUseAbsoluteCoordinatesNotZeroBasedSegmentMath() throws {
        let workStart: Int64 = 1_200 * 16_000  // a 20-minute slice offset
        let workEnd = workStart + 60 * 16_000
        let merged = try LocalTranscriptMerger.render(
            leaves: [leaf(workStart, workEnd, .completed, "第一段內容")],
            displayGroups: [group(workStart, workEnd)],
            workSpan: LocalSampleSpan(start: workStart, end: workEnd)
        )
        XCTAssertTrue(
            merged.text.hasPrefix("[00:20:00 - 00:21:00]"),
            "heading should be absolute, got: \(merged.text)"
        )
        XCTAssertFalse(merged.containsGaps)
        XCTAssertEqual(merged.lastRenderedEndSample, workEnd)
    }

    /// A display group (10 min) is shorter than a root (20 min), but roots are
    /// measured, never exact, so a group can straddle two of them. Concatenating
    /// per-root renders would emit two headings and split one paragraph.
    func testADisplayGroupStraddlingTwoRootsIsRenderedAsOneSection() throws {
        let rootOneEnd: Int64 = 30 * 16_000
        let workEnd: Int64 = 60 * 16_000
        let merged = try LocalTranscriptMerger.render(
            leaves: [
                leaf(0, rootOneEnd, .completed, "root one 的句子"),
                leaf(rootOneEnd, workEnd, .completed, "root two 的句子"),
            ],
            displayGroups: [group(0, workEnd)],
            workSpan: LocalSampleSpan(start: 0, end: workEnd)
        )
        XCTAssertEqual(
            merged.text,
            "[00:00:00 - 00:01:00]\n\nroot one 的句子 root two 的句子"
        )
        XCTAssertEqual(merged.text.components(separatedBy: "[00:").count - 1, 1)
    }

    /// §9.4: crossing an hour boundary must not reset or double-count the hour
    /// field, and a slice offset must be added exactly once.
    func testHeadingsCrossAnHourBoundaryWithoutDoubleCounting() throws {
        let workStart: Int64 = (3_600 - 30) * 16_000  // 00:59:30
        let workEnd = workStart + 60 * 16_000         // 01:00:30
        let split = workStart + 30 * 16_000           // 01:00:00
        let merged = try LocalTranscriptMerger.render(
            leaves: [
                leaf(workStart, split, .completed, "跨小時前"),
                leaf(split, workEnd, .completed, "跨小時後"),
            ],
            displayGroups: [group(workStart, workEnd)],
            workSpan: LocalSampleSpan(start: workStart, end: workEnd)
        )
        XCTAssertTrue(
            merged.text.hasPrefix("[00:59:30 - 01:00:30]"),
            "unexpected heading: \(merged.text)"
        )
        XCTAssertEqual(merged.text.components(separatedBy: "[0").count - 1, 1)
    }

    /// §9.4: a tail shorter than one second still renders at its real position.
    func testASubSecondTailKeepsItsOwnHeadingSpan() throws {
        let workEnd: Int64 = 16_000 + 500  // 1.03125 s
        let merged = try LocalTranscriptMerger.render(
            leaves: [leaf(0, workEnd, .completed, "很短的結尾")],
            displayGroups: [group(0, workEnd)],
            workSpan: LocalSampleSpan(start: 0, end: workEnd)
        )
        XCTAssertTrue(
            merged.text.hasPrefix("[00:00:00 - 00:00:01]"),
            "unexpected heading: \(merged.text)"
        )
        XCTAssertEqual(merged.lastRenderedEndSample, workEnd)
    }

    /// §6: a gap is retained with its own measured duration and counted, never
    /// papered over with neighbouring text.
    func testGapsAreRetainedWithTheirOwnDurationAndCounted() throws {
        let workEnd: Int64 = 60 * 16_000
        let merged = try LocalTranscriptMerger.render(
            leaves: [
                leaf(0, 20 * 16_000, .completed, "前面有說話"),
                leaf(20 * 16_000, 25 * 16_000, .gap, ""),
                leaf(25 * 16_000, workEnd, .completed, "後面有說話"),
            ],
            displayGroups: [group(0, workEnd)],
            workSpan: LocalSampleSpan(start: 0, end: workEnd)
        )
        XCTAssertTrue(merged.containsGaps)
        XCTAssertEqual(merged.gapSampleCount, 5 * 16_000)
        XCTAssertEqual(merged.gapSeconds, 5, accuracy: 0.0001)
        XCTAssertTrue(merged.text.contains("【此處約缺少 5 秒"))
        XCTAssertTrue(merged.text.contains("前面有說話"))
        XCTAssertTrue(merged.text.contains("後面有說話"))
    }

    func testVerifiedSilenceContributesCoverageButNoTextOrMarker() throws {
        let workEnd: Int64 = 30 * 16_000
        let merged = try LocalTranscriptMerger.render(
            leaves: [
                leaf(0, 10 * 16_000, .completed, "有人說話"),
                leaf(10 * 16_000, workEnd, .verifiedSilence, ""),
            ],
            displayGroups: [group(0, workEnd)],
            workSpan: LocalSampleSpan(start: 0, end: workEnd)
        )
        XCTAssertFalse(merged.containsGaps)
        XCTAssertEqual(merged.gapSampleCount, 0)
        XCTAssertFalse(merged.text.contains("缺少"))
        XCTAssertEqual(merged.lastRenderedEndSample, workEnd)
    }

    /// Time headings are not transcription. An output made only of headings and
    /// silence markers must not be published as a finished transcript.
    func testOutputWithNoRecognizedSpeechIsRefused() {
        let workEnd: Int64 = 30 * 16_000
        XCTAssertThrowsError(
            try LocalTranscriptMerger.render(
                leaves: [leaf(0, workEnd, .verifiedSilence, "")],
                displayGroups: [group(0, workEnd)],
                workSpan: LocalSampleSpan(start: 0, end: workEnd)
            )
        ) { error in
            XCTAssertEqual(error as? LocalMergeError, .noSpeechContent)
        }
    }

    /// A group whose leaves are all empty produces no section at all, so a
    /// heading can never manufacture content.
    func testAGroupWithNoTextProducesNoHeading() throws {
        let workEnd: Int64 = 60 * 16_000
        let merged = try LocalTranscriptMerger.render(
            leaves: [
                leaf(0, 30 * 16_000, .verifiedSilence, ""),
                leaf(30 * 16_000, workEnd, .completed, "只有後半段有聲音"),
            ],
            displayGroups: [group(0, 30 * 16_000), group(30 * 16_000, workEnd)],
            workSpan: LocalSampleSpan(start: 0, end: workEnd)
        )
        XCTAssertEqual(merged.text.components(separatedBy: "[00:").count - 1, 1)
        XCTAssertTrue(merged.text.hasPrefix("[00:00:30 - 00:01:00]"))
    }

    func testLeavesThatDoNotTileTheWorkAreRefused() {
        XCTAssertThrowsError(
            try LocalTranscriptMerger.render(
                leaves: [leaf(0, 10 * 16_000, .completed, "只有前段")],
                displayGroups: [group(0, 20 * 16_000)],
                workSpan: LocalSampleSpan(start: 0, end: 20 * 16_000)
            )
        )
    }

    /// `failed` and `split` are not publishable: a split parent holds truncated
    /// text, and a failure is a hole that must surface rather than vanish.
    func testUncommittedLeafStatesAreRefused() {
        for state: LocalNodeState in [.failed, .split, .pending, .running] {
            XCTAssertThrowsError(
                try LocalTranscriptMerger.render(
                    leaves: [leaf(0, 10 * 16_000, state, "文字")],
                    displayGroups: [group(0, 10 * 16_000)],
                    workSpan: LocalSampleSpan(start: 0, end: 10 * 16_000)
                ),
                "state \(state.rawValue) should not be renderable"
            ) { error in
                guard case .unrenderableLeaf = error as? LocalMergeError else {
                    return XCTFail("expected unrenderableLeaf, got \(error)")
                }
            }
        }
    }

    // MARK: Prompt channel

    /// Vectors captured by running `resolve_prompt_channel` in the helper. Swift
    /// freezes this value into `identity.json` before the model is loaded; the
    /// helper recomputes it afterwards and fails closed on disagreement, so the
    /// two implementations must agree on every input.
    func testPromptChannelResolutionMatchesPythonVectors() {
        let vectors: [(String, Bool, Bool, String)] = [
            ("", true, true, LocalPromptChannel.none),
            ("", true, false, LocalPromptChannel.none),
            ("", false, true, LocalPromptChannel.none),
            ("", false, false, LocalPromptChannel.none),
            ("詞庫提示", true, true, LocalPromptChannel.systemPrompt),
            ("詞庫提示", true, false, LocalPromptChannel.systemPrompt),
            ("詞庫提示", false, true, LocalPromptChannel.context),
            ("詞庫提示", false, false, LocalPromptChannel.none),
        ]
        for (prompt, supportsSystemPrompt, supportsContext, expected) in vectors {
            let actual = LocalPromptChannel.resolve(
                prompt: prompt,
                capability: ASRCapability(
                    supportsSystemPrompt: supportsSystemPrompt,
                    supportsContext: supportsContext
                )
            )
            XCTAssertEqual(
                actual,
                expected,
                "prompt=\(prompt.isEmpty ? "<empty>" : "<set>") "
                    + "system=\(supportsSystemPrompt) context=\(supportsContext)"
            )
        }
    }

    /// The helper rejects a channel outside its allowlist, so the names Swift
    /// freezes have to be spelled exactly as the helper spells them.
    func testPromptChannelNamesMatchTheHelperAllowlist() {
        XCTAssertEqual(LocalPromptChannel.systemPrompt, "system_prompt")
        XCTAssertEqual(LocalPromptChannel.context, "context")
        XCTAssertEqual(LocalPromptChannel.none, "none")
    }

    func testCheckpointV2CarriesThePromptChannelUnderTheKeyTheHelperReads() throws {
        let block = ASRCheckpointV2(
            directory: directory.path,
            rootID: "root-fixture0000000",
            planID: "plan-" + String(repeating: "0", count: 59),
            identityDigest: String(repeating: "i", count: 64),
            sampleRate: 16_000,
            audioStartSample: 0,
            workStartSample: 0,
            workEndSample: 64,
            promptChannel: LocalPromptChannel.context
        )
        let encoded = try JSONEncoder().encode(block)
        let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(decoded?["promptChannel"] as? String, "context")
        XCTAssertEqual(try JSONDecoder().decode(ASRCheckpointV2.self, from: encoded), block)
    }

    // MARK: Runtime identity probe

    /// `--report-runtime` is the only way Swift learns the prompt channel and the
    /// installed MLX versions before freezing an identity, so the parse has to
    /// survive a helper that also prints other event types.
    func testReportRuntimeReadsTheCapabilityLine() async throws {
        guard let python = Self.availablePython else {
            throw XCTSkip("Python required for the runtime probe test")
        }
        let backend = try makeBackend(
            python: python,
            helperBody: """
            import json
            print(json.dumps({"type": "stage", "value": "starting"}), flush=True)
            print(json.dumps({
                "type": "runtime",
                "asrContractVersion": "\(LocalCheckpointSchema.asrContractVersion)",
                "supportsSystemPrompt": False,
                "supportsContext": True,
                "mlxVersion": "0.30.0",
                "mlxAudioVersion": None,
            }), flush=True)
            """
        )
        let report = try await backend.reportRuntime(
            modelCacheDirectory: directory.path,
            offline: true
        )
        XCTAssertEqual(report.supportsSystemPrompt, false)
        XCTAssertEqual(report.supportsContext, true)
        XCTAssertEqual(report.mlxVersion, "0.30.0")
        XCTAssertNil(report.mlxAudioVersion)
        XCTAssertEqual(
            LocalPromptChannel.resolve(prompt: "詞庫", capability: report.capability),
            LocalPromptChannel.context
        )
    }

    /// A helper from a different app version must be refused outright. Resuming
    /// against a checkpoint written under another contract is how silently mixed
    /// results happen.
    func testReportRuntimeRefusesAContractVersionMismatch() async throws {
        guard let python = Self.availablePython else {
            throw XCTSkip("Python required for the runtime probe test")
        }
        let backend = try makeBackend(
            python: python,
            helperBody: """
            import json
            print(json.dumps({
                "type": "runtime",
                "asrContractVersion": "rec2t-local-asr-v1",
                "supportsSystemPrompt": True,
                "supportsContext": False,
            }), flush=True)
            """
        )
        await XCTAssertThrowsErrorAsync(
            try await backend.reportRuntime(
                modelCacheDirectory: directory.path,
                offline: true
            )
        ) { error in
            guard case let .runtimeContractMismatch(expected, actual) = error as? ASRBackendError else {
                return XCTFail("expected runtimeContractMismatch, got \(error)")
            }
            XCTAssertEqual(expected, LocalCheckpointSchema.asrContractVersion)
            XCTAssertEqual(actual, "rec2t-local-asr-v1")
        }
    }

    func testReportRuntimeSurfacesTheHelperErrorInsteadOfGuessing() async throws {
        guard let python = Self.availablePython else {
            throw XCTSkip("Python required for the runtime probe test")
        }
        let backend = try makeBackend(
            python: python,
            helperBody: """
            import json
            print(json.dumps({
                "type": "error",
                "code": "runtime_report_failed",
                "message": "無法讀取模型快照",
                "recoverable": False,
            }), flush=True)
            raise SystemExit(1)
            """
        )
        await XCTAssertThrowsErrorAsync(
            try await backend.reportRuntime(
                modelCacheDirectory: directory.path,
                offline: true
            )
        ) { error in
            guard case let .runtimeReportFailed(message) = error as? ASRBackendError else {
                return XCTFail("expected runtimeReportFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("無法讀取模型快照"), message)
        }
    }

    private static var availablePython: String? {
        ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func makeBackend(python: String, helperBody: String) throws -> HelperASRBackend {
        let executable = URL(fileURLWithPath: python)
        let helper = directory.appendingPathComponent("qwen_asr_mlx_runner.py")
        try helperBody.write(to: helper, atomically: true, encoding: .utf8)
        return HelperASRBackend(
            runtime: ResolvedRuntime(
                python: executable,
                ffmpeg: executable,
                ffprobe: executable,
                opencc: executable,
                helper: helper,
                isDeveloperRuntime: true
            ),
            paths: ApplicationPaths(root: directory),
            runner: ProcessRunner()
        )
    }

    // MARK: Source identity

    /// §9.1: a same-length replacement with the mtime restored must still be
    /// refused. Size and timestamps are hints; only the content digest decides.
    func testASameLengthReplacementWithRestoredTimestampsIsRefused() async throws {
        let source = directory.appendingPathComponent("interview.m4a")
        let original = Data("AAAA-original-recording-bytes".utf8)
        try original.write(to: source)
        let snapshotURL = directory.appendingPathComponent(
            LocalSourceVerification.snapshotFileName
        )
        let facts = try await LocalSourceVerification.snapshotAndVerify(
            sourceURL: source,
            snapshotURL: snapshotURL
        )

        let replaced = Data("BBBB-replaced-recording-bytes".utf8)
        XCTAssertEqual(replaced.count, original.count, "fixture must keep the length")
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        try replaced.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: attributes[.modificationDate] as Any,
             .creationDate: attributes[.creationDate] as Any],
            ofItemAtPath: source.path
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64,
            Int64(original.count)
        )

        await XCTAssertThrowsErrorAsync(
            try await LocalSourceVerification.confirmUnchanged(
                sourceURL: source,
                expectedSHA256: facts.sha256
            )
        ) { error in
            guard case .sourceChanged = error as? LocalSourceVerificationError else {
                return XCTFail("expected sourceChanged, got \(error)")
            }
        }
        // The snapshot still holds the bytes that were actually transcribed.
        XCTAssertEqual(try Data(contentsOf: snapshotURL), original)
    }

    /// §9.1: the digest describes content, so a path hint alone must not look
    /// like a different recording.
    func testTheSameBytesAtAnotherPathShareOneDigest() async throws {
        let bytes = Data("identical-recording-bytes".utf8)
        let first = directory.appendingPathComponent("a.m4a")
        let second = directory.appendingPathComponent("renamed-copy.m4a")
        try bytes.write(to: first)
        try bytes.write(to: second)

        let factsA = try await LocalSourceVerification.snapshotAndVerify(
            sourceURL: first,
            snapshotURL: directory.appendingPathComponent("snapshot-a")
        )
        let factsB = try await LocalSourceVerification.snapshotAndVerify(
            sourceURL: second,
            snapshotURL: directory.appendingPathComponent("snapshot-b")
        )
        XCTAssertEqual(factsA.sha256, factsB.sha256)
        XCTAssertEqual(factsA.byteCount, factsB.byteCount)
    }

    /// The attribute signature is auxiliary (§2.1), but a rename-swap is the one
    /// substitution that can match on size and timestamps, so the inode has to be
    /// part of it or that swap is invisible until the digest finishes.
    func testAttributeSignatureNoticesARenameSwap() throws {
        let target = directory.appendingPathComponent("interview.m4a")
        let incoming = directory.appendingPathComponent("incoming.m4a")
        try Data("AAAAAAAA".utf8).write(to: target)
        try Data("AAAAAAAA".utf8).write(to: incoming)

        let before = try LocalSourceVerification.attributeSignature(of: target)
        // Same bytes, same size — only the inode differs after the swap.
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: incoming, to: target)
        let after = try LocalSourceVerification.attributeSignature(of: target)

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(
            try LocalSourceVerification.attributeSignature(of: target),
            after,
            "an untouched file must keep one stable signature"
        )
    }

    // MARK: Root measurement

    func testRootMeasurerCountsDecodedSamplesNotContainerSeconds() async throws {
        let url = directory.appendingPathComponent("root.wav")
        try writeWav(to: url, sampleCount: 48_000)
        let measurement = try await LocalRootMeasurer.measure(
            wavURL: url,
            expectedSeconds: 3.0
        )
        XCTAssertEqual(measurement.sampleCount, 48_000)
        XCTAssertEqual(measurement.seconds, 3.0, accuracy: 0.0001)
        XCTAssertEqual(measurement.pcmSHA256.count, 64)
    }

    /// §3: `ffprobe` duration is an estimate only. A decode that disagrees with
    /// it by more than the tolerance is a defect to report, not a tail to invent.
    func testRootMeasurerRejectsADecodeFarFromTheEstimate() async throws {
        let url = directory.appendingPathComponent("short.wav")
        try writeWav(to: url, sampleCount: 16_000)  // 1 s decoded
        await XCTAssertThrowsErrorAsync(
            try await LocalRootMeasurer.measure(wavURL: url, expectedSeconds: 10.0)
        ) { error in
            guard case .durationMismatch = error as? LocalCoordinateError else {
                return XCTFail("expected durationMismatch, got \(error)")
            }
        }
        // Inside the tolerance the measured count still wins.
        let measurement = try await LocalRootMeasurer.measure(
            wavURL: url,
            expectedSeconds: 1.05
        )
        XCTAssertEqual(measurement.sampleCount, 16_000)
    }

    func testRootMeasurerRejectsAudioThatIsNotTheNormalizedLayout() async throws {
        let stereo = directory.appendingPathComponent("stereo.wav")
        try writeWav(to: stereo, sampleCount: 1_000, channels: 2)
        await XCTAssertThrowsErrorAsync(
            try await LocalRootMeasurer.measure(wavURL: stereo, expectedSeconds: nil)
        ) { error in
            guard case .unexpectedWaveLayout = error as? LocalSourceIdentityError else {
                return XCTFail("expected unexpectedWaveLayout, got \(error)")
            }
        }

        let wrongRate = directory.appendingPathComponent("wrongrate.wav")
        try writeWav(to: wrongRate, sampleCount: 1_000, sampleRate: 8_000)
        await XCTAssertThrowsErrorAsync(
            try await LocalRootMeasurer.measure(wavURL: wrongRate, expectedSeconds: nil)
        ) { error in
            XCTAssertEqual((error as? LocalSourceIdentityError)?.code, "local_pcm_mismatch")
        }
    }

    // MARK: H3.5 — real ffmpeg extraction at non-integer-second cut points

    private func ffmpegURL() throws -> URL {
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw XCTSkip("ffmpeg is required for the extraction fixture")
    }

    /// A position-dependent payload, so a one-sample shift is a different digest
    /// rather than the same bytes in a different place.
    private func rampPCM(sampleCount: Int) -> Data {
        var data = Data(count: sampleCount * 2)
        for index in 0..<sampleCount {
            // Never silent and never periodic within the test's length.
            let value = Int16(((index * 7919) % 20_000) - 10_000)
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes in
                data.replaceSubrange((index * 2)..<(index * 2 + 2), with: bytes)
            }
        }
        return data
    }

    /// The plan's boundaries are integer samples, but the extraction adapter
    /// hands ffmpeg seconds formatted `%.6f`, which cannot represent an odd
    /// sample exactly at 16 kHz. This runs the real ffmpeg and concatenates the
    /// payloads it produced: a one-sample shift, a dropped tail or a duplicated
    /// boundary all change the digest, and comparing total duration alone would
    /// hide every one of them.
    func testRealFFmpegExtractionAtFractionalBoundariesReassemblesTheExactPCM() async throws {
        let service = FFmpegService(executableURL: try ffmpegURL(), runner: ProcessRunner())
        let sampleCount = 112_001  // 7.0000625 s: not a whole second
        let normalized = directory.appendingPathComponent("normalized.wav")
        let payload = rampPCM(sampleCount: sampleCount)
        try writeWav(to: normalized, sampleCount: sampleCount, pcm: payload)

        // A pause whose midpoint is an odd sample inside the search window, so
        // the first boundary lands where no whole-second grid ever would.
        let candidates = LocalSilenceCandidateIndex(intervals: [
            LocalSilenceInterval(startSample: 31_999, endSample: 47_999),
        ])
        XCTAssertEqual(candidates.candidates, [39_999])
        let thresholds = LocalSilenceThresholds(
            maximumRootSeconds: 3,
            outerSearchSeconds: 1,
            displayGroupSeconds: LocalSilenceThresholds.current.displayGroupSeconds,
            displaySearchSeconds: LocalSilenceThresholds.current.displaySearchSeconds,
            chunkSeconds: LocalSilenceThresholds.current.chunkSeconds,
            innerSearchSeconds: LocalSilenceThresholds.current.innerSearchSeconds,
            recursiveSearchSeconds: LocalSilenceThresholds.current.recursiveSearchSeconds,
            minimumChildSeconds: LocalSilenceThresholds.current.minimumChildSeconds,
            noiseProfile: LocalSilenceThresholds.current.noiseProfile,
            minimumSilenceDurationSeconds: LocalSilenceThresholds.current.minimumSilenceDurationSeconds,
            maximumIntervalCount: LocalSilenceThresholds.current.maximumIntervalCount
        )
        let plan = try LocalSilenceScanner.makeOuterPlan(
            workStartSample: 0,
            sampleCount: Int64(sampleCount),
            candidates: candidates,
            thresholds: thresholds
        )

        // Every boundary re-quantizes to the integer sample the plan meant.
        let expectedSpans: [(Int64, Int64)] = [(0, 39_999), (39_999, 87_999), (87_999, 112_001)]
        var cursor = 0
        var spans: [(Int64, Int64)] = []
        for segment in plan.segments {
            let start = try LocalAudioCoordinates.quantize(seconds: segment.startSeconds)
            let end = try LocalAudioCoordinates.quantize(seconds: segment.endSeconds)
            XCTAssertEqual(start, Int64(cursor), "segment \(segment.index) must start where the last ended")
            spans.append((start, end))
            cursor = Int(end)
        }
        XCTAssertEqual(spans.map { $0.0 }, expectedSpans.map(\.0))
        XCTAssertEqual(spans.map { $0.1 }, expectedSpans.map(\.1))
        XCTAssertEqual(cursor, sampleCount)

        // Extract with the same call the engine makes, then reassemble.
        var reassembled = Data()
        for (order, span) in spans.enumerated() {
            let destination = directory.appendingPathComponent("root-\(order).wav")
            try await service.extractSegment(
                sourceURL: normalized,
                destinationURL: destination,
                startSeconds: LocalAudioCoordinates.seconds(forSamples: span.0),
                durationSeconds: LocalAudioCoordinates.seconds(forSamples: span.1 - span.0)
            )
            let layout = try WavePCMLayout.parse(at: destination)
            XCTAssertEqual(
                layout.sampleCount, span.1 - span.0,
                "root \(order) must hold exactly its planned samples, not a rounded second"
            )
            XCTAssertEqual(layout.sampleRate, 16_000)
            XCTAssertEqual(layout.channels, 1)
            XCTAssertEqual(layout.bitsPerSample, 16)
            let bytes = try Data(contentsOf: destination)
            reassembled.append(
                bytes.subdata(in: Int(layout.dataOffset)..<Int(layout.dataOffset + layout.dataByteCount))
            )
        }
        XCTAssertEqual(
            LocalDigest.sha256(reassembled),
            LocalDigest.sha256(payload),
            "the extracted roots must reassemble into the normalized PCM sample for sample"
        )
        XCTAssertEqual(reassembled, payload)
    }

    // MARK: Disk reservation

    /// The v2 path keeps a full copy of the source in App-private storage, so the
    /// pre-flight reservation has to cover it rather than discover the shortage
    /// halfway through normalization.
    func testDiskReservationCoversTheSourceSnapshot() throws {
        let service = AudioProbeService(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        // Large enough that no real volume satisfies it, so the reported
        // requirement is observable through the error.
        let metadata = AudioMetadata(
            duration: 100_000_000,
            codecName: "pcm_s16le",
            sampleRate: 16_000,
            channels: 1
        )
        let snapshotBytes: Int64 = 7_000_000

        func requirement(extra: Int64) throws -> Int64 {
            do {
                try service.validateDiskSpace(
                    for: metadata,
                    temporaryDirectory: directory,
                    outputDirectory: directory,
                    extraTemporaryBytes: extra
                )
            } catch let error as AudioServiceError {
                guard case let .insufficientDiskSpace(required, _) = error else {
                    throw error
                }
                return required
            }
            throw XCTSkip("this volume has enough space to satisfy the reservation")
        }

        let without = try requirement(extra: 0)
        let with = try requirement(extra: snapshotBytes)
        XCTAssertEqual(with - without, snapshotBytes)
        XCTAssertGreaterThan(without, 0)
    }

    // MARK: Recovery allowlist

    /// §8: a v2 checkpoint directory must be recognized as evidence, not scanned
    /// as junk. An unknown entry here is what makes a resumable job look
    /// disposable to the user.
    func testRecoveryScannerRecognizesTheV2CheckpointAndSnapshot() throws {
        XCTAssertTrue(
            RecoveryScanner.knownRecoveryFileNames.contains(LocalCheckpointSchema.directoryName)
        )
        XCTAssertTrue(
            RecoveryScanner.knownTempJobFileNames.contains(
                LocalSourceVerification.snapshotFileName
            )
        )
        // v1 stays listed so existing checkpoints remain retrievable.
        XCTAssertTrue(
            RecoveryScanner.knownRecoveryFileNames.contains(LocalChunkCheckpoint.directoryName)
        )
    }

    func testAV2CheckpointDirectoryIsNotReportedAsUnknown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-v2-scan-\(UUID().uuidString)")
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let tempJobs = root.appendingPathComponent("system-temp-jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: tempJobs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jobID = UUID()
        let tempJob = tempJobs.appendingPathComponent(jobID.uuidString)
        try FileManager.default.createDirectory(at: tempJob, withIntermediateDirectories: true)
        try Data("wav".utf8).write(
            to: tempJob.appendingPathComponent(RecoveryScanner.normalizedWAVFileName)
        )
        try Data("snapshot".utf8).write(
            to: tempJob.appendingPathComponent(LocalSourceVerification.snapshotFileName)
        )

        let recoveryJob = paths.tempRecovery.appendingPathComponent(jobID.uuidString)
        try FileManager.default.createDirectory(
            at: recoveryJob.appendingPathComponent(LocalCheckpointSchema.directoryName),
            withIntermediateDirectories: true
        )
        try Data("wav".utf8).write(
            to: recoveryJob.appendingPathComponent(RecoveryScanner.normalizedWAVFileName)
        )

        let report = RecoveryScanner.scan(paths: paths, systemTempRoot: tempJobs)
        let tempItem = try XCTUnwrap(
            report.items.first { $0.location == .systemTemp }
        )
        let recoveryItem = try XCTUnwrap(
            report.items.first { $0.location == .tempRecovery }
        )
        XCTAssertEqual(tempItem.unknownEntryNames, [])
        XCTAssertEqual(recoveryItem.unknownEntryNames, [])
    }

    // MARK: Fixtures

    private func writeWav(
        to url: URL,
        sampleCount: Int,
        channels: Int = 1,
        bits: Int = 16,
        sampleRate: Int = 16_000,
        pcm: Data? = nil
    ) throws {
        let dataBytes = sampleCount * channels * (bits / 8)
        var body = Data()
        func chunk(_ id: String, _ payload: Data) {
            body.append(Data(id.utf8))
            var size = UInt32(payload.count).littleEndian
            body.append(Data(bytes: &size, count: 4))
            body.append(payload)
            if payload.count % 2 == 1 { body.append(0) }
        }
        var fmt = Data()
        var tag = UInt16(1).littleEndian
        fmt.append(Data(bytes: &tag, count: 2))
        var ch = UInt16(channels).littleEndian
        fmt.append(Data(bytes: &ch, count: 2))
        var rate = UInt32(sampleRate).littleEndian
        fmt.append(Data(bytes: &rate, count: 4))
        var byteRate = UInt32(sampleRate * channels * (bits / 8)).littleEndian
        fmt.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(channels * (bits / 8)).littleEndian
        fmt.append(Data(bytes: &blockAlign, count: 2))
        var bitsPer = UInt16(bits).littleEndian
        fmt.append(Data(bytes: &bitsPer, count: 2))
        chunk("fmt ", fmt)

        let pcm = pcm ?? Data(repeating: 0x11, count: dataBytes)
        XCTAssertEqual(
            pcm.count, dataBytes,
            "an explicit payload must match the declared layout"
        )
        var header = Data("RIFF".utf8)
        var riffSize = UInt32(4 + body.count + 8 + pcm.count).littleEndian
        header.append(Data(bytes: &riffSize, count: 4))
        header.append(Data("WAVE".utf8))
        header.append(body)
        header.append(Data("data".utf8))
        var dataSize = UInt32(pcm.count).littleEndian
        header.append(Data(bytes: &dataSize, count: 4))
        header.append(pcm)
        try header.write(to: url)
    }
}

/// `XCTAssertThrowsError` has no async form, and wrapping an `await` in its
/// autoclosure silently changes when the call runs.
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
