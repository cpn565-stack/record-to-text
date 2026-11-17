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
        model.selectQuickTranscriptionChoice(.vertexGemini4Hydrogen)

        for size in [NSSize(width: 760, height: 680), NSSize(width: 900, height: 780)] {
            let hosting = NSHostingView(rootView: MainView(viewModel: model))
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        }

        await model.stopAllForTermination()
    }

    func testOneClickUnsuccessfulCleanupRemovesFailedRecordsAndTempDirsWhileProtectingCompletedGapQueuedAndSources() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let isolatedSysTemp = root.appendingPathComponent("IsolatedSysTemp")
        try paths.createDirectories()
        try FileManager.default.createDirectory(at: isolatedSysTemp, withIntermediateDirectories: true)

        let sourceAudio = root.appendingPathComponent("interview.m4a")
        let sourceBytes = Data("original-audio-never-delete".utf8)
        try sourceBytes.write(to: sourceAudio)

        let completeOut = root.appendingPathComponent("complete.txt")
        let gapOut = root.appendingPathComponent("gap.txt")
        try Data("完整逐字稿".utf8).write(to: completeOut)
        try Data("含缺口逐字稿".utf8).write(to: gapOut)

        let snapshot = JobSnapshot(
            modelID: ASRModelDescriptor.appleSiliconBF16.id,
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "",
            outputLocationMode: .fixedDirectory,
            outputDirectory: root.path,
            keepRawTranscript: false,
            backendType: .vertexAI,
            vertexAIModelID: "gemini-4-hydrogen"
        )

        // 1. Queued job (must stay + its temp dir must stay)
        let queuedJob = TranscriptionJob(sourcePath: sourceAudio.path, snapshot: snapshot, stage: .queued)
        let queuedTempDir = isolatedSysTemp.appendingPathComponent(queuedJob.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: queuedTempDir, withIntermediateDirectories: true)
        try Data("active-wav".utf8).write(to: queuedTempDir.appendingPathComponent("normalized.wav"))

        // 2. Seamless completed job (must stay + output must stay)
        var completedJob = TranscriptionJob(sourcePath: sourceAudio.path, snapshot: snapshot, stage: .completed)
        completedJob.outputPath = completeOut.path
        completedJob.outputCompleteness = .complete

        // 3. Completed with gaps job (must stay + output must stay + its Temp-Recovery dir must stay!)
        var gapCompletedJob = TranscriptionJob(sourcePath: sourceAudio.path, snapshot: snapshot, stage: .completed)
        gapCompletedJob.outputPath = gapOut.path
        gapCompletedJob.outputCompleteness = .hasGaps
        let gapRecoveryDir = paths.tempRecovery.appendingPathComponent(gapCompletedJob.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: gapRecoveryDir, withIntermediateDirectories: true)
        try Data("gap-partial".utf8).write(to: gapRecoveryDir.appendingPathComponent(RecoveryScanner.partialTranscriptFileName))
        gapCompletedJob.failure = JobFailure(
            stage: .completed,
            userMessage: "第 2 段略過",
            technicalDetails: "gap",
            recoverable: true,
            recoveryDirectory: gapRecoveryDir.path
        )

        // 4. Failed job + recoverable Temp-Recovery dir (both must be deleted)
        var failedJob = TranscriptionJob(sourcePath: sourceAudio.path, snapshot: snapshot, stage: .failed)
        let failedRecoveryDir = paths.tempRecovery.appendingPathComponent(failedJob.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: failedRecoveryDir, withIntermediateDirectories: true)
        let failedMeta = RecoveryScanner.RecoveryMetadata(
            schemaVersion: 2,
            jobID: failedJob.id,
            sourcePath: sourceAudio.path,
            failureStage: "transcribing",
            createdAt: Date(),
            technicalError: "timeout",
            recoveryKind: "cloudCheckpoint",
            backendType: .vertexAI,
            partialTranscriptFile: RecoveryScanner.partialTranscriptFileName
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(failedMeta).write(to: failedRecoveryDir.appendingPathComponent(RecoveryScanner.recoveryJSONFileName))
        try Data("partial-text".utf8).write(to: failedRecoveryDir.appendingPathComponent(RecoveryScanner.partialTranscriptFileName))
        failedJob.failure = JobFailure(
            stage: .transcribing,
            userMessage: "逾時失敗",
            technicalDetails: "timeout",
            recoverable: true,
            recoveryDirectory: failedRecoveryDir.path,
            partialTranscriptPath: failedRecoveryDir.appendingPathComponent(RecoveryScanner.partialTranscriptFileName).path
        )

        // 5. Cancelled & Interrupted jobs + orphaned systemTemp dir (all must be deleted)
        let cancelledJob = TranscriptionJob(sourcePath: sourceAudio.path, snapshot: snapshot, stage: .cancelled)
        var pausedInterruptedJob = TranscriptionJob(sourcePath: sourceAudio.path, snapshot: snapshot, stage: .interrupted)
        pausedInterruptedJob.serviceRecovery = {
            var r = CloudServiceRecovery()
            r.state = .paused
            return r
        }()

        let orphanUUID = UUID()
        let orphanTempDir = isolatedSysTemp.appendingPathComponent(orphanUUID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphanTempDir, withIntermediateDirectories: true)
        try Data("orphan-wav".utf8).write(to: orphanTempDir.appendingPathComponent("normalized.wav"))

        let archivedCancelledID = UUID()
        let archivedCompletedID = UUID()
        let recentSummaries: [RecentJobSummary] = [
            RecentJobSummary(job: completedJob),
            RecentJobSummary(job: gapCompletedJob),
            RecentJobSummary(job: failedJob),
            RecentJobSummary(
                id: archivedCancelledID,
                sourcePath: sourceAudio.path,
                outputPath: nil,
                stage: .cancelled,
                startedAt: nil,
                completedAt: Date(),
                modelID: "gemini-4-hydrogen",
                glossaryName: nil,
                backendType: .vertexAI
            ),
            RecentJobSummary(
                id: archivedCompletedID,
                sourcePath: sourceAudio.path,
                outputPath: completeOut.path,
                stage: .completed,
                startedAt: Date(),
                completedAt: Date(),
                modelID: "gemini-4-hydrogen",
                glossaryName: nil,
                backendType: .vertexAI,
                outputCompleteness: .complete
            )
        ]

        try JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs).write(
            .init(
                revision: 1,
                jobs: [queuedJob, completedJob, gapCompletedJob, failedJob, cancelledJob, pausedInterruptedJob],
                recentJobs: recentSummaries,
                recentHistoryLimit: 20
            )
        )

        let model = AppViewModel(
            paths: paths,
            systemTempRoot: isolatedSysTemp,
            credentialStore: RedesignTestCredentialStore()
        )
        await model.waitForCredentialLoading()
        model.setSetting(\.showNotificationWhenCompleted, to: false)
        model.setSetting(\.revealInFinderWhenCompleted, to: false)
        model.setSetting(\.openTextWhenCompleted, to: false)
        let liveAudio = root.appendingPathComponent("live-session.m4a")
        try sourceBytes.write(to: liveAudio)
        model.addFiles([liveAudio])
        let liveCompletedID = try XCTUnwrap(model.jobs.last?.id)
        let accepted = await model.acceptCompletedResult(
            PipelineResult(outputURL: completeOut, rawOutputURL: nil, duration: 2),
            id: liveCompletedID
        )
        XCTAssertTrue(accepted)
        try await TestSupport.eventually { !model.isRecoveryScanRunning && model.recoveryScanReport != nil }

        // 4 unsuccessful records: failedJob, cancelledJob, pausedInterruptedJob, archivedCancelledID
        XCTAssertEqual(model.unsuccessfulJobCount, 4)
        // 2 unprotected directories: failedRecoveryDir (recoverable) + orphanTempDir (orphaned)
        XCTAssertEqual(model.cleanableRecoveryItemCount, 2)
        XCTAssertTrue(model.hasUnsuccessfulItemsToClean)

        let stats = await model.cleanUpUnsuccessfulJobsAndResidualFiles()
        XCTAssertEqual(stats.removedRecords, 4)
        XCTAssertEqual(stats.deletedDirectories, 2)
        try await model.flushJobPersistence()
        try await TestSupport.eventually { !model.isRecoveryScanRunning && model.cleanableRecoveryItemCount == 0 }

        // Unsuccessful records are gone from both live and recent lists,
        // while queued, in-session completed, gap-completed, and archived completed all remain.
        XCTAssertEqual(model.unsuccessfulJobCount, 0)
        XCTAssertFalse(model.hasUnsuccessfulItemsToClean)
        XCTAssertEqual(Set(model.jobs.map(\.id)), Set([queuedJob.id, gapCompletedJob.id, liveCompletedID]))
        XCTAssertEqual(
            Set(model.recentJobs.map(\.id)),
            Set([completedJob.id, gapCompletedJob.id, archivedCompletedID, liveCompletedID])
        )

        // Leftover failed & orphan directories deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedRecoveryDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanTempDir.path))

        // Protected files & directories remain 100% intact
        XCTAssertEqual(try Data(contentsOf: sourceAudio), sourceBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completeOut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gapOut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gapRecoveryDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: queuedTempDir.path))

        await model.stopAllForTermination()
    }
}
