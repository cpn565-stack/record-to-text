import AppKit
import SwiftUI
import XCTest
@testable import RecordToTextApp
@testable import RecordToTextCore

private struct RedesignTestCredentialStore: GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ apiKey: String?) throws {}
}

@MainActor
final class MainWindowRedesignTests: XCTestCase {
    func testJobModelDisplayHelperMapsFriendlyNamesAndFallbacksWithoutMutatingCore() {
        let vertexSnapshot = JobSnapshot(
            modelID: "unused",
            glossaryID: nil,
            glossaryName: "半導體",
            terms: [],
            prompt: "",
            outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp",
            keepRawTranscript: false,
            backendType: .vertexAI,
            vertexAIModelID: "gemini-4-hydrogen"
        )
        let vertexJob = TranscriptionJob(sourcePath: "/tmp/a.m4a", snapshot: vertexSnapshot, stage: .completed)
        XCTAssertEqual(JobModelDisplayHelper.displayModelLabel(for: vertexJob), "Gemini 4 Hydrogen")
        XCTAssertEqual(JobModelDisplayHelper.displayBackendAndModel(for: vertexJob), "Vertex AI · Gemini 4 Hydrogen")
        XCTAssertNil(JobModelDisplayHelper.fallbackTooltip(for: vertexJob))

        let fallbackSnapshot = JobSnapshot(
            modelID: "unused",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "",
            outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp",
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioModelID: "gemini-3.8-flash"
        )
        let fallbackMeta = CloudTranscriptionMetadata(
            requestedModelID: "gemini-3.8-flash",
            effectiveModelID: "gemini-3.6-flash",
            fallbackReason: "503"
        )
        let fallbackJob = TranscriptionJob(
            sourcePath: "/tmp/b.m4a",
            snapshot: fallbackSnapshot,
            stage: .completed,
            cloudSegmentMetadata: [fallbackMeta]
        )
        XCTAssertEqual(JobModelDisplayHelper.displayModelLabel(for: fallbackJob), "Gemini 3.8 Flash → 3.6 Flash")
        XCTAssertEqual(JobModelDisplayHelper.fallbackTooltip(for: fallbackJob), "要求：gemini-3.8-flash；實際：gemini-3.6-flash")
        // Core debug clipboard keeps raw technical model summary intact.
        XCTAssertTrue(JobDebugClipboard.dump(fallbackJob).contains("要求：gemini-3.8-flash；實際：gemini-3.6-flash"))

        let recentFallback = RecentJobSummary(job: fallbackJob)
        XCTAssertEqual(JobModelDisplayHelper.displayModelLabel(for: recentFallback), "Gemini 3.8 Flash → 3.6 Flash")
        XCTAssertEqual(JobModelDisplayHelper.displayBackendAndModel(for: recentFallback), "AI Studio · Gemini 3.8 Flash → 3.6 Flash")

        let localSnapshot = JobSnapshot(
            modelID: ASRModelDescriptor.appleSiliconBF16.id,
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "",
            outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp",
            keepRawTranscript: false,
            backendType: .localQwen
        )
        let localJob = TranscriptionJob(sourcePath: "/tmp/c.m4a", snapshot: localSnapshot, stage: .queued)
        XCTAssertEqual(JobModelDisplayHelper.displayBackendAndModel(for: localJob), "本機 Qwen · Qwen3-ASR 1.7B BF16")

        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            JobModelDisplayHelper.formattedDuration(startedAt: start, completedAt: start.addingTimeInterval(351)),
            "5分51秒"
        )
        XCTAssertEqual(
            JobModelDisplayHelper.formattedDuration(startedAt: start, completedAt: start.addingTimeInterval(42)),
            "42秒"
        )
    }

    func testPendingWorkCountAndQueueActionBarVisibilityTrackLifecycle() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let model = AppViewModel(paths: paths, credentialStore: RedesignTestCredentialStore())
        await model.waitForCredentialLoading()

        XCTAssertEqual(model.pendingWorkCount, 0)
        XCTAssertFalse(QueueActionBar.shouldShow(for: model))

        model.addFiles([
            root.appendingPathComponent("part1.m4a"),
            root.appendingPathComponent("part2.m4a")
        ])
        XCTAssertEqual(model.queuedJobCount, 2)
        XCTAssertEqual(model.pendingWorkCount, 2)
        XCTAssertTrue(QueueActionBar.shouldShow(for: model))

        let firstID = try XCTUnwrap(model.jobs.first?.id)
        model.removeQueuedJob(firstID)
        XCTAssertEqual(model.pendingWorkCount, 1)

        await model.stopAllForTermination()
        XCTAssertEqual(model.pendingWorkCount, 0)
        XCTAssertFalse(QueueActionBar.shouldShow(for: model))
    }

    func testMainViewRendersAllFourCoreStatesAtMinimumAndDefaultWindowSizes() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))

        let snapshot = JobSnapshot(
            modelID: ASRModelDescriptor.appleSiliconBF16.id,
            glossaryID: nil,
            glossaryName: "訪談詞庫",
            terms: ["CoWoS"],
            prompt: "CoWoS",
            outputLocationMode: .fixedDirectory,
            outputDirectory: root.path,
            keepRawTranscript: false,
            backendType: .vertexAI,
            vertexAIModelID: "gemini-4-hydrogen"
        )

        var active = TranscriptionJob(
            sourcePath: root.appendingPathComponent("active.m4a").path,
            snapshot: snapshot,
            stage: .transcribing
        )
        active.startedAt = Date().addingTimeInterval(-95)
        active.progressUnit = "waiting|2|4"
        active.logLines = ["正在由 gemini-4-hydrogen 第 2/4 段 忠實轉錄。"]

        let queued = TranscriptionJob(
            sourcePath: root.appendingPathComponent("queued.m4a").path,
            snapshot: snapshot,
            stage: .queued
        )

        var failed = TranscriptionJob(
            sourcePath: root.appendingPathComponent("failed.m4a").path,
            snapshot: snapshot,
            stage: .failed
        )
        failed.failure = JobFailure(
            stage: .transcribing,
            userMessage: "雲端連線中斷，已保留可續跑檢查點。",
            technicalDetails: "fixture",
            recoverable: true,
            recoveryDirectory: root.path
        )

        let recentItems: [RecentJobSummary] = (0..<7).map { (index: Int) -> RecentJobSummary in
            let startOffset = TimeInterval(-600 - index * 60)
            let endOffset = TimeInterval(-300 - index * 60)
            let glossary: String? = index == 0 ? "訪談詞庫" : nil
            let completeness: OutputCompleteness = index == 1 ? .hasGaps : .complete
            let gapReason: String? = index == 1 ? "第 2 段因安全政策略過。" : nil
            return RecentJobSummary(
                id: UUID(),
                sourcePath: root.appendingPathComponent("done-\(index).m4a").path,
                outputPath: root.appendingPathComponent("done-\(index).txt").path,
                stage: .completed,
                startedAt: Date().addingTimeInterval(startOffset),
                completedAt: Date().addingTimeInterval(endOffset),
                modelID: "gemini-4-hydrogen",
                glossaryName: glossary,
                backendType: .vertexAI,
                outputCompleteness: completeness,
                outputGapReason: gapReason
            )
        }

        try JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs)
            .write(.init(revision: 1, jobs: [active, queued, failed], recentJobs: recentItems, recentHistoryLimit: 20))

        let model = AppViewModel(paths: paths, credentialStore: RedesignTestCredentialStore())
        await model.waitForCredentialLoading()
        model.selectQuickTranscriptionChoice(.vertexGemini35Transcribe)

        for size in [NSSize(width: 760, height: 680), NSSize(width: 900, height: 780)] {
            let hosting = NSHostingView(rootView: MainView(viewModel: model))
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        }

        await model.stopAllForTermination()
    }
}
