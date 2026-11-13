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
}
