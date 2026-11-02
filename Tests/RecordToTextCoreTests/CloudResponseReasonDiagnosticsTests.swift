import XCTest
@testable import RecordToTextCore

final class CloudResponseReasonDiagnosticsTests: XCTestCase {
    private func parse(_ json: String, collector: CloudDiagnosticCollector) throws -> String {
        try CloudDiagnosticContext.$current.withValue(collector) {
            try GoogleAIStudioBackend().parseCandidateText(from: Data(json.utf8))
        }
    }

    func testUnaryReasonsAreRecordedBeforeFailureAndNeverInheritedByNextAttempt() throws {
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
        let collector = CloudDiagnosticCollector(history: history)
        collector.requestStarted(stage: .generation, responseMode: .unaryJSON, sendSequence: 1)
        XCTAssertThrowsError(try parse(#"{"candidates":[{"finishReason":"STOP"}]}"#, collector: collector)) {
            collector.failure($0, stage: .generation)
        }
        collector.requestStarted(stage: .generation, responseMode: .unaryJSON, sendSequence: 2)
        XCTAssertThrowsError(try parse(#"{"promptFeedback":{"blockReason":"OTHER","blockReasonMessage":"PRIVATE_REASON"}}"#, collector: collector)) {
            collector.failure($0, stage: .generation)
        }
        let events = history.snapshot().events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].finishReason, "STOP")
        XCTAssertNil(events[0].promptBlockReason)
        XCTAssertNil(events[1].finishReason)
        XCTAssertEqual(events[1].promptBlockReason, "OTHER")
        XCTAssertEqual(events[1].failure.promptBlockReason, "OTHER")
        XCTAssertTrue(events[1].failure.userMessage.contains("未提供具體原因（OTHER）"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(history.snapshot()), as: UTF8.self).contains("PRIVATE_REASON"))
        let jobDiagnostics = CloudJobDiagnostics(
            audioDurationSeconds: 10,
            segments: [collector.snapshot(start: 0, end: 10, outcome: .failed, preparation: nil, cloud: nil)],
            postprocessingSeconds: 0,
            failureHistory: history.snapshot()
        )
        let eventLines = jobDiagnostics.debugSummary.split(separator: "\n").filter { $0.contains("attempt=") }
        XCTAssertEqual(eventLines.count, 2)
        XCTAssertEqual(eventLines[0].components(separatedBy: "finishReason=STOP").count - 1, 1)
        XCTAssertEqual(eventLines[1].components(separatedBy: "promptBlockReason=OTHER").count - 1, 1)
        XCTAssertEqual(
            CloudFailureDiagnostic.classify(GoogleAIStudioError.incompleteResponse(finishReason: "RECITATION", message: nil), stage: .generation).finishReason,
            "RECITATION"
        )
        XCTAssertNil(
            CloudFailureDiagnostic.classify(GoogleAIStudioError.incompleteResponse(finishReason: "MISSING_FINISH_REASON", message: nil), stage: .generation).finishReason
        )
    }

