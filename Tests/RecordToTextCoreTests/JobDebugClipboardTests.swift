import SwiftUI
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

    func testBudgetDebugLinesStayHiddenInCollapsedSummaryWhileRetryReasonsRemainVisible() {
        let retryLine = "雲端生成第 1／4 次未完成（Google 串流回應未完整結束，incompleteStream），約 20 秒後重試。"
        let lines = [
            "開始處理。",
            "budget created root=ABC limit=1800.0 resumed=false；續跑重新計時。",
            "正在由 gemini-4-hydrogen 第 1/4 段 忠實轉錄。",
            "budget root=ABC model=gemini-4-hydrogen attempt=1 elapsed=2.9 remaining=1797.1",
            retryLine,
            "轉錄請求送出 maxOutputTokens=65536，thinkingConfig=high（模型 gemini-4-hydrogen）。"
        ]
        XCTAssertEqual(
            JobDebugClipboard.statusSummary(from: lines),
            "正在由 gemini-4-hydrogen 第 1/4 段 忠實轉錄。\n\(retryLine)"
        )

        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory, outputDirectory: "/tmp",
            keepRawTranscript: false)
        var job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
        job.logLines = lines
        let expanded = JobDebugClipboard.expandedContent(for: job)
        XCTAssertTrue(expanded.contains("budget created root=ABC"))
        XCTAssertTrue(expanded.contains("budget root=ABC"))
        XCTAssertTrue(expanded.contains(retryLine))
        XCTAssertTrue(JobDebugClipboard.dump(job).contains("budget root=ABC"))
    }

    func testExpandableLogAndRecentDiagnosticsHelpersAndStatePersistence() throws {
        XCTAssertEqual(JobDebugClipboard.logToggleTitle(isExpanded: false, lineCount: 12, hasDiagnostics: false), "展開日誌（12）")
        XCTAssertEqual(JobDebugClipboard.logToggleTitle(isExpanded: true, lineCount: 12, hasDiagnostics: true), "收合日誌")
        XCTAssertEqual(JobDebugClipboard.logToggleTitle(isExpanded: false, lineCount: 0, hasDiagnostics: true), "展開診斷")
        XCTAssertEqual(JobDebugClipboard.logToggleTitle(isExpanded: true, lineCount: 0, hasDiagnostics: true), "收合診斷")
        XCTAssertEqual(JobDebugClipboard.recentDiagnosticsToggleTitle(isExpanded: false), "展開診斷")
        XCTAssertEqual(JobDebugClipboard.recentDiagnosticsToggleTitle(isExpanded: true), "收合診斷")

        let diagnostics = CloudJobDiagnostics(
            audioDurationSeconds: 20,
            segments: [.init(startSeconds: 0, endSeconds: 20, outcome: .completed, preparationSeconds: 0.5, cloudSeconds: 4.2)],
            postprocessingSeconds: 0.1
        )
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory, outputDirectory: "/tmp",
            keepRawTranscript: false)
        var job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot, stage: .completed)
        job.logLines = ["開始處理。", "完成，耗時 00:05。"]
        job.cloudDiagnostics = diagnostics

        let expandedJob = JobDebugClipboard.expandedContent(for: job)
        XCTAssertTrue(expandedJob.contains("開始處理。\n完成，耗時 00:05。"))
        XCTAssertTrue(expandedJob.contains("--- 分段診斷 ---"))
        XCTAssertTrue(expandedJob.contains("[00:00 - 00:20]"))

        let recentWithDiag = RecentJobSummary(job: job)
        XCTAssertEqual(JobDebugClipboard.expandedContent(for: recentWithDiag), diagnostics.debugSummary)
        let recentWithoutDiag = RecentJobSummary(
            id: UUID(), sourcePath: "/fixture.wav", outputPath: "/out.txt",
            stage: .completed, startedAt: nil, completedAt: nil, modelID: "fixture", glossaryName: nil
        )
        XCTAssertNil(JobDebugClipboard.expandedContent(for: recentWithoutDiag))

        var expansion = JobLogExpansionState()
        XCTAssertFalse(expansion.isExpanded(job.id))
        expansion.toggle(job.id)
        XCTAssertTrue(expansion.isExpanded(job.id))
        // Appending more log lines / mutating job must not collapse parent-owned state.
        job.logLines.append("第 2/4 段 正在接收 Google 回應（已耗時 30 秒）。")
        XCTAssertTrue(expansion.isExpanded(job.id))
        expansion.prune(retaining: [job.id])
        XCTAssertTrue(expansion.isExpanded(job.id))
        expansion.prune(retaining: [])
        XCTAssertFalse(expansion.isExpanded(job.id))
    }

    func testLedgerRetentionTrimmingPreservesDiagnosticsAndLatestLogLines() {
        let diagnostics = CloudJobDiagnostics(
            audioDurationSeconds: 10,
            segments: [.init(startSeconds: 0, endSeconds: 10, outcome: .failed)],
            postprocessingSeconds: 0
        )
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory, outputDirectory: "/tmp",
            keepRawTranscript: false)
        var failed = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot, stage: .failed)
        failed.logLines = (0..<420).map { "line-\($0)" }
        failed.cloudDiagnostics = diagnostics
        let retained = JobRetentionPolicy.ledgerJobs([failed], terminalHistoryLimit: 5)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained[0].logLines.count, 100)
        XCTAssertEqual(retained[0].logLines.first, "line-320")
        XCTAssertEqual(retained[0].cloudDiagnostics, diagnostics)
    }

    func testMainViewRendersWithExpandableJobAndRecentDiagnostics() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let diagnostics = CloudJobDiagnostics(
            audioDurationSeconds: 20,
            segments: [.init(startSeconds: 0, endSeconds: 20, outcome: .completed, preparationSeconds: 0.4, cloudSeconds: 3.2)],
            postprocessingSeconds: 0.1
        )
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory, outputDirectory: root.path,
            keepRawTranscript: false, backendType: .vertexAI, vertexAIModelID: "gemini-4-hydrogen")
        var job = TranscriptionJob(sourcePath: root.appendingPathComponent("live.mp3").path, snapshot: snapshot, stage: .transcribing)
        job.logLines = ["開始處理。", "雲端生成第 1／4 次未完成（Google 串流回應未完整結束，incompleteStream），約 20 秒後重試。"]
        job.cloudDiagnostics = diagnostics
        let recent = RecentJobSummary(
            id: UUID(),
            sourcePath: root.appendingPathComponent("recent.mp3").path,
            outputPath: root.appendingPathComponent("recent.txt").path,
            stage: .completed,
            startedAt: Date().addingTimeInterval(-60),
            completedAt: Date(),
            modelID: "gemini-4-hydrogen",
            glossaryName: nil,
            backendType: .vertexAI,
            cloudDiagnostics: diagnostics
        )
        try JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs)
            .write(.init(revision: 1, jobs: [job], recentJobs: [recent], recentHistoryLimit: 10))
        let model = AppViewModel(paths: paths, credentialStore: EmptyClipboardTestCredentialStore())
        await model.waitForCredentialLoading()
        let view = MainView(viewModel: model)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        await model.stopAllForTermination()
    }
}

private struct EmptyClipboardTestCredentialStore: GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ apiKey: String?) throws {}
}
