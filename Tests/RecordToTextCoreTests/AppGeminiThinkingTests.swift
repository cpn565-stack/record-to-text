import XCTest
@testable import RecordToTextCore
@testable import RecordToTextApp

private struct ThinkingCredentialStore: GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ apiKey: String?) throws {}
}

@MainActor
final class AppGeminiThinkingTests: XCTestCase {
    func testSettingsAndQuickSelectionsUpdateQueuedJobsAndPersistPerModel() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let settings = AppSettings(defaultOutputDirectory: root.path,
            showNotificationWhenCompleted: false, hasCompletedOnboarding: true)
        try JSONRepository<AppSettings>(url: paths.settings).save(settings)
        let model = AppViewModel(paths: paths, credentialStore: ThinkingCredentialStore())
        await model.waitForCredentialLoading()
        model.selectQuickTranscriptionChoice(.aiStudioGemini4Hydrogen)
        model.addFiles([root.appendingPathComponent("fixture.wav")])
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.snapshot.geminiThinkingLevel, .xhigh)
        model.setSetting(\.geminiThinkingLevel, to: .medium)
        XCTAssertEqual(model.jobs.first?.snapshot.geminiThinkingLevel, .medium)

        // Settings model picker and main-window quick selector use the same policy.
        model.setSetting(\.googleAIStudioModelID, to: "gemini-4-carbon")
        model.setSetting(\.geminiThinkingLevel, to: .low)
        XCTAssertEqual(model.jobs.first?.snapshot.geminiThinkingLevel, .low)
        model.selectQuickTranscriptionChoice(.vertexGemini4Hydrogen)
        XCTAssertEqual(model.settings.geminiThinkingLevel, .medium)
        XCTAssertEqual(model.jobs.first?.snapshot.backendType, .vertexAI)
        XCTAssertEqual(model.jobs.first?.snapshot.vertexAIModelID, "gemini-4-hydrogen")
        XCTAssertEqual(model.jobs.first?.snapshot.geminiThinkingLevel, .medium)
        model.flushPendingSettingsPersistence()
        await model.stopAllForTermination()
        try await model.flushJobPersistence()

        let restored = AppViewModel(paths: paths, credentialStore: ThinkingCredentialStore())
        await restored.waitForCredentialLoading()
        XCTAssertEqual(restored.settings.geminiThinkingLevel, .medium)
        restored.selectQuickTranscriptionChoice(.vertexGemini4Carbon)
        XCTAssertEqual(restored.settings.geminiThinkingLevel, .low)
        restored.selectQuickTranscriptionChoice(.aiStudioGemini4Hydrogen)
        XCTAssertEqual(restored.settings.geminiThinkingLevel, .medium)
        restored.flushPendingSettingsPersistence()
        await restored.stopAllForTermination()
        try await restored.flushJobPersistence()
    }

    func testRunningAndRecoveryJobsAreNotEligibleForPreferenceChanges() {
        let snapshot = JobSnapshot(modelID: "unused", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp/output", keepRawTranscript: false,
            googleAIStudioModelID: "gemini-4-hydrogen", geminiThinkingLevel: .xhigh)
        var job = TranscriptionJob(sourcePath: "/tmp/fixture.wav", snapshot: snapshot)
        XCTAssertTrue(job.canUpdateQueuedEngine(activeJobID: nil))
        XCTAssertFalse(job.canUpdateQueuedEngine(activeJobID: job.id))
        job.startedAt = Date()
        XCTAssertFalse(job.canUpdateQueuedEngine(activeJobID: nil))
        job.startedAt = nil
        job.resumeFromRecoveryDirectory = "/tmp/recovery"
        XCTAssertFalse(job.canUpdateQueuedEngine(activeJobID: nil))
    }
}
