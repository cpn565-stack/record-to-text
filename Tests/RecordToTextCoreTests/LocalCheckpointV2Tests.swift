import Foundation
import XCTest
@testable import RecordToTextCore

/// Phase 0 acceptance for the local v2 checkpoint contract.
///
/// Covers spec §9 items 1, 3, 4, 5, 6, 7, 8 and 9. Item 2 (cancellation during
/// a multi-gigabyte hash) and item 10 (30-minute / 173-minute cost measurements)
/// are instrumented rather than asserted here; see the phase 0 report.
final class LocalCheckpointV2Tests: XCTestCase {

    // MARK: Fixtures

    private func makeInference(
        modelManifestDigest: String? = "m" + String(repeating: "0", count: 63),
        promptDigest: String = "p" + String(repeating: "0", count: 63),
        termsDigest: String = "t" + String(repeating: "0", count: 63),
        promptChannel: String = "system-prompt",
        language: String? = "Chinese",
        modelRevision: String? = String(repeating: "a", count: 40),
        maximumTokens: Int = 16_384
    ) -> LocalInferenceIdentity {
        LocalInferenceIdentity(
            runtimeKind: "mlx",
            modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
            modelRevision: modelRevision,
            modelManifestDigest: modelManifestDigest,
            language: language,
            promptDigest: promptDigest,
            termsDigest: termsDigest,
            promptChannel: promptChannel,
            allowMissingPrompt: false,
            maximumTokens: maximumTokens,
            samplerDigest: "s" + String(repeating: "0", count: 63),
            mlxVersion: "0.30.1",
            mlxAudioVersion: "0.4.6"
        )
    }

    private func makeIdentityDocument(
        jobID: String = "job-1",
        workStart: Int64 = 0,
        workEnd: Int64 = 32 * 60 * 16_000,
        sliceStartSeconds: Double? = nil,
        inference: LocalInferenceIdentity? = nil
    ) -> LocalIdentityDocument {
        LocalIdentityDocument(
            jobID: jobID,
            source: LocalSourceIdentity(
                sourceSHA256: String(repeating: "f", count: 64),
                sourceByteCount: 1_000_000,
                sourceLocator: "/tmp/recording.m4a",
                normalizationProfile: .current,
                decoder: LocalDecoderIdentity(
                    executablePath: "/usr/local/bin/ffmpeg",
                    versionLine: "ffmpeg version 7.1",
                    signature: String(repeating: "d", count: 64)
                ),
                sliceStartSeconds: sliceStartSeconds,
                workStartSample: workStart,
                workEndSample: workEnd
            ),
            normalizationProfile: .current,
            inference: inference ?? makeInference(),
            presentation: LocalPresentationOptions(
                openCCConfiguration: "s2twp.json",
                outputLocatorHint: "/tmp/out.txt",
                jobUUID: "uuid-1"
            )
        )
    }

    private func makeRoot(
        order: Int,
        start: Int64,
        end: Int64,
        chunkSeconds: Double = 120
    ) -> LocalRootPlan {
        let rootID = LocalCheckpointID.root(order: order, startSample: start, endSample: end)
        let step = Int64(chunkSeconds * Double(LocalAudioCoordinates.sampleRate))
        var chunks: [LocalChunkPlan] = []
        var cursor = start
        var index = 0
        while cursor < end {
            let chunkEnd = min(cursor + step, end)
            chunks.append(
                LocalChunkPlan(
                    nodeID: LocalCheckpointID.chunk(
                        rootID: rootID,
                        order: index,
                        startSample: cursor,
                        endSample: chunkEnd
                    ),
                    startSample: cursor,
                    endSample: chunkEnd
                )
            )
            cursor = chunkEnd
            index += 1
        }
        return LocalRootPlan(
            rootID: rootID,
            order: order,
            startSample: start,
            endSample: end,
            pcmSHA256: String(repeating: "c", count: 64),
            audioRelativePath: "audio/\(rootID).wav",
            stateRelativePath: "roots/\(rootID).json",
            initialChunks: chunks
        )
    }

    private func makeManifest(
        identity: LocalIdentityDocument,
        identityDigest: String,
        roots: [LocalRootPlan]
    ) throws -> LocalCheckpointManifest {
        let groups = try LocalCheckpointManifest.makeDisplayGroups(
            workStartSample: identity.source.workStartSample,
            workEndSample: identity.source.workEndSample
        )
        return LocalCheckpointManifest(
            jobID: identity.jobID,
            identityDigest: identityDigest,
            inferenceDigest: identity.inference.digest,
            normalizationDigest: LocalDigest.sha256(identity.normalizationProfile),
            workStartSample: identity.source.workStartSample,
            workEndSample: identity.source.workEndSample,
            planID: LocalCheckpointManifest.computePlanID(
                workStartSample: identity.source.workStartSample,
                workEndSample: identity.source.workEndSample,
                roots: roots,
                displayGroups: groups
            ),
            roots: roots,
            displayGroups: groups,
            createdAt: "2026-09-27T00:00:00Z"
        )
    }

    private func pendingNode(
        _ chunk: LocalChunkPlan,
        depth: Int = 0,
        parentID: String? = nil
    ) -> LocalCheckpointNode {
        LocalCheckpointNode(
            nodeID: chunk.nodeID,
            parentID: parentID,
            startSample: chunk.startSample,
            endSample: chunk.endSample,
            splitDepth: depth,
            state: .pending
        )
    }

    private func completedLeaf(
        _ chunk: LocalChunkPlan,
        text: String,
        depth: Int = 0,
        parentID: String? = nil,
        tokens: Int? = 100
    ) -> LocalCheckpointNode {
        LocalCheckpointNode(
            nodeID: chunk.nodeID,
            parentID: parentID,
            startSample: chunk.startSample,
            endSample: chunk.endSample,
            splitDepth: depth,
            state: .completed,
            result: LocalLeafResult(
                text: text,
                textSHA256: LocalDigest.sha256(text),
                pcmSHA256: String(repeating: "c", count: 64),
                finishEvidence: tokens.map {
                    LocalFinishEvidence(
                        generationTokens: $0,
                        maximumTokens: 16_384,
                        reachedTokenLimit: false,
                        finishReason: "stop"
                    )
                }
            )
        )
    }

    private func rootState(
        plan: LocalRootPlan,
        manifest: LocalCheckpointManifest,
        nodes: [LocalCheckpointNode],
        revision: Int = 1
    ) -> LocalRootState {
        LocalRootState(
            identityDigest: manifest.identityDigest,
            planID: manifest.planID,
            rootID: plan.rootID,
            revision: revision,
            nodes: nodes
        )
    }

    // MARK: Canonical JSON must agree with the Python helper byte for byte

    func testCanonicalEncodingMatchesPythonReferenceVectors() {
        let payload = CanonicalJSONValue.object([
            "b": .integer(1),
            "a": .string("x"),
            "n": .null,
            "t": .bool(true),
            "f": .bool(false),
            "arr": .array([.object(["z": .integer(2), "y": .string("中文")])]),
            "e": .string("")
        ])
        XCTAssertEqual(
            String(decoding: CanonicalJSONEncoder.encode(payload), as: UTF8.self),
            #"{"a":"x","arr":[{"y":"中文","z":2}],"b":1,"e":"","f":false,"n":null,"t":true}"#
        )
        XCTAssertEqual(
            LocalDigest.sha256(CanonicalJSONEncoder.encode(payload)),
            "b4d136db5d962ba1f7bddeec1c8e470a8935830108387150499b468066dab558"
        )
    }

    func testCanonicalStringEscapingMatchesPython() {
        let value = CanonicalJSONValue.object([
            "s": .string("a\"b\\c\nd\te中文\u{0001}\u{007f}")
        ])
        XCTAssertEqual(
            String(decoding: CanonicalJSONEncoder.encode(value), as: UTF8.self),
            "{\"s\":\"a\\\"b\\\\c\\nd\\te中文\\u0001\u{007f}\"}"
        )
    }

    func testSplitChildIDsMatchPythonHelper() {
        XCTAssertEqual(
            LocalCheckpointID.splitChild(parentID: "node-abc", side: "a", startSample: 0, endSample: 60),
            "node-baa0e6ace3062875"
        )
        XCTAssertEqual(
            LocalCheckpointID.splitChild(parentID: "node-abc", side: "b", startSample: 60, endSample: 120),
            "node-1b451270becc7638"
        )
    }

    func testCanonicalEncodingIsOrderInsensitive() {
        let first = CanonicalJSONValue.object(["a": .integer(1), "b": .integer(2)])
        let second = CanonicalJSONValue.object(["b": .integer(2), "a": .integer(1)])
        XCTAssertEqual(
            CanonicalJSONEncoder.encode(first),
            CanonicalJSONEncoder.encode(second)
        )
    }

