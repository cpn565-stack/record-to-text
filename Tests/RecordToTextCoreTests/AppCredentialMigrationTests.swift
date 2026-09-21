import Foundation
import Darwin
import XCTest
@testable import RecordToTextApp
@testable import RecordToTextCore

@MainActor
final class AppCredentialMigrationTests: XCTestCase {
    func testQueuedJobFollowsQuickMenuAndSettingsWithoutChangingContent() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppViewModel(paths: ApplicationPaths(root: root), credentialStore: FakeCredentialStore())
        await model.waitForCredentialLoading()
        model.setSetting(\.outputLocationMode, to: .fixedDirectory)
        model.setSetting(\.defaultOutputDirectory, to: root.path)
        model.selectQuickTranscriptionChoice(.qwen3ASR1_7BBF16)
        model.addFiles([root.appendingPathComponent("fixture.wav")])
        let original = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(original.snapshot.backendType, .localQwen)
        model.selectQuickTranscriptionChoice(.aiStudioGemini38Flash)
        let queued = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(queued.id, original.id)
        XCTAssertEqual(queued.stage, .queued)
        XCTAssertEqual(queued.snapshot.backendType, .googleAIStudio)
        XCTAssertEqual(queued.snapshot.requestedModelID, "gemini-3.8-flash")
        XCTAssertEqual(queued.snapshot.prompt, original.snapshot.prompt)
        XCTAssertEqual(queued.snapshot.outputDirectory, original.snapshot.outputDirectory)
        XCTAssertNil(queued.snapshot.googleAIStudioAPIKey)
        model.setSetting(\.backendType, to: .vertexAI)
        model.setSetting(\.vertexAIModelID, to: "custom-vertex")
        XCTAssertEqual(model.jobs.first?.snapshot.requestedModelID, "custom-vertex")
        XCTAssertEqual(model.jobs.first?.snapshot.backendType, .vertexAI)
        try await model.flushJobPersistence()
        let saved = try JSONRepository<JobLedgerCollection>(url: ApplicationPaths(root: root).jobLedger).load(default: .init(jobs: []))
        XCTAssertEqual(saved.jobs.first?.snapshot.backendType, .vertexAI)
    }

    func testEngineChangesExcludeRunningAndCheckpointJobs() {
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp", keepRawTranscript: false, backendType: .localQwen)
        var job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
        XCTAssertTrue(job.canUpdateQueuedEngine(activeJobID: nil))
        XCTAssertFalse(job.canUpdateQueuedEngine(activeJobID: job.id))
        job.resumeFromRecoveryDirectory = "/checkpoint"
        XCTAssertFalse(job.canUpdateQueuedEngine(activeJobID: nil))
        job.resumeFromRecoveryDirectory = nil
        job.continuationParentJobID = UUID()
        XCTAssertFalse(job.canUpdateQueuedEngine(activeJobID: nil), "Zero-checkpoint resend must preserve the original model")
        job.continuationParentJobID = nil
        job.stage = .transcribing
        XCTAssertFalse(job.canUpdateQueuedEngine(activeJobID: nil))
        XCTAssertTrue(job.snapshot.engineDisplayName.contains("本機 Qwen"))
    }

    func testActualMainActorPersistenceSubmissionBenchmark() async throws {
        for count in [10, 100, 1000] {
            let root = try TestSupport.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ApplicationPaths(root: root)
            let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: [], prompt: "fixture", outputLocationMode: .fixedDirectory, outputDirectory: root.path, keepRawTranscript: false)
            let jobs = (0..<count).map { index in
                var job = TranscriptionJob(sourcePath: "/fixture-\(index).wav", snapshot: snapshot)
                job.stage = .interrupted
                job.logLines = (0..<400).map { "工作 \(index) 紀錄 \($0)：效能測試，非使用者資料。" }
                return job
            }
            try JSONRepository<JobLedgerCollection>(url: paths.jobLedger).save(.init(jobs: jobs))
            let model = AppViewModel(paths: paths, credentialStore: FakeCredentialStore())
            await model.waitForCredentialLoading()
            for iteration in 1...3 {
                var samples: [Double] = []
                for _ in 0..<100 {
                    let start = ContinuousClock.now
                    XCTAssertTrue(model.persistJobs(urgency: .coalescible))
                    samples.append(start.duration(to: .now).secondsValue * 1000)
                }
                try await model.flushJobPersistence()
                let p95 = samples.sorted()[94]
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                print("app_submit jobs=\(count) logs=400 run=\(iteration) p95_ms=\(p95) process_peak_rss_bytes=\(usage.ru_maxrss)")
                XCTAssertLessThan(p95, 16)
            }
        }
    }

    func testAppStartupRecoversPublicationAndDeletionStaysDeleted() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: [], prompt: "fixture", outputLocationMode: .fixedDirectory, outputDirectory: root.path, keepRawTranscript: false)
        let job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
        let store = JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs)
        try store.write(.init(revision: 1, jobs: [job], recentJobs: [], recentHistoryLimit: 10))
        let output = root.appendingPathComponent("final.txt")
        let publication = OutputPublicationStore(paths: paths)
        try publication.prepare(job: job, result: .init(outputURL: output, rawOutputURL: nil, duration: 1), text: "完成")
        try AtomicFileWriter.writeTextNew("完成", to: output)
        let model = AppViewModel(paths: paths, credentialStore: FakeCredentialStore())
        await model.waitForCredentialLoading()
        XCTAssertEqual(model.jobs.first?.stage, .completed)
        XCTAssertEqual(model.recentJobs.first?.outputPath, output.path)
        // Simulate the durable deletion while a stale publication receipt remains.
        try publication.prepare(job: job, result: .init(outputURL: output, rawOutputURL: nil, duration: 1), text: "完成")
        try store.write(.init(revision: 100, jobs: [], recentJobs: [], recentHistoryLimit: 10))
        let next = AppViewModel(paths: paths, credentialStore: FakeCredentialStore())
        await next.waitForCredentialLoading()
        XCTAssertTrue(next.jobs.isEmpty)
        XCTAssertTrue(next.recentJobs.isEmpty)
    }

    func testSlowCredentialReadDoesNotBlockInitializer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FakeCredentialStore()
        store.loadDelay = 0.4
        let start = Date()
        let model = AppViewModel(paths: ApplicationPaths(root: root), credentialStore: store)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        _ = model.settings
        await model.waitForCredentialLoading()
    }

    func testLoadingKeepsUIEditableAndRejectsConflictingCredentialWrites() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore(storedAPIKey: "loaded-key")
        store.loadDelay = 0.3
        let model = AppViewModel(paths: fixture.paths, credentialStore: store)
        XCTAssertTrue(model.isGoogleAIStudioCredentialLoading)
        model.setSetting(\.recentJobLimit, to: 17)
        XCTAssertEqual(model.settings.recentJobLimit, 17)
        do { let result = await model.setGoogleAIStudioAPIKey("must-not-overwrite"); XCTAssertFalse(result) }
        XCTAssertTrue(try fileContainsSecret(fixture.paths.settings))
        await model.waitForCredentialLoading()
        XCTAssertFalse(model.isGoogleAIStudioCredentialLoading)
        XCTAssertEqual(model.settings.recentJobLimit, 17)
        XCTAssertEqual(model.settings.googleAIStudioAPIKey, "loaded-key")
        XCTAssertEqual(store.saveCallCount, 0)
        XCTAssertFalse(try fileContainsSecret(fixture.paths.settings))
    }

    func testAIStudioJobStaysQueuedDuringCredentialLoading() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore()
        store.loadDelay = 0.4
        let model = AppViewModel(paths: fixture.paths, credentialStore: store)
        let original = try XCTUnwrap(model.jobs.first { $0.id == fixture.jobID })
        try Data("fixture audio".utf8).write(to: original.sourceURL)
        model.retryJob(fixture.jobID)
        let queued = try XCTUnwrap(model.jobs.first(where: { $0.stage == .queued }))
        model.startQueuedJobs()
        await Task.yield()
        XCTAssertNil(model.activeJobID)
        XCTAssertEqual(model.jobs.first(where: { $0.id == queued.id })?.stage, .queued)
        // Cancel the pending work before loading finishes; no real API is called.
        model.removeQueuedJob(queued.id)
        await model.waitForCredentialLoading()
        XCTAssertFalse(model.jobs.contains(where: { $0.id == queued.id }))
        XCTAssertNil(model.jobs.first { $0.id == fixture.jobID }?.cloudContinuationID)
        XCTAssertNil(model.cloudResendStatus(fixture.jobID))
    }

    func testSuccessfulMigrationStoresKeyBeforeRedactingLegacyFiles() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore()

        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )
        await viewModel.waitForCredentialLoading()

        XCTAssertEqual(store.storedAPIKey, "settings-legacy-secret")
        XCTAssertEqual(
            viewModel.settings.googleAIStudioAPIKey,
            "settings-legacy-secret"
        )
        XCTAssertFalse(try fileContainsSecret(fixture.paths.settings))
        XCTAssertFalse(try fileContainsSecret(fixture.paths.jobLedger))
    }

    func testFailedMigrationLeavesLegacyFilesUntouchedAcrossPersistenceAttempts() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originalSettings = try Data(contentsOf: fixture.paths.settings)
        let originalLedger = try Data(contentsOf: fixture.paths.jobLedger)
        let store = FakeCredentialStore(failure: .unavailable)

        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )
        await viewModel.waitForCredentialLoading()
        viewModel.setSetting(\.recentJobLimit, to: 11)

        XCTAssertEqual(try Data(contentsOf: fixture.paths.settings), originalSettings)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.jobLedger), originalLedger)
        XCTAssertEqual(
            viewModel.settings.googleAIStudioAPIKey,
            "settings-legacy-secret"
        )
        XCTAssertEqual(
            viewModel.googleAIStudioCredentialStorageState,
            .memoryOnly
        )
        XCTAssertTrue(
            viewModel.alert?.message.contains("Keychain") == true
        )
    }

    func testExistingKeychainValueWinsAndLegacyFilesAreRedacted() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore(storedAPIKey: "keychain-secret")

        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )
        await viewModel.waitForCredentialLoading()

        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, "keychain-secret")
        XCTAssertEqual(store.saveCallCount, 0)
        XCTAssertFalse(try fileContainsSecret(fixture.paths.settings))
        XCTAssertFalse(try fileContainsSecret(fixture.paths.jobLedger))
    }

    func testClearAfterMigrationRecoverySanitizesLedgerAndCannotResurrectKey() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore(failure: .unavailable)
        let firstLaunch = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )
        await firstLaunch.waitForCredentialLoading()
        XCTAssertTrue(try fileContainsSecret(fixture.paths.settings))
        XCTAssertTrue(try fileContainsSecret(fixture.paths.jobLedger))

        store.failure = nil
        do { let result = await firstLaunch.setGoogleAIStudioAPIKey(nil); XCTAssertTrue(result) }
        XCTAssertEqual(firstLaunch.googleAIStudioCredentialStorageState, .absent)
        XCTAssertFalse(try fileContainsSecret(fixture.paths.settings))
        XCTAssertFalse(try fileContainsSecret(fixture.paths.jobLedger))

        let secondLaunch = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )
        await secondLaunch.waitForCredentialLoading()
        XCTAssertEqual(secondLaunch.settings.googleAIStudioAPIKey, nil)
        XCTAssertEqual(store.storedAPIKey, nil)
        XCTAssertEqual(secondLaunch.googleAIStudioCredentialStorageState, .absent)
    }

    func testSaveAndDeleteFailuresRemainVisibleAndRetryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let store = FakeCredentialStore()
        let viewModel = AppViewModel(paths: paths, credentialStore: store)
        await viewModel.waitForCredentialLoading()

        store.failure = .unavailable
        do { let result = await viewModel.setGoogleAIStudioAPIKey("retry-key"); XCTAssertFalse(result) }
        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, "retry-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .memoryOnly)

        store.failure = nil
        do { let result = await viewModel.setGoogleAIStudioAPIKey("retry-key"); XCTAssertTrue(result) }
        XCTAssertEqual(store.storedAPIKey, "retry-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .stored)

        store.failure = .unavailable
        do { let result = await viewModel.setGoogleAIStudioAPIKey(nil); XCTAssertFalse(result) }
        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, "retry-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .unavailable)

        store.failure = nil
        do { let result = await viewModel.setGoogleAIStudioAPIKey(nil); XCTAssertTrue(result) }
        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, nil)
        XCTAssertEqual(store.storedAPIKey, nil)
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .absent)
    }

    func testClearKeepsKeychainValueWhenLegacySettingsRedactionFails() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore(failure: .unavailable)
        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store,
            settingsSaveOverride: { _ in
                throw PersistenceFailure.settings
            }
        )
        await viewModel.waitForCredentialLoading()

        store.failure = nil
        do { let result = await viewModel.setGoogleAIStudioAPIKey(nil); XCTAssertFalse(result) }

        XCTAssertEqual(store.storedAPIKey, "settings-legacy-secret")
        XCTAssertFalse(store.saveRequests.contains(.delete))
        XCTAssertEqual(
            viewModel.settings.googleAIStudioAPIKey,
            "settings-legacy-secret"
        )
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .stored)
        XCTAssertTrue(
            try fileContains("settings-legacy-secret", in: fixture.paths.settings)
        )
        XCTAssertEqual(viewModel.alert?.title, "無法清除 API Key")
    }

    func testResetKeepsKeychainValueWhenLegacyLedgerRedactionFails() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore(failure: .unavailable)
        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store,
            jobLedgerSaveOverride: { _ in
                throw PersistenceFailure.ledger
            }
        )
        await viewModel.waitForCredentialLoading()

        store.failure = nil
        do { let result = await viewModel.resetSettings(keepGlossaries: true); XCTAssertFalse(result) }

        XCTAssertEqual(store.storedAPIKey, "settings-legacy-secret")
        XCTAssertFalse(store.saveRequests.contains(.delete))
        XCTAssertEqual(
            viewModel.settings.googleAIStudioAPIKey,
            "settings-legacy-secret"
        )
        XCTAssertTrue(
            try fileContains("ledger-legacy-secret", in: fixture.paths.jobLedger)
        )
        XCTAssertFalse(
            try fileContains("settings-legacy-secret", in: fixture.paths.settings)
        )
        XCTAssertEqual(viewModel.alert?.title, "無法清除 API Key")
    }

    func testDeleteThatMutatesThenThrowsRestoresPreviousKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let store = FakeCredentialStore(storedAPIKey: "existing-key")
        let viewModel = AppViewModel(paths: paths, credentialStore: store)
        await viewModel.waitForCredentialLoading()

        store.failNextSaveAfterMutation = true
        do { let result = await viewModel.setGoogleAIStudioAPIKey(nil); XCTAssertFalse(result) }

        XCTAssertEqual(store.storedAPIKey, "existing-key")
        XCTAssertEqual(
            Array(store.saveRequests.suffix(2)),
            [.delete, .store("existing-key")]
        )
        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, "existing-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .stored)
        XCTAssertEqual(viewModel.alert?.title, "無法清除 API Key")
    }

    func testStoredKeyWithFailedLegacyRedactionRemainsRetryable() async throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore(failure: .unavailable)
        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store,
            settingsSaveOverride: { _ in
                throw PersistenceFailure.settings
            }
        )
        await viewModel.waitForCredentialLoading()

        store.failure = nil
        do { let result = await viewModel.setGoogleAIStudioAPIKey("replacement-key"); XCTAssertFalse(result) }
        XCTAssertEqual(store.storedAPIKey, "replacement-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .stored)
        XCTAssertTrue(viewModel.hasPendingGoogleAIStudioCredentialMigration)
        XCTAssertFalse(
            GoogleAIStudioAPIKeyDraftPolicy.shouldDisableSave(
                normalizedDraft: "replacement-key",
                normalizedInMemoryAPIKey: "replacement-key",
                storageState: .stored,
                hasPendingMigration: true
            )
        )
    }

    func testAPICredentialDraftReflectsClearResult() {
        XCTAssertTrue(
            GoogleAIStudioAPIKeyDraftPolicy.shouldDisableSave(
                normalizedDraft: nil,
                normalizedInMemoryAPIKey: nil,
                storageState: .absent,
                hasPendingMigration: false
            )
        )
        XCTAssertTrue(
            GoogleAIStudioAPIKeyDraftPolicy.shouldDisableSave(
                normalizedDraft: "stored-key",
                normalizedInMemoryAPIKey: "stored-key",
                storageState: .stored,
                hasPendingMigration: false
            )
        )
        XCTAssertFalse(
            GoogleAIStudioAPIKeyDraftPolicy.shouldDisableSave(
                normalizedDraft: "stored-key",
                normalizedInMemoryAPIKey: "stored-key",
                storageState: .stored,
                hasPendingMigration: true
            )
        )
        XCTAssertEqual(
            GoogleAIStudioAPIKeyDraftPolicy.afterClearAttempt(
                succeeded: true,
                attemptedDraft: "typed-key",
                inMemoryAPIKey: "old-key"
            ),
            ""
        )
        XCTAssertEqual(
            GoogleAIStudioAPIKeyDraftPolicy.afterClearAttempt(
                succeeded: false,
                attemptedDraft: "",
                inMemoryAPIKey: "old-key"
            ),
            "old-key"
        )
        XCTAssertEqual(
            GoogleAIStudioAPIKeyDraftPolicy.afterClearAttempt(
                succeeded: false,
                attemptedDraft: "unsaved-key",
                inMemoryAPIKey: nil
            ),
            "unsaved-key"
        )
    }

    private func makeLegacyFixture() throws -> (paths: ApplicationPaths, jobID: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-migration-\(UUID().uuidString)")
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()

        let settingsRepository = JSONRepository<AppSettings>(url: paths.settings)
        try settingsRepository.save(
            AppSettings(defaultOutputDirectory: root.appendingPathComponent("output").path)
        )
        try inject(
            key: "googleAIStudioAPIKey",
            value: "settings-legacy-secret",
            into: paths.settings
        )

        let snapshot = JobSnapshot(
            modelID: "gemini-test",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "prompt",
            outputLocationMode: .fixedDirectory,
            outputDirectory: root.path,
            keepRawTranscript: false,
            backendType: .googleAIStudio
        )
        let job = TranscriptionJob(
            sourcePath: root.appendingPathComponent("meeting.m4a").path,
            snapshot: snapshot,
            stage: .failed
        )
        let ledgerRepository = JSONRepository<JobLedgerCollection>(
            url: paths.jobLedger
        )
        try ledgerRepository.save(JobLedgerCollection(jobs: [job]))
        try inject(
            key: "googleAIStudioAPIKey",
            value: "ledger-legacy-secret",
            intoFirstJobSnapshotAt: paths.jobLedger
        )
        return (paths, job.id)
    }

    private func inject(key: String, value: String, into url: URL) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        object[key] = value
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url)
    }

    private func inject(
        key: String,
        value: String,
        intoFirstJobSnapshotAt url: URL
    ) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
        var snapshot = try XCTUnwrap(jobs.first?["snapshot"] as? [String: Any])
        snapshot[key] = value
        jobs[0]["snapshot"] = snapshot
        object["jobs"] = jobs
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url)
    }

    private func fileContainsSecret(_ url: URL) throws -> Bool {
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        return text.contains("settings-legacy-secret")
            || text.contains("ledger-legacy-secret")
    }

    private func fileContains(_ value: String, in url: URL) throws -> Bool {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .contains(value)
    }
}

private enum PersistenceFailure: Error {
    case settings
    case ledger
}

private final class FakeCredentialStore: GoogleAIStudioCredentialStoring, @unchecked Sendable {
    enum Failure: Error {
        case unavailable
    }

    var loadDelay: TimeInterval = 0
    var storedAPIKey: String?
    var saveCallCount = 0
    var saveRequests: [SaveRequest] = []
    var failure: Failure?
    var failNextSaveAfterMutation = false

    enum SaveRequest: Equatable {
        case store(String)
        case delete
    }

    init(storedAPIKey: String? = nil, failure: Failure? = nil) {
        self.storedAPIKey = storedAPIKey
        self.failure = failure
    }

    func loadAPIKey() throws -> String? {
        Thread.sleep(forTimeInterval: loadDelay)
        if let failure {
            throw failure
        }
        return storedAPIKey
    }

    func saveAPIKey(_ apiKey: String?) throws {
        saveCallCount += 1
        saveRequests.append(apiKey.map(SaveRequest.store) ?? .delete)
        if let failure {
            throw failure
        }
        storedAPIKey = apiKey
        if failNextSaveAfterMutation {
            failNextSaveAfterMutation = false
            throw Failure.unavailable
        }
    }
}
