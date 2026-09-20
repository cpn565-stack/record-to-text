import XCTest
@testable import RecordToTextCore

final class CloudFailureDiagnosticTests: XCTestCase {
    func testClassificationAndTimeoutSources() throws {
        let cases: [(Error, CloudFailureDiagnostic.Category)] = [
            (URLError(.networkConnectionLost), .connectionLost), (URLError(.notConnectedToInternet), .offline),
            (URLError(.dnsLookupFailed), .dnsFailure), (URLError(.cannotFindHost), .hostUnreachable),
            (URLError(.timedOut), .urlSessionTimeout), (CloudRequestDeadlineExceeded(stage: "generation"), .requestDeadlineExceeded),
            (CloudSegmentBudget(limit: .zero).deadlineError(stage: "generation"), .segmentDeadlineExceeded),
            (VertexAIError.emptyCompletedResponse, .emptyResponse), (CancellationError(), .cancelled),
            (URLError(.secureConnectionFailed), .tlsFailure), (VertexAIError.requestFailed(statusCode: 403, message: "secret"), .authentication),
            (VertexAIError.authenticationFailed("offline -1005"), .authUnavailable)
        ]
        for (error, category) in cases {
            let diagnostic = CloudFailureDiagnostic.classify(error, stage: .generation)
            XCTAssertEqual(diagnostic.category, category)
            XCTAssertEqual(try JSONDecoder().decode(CloudFailureDiagnostic.self, from: JSONEncoder().encode(diagnostic)), diagnostic)
        }
        XCTAssertEqual(CloudFailureDiagnostic.classify(URLError(.timedOut)).timeoutSource, .urlSession)
        XCTAssertEqual(CloudFailureDiagnostic.classify(CloudRequestDeadlineExceeded(stage: "poll")).timeoutSource, .requestDeadline)
    }

