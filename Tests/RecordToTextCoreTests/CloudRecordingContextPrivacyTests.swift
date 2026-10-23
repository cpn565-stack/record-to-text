import XCTest
@testable import RecordToTextCore

final class CloudRecordingContextPrivacyTests: XCTestCase {
    func testDiagnosticRedactsRawNormalizedLinesAndJSONValuesWithoutRewritingMarker() throws {
        let context = "  PRIVATE_LINE_ONE\r\nPRIVATE_\"LINE\"_TWO\\path/part  "
        let normalized = CloudRecordingContext.normalized(context)
        let encoder = JSONEncoder()
        let encoded = String(decoding: try encoder.encode(normalized), as: UTF8.self)
        let message = "raw=\(context); normalized=\(normalized); encoded=\(encoded); line=PRIVATE_LINE_ONE"
        let clean = CloudRecordingContext.redactedDiagnostic(message, context: context)
        XCTAssertFalse(clean.contains("PRIVATE_LINE_ONE"))
        XCTAssertFalse(clean.contains("PRIVATE_"))
        XCTAssertTrue(clean.contains("[錄音背景已隱藏]"))
        XCTAssertEqual(CloudRecordingContext.redactedDiagnostic("message", context: " \r\n"), "message")
        XCTAssertEqual(CloudRecordingContext.redactedDiagnostic("錄音背景\n背景", context: "錄音背景\n背景"),
            "[錄音背景已隱藏]")
    }

    func testTruncatedResponseKeepsPartialTextAndTypeButRedactsFinishMessage() throws {
        let partial = "講者 1：實際說出的 PRIVATE_CONTEXT。"
        let original = CloudOutputTruncatedError(partialText: partial, finishMessage: "output limit for PRIVATE_CONTEXT")
        let clean = try XCTUnwrap(CloudRecordingContext.redactedError(original, context: "PRIVATE_CONTEXT") as? CloudOutputTruncatedError)
        XCTAssertEqual(clean.partialText, partial, "Do not silently alter partial transcript content")
        XCTAssertFalse(clean.localizedDescription.contains("PRIVATE_CONTEXT"))
        XCTAssertTrue(clean.localizedDescription.contains("maxOutputTokens"))
        XCTAssertEqual(CloudFailureDiagnostic.classify(clean), CloudFailureDiagnostic.classify(original))
        XCTAssertEqual(CloudRecordingContext.redactedError(original, context: "") as? CloudOutputTruncatedError, original)
    }

    func testRedactionPreservesProviderErrorKindsAndRetryDelay() throws {
        let errors: [Error] = [
            GoogleAIStudioError.requestFailed(statusCode: 503, message: "PRIVATE_CONTEXT"),
            GoogleAIStudioError.rateLimited(message: "PRIVATE_CONTEXT", retryAfterSeconds: 7.5),
            GoogleAIStudioError.quotaExceeded("PRIVATE_CONTEXT"),
            GoogleAIStudioError.prohibitedContent("PRIVATE_CONTEXT"),
            GoogleAIStudioError.incompleteResponse(finishReason: "OTHER", message: "PRIVATE_CONTEXT"),
            GoogleAIStudioError.fileUploadFailed("PRIVATE_CONTEXT"),
            VertexAIError.requestFailed(statusCode: 400, message: "PRIVATE_CONTEXT"),
            VertexAIError.rateLimited(message: "PRIVATE_CONTEXT", retryAfterSeconds: 7.5),
            VertexAIError.quotaExceeded("PRIVATE_CONTEXT"),
            VertexAIError.prohibitedContent("PRIVATE_CONTEXT"),
            VertexAIError.incompleteResponse(finishReason: "OTHER", message: "PRIVATE_CONTEXT"),
            VertexAIError.authenticationFailed("PRIVATE_CONTEXT")
        ]
        for error in errors {
            let clean = CloudRecordingContext.redactedError(error, context: "PRIVATE_CONTEXT")
            XCTAssertFalse(clean.localizedDescription.contains("PRIVATE_CONTEXT"))
            XCTAssertEqual(CloudFailureDiagnostic.classify(clean), CloudFailureDiagnostic.classify(error))
        }
        guard case let GoogleAIStudioError.rateLimited(_, studioDelay) = CloudRecordingContext.redactedError(errors[1], context: "PRIVATE_CONTEXT"),
              case let VertexAIError.rateLimited(_, vertexDelay) = CloudRecordingContext.redactedError(errors[7], context: "PRIVATE_CONTEXT") else {
            return XCTFail("Redaction changed the typed rate-limit errors")
        }
        XCTAssertEqual(studioDelay, 7.5)
        XCTAssertEqual(vertexDelay, 7.5)
    }

    func testPromptBlockRetainsSafetyClassificationWhenContextMatchesProtocolToken() throws {
        let diagnostics = GeminiPromptBlockDiagnostics(httpStatusCode: 200, blockReason: "SAFETY",
            blockReasonMessage: "submitted SAFETY", safetyRatings: [], modelVersion: "model", responseID: "response",
            promptTokenCount: 42, audioTokenCount: 20)
        let studio = try XCTUnwrap(CloudRecordingContext.redactedError(GoogleAIStudioError.promptBlocked(diagnostics),
            context: "SAFETY") as? GoogleAIStudioError)
        let vertex = try XCTUnwrap(CloudRecordingContext.redactedError(VertexAIError.promptBlocked(diagnostics),
            context: "SAFETY") as? VertexAIError)
        XCTAssertTrue(studio.isExplicitSafetyPolicyBlock)
        XCTAssertTrue(vertex.isExplicitSafetyPolicyBlock)
        guard case let .promptBlocked(clean) = vertex else { return XCTFail("Changed error type") }
        XCTAssertEqual(clean.blockReason, "SAFETY")
        XCTAssertFalse(clean.blockReasonMessage?.contains("SAFETY") ?? true)
        XCTAssertEqual(clean.promptTokenCount, 42)
        XCTAssertEqual(clean.audioTokenCount, 20)
    }

    func testAIStudioTruncationRedactsProviderFinishMessageBeforeLeavingBackend() async throws {
        let context = "PRIVATE_CONTEXT_LINE_ONE\nPRIVATE_CONTEXT_LINE_TWO"
        let partial = "講者 1：實際對話。"
        let data = try JSONSerialization.data(withJSONObject: [
            "candidates": [["finishReason": "MAX_TOKENS", "finishMessage": "Output limit: PRIVATE_CONTEXT_LINE_TWO",
                "content": ["parts": [["text": partial]]]]]
        ])
        ContextPrivacyURLProtocol.responseData = data
        ContextPrivacyURLProtocol.statusCode = 200
        let session = GeminiTransportHelper.makeEphemeralRetrySession(protocolClasses: [ContextPrivacyURLProtocol.self])
        defer { session.invalidateAndCancel(); ContextPrivacyURLProtocol.responseData = Data() }
        let backend = GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "fixture", useFilesAPI: false))
        var logMessages: [String] = []
        do {
            _ = try await backend.transcribeDetailed(audioData: Data("fixture-audio".utf8), recordingContext: context,
                logger: { _, message in logMessages.append(message) })
            XCTFail("MAX_TOKENS must stay a truncation error")
        } catch let error as CloudOutputTruncatedError {
            XCTAssertEqual(error.partialText, partial)
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE_CONTEXT"))
        }
        XCTAssertFalse(logMessages.joined().contains("PRIVATE_CONTEXT"))
    }
}

private final class ContextPrivacyURLProtocol: URLProtocol {
    static var responseData = Data()
    static var statusCode = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
