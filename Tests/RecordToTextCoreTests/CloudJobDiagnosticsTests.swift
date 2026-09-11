import XCTest
@testable import RecordToTextCore

final class CloudJobDiagnosticsTests: XCTestCase {
    private func fixture() -> CloudJobDiagnostics {
        .init(audioDurationSeconds: 1200, segments: [.init(startSeconds: 0, endSeconds: 1200,
            outcome: .completed, preparationSeconds: 1.5, cloudSeconds: 60,
            stageTimings: [.init(stage: .generation, seconds: 50), .init(stage: .backoff, seconds: 8)],
            retryReasons: [.serverError], timestampReview: .init(disposition: .segmentRangeOnly, issues: [.missingIntervals]))],
            postprocessingSeconds: 0.2)
    }

    func testJournalAndPublicationRecoveryKeepSanitizedDiagnostics() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: ["PRIVATE-TERM"], prompt: "PRIVATE-PROMPT", outputLocationMode: .fixedDirectory,
            outputDirectory: root.path, keepRawTranscript: false)
        var job = TranscriptionJob(sourcePath: root.appendingPathComponent("source.wav").path, snapshot: snapshot)
        job.logLines = ["PRIVATE-LOG https://example.test/secret-key"]
        let output = root.appendingPathComponent("final.txt")
        let diagnostics = fixture()
        let result = PipelineResult(outputURL: output, rawOutputURL: nil, duration: 62,
                                    cloudDiagnostics: diagnostics)
        let publication = OutputPublicationStore(paths: paths)
        try publication.prepare(job: job, result: result, text: "PRIVATE-TRANSCRIPT")
        try AtomicFileWriter.writeTextNew("PRIVATE-TRANSCRIPT", to: output)
        let recovered = try XCTUnwrap(publication.recover(job: job))
        XCTAssertEqual(recovered.cloudDiagnostics, diagnostics)
        XCTAssertEqual(recovered.outputCompleteness, .complete)
        let store = JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs)
        try store.write(.init(revision: 1, jobs: [recovered], recentJobs: [], recentHistoryLimit: 10))
        let persisted = try XCTUnwrap(store.recover())
        XCTAssertTrue(persisted.jobs.isEmpty)
        XCTAssertEqual(persisted.recentJobs.first?.cloudDiagnostics, diagnostics)
        XCTAssertNotNil(persisted.recentJobs.first?.cloudDiagnostics?.timestampNotice)
        let recentJSON = try String(contentsOf: paths.recentJobs, encoding: .utf8)
        for secret in ["PRIVATE-TERM", "PRIVATE-PROMPT", "PRIVATE-LOG", "secret-key", "PRIVATE-TRANSCRIPT"] {
            XCTAssertFalse(recentJSON.contains(secret))
            XCTAssertFalse(diagnostics.debugSummary.contains(secret))
        }
        try store.write(.init(revision: 2, jobs: [], recentJobs: persisted.recentJobs, recentHistoryLimit: 0))
        XCTAssertEqual(try store.recover()?.recentJobs.count, 0)
    }

    func testLegacyResultAndSummaryDecodeWithoutDiagnostics() throws {
        let result = PipelineResult(outputURL: URL(fileURLWithPath: "/tmp/out.txt"), rawOutputURL: nil, duration: 1)
        let data = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("cloudDiagnostics"))
        XCTAssertNil(try JSONDecoder().decode(PipelineResult.self, from: data).cloudDiagnostics)
        let summary = RecentJobSummary(id: UUID(), sourcePath: "/tmp/in.wav", outputPath: "/tmp/out.txt",
            stage: .completed, startedAt: nil, completedAt: nil, modelID: "fixture", glossaryName: nil)
        XCTAssertNil(try JSONDecoder().decode(RecentJobSummary.self, from: JSONEncoder().encode(summary)).cloudDiagnostics)
    }

    func testTimedOperationsIncludeFailuresAndTaskLocalIsolation() async throws {
        let collector = CloudDiagnosticCollector()
        try await CloudDiagnosticContext.$current.withValue(collector) {
            try await CloudBudgetContext.perform(stage: "generation") { try await Task.sleep(for: .milliseconds(5)) }
            do {
                try await CloudBudgetContext.perform(stage: "upload") { throw URLError(.timedOut) }
                XCTFail("Expected failure")
            } catch { }
            CloudDiagnosticContext.current?.retry(.network)
            // Unknown stage strings (including anything sensitive) are discarded.
            try await CloudBudgetContext.perform(stage: "SECRET-STAGE") { }
        }
        XCTAssertNil(CloudDiagnosticContext.current)
        let result = collector.snapshot(start: 0, end: 10, outcome: .completed, preparation: 1, cloud: 2)
        XCTAssertEqual(result.stageTimings.map(\.stage), [.upload, .generation])
        XCTAssertGreaterThan(result.stageTimings.last!.seconds, 0)
        XCTAssertEqual(result.retryReasons, [.network])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("SECRET"))
    }
}
