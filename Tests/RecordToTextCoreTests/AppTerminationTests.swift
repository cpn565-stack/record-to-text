import Foundation
import XCTest
@testable import RecordToTextApp
@testable import RecordToTextCore

@MainActor
final class AppTerminationTests: XCTestCase {
    func testTerminationPersistsWhileUnrelatedCredentialReadIsBlocked() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let credentials = TerminationCredentialStore()
        let model = AppViewModel(paths: paths, credentialStore: credentials)
        model.addFiles([root.appendingPathComponent("fixture.wav")])
        let jobID = try XCTUnwrap(model.jobs.first?.id)
        await model.stopAllForTermination()
        XCTAssertTrue(model.isGoogleAIStudioCredentialLoading)
        do {
            try await model.saveLatestJobsForTermination()
            let saved = try XCTUnwrap(JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs).recover())
            XCTAssertEqual(saved.jobs.first?.id, jobID)
            XCTAssertEqual(saved.jobs.first?.stage, .cancelled)
        } catch {
            XCTFail("Unrelated Keychain loading must not block saving: \(error.localizedDescription)")
        }
        credentials.release()
        await model.waitForCredentialLoading()
    }

    func testTerminationWaitsForLegacyCredentialBeforeRedactingLedger() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let original = try makeLegacyLedger(paths)
        let credentials = TerminationCredentialStore()
        let model = AppViewModel(paths: paths, credentialStore: credentials)
        await model.stopAllForTermination()
        XCTAssertEqual(try Data(contentsOf: paths.jobLedger), original)
        let unblock = Task {
            try? await Task.sleep(for: .milliseconds(100))
            credentials.release()
        }
        do {
            try await model.saveLatestJobsForTermination()
            XCTAssertFalse(model.isGoogleAIStudioCredentialLoading)
            XCTAssertFalse(String(decoding: try Data(contentsOf: paths.jobLedger), as: UTF8.self).contains("fixture-legacy-secret"))
            XCTAssertEqual(credentials.storedKey, "fixture-legacy-secret")
        } catch {
            XCTFail("Quit should wait for the pending credential migration: \(error.localizedDescription)")
        }
        await unblock.value
        await model.waitForCredentialLoading()
    }

    func testLegacyCredentialTimeoutPreservesLedgerAndCanRetry() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let original = try makeLegacyLedger(paths)
        let credentials = TerminationCredentialStore()
        let model = AppViewModel(paths: paths, credentialStore: credentials)
        await model.stopAllForTermination()
        do {
            try await model.saveLatestJobsForTermination(timeout: .milliseconds(30))
            XCTFail("Legacy credential migration must not be bypassed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Keychain"))
            XCTAssertEqual(model.jobPersistenceError, error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: paths.jobLedger), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("job-journal.json").path))
        credentials.release()
        await model.waitForCredentialLoading()
        try await model.saveLatestJobsForTermination()
        XCTAssertNil(model.jobPersistenceError)
    }

    func testCancellingQuitAllowsManualStartWithoutAutomaticRestart() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TerminationCredentialStore()
        let model = AppViewModel(paths: ApplicationPaths(root: root), credentialStore: credentials)
        model.setNotificationPreference(false)
        model.addFiles([root.appendingPathComponent("cancelled.wav")])
        model.startQueuedJobs()
        await model.stopAllForTermination()
        model.cancelTermination()
        model.addFiles([root.appendingPathComponent("missing.wav")])
        let nextID = try XCTUnwrap(model.jobs.last?.id)
        credentials.release()
        await model.waitForCredentialLoading()
        XCTAssertFalse(model.manualDrainRequested)
        XCTAssertTrue(model.jobs.allSatisfy { $0.startedAt == nil })
        model.startQueuedJobs()
        for _ in 0..<100 {
            if model.jobs.first(where: { $0.id == nextID })?.startedAt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.jobs.first(where: { $0.id == nextID })?.startedAt)
        await model.stopAllForTermination()
        try await model.saveLatestJobsForTermination()
    }

    func testUnreadableJournalIsNeverOverwrittenByQuitOrRetry() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let journal = root.appendingPathComponent("job-journal.json")
        let original = Data("broken fixture journal".utf8)
        try original.write(to: journal)
        let credentials = TerminationCredentialStore()
        credentials.release()
        let model = AppViewModel(paths: paths, credentialStore: credentials)
        await model.waitForCredentialLoading()
        await model.stopAllForTermination()
        do {
            try await model.saveLatestJobsForTermination()
            XCTFail("An unreadable journal must remain protected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("停止儲存"))
            XCTAssertEqual(model.jobPersistenceError, error.localizedDescription)
        }
        await model.retryJobPersistence()
        XCTAssertEqual(try Data(contentsOf: journal), original)
        XCTAssertNotNil(model.jobPersistenceError)
    }

    func testWriteFailureShowsUnderlyingErrorInsteadOfGenericTimeout() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TerminationCredentialStore()
        let failure = CocoaError(.fileWriteOutOfSpace)
        let model = AppViewModel(paths: ApplicationPaths(root: root), credentialStore: credentials,
            jobLedgerSaveOverride: { _ in throw failure })
        await model.stopAllForTermination()
        do {
            try await model.saveLatestJobsForTermination(timeout: .milliseconds(100))
            XCTFail("Failed writes must not be acknowledged as durable")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(failure.localizedDescription))
            XCTAssertFalse(error.localizedDescription.contains("本片段"))
            XCTAssertEqual(model.jobPersistenceError, error.localizedDescription)
        }
        credentials.release()
        await model.waitForCredentialLoading()
    }

    func testSlowWriterTimeoutCanBeRetriedWithoutLosingJobs() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let credentials = TerminationCredentialStore()
        let model = AppViewModel(paths: paths, credentialStore: credentials,
            jobLedgerSaveOverride: { _ in Thread.sleep(forTimeInterval: 0.2) })
        model.addFiles([root.appendingPathComponent("fixture.wav")])
        let jobID = try XCTUnwrap(model.jobs.first?.id)
        await model.stopAllForTermination()
        do {
            try await model.saveLatestJobsForTermination(timeout: .milliseconds(30))
            XCTFail("A slow write must time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("寫入逾時"))
            XCTAssertFalse(error.localizedDescription.contains("本片段"))
        }
        try await model.saveLatestJobsForTermination()
        XCTAssertNil(model.jobPersistenceError)
        let saved = try XCTUnwrap(JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs).recover())
        XCTAssertEqual(saved.jobs.first?.id, jobID)
        credentials.release()
        await model.waitForCredentialLoading()
    }

    private func makeLegacyLedger(_ paths: ApplicationPaths) throws -> Data {
        try paths.createDirectories()
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "fixture", outputLocationMode: .fixedDirectory,
            outputDirectory: paths.root.path, keepRawTranscript: false)
        let job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
        try JSONRepository<JobLedgerCollection>(url: paths.jobLedger).save(.init(jobs: [job]))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.jobLedger)) as? [String: Any])
        var records = try XCTUnwrap(document["jobs"] as? [[String: Any]])
        var legacySnapshot = try XCTUnwrap(records[0]["snapshot"] as? [String: Any])
        legacySnapshot["googleAIStudioAPIKey"] = "fixture-legacy-secret"
        records[0]["snapshot"] = legacySnapshot
        document["jobs"] = records
        let data = try JSONSerialization.data(withJSONObject: document)
        try data.write(to: paths.jobLedger)
        return data
    }
}

private final class TerminationCredentialStore: GoogleAIStudioCredentialStoring, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var key: String?
    var storedKey: String? { lock.withLock { key } }
    func release() { gate.signal() }
    func loadAPIKey() throws -> String? {
        gate.wait()
        return storedKey
    }
    func saveAPIKey(_ apiKey: String?) throws { lock.withLock { key = apiKey } }
}
