import XCTest
@testable import RecordToTextApp
@testable import RecordToTextCore

@MainActor
final class JobDebugClipboardTests: XCTestCase {
    func testReasonsAndRetryCostNoteSurviveJobAndRecentHistoryRoundTrip() throws {
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
        let collector = CloudDiagnosticCollector(history: history)
        collector.requestStarted(stage: .generation, responseMode: .unaryJSON)
        collector.recordGenerationResponse(finishReason: "STOP", promptBlockReason: nil)
        collector.failure(GoogleAIStudioError.emptyCompletedResponse, stage: .generation)
        collector.retry(.emptyResponse)
        collector.requestStarted(stage: .generation, responseMode: .unaryJSON)
        collector.recordGenerationResponse(finishReason: nil, promptBlockReason: "OTHER")
        collector.failure(GoogleAIStudioError.promptBlocked(.init(httpStatusCode: 200, blockReason: "OTHER")), stage: .generation)
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory, outputDirectory: "/tmp",
            keepRawTranscript: false, backendType: .googleAIStudio)
        var job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot, stage: .failed)
        job.cloudDiagnostics = CloudJobDiagnostics(audioDurationSeconds: 10,
            segments: [collector.snapshot(start: 0, end: 10, outcome: .failed, preparation: 0, cloud: 2)],
            postprocessingSeconds: 0, failureHistory: history.snapshot())
        let restored = try JSONDecoder().decode(TranscriptionJob.self, from: JSONEncoder().encode(job))
        let recent = try JSONDecoder().decode(RecentJobSummary.self, from: JSONEncoder().encode(RecentJobSummary(job: restored)))
        for dump in [JobDebugClipboard.dump(restored), JobDebugClipboard.dump(recent)] {
            XCTAssertTrue(dump.contains("finishReason=STOP"))
            XCTAssertTrue(dump.contains("promptBlockReason=OTHER"))
            XCTAssertTrue(dump.contains("App 生成發送=2"))
            XCTAssertTrue(dump.contains("費用為估算，失敗或重試請求可能未完整列入。"))
        }
    }

    func testCopiedStatusDistinguishesCompleteOutputFromSafetyGaps() {
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp", keepRawTranscript: false)
        var job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot, stage: .completed)
        job.outputCompleteness = .hasGaps
        XCTAssertTrue(JobDebugClipboard.dump(job).contains("狀態：完成（含缺口）\n"))
        XCTAssertTrue(JobDebugClipboard.dump(RecentJobSummary(job: job)).contains("狀態：完成（含缺口）\n"))

        job.outputCompleteness = .complete
        XCTAssertTrue(JobDebugClipboard.dump(job).contains("狀態：完成\n"))
        XCTAssertTrue(JobDebugClipboard.dump(RecentJobSummary(job: job)).contains("狀態：完成\n"))

        job.stage = .failed
        job.outputCompleteness = .hasGaps
        XCTAssertTrue(JobDebugClipboard.dump(job).contains("狀態：失敗\n"))
        XCTAssertTrue(JobDebugClipboard.dump(RecentJobSummary(job: job)).contains("狀態：失敗\n"))
    }

    func testRecentDiagnosticCopyIsAvailableWithoutLogOrPrivateContent() {
        let diagnostics = CloudJobDiagnostics(audioDurationSeconds: 10,
            segments: [.init(startSeconds: 0, endSeconds: 10, outcome: .completed,
                timestampReview: .init(disposition: .segmentRangeOnly, issues: [.missingIntervals]))],
            postprocessingSeconds: 0.1)
        let summary = RecentJobSummary(id: UUID(), sourcePath: "/PRIVATE/source.wav", outputPath: "/PRIVATE/out.txt",
            stage: .completed, startedAt: nil, completedAt: nil, modelID: "fixture", glossaryName: "PRIVATE-GLOSSARY",
            cloudDiagnostics: diagnostics)
        let dump = JobDebugClipboard.dump(summary)
        XCTAssertTrue(dump.contains("[00:00 - 00:10]"))
        XCTAssertTrue(dump.contains("segmentRangeOnly"))
        XCTAssertFalse(dump.contains("PRIVATE"))
    }

    func testSummaryKeepsNewestHumanMessagesInChronologicalOrder() {
        XCTAssertEqual(JobDebugClipboard.statusSummary(from: [
            "舊訊息", "正在準備", "HTTP 200", "", "正在轉錄", "responseId=fixture"
        ]), "正在準備\n正在轉錄")
        XCTAssertNil(JobDebugClipboard.statusSummary(from: ["  ", "HTTP 200"]))
    }

    func testLongSummaryIsBoundedWithoutTruncatingCopiedDiagnostics() {
        let longLine = String(repeating: "長訊息👨‍👩‍👧‍👦", count: 500)
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp", keepRawTranscript: false)
        var job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
        job.logLines = ["開始", longLine]
        XCTAssertEqual(JobDebugClipboard.statusSummary(from: job.logLines),
            "開始\n" + String(longLine.prefix(240)) + "…")
        XCTAssertTrue(JobDebugClipboard.dump(job).hasSuffix("開始\n" + longLine))
        XCTAssertEqual(JobDebugClipboard.statusSummary(from: [String(repeating: "字", count: 240)]),
            String(repeating: "字", count: 240))
    }
}
