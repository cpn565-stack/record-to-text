import Foundation
import XCTest
@testable import RecordToTextCore
@testable import RecordToTextApp

// Regression cases from the finalization review. No provider calls or user data.
@MainActor
final class FinalizationReviewProbeTests: XCTestCase {
    func testOrdinarySentenceMustNotBecomeSpeakerName() {
        var roster = SpeakerRoster()
        let text = "講者 1：我是負責這個專案的窗口。"
        roster.observe(transcript: text, segmentIndex: 1)
        XCTAssertEqual(roster.normalizingSpeakerLabels(in: text), text)
    }

    func testAmbiguousSuffixMustNotChooseFirstPerson() {
        var roster = SpeakerRoster()
        roster.observe(transcript: "王小明：早安。\n陳小明：你好。", segmentIndex: 1)
        let text = "小明：我補充一下。"
        roster.observe(transcript: text, segmentIndex: 2)
        XCTAssertEqual(roster.normalizingSpeakerLabels(in: text), text)
    }

    func testRepeatedGenericLabelMustNotOverrideExplicitNewIntroduction() {
        var roster = SpeakerRoster()
        roster.observe(transcript: "講者 1：我叫王小明。", segmentIndex: 1)
        let text = "講者 1：我叫陳大文。"
        roster.observe(transcript: text, segmentIndex: 2)
        XCTAssertFalse(roster.normalizingSpeakerLabels(in: text).hasPrefix("王小明："))
    }

    func testLocalJobMustNotFailWhileCredentialLoadIsPending() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewBlockedCredentialStore()
        let model = AppViewModel(paths: ApplicationPaths(root: root), credentialStore: store)
        defer { store.gate.signal() }
        model.setSetting(\.outputLocationMode, to: .fixedDirectory)
        model.setSetting(\.defaultOutputDirectory, to: root.path)
        model.selectQuickTranscriptionChoice(.qwen3ASR1_7BBF16)
        model.addFiles([root.appendingPathComponent("fixture.wav")])
        let id = try XCTUnwrap(model.jobs.first?.id)
        model.startQueuedJobs()
        for _ in 0..<50 {
            if model.jobs.first(where: { $0.id == id })?.stage == .failed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let job = try XCTUnwrap(model.jobs.first(where: { $0.id == id }))
        XCTAssertTrue(model.isGoogleAIStudioCredentialLoading)
        XCTAssertNotEqual(job.stage, .failed, job.failure?.technicalDetails ?? "")
        await model.stopAllForTermination()
        store.gate.signal()
        await model.waitForCredentialLoading()
    }

    func testGapWarningMustSurvivePersistenceRoundTrip() throws {
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp", keepRawTranscript: false)
        var job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot)
        job.stage = .completed
        job.completedAt = Date()
        job.failure = JobFailure(stage: .completed, userMessage: "稿件含缺口",
            technicalDetails: "review fixture", recoverable: true,
            recoveryDirectory: "/fixture-recovery")
        let canonical = PersistenceSnapshot(revision: 1, jobs: [job], recentJobs: [],
            recentHistoryLimit: 10).canonical()
        let decoded = try JSONDecoder().decode(PersistenceSnapshot.self,
            from: JSONEncoder().encode(canonical))
        XCTAssertTrue(decoded.jobs.contains { $0.id == job.id && $0.failure != nil }
            || decoded.recentJobs.contains { $0.id == job.id && $0.statusWithCompletionTime().contains("缺口") })
    }

    func testAllBackendsWaitForStartupAndResumeAfterLoadOutcome() async throws {
        for backend in [ASRBackendType.localQwen, .vertexAI, .googleAIStudio] {
            for outcome in [0, 1, 2] {
                let root = try TestSupport.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let store = ReviewBlockedCredentialStore(outcome: outcome)
                let paths = ApplicationPaths(root: root)
                let model = AppViewModel(paths: paths, credentialStore: store)
                model.setSetting(\.outputLocationMode, to: .fixedDirectory)
                model.setSetting(\.defaultOutputDirectory, to: root.path)
                model.setSetting(\.backendType, to: backend)
                model.addFiles([root.appendingPathComponent("missing.wav")])
                let id = try XCTUnwrap(model.jobs.first?.id)
                model.startQueuedJobs()
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(model.jobs.first?.stage, .queued)
                XCTAssertNil(model.jobs.first?.startedAt)
                XCTAssertTrue(model.isWaitingForStartup)
                store.gate.signal()
                await model.waitForCredentialLoading()
                for _ in 0..<200 {
                    if model.jobs.first?.stage.isTerminal == true { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let job = try XCTUnwrap(model.jobs.first(where: { $0.id == id }))
                // The deliberately missing source/runtime prevents any provider call.
                XCTAssertNotNil(job.startedAt, "\(backend) outcome \(outcome)")
                XCTAssertFalse(job.failure?.technicalDetails.contains("Code=512") == true)
                await model.stopAllForTermination()
                try await model.flushJobPersistence()
                let saved = try XCTUnwrap(JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs).recover())
                XCTAssertTrue(saved.jobs.contains { $0.id == id })
            }
        }
    }

    func testCancelledRemovedOrTerminatedPendingStartCannotRunLater() async throws {
        for action in ["cancel", "remove", "terminate"] {
            let root = try TestSupport.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ReviewBlockedCredentialStore()
            let model = AppViewModel(paths: ApplicationPaths(root: root), credentialStore: store)
            model.setSetting(\.outputLocationMode, to: .fixedDirectory)
            model.setSetting(\.defaultOutputDirectory, to: root.path)
            model.addFiles([root.appendingPathComponent("missing.wav")])
            let id = try XCTUnwrap(model.jobs.first?.id)
            model.startQueuedJobs()
            switch action {
            case "cancel": model.cancelPendingStart()
            case "remove": model.removeQueuedJob(id)
            default: await model.stopAllForTermination()
            }
            store.gate.signal()
            await model.waitForCredentialLoading()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(model.manualDrainRequested)
            XCTAssertTrue(model.jobs.allSatisfy { $0.startedAt == nil })
            XCTAssertNil(model.activeJobID)
            await model.stopAllForTermination()
            try await model.flushJobPersistence()
        }
    }
}

private final class ReviewBlockedCredentialStore: GoogleAIStudioCredentialStoring, @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    let outcome: Int
    init(outcome: Int = 0) { self.outcome = outcome }
    func loadAPIKey() throws -> String? {
        gate.wait()
        if outcome == 2 { throw CocoaError(.fileReadNoPermission) }
        return outcome == 1 ? "fixture-key" : nil
    }
    func saveAPIKey(_ apiKey: String?) throws {}
}
