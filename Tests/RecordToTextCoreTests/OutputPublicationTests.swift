import XCTest
@testable import RecordToTextCore

final class OutputPublicationTests: XCTestCase {
    func testOnlyPublishedMatchingOutputCanRecoverKnownJob() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: [], prompt: "fixture", outputLocationMode: .fixedDirectory, outputDirectory: root.path, keepRawTranscript: false)
        let job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
        let output = root.appendingPathComponent("final.txt")
        let result = PipelineResult(outputURL: output, rawOutputURL: nil, duration: 1)
        let store = OutputPublicationStore(paths: paths)
        try store.prepare(job: job, result: result, text: "完整稿\r\n")
        XCTAssertNil(try store.recover(job: job))
        try AtomicFileWriter.writeTextNew("完整稿\r\n", to: output)
        XCTAssertEqual(try store.recover(job: job)?.outputPath, output.path)
        XCTAssertEqual(try store.recover(job: job)?.stage, .completed)
        let other = TranscriptionJob(id: job.id, sourcePath: "/other.wav", snapshot: snapshot)
        XCTAssertNil(try store.recover(job: other))
        try AtomicFileWriter.writeText("不相符", to: output)
        XCTAssertNil(try store.recover(job: job))
    }

    func testProcessCrashAcrossPublicationJournalAndCleanup() throws {
        for stage in ["beforePublish", "afterPublish", "beforeJournal", "afterJournal", "beforeCleanup", "afterCleanup"] {
            let root = try TestSupport.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ApplicationPaths(root: root)
            let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: [], prompt: "fixture", outputLocationMode: .fixedDirectory, outputDirectory: root.path, keepRawTranscript: false)
            let job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
            let store = JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs)
            try store.write(.init(revision: 1, jobs: [job], recentJobs: [], recentHistoryLimit: 10))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/record-to-text-self-test")
            process.arguments = ["--publication-crash-fixture", root.path, stage]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 73, stage)
            let recovered = try XCTUnwrap(store.recover())
            let jobs = try OutputPublicationStore(paths: paths).recoverKnownJobs(recovered.jobs)
            let completed = jobs.filter { $0.stage == .completed }.map(RecentJobSummary.init(job:)) + recovered.recentJobs.filter { $0.stage == .completed }
            XCTAssertEqual(completed.count, stage == "beforePublish" ? 0 : 1, stage)
            if let saved = completed.first {
                XCTAssertEqual(saved.outputPath, root.appendingPathComponent("final.txt").path)
            }
        }
    }

    func testDeletedJobIsNotReintroducedByOldReceipt() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: [], prompt: "fixture", outputLocationMode: .fixedDirectory, outputDirectory: root.path, keepRawTranscript: false)
        let job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
        let output = root.appendingPathComponent("final.txt")
        let store = OutputPublicationStore(paths: paths)
        try store.prepare(job: job, result: .init(outputURL: output, rawOutputURL: nil, duration: 1), text: "完成")
        try AtomicFileWriter.writeTextNew("完成", to: output)
        XCTAssertEqual(try store.recoverKnownJobs([]).count, 0)
        XCTAssertEqual(try store.recoverKnownJobs([job]).first?.stage, .completed)
    }
}