    // MARK: §9.4 coordinate arithmetic

    func testQuantizeHappensOnceAndMatchesSpecExample() throws {
        let sliceStart = try LocalAudioCoordinates.quantize(seconds: 1_800)
        XCTAssertEqual(sliceStart, 1_800 * 16_000)

        let rootStart = sliceStart + 1_200 * 16_000
        let leafStart = rootStart + 120 * 16_000
        XCTAssertEqual(leafStart, 3_120 * 16_000)
        XCTAssertEqual(LocalAudioCoordinates.formatTimestamp(samples: leafStart), "00:52:00")
    }

    func testQuantizeRoundsToNearestSample() throws {
        XCTAssertEqual(try LocalAudioCoordinates.quantize(seconds: 0), 0)
        // 0.5 sample rounds up; just under rounds down.
        XCTAssertEqual(try LocalAudioCoordinates.quantize(seconds: 0.5 / 16_000), 1)
        XCTAssertEqual(try LocalAudioCoordinates.quantize(seconds: 0.4 / 16_000), 0)
    }

    func testQuantizeRejectsNonFiniteAndNegative() {
        XCTAssertThrowsError(try LocalAudioCoordinates.quantize(seconds: .nan)) { error in
            guard case .nonFiniteSeconds = error as? LocalCoordinateError else {
                return XCTFail("expected nonFiniteSeconds, got \(error)")
            }
        }
        XCTAssertThrowsError(try LocalAudioCoordinates.quantize(seconds: .infinity)) { error in
            guard case .nonFiniteSeconds = error as? LocalCoordinateError else {
                return XCTFail("expected nonFiniteSeconds, got \(error)")
            }
        }
        XCTAssertThrowsError(try LocalAudioCoordinates.quantize(seconds: -1)) { error in
            guard case .negativeSeconds = error as? LocalCoordinateError else {
                return XCTFail("expected negativeSeconds, got \(error)")
            }
        }
    }

    func testTilingDetectsOverlapHoleAndOverflow() {
        let work = LocalSampleSpan(start: 0, end: 300)
        XCTAssertNoThrow(
            try [
                LocalSampleSpan(start: 0, end: 100),
                LocalSampleSpan(start: 100, end: 200),
                LocalSampleSpan(start: 200, end: 300)
            ].validatedTiling(of: work)
        )
        XCTAssertThrowsError(
            try [
                LocalSampleSpan(start: 0, end: 120),
                LocalSampleSpan(start: 100, end: 300)
            ].validatedTiling(of: work)
        ) { error in
            guard case .overlap = error as? LocalCoverageError else {
                return XCTFail("expected overlap, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try [
                LocalSampleSpan(start: 0, end: 100),
                LocalSampleSpan(start: 150, end: 300)
            ].validatedTiling(of: work)
        ) { error in
            guard case .hole = error as? LocalCoverageError else {
                return XCTFail("expected hole, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try [LocalSampleSpan(start: 0, end: 400)].validatedTiling(of: work)
        ) { error in
            guard case .outsideWork = error as? LocalCoverageError else {
                return XCTFail("expected outsideWork, got \(error)")
            }
        }
    }

    func testSpanTranslationGuardsOverflow() {
        let span = LocalSampleSpan(start: Int64.max - 10, end: Int64.max)
        XCTAssertThrowsError(try span.translated(by: 100)) { error in
            guard case .overflow = error as? LocalCoordinateError else {
                return XCTFail("expected overflow, got \(error)")
            }
        }
    }

    // MARK: §9.4 display groups

    func testDisplayGroupsCoverWorkWithRealTailEnd() throws {
        // 25 minutes of audio: two full ten-minute groups plus a five-minute tail.
        let workEnd = Int64(25 * 60 * 16_000)
        let groups = try LocalCheckpointManifest.makeDisplayGroups(
            workStartSample: 0,
            workEndSample: workEnd
        )
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].startSample, 0)
        XCTAssertEqual(groups[0].endSample, 600 * 16_000)
        XCTAssertEqual(groups[2].startSample, 1_200 * 16_000)
        XCTAssertEqual(groups[2].endSample, workEnd)
        try groups.map(\.span).validatedTiling(of: LocalSampleSpan(start: 0, end: workEnd))
    }

    func testDisplayGroupsStartAtWorkStartNotWallClock() throws {
        // A slice beginning mid-recording must not snap to the original grid.
        let start = Int64(1_837 * 16_000)
        let end = start + Int64(60 * 16_000)
        let groups = try LocalCheckpointManifest.makeDisplayGroups(
            workStartSample: start,
            workEndSample: end
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].startSample, start)
        XCTAssertEqual(groups[0].endSample, end)
    }

