import Foundation
import XCTest
@testable import RecordToTextApp
@testable import RecordToTextCore

@MainActor
final class AppCredentialMigrationTests: XCTestCase {
    func testSuccessfulMigrationStoresKeyBeforeRedactingLegacyFiles() throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore()

        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )

        XCTAssertEqual(store.storedAPIKey, "settings-legacy-secret")
        XCTAssertEqual(
            viewModel.settings.googleAIStudioAPIKey,
            "settings-legacy-secret"
        )
        XCTAssertFalse(try fileContainsSecret(fixture.paths.settings))
        XCTAssertFalse(try fileContainsSecret(fixture.paths.jobLedger))
    }

    func testFailedMigrationLeavesLegacyFilesUntouchedAcrossPersistenceAttempts() throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originalSettings = try Data(contentsOf: fixture.paths.settings)
        let originalLedger = try Data(contentsOf: fixture.paths.jobLedger)
        let store = FakeCredentialStore(failure: .unavailable)

        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )
        viewModel.setSetting(\.recentJobLimit, to: 11)

        XCTAssertEqual(try Data(contentsOf: fixture.paths.settings), originalSettings)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.jobLedger), originalLedger)
        XCTAssertEqual(
            viewModel.settings.googleAIStudioAPIKey,
            "settings-legacy-secret"
        )
        XCTAssertEqual(viewModel.alert?.title, "舊版 API Key 尚未遷移")
    }

    func testExistingKeychainValueWinsAndLegacyFilesAreRedacted() throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore(storedAPIKey: "keychain-secret")

        let viewModel = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )

        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, "keychain-secret")
        XCTAssertEqual(store.saveCallCount, 0)
        XCTAssertFalse(try fileContainsSecret(fixture.paths.settings))
        XCTAssertFalse(try fileContainsSecret(fixture.paths.jobLedger))
    }

    func testClearAfterMigrationRecoverySanitizesLedgerAndCannotResurrectKey() throws {
        let fixture = try makeLegacyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let store = FakeCredentialStore(failure: .unavailable)
        let firstLaunch = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )
        XCTAssertTrue(try fileContainsSecret(fixture.paths.settings))
        XCTAssertTrue(try fileContainsSecret(fixture.paths.jobLedger))

        store.failure = nil
        XCTAssertTrue(firstLaunch.setGoogleAIStudioAPIKey(nil))
        XCTAssertEqual(firstLaunch.googleAIStudioCredentialStorageState, .absent)
        XCTAssertFalse(try fileContainsSecret(fixture.paths.settings))
        XCTAssertFalse(try fileContainsSecret(fixture.paths.jobLedger))

        let secondLaunch = AppViewModel(
            paths: fixture.paths,
            credentialStore: store
        )
        XCTAssertEqual(secondLaunch.settings.googleAIStudioAPIKey, nil)
        XCTAssertEqual(store.storedAPIKey, nil)
        XCTAssertEqual(secondLaunch.googleAIStudioCredentialStorageState, .absent)
    }

    func testSaveAndDeleteFailuresRemainVisibleAndRetryable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let store = FakeCredentialStore()
        let viewModel = AppViewModel(paths: paths, credentialStore: store)

        store.failure = .unavailable
        XCTAssertFalse(viewModel.setGoogleAIStudioAPIKey("retry-key"))
        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, "retry-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .memoryOnly)

        store.failure = nil
        XCTAssertTrue(viewModel.setGoogleAIStudioAPIKey("retry-key"))
        XCTAssertEqual(store.storedAPIKey, "retry-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .stored)

        store.failure = .unavailable
        XCTAssertFalse(viewModel.setGoogleAIStudioAPIKey(nil))
        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, "retry-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .unavailable)

        store.failure = nil
        XCTAssertTrue(viewModel.setGoogleAIStudioAPIKey(nil))
        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, nil)
        XCTAssertEqual(store.storedAPIKey, nil)
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .absent)
    }

    func testClearKeepsKeychainValueWhenLegacySettingsRedactionFails() throws {
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

        store.failure = nil
        XCTAssertFalse(viewModel.setGoogleAIStudioAPIKey(nil))

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

    func testResetKeepsKeychainValueWhenLegacyLedgerRedactionFails() throws {
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

        store.failure = nil
        XCTAssertFalse(viewModel.resetSettings(keepGlossaries: true))

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

    func testDeleteThatMutatesThenThrowsRestoresPreviousKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let store = FakeCredentialStore(storedAPIKey: "existing-key")
        let viewModel = AppViewModel(paths: paths, credentialStore: store)

        store.failNextSaveAfterMutation = true
        XCTAssertFalse(viewModel.setGoogleAIStudioAPIKey(nil))

        XCTAssertEqual(store.storedAPIKey, "existing-key")
        XCTAssertEqual(
            Array(store.saveRequests.suffix(2)),
            [.delete, .store("existing-key")]
        )
        XCTAssertEqual(viewModel.settings.googleAIStudioAPIKey, "existing-key")
        XCTAssertEqual(viewModel.googleAIStudioCredentialStorageState, .stored)
        XCTAssertEqual(viewModel.alert?.title, "無法清除 API Key")
    }

    func testStoredKeyWithFailedLegacyRedactionRemainsRetryable() throws {
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

        store.failure = nil
        XCTAssertFalse(
            viewModel.setGoogleAIStudioAPIKey("replacement-key")
        )
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

private final class FakeCredentialStore: GoogleAIStudioCredentialStoring {
    enum Failure: Error {
        case unavailable
    }

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