    func testSuccessfulUnaryResponseAndLateTransportUpdateRemainOnCorrectAttempt() throws {
        let collector = CloudDiagnosticCollector()
        let generationID = collector.requestStarted(stage: .generation, responseMode: .unaryJSON)
        XCTAssertEqual(try parse(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"逐字稿"}]}}]}"#,
                                 collector: collector), "逐字稿")
        collector.requestStarted(stage: .poll, responseMode: .unaryJSON)
        collector.recordGenerationResponse(finishReason: "OTHER", promptBlockReason: "SAFETY")
        collector.updateCurrentAttempt(attemptID: generationID, httpStatus: 200, finishReason: "STOP", receivedByteCount: 100)
        let attempts = try XCTUnwrap(collector.snapshot(start: 0, end: 10, outcome: .completed,
            preparation: nil, cloud: nil).attempts)
        XCTAssertEqual(attempts[0].finishReason, "STOP")
        XCTAssertEqual(attempts[0].receivedByteCount, 100)
        XCTAssertNil(attempts[1].finishReason)
        XCTAssertNil(attempts[1].promptBlockReason)
        for _ in 0..<40 { collector.requestStarted(stage: .upload) }
        collector.updateCurrentAttempt(attemptID: generationID, finishReason: "OTHER")
        XCTAssertNil(collector.snapshot(start: 0, end: 10, outcome: .completed,
            preparation: nil, cloud: nil).attempts?.last?.finishReason)
    }

    func testUnknownProviderCodesCannotPersistPrivateASCIIOrLongText() throws {
        for value in ["PRIVATE_CONTEXT", "private\nmessage", String(repeating: "x", count: 500)] {
            let collector = CloudDiagnosticCollector()
            collector.requestStarted(stage: .generation, responseMode: .unaryJSON)
            collector.recordGenerationResponse(finishReason: value, promptBlockReason: value)
            let snapshot = collector.snapshot(start: 0, end: 1, outcome: .failed, preparation: nil, cloud: nil)
            XCTAssertEqual(snapshot.attempts?.first?.finishReason, "UNKNOWN")
            XCTAssertEqual(snapshot.attempts?.first?.promptBlockReason, "UNKNOWN")
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(value))
            let failure = CloudFailureDiagnostic.classify(GoogleAIStudioError.promptBlocked(
                .init(httpStatusCode: 200, blockReason: value)))
            XCTAssertEqual(failure.promptBlockReason, "UNKNOWN")
            XCTAssertFalse(failure.userMessage.contains(value))
        }
    }

    func testReasonFieldsRoundTripAndLegacyHistoryDecodesWithoutInventedValues() throws {
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
        let collector = CloudDiagnosticCollector(history: history)
        collector.requestStarted(stage: .generation, responseMode: .unaryJSON)
        collector.recordGenerationResponse(finishReason: nil, promptBlockReason: "OTHER")
        collector.failure(GoogleAIStudioError.promptBlocked(.init(httpStatusCode: 200, blockReason: "OTHER")), stage: .generation)
        let data = try JSONEncoder().encode(history.snapshot())
        XCTAssertEqual(try JSONDecoder().decode(CloudFailureHistory.self, from: data), history.snapshot())
        func legacy(_ object: Any) -> Any {
            if let object = object as? [String: Any] {
                return object.filter { !["promptBlockReason", "finishReason", "generationSendCount"].contains($0.key) }
                    .mapValues(legacy)
            }
            if let list = object as? [Any] { return list.map(legacy) }
            return object
        }
        let old = try JSONSerialization.data(withJSONObject: legacy(JSONSerialization.jsonObject(with: data)))
        let decoded = try JSONDecoder().decode(CloudFailureHistory.self, from: old)
        XCTAssertNil(decoded.events.first?.finishReason)
        XCTAssertNil(decoded.events.first?.promptBlockReason)
        XCTAssertNil(decoded.events.first?.failure.promptBlockReason)
        let inherited = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio, inherited: history.snapshot())
        XCTAssertEqual(inherited.snapshot().events, history.snapshot().events)
        XCTAssertEqual(inherited.snapshot().generationRequestCount, 1)
    }

    func testExhaustionIsSeparateTerminalSummaryNotAnotherSendAndUsesAccurateMessage() throws {
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
        let collector = CloudDiagnosticCollector(history: history)
        for n in 1...4 {
            collector.requestStarted(stage: .generation, responseMode: .unaryJSON, sendSequence: n)
            collector.recordGenerationResponse(finishReason: "STOP", promptBlockReason: nil)
            collector.failure(GoogleAIStudioError.emptyCompletedResponse, stage: .generation)
        }
        let exhausted = CloudEmptyResponseExhausted(sendCount: 4)
        let diagnostic = collector.failure(exhausted, stage: .generation)
        collector.failure(exhausted, stage: .generation)
        XCTAssertEqual(history.snapshot().generationRequestCount, 4)
        XCTAssertEqual(history.snapshot().events.count, 5)
        XCTAssertEqual(history.snapshot().events.last?.recoveryStopReason, .attemptsExhausted)
        XCTAssertFalse(history.snapshot().events.last?.resultUnknown ?? true)
        XCTAssertEqual(diagnostic.category, .emptyResponse)
        let wrapped = CloudSegmentExecutionError(segmentIndex: 2, segmentCount: 3, underlying: exhausted, diagnostic: diagnostic)
        XCTAssertTrue(wrapped.localizedDescription.contains("4 次發送上限"))
        XCTAssertTrue(wrapped.localizedDescription.contains("最後一次"))
        XCTAssertFalse(wrapped.localizedDescription.contains("網路"))
    }

    func testContextMatchingProtocolWordsPreservesNewTypedError() throws {
        for context in ["STOP", "OTHER", "PRIVATE_CONTEXT"] {
            let redacted = CloudRecordingContext.redactedError(GoogleAIStudioError.emptyCompletedResponse, context: context)
            XCTAssertEqual(redacted as? GoogleAIStudioError, .emptyCompletedResponse)
            XCTAssertEqual(CloudFailureDiagnostic.classify(redacted).finishReason, "STOP")
        }
    }

    func testUntrustedResponseFieldsNeverReachParserLogsOrUserErrors() throws {
        for privateValue in ["PRIVATE_PROJECT", "PRIVATE\nCREDENTIAL", String(repeating: "PRIVATE", count: 100)] {
            let responses: [[String: Any]] = [
                ["promptFeedback": ["blockReason": privateValue, "blockReasonMessage": privateValue,
                    "safetyRatings": [["category": privateValue, "probability": privateValue]]],
                 "responseId": privateValue, "modelVersion": privateValue],
                ["promptFeedback": ["blockReason": "OTHER", "blockReasonMessage": privateValue]],
                ["promptFeedback": ["blockReason": "SAFETY", "blockReasonMessage": privateValue]],
                ["candidates": [["finishReason": privateValue, "finishMessage": privateValue,
                    "content": ["parts": [[privateValue: privateValue, "thought": true, "text": privateValue]]]]],
                 privateValue: privateValue, "responseId": privateValue, "modelVersion": privateValue,
                 "usageMetadata": ["promptTokenCount": privateValue]],
                ["candidates": [["finishMessage": privateValue]]],
                ["candidates": [["finishReason": "SAFETY", "finishMessage": privateValue]]]
            ]
            for response in responses {
                let data = try JSONSerialization.data(withJSONObject: response)
                var logs: [String] = []
                let logger: (String, String) -> Void = { _, message in logs.append(message) }
                XCTAssertThrowsError(try GoogleAIStudioBackend().parseCandidateText(from: data, logger: logger)) {
                    XCTAssertFalse($0.localizedDescription.contains(privateValue))
                }
                XCTAssertThrowsError(try VertexAIGeminiBackend().parseCandidateText(from: data, logger: logger)) {
                    XCTAssertFalse($0.localizedDescription.contains(privateValue))
                }
                XCTAssertFalse(logs.joined().contains(privateValue))
            }
        }
        let unknown = GeminiPromptBlockDiagnostics(httpStatusCode: 200, blockReason: "PRIVATE_UNKNOWN_REASON")
        XCTAssertEqual(unknown.blockReason, "PRIVATE_UNKNOWN_REASON", "Classification must keep the original reason")
        XCTAssertFalse(unknown.isExplicitSafetyPolicy)
        XCTAssertTrue(unknown.userFacingMessage.contains("UNKNOWN"))
    }

    func testPartialBackgroundInHTTPFailureCannotReachBackendLogsOrSavedFailureMessage() async throws {
        let privateName = "PRIVATE_PROJECT"
        let context = "This recording discusses \(privateName) and its confidential plans."
        ReasonPrivacyURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
            "error": ["message": "Invalid argument for \(privateName)"]
        ])
        let session = GeminiTransportHelper.makeEphemeralRetrySession(protocolClasses: [ReasonPrivacyURLProtocol.self])
        defer { session.invalidateAndCancel(); ReasonPrivacyURLProtocol.responseData = Data() }
        let backend = GoogleAIStudioBackend(urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false))
        var logs: [String] = []
        do {
            _ = try await backend.transcribeDetailed(audioData: Data("fixture-audio".utf8), recordingContext: context,
                logger: { _, message in logs.append(message) })
            XCTFail("HTTP 400 must remain a failure")
        } catch {
            guard case let .requestFailed(status, rawMessage) = error as? GoogleAIStudioError else {
                return XCTFail("Redaction changed the error type")
            }
            XCTAssertEqual(status, 400)
            XCTAssertFalse(rawMessage.contains(privateName))
            let diagnostic = CloudFailureDiagnostic.classify(error, stage: .generation)
            let wrapped = CloudSegmentExecutionError(segmentIndex: 1, segmentCount: 1, underlying: error, diagnostic: diagnostic)
            XCTAssertFalse(wrapped.localizedDescription.contains(privateName))
            XCTAssertTrue(wrapped.localizedDescription.contains("HTTP 400"))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains(privateName))
        }
        XCTAssertFalse(logs.joined().contains(privateName))

        let vertex = CloudRecordingContext.redactedError(
            VertexAIError.requestFailed(statusCode: 400, message: "Invalid argument for \(privateName)"), context: context)
        guard case let .requestFailed(status, message) = vertex as? VertexAIError else {
            return XCTFail("Vertex redaction changed the error type")
        }
        XCTAssertEqual(status, 400)
        XCTAssertFalse(message.contains(privateName))
        XCTAssertFalse(vertex.localizedDescription.contains(privateName))
    }
}

private final class ReasonPrivacyURLProtocol: URLProtocol {
    static var responseData = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
