import XCTest
@testable import RecordToTextApp
@testable import RecordToTextCore

@MainActor
final class JobDebugClipboardTests: XCTestCase {
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
