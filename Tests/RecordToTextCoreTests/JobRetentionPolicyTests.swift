import XCTest
@testable import RecordToTextCore

final class JobRetentionPolicyTests: XCTestCase {
    func testLimitZeroStillRetainsQueuedActiveAndInterruptedJobs() {
        let queued = makeJob(index: 1, stage: .queued)
        let active = makeJob(index: 2, stage: .transcribing)
        let interrupted = makeJob(index: 3, stage: .interrupted)
        let failed = makeJob(index: 4, stage: .failed)
        let cancelled = makeJob(index: 5, stage: .cancelled)
        let completed = makeJob(index: 6, stage: .completed)

        let retained = JobRetentionPolicy.ledgerJobs(
            [queued, active, interrupted, failed, cancelled, completed],
            terminalHistoryLimit: 0
        )

        XCTAssertEqual(
            retained.map(\.id),
            [queued.id, active.id, interrupted.id]
        )
    }

    func testQueueLongerThanHistoryLimitIsNeverTruncated() {
        let queued = (0..<12).map { makeJob(index: $0, stage: .queued) }
        let failed = (20..<24).map { makeJob(index: $0, stage: .failed) }

        let retained = JobRetentionPolicy.ledgerJobs(
            queued + failed,
            terminalHistoryLimit: 2
        )

        XCTAssertEqual(
            Array(retained.prefix(queued.count)).map(\.id),
            queued.map(\.id)
        )
        XCTAssertEqual(
            Array(retained.suffix(2)).map(\.id),
            Array(failed.suffix(2)).map(\.id)
        )
    }

    func testLedgerRetainsNewestRetryableTerminalHistoryOnly() {
        let newest = makeJob(index: 30, stage: .failed)
        let oldest = makeJob(index: 10, stage: .failed)
        let middle = makeJob(index: 20, stage: .cancelled)

        let retained = JobRetentionPolicy.ledgerJobs(
            [newest, oldest, middle],
            terminalHistoryLimit: 2
        )

        XCTAssertEqual(retained.map(\.id), [newest.id, middle.id])
    }

    func testLedgerAlwaysExcludesCompletedJobs() {
        let completed = (0..<3).map {
            makeJob(index: $0, stage: .completed)
        }

        XCTAssertTrue(
            JobRetentionPolicy.ledgerJobs(
                completed,
                terminalHistoryLimit: 100
            ).isEmpty
        )
    }

    func testLedgerCapsLogsWithoutMutatingInputJobs() {
        var queued = makeJob(index: 1, stage: .queued)
        queued.logLines = (0..<150).map { "line-\($0)" }

        let retained = JobRetentionPolicy.ledgerJobs(
            [queued],
            terminalHistoryLimit: 0,
            maximumLogLines: 100
        )

        XCTAssertEqual(retained[0].logLines.count, 100)
        XCTAssertEqual(retained[0].logLines.first, "line-50")
        XCTAssertEqual(queued.logLines.count, 150)
    }

    func testInMemoryPruningKeepsDurableJobsAtLimitZero() {
        let queued = makeJob(index: 1, stage: .queued)
        let active = makeJob(index: 2, stage: .loadingModel)
        let interrupted = makeJob(index: 3, stage: .interrupted)
        let failed = makeJob(index: 4, stage: .failed)
        let completed = makeJob(index: 5, stage: .completed)

        let retained = JobRetentionPolicy.inMemoryJobs(
            [queued, active, interrupted, failed, completed],
            terminalHistoryLimit: 0
        )

        XCTAssertEqual(
            retained.map(\.id),
            [queued.id, active.id, interrupted.id]
        )
    }

    func testRecentSummariesRespectZeroAndNewestLimit() {
        let summaries = (0..<4).map { index in
            RecentJobSummary(
                job: makeJob(index: index, stage: .completed)
            )
        }

        XCTAssertTrue(
            JobRetentionPolicy.recentSummaries(
                summaries,
                limit: 0
            ).isEmpty
        )
        XCTAssertEqual(
            JobRetentionPolicy.recentSummaries(
                Array(summaries.reversed()),
                limit: 2
            ).map(\.id),
            Array(summaries.suffix(2)).map(\.id)
        )
    }

    func testQueuedJobsRoundTripWhenRecentLimitIsZero() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONRepository<JobLedgerCollection>(
            url: directory.appendingPathComponent("job-ledger.json")
        )
        let queued = (0..<15).map { makeJob(index: $0, stage: .queued) }
        let ledger = JobRetentionPolicy.ledgerJobs(
            queued,
            terminalHistoryLimit: 0
        )

        try repository.save(JobLedgerCollection(jobs: ledger))
        let restored = try repository.load(default: JobLedgerCollection())

        XCTAssertEqual(restored.jobs.map(\.id), queued.map(\.id))
        XCTAssertTrue(restored.jobs.allSatisfy { $0.stage == .queued })
    }

    private func makeJob(
        index: Int,
        stage: TranscriptionStage
    ) -> TranscriptionJob {
        let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
        let snapshot = JobSnapshot(
            modelID: "mock/model",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "忠實轉錄",
            outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp/output",
            keepRawTranscript: false
        )
        var job = TranscriptionJob(
            sourcePath: "/tmp/audio-\(index).m4a",
            snapshot: snapshot,
            stage: stage,
            createdAt: date
        )
        if stage != .queued {
            job.startedAt = date
        }
        if stage.isTerminal {
            job.completedAt = date
        }
        return job
    }
}
