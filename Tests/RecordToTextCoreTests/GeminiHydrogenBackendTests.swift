import Foundation
import XCTest
@testable import RecordToTextCore

private final class HydrogenURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let streaming = request.url!.absoluteString.contains("streamGenerateContent")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GeminiHydrogenBackendTests: XCTestCase {
    private var session: URLSession!
    private var root: URL!
    private var auth: GCloudAuthService!

    override func setUpWithError() throws {
        root = try TestSupport.makeTemporaryDirectory()
        let gcloud = root.appendingPathComponent("gcloud")
        try "#!/bin/sh\necho fixture-access-token\n".write(to: gcloud, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gcloud.path)
        auth = GCloudAuthService(customGCloudPath: gcloud.path)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HydrogenURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDownWithError() throws {
        HydrogenURLProtocol.handler = nil
        session?.invalidateAndCancel()
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testBothBackendsSendEverySupportedLevelAndExcludeThoughtsFromTranscript() async throws {
        for vertex in [false, true] {
            for (model, levels, outputLimit) in [
                ("gemini-4-hydrogen", [GeminiThinkingLevel.low, .medium, .high, .xhigh], 65_536),
                ("gemini-4-carbon", [.low, .medium, .high], 32_768)
            ] {
                for level in levels {
                    var calls = 0
                    HydrogenURLProtocol.handler = { request in
                        calls += 1
                        let expected = vertex
                            ? "/v1/projects/fixture-project/locations/global/publishers/google/models/\(model):streamGenerateContent"
                            : "/v1beta/models/\(model):generateContent"
                        XCTAssertEqual(request.url?.path, expected)
                        XCTAssertEqual(request.url?.host, vertex ? "aiplatform.googleapis.com" : "generativelanguage.googleapis.com")
                        if vertex { XCTAssertEqual(request.url?.query, "alt=sse") }
                        let body = try contextRequestBody(request)
                        let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
                        let thinking = try XCTUnwrap(generation["thinkingConfig"] as? [String: Any])
                        XCTAssertEqual(thinking["thinkingLevel"] as? String, level.rawValue)
                        XCTAssertNil(thinking["thinkingBudget"])
                        XCTAssertEqual(generation["maxOutputTokens"] as? Int, outputLimit)
                        XCTAssertNil(generation["temperature"])
                        XCTAssertGreaterThan(request.timeoutInterval, 1_100)
                        XCTAssertLessThanOrEqual(request.timeoutInterval, 1_200)
                        return (200, try self.response(vertex: vertex))
                    }
                    let result = try await transcribe(vertex: vertex, model: model, level: level)
                    XCTAssertEqual(calls, 1)
                    XCTAssertEqual(result.text, "講者 1：測試逐字稿。")
                    XCTAssertEqual(result.metadata.thinkingLevel, level)
                    XCTAssertEqual(result.metadata.effectiveModelID, model)
                    XCTAssertEqual(result.metadata.usage?.thoughtsTokenCount, 200)
                }
            }
        }
    }

    func testHydrogenDefaultIsActuallySentAndCarbonRejectsInheritedXHigh() async throws {
        for vertex in [false, true] {
            for (model, supplied, expected) in [
                ("gemini-4-hydrogen", Optional<GeminiThinkingLevel>.none, "xhigh"),
                ("gemini-4-carbon", .some(.xhigh), "high")
            ] {
                HydrogenURLProtocol.handler = { request in
                    let body = try contextRequestBody(request)
                    let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
                    XCTAssertEqual((generation["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, expected)
                    return (200, try self.response(vertex: vertex))
                }
                let result = try await transcribe(vertex: vertex, model: model, level: supplied)
                XCTAssertEqual(result.metadata.thinkingLevel.rawValue, expected)
            }
        }
    }

    func testHydrogenTruncatedAndContinuationResponsesCannotBecomeFinishedText() async throws {
        for vertex in [false, true] {
            for reason in ["MAX_TOKENS", "CONTINUATION"] {
                var calls = 0
                HydrogenURLProtocol.handler = { _ in
                    calls += 1
                    return (200, try self.response(vertex: vertex, finishReason: reason))
                }
                do {
                    _ = try await transcribe(vertex: vertex)
                    XCTFail("Incomplete Hydrogen output accepted")
                } catch let error as CloudOutputTruncatedError {
                    XCTAssertEqual(reason, "MAX_TOKENS")
                    XCTAssertEqual(error.partialText, "講者 1：測試逐字稿。")
                } catch {
                    XCTAssertEqual(reason, "CONTINUATION")
                    if vertex {
                        guard let vertexError = error as? VertexAIError, case .incompleteResponse = vertexError else {
                            return XCTFail("Unexpected error: \(error)")
                        }
                    } else {
                        guard let studioError = error as? GoogleAIStudioError, case .incompleteResponse = studioError else {
                            return XCTFail("Unexpected error: \(error)")
                        }
                    }
                }
                XCTAssertEqual(calls, 1)
            }
        }
    }

    func testHydrogenTimeoutStillRespectsShorterCallerBudget() async throws {
        for vertex in [false, true] {
            _ = try await auth.getAccessToken()
            HydrogenURLProtocol.handler = { request in
                XCTAssertGreaterThan(request.timeoutInterval, 400)
                XCTAssertLessThanOrEqual(request.timeoutInterval, 450)
                return (200, try self.response(vertex: vertex))
            }
            _ = try await CloudBudgetContext.$current.withValue(CloudSegmentBudget(limit: .seconds(450))) {
                try await self.transcribe(vertex: vertex)
            }
        }
    }

    func testOptionalVertexSummaryHasThinkingHeadroomAndFiltersThoughts() async throws {
        HydrogenURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("gemini-4-hydrogen:generateContent"))
            let body = try contextRequestBody(request)
            let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
            XCTAssertEqual(generation["maxOutputTokens"] as? Int, 65_536)
            XCTAssertEqual((generation["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "xhigh")
            return (200, try self.response(vertex: false))
        }
        let backend = VertexAIGeminiBackend(authService: auth, urlSession: session,
            configuration: .init(projectID: "fixture-project", modelID: "gemini-4-hydrogen"))
        let text = try await backend.summarizeTranscript("完整逐字稿")
        XCTAssertEqual(text, "講者 1：測試逐字稿。")
    }

    private func transcribe(vertex: Bool, model: String = "gemini-4-hydrogen",
                            level: GeminiThinkingLevel? = nil) async throws -> CloudTranscriptionResult {
        if vertex {
            return try await VertexAIGeminiBackend(authService: auth, urlSession: session,
                configuration: .init(projectID: "fixture-project", modelID: model, thinkingLevel: level))
                .transcribeDetailed(audioData: Data("fixture-audio".utf8))
        }
        return try await GoogleAIStudioBackend(urlSession: session,
            configuration: .init(apiKey: "fixture-key", modelID: model, useFilesAPI: false, thinkingLevel: level))
            .transcribeDetailed(audioData: Data("fixture-audio".utf8))
    }

    private func response(vertex: Bool, finishReason: String = "STOP") throws -> Data {
        let json: [String: Any] = [
            "candidates": [["index": 0, "finishReason": finishReason, "content": ["parts": [
                ["thought": true, "text": "PRIVATE_THOUGHT"],
                ["text": "講者 1：測試逐字稿。"]
            ]]]],
            "usageMetadata": ["promptTokenCount": 1_000, "candidatesTokenCount": 100,
                              "thoughtsTokenCount": 200, "totalTokenCount": 1_300]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return vertex ? Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8) : data
    }

    func testAIStudioValidateAPIKeyUsesLightweightModelsEndpointAndModelIDAllowlist() async throws {
        var lastMethod: String?
        var lastURL: URL?
        var lastKeyHeader: String?

        HydrogenURLProtocol.handler = { request in
            lastMethod = request.httpMethod
            lastURL = request.url
            lastKeyHeader = request.value(forHTTPHeaderField: "x-goog-api-key")
            return (200, Data(#"{"models":[{"name":"models/gemini-4-hydrogen"}]}"#.utf8))
        }

        let backend = GoogleAIStudioBackend(urlSession: session)
        let ok = try await backend.validateAPIKey("  AIza-test-key  ")
        XCTAssertTrue(ok)
        XCTAssertEqual(lastMethod, "GET")
        XCTAssertEqual(lastURL?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")
        XCTAssertEqual(lastKeyHeader, "AIza-test-key")

        HydrogenURLProtocol.handler = { _ in
            (403, Data(#"{"error":{"code":403,"message":"API key invalid"}}"#.utf8))
        }
        do {
            _ = try await backend.validateAPIKey("bad-key")
            XCTFail("Expected invalidAPIKey")
        } catch let error as GoogleAIStudioError {
            guard case .invalidAPIKey = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        var networkCalls = 0
        HydrogenURLProtocol.handler = { _ in
            networkCalls += 1
            return (200, Data())
        }
        for badModel in ["gemini/../evil", "gemini-4?alt=json", "gemini/subpath", ""] {
            let badBackend = GoogleAIStudioBackend(
                urlSession: session,
                configuration: .init(apiKey: "fixture-key", modelID: badModel, useFilesAPI: false)
            )
            do {
                _ = try await badBackend.transcribeDetailed(audioData: Data("audio".utf8))
                XCTFail("Expected invalidModelID for \(badModel)")
            } catch let error as GoogleAIStudioError {
                XCTAssertEqual(error, .invalidModelID(badModel))
            }
        }
        XCTAssertEqual(networkCalls, 0)
    }

    func testAIStudioStreamingSSEAndZeroCopyAudioFileURL() async throws {
        let workDir = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let audioFile = root.appendingPathComponent("segment-0001.mp3")
        try Data("direct-audio-file-bytes".utf8).write(to: audioFile)

        var sawAcceptHeader: String?
        var sawIncludeThoughts: Bool?
        HydrogenURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-4-hydrogen:streamGenerateContent")
            XCTAssertEqual(request.url?.query, "alt=sse")
            sawAcceptHeader = request.value(forHTTPHeaderField: "Accept")
            let body = try contextRequestBody(request)
            let gen = try XCTUnwrap(body["generationConfig"] as? [String: Any])
            let thinking = try XCTUnwrap(gen["thinkingConfig"] as? [String: Any])
            sawIncludeThoughts = thinking["includeThoughts"] as? Bool
            let sse =
                "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"thought\":true,\"text\":\"隱藏思考\"},{\"text\":\"講者 1：AI Studio \"}]}}]}\n\n" +
                "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"SSE 串流完成。\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":50,\"candidatesTokenCount\":12,\"thoughtsTokenCount\":30,\"totalTokenCount\":92}}\n\n"
            return (200, Data(sse.utf8))
        }

        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(
                apiKey: "fixture-key",
                modelID: "gemini-4-hydrogen",
                useFilesAPI: false,
                thinkingLevel: .xhigh,
                useStreamingSSE: true
            )
        )
        let result = try await backend.transcribeDetailed(
            audioFileURL: audioFile,
            workingDirectory: workDir
        )
        XCTAssertEqual(sawAcceptHeader, "text/event-stream")
        XCTAssertEqual(sawIncludeThoughts, true)
        XCTAssertEqual(result.text, "講者 1：AI Studio SSE 串流完成。")
        XCTAssertEqual(result.metadata.usage?.thoughtsTokenCount, 30)
    }

    func testEngineCancelCurrentJobImmediatelyTerminatesSlowFFprobe() async throws {
        let slowProbe = root.appendingPathComponent("slow-ffprobe")
        let startedFlag = root.appendingPathComponent("probe-started")
        let script = """
        #!/bin/sh
        touch "\(startedFlag.path)"
        sleep 20
        """
        try script.write(to: slowProbe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slowProbe.path)

        let dummyAudio = root.appendingPathComponent("sample.m4a")
        try Data("audio".utf8).write(to: dummyAudio)
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let runtime = ResolvedRuntime(
            python: URL(fileURLWithPath: "/usr/bin/true"),
            ffmpeg: URL(fileURLWithPath: "/usr/bin/true"),
            ffprobe: slowProbe,
            opencc: URL(fileURLWithPath: "/usr/bin/true"),
            helper: URL(fileURLWithPath: "/usr/bin/true"),
            gcloud: nil,
            isDeveloperRuntime: true
        )
        let engine = TranscriptionEngine(runtime: runtime, paths: paths)
        let snapshot = JobSnapshot(
            modelID: "gemini-4-hydrogen",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "",
            outputLocationMode: .fixedDirectory,
            outputDirectory: outDir.path,
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioAPIKey: "fixture-key",
            googleAIStudioModelID: "gemini-4-hydrogen"
        )
        let job = TranscriptionJob(sourcePath: dummyAudio.path, snapshot: snapshot)

        let start = ContinuousClock.now
        let runTask = Task {
            try await engine.run(job: job) { _ in }
        }
        try await TestSupport.eventually { FileManager.default.fileExists(atPath: startedFlag.path) }
        engine.cancelCurrentJob()
        runTask.cancel()
        _ = try? await runTask.value
        let elapsed = start.duration(to: .now).secondsValue
        XCTAssertLessThan(elapsed, 5.0, "cancelCurrentJob() must terminate ffprobe promptly instead of waiting 20s")
    }
}
