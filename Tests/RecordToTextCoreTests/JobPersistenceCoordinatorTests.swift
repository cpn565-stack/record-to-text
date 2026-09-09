import XCTest
@testable import RecordToTextCore

final class JobPersistenceCoordinatorTests: XCTestCase {
    func testCoalescingAndStaleSubmissions() async throws {
        let writer = RevisionRecorder()
        let coordinator = JobPersistenceCoordinator(writer: { snapshot in
            Thread.sleep(forTimeInterval: 0.02)
            writer.append(snapshot.revision)
        })
        for revision in 1...100 {
            await coordinator.submit(PersistenceSnapshot(revision: UInt64(revision), jobs: [], recentJobs: [], recentHistoryLimit: 10), urgency: .coalescible)
        }
        try await coordinator.flush(throughRevision: 100)
        await coordinator.submit(PersistenceSnapshot(revision: 1, jobs: [], recentJobs: [], recentHistoryLimit: 10), urgency: .critical)
        try await coordinator.flush(throughRevision: 100)
        XCTAssertEqual(writer.values.last, 100)
        XCTAssertLessThan(writer.values.count, 5)
    }

    @MainActor
    func testSlowWriterLeavesMainActorResponsiveAndCriticalWaits() async throws {
        let recorder = RevisionRecorder()
        let coordinator = JobPersistenceCoordinator(writer: { snapshot in
            Thread.sleep(forTimeInterval: 0.5)
            recorder.append(snapshot.revision)
        })
        let start = ContinuousClock.now
        await coordinator.submit(.init(revision: 1, jobs: [], recentJobs: [], recentHistoryLimit: 10), urgency: .critical)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(200))
        XCTAssertTrue(recorder.values.isEmpty, "Receipt cannot be durable yet")
        for revision in 2...100 {
            await coordinator.submit(.init(revision: UInt64(revision), jobs: [], recentJobs: [], recentHistoryLimit: 10), urgency: .coalescible)
        }
        try await coordinator.flush(throughRevision: 100)
        XCTAssertEqual(recorder.values, [1, 100])
    }

    func testCrashMatrixNeverResurrectsDeletedJob() throws {
        for crashPoint in ["beforeJournal", "journal-temporaryCreated", "journal-beforeRename", "afterJournal", "afterLedger", "afterRecent"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ledger = directory.appendingPathComponent("job-ledger.json")
            let recent = directory.appendingPathComponent("recent-jobs.json")
            let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: [], prompt: "fixture", outputLocationMode: .fixedDirectory, outputDirectory: directory.path, keepRawTranscript: false)
            let job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
            let store = JobPersistenceStore(ledgerURL: ledger, recentURL: recent)
            try store.write(.init(revision: 1, jobs: [job], recentJobs: [], recentHistoryLimit: 10))
            let executable = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug/record-to-text-self-test")
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--persistence-crash-fixture", directory.path, crashPoint]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 73)
            let recovered = try XCTUnwrap(store.recover())
            let expected: UInt64 = ["beforeJournal", "journal-temporaryCreated", "journal-beforeRename"].contains(crashPoint) ? 1 : 2
            XCTAssertEqual(recovered.revision, expected)
            XCTAssertEqual(recovered.jobs.count, expected == 1 ? 1 : 0)
            let ledgerValue = try JSONRepository<JobLedgerCollection>(url: ledger).load(default: .init())
            let recentValue = try JSONRepository<RecentJobCollection>(url: recent).load(default: .init())
            XCTAssertEqual(ledgerValue.revision, recentValue.revision)
            XCTAssertEqual(ledgerValue.revision, expected)
        }
    }

    func testPersistenceFixtureBenchmarks() async throws {
        for count in [10, 100, 1000] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: [], prompt: "fixture", outputLocationMode: .fixedDirectory, outputDirectory: directory.path, keepRawTranscript: false)
            let jobs = (0..<count).map { index in
                var job = TranscriptionJob(sourcePath: "/fixture-\(index).wav", snapshot: snapshot)
                job.logLines = (0..<400).map { "工作 \(index) 紀錄 \($0)：正在處理音訊；此為效能測試資料。" }
                return job
            }
            let store = JobPersistenceStore(ledgerURL: directory.appendingPathComponent("job-ledger.json"), recentURL: directory.appendingPathComponent("recent-jobs.json"))
            let coordinator = JobPersistenceCoordinator(writer: { try store.write($0) })
            for revision in 1...3 {
                let start = ContinuousClock.now
                let input = PersistenceSnapshot(revision: UInt64(revision), jobs: jobs, recentJobs: [], recentHistoryLimit: 1000)
                await coordinator.submit(input, urgency: .critical)
                let submit = start.duration(to: .now).secondsValue * 1000
                try await coordinator.flush(throughRevision: UInt64(revision))
                let total = start.duration(to: .now).secondsValue * 1000
                print("persistence_fixture jobs=\(count) logs=400 run=\(revision) submit_ms=\(submit) durable_ms=\(total)")
                XCTAssertLessThan(submit, 16)
            }
        }
    }

    func testFailedWriterRetainsLatestAndCanRetryWithoutTranscription() async throws {
        let recorder = RevisionRecorder()
        let coordinator = JobPersistenceCoordinator(writer: { snapshot in
            if recorder.values.isEmpty { recorder.append(0); throw CocoaError(.fileWriteOutOfSpace) }
            recorder.append(snapshot.revision)
        })
        await coordinator.submit(.init(revision: 1, jobs: [], recentJobs: [], recentHistoryLimit: 10), urgency: .critical)
        try await Task.sleep(for: .milliseconds(30))
        let failed = await coordinator.status
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(failed.lastDurableRevision, 0)
        await coordinator.submit(.init(revision: 2, jobs: [], recentJobs: [], recentHistoryLimit: 10), urgency: .critical)
        try await coordinator.flush(throughRevision: 2)
        XCTAssertEqual(recorder.values, [0, 2])
    }

    func testFlushTimeoutDoesNotPreventLaterSave() async throws {
        let recorder = RevisionRecorder()
        let coordinator = JobPersistenceCoordinator(writer: { snapshot in
            Thread.sleep(forTimeInterval: 0.3)
            recorder.append(snapshot.revision)
        })
        await coordinator.submit(.init(revision: 1, jobs: [], recentJobs: [], recentHistoryLimit: 10), urgency: .coalescible)
        do {
            try await CloudSegmentBudget(limit: .milliseconds(30)).withDeadline(stage: "persistence") {
                try await coordinator.flush(throughRevision: 1)
            }
            XCTFail("Slow writer did not time out")
        } catch let error as CloudSegmentDeadlineExceeded { XCTAssertEqual(error.stage, "persistence") }
        await coordinator.submit(.init(revision: 2, jobs: [], recentJobs: [], recentHistoryLimit: 10), urgency: .critical)
        try await coordinator.flush(throughRevision: 2)
        XCTAssertEqual(recorder.values.last, 2)
    }

    func testIndependentRepositoryFormattersUnderConcurrentLoad() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let repository = JSONRepository<PersistenceSnapshot>(url: root.appendingPathComponent("\(index).json"))
                    for revision in 1...20 {
                        let value = PersistenceSnapshot(revision: UInt64(revision), jobs: [], recentJobs: [], recentHistoryLimit: 10)
                        try repository.save(value)
                        let loaded = try repository.load(default: value)
                        XCTAssertEqual(loaded.revision, value.revision)
                        XCTAssertEqual(loaded.timestamp.timeIntervalSince1970, value.timestamp.timeIntervalSince1970, accuracy: 0.001)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    func testJournalRepairsBothOutputsAfterCrash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = directory.appendingPathComponent("job-ledger.json")
        let recent = directory.appendingPathComponent("recent-jobs.json")
        let store = JobPersistenceStore(ledgerURL: ledger, recentURL: recent)
        try store.write(PersistenceSnapshot(revision: 1, jobs: [], recentJobs: [], recentHistoryLimit: 10))
        try Data("broken".utf8).write(to: ledger)
        try Data("broken".utf8).write(to: recent)
        let recovered = try store.recover()
        XCTAssertEqual(recovered?.revision, 1)
        XCTAssertEqual(try JSONRepository<JobLedgerCollection>(url: ledger).load(default: .init()).revision, 1)
        XCTAssertEqual(try JSONRepository<RecentJobCollection>(url: recent).load(default: .init()).revision, 1)
    }
}

private final class RevisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []
    func append(_ value: UInt64) { lock.withLock { storage.append(value) } }
    var values: [UInt64] { lock.withLock { storage } }
}