    func testErrorChainPrivacyAndDepth() throws {
        var error: NSError = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [
            NSLocalizedDescriptionKey: "PRIVATE-TRANSCRIPT", NSURLErrorFailingURLStringErrorKey: "https://secret.test/?key=PRIVATE-KEY",
            "token": "PRIVATE-TOKEN", "SSID": "PRIVATE-SSID", "address": "192.0.2.123"])
        error = NSError(domain: "PRIVATE-DOMAIN", code: 3, userInfo: [NSUnderlyingErrorKey: error, "prompt": "PRIVATE-PROMPT"])
        let diagnostic = CloudFailureDiagnostic.classify(error)
        XCTAssertEqual(diagnostic.category, .connectionLost)
        XCTAssertEqual(diagnostic.errorChain.count, 1)
        let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE"))
        XCTAssertFalse(diagnostic.debugSummary.contains("secret"))
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
        let collector = CloudDiagnosticCollector(history: history)
        collector.setModel("https://secret.test/?key=PRIVATE-KEY")
        collector.requestStarted(stage: .generation)
        collector.failure(error, stage: .generation)
        let job = CloudJobDiagnostics(audioDurationSeconds: 1,
            segments: [collector.snapshot(start: 0, end: 1, outcome: .failed, preparation: nil, cloud: nil)],
            postprocessingSeconds: 0, failureHistory: history.snapshot())
        let persisted = String(decoding: try JSONEncoder().encode(job), as: UTF8.self) + job.debugSummary
        for value in ["PRIVATE", "secret.test", "192.0.2.123"] { XCTAssertFalse(persisted.contains(value)) }
        for _ in 0..<10 { error = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: error]) }
        XCTAssertEqual(CloudFailureDiagnostic.classify(error).errorChain.count, 8)
        XCTAssertEqual(CloudFailureDiagnostic.classify(error).category, .unknown)
        XCTAssertEqual(CloudFailureDiagnostic.classify(CyclicDiagnosticError(domain: NSCocoaErrorDomain, code: 1)).errorChain.count, 1)
    }

    func testEventCapPreservesCountersAndTypedCause() throws {
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .vertexAI)
        let collector = CloudDiagnosticCollector(history: history)
        for _ in 0..<120 {
            collector.requestStarted(stage: .generation)
            collector.failure(URLError(.networkConnectionLost), stage: .generation)
        }
        let saved = history.snapshot()
        XCTAssertEqual(saved.events.count, 100)
        XCTAssertEqual(saved.totalEventCount, 120)
        XCTAssertEqual(saved.generationRequestCount, 120)
        XCTAssertEqual(saved.events.first?.attempt, 21)
        let cause = URLError(.networkConnectionLost)
        let segment = CloudSegmentExecutionError(segmentIndex: 3, segmentCount: 5, underlying: cause,
            diagnostic: .classify(cause, stage: .generation))
        let pipeline = PipelineExecutionError(stage: .transcribing, underlying: segment, recoveryDirectory: nil)
        XCTAssertEqual(CloudFailureDiagnostic.classify(pipeline).category, .connectionLost)
        XCTAssertTrue(pipeline.localizedDescription.contains("3/5"))
    }

    func testUnknownDiagnosticEnumsAndOldSegmentDecode() throws {
        XCTAssertEqual(try JSONDecoder().decode(CloudFailureDiagnostic.Category.self, from: Data("\"future\"".utf8)), .unknown)
        XCTAssertEqual(try JSONDecoder().decode(CloudSegmentDiagnostic.Outcome.self, from: Data("\"future\"".utf8)), .unknown)
        XCTAssertEqual(try JSONDecoder().decode(CloudRetryReason.self, from: Data("\"future\"".utf8)), .unknown)
        let old = Data(#"{"startSeconds":0,"endSeconds":10,"outcome":"completed","reusedFromCheckpoint":false,"stageTimings":[],"retryReasons":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(CloudSegmentDiagnostic.self, from: old)
        XCTAssertNil(decoded.failure)
        XCTAssertNil(decoded.generationRequestCount)
    }

    func testRecoveryStopSurvivesDeduplicationWrappingAndDebugCopy() throws {
        for reason: CloudNetworkRecovery.StopReason in [.rootDeadline, .waitExhausted, .attemptsExhausted] {
            let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .vertexAI)
            let collector = CloudDiagnosticCollector(history: history)
            let cause = CloudFailureDiagnostic.classify(URLError(.networkConnectionLost), stage: .generation)
            collector.requestStarted(stage: .generation)
            collector.failure(cause)
            collector.failure(cause)
            let recovery = CloudNetworkRecovery(state: .paused, stopReason: reason,
                waitedSeconds: 20, remainingWaitSeconds: 0, segmentIndex: 3, segmentCount: 5,
                completedSegmentCount: 2, lastFailure: cause, resultUnknown: true)
            let exhausted = CloudNetworkRecoveryExhausted(recovery: recovery)
            let wrapped = PipelineExecutionError(stage: .transcribing,
                underlying: CloudSegmentExecutionError(segmentIndex: 3, segmentCount: 5,
                    underlying: exhausted, diagnostic: .classify(exhausted)), recoveryDirectory: nil)
            collector.failure(wrapped, stage: .generation)
            collector.failure(wrapped, stage: .generation)
            let saved = history.snapshot()
            XCTAssertEqual(saved.totalEventCount, 2)
            XCTAssertEqual(saved.generationRequestCount, 1)
            XCTAssertNil(saved.events.first?.recoveryStopReason)
            XCTAssertEqual(saved.events.last?.recoveryStopReason, reason)
            XCTAssertEqual(saved.events.last?.failure, cause)
            XCTAssertEqual(saved.events.last?.resultUnknown, true)
            let job = CloudJobDiagnostics(audioDurationSeconds: 1, segments: [],
                postprocessingSeconds: 0, failureHistory: saved)
            let decoded = try JSONDecoder().decode(CloudJobDiagnostics.self, from: JSONEncoder().encode(job))
            XCTAssertEqual(decoded, job)
            XCTAssertTrue(decoded.debugSummary.contains("category=connectionLost"))
            XCTAssertTrue(decoded.debugSummary.contains("recoveryStopReason=\(reason.rawValue)"))
        }
    }

    func testOldFailureEventAndUnknownStopReasonDecode() throws {
        let old = Data(#"{"timestamp":0,"attempt":1,"completedSegmentCount":0,"resultUnknown":true,"failure":{"category":"connectionLost","stage":"generation","errorChain":[]}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CloudFailureEvent.self, from: old).recoveryStopReason)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        future["recoveryStopReason"] = "future"
        let decoded = try JSONDecoder().decode(CloudFailureEvent.self, from: JSONSerialization.data(withJSONObject: future))
        XCTAssertEqual(decoded.recoveryStopReason, .unknown)
    }
}

private final class CyclicDiagnosticError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}
