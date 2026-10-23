import XCTest
@testable import RecordToTextCore
@testable import RecordToTextApp

private struct ContextCredentialStore: GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ apiKey: String?) throws {}
}

@MainActor
final class AppRecordingContextTests: XCTestCase {
    private func fixture(choose: (() -> URL?)? = nil) throws -> (AppViewModel, ApplicationPaths) {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        var settings = AppSettings(defaultOutputDirectory: root.path)
        settings.outputLocationMode = choose == nil ? .fixedDirectory : .askEveryTime
        settings.showNotificationWhenCompleted = false
        settings.hasCompletedOnboarding = true
        try JSONRepository<AppSettings>(url: paths.settings).save(settings)
        return (AppViewModel(paths: paths, credentialStore: ContextCredentialStore(), outputDirectoryChooser: choose), paths)
    }

    func testBatchCapturesOnceClearsUsedDraftAndPersistsOnlySnapshots() async throws {
        let (model, paths) = try fixture()
        await model.waitForCredentialLoading()
        model.cloudRecordingContextDraft = " \r\n背景 A\rB \n"
        XCTAssertEqual(model.recordingContextCount, 6)
        model.addFiles([paths.root.appendingPathComponent("a.wav"), paths.root.appendingPathComponent("b.wav")])
        XCTAssertEqual(model.jobs.map(\.snapshot.cloudRecordingContext), ["背景 A\nB", "背景 A\nB"])
        XCTAssertEqual(model.cloudRecordingContextDraft, "")
        model.cloudRecordingContextDraft = "新的草稿"
        XCTAssertFalse(model.promptPreview(for: model.jobs[0].snapshot).contains("新的草稿"))
        XCTAssertTrue(model.promptPreview.contains("新的草稿"))
        XCTAssertTrue(model.promptPreview.contains(GeminiTranscriptPrompt.systemInstruction))
        XCTAssertTrue(model.promptPreview.contains("片段時間與講者參考會在處理時附加"))
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
        let stored = try XCTUnwrap(JobPersistenceStore(ledgerURL: paths.jobLedger, recentURL: paths.recentJobs).recover())
        XCTAssertEqual(stored.jobs.map(\.snapshot.cloudRecordingContext), ["背景 A\nB", "背景 A\nB"])
        XCTAssertFalse(try String(contentsOf: paths.settings).contains("新的草稿"))
        let restored = AppViewModel(paths: paths, credentialStore: ContextCredentialStore())
        await restored.waitForCredentialLoading()
        XCTAssertEqual(restored.cloudRecordingContextDraft, "")
        XCTAssertEqual(restored.jobs.map(\.snapshot.cloudRecordingContext), ["背景 A\nB", "背景 A\nB"])
        await restored.stopAllForTermination()
        try await restored.flushJobPersistence()
    }

