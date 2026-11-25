import Foundation
import XCTest
@testable import RecordToTextApp
@testable import RecordToTextCore

private struct OptSpecCredentialStore: GoogleAIStudioCredentialStoring {
    var key: String?
    func loadAPIKey() throws -> String? { key }
    func saveAPIKey(_ apiKey: String?) throws {}
}

private final class OptSpecURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let currentHandler = Self.lock.withLock { Self.handler }
        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try currentHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.withLock { items.append(item) }
    }

    var values: [Element] {
        lock.withLock { items }
    }
}

final class OptimizationSpec20261125Tests: XCTestCase {
    override func tearDown() {
        OptSpecURLProtocol.lock.withLock { OptSpecURLProtocol.handler = nil }
        super.tearDown()
    }

    // MARK: - AC-01 (OPT-01): Duplicate confirmation syncs engine settings while preserving batch glossary/context

    @MainActor
    func testDuplicateConfirmationSyncsEngineSwitchToLocalQwenAndCloudModels() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        var initial = AppSettings(defaultOutputDirectory: root.path)
        initial.backendType = .googleAIStudio
        initial.googleAIStudioModelID = "gemini-4-neon"
        initial.showNotificationWhenCompleted = false
        initial.hasCompletedOnboarding = true
        try JSONRepository<AppSettings>(url: paths.settings).save(initial)

        let model = AppViewModel(
            paths: paths,
            credentialStore: OptSpecCredentialStore(key: "fixture-api-key")
        )
        await model.waitForCredentialLoading()

        let glossaryID = model.createGlossary(name: "半導體詞庫", terms: ["CoWoS", "HBM4"])
        model.selectGlossary(glossaryID)
        model.cloudRecordingContextDraft = "原始批次背景"

        let audioA = root.appendingPathComponent("a.wav")
        try Data("fixture".utf8).write(to: audioA)

        model.addFiles([audioA, audioA])
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertTrue(model.isDuplicateConfirmationPresented)

        // While the duplicate dialog is open, switch backend to Local Qwen and mutate drafts.
        model.selectQuickTranscriptionChoice(.qwen3ASR0_6B8bit)
        let otherGlossaryID = model.createGlossary(name: "醫療詞庫", terms: ["MRI"])
        model.selectGlossary(otherGlossaryID)
        model.cloudRecordingContextDraft = "新批次背景"

        model.confirmDuplicateFiles()
        XCTAssertFalse(model.isDuplicateConfirmationPresented)
        XCTAssertEqual(model.jobs.count, 2)

        for job in model.jobs {
            XCTAssertEqual(job.snapshot.backendType, .localQwen)
            XCTAssertEqual(job.snapshot.modelID, ASRModelDescriptor.appleSilicon0_6B8bit.id)
            XCTAssertEqual(job.snapshot.glossaryName, "半導體詞庫")
            XCTAssertEqual(job.snapshot.terms, ["CoWoS", "HBM4"])
            XCTAssertEqual(job.snapshot.cloudRecordingContext, "原始批次背景")
            XCTAssertNil(job.snapshot.googleAIStudioAPIKey)
        }

        // Verify cloud model + thinking level switching during duplicate confirmation as well.
        model.selectQuickTranscriptionChoice(.aiStudioGemini4Neon)
        let audioB = root.appendingPathComponent("b.wav")
        try Data("fixture-b".utf8).write(to: audioB)
        model.addFiles([audioB, audioB])
        XCTAssertEqual(model.jobs.count, 3)
        XCTAssertTrue(model.isDuplicateConfirmationPresented)

        model.selectQuickTranscriptionChoice(.vertexGemini4Hydrogen)
        model.setSetting(\.vertexAIProjectID, to: "proj-sync-test")
        model.setSetting(\.vertexAILocation, to: "eu")
        model.confirmDuplicateFiles()

        XCTAssertEqual(model.jobs.count, 4)
        for job in model.jobs.suffix(2) {
            XCTAssertEqual(job.snapshot.backendType, .vertexAI)
            XCTAssertEqual(job.snapshot.vertexAIModelID, "gemini-4-hydrogen")
            XCTAssertEqual(job.snapshot.geminiThinkingLevel, .xhigh)
            XCTAssertEqual(job.snapshot.vertexAIProjectID, "proj-sync-test")
            XCTAssertEqual(job.snapshot.vertexAILocation, "eu")
        }