    func testDisplayGroupsHandleSubSecondTail() throws {
        let end = Int64(1)
        let groups = try LocalCheckpointManifest.makeDisplayGroups(
            workStartSample: 0,
            workEndSample: end
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].endSample, 1)
    }

    // MARK: §9.3 planID

    func testPlanIDIsStableAndSensitiveToBoundaries() throws {
        let identity = makeIdentityDocument()
        let roots = [makeRoot(order: 0, start: 0, end: 32 * 60 * 16_000)]
        let manifest = try makeManifest(identity: identity, identityDigest: "x", roots: roots)
        let recomputed = LocalCheckpointManifest.computePlanID(
            workStartSample: manifest.workStartSample,
            workEndSample: manifest.workEndSample,
            roots: manifest.roots,
            displayGroups: manifest.displayGroups
        )
        XCTAssertEqual(recomputed, manifest.planID)

        let shiftedRoot = makeRoot(order: 0, start: 0, end: 32 * 60 * 16_000 - 1)
        let shiftedID = LocalCheckpointManifest.computePlanID(
            workStartSample: manifest.workStartSample,
            workEndSample: manifest.workEndSample,
            roots: [shiftedRoot],
            displayGroups: manifest.displayGroups
        )
        XCTAssertNotEqual(shiftedID, manifest.planID)
    }

    func testPlanIDDetectsChangedPCMDigest() throws {
        var root = makeRoot(order: 0, start: 0, end: 1_600_000)
        let baseline = LocalCheckpointManifest.computePlanID(
            workStartSample: 0, workEndSample: 1_600_000, roots: [root], displayGroups: []
        )
        root = LocalRootPlan(
            rootID: root.rootID,
            order: root.order,
            startSample: root.startSample,
            endSample: root.endSample,
            pcmSHA256: String(repeating: "9", count: 64),
            audioRelativePath: root.audioRelativePath,
            stateRelativePath: root.stateRelativePath,
            initialChunks: root.initialChunks
        )
        let changed = LocalCheckpointManifest.computePlanID(
            workStartSample: 0, workEndSample: 1_600_000, roots: [root], displayGroups: []
        )
        XCTAssertNotEqual(baseline, changed)
    }

    // MARK: §9.3 identity separation

    func testPresentationChangesDoNotAlterInferenceDigest() {
        let identity = makeIdentityDocument()
        let restyled = LocalIdentityDocument(
            jobID: identity.jobID,
            source: identity.source,
            normalizationProfile: identity.normalizationProfile,
            inference: identity.inference,
            presentation: LocalPresentationOptions(
                displayLayoutVersion: "rec2t-local-display-v9",
                openCCConfiguration: "t2s.json",
                outputLocatorHint: "/somewhere/else.txt",
                jobUUID: "different-uuid"
            )
        )
        XCTAssertEqual(identity.inference.digest, restyled.inference.digest)
        XCTAssertNotEqual(identity.digest, restyled.digest)
    }

    func testInferenceDigestChangesWithLanguageTermsPromptChannelAndRevision() {
        let baseline = makeInference().digest
        XCTAssertNotEqual(baseline, makeInference(language: "English").digest)
        XCTAssertNotEqual(baseline, makeInference(termsDigest: String(repeating: "1", count: 64)).digest)
        XCTAssertNotEqual(baseline, makeInference(promptDigest: String(repeating: "2", count: 64)).digest)
        XCTAssertNotEqual(baseline, makeInference(promptChannel: "context").digest)
        XCTAssertNotEqual(baseline, makeInference(modelRevision: String(repeating: "b", count: 40)).digest)
        XCTAssertNotEqual(baseline, makeInference(maximumTokens: 8_192).digest)
    }

    func testModelWithoutContentManifestCannotBeReusedAcrossRuns() {
        XCTAssertFalse(makeInference(modelManifestDigest: nil).canReuseAcrossRuns)
        XCTAssertTrue(makeInference().canReuseAcrossRuns)
    }

    // MARK: Manifest validation

    func testManifestValidationAcceptsAConsistentPlan() throws {
        let identity = makeIdentityDocument()
        let digest = LocalDigest.sha256(identity)
        let roots = [
            makeRoot(order: 0, start: 0, end: 20 * 60 * 16_000),
            makeRoot(order: 1, start: 20 * 60 * 16_000, end: 32 * 60 * 16_000)
        ]
        let manifest = try makeManifest(identity: identity, identityDigest: digest, roots: roots)
        XCTAssertNoThrow(
            try LocalCheckpointValidator.validate(
                manifest: manifest,
                identity: identity,
                identityDigest: digest
            )
        )
    }

    func testManifestValidationRejectsTamperedIdentityDigest() throws {
        let identity = makeIdentityDocument()
        let roots = [makeRoot(order: 0, start: 0, end: 32 * 60 * 16_000)]
        let manifest = try makeManifest(
            identity: identity,
            identityDigest: LocalDigest.sha256(identity),
            roots: roots
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                manifest: manifest,
                identity: identity,
                identityDigest: String(repeating: "0", count: 64)
            )
        ) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_identity_mismatch")
        }
    }

    func testManifestValidationRejectsUnverifiableModelManifest() throws {
        let identity = makeIdentityDocument(
            inference: makeInference(modelManifestDigest: nil)
        )
        let digest = LocalDigest.sha256(identity)
        let roots = [makeRoot(order: 0, start: 0, end: 32 * 60 * 16_000)]
        let manifest = try makeManifest(identity: identity, identityDigest: digest, roots: roots)
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                manifest: manifest,
                identity: identity,
                identityDigest: digest
            )
        ) { error in
            guard case .unverifiableModelManifest = error as? LocalCheckpointError else {
                return XCTFail("expected unverifiableModelManifest, got \(error)")
            }
        }
    }

    func testManifestValidationRejectsRootsWithHoleBetweenThem() throws {
        let identity = makeIdentityDocument()
        let digest = LocalDigest.sha256(identity)
        let roots = [
            makeRoot(order: 0, start: 0, end: 20 * 60 * 16_000),
            makeRoot(order: 1, start: 21 * 60 * 16_000, end: 32 * 60 * 16_000)
        ]
        var manifest = try makeManifest(identity: identity, identityDigest: digest, roots: roots)
        // planID is recomputed so the failure is the coverage check, not planID.
        manifest = LocalCheckpointManifest(
            jobID: manifest.jobID,
            identityDigest: manifest.identityDigest,
            inferenceDigest: manifest.inferenceDigest,
            normalizationDigest: manifest.normalizationDigest,
            workStartSample: manifest.workStartSample,
            workEndSample: manifest.workEndSample,
            planID: LocalCheckpointManifest.computePlanID(
                workStartSample: manifest.workStartSample,
                workEndSample: manifest.workEndSample,
                roots: roots,
                displayGroups: manifest.displayGroups
            ),
            roots: roots,
            displayGroups: manifest.displayGroups,
            createdAt: manifest.createdAt
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                manifest: manifest,
                identity: identity,
                identityDigest: digest
            )
        )
    }

    // MARK: §8 path containment

    func testLayoutRejectsTraversalAbsoluteAndSymlinkPaths() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let layout = LocalCheckpointLayout(recoveryDirectory: base)
        try layout.createDirectories()
        defer { try? FileManager.default.removeItem(at: base) }

        for rejected in ["../escape.json", "roots/../../escape.json", "/etc/passwd", ""] {
            XCTAssertThrowsError(try layout.resolve(relativePath: rejected)) { error in
                XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_checkpoint_invalid")
            }
        }

        XCTAssertNoThrow(try layout.resolve(relativePath: "roots/r1.json"))

        let outside = base.appendingPathComponent("outside.txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        let link = layout.audioDirectoryURL.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try layout.resolve(relativePath: "audio/link.wav")) { error in
            guard case .pathEscape = error as? LocalCheckpointError else {
                return XCTFail("expected pathEscape, got \(error)")
            }
        }
    }

    // MARK: Root state validation

    private func scenario() throws -> (LocalRootPlan, LocalCheckpointManifest, LocalIdentityDocument) {
        let identity = makeIdentityDocument(workStart: 0, workEnd: 4 * 60 * 16_000)
        let roots = [makeRoot(order: 0, start: 0, end: 4 * 60 * 16_000)]
        let manifest = try makeManifest(
            identity: identity,
            identityDigest: LocalDigest.sha256(identity),
            roots: roots
        )
        return (roots[0], manifest, identity)
    }

    func testCompletedRootTilesExactlyAndReportsCompleted() throws {
        let (plan, manifest, _) = try scenario()
        let nodes = plan.initialChunks.map { completedLeaf($0, text: "第 \($0.nodeID) 段文字") }
        let state = rootState(plan: plan, manifest: manifest, nodes: nodes)
        let outcome = try LocalCheckpointValidator.validate(
            rootState: state, plan: plan, manifest: manifest
        )
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(
            LocalCheckpointValidator.orderedCompletedLeaves(in: state).map(\.nodeID),
            plan.initialChunks.map(\.nodeID)
        )
    }

    func testPendingLeavesMakeRootIncompleteWithoutThrowing() throws {
        let (plan, manifest, _) = try scenario()
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[1] = pendingNode(plan.initialChunks[1])
        let outcome = try LocalCheckpointValidator.validate(
            rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
            plan: plan,
            manifest: manifest
        )
        XCTAssertEqual(outcome, .incomplete)
    }

    func testGapLeafYieldsCompletedWithGaps() throws {
        let (plan, manifest, _) = try scenario()
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        let gapChunk = plan.initialChunks[1]
        nodes[1] = LocalCheckpointNode(
            nodeID: gapChunk.nodeID,
            startSample: gapChunk.startSample,
            endSample: gapChunk.endSample,
            state: .gap,
            result: LocalLeafResult(
                text: "",
                textSHA256: LocalDigest.sha256(""),
                pcmSHA256: String(repeating: "c", count: 64),
                finishEvidence: LocalFinishEvidence(
                    generationTokens: 16_384,
                    maximumTokens: 16_384,
                    reachedTokenLimit: true,
                    finishReason: "length"
                ),
                gapReason: "token_limit",
                gapErrorCode: "local_token_limit"
            )
        )
        let outcome = try LocalCheckpointValidator.validate(
            rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
            plan: plan,
            manifest: manifest
        )
        XCTAssertEqual(outcome, .completedWithGaps)
    }

    func testGapWithoutReasonIsRejected() throws {
        let (plan, manifest, _) = try scenario()
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        let chunk = plan.initialChunks[0]
        nodes[0] = LocalCheckpointNode(
            nodeID: chunk.nodeID,
            startSample: chunk.startSample,
            endSample: chunk.endSample,
            state: .gap,
            result: LocalLeafResult(
                text: "",
                textSHA256: LocalDigest.sha256(""),
                pcmSHA256: String(repeating: "c", count: 64),
                finishEvidence: nil
            )
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        ) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_empty_unverified")
        }
    }

    // MARK: §9.8 completion evidence

    func testCompletedLeafMissingTokenCountIsRejected() throws {
        let (plan, manifest, _) = try scenario()
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[0] = completedLeaf(plan.initialChunks[0], text: "文字", tokens: nil)
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        ) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_empty_unverified")
        }
    }

    func testCompletedLeafWithZeroTokensIsRejected() throws {
        let (plan, manifest, _) = try scenario()
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[0] = completedLeaf(plan.initialChunks[0], text: "文字", tokens: 0)
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        )
    }

    func testCompletedLeafAtTokenLimitIsRejected() throws {
        let (plan, manifest, _) = try scenario()
        let chunk = plan.initialChunks[0]
        let node = LocalCheckpointNode(
            nodeID: chunk.nodeID,
            startSample: chunk.startSample,
            endSample: chunk.endSample,
            state: .completed,
            result: LocalLeafResult(
                text: "被截斷的文字",
                textSHA256: LocalDigest.sha256("被截斷的文字"),
                pcmSHA256: String(repeating: "c", count: 64),
                finishEvidence: LocalFinishEvidence(
                    generationTokens: 16_384,
                    maximumTokens: 16_384,
                    reachedTokenLimit: true,
                    finishReason: "length"
                )
            )
        )
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[0] = node
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        )
    }

    func testEmptyTextWithoutSilenceEvidenceIsRejected() throws {
        let (plan, manifest, _) = try scenario()
        let nodes = plan.initialChunks.map { completedLeaf($0, text: "") }
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        ) { error in
            guard case .emptyUnverified = error as? LocalCheckpointError else {
                return XCTFail("expected emptyUnverified, got \(error)")
            }
        }
    }

    func testTamperedLeafTextIsRejected() throws {
        let (plan, manifest, _) = try scenario()
        let chunk = plan.initialChunks[0]
        let node = LocalCheckpointNode(
            nodeID: chunk.nodeID,
            startSample: chunk.startSample,
            endSample: chunk.endSample,
            state: .completed,
            result: LocalLeafResult(
                text: "被換掉的文字",
                textSHA256: LocalDigest.sha256("原本的文字"),
                pcmSHA256: String(repeating: "c", count: 64),
                finishEvidence: LocalFinishEvidence(
                    generationTokens: 10,
                    maximumTokens: 16_384,
                    reachedTokenLimit: false,
                    finishReason: "stop"
                )
            )
        )
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[0] = node
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        ) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_identity_mismatch")
        }
    }

    func testVerifiedSilenceRequiresEvidenceCoveringTheWholeLeaf() throws {
        let (plan, manifest, _) = try scenario()
        let chunk = plan.initialChunks[0]
        func silenceNode(covered: LocalSampleSpan) -> LocalCheckpointNode {
            LocalCheckpointNode(
                nodeID: chunk.nodeID,
                startSample: chunk.startSample,
                endSample: chunk.endSample,
                state: .verifiedSilence,
                result: LocalLeafResult(
                    text: "",
                    textSHA256: LocalDigest.sha256(""),
                    pcmSHA256: String(repeating: "c", count: 64),
                    finishEvidence: LocalFinishEvidence(
                        generationTokens: 1,
                        maximumTokens: 16_384,
                        reachedTokenLimit: false,
                        finishReason: "stop"
                    ),
                    silenceEvidence: LocalSilenceEvidence(
                        detector: "ffmpeg-silencedetect-v1",
                        coveredStartSample: covered.start,
                        coveredEndSample: covered.end,
                        thresholdDB: -45,
                        minimumDurationSeconds: 0.6
                    )
                )
            )
        }

        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[0] = silenceNode(covered: chunk.span)
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        )

        nodes[0] = silenceNode(
            covered: LocalSampleSpan(start: chunk.startSample, end: chunk.endSample - 1)
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        )
    }

    // MARK: §9.7 two-level split

    func testSplitSubtreeKeepsExactCoverageAndFirstChildSurvivesSecondFailing() throws {
        let (plan, manifest, _) = try scenario()
        let parent = plan.initialChunks[1]
        let midpoint = (parent.startSample + parent.endSample) / 2
        let leftID = LocalCheckpointID.splitChild(
            parentID: parent.nodeID, side: "a", startSample: parent.startSample, endSample: midpoint
        )
        let rightID = LocalCheckpointID.splitChild(
            parentID: parent.nodeID, side: "b", startSample: midpoint, endSample: parent.endSample
        )

        var splitParent = pendingNode(parent)
        splitParent.state = .split
        splitParent.childrenIDs = [leftID, rightID]
        splitParent.splitPolicy = "token-limit-midpoint-v1"

        let left = LocalCheckpointNode(
            nodeID: leftID,
            parentID: parent.nodeID,
            startSample: parent.startSample,
            endSample: midpoint,
            splitDepth: 1,
            state: .completed,
            result: LocalLeafResult(
                text: "左半段文字",
                textSHA256: LocalDigest.sha256("左半段文字"),
                pcmSHA256: String(repeating: "c", count: 64),
                finishEvidence: LocalFinishEvidence(
                    generationTokens: 42,
                    maximumTokens: 16_384,
                    reachedTokenLimit: false,
                    finishReason: "stop"
                )
            )
        )
        let right = LocalCheckpointNode(
            nodeID: rightID,
            parentID: parent.nodeID,
            startSample: midpoint,
            endSample: parent.endSample,
            splitDepth: 1,
            state: .failed
        )

        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[1] = splitParent
        nodes.append(contentsOf: [left, right])

        // The successful first child stays recoverable; only the failing half is
        // reported as a hole, never the whole 120-second chunk.
        let outcome = try LocalCheckpointValidator.validate(
            rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
            plan: plan,
            manifest: manifest
        )
        XCTAssertEqual(outcome, .incomplete)

        let leaves = LocalCheckpointValidator.effectiveLeaves(
            in: rootState(plan: plan, manifest: manifest, nodes: nodes)
        )
        XCTAssertTrue(leaves.contains { $0.nodeID == leftID && $0.state == .completed })
        XCTAssertFalse(leaves.contains { $0.nodeID == parent.nodeID })

        // Repairing only the right half completes the root.
        var repaired = right
        repaired.state = .completed
        repaired.result = LocalLeafResult(
            text: "右半段文字",
            textSHA256: LocalDigest.sha256("右半段文字"),
            pcmSHA256: String(repeating: "c", count: 64),
            finishEvidence: LocalFinishEvidence(
                generationTokens: 43,
                maximumTokens: 16_384,
                reachedTokenLimit: false,
                finishReason: "stop"
            )
        )
        let repairedNodes = nodes.map { $0.nodeID == rightID ? repaired : $0 }
        let repairedOutcome = try LocalCheckpointValidator.validate(
            rootState: rootState(plan: plan, manifest: manifest, nodes: repairedNodes),
            plan: plan,
            manifest: manifest
        )
        XCTAssertEqual(repairedOutcome, .completed)
    }

    func testSplitWithOneChildOrUnevenUnionIsRejected() throws {
        let (plan, manifest, _) = try scenario()
        let parent = plan.initialChunks[0]
        let midpoint = (parent.startSample + parent.endSample) / 2
        let leftID = LocalCheckpointID.splitChild(
            parentID: parent.nodeID, side: "a", startSample: parent.startSample, endSample: midpoint
        )

        var splitParent = pendingNode(parent)
        splitParent.state = .split
        splitParent.childrenIDs = [leftID]
        let left = LocalCheckpointNode(
            nodeID: leftID,
            parentID: parent.nodeID,
            startSample: parent.startSample,
            endSample: midpoint,
            splitDepth: 1
        )
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[0] = splitParent
        nodes.append(left)
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        ) { error in
            guard case .splitInvariant = error as? LocalCheckpointError else {
                return XCTFail("expected splitInvariant, got \(error)")
            }
        }
    }

    func testSplitParentCarryingPublishableTextIsRejected() throws {
        let (plan, manifest, _) = try scenario()
        let parent = plan.initialChunks[0]
        let midpoint = (parent.startSample + parent.endSample) / 2
        let leftID = LocalCheckpointID.splitChild(
            parentID: parent.nodeID, side: "a", startSample: parent.startSample, endSample: midpoint
        )
        let rightID = LocalCheckpointID.splitChild(
            parentID: parent.nodeID, side: "b", startSample: midpoint, endSample: parent.endSample
        )
        var splitParent = pendingNode(parent)
        splitParent.state = .split
        splitParent.childrenIDs = [leftID, rightID]
        splitParent.result = LocalLeafResult(
            text: "被截斷的父層文字",
            textSHA256: LocalDigest.sha256("被截斷的父層文字"),
            pcmSHA256: String(repeating: "c", count: 64),
            finishEvidence: nil
        )
        func child(_ id: String, _ start: Int64, _ end: Int64) -> LocalCheckpointNode {
            LocalCheckpointNode(
                nodeID: id,
                parentID: parent.nodeID,
                startSample: start,
                endSample: end,
                splitDepth: 1,
                state: .completed,
                result: LocalLeafResult(
                    text: "子層文字",
                    textSHA256: LocalDigest.sha256("子層文字"),
                    pcmSHA256: String(repeating: "c", count: 64),
                    finishEvidence: LocalFinishEvidence(
                        generationTokens: 5,
                        maximumTokens: 16_384,
                        reachedTokenLimit: false,
                        finishReason: "stop"
                    )
                )
            )
        }
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[0] = splitParent
        nodes.append(child(leftID, parent.startSample, midpoint))
        nodes.append(child(rightID, midpoint, parent.endSample))
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(plan: plan, manifest: manifest, nodes: nodes),
                plan: plan,
                manifest: manifest
            )
        ) { error in
            guard case .splitInvariant = error as? LocalCheckpointError else {
                return XCTFail("expected splitInvariant, got \(error)")
            }
        }
    }

    // MARK: §9.6 malformed input

    func testRootStateRejectsBooleanAndFloatSampleCoordinates() throws {
        let (plan, manifest, _) = try scenario()
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("root.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let chunk = plan.initialChunks[0]
        func writeAndLoad(_ startSampleJSON: String) throws -> LocalRootState {
            let json = """
            {"schemaVersion":2,"identityDigest":"\(manifest.identityDigest)",\
            "planID":"\(manifest.planID)","rootID":"\(plan.rootID)","revision":1,\
            "nodes":[{"nodeID":"\(chunk.nodeID)","parentID":null,\
            "startSample":\(startSampleJSON),"endSample":\(chunk.endSample),\
            "splitDepth":0,"state":"pending","childrenIDs":[],"attempts":[],"result":null}]}
            """
            try Data(json.utf8).write(to: stateURL)
            return try LocalCheckpointValidator.loadRootState(at: stateURL)
        }

        XCTAssertThrowsError(try writeAndLoad("true")) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_checkpoint_invalid")
        }
        XCTAssertThrowsError(try writeAndLoad("\(chunk.startSample).5")) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_checkpoint_invalid")
        }
        XCTAssertNoThrow(try writeAndLoad("\(chunk.startSample)"))
    }

    func testRootStateRejectsDuplicateAndUnknownNodes() throws {
        let (plan, manifest, _) = try scenario()
        let chunk = plan.initialChunks[0]
        let duplicate = rootState(
            plan: plan,
            manifest: manifest,
            nodes: [pendingNode(chunk), pendingNode(chunk)]
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: duplicate, plan: plan, manifest: manifest
            )
        ) { error in
            guard case .duplicateNode = error as? LocalCheckpointError else {
                return XCTFail("expected duplicateNode, got \(error)")
            }
        }

        let orphan = LocalCheckpointNode(
            nodeID: "node-doesnotexist",
            parentID: "node-alsomissing",
            startSample: chunk.startSample,
            endSample: chunk.endSample,
            splitDepth: 1
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: rootState(
                    plan: plan,
                    manifest: manifest,
                    nodes: plan.initialChunks.map { pendingNode($0) } + [orphan]
                ),
                plan: plan,
                manifest: manifest
            )
        ) { error in
            guard case .unknownNode = error as? LocalCheckpointError else {
                return XCTFail("expected unknownNode, got \(error)")
            }
        }
    }

    func testRootStateRejectsWrongPlanIDRootIDAndSchemaVersion() throws {
        let (plan, manifest, _) = try scenario()
        let nodes = plan.initialChunks.map { pendingNode($0) }

        let wrongPlan = LocalRootState(
            identityDigest: manifest.identityDigest,
            planID: String(repeating: "0", count: 64),
            rootID: plan.rootID,
            revision: 1,
            nodes: nodes
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: wrongPlan, plan: plan, manifest: manifest
            )
        ) { error in
            guard case .planMismatch = error as? LocalCheckpointError else {
                return XCTFail("expected planMismatch, got \(error)")
            }
        }

        let wrongRoot = LocalRootState(
            identityDigest: manifest.identityDigest,
            planID: manifest.planID,
            rootID: "root-other",
            revision: 1,
            nodes: nodes
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                rootState: wrongRoot, plan: plan, manifest: manifest
            )
        )
    }

    // MARK: §9.5 interrupted run

    func testUncommittedRunningNodesAreDemotedToPending() throws {
        let (plan, manifest, _) = try scenario()
        let chunk = plan.initialChunks[1]
        var running = pendingNode(chunk)
        running.state = .running
        running.result = LocalLeafResult(
            text: "寫到一半的文字",
            textSHA256: LocalDigest.sha256("寫到一半的文字"),
            pcmSHA256: String(repeating: "c", count: 64),
            finishEvidence: nil
        )
        var nodes = plan.initialChunks.map { completedLeaf($0, text: "文字") }
        nodes[1] = running

        let state = rootState(plan: plan, manifest: manifest, nodes: nodes)
        let demoted = state.demotingUncommittedRunning()
        XCTAssertEqual(demoted.node(chunk.nodeID)?.state, .pending)
        XCTAssertNil(demoted.node(chunk.nodeID)?.result)

        // A node claiming `running` while holding a result is corrupt, not partial.
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(rootState: state, plan: plan, manifest: manifest)
        )
        let outcome = try LocalCheckpointValidator.validate(
            rootState: demoted, plan: plan, manifest: manifest
        )
        XCTAssertEqual(outcome, .incomplete)
    }

    // MARK: §9.9 unknown schema version

    func testUnknownSchemaVersionIsRefusedNotReinterpreted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("manifest.json")
        try Data(#"{"schemaVersion":3,"jobID":"x"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try LocalCheckpointValidator.loadManifest(at: url)) { error in
            guard case let .unknownSchemaVersion(found, _) = error as? LocalCheckpointError else {
                return XCTFail("expected unknownSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 3)
        }

        try Data(#"{"schemaVersion":1,"jobID":"x"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try LocalCheckpointValidator.loadManifest(at: url)) { error in
            guard case let .unknownSchemaVersion(found, _) = error as? LocalCheckpointError else {
                return XCTFail("expected unknownSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 1)
        }

        // A v3 root state is refused the same way, before any v2 shape is assumed.
        let rootURL = directory.appendingPathComponent("root.json")
        try Data(#"{"schemaVersion":3}"#.utf8).write(to: rootURL)
        XCTAssertThrowsError(try LocalCheckpointValidator.loadRootState(at: rootURL)) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_checkpoint_invalid")
        }
    }

    func testLegacyV1IsDetectedForRetrievalOnly() throws {
        let recovery = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let checkpoints = recovery.appendingPathComponent(LocalChunkCheckpoint.directoryName)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recovery) }

        XCTAssertNil(LocalCheckpointValidator.detectLegacyV1(in: recovery))

        let payload = """
        {"schemaVersion":1,"fingerprint":"\(String(repeating: "a", count: 64))",\
        "totalChunks":1,"completedChunks":[{"index":0,"text":"舊稿","containsSkippedAudio":false}]}
        """
        try Data(payload.utf8).write(
            to: checkpoints.appendingPathComponent("segment-1.chunks.json")
        )
        // `detectLegacyV1` builds the directory URL with `isDirectory: true`,
        // so compare resolved paths rather than URL objects.
        XCTAssertEqual(
            LocalCheckpointValidator.detectLegacyV1(in: recovery)?.path,
            checkpoints.path
        )
        // v2 must never be written over v1.
        XCTAssertEqual(LocalCheckpointSchema.directoryName, "local-checkpoint-v2")
        XCTAssertNotEqual(LocalCheckpointSchema.directoryName, LocalChunkCheckpoint.directoryName)
    }

    // MARK: §9.1 source hashing

    func testContentHasherMatchesWholeFileAndWindowedDigests() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("audio.bin")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: url)

        let whole = try await LocalContentHasher.sha256(of: url)
        XCTAssertEqual(whole, LocalDigest.sha256(bytes))

        let window = try await LocalContentHasher.sha256(of: url, offset: 1_024, length: 1_024)
        XCTAssertEqual(window, LocalDigest.sha256(bytes.subdata(in: 1_024..<2_048)))
        XCTAssertNotEqual(window, whole)
    }

    func testContentHasherRefusesToDigestATruncatedPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("short.bin")
        try Data(repeating: 7, count: 16).write(to: url)
        do {
            _ = try await LocalContentHasher.sha256(of: url, offset: 0, length: 4_096)
            XCTFail("a truncated read must not forge an identity")
        } catch let error as LocalSourceIdentityError {
            XCTAssertEqual(error.code, "local_source_unreadable")
        }
    }

    func testContentHasherIsCancellable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("big.bin")
        try Data(repeating: 3, count: 3 * 1_048_576).write(to: url)

        // Park until cancellation actually lands, so this asserts the hasher's own
        // refusal rather than racing the read loop.
        let task = Task { () throws -> String in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            return try await LocalContentHasher.sha256(of: url)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled hash must not return a digest")
        } catch is CancellationError {
            // expected
        }
    }

    func testContentHasherReportsMissingSource() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("absent.m4a")
        do {
            _ = try await LocalContentHasher.sha256(of: url)
            XCTFail("a missing source must not hash")
        } catch let error as LocalSourceIdentityError {
            XCTAssertEqual(error.code, "local_source_changed")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSnapshotIsByteIdenticalAndPrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.m4a")
        let payload = Data((0..<8_192).map { UInt8($0 % 199) })
        try payload.write(to: source)

        let snapshot = directory.appendingPathComponent("private/snapshot.m4a")
        try LocalSourceSnapshot.create(from: source, to: snapshot)
        XCTAssertEqual(try Data(contentsOf: snapshot), payload)

        let permissions = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    // MARK: WAV layout

    private func writeWav(
        to url: URL,
        sampleCount: Int,
        channels: Int = 1,
        bits: Int = 16,
        formatTag: Int = 1,
        extraChunk: Bool = false
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
        var tag = UInt16(formatTag).littleEndian
        fmt.append(Data(bytes: &tag, count: 2))
        var ch = UInt16(channels).littleEndian
        fmt.append(Data(bytes: &ch, count: 2))
        var rate = UInt32(16_000).littleEndian
        fmt.append(Data(bytes: &rate, count: 4))
        var byteRate = UInt32(16_000 * channels * (bits / 8)).littleEndian
        fmt.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(channels * (bits / 8)).littleEndian
        fmt.append(Data(bytes: &blockAlign, count: 2))
        var bitsPer = UInt16(bits).littleEndian
        fmt.append(Data(bytes: &bitsPer, count: 2))
        chunk("fmt ", fmt)
        if extraChunk { chunk("LIST", Data("INFO".utf8)) }

        let pcm = Data(repeating: 0x11, count: dataBytes)
        var header = Data("RIFF".utf8)
        var riffSize = UInt32(4 + body.count + 8 + pcm.count).littleEndian
        header.append(Data(bytes: &riffSize, count: 4))
        header.append(Data("WAVE".utf8))
        header.append(body)
        header.append(Data("data".utf8))
        var dataSize = UInt32(pcm.count).littleEndian
        header.append(Data(bytes: &dataSize, count: 4))
        try (header + pcm).write(to: url)
    }

    func testWaveLayoutSkipsMetadataChunksAndExcludesHeaderFromDigest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = directory.appendingPathComponent("plain.wav")
        let withList = directory.appendingPathComponent("withlist.wav")
        try writeWav(to: plain, sampleCount: 1_000)
        try writeWav(to: withList, sampleCount: 1_000, extraChunk: true)

        let plainLayout = try WavePCMLayout.parse(at: plain)
        let listLayout = try WavePCMLayout.parse(at: withList)
        XCTAssertEqual(plainLayout.sampleCount, 1_000)
        XCTAssertEqual(listLayout.sampleCount, 1_000)
        XCTAssertNotEqual(plainLayout.dataOffset, listLayout.dataOffset)

        // Both hold identical samples, so the PCM digest matches even though the
        // whole-file digests differ. This is what makes the digest sample-level.
        let plainPCM = try await plainLayout.pcmSHA256(at: plain)
        let listPCM = try await listLayout.pcmSHA256(at: withList)
        XCTAssertEqual(plainPCM, listPCM)
        let plainFile = try await LocalContentHasher.sha256(of: plain)
        let listFile = try await LocalContentHasher.sha256(of: withList)
        XCTAssertNotEqual(plainFile, listFile)
    }

    func testWaveLayoutRejectsNonPCMAndTruncatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let adpcm = directory.appendingPathComponent("adpcm.wav")
        try writeWav(to: adpcm, sampleCount: 100, formatTag: 2)
        XCTAssertThrowsError(try WavePCMLayout.parse(at: adpcm)) { error in
            XCTAssertEqual((error as? LocalSourceIdentityError)?.code, "local_checkpoint_invalid")
        }

        let truncated = directory.appendingPathComponent("truncated.wav")
        try writeWav(to: truncated, sampleCount: 1_000)
        let full = try Data(contentsOf: truncated)
        try full.prefix(full.count - 500).write(to: truncated)
        XCTAssertThrowsError(try WavePCMLayout.parse(at: truncated)) { error in
            guard case .unexpectedWaveLayout = error as? LocalSourceIdentityError else {
                return XCTFail("expected unexpectedWaveLayout, got \(error)")
            }
        }

        let notRiff = directory.appendingPathComponent("notriff.wav")
        try Data("not a riff file at all".utf8).write(to: notRiff)
        XCTAssertThrowsError(try WavePCMLayout.parse(at: notRiff))
    }

    // MARK: Model manifest

    func testModelManifestDigestIsContentBasedAndOrderIndependent() async throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let snapshot = LocalModelManifestStore.snapshotDirectory(
            cacheDirectory: cache,
            modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
            revision: "rev1"
        )
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        try Data("weights-a".utf8).write(to: snapshot.appendingPathComponent("weights.safetensors"))
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))

        let manifest = try await LocalModelManifestStore.compute(
            modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
            revision: "rev1",
            cacheDirectory: cache
        )
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.files.map(\.relativePath), ["config.json", "weights.safetensors"])
        let first = manifest.digest
        let again = try await LocalModelManifestStore.compute(
            modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
            revision: "rev1",
            cacheDirectory: cache
        )
        XCTAssertEqual(again.digest, first)

        // Same path, same size, same name: only the bytes changed.
        try Data("weights-b".utf8).write(to: snapshot.appendingPathComponent("weights.safetensors"))
        let changed = try await LocalModelManifestStore.compute(
            modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
            revision: "rev1",
            cacheDirectory: cache
        )
        XCTAssertNotEqual(changed.digest, first)
    }

    func testModelManifestRequiresPinnedRevisionAndExistingSnapshot() async {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await LocalModelManifestStore.compute(
                modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
                revision: nil,
                cacheDirectory: cache
            )
            XCTFail("an unpinned model must not yield a manifest")
        } catch let error as LocalModelManifestError {
            guard case .revisionRequired = error else {
                return XCTFail("expected revisionRequired, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        do {
            _ = try await LocalModelManifestStore.compute(
                modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
                revision: "missing",
                cacheDirectory: cache
            )
            XCTFail("an absent snapshot must not yield a manifest")
        } catch let error as LocalModelManifestError {
            guard case .snapshotMissing = error else {
                return XCTFail("expected snapshotMissing, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Identity / manifest round trip on disk

    func testIdentityAndManifestRoundTripThroughDiskWithVerifiedDigests() throws {
        let recovery = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let layout = LocalCheckpointLayout(recoveryDirectory: recovery)
        try layout.createDirectories()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let identity = makeIdentityDocument()
        let identityBytes = CanonicalJSONEncoder.encode(identity)
        try AtomicFileWriter.write(identityBytes, to: layout.identityURL)

        let digest = LocalDigest.sha256(identityBytes)
        let roots = [makeRoot(order: 0, start: 0, end: 32 * 60 * 16_000)]
        let manifest = try makeManifest(identity: identity, identityDigest: digest, roots: roots)
        try AtomicFileWriter.write(
            CanonicalJSONEncoder.encode(manifest),
            to: layout.manifestURL
        )

        let loaded = try LocalCheckpointValidator.loadIdentity(at: layout.identityURL)
        XCTAssertEqual(loaded.digest, digest)
        XCTAssertEqual(loaded.document, identity)

        let loadedManifest = try LocalCheckpointValidator.loadManifest(at: layout.manifestURL)
        XCTAssertEqual(loadedManifest, manifest)
        XCTAssertNoThrow(
            try LocalCheckpointValidator.validate(
                manifest: loadedManifest,
                identity: loaded.document,
                identityDigest: loaded.digest
            )
        )

        // Permissions required by spec §8.
        for url in [layout.root, layout.rootsDirectoryURL, layout.audioDirectoryURL] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700, "\(url.lastPathComponent) must be 0700")
        }
        for url in [layout.identityURL, layout.manifestURL] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600, "\(url.lastPathComponent) must be 0600")
        }
    }

    /// A sliced job freezes `sliceStartSeconds` as a canonical `"%.6f"` string.
    /// Synthesized `Decodable` demanded a JSON number, so every sliced job wrote
    /// an `identity.json` that no resume could read back. This pins the bytes and
    /// the read path together, and keeps the strict integer guard on the sample
    /// coordinates that sit next to it.
    func testASlicedIdentityRoundTripsThroughItsOwnCanonicalBytes() throws {
        let recovery = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let layout = LocalCheckpointLayout(recoveryDirectory: recovery)
        try layout.createDirectories()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let sliced = makeIdentityDocument(
            workStart: 80_000,
            workEnd: 19_440_000,
            sliceStartSeconds: 5
        )
        let bytes = sliced.canonicalBytes()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(
            text.contains("\"sliceStartSeconds\":\"5.000000\""),
            "the canonical subset has no float type: \(text)"
        )
        try AtomicFileWriter.write(bytes, to: layout.identityURL)
        let loaded = try LocalCheckpointValidator.loadIdentity(at: layout.identityURL)
        XCTAssertEqual(loaded.document, sliced)
        XCTAssertEqual(loaded.document.source.sliceStartSeconds, 5)
        XCTAssertEqual(loaded.digest, LocalDigest.sha256(bytes))

        // The unsliced form records an explicit null, which must stay nil rather
        // than fail or become zero.
        let whole = makeIdentityDocument()
        XCTAssertTrue(
            String(decoding: whole.canonicalBytes(), as: UTF8.self)
                .contains("\"sliceStartSeconds\":null")
        )
        try AtomicFileWriter.write(whole.canonicalBytes(), to: layout.identityURL)
        XCTAssertNil(try LocalCheckpointValidator.loadIdentity(at: layout.identityURL).document.source.sliceStartSeconds)

        // `true` must not be laundered into `1` on a sample coordinate.
        let tampered = text.replacingOccurrences(
            of: "\"workStartSample\":80000",
            with: "\"workStartSample\":true"
        )
        XCTAssertNotEqual(tampered, text, "the fixture must actually contain the field")
        try AtomicFileWriter.write(Data(tampered.utf8), to: layout.identityURL)
        XCTAssertThrowsError(try LocalCheckpointValidator.loadIdentity(at: layout.identityURL)) { error in
            guard case let .invalidField(field, _) = error as? LocalCheckpointError else {
                return XCTFail("expected invalidField, got \(error)")
            }
            XCTAssertEqual(field, "source.workStartSample")
        }
    }

    func testManifestRejectsIdentityFileEditedAfterFreeze() throws {        let recovery = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let layout = LocalCheckpointLayout(recoveryDirectory: recovery)
        try layout.createDirectories()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let identity = makeIdentityDocument()
        let digest = LocalDigest.sha256(CanonicalJSONEncoder.encode(identity))
        let roots = [makeRoot(order: 0, start: 0, end: 32 * 60 * 16_000)]
        let manifest = try makeManifest(identity: identity, identityDigest: digest, roots: roots)
        try AtomicFileWriter.write(CanonicalJSONEncoder.encode(manifest), to: layout.manifestURL)

        // Same job, different prompt: the identity file no longer matches.
        let swapped = makeIdentityDocument(inference: makeInference(promptChannel: "context"))
        try AtomicFileWriter.write(
            CanonicalJSONEncoder.encode(swapped),
            to: layout.identityURL
        )
        let loaded = try LocalCheckpointValidator.loadIdentity(at: layout.identityURL)
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                manifest: manifest,
                identity: loaded.document,
                identityDigest: loaded.digest
            )
        ) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_identity_mismatch")
        }
    }

    // MARK: §9.2 planner — measured boundaries, not assumed ones

    private func source(
        order: Int,
        sampleCount: Int64,
        digestCharacter: Character = "c"
    ) -> LocalRootSource {
        LocalRootSource(
            order: order,
            audioURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("root-\(order).wav"),
            sampleCount: sampleCount,
            pcmSHA256: String(repeating: digestCharacter, count: 64)
        )
    }

    func testRootBoundariesAccumulateMeasuredSampleCountsExactly() throws {
        // ffmpeg cuts land a few samples off round numbers; the plan must record
        // what was measured, and a slice job must start where the recording does.
        let workStart = Int64(1_837 * 16_000)
        let counts: [Int64] = [19_199_997, 19_200_003, 11]
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: workStart,
            sources: counts.enumerated().map { source(order: $0.offset, sampleCount: $0.element) },
            chunkSeconds: 120
        )
        XCTAssertEqual(roots.map(\.startSample), [
            workStart,
            workStart + 19_199_997,
            workStart + 19_199_997 + 19_200_003
        ])
        XCTAssertEqual(roots.last?.endSample, workStart + 38_400_011)
        try roots.map(\.span).validatedTiling(
            of: LocalSampleSpan(start: workStart, end: roots.last!.endSample)
        )
        XCTAssertEqual(roots.map(\.order), [0, 1, 2])
        // IDs are derived from coordinates, so a one-sample shift changes them.
        XCTAssertNotEqual(roots[0].rootID, roots[1].rootID)
        XCTAssertEqual(
            roots[0].rootID,
            LocalCheckpointID.root(
                order: 0, startSample: workStart, endSample: workStart + 19_199_997
            )
        )
    }

    func testChunkTilingCoversRootExactlyWithShortTail() throws {
        // 250 seconds at 120-second windows: two full chunks plus a 10-second tail.
        let end = Int64(250 * 16_000)
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [source(order: 0, sampleCount: end)],
            chunkSeconds: 120
        )
        let chunks = roots[0].initialChunks
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].startSample, 0)
        XCTAssertEqual(chunks[0].endSample, 120 * 16_000)
        XCTAssertEqual(chunks[2].startSample, 240 * 16_000)
        XCTAssertEqual(chunks[2].endSample, end)
        try chunks.map(\.span).validatedTiling(of: LocalSampleSpan(start: 0, end: end))
    }

    func testSingleSampleRootStillGetsOneChunk() throws {
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 5,
            sources: [source(order: 0, sampleCount: 1)],
            chunkSeconds: 120
        )
        XCTAssertEqual(roots[0].initialChunks.count, 1)
        XCTAssertEqual(roots[0].initialChunks[0].startSample, 5)
        XCTAssertEqual(roots[0].initialChunks[0].endSample, 6)
    }

    func testRelativePathsStayInsideTheLayout() throws {
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [source(order: 0, sampleCount: 16_000)],
            chunkSeconds: 120
        )
        let layout = LocalCheckpointLayout(
            recoveryDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        // `resolve` is the containment gate; a planner path that it rejects would
        // be unwritable at runtime.
        XCTAssertEqual(
            try layout.resolve(relativePath: roots[0].audioRelativePath).path,
            layout.audioURL(rootID: roots[0].rootID).path
        )
        XCTAssertEqual(
            try layout.resolve(relativePath: roots[0].stateRelativePath).path,
            layout.stateURL(rootID: roots[0].rootID).path
        )
    }

    func testPlannerRejectsEmptyGappedAndDegenerateInput() {
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.makeRootPlans(
                workStartSample: 0, sources: [], chunkSeconds: 120
            )
        ) { error in
            XCTAssertEqual(error as? LocalPlannerError, .noRoots)
        }
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.makeRootPlans(
                workStartSample: 0,
                sources: [source(order: 1, sampleCount: 16_000)],
                chunkSeconds: 120
            )
        ) { error in
            XCTAssertEqual(error as? LocalPlannerError, .orderGap(expected: 0, found: 1))
        }
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.makeRootPlans(
                workStartSample: 0,
                sources: [source(order: 0, sampleCount: 0)],
                chunkSeconds: 120
            )
        ) { error in
            XCTAssertEqual(error as? LocalPlannerError, .emptyRoot(order: 0))
        }
        // A sub-sample window would produce an infinite chunk loop.
        for window in [0.0, -1.0, 1.0 / 32_000, Double.infinity] {
            XCTAssertThrowsError(
                try LocalCheckpointPlanner.makeRootPlans(
                    workStartSample: 0,
                    sources: [source(order: 0, sampleCount: 16_000)],
                    chunkSeconds: window
                )
            ) { error in
                XCTAssertEqual(error as? LocalPlannerError, .chunkWindowTooSmall(seconds: window))
            }
        }
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.makeRootPlans(
                workStartSample: 0,
                sources: [source(order: 0, sampleCount: 16_000)],
                chunkSeconds: .nan
            )
        ) { error in
            guard case .chunkWindowTooSmall = error as? LocalPlannerError else {
                return XCTFail("expected chunkWindowTooSmall, got \(error)")
            }
        }
        // A fractional window floors to whole samples rather than inventing a boundary.
        let floored = try? LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [source(order: 0, sampleCount: 32_000)],
            chunkSeconds: 1.5
        )
        XCTAssertEqual(floored?[0].initialChunks.count, 2)
        XCTAssertEqual(floored?[0].initialChunks[0].endSample, 24_000)
    }

    private func plannerLayout() throws -> (URL, LocalCheckpointLayout) {
        let recovery = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return (recovery, LocalCheckpointLayout(recoveryDirectory: recovery))
    }

    private func plannerRoots(workEnd: Int64) throws -> [LocalRootPlan] {
        try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [
                source(order: 0, sampleCount: workEnd / 2, digestCharacter: "c"),
                source(order: 1, sampleCount: workEnd - workEnd / 2, digestCharacter: "d")
            ],
            chunkSeconds: 120
        )
    }

    func testFreezeWritesIdentityThenManifestBoundByDigest() throws {
        let (recovery, layout) = try plannerLayout()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let workEnd = Int64(4 * 60 * 16_000)
        let identity = makeIdentityDocument(workStart: 0, workEnd: workEnd)
        let manifest = try LocalCheckpointPlanner.freeze(
            layout: layout,
            identity: identity,
            roots: try plannerRoots(workEnd: workEnd),
            createdAt: "2026-09-27T00:00:00Z"
        )

        let identityBytes = try Data(contentsOf: layout.identityURL)
        XCTAssertEqual(identityBytes, identity.canonicalBytes())
        XCTAssertEqual(manifest.identityDigest, LocalDigest.sha256(identityBytes))
        XCTAssertEqual(manifest.roots.count, 2)
        XCTAssertEqual(manifest.workEndSample, workEnd)

        let reloaded = try LocalCheckpointValidator.loadIdentity(at: layout.identityURL)
        let reloadedManifest = try LocalCheckpointValidator.loadManifest(at: layout.manifestURL)
        XCTAssertEqual(reloadedManifest, manifest)
        XCTAssertNoThrow(
            try LocalCheckpointValidator.validate(
                manifest: reloadedManifest,
                identity: reloaded.document,
                identityDigest: reloaded.digest
            )
        )

        for url in [layout.root, layout.rootsDirectoryURL, layout.audioDirectoryURL] {
            let mode = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700, "\(url.lastPathComponent) must be 0700")
        }
        for url in [layout.identityURL, layout.manifestURL] {
            let mode = try FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600, "\(url.lastPathComponent) must be 0600")
        }
    }

    func testFreezeRejectsRootsThatDoNotSpanTheWork() throws {
        let (recovery, layout) = try plannerLayout()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let workEnd = Int64(4 * 60 * 16_000)
        let identity = makeIdentityDocument(workStart: 0, workEnd: workEnd)

        // Roots planned from a different start than the identity records.
        let shifted = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 16_000,
            sources: [
                source(order: 0, sampleCount: workEnd / 2 - 16_000),
                source(order: 1, sampleCount: workEnd - workEnd / 2)
            ],
            chunkSeconds: 120
        )
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.freeze(
                layout: layout, identity: identity, roots: shifted,
                createdAt: "2026-09-27T00:00:00Z"
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalPlannerError,
                .workStartMismatch(expected: 0, found: 16_000)
            )
        }

        // Roots that stop short of the recorded work end.
        let short = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [source(order: 0, sampleCount: workEnd - 1)],
            chunkSeconds: 120
        )
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.freeze(
                layout: layout, identity: identity, roots: short,
                createdAt: "2026-09-27T00:00:00Z"
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalPlannerError,
                .workEndMismatch(expected: workEnd, found: workEnd - 1)
            )
        }

        XCTAssertThrowsError(
            try LocalCheckpointPlanner.freeze(
                layout: layout, identity: identity, roots: [],
                createdAt: "2026-09-27T00:00:00Z"
            )
        ) { error in
            XCTAssertEqual(error as? LocalPlannerError, .noRoots)
        }

        // Nothing may be left behind for a resume to mistake for a real plan.
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.identityURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.manifestURL.path))
    }

    func testFreezeRefusesAnUnverifiableModelBeforeWritingAnything() throws {
        let (recovery, layout) = try plannerLayout()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let workEnd = Int64(4 * 60 * 16_000)
        let identity = makeIdentityDocument(
            workStart: 0,
            workEnd: workEnd,
            inference: makeInference(modelManifestDigest: nil)
        )
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.freeze(
                layout: layout,
                identity: identity,
                roots: try plannerRoots(workEnd: workEnd),
                createdAt: "2026-09-27T00:00:00Z"
            )
        ) { error in
            guard case .unverifiableModelManifest = error as? LocalCheckpointError else {
                return XCTFail("expected unverifiableModelManifest, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.identityURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.manifestURL.path))
    }

    func testOpenOrFreezeFreezesOnceThenReusesWithoutRewriting() throws {
        let (recovery, layout) = try plannerLayout()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let workEnd = Int64(4 * 60 * 16_000)
        let identity = makeIdentityDocument(workStart: 0, workEnd: workEnd)
        let roots = try plannerRoots(workEnd: workEnd)

        let frozen = try LocalCheckpointPlanner.openOrFreeze(
            layout: layout, identity: identity, roots: roots,
            createdAt: "2026-09-27T00:00:00Z"
        )
        XCTAssertFalse(frozen.loadedExisting)
        let identityBytes = try Data(contentsOf: layout.identityURL)
        let manifestBytes = try Data(contentsOf: layout.manifestURL)

        // A resume with the same identity must hand back the frozen plan and
        // leave both files untouched, even though the caller recomputed roots.
        let reopened = try LocalCheckpointPlanner.openOrFreeze(
            layout: layout, identity: identity, roots: roots,
            createdAt: "2027-01-01T00:00:00Z"
        )
        XCTAssertTrue(reopened.loadedExisting)
        XCTAssertEqual(reopened.manifest, frozen.manifest)
        XCTAssertEqual(reopened.manifest.createdAt, "2026-09-27T00:00:00Z")
        XCTAssertEqual(try Data(contentsOf: layout.identityURL), identityBytes)
        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), manifestBytes)
    }

    func testOpenOrFreezeRefusesToResumeAgainstAChangedIdentity() throws {
        let (recovery, layout) = try plannerLayout()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let workEnd = Int64(4 * 60 * 16_000)
        let identity = makeIdentityDocument(workStart: 0, workEnd: workEnd)
        _ = try LocalCheckpointPlanner.freeze(
            layout: layout, identity: identity,
            roots: try plannerRoots(workEnd: workEnd),
            createdAt: "2026-09-27T00:00:00Z"
        )

        // Same job, glossary changed: results are no longer comparable.
        let restyled = makeIdentityDocument(
            workStart: 0,
            workEnd: workEnd,
            inference: makeInference(termsDigest: String(repeating: "9", count: 64))
        )
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.openOrFreeze(
                layout: layout, identity: restyled,
                roots: try plannerRoots(workEnd: workEnd),
                createdAt: "2026-09-27T00:00:00Z"
            )
        ) { error in
            guard case .frozenIdentityChanged = error as? LocalPlannerError else {
                return XCTFail("expected frozenIdentityChanged, got \(error)")
            }
        }
    }

    func testOpenOrFreezeRejectsAHalfWrittenPlan() throws {
        let (recovery, layout) = try plannerLayout()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let workEnd = Int64(4 * 60 * 16_000)
        let identity = makeIdentityDocument(workStart: 0, workEnd: workEnd)
        let roots = try plannerRoots(workEnd: workEnd)
        try layout.createDirectories()

        // identity without manifest: a crash between the two writes must not be
        // resumed as a fresh plan, because a resume cannot tell it apart from
        // one that never started.
        try AtomicFileWriter.write(identity.canonicalBytes(), to: layout.identityURL)
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.openOrFreeze(
                layout: layout, identity: identity, roots: roots,
                createdAt: "2026-09-27T00:00:00Z"
            )
        ) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_checkpoint_invalid")
        }

        // manifest without identity is equally unusable.
        try FileManager.default.removeItem(at: layout.identityURL)
        _ = try LocalCheckpointPlanner.freeze(
            layout: layout, identity: identity, roots: roots,
            createdAt: "2026-09-27T00:00:00Z"
        )
        try FileManager.default.removeItem(at: layout.identityURL)
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.openOrFreeze(
                layout: layout, identity: identity, roots: roots,
                createdAt: "2026-09-27T00:00:00Z"
            )
        ) { error in
            XCTAssertEqual((error as? LocalCheckpointError)?.code, "local_checkpoint_invalid")
        }
    }

    func testFrozenPlanIsReadableByThePythonHelper() throws {
        // The helper digests Swift's identity bytes verbatim; this proves the
        // frozen file is canonical JSON with sorted keys and no ASCII escaping.
        let (recovery, layout) = try plannerLayout()
        defer { try? FileManager.default.removeItem(at: recovery) }

        let workEnd = Int64(4 * 60 * 16_000)
        let identity = makeIdentityDocument(workStart: 0, workEnd: workEnd)
        _ = try LocalCheckpointPlanner.freeze(
            layout: layout, identity: identity,
            roots: try plannerRoots(workEnd: workEnd),
            createdAt: "2026-09-27T00:00:00Z"
        )
        let text = String(decoding: try Data(contentsOf: layout.identityURL), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{"))
        // Compact separators; a space inside a string value is fine, one after a
        // structural `,` or `:` is not.
        XCTAssertFalse(text.contains(", "), "canonical JSON must use compact separators")
        XCTAssertFalse(text.contains(": "), "canonical JSON must use compact separators")
        XCTAssertFalse(text.contains("\\u"), "non-ASCII must stay verbatim UTF-8")
        let keys = ["inference", "jobID", "normalizationProfile", "presentation", "schemaVersion", "source"]
        var last = -1
        for key in keys {
            let position = text.range(of: "\"\(key)\":")?.lowerBound
            XCTAssertNotNil(position, "missing key \(key)")
            let index = text.distance(from: text.startIndex, to: position!)
            XCTAssertGreaterThan(index, last, "keys must be sorted: \(key)")
            last = index
        }
    }
}