    func testInvalidDraftBlocksCloudButNotLocalAndLocalDoesNotClearIt() async throws {
        let (model, paths) = try fixture()
        await model.waitForCredentialLoading()
        let source = paths.root.appendingPathComponent("a.wav")
        for invalid in [String(repeating: "x", count: 501), "a\0b"] {
            model.cloudRecordingContextDraft = invalid
            XCTAssertNotNil(model.recordingContextErrorMessage)
            model.addFiles([source])
            XCTAssertTrue(model.jobs.isEmpty)
            XCTAssertEqual(model.cloudRecordingContextDraft, invalid)
        }
        model.setSetting(\.backendType, to: .localQwen)
        XCTAssertNil(model.recordingContextErrorMessage)
        model.addFiles([source])
        XCTAssertEqual(model.jobs.first?.snapshot.cloudRecordingContext, "")
        XCTAssertEqual(model.cloudRecordingContextDraft, "a\0b")
        model.setSetting(\.backendType, to: .vertexAI)
        XCTAssertEqual(model.jobs.first?.snapshot.cloudRecordingContext, "")
        model.cloudRecordingContextDraft = "有效背景"
        model.addFiles([paths.root.appendingPathComponent("b.wav")])
        XCTAssertEqual(model.jobs.last?.snapshot.cloudRecordingContext, "有效背景")
        model.setSetting(\.backendType, to: .localQwen)
        XCTAssertTrue(model.promptPreview(for: model.jobs.last!.snapshot).contains("本機不套用"))
        model.setSetting(\.backendType, to: .googleAIStudio)
        XCTAssertEqual(model.jobs.last?.snapshot.cloudRecordingContext, "有效背景")
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testModalCancelRetainsDraftAndModalEditCannotBeClearedByOldBatch() async throws {
        var shouldCancel = true
        weak var editingModel: AppViewModel?
        let (model, paths) = try fixture(choose: {
            if shouldCancel { return nil }
            editingModel?.cloudRecordingContextDraft = "背景 B"
            return FileManager.default.temporaryDirectory
        })
        editingModel = model
        await model.waitForCredentialLoading()
        model.cloudRecordingContextDraft = "背景 A"
        model.addFiles([paths.root.appendingPathComponent("a.wav")])
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(model.cloudRecordingContextDraft, "背景 A")
        shouldCancel = false
        model.addFiles([paths.root.appendingPathComponent("a.wav"), paths.root.appendingPathComponent("b.wav")])
        XCTAssertEqual(model.jobs.map(\.snapshot.cloudRecordingContext), ["背景 A", "背景 A"])
        XCTAssertEqual(model.cloudRecordingContextDraft, "背景 B")
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testDuplicateConfirmationKeepsOriginalBatchContextAndNewDraft() async throws {
        let (model, paths) = try fixture()
        await model.waitForCredentialLoading()
        let source = paths.root.appendingPathComponent("a.wav")
        model.cloudRecordingContextDraft = "背景 A"
        model.addFiles([source, source])
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertTrue(model.isDuplicateConfirmationPresented)
        model.cloudRecordingContextDraft = "背景 B"
        model.confirmDuplicateFiles()
        XCTAssertEqual(model.jobs.map(\.snapshot.cloudRecordingContext), ["背景 A", "背景 A"])
        XCTAssertEqual(model.cloudRecordingContextDraft, "背景 B")
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }

    func testCurrentSettingsRebuildsUseNewDraftAndNeverOldRecovery() async throws {
        let (model, paths) = try fixture()
        await model.waitForCredentialLoading()
        let source = paths.root.appendingPathComponent("a.wav")
        try Data("fixture".utf8).write(to: source)
        model.cloudRecordingContextDraft = "背景 A"
        model.addFiles([source])
        let original = try XCTUnwrap(model.jobs.first)
        await model.stopAllForTermination() // queued -> terminal, without running inference
        model.cloudRecordingContextDraft = "背景 B"
        model.retryJob(original.id, usingCurrentSettings: true)
        let rebuilt = try XCTUnwrap(model.jobs.last)
        XCTAssertNotEqual(rebuilt.id, original.id)
        XCTAssertEqual(rebuilt.snapshot.cloudRecordingContext, "背景 B")
        XCTAssertNil(rebuilt.resumeFromRecoveryDirectory)
        XCTAssertNil(rebuilt.continuationParentJobID)
        let summary = RecentJobSummary(job: original)
        model.retryRecentJob(summary)
        XCTAssertEqual(model.jobs.last?.snapshot.cloudRecordingContext, "")
        let continuation = try CloudJobContinuation.make(from: original, paths: paths)
        XCTAssertEqual(continuation.snapshot.cloudRecordingContext, "背景 A")
        XCTAssertNotEqual(continuation.id, original.id)
        XCTAssertFalse(continuation.logLines.joined().contains("背景 A"))
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }
}

private final class ContextAppURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["X-Goog-Upload-URL": "https://upload.context.test/session"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct ContextExecutionCredentialStore: GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String? { "fixture-key" }
    func saveAPIKey(_ apiKey: String?) throws {}
}

extension AppRecordingContextTests {
    func testResendAndBothCurrentSettingsEntrypointsReachActualRequestWithCorrectContext() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        var settings = AppSettings(defaultOutputDirectory: root.path)
        settings.showNotificationWhenCompleted = false
        settings.outputLocationMode = .fixedDirectory
        settings.silenceAwareCloudSegmentation = false
        try JSONRepository<AppSettings>(url: paths.settings).save(settings)
        let runtime = RuntimeEnvironment.candidate(paths: paths, settings: settings, bundledHelperURL: nil)
        let source = root.appendingPathComponent("fixture.wav")
        _ = try await ProcessRunner().run(executableURL: runtime.ffmpeg,
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-y", source.path])
        let session = GeminiTransportHelper.makeEphemeralRetrySession(protocolClasses: [ContextAppURLProtocol.self])
        defer { session.invalidateAndCancel(); ContextAppURLProtocol.handler = nil }
        let texts = ContextRequestCapture()
        ContextAppURLProtocol.handler = { request in
            if request.url!.host == "upload.context.test" {
                return Data(#"{"file":{"name":"files/context-fixture","uri":"https://files.context.test/audio","state":"ACTIVE"}}"#.utf8)
            }
            if !request.url!.absoluteString.contains(":generateContent") {
                return Data(#"{"name":"files/context-fixture","state":"ACTIVE"}"#.utf8)
            }
            texts.append(try contextRequestText(contextRequestBody(request)))
            return Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[00:00 - 00:02]\n講者 1：測試內容。"}]}}]}"#.utf8)
        }
        let backend = GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "fixture", useFilesAPI: false))
        let model = AppViewModel(paths: paths, credentialStore: ContextExecutionCredentialStore(), engineFactory: { runtime in
            TranscriptionEngine(runtime: runtime, paths: paths, googleAIStudioBackend: backend)
        })
        await model.waitForCredentialLoading()
        model.cloudRecordingContextDraft = "CONTEXT_A"
        model.addFiles([source])
        let originalID = try XCTUnwrap(model.jobs.first?.id)
        model.startQueuedJobs()
        try await TestSupport.eventually { model.jobs.first?.stage == .completed && model.activeJobID == nil }
        model.cloudRecordingContextDraft = "CONTEXT_B"
        model.retryJob(originalID)
        try await TestSupport.eventually { model.jobs.count == 2 && model.jobs.last?.stage == .completed && model.activeJobID == nil }
        XCTAssertEqual(model.cloudRecordingContextDraft, "CONTEXT_B")
        model.retryJob(originalID, usingCurrentSettings: true)
        model.startQueuedJobs()
        try await TestSupport.eventually { model.jobs.count == 3 && model.jobs.last?.stage == .completed && model.activeJobID == nil }
        let summary = RecentJobSummary(job: try XCTUnwrap(model.jobs.first))
        model.retryRecentJob(summary)
        model.startQueuedJobs()
        try await TestSupport.eventually { model.jobs.count == 4 && model.jobs.last?.stage == .completed && model.activeJobID == nil }
        let sent = texts.values
        XCTAssertEqual(sent.count, 4)
        XCTAssertTrue(sent[0].contains("CONTEXT_A"))
        XCTAssertTrue(sent[1].contains("CONTEXT_A"))
        XCTAssertFalse(sent[1].contains("CONTEXT_B"))
        XCTAssertTrue(sent[2].contains("CONTEXT_B"))
        XCTAssertFalse(sent[3].contains("recording_context"))
        XCTAssertNil(model.jobs[2].continuationParentJobID)
        XCTAssertNil(model.jobs[3].resumeFromRecoveryDirectory)
        XCTAssertFalse(model.jobs.flatMap(\.logLines).joined().contains("CONTEXT_"))
        await model.stopAllForTermination()
        try await model.flushJobPersistence()
    }
}

private final class ContextRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}
