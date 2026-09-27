import XCTest
@testable import RecordToTextCore
@testable import RecordToTextApp

@MainActor
final class AppNetworkRecoveryTests: XCTestCase {
    private func snapshot(_ root: URL) -> JobSnapshot {
        .init(modelID: "fixture-model", glossaryID: nil, glossaryName: nil, terms: ["fixture-term"],
              prompt: "fixture-prompt", outputLocationMode: .fixedDirectory, outputDirectory: root.path,
              keepRawTranscript: false, backendType: .googleAIStudio, googleAIStudioModelID: "gemini-3.8-flash")
    }
    private func paused(_ root: URL) -> TranscriptionJob {
        var job = TranscriptionJob(sourcePath: root.appendingPathComponent("fixture.wav").path,
            snapshot: snapshot(root), sourceSlice: .init(startSeconds: 1, durationSeconds: 2, partIndex: 1, partCount: 1))
        job.stage = .interrupted
        job.networkRecovery = .init(state: .paused, stopReason: .attemptsExhausted,
            waitedSeconds: 180, remainingWaitSeconds: 120, segmentIndex: 1, segmentCount: 3,
            completedSegmentCount: 0, lastFailure: .classify(URLError(.networkConnectionLost)), resultUnknown: true)
        return job
    }
    private func save(_ jobs: [TranscriptionJob], paths: ApplicationPaths) throws {
        try JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs)
            .write(.init(revision: 1, jobs: jobs, recentJobs: [], recentHistoryLimit: 0))
    }

    func testPausedRestartKeepsQueueAndZeroHistoryDoesNotRemoveSnapshot() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let parent = paused(root)
        let queued = TranscriptionJob(sourcePath: root.appendingPathComponent("next.wav").path, snapshot: snapshot(root))
        try save([parent, queued], paths: paths)
        let model = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore())
        await model.waitForCredentialLoading()
        model.setNotificationPreference(false)
        model.startQueuedJobs()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.queuePausedForNetwork)
        XCTAssertEqual(model.jobs.first?.snapshot, parent.snapshot)
        XCTAssertEqual(model.jobs.last?.stage, .queued)
        XCTAssertNil(model.activeJobID)
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
        let saved = try XCTUnwrap(JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs).recover())
        XCTAssertEqual(saved.jobs.first?.networkRecovery?.state, .paused)
        XCTAssertEqual(saved.jobs.last?.stage, .queued)
    }

    func testRealPipelinePausesFirstJobAndKeepsSecondQueuedThenResumesOnce() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let runtime = RuntimeEnvironment.candidate(paths: paths,
            settings: AppSettings.defaultValue(developerMode: true), bundledHelperURL: nil)
        let source = root.appendingPathComponent("fixture.wav")
        _ = try await ProcessRunner().run(executableURL: runtime.ffmpeg,
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-y", source.path])
        let original = TranscriptionJob(sourcePath: source.path, snapshot: snapshot(root))
        let next = TranscriptionJob(sourcePath: source.path, snapshot: snapshot(root))
        try save([original, next], paths: paths)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        var sends = 0
        RecoveryURLProtocol.handler = { request in
            guard request.url!.absoluteString.contains(":generateContent") else { return (404, Data()) }
            sends += 1
            throw URLError(.networkConnectionLost)
        }
        let clock = RecoveryClock()
        let backend = GoogleAIStudioBackend(networkEnvironment: clock.environment(), urlSession: session,
            configuration: .init(apiKey: "fixture-key", useFilesAPI: false))
        let model = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore(), engineFactory: { runtime in
            TranscriptionEngine(cloudNetworkEnvironment: clock.environment(), runtime: runtime, paths: paths,
                googleAIStudioBackend: backend, cloudAdaptiveMinimumChildDuration: 1)
        })
        await model.waitForCredentialLoading()
        model.setNotificationPreference(false)
        model.startQueuedJobs()
        for _ in 0..<500 {
            if model.queuePausedForNetwork && model.activeJobID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = try XCTUnwrap(model.jobs.first { $0.id == original.id })
        XCTAssertEqual(paused.stage, .interrupted, paused.failure?.technicalDetails ?? "")
        XCTAssertEqual(sends, 4)
        XCTAssertEqual(model.jobs.first { $0.id == next.id }?.stage, .queued)
        XCTAssertEqual(paused.cloudDiagnostics?.segments.last?.failure?.category, .connectionLost)
        XCTAssertEqual(paused.cloudDiagnostics?.failureHistory?.generationRequestCount, 4)
        XCTAssertFalse(model.canResumeCloudJob(paused))
        let recovery = try XCTUnwrap(paused.failure?.recoveryDirectory)
        let manifest = try JSONDecoder().decode(AudioSegmentManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: recovery).appendingPathComponent("segment-manifest.json")))
        XCTAssertEqual(manifest.segments.first?.diagnostic?.outcome, .failed)
        XCTAssertEqual(manifest.failureHistory?.generationRequestCount, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: recovery).appendingPathComponent("partial-transcript.txt").path))
        RecoveryURLProtocol.handler = { request in
            guard request.url!.absoluteString.contains(":generateContent") else { return (404, Data()) }
            sends += 1
            return (200, Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[00:00 - 00:02]\n講者 1：測試內容。"}]}}]}"#.utf8))
        }
        model.resumeNetworkPausedJob(original.id)
        model.resumeNetworkPausedJob(original.id)
        for _ in 0..<500 {
            if model.jobs.first(where: { $0.id == next.id })?.stage.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuationID = try XCTUnwrap(model.jobs.first { $0.id == original.id }?.networkContinuationJobID)
        let resumed = try XCTUnwrap(model.jobs.first { $0.id == continuationID })
        XCTAssertEqual(resumed.stage, .completed, resumed.failure?.technicalDetails ?? "")
        XCTAssertEqual(resumed.snapshot, original.snapshot)
        XCTAssertEqual(sends, 6)
        XCTAssertLessThanOrEqual(try XCTUnwrap(resumed.startedAt), try XCTUnwrap(model.jobs.first { $0.id == next.id }?.startedAt))
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testWaitingRestartPausesAndDoesNotSend() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        var parent = paused(root)
        parent.stage = .transcribing; parent.networkRecovery?.state = .waiting
        let queued = TranscriptionJob(sourcePath: "/next.wav", snapshot: snapshot(root))
        try save([parent, queued], paths: paths)
        let model = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore())
        await model.waitForCredentialLoading()
        XCTAssertEqual(model.jobs.first?.stage, .interrupted)
        XCTAssertEqual(model.jobs.first?.networkRecovery?.stopReason, .appRestarted)
        XCTAssertEqual(model.jobs.last?.stage, .queued)
        XCTAssertTrue(model.queuePausedForNetwork)
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testUnknownRecoveryStateRemainsActionableAfterRestart() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        var parent = paused(root)
        parent.networkRecovery?.state = .unknown
        try save([parent], paths: paths)
        let model = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore())
        await model.waitForCredentialLoading()
        XCTAssertTrue(model.queuePausedForNetwork)
        XCTAssertEqual(model.jobs.first?.networkRecovery?.state, .paused)
        model.cancelNetworkPausedJob(parent.id)
        XCTAssertFalse(model.queuePausedForNetwork)
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testCancelledTerminationDoesNotReviveAnEarlierResend() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let parent = paused(root)
        try Data("not valid audio".utf8).write(to: parent.sourceURL)
        try save([parent], paths: paths)
        let model = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore())
        await model.waitForCredentialLoading()
        model.setNotificationPreference(false)
        model.resumeNetworkPausedJob(parent.id)
        await model.stopAllForTermination()
        model.cancelTermination()
        try await model.saveLatestJobsForTermination()
        try await Task.sleep(for: .milliseconds(100))
        let continuationID = try XCTUnwrap(model.jobs.first { $0.id == parent.id }?.networkContinuationJobID)
        let continuation = try XCTUnwrap(model.jobs.first { $0.id == continuationID })
        XCTAssertNil(continuation.startedAt)
        XCTAssertEqual(continuation.stage, .queued)
        XCTAssertTrue(model.jobs.first { $0.id == parent.id }?.continuationPending == true)
        XCTAssertFalse(model.manualDrainRequested)
        await model.stopAllForTermination()
        try await model.saveLatestJobsForTermination()
    }

    func testTerminationWhileContinuationFlushesCannotStartAndRestartReusesItsID() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let parent = paused(root)
        try Data("fixture".utf8).write(to: parent.sourceURL)
        try save([parent], paths: paths)
        var engineCalls = 0
        let model = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore(),
            engineFactory: { runtime in engineCalls += 1; return TranscriptionEngine(runtime: runtime, paths: paths) })
        await model.waitForCredentialLoading()
        model.resumeNetworkPausedJob(parent.id)
        // Termination wins before the continuation's async flush can restart the queue.
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engineCalls, 0)
        XCTAssertFalse(model.manualDrainRequested)
        let continuation = try XCTUnwrap(model.jobs.first { $0.id == parent.id }?.networkContinuationJobID)
        XCTAssertEqual(model.jobs.first { $0.id == continuation }?.stage, .queued)

        let restored = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore(),
            jobLedgerSaveOverride: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        await restored.waitForCredentialLoading()
        XCTAssertTrue(restored.queuePausedForNetwork)
        XCTAssertNil(restored.activeJobID)
        restored.resumeNetworkPausedJob(parent.id)
        restored.resumeNetworkPausedJob(parent.id)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(restored.jobs.count, 2)
        XCTAssertEqual(restored.jobs.first { $0.id == parent.id }?.networkContinuationJobID, continuation)
        await restored.stopAllForTermination()
    }

    func testFailedContinuationSaveNeverStartsAndRepeatedClicksReuseOneJob() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let parent = paused(root)
        try Data("fixture".utf8).write(to: parent.sourceURL)
        let queued = TranscriptionJob(sourcePath: "/next.wav", snapshot: snapshot(root))
        try save([parent, queued], paths: paths)
        var engineCalls = 0
        let model = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore(),
            jobLedgerSaveOverride: { _ in throw CocoaError(.fileWriteOutOfSpace) },
            engineFactory: { runtime in engineCalls += 1; return TranscriptionEngine(runtime: runtime, paths: paths) })
        await model.waitForCredentialLoading()
        for _ in 0..<2 {
            model.resumeNetworkPausedJob(parent.id)
            model.resumeNetworkPausedJob(parent.id)
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertEqual(engineCalls, 0)
        XCTAssertTrue(model.queuePausedForNetwork)
        XCTAssertEqual(model.jobs.count, 3)
        let continuationID = try XCTUnwrap(model.jobs.first?.networkContinuationJobID)
        let continuation = try XCTUnwrap(model.jobs.first { $0.id == continuationID })
        XCTAssertEqual(continuation.snapshot, parent.snapshot)
        XCTAssertEqual(continuation.sourceSlice, parent.sourceSlice)
        XCTAssertNil(continuation.resumeFromRecoveryDirectory)
        XCTAssertEqual(model.jobs.filter { $0.stage == .queued }.first?.id, continuationID)
        XCTAssertFalse(model.manualDrainRequested)
        await model.stopAllForTermination()
    }

    func testCancellingPausedJobReleasesGateWithoutStartingNext() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let parent = paused(root)
        try save([parent, TranscriptionJob(sourcePath: "/next.wav", snapshot: snapshot(root))], paths: paths)
        let model = AppViewModel(paths: paths, credentialStore: RecoveryCredentialStore())
        await model.waitForCredentialLoading()
        model.startQueuedJobs()
        model.cancelNetworkPausedJob(parent.id)
        XCTAssertFalse(model.queuePausedForNetwork)
        XCTAssertFalse(model.manualDrainRequested)
        XCTAssertEqual(model.jobs.last?.stage, .queued)
        XCTAssertNil(model.activeJobID)
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }
}

private struct RecoveryCredentialStore: GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String? { "fixture-key" }
    func saveAPIKey(_ apiKey: String?) throws {}
}
