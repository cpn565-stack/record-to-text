import XCTest
@testable import RecordToTextCore

final class CloudDiagnosticPersistenceTests: XCTestCase {
    func testDecodedUnknownReasonsCannotReenterCopiedDiagnostics() throws {
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
        let collector = CloudDiagnosticCollector(history: history)
        collector.requestStarted(stage: .generation, responseMode: .unaryJSON)
        collector.recordGenerationResponse(finishReason: "STOP", promptBlockReason: "OTHER")
        collector.failure(GoogleAIStudioError.promptBlocked(.init(httpStatusCode: 200, blockReason: "OTHER")), stage: .generation)
        let diagnostic = CloudJobDiagnostics(audioDurationSeconds: 1,
            segments: [collector.snapshot(start: 0, end: 1, outcome: .failed, preparation: nil, cloud: nil)],
            postprocessingSeconds: 0, failureHistory: history.snapshot())
        let encoded = try JSONEncoder().encode(diagnostic)
        func replacingCodes(_ object: Any, with value: Any) -> Any {
            if let dictionary = object as? [String: Any] {
                return dictionary.reduce(into: [String: Any]()) { result, entry in
                    result[entry.key] = ["finishReason", "promptBlockReason"].contains(entry.key)
                        ? value : replacingCodes(entry.value, with: value)
                }
            }
            if let array = object as? [Any] { return array.map { replacingCodes($0, with: value) } }
            return object
        }
        for value: Any in ["PRIVATE_PROVIDER_TEXT", NSNull()] {
            let object = replacingCodes(try JSONSerialization.jsonObject(with: encoded), with: value)
            let decoded = try JSONDecoder().decode(CloudJobDiagnostics.self, from: JSONSerialization.data(withJSONObject: object))
            let expected: String? = value is NSNull ? nil : "UNKNOWN"
            XCTAssertEqual(decoded.segments.first?.attempts?.first?.finishReason, expected)
            XCTAssertEqual(decoded.segments.first?.attempts?.first?.promptBlockReason, expected)
            XCTAssertEqual(decoded.segments.first?.failure?.promptBlockReason, expected)
            XCTAssertEqual(decoded.failureHistory?.events.first?.finishReason, expected)
            XCTAssertEqual(decoded.failureHistory?.events.first?.promptBlockReason, expected)
            XCTAssertEqual(decoded.failureHistory?.events.first?.failure.promptBlockReason, expected)
            XCTAssertFalse(decoded.debugSummary.contains("PRIVATE_PROVIDER_TEXT"))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("PRIVATE_PROVIDER_TEXT"))
        }
    }

    func testCancellationBeforeAttemptBindingDoesNotChangePreviousRequest() {
        let collector = CloudDiagnosticCollector()
        collector.requestStarted(stage: .generation, responseMode: .unaryJSON)
        collector.recordGenerationResponse(finishReason: "STOP", promptBlockReason: nil)
        let before = collector.snapshot(start: 0, end: 1, outcome: .failed, preparation: nil, cloud: nil)
        let delegate = CloudRequestTaskDelegate(stage: .generation, responseMode: .unaryJSON,
            streamingLimits: .default, context: nil, collector: collector, trackConnectivityWait: false) { _, _ in }
        delegate.stop(cancelled: true)
        XCTAssertEqual(collector.snapshot(start: 0, end: 1, outcome: .failed, preparation: nil, cloud: nil), before)
    }

    func testTruncationMessageDoesNotPublishProviderFreeText() {
        let error = CloudOutputTruncatedError(partialText: "救援文字", finishMessage: "PRIVATE_PROVIDER_TEXT")
        XCTAssertEqual(error.partialText, "救援文字")
        XCTAssertFalse(error.localizedDescription.contains("PRIVATE_PROVIDER_TEXT"))
        XCTAssertTrue(error.localizedDescription.contains("maxOutputTokens"))
    }
}