        await model.stopAllForTermination()
    }

    // MARK: - AC-02 (OPT-02): Remote fileName validation & redacted cleanup/GCS logs

    func testValidateRemoteFileNameRejectsTraversalURLsAndMalformedIDs() throws {
        XCTAssertEqual(try GoogleAIStudioBackend.validateRemoteFileName("files/abc-019"), "files/abc-019")

        let invalidNames = [
            "",
            "files/",
            "files/../models/gemini-4-neon",
            "https://evil.example/steal",
            "files/UPPERCASE",
            "files/abc?alt=media",
            "files/abc#frag",
            "files/" + String(repeating: "a", count: 41),
            "models/gemini-4-neon"
        ]
        for bad in invalidNames {
            XCTAssertThrowsError(try GoogleAIStudioBackend.validateRemoteFileName(bad), "Should reject \(bad)") { error in
                guard case .fileUploadFailed = error as? GoogleAIStudioError else {
                    return XCTFail("Expected fileUploadFailed for \(bad), got \(error)")
                }
            }
        }
    }

    func testFilesAPIRefusesPollAndDeleteOnMalformedFileNameAndRedactsCleanupLogs() async throws {
        let session = GeminiTransportHelper.makeInteractiveProbeSession(protocolClasses: [OptSpecURLProtocol.self])
        defer { session.finishTasksAndInvalidate() }

        let seenRequests = LockedList<String>()
        OptSpecURLProtocol.lock.withLock {
            OptSpecURLProtocol.handler = { request in
                let url = request.url!
                seenRequests.append("\(request.httpMethod ?? "GET") \(url.absoluteString)")
                if url.path.contains("/upload/v1beta/files") {
                    let resp = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["X-Goog-Upload-URL": "https://upload.optspec.test/resumable"]
                    )!
                    return (resp, Data())
                }
                if url.host == "upload.optspec.test" {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    let malicious = #"{"file":{"name":"files/../models/secret","uri":"https://files.optspec.test/a","state":"PROCESSING"}}"#
                    return (resp, Data(malicious.utf8))
                }
                XCTFail("Unexpected request sent for unvalidated fileName: \(url)")
                throw URLError(.badURL)
            }
        }

        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(apiKey: "secret-api-key", useFilesAPI: true)
        )
        do {
            _ = try await backend.transcribe(audioData: Data("audio-bytes".utf8))
            XCTFail("Expected malformed file.name to fail upload")
        } catch let error as GoogleAIStudioError {
            guard case .fileUploadFailed = error else {
                return XCTFail("Expected fileUploadFailed, got \(error)")
            }
        }

        // Neither poll GET nor DELETE may be issued for an invalid file.name.
        XCTAssertEqual(seenRequests.values.count, 2)
        XCTAssertFalse(seenRequests.values.joined(separator: "\n").contains("models/secret"))

        let directDeleteDiag = await backend.deleteRemoteFile(
            fileName: "https://evil.example/leak",
            apiKey: "secret-api-key"
        )
        XCTAssertEqual(directDeleteDiag?.category, .invalidResponse)
        XCTAssertEqual(directDeleteDiag?.stage, .cleanup)
        XCTAssertEqual(seenRequests.values.count, 2)

        // Now verify cleanup error logging never leaks fileName or NSError.localizedDescription.
        let studioLogs = LockedList<String>()
        OptSpecURLProtocol.lock.withLock {
            OptSpecURLProtocol.handler = { request in
                let url = request.url!
                if url.path.contains("/upload/v1beta/files") {
                    return (
                        HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["X-Goog-Upload-URL": "https://upload.optspec.test/ok"]
                        )!,
                        Data()
                    )
                }
                if url.host == "upload.optspec.test" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"file":{"name":"files/sensitive-id-999","uri":"https://files.optspec.test/ok","state":"ACTIVE"}}"#.utf8)
                    )
                }
                if request.httpMethod == "DELETE" {
                    throw NSError(
                        domain: NSURLErrorDomain,
                        code: URLError.cannotConnectToHost.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "Proxy error for https://secret-proxy.internal/files/sensitive-id-999"]
                    )
                }
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"測試逐字稿。"}]}}]}"#.utf8)
                )
            }
        }

        _ = try await backend.transcribe(audioData: Data("audio".utf8)) { _, msg in
            studioLogs.append(msg)
        }
        let studioJoined = studioLogs.values.joined(separator: "\n")
        XCTAssertTrue(studioJoined.contains("清理 Files API 暫存檔未完成（"))
        XCTAssertFalse(studioJoined.contains("sensitive-id-999"))
        XCTAssertFalse(studioJoined.contains("secret-proxy.internal"))

        // Verify Vertex GCS upload & cleanup logs redact bucket, objectName, and localizedDescription.
        let gcloudFixture = try makeFakeGCloud()
        defer { try? FileManager.default.removeItem(at: gcloudFixture.root) }

        let vertexLogs = LockedList<String>()
        OptSpecURLProtocol.lock.withLock {
            OptSpecURLProtocol.handler = { request in
                let url = request.url!
                if url.host == "storage.googleapis.com", request.httpMethod == "POST" {
                    let resp = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Location": "https://storage.googleapis.com/upload/storage/v1/b/private-bucket-xyz/o?upload_id=1"]
                    )!
                    return (resp, Data())
                }
                if url.host == "storage.googleapis.com", request.httpMethod == "PUT" {
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{}"#.utf8))
                }
                if url.host == "storage.googleapis.com", request.httpMethod == "DELETE" {
                    throw NSError(
                        domain: NSURLErrorDomain,
                        code: URLError.timedOut.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "DELETE https://storage.googleapis.com/private-bucket-xyz/secret leaked"]
                    )
                }
                let sse = "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"Vertex 逐字稿。\"}]}}]}\r\n\r\n"
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(sse.utf8))
            }
        }

        let vertexBackend = VertexAIGeminiBackend(
            authService: GCloudAuthService(customGCloudPath: gcloudFixture.executable.path),
            urlSession: session,
            configuration: .init(
                projectID: "proj-test",
                location: "global",
                modelID: "gemini-4-neon",
                gcsBucket: "private-bucket-xyz"
            )
        )
        _ = try await vertexBackend.transcribe(audioData: Data("audio".utf8)) { _, msg in
            vertexLogs.append(msg)
        }
        let vertexJoined = vertexLogs.values.joined(separator: "\n")
        XCTAssertTrue(vertexJoined.contains("使用設定的 GCS 儲存貯體串流上傳音訊..."))
        XCTAssertTrue(vertexJoined.contains("清理 GCS 暫存檔未完成（"))
        XCTAssertFalse(vertexJoined.contains("private-bucket-xyz"))
        XCTAssertFalse(vertexJoined.contains("record_to_text_"))
        XCTAssertFalse(vertexJoined.contains("secret leaked"))
    }

    // MARK: - AC-03 (OPT-03): Inside-out signing & universal helper verification in release scripts

    func testSignScriptSignsHelpersBeforeAppAndVerifyReleaseEnforcesUniversalHelpers() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let signScript = projectRoot.appendingPathComponent("scripts/sign-app.sh")
        let verifyScript = projectRoot.appendingPathComponent("scripts/verify-release.sh")

        let appURL = root.appendingPathComponent("record-to-text.app", isDirectory: true)
        let macOSDir = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let helpersDir = appURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let resourceBundle = appURL.appendingPathComponent(
            "Contents/Resources/record-to-text_RecordToTextApp.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceBundle, withIntermediateDirectories: true)

        // Compile a tiny universal stub for main executable and arm64-only stub for helpers.
        let cSource = root.appendingPathComponent("stub.c")
        try "int main(void) { return 0; }\n".write(to: cSource, atomically: true, encoding: .utf8)

        let mainBin = macOSDir.appendingPathComponent("record-to-text")
        let ffmpegBin = helpersDir.appendingPathComponent("ffmpeg")
        let ffprobeBin = helpersDir.appendingPathComponent("ffprobe")
        _ = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: ["-arch", "arm64", "-arch", "x86_64", cSource.path, "-o", mainBin.path]
        )
        _ = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: ["-arch", "arm64", cSource.path, "-o", ffmpegBin.path]
        )
        _ = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: ["-arch", "arm64", cSource.path, "-o", ffprobeBin.path]
        )

        let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.copyItem(
            at: projectRoot.appendingPathComponent("Config/Info.plist"),
            to: infoPlist
        )
        for helper in [
            "qwen_asr_chunking.py",
            "qwen_asr_local_checkpoint.py",
            "qwen_asr_mlx_runner.py",
            "qwen_asr_transformers_runner.py"
        ] {
            try Data("# stub\n".utf8).write(to: resourceBundle.appendingPathComponent(helper))
        }

        // Mock codesign to verify exact inside-out signing order and flags without needing a Developer ID cert.
        let mockBinDir = root.appendingPathComponent("mock-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: mockBinDir, withIntermediateDirectories: true)
        let logFile = root.appendingPathComponent("codesign.log")
        let mockCodesign = mockBinDir.appendingPathComponent("codesign")
        try """
        #!/bin/sh
        echo "$*" >> "\(logFile.path)"
        exit 0
        """.write(to: mockCodesign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mockCodesign.path)

        var signEnv = ProcessInfo.processInfo.environment
        signEnv["DEVELOPER_ID_APPLICATION"] = "Developer ID Application: Mock Test"
        signEnv["PATH"] = "\(mockBinDir.path):/usr/bin:/bin:/usr/sbin:/sbin"
        _ = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [signScript.path, appURL.path],
            environment: signEnv
        )

        let calls = try String(contentsOf: logFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls[0].contains("Contents/Helpers/ffmpeg") && !calls[0].contains("--entitlements"))
        XCTAssertTrue(calls[1].contains("Contents/Helpers/ffprobe") && !calls[1].contains("--entitlements"))
        XCTAssertTrue(calls[2].hasSuffix(appURL.path) && calls[2].contains("--entitlements"))
        XCTAssertTrue(calls[3].contains("--verify --deep --strict"))

        // REQUIRE_UNIVERSAL=1 must fail when Contents/Helpers/ffmpeg is arm64-only.
        var verifyEnv = ProcessInfo.processInfo.environment
        verifyEnv["ALLOW_UNSIGNED"] = "1"
        verifyEnv["REQUIRE_UNIVERSAL"] = "1"
        let verifyResult = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [verifyScript.path, appURL.path],
            environment: verifyEnv,
            requireSuccess: false
        )
        XCTAssertNotEqual(verifyResult.terminationStatus, 0)
        XCTAssertTrue(verifyResult.standardErrorText.contains("Universal build requires both arm64 and x86_64 for bundled helper ffmpeg"))
    }

    // MARK: - AC-04 (OPT-04): Cloud disk space precheck fails fast before compression or API calls

    func testCloudDiskSpacePrecheckFailsBeforeCompressionOrNetworkCalls() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let settings = AppSettings.defaultValue(developerMode: true)
        let runtime = RuntimeEnvironment.candidate(paths: paths, settings: settings, bundledHelperURL: nil)
        let source = root.appendingPathComponent("short.wav")
        _ = try await ProcessRunner().run(
            executableURL: runtime.ffmpeg,
            arguments: ["-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-y", source.path]
        )

        let networkHitCount = LockedList<Int>()
        let session = GeminiTransportHelper.makeInteractiveProbeSession(protocolClasses: [OptSpecURLProtocol.self])
        defer { session.finishTasksAndInvalidate() }
        OptSpecURLProtocol.lock.withLock {
            OptSpecURLProtocol.handler = { _ in
                networkHitCount.append(1)
                throw URLError(.badServerResponse)
            }
        }

        // Case 1: Insufficient temporary space
        let lowTempProbe = AudioProbeService(
            executableURL: runtime.ffprobe,
            capacityProvider: { url in
                url.path == root.path ? 500 * 1_024 * 1_024 : 10 * 1_024 * 1_024
            }
        )
        let lowTempEngine = TranscriptionEngine(
            runtime: runtime,
            paths: paths,
            probeService: lowTempProbe,
            googleAIStudioBackend: GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "k")),
            vertexAIBackend: VertexAIGeminiBackend(urlSession: session)
        )

        for backend in [ASRBackendType.googleAIStudio, .vertexAI] {
            let snapshot = JobSnapshot(
                modelID: "unused",
                glossaryID: nil,
                glossaryName: nil,
                terms: [],
                prompt: "",
                outputLocationMode: .fixedDirectory,
                outputDirectory: root.path,
                keepRawTranscript: false,
                backendType: backend
            )
            let job = TranscriptionJob(sourcePath: source.path, snapshot: snapshot)
            do {
                _ = try await lowTempEngine.run(job: job) { _ in }
                XCTFail("Expected insufficientDiskSpace for \(backend)")
            } catch let error as PipelineExecutionError {
                guard case .insufficientDiskSpace = error.underlying as? AudioServiceError else {
                    return XCTFail("Expected insufficientDiskSpace, got \(error.underlying)")
                }
            }
        }

        // Case 2: Insufficient output directory space
        let outDir = root.appendingPathComponent("LowOut", isDirectory: true)
        let lowOutProbe = AudioProbeService(
            executableURL: runtime.ffprobe,
            capacityProvider: { url in
                url.standardizedFileURL.path == outDir.standardizedFileURL.path
                    ? 1_024 * 1_024
                    : 500 * 1_024 * 1_024
            }
        )
        let lowOutEngine = TranscriptionEngine(
            runtime: runtime,
            paths: paths,
            probeService: lowOutProbe,
            googleAIStudioBackend: GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "k")),
            vertexAIBackend: VertexAIGeminiBackend(urlSession: session)
        )

        for backend in [ASRBackendType.googleAIStudio, .vertexAI] {
            let snapshot = JobSnapshot(
                modelID: "unused",
                glossaryID: nil,
                glossaryName: nil,
                terms: [],
                prompt: "",
                outputLocationMode: .fixedDirectory,
                outputDirectory: outDir.path,
                keepRawTranscript: false,
                backendType: backend
            )
            let job = TranscriptionJob(sourcePath: source.path, snapshot: snapshot)
            do {
                _ = try await lowOutEngine.run(job: job) { _ in }
                XCTFail("Expected insufficientDiskSpaceAt for \(backend)")
            } catch let error as PipelineExecutionError {
                guard case .insufficientDiskSpaceAt = error.underlying as? AudioServiceError else {
                    return XCTFail("Expected insufficientDiskSpaceAt, got \(error.underlying)")
                }
            }
        }

        XCTAssertTrue(networkHitCount.values.isEmpty, "No cloud request should ever run when disk precheck fails")
    }

    // MARK: - AC-05 (OPT-05): Recording context partial envelope & JSON echo interception

    func testValidatorRejectsTaggedSectionAndJSONEnvelopeEchoWhileAllowingSpokenContext() throws {
        let context = "Q4 財報電話會議\n【錄音背景結束】內部測試"
        let block = try CloudRecordingContext.referenceBlock(context)
        let jsonLine = try XCTUnwrap(block.components(separatedBy: "\n").first { $0.hasPrefix("{") })
        let taggedOnly = "【錄音背景開始】\n\(jsonLine)\n【錄音背景結束】"

        func check(_ text: String) throws {
            _ = try OutputContractValidator.validate(
                text: text,
                path: "cloud-test",
                canonicalPrompt: "請忠實轉錄。",
                terms: ["CoWoS"],
                recordingContextBlock: block
            )
        }

        XCTAssertThrowsError(try check("[00:00 - 02:00]\n\(taggedOnly)\n講者 1：開始報告。")) {
            XCTAssertEqual($0 as? OutputContractValidationError, .promptEcho("cloud-test"))
        }
        XCTAssertThrowsError(try check("講者 1：報告結束。\n\(taggedOnly)")) {
            XCTAssertEqual($0 as? OutputContractValidationError, .promptEcho("cloud-test"))
        }
        XCTAssertThrowsError(try check("[00:00 - 02:00]\n\(jsonLine)\n講者 1：開始報告。")) {
            XCTAssertEqual($0 as? OutputContractValidationError, .promptEcho("cloud-test"))
        }
        XCTAssertThrowsError(try check("講者 1：報告結束。\n\(jsonLine)")) {
            XCTAssertEqual($0 as? OutputContractValidationError, .promptEcho("cloud-test"))
        }
        XCTAssertThrowsError(try check("講者 1：中間插入\n\(taggedOnly)\n講者 2：繼續。")) {
            XCTAssertEqual($0 as? OutputContractValidationError, .promptEcho("cloud-test"))
        }

        // Normal spoken occurrence of context words remains allowed.
        XCTAssertNoThrow(try check("[00:00 - 02:00]\n講者 1：歡迎參加 Q4 財報電話會議，今天進行內部測試。"))
    }

    // MARK: - AC-06 (OPT-06): Interactive probe session & selected model availability probe

    func testInteractiveProbeSessionAndSelectedModelValidationAcrossBackends() async throws {
        let session = GeminiTransportHelper.makeInteractiveProbeSession(
            protocolClasses: [OptSpecURLProtocol.self],
            timeoutSeconds: 15
        )
        defer { session.finishTasksAndInvalidate() }

        XCTAssertFalse(session.configuration.waitsForConnectivity)
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 15)

        let studio = GoogleAIStudioBackend(urlSession: session)

        // 1. Offline fails immediately
        OptSpecURLProtocol.lock.withLock {
            OptSpecURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        }
        let offlineStart = ContinuousClock.now
        do {
            _ = try await studio.validateConnectionAndModel(apiKey: "key", modelID: "gemini-4-neon")
            XCTFail("Expected offline failure")
        } catch {
            XCTAssertLessThan(offlineStart.duration(to: .now), .seconds(5))
        }

        // 2. AI Studio: 200 success, 401 invalid key, 404 model not found, 403 permission denied
        OptSpecURLProtocol.lock.withLock {
            OptSpecURLProtocol.handler = { req in
                let path = req.url!.path
                let http = { (code: Int) in HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)! }
                if path.hasSuffix("/models/gemini-4-neon") {
                    return (http(200), Data(#"{"name":"models/gemini-4-neon","displayName":"Gemini 4 Neon"}"#.utf8))
                }
                if path.hasSuffix("/models/missing-model") {
                    return (http(404), Data(#"{"error":{"message":"Model not found"}}"#.utf8))
                }
                if path.hasSuffix("/models/gated-model") {
                    return (http(403), Data(#"{"error":{"message":"Caller does not have permission"}}"#.utf8))
                }
                return (http(400), Data(#"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#.utf8))
            }
        }

        let okProbe = try await studio.validateConnectionAndModel(apiKey: "valid-key", modelID: "gemini-4-neon")
        XCTAssertEqual(okProbe, .init(modelID: "gemini-4-neon", displayName: "Gemini 4 Neon"))

        do {
            _ = try await studio.validateConnectionAndModel(apiKey: "valid-key", modelID: "missing-model")
            XCTFail("Expected modelNotFound")
        } catch let error as GoogleAIStudioError {
            XCTAssertEqual(error, .modelNotFound("missing-model"))
            XCTAssertTrue(error.localizedDescription.contains("API Key 有效，但找不到模型 missing-model"))
        }

        do {
            _ = try await studio.validateConnectionAndModel(apiKey: "valid-key", modelID: "gated-model")
            XCTFail("Expected permissionDenied")
        } catch let error as GoogleAIStudioError {
            guard case .permissionDenied(modelID: "gated-model", _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            _ = try await studio.validateConnectionAndModel(apiKey: "bad-key", modelID: "other-model")
            XCTFail("Expected invalidAPIKey")
        } catch let error as GoogleAIStudioError {
            guard case .invalidAPIKey = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // 3. Vertex AI: Neon/Hydrogen incompatible location rejected before gcloud/network, 404->countTokens fallback, 403 IAM
        let gcloud = try makeFakeGCloud()
        defer { try? FileManager.default.removeItem(at: gcloud.root) }
        let vertex = VertexAIGeminiBackend(
            authService: GCloudAuthService(customGCloudPath: gcloud.executable.path),
            urlSession: session
        )

        for restricted in ["gemini-4-neon", "gemini-4-hydrogen"] {
            do {
                _ = try await vertex.validateConnectionAndModel(
                    projectID: "proj-1",
                    location: "asia-east1",
                    modelID: restricted
                )
                XCTFail("Expected unsupportedModelLocation for \(restricted)")
            } catch let error as VertexAIError {
                XCTAssertEqual(error, .unsupportedModelLocation(modelID: restricted, location: "asia-east1"))
            }
        }

        OptSpecURLProtocol.lock.withLock {
            OptSpecURLProtocol.handler = { req in
                let urlStr = req.url!.absoluteString
                let http = { (code: Int) in HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)! }
                if urlStr.contains("/models/gemini-4-neon:countTokens") {
                    return (http(200), Data(#"{"totalTokens":2}"#.utf8))
                }
                if urlStr.hasSuffix("/models/gemini-4-neon") {
                    return (http(404), Data(#"{"error":{"message":"Publisher GET unsupported"}}"#.utf8))
                }
                if urlStr.contains("/models/no-iam-model") {
                    return (http(403), Data(#"{"error":{"message":"Vertex AI API has not been used"}}"#.utf8))
                }
                return (http(404), Data(#"{"error":{"message":"Not found"}}"#.utf8))
            }
        }

        let resolvedProject = try await vertex.validateConnectionAndModel(
            projectID: nil,
            location: "global",
            modelID: "gemini-4-neon"
        )
        XCTAssertEqual(resolvedProject, "fake-gcp-project")

        do {
            _ = try await vertex.validateConnectionAndModel(
                projectID: "proj-1",
                location: "us-central1",
                modelID: "no-iam-model"
            )
            XCTFail("Expected permissionDenied")
        } catch let error as VertexAIError {
            XCTAssertEqual(error, .permissionDenied(projectID: "proj-1", location: "us-central1", modelID: "no-iam-model"))
        }

        do {
            _ = try await vertex.validateConnectionAndModel(
                projectID: "proj-1",
                location: "us-central1",
                modelID: "nonexistent-model"
            )
            XCTFail("Expected modelOrLocationNotFound")
        } catch let error as VertexAIError {
            XCTAssertEqual(error, .modelOrLocationNotFound(projectID: "proj-1", location: "us-central1", modelID: "nonexistent-model"))
        }
    }

    // MARK: - AC-07 (OPT-07): HF_TOKEN / HF_TOKEN_PATH propagation, download timeouts & atomic cache import

    @MainActor
    func testHFTokenEnvironmentPropagationAndAtomicCacheImport() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHome = root.appendingPathComponent("Home", isDirectory: true)
        let defaultTokenFile = fakeHome.appendingPathComponent(".cache/huggingface/token")
        try FileManager.default.createDirectory(
            at: defaultTokenFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("hf_dummy_local_login_token".utf8).write(to: defaultTokenFile)

        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let settings = AppSettings.defaultValue(developerMode: true)
        let runtime = RuntimeEnvironment.candidate(paths: paths, settings: settings, bundledHelperURL: nil)
        let helperBackend = HelperASRBackend(runtime: runtime, paths: paths, runner: ProcessRunner())

        // 1. Default ~/.cache/huggingface/token sets HF_TOKEN_PATH without reading secret value into env
        let fallbackEnv = helperBackend.helperEnvironment(
            modelCacheDirectory: paths.models.path,
            offline: false,
            inheritedEnvironment: ["HOME": fakeHome.path]
        )
        XCTAssertEqual(fallbackEnv["HF_TOKEN_PATH"], defaultTokenFile.path)
        XCTAssertNil(fallbackEnv["HF_TOKEN"])

        // 2. Explicit HF_TOKEN is forwarded and suppresses implicit HF_TOKEN_PATH override
        let explicitEnv = helperBackend.helperEnvironment(
            modelCacheDirectory: paths.models.path,
            offline: false,
            inheritedEnvironment: ["HOME": fakeHome.path, "HF_TOKEN": "explicit-token"]
        )
        XCTAssertEqual(explicitEnv["HF_TOKEN"], "explicit-token")
        XCTAssertNil(explicitEnv["HF_TOKEN_PATH"])

        let viewModel = AppViewModel(paths: paths, credentialStore: OptSpecCredentialStore())
        await viewModel.waitForCredentialLoading()
        let downloadEnv = viewModel.modelDownloadEnvironment(
            modelsDirectory: paths.models,
            inheritedEnvironment: ["HOME": fakeHome.path]
        )
        XCTAssertEqual(downloadEnv["HF_TOKEN_PATH"], defaultTokenFile.path)
        XCTAssertEqual(AppViewModel.modelDownloadHardTimeout, 7_200)
        XCTAssertEqual(AppViewModel.modelDownloadInactivityTimeout, 300)

        // 3. Atomic staging import: incomplete source must NOT clobber existing valid destination
        let modelID = ASRModelDescriptor.appleSiliconDefault.id
        let revision = try XCTUnwrap(ASRModelDescriptor.appleSiliconDefault.revision)
        let existingSnap = ModelCache.repositoryDirectory(
            modelID: modelID,
            hubRoot: ModelCache.hubRoot(modelsDirectory: paths.models)
        ).appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: existingSnap, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: existingSnap.appendingPathComponent("config.json"))
        try Data("existing-weights".utf8).write(to: existingSnap.appendingPathComponent("model.safetensors"))

        let incompleteHub = root.appendingPathComponent("IncompleteHub", isDirectory: true)
        let incompleteSnap = ModelCache.repositoryDirectory(modelID: modelID, hubRoot: incompleteHub)
            .appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: incompleteSnap, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: incompleteSnap.appendingPathComponent("config.json"))
        // Missing model.safetensors!

        try AppViewModel.copyModelFromDefaultHFCache(
            modelID: modelID,
            revision: revision,
            defaultHubRoot: incompleteHub,
            modelsDirectory: paths.models,
            fileManager: .default
        )
        XCTAssertTrue(ModelCache.isDownloaded(modelID: modelID, revision: revision, modelsDirectory: paths.models))
        XCTAssertEqual(
            try Data(contentsOf: existingSnap.appendingPathComponent("model.safetensors")),
            Data("existing-weights".utf8)
        )

        // Now complete the source cache and verify atomic replacement succeeds and leaves no .import-* dirs
        try Data("updated-weights".utf8).write(to: incompleteSnap.appendingPathComponent("model.safetensors"))
        try AppViewModel.copyModelFromDefaultHFCache(
            modelID: modelID,
            revision: revision,
            defaultHubRoot: incompleteHub,
            modelsDirectory: paths.models,
            fileManager: .default
        )
        XCTAssertEqual(
            try Data(contentsOf: existingSnap.appendingPathComponent("model.safetensors")),
            Data("updated-weights".utf8)
        )
        let leftoverStaging = try FileManager.default.contentsOfDirectory(atPath: paths.models.path)
            .filter { $0.hasPrefix(".import-") }
        XCTAssertTrue(leftoverStaging.isEmpty)

        await viewModel.stopAllForTermination()
    }

    // MARK: - AC-08 (OPT-08): GCloudAuthService environment allowlist, Homebrew PATH & 5-minute project TTL

    func testGCloudAuthAllowlistsEnvironmentAddsHomebrewPathAndExpiresProjectCache() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let envDump = root.appendingPathComponent("env.txt")
        let counterFile = root.appendingPathComponent("count.txt")
        let gcloudScript = root.appendingPathComponent("gcloud")
        try """
        #!/bin/sh
        /usr/bin/env > "\(envDump.path)"
        if [ "$1" = "config" ] && [ "$2" = "get-value" ] && [ "$3" = "project" ]; then
          c=0
          if [ -f "\(counterFile.path)" ]; then c=$(cat "\(counterFile.path)"); fi
          c=$((c + 1))
          echo "$c" > "\(counterFile.path)"
          echo "project-$c"
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "print-access-token" ]; then
          echo "tok-ok"
          exit 0
        fi
        exit 1
        """.write(to: gcloudScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gcloudScript.path)

        final class MutableClock: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Date(timeIntervalSince1970: 1_700_000_000)
            func now() -> Date { lock.withLock { value } }
            func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
        }
        let clock = MutableClock()

        let auth = GCloudAuthService(
            customGCloudPath: gcloudScript.path,
            inheritedEnvironmentProvider: {
                [
                    "HOME": root.path,
                    "CLOUDSDK_CONFIG": "/tmp/custom-gcloud-cfg",
                    "GITHUB_TOKEN": "ghp_should_not_leak",
                    "AWS_SECRET_ACCESS_KEY": "aws_should_not_leak"
                ]
            },
            nowProvider: { clock.now() }
        )

        let p1 = try await auth.getDefaultProjectID()
        let p2 = try await auth.getDefaultProjectID()
        XCTAssertEqual(p1, "project-1")
        XCTAssertEqual(p2, "project-1")

        let envText = try String(contentsOf: envDump, encoding: .utf8)
        XCTAssertFalse(envText.contains("GITHUB_TOKEN="))
        XCTAssertFalse(envText.contains("AWS_SECRET_ACCESS_KEY="))
        XCTAssertTrue(envText.contains("CLOUDSDK_CONFIG=/tmp/custom-gcloud-cfg"))
        XCTAssertTrue(envText.contains("PATH=\(root.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"))

        // Advance past 300s TTL -> must re-query gcloud automatically
        clock.advance(301)
        let p3 = try await auth.getDefaultProjectID()
        XCTAssertEqual(p3, "project-2")
    }

    // MARK: - AC-09 (OPT-09): Unknown/Gemini-4 models return nil cost; fallback cost matches across Job, Log, and RecentJobSummary

    @MainActor
    func testUnknownModelsOmitEstimatedCostAndFallbackCostAlignsAcrossJobLogAndRecentSummary() async throws {
        let usage = CloudUsageMetadata(
            promptTokenCount: 100_000,
            candidatesTokenCount: 10_000,
            thoughtsTokenCount: 2_000,
            totalTokenCount: 112_000
        )
        for unpriced in [
            "gemini-4-neon",
            "gemini-4-neon-001",
            "publishers/google/models/gemini-4-hydrogen",
            "gemini-2.5-pro",
            "custom-enterprise-asr"
        ] {
            XCTAssertNil(usage.estimatedCostUSD(modelID: unpriced), "Model \(unpriced) must not fabricate cost")
            XCTAssertEqual(usage.summaryDisplay(modelID: unpriced), "112.0k tokens (思考 2.0k)")
        }
        XCTAssertNotNil(usage.estimatedCostUSD(modelID: "gemini-3.1-pro-preview"))

        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        var settings = AppSettings(defaultOutputDirectory: root.path)
        settings.showNotificationWhenCompleted = false
        settings.revealInFinderWhenCompleted = false
        settings.openTextWhenCompleted = false
        settings.hasCompletedOnboarding = true
        try JSONRepository<AppSettings>(url: paths.settings).save(settings)

        let model = AppViewModel(paths: paths, credentialStore: OptSpecCredentialStore())
        await model.waitForCredentialLoading()

        let audio = root.appendingPathComponent("fallback.m4a")
        let outTXT = root.appendingPathComponent("fallback.txt")
        try Data("audio".utf8).write(to: audio)
        try Data("逐字稿".utf8).write(to: outTXT)

        model.setSetting(\.googleAIStudioModelID, to: "gemini-3.8-flash")
        model.addFiles([audio])
        let jobID = try XCTUnwrap(model.jobs.first?.id)

        let seg1 = CloudTranscriptionMetadata(
            requestedModelID: "gemini-3.8-flash",
            effectiveModelID: "gemini-3.8-flash",
            usage: CloudUsageMetadata(promptTokenCount: 100_000, candidatesTokenCount: 10_000, thoughtsTokenCount: 0, totalTokenCount: 110_000)
        )
        let seg2 = CloudTranscriptionMetadata(
            requestedModelID: "gemini-3.8-flash",
            effectiveModelID: "gemini-3.6-flash",
            retryCount: 1,
            fallbackReason: "503",
            usage: CloudUsageMetadata(promptTokenCount: 100_000, candidatesTokenCount: 10_000, thoughtsTokenCount: 0, totalTokenCount: 110_000)
        )
        // Exact sum = $0.1125 + $0.0740 = $0.1865 ($0.19), NOT $0.2250 ($0.23)!
        let accepted = await model.acceptCompletedResult(
            PipelineResult(
                outputURL: outTXT,
                rawOutputURL: nil,
                duration: 3,
                cloudSegmentMetadata: [seg1, seg2]
            ),
            id: jobID
        )
        XCTAssertTrue(accepted)

        let completedJob = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(completedJob.cloudTokenSummary, "220.0k tokens，預估 $0.19")
        XCTAssertTrue(completedJob.logLines.joined(separator: "\n").contains("預估 $0.19"))

        let summary = RecentJobSummary(job: completedJob)
        XCTAssertEqual(summary.cloudTokenSummary, "220.0k tokens，預估 $0.19")
        let roundTripped = try JSONDecoder().decode(RecentJobSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(roundTripped.cloudTokenSummary, "220.0k tokens，預估 $0.19")

        await model.stopAllForTermination()
    }

    // MARK: - AC-10 & AC-11 (OPT-10, OPT-11): Idle/backend-switch helper release & toolbar local model checkmark

    @MainActor
    func testLocalEngineReleasesResourcesOnBackendSwitchAndIdleTimeoutAndToolbarAvoidsDuplicateCheckmark() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        var settings = AppSettings(defaultOutputDirectory: root.path)
        settings.backendType = .localQwen
        settings.developerMode = true
        settings.showNotificationWhenCompleted = false
        settings.revealInFinderWhenCompleted = false
        settings.openTextWhenCompleted = false
        settings.hasCompletedOnboarding = true
        try JSONRepository<AppSettings>(url: paths.settings).save(settings)

        let releaseCalls = LockedList<Int>()
        let model = AppViewModel(
            paths: paths,
            credentialStore: OptSpecCredentialStore(),
            engineFactory: { runtime in
                TranscriptionEngine(
                    runtime: runtime,
                    paths: paths,
                    onReleaseIdleResources: { releaseCalls.append(1) }
                )
            },
            idleEngineReleaseDelay: .milliseconds(80)
        )
        await model.waitForCredentialLoading()

        // AC-11: Default 1.7B 8-bit, 1.7B BF16, and 0.6B 8-bit all match QuickTranscriptionChoice with no custom header
        XCTAssertEqual(model.selectedQuickTranscriptionChoice, .qwen3ASR1_7B8bit)
        XCTAssertFalse(ToolbarModelMenu.showsCustomSelectionHeader(for: model))

        model.selectQuickTranscriptionChoice(.qwen3ASR0_6B8bit)
        XCTAssertEqual(model.selectedQuickTranscriptionChoice, .qwen3ASR0_6B8bit)
        XCTAssertFalse(ToolbarModelMenu.showsCustomSelectionHeader(for: model))

        model.setSelectedModelID("org/custom-local-qwen")
        XCTAssertNil(model.selectedQuickTranscriptionChoice)
        XCTAssertTrue(ToolbarModelMenu.showsCustomSelectionHeader(for: model))

        model.selectQuickTranscriptionChoice(.qwen3ASR1_7B8bit)

        // AC-10: Run a short job through the engine (using cloud mock so no MLX Python env is required to instantiate reusableEngine),
        // then verify idle timer and backend switch both trigger releaseIdleResources().
        let session = GeminiTransportHelper.makeInteractiveProbeSession(protocolClasses: [OptSpecURLProtocol.self])
        defer { session.finishTasksAndInvalidate() }
        OptSpecURLProtocol.lock.withLock {
            OptSpecURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"測試。"}]}}]}"#.utf8)
                )
            }
        }

        let runtimeSample = RuntimeEnvironment.candidate(paths: paths, settings: settings, bundledHelperURL: nil)
        let source = root.appendingPathComponent("idle.wav")
        _ = try await ProcessRunner().run(
            executableURL: runtimeSample.ffmpeg,
            arguments: ["-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-y", source.path]
        )

        let engineModel = AppViewModel(
            paths: paths,
            credentialStore: OptSpecCredentialStore(key: "fixture-key"),
            engineFactory: { runtime in
                TranscriptionEngine(
                    runtime: runtime,
                    paths: paths,
                    googleAIStudioBackend: GoogleAIStudioBackend(
                        urlSession: session,
                        configuration: .init(apiKey: "fixture-key", useFilesAPI: false)
                    ),
                    onReleaseIdleResources: { releaseCalls.append(1) }
                )
            },
            idleEngineReleaseDelay: .milliseconds(80)
        )
        await engineModel.waitForCredentialLoading()
        engineModel.selectQuickTranscriptionChoice(.aiStudioGemini4Neon)
        engineModel.setSetting(\.silenceAwareCloudSegmentation, to: false)
        engineModel.addFiles([source])
        engineModel.startQueuedJobs()

        try await TestSupport.eventually {
            engineModel.jobs.first?.stage == .completed && engineModel.activeJobID == nil
        }
        // Wait for 80ms idle release timer to fire
        try await TestSupport.eventually { !releaseCalls.values.isEmpty }
        let afterIdleCount = releaseCalls.values.count

        // Switch to localQwen and back to cloud while idle -> immediate releaseIdleResources()
        engineModel.selectQuickTranscriptionChoice(.qwen3ASR1_7B8bit)
        engineModel.selectQuickTranscriptionChoice(.vertexGemini4Neon)
        XCTAssertGreaterThan(releaseCalls.values.count, afterIdleCount)

        await model.stopAllForTermination()
        await engineModel.stopAllForTermination()
    }

    // MARK: - Helpers

    private func makeFakeGCloud() throws -> (root: URL, executable: URL) {
        let root = try TestSupport.makeTemporaryDirectory()
        let script = root.appendingPathComponent("gcloud")
        try """
        #!/bin/sh
        if [ "$1" = "config" ] && [ "$2" = "get-value" ] && [ "$3" = "project" ]; then
          echo "fake-gcp-project"
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "print-access-token" ]; then
          echo "fake-oauth-token"
          exit 0
        fi
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (root, script)
    }
}
