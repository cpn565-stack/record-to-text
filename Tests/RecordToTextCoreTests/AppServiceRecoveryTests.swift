import XCTest
@testable import RecordToTextCore
@testable import RecordToTextApp

@MainActor
final class AppServiceRecoveryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let paths: ApplicationPaths
        let source: URL
        var snapshot: JobSnapshot {
            .init(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: ["fixture-term"],
                prompt: "fixture-prompt", outputLocationMode: .fixedDirectory, outputDirectory: root.path,
                keepRawTranscript: false, backendType: .googleAIStudio, googleAIStudioModelID: "gemini-3.8-flash")
        }
        func job(paused: Bool = false) -> TranscriptionJob {
            var job = TranscriptionJob(sourcePath: source.path, snapshot: snapshot)
            if paused {
                job.stage = .interrupted
                var recovery = CloudServiceRecovery()
                recovery.state = .paused; recovery.stopReason = .attemptsExhausted; recovery.attempts = 4
                job.serviceRecovery = recovery
            }
            return job
        }
    }
    private func fixture(historyLimit: Int = 100) async throws -> Fixture {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let source = root.appendingPathComponent("fixture.wav")
        let runtime = RuntimeEnvironment.candidate(paths: paths,
            settings: AppSettings.defaultValue(developerMode: true), bundledHelperURL: nil)
        _ = try await ProcessRunner().run(executableURL: runtime.ffmpeg,
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-y", source.path])
        var settings = AppSettings.defaultValue(developerMode: true)
        settings.showNotificationWhenCompleted = false
        settings.revealInFinderWhenCompleted = false
        settings.openTextWhenCompleted = false
        settings.recentJobLimit = historyLimit
        try JSONRepository<AppSettings>(url: paths.settings).save(settings)
        return Fixture(root: root, paths: paths, source: source)
    }
    private func save(_ jobs: [TranscriptionJob], fixture: Fixture, limit: Int = 100) throws {
        try JobPersistenceStore(ledgerURL: fixture.paths.jobLedger, recentURL: fixture.paths.recentJobs)
            .write(.init(revision: 1, jobs: jobs, recentJobs: [], recentHistoryLimit: limit))
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryURLProtocol.self]
        return URLSession(configuration: config)
    }
    private func model(_ fixture: Fixture, session: URLSession,
                       sleep: QueueCompletionSleepCoordinator? = nil) async -> AppViewModel {
        let clock = RecoveryClock()
        let backend = GoogleAIStudioBackend(networkEnvironment: clock.environment(), urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false))
        let model = AppViewModel(paths: fixture.paths, credentialStore: ServiceCredentialStore(), engineFactory: { runtime in
            TranscriptionEngine(cloudNetworkEnvironment: clock.environment(), runtime: runtime, paths: fixture.paths,
                googleAIStudioBackend: backend, cloudAdaptiveMinimumChildDuration: 1)
        }, queueSleep: sleep)
        await model.waitForCredentialLoading()
        return model
    }
    private var success: Data {
        Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[00:00 - 00:02]\n講者 1：測試內容。"}]}}]}"#.utf8)
    }

    func testRealPipelinePausesThenManualResendOnceAndSleepsAfterDurableQueueCompletion() async throws {
        let fixture = try await fixture(), session = session()
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        let original = fixture.job(), next = fixture.job()
        try save([original, next], fixture: fixture)
        let countdown = RecoveryTestGate()
        var sleeps = 0
        let sleep = QueueCompletionSleepCoordinator(wait: { _ in try await countdown.wait() }, requestSleep: { sleeps += 1 })
        let sends = RecoveryValue(0)
        RecoveryURLProtocol.handler = { request in
            guard request.url!.absoluteString.contains(":generateContent") else { return (404, Data()) }
            sends.value += 1
            return (429, Data(#"{"error":{"message":"Resource exhausted"}}"#.utf8))
        }
        let model = await model(fixture, session: session, sleep: sleep)
        model.setSleepAfterCompletion(true)
        model.startQueuedJobs()
        try await TestSupport.eventually { model.jobs.first { $0.id == original.id }?.stage == .interrupted && model.activeJobID == nil }
        let paused = try XCTUnwrap(model.jobs.first { $0.id == original.id })
        XCTAssertEqual(paused.serviceRecovery?.stopReason, .attemptsExhausted)
        XCTAssertTrue(model.queuePausedForRecovery)
        XCTAssertNil(paused.networkRecovery)
        XCTAssertEqual(sends.value, 4)
        XCTAssertEqual(model.jobs.first { $0.id == next.id }?.stage, .queued)
        XCTAssertNil(sleep.countdownUntil)
        let path = try XCTUnwrap(paused.failure?.recoveryDirectory)
        let manifest = try JSONDecoder().decode(AudioSegmentManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("segment-manifest.json")))
        XCTAssertEqual(manifest.serviceRecovery?.stopReason, .attemptsExhausted)
        XCTAssertEqual(manifest.failureHistory?.generationRequestCount, 4)
        let response = success
        RecoveryURLProtocol.handler = { request in
            guard request.url!.absoluteString.contains(":generateContent") else { return (404, Data()) }
            sends.value += 1; return (200, response)
        }
        model.resendCloudJob(original.id)
        XCTAssertEqual(model.cloudResendStatus(original.id), "正在保存重送…")
        model.resumeCloudJobFromCheckpoint(original.id)
        try await TestSupport.eventually { await countdown.calls == 1 }
        let continuationID = try XCTUnwrap(model.jobs.first { $0.id == original.id }?.continuationJobID)
        let continuation = try XCTUnwrap(model.jobs.first { $0.id == continuationID })
        XCTAssertEqual(continuation.stage, .completed, continuation.failure?.technicalDetails ?? "")
        XCTAssertEqual(continuation.snapshot, original.snapshot)
        XCTAssertEqual(continuation.cloudDiagnostics?.failureHistory?.generationRequestCount, 5)
        XCTAssertEqual(sends.value, 6)
        XCTAssertEqual(model.cloudResendStatus(original.id), "重送已完成")
        XCTAssertLessThanOrEqual(try XCTUnwrap(continuation.startedAt), try XCTUnwrap(model.jobs.first { $0.id == next.id }?.startedAt))
        let journal = try XCTUnwrap(JobPersistenceStore(ledgerURL: fixture.paths.jobLedger, recentURL: fixture.paths.recentJobs).recover())
        XCTAssertEqual(journal.recentJobs.first { $0.id == next.id }?.stage, .completed)
        await countdown.release()
        try await TestSupport.eventually { sleeps == 1 }
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testManualContinuationCanPassOtherPausedParentsButOrdinaryQueueCannot() async throws {
        let fixture = try await fixture(), session = session()
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        let first = fixture.job(paused: true), second = fixture.job(paused: true), ordinary = fixture.job()
        try save([first, second, ordinary], fixture: fixture)
        let sends = RecoveryValue(0), response = success
        RecoveryURLProtocol.handler = { request in
            guard request.url!.absoluteString.contains(":generateContent") else { return (404, Data()) }
            sends.value += 1; return (200, response)
        }
        let model = await model(fixture, session: session)
        model.resendCloudJob(second.id)
        do { try await TestSupport.eventually {
            guard let id = model.jobs.first(where: { $0.id == second.id })?.continuationJobID else { return false }
            return model.jobs.first { $0.id == id }?.stage == .completed && model.activeJobID == nil
        } } catch {
            XCTFail("Continuation failed: \(model.jobs.map { ($0.stage, $0.failure?.technicalDetails, $0.continuationPending) }); alert=\(String(describing: model.alert?.message)); save=\(String(describing: model.jobPersistenceError))")
            await model.stopAllForTermination()
            throw error
        }
        XCTAssertTrue(model.queuePausedForRecovery)
        XCTAssertEqual(model.jobs.first { $0.id == ordinary.id }?.stage, .queued)
        XCTAssertEqual(sends.value, 1)
        model.startQueuedJobs()
        await Task.yield()
        XCTAssertNil(model.activeJobID)
        XCTAssertEqual(sends.value, 1)
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testZeroHistoryKeepsFailedContinuationAndCompletedReceiptPreventsReplay() async throws {
        let fixture = try await fixture(historyLimit: 0), session = session()
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        let parent = fixture.job(paused: true)
        try save([parent], fixture: fixture, limit: 0)
        let sends = RecoveryValue(0)
        RecoveryURLProtocol.handler = { request in
            guard request.url!.absoluteString.contains(":generateContent") else { return (404, Data()) }
            sends.value += 1
            return (400, Data(#"{"error":{"message":"invalid fixture argument"}}"#.utf8))
        }
        let model = await model(fixture, session: session)
        model.resendCloudJob(parent.id)
        try await TestSupport.eventually { sends.value == 1 && model.activeJobID == nil }
        let childID = try XCTUnwrap(model.jobs.first { $0.id == parent.id }?.continuationJobID)
        XCTAssertEqual(model.jobs.first { $0.id == childID }?.stage, .failed)
        XCTAssertNil(model.cloudResendStatus(parent.id))
        let response = success
        RecoveryURLProtocol.handler = { request in
            guard request.url!.absoluteString.contains(":generateContent") else { return (404, Data()) }
            sends.value += 1; return (200, response)
        }
        model.resendCloudJob(parent.id)
        try await TestSupport.eventually { model.cloudResendStatus(parent.id) == "重送已完成" && model.activeJobID == nil }
        XCTAssertFalse(model.jobs.contains { $0.stage == .completed })
        model.resendCloudJob(parent.id)
        XCTAssertEqual(sends.value, 2)
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
        let restored = AppViewModel(paths: fixture.paths, credentialStore: ServiceCredentialStore())
        await restored.waitForCredentialLoading()
        XCTAssertEqual(restored.cloudResendStatus(parent.id), "重送已完成")
        restored.resendCloudJob(parent.id)
        XCTAssertNil(restored.activeJobID)
        await restored.stopAllForTermination()
        try await restored.flushJobPersistence()
    }

    func testServiceContinuationCrashWindowKeepsSameIDAndZeroHistoryParent() async throws {
        let fixture = try await fixture()
        var parent = fixture.job()
        parent.stage = .failed // old build 6 failure has no recovery state
        var child = fixture.job()
        child.continuationParentJobID = parent.id
        parent.continuationJobID = child.id
        parent.continuationPending = false // saved, not yet started
        try save([parent, child], fixture: fixture, limit: 0)
        let entered = RecoveryValue(false), failWrites = RecoveryValue(false), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = AppViewModel(paths: fixture.paths, credentialStore: ServiceCredentialStore(), jobLedgerSaveOverride: { _ in
            guard failWrites.value else { return }
            entered.value = true
            _ = gate.wait(timeout: .now() + 2)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        await model.waitForCredentialLoading()
        failWrites.value = true
        XCTAssertEqual(model.jobs.first { $0.id == parent.id }?.continuationPending, true)
        XCTAssertTrue(model.queuePausedForRecovery)
        XCTAssertNil(model.cloudResendStatus(parent.id))
        model.resendCloudJob(parent.id)
        model.retryJob(parent.id)
        try await TestSupport.eventually { entered.value }
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs.first { $0.id == parent.id }?.continuationJobID, child.id)
        XCTAssertNil(model.activeJobID)
        await model.stopAllForTermination()
        failWrites.value = false
        gate.signal()
        await model.retryJobPersistence()
        XCTAssertFalse(model.manualDrainRequested)
    }

    func testDelayedJournalAndInteractiveWorkBlockCountdownUntilDurable() async throws {
        let fixture = try await fixture()
        var original = fixture.job()
        original.startedAt = Date()
        try save([original], fixture: fixture)
        let entered = RecoveryValue(false), holdWrites = RecoveryValue(false), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let countdown = RecoveryTestGate()
        var sleeps = 0
        let sleep = QueueCompletionSleepCoordinator(wait: { _ in try await countdown.wait() }, requestSleep: { sleeps += 1 })
        let model = AppViewModel(paths: fixture.paths, credentialStore: ServiceCredentialStore(), jobLedgerSaveOverride: { ledger in
            if ledger.jobs.contains(where: { $0.stage == .completed }) { XCTFail("Completed jobs belong to recent summaries") }
            if holdWrites.value && !entered.value {
                entered.value = true
                _ = gate.wait(timeout: .now() + 3)
            }
        }, queueSleep: sleep)
        await model.waitForCredentialLoading()
        holdWrites.value = true
        model.setSleepAfterCompletion(true)
        let output = fixture.root.appendingPathComponent("output.txt")
        try Data("fixture output".utf8).write(to: output)
        let completion = Task { await model.acceptCompletedResult(.init(outputURL: output, rawOutputURL: nil, duration: 1), id: original.id) }
        try await TestSupport.eventually { entered.value }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(sleep.countdownUntil)
        XCTAssertEqual(sleeps, 0)
        gate.signal()
        let saved = await completion.value
        XCTAssertTrue(saved)
        try await TestSupport.eventually { sleep.countdownUntil != nil }
        for action in 0..<3 {
            if action == 0 { model.beginFileImport() }
            if action == 1 { model.isDuplicateConfirmationPresented = true }
            if action == 2 { model.isPromptConsentPresented = true }
            XCTAssertNil(sleep.countdownUntil)
            if action == 0 { model.endFileImport() }
            if action == 1 { model.isDuplicateConfirmationPresented = false }
            if action == 2 { model.isPromptConsentPresented = false }
            XCTAssertNotNil(sleep.countdownUntil)
        }
        model.setSleepAfterCompletion(false)
        await countdown.release()
        XCTAssertEqual(sleeps, 0)
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testServerNotBeforeSurvivesRestartAndCancellationDoesNotSend() async throws {
        let fixture = try await fixture(), session = session()
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        var parent = fixture.job(paused: true)
        parent.serviceRecovery?.state = .unknown
        parent.serviceRecovery?.serverNotBefore = Date().addingTimeInterval(3600)
        try save([parent], fixture: fixture)
        RecoveryURLProtocol.handler = { _ in XCTFail("Server not-before bypassed"); return (500, Data()) }
        let model = await model(fixture, session: session)
        XCTAssertEqual(model.jobs.first?.serviceRecovery?.state, .paused)
        model.resendCloudJob(parent.id)
        do { try await TestSupport.eventually { model.activeJobID != nil } }
        catch {
            XCTFail("Continuation not active: \(model.jobs.map { ($0.stage, $0.failure?.technicalDetails, $0.continuationPending) }); alert=\(String(describing: model.alert?.message)); save=\(String(describing: model.jobPersistenceError))")
            await model.stopAllForTermination()
            throw error
        }
        let childID = try XCTUnwrap(model.activeJobID)
        XCTAssertEqual(model.cloudResendStatus(parent.id), "正在重送")
        model.resendCloudJob(parent.id)
        XCTAssertEqual(model.jobs.count, 2)
        model.cancelCurrentJob()
        try await TestSupport.eventually { model.activeJobID == nil }
        XCTAssertEqual(model.jobs.first { $0.id == childID }?.stage, .cancelled)
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }
}

private struct ServiceCredentialStore: GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String? { "fixture" }
    func saveAPIKey(_ apiKey: String?) throws {}
}
