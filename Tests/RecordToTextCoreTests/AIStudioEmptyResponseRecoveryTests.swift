import Foundation
import XCTest
@testable import RecordToTextCore

/// Every URL, including Files cleanup and replacement sessions, stays in this protocol.
private final class EmptyResponseProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, headers, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AIStudioEmptyResponseRecoveryTests: XCTestCase {
    private let audio = Data("synthetic audio fixture".utf8)
    private let empty = Data(#"{"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"thoughtsTokenCount":4883}}"#.utf8)
    private let success = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"講者 1：完整測試逐字稿。"}]}}]}"#.utf8)
    private let busy = Data(#"{"error":{"code":429,"message":"Resource exhausted"}}"#.utf8)

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmptyResponseProtocol.self]
        return URLSession(configuration: config)
    }

    private func backend(_ session: URLSession, clock: RecoveryClock, files: Bool = false,
                         model: String = "gemini-3.8-flash") -> GoogleAIStudioBackend {
        GoogleAIStudioBackend(networkEnvironment: clock.environment(), urlSession: session,
            configuration: .init(apiKey: "synthetic-test-key", modelID: model, useFilesAPI: files,
                                 thinkingLevel: .high, fallbackPolicy: .flashOnly))
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }

    private func file(_ name: String) -> [String: Any] {
        ["name": name, "uri": "https://generativelanguage.googleapis.com/v1beta/" + name, "state": "ACTIVE"]
    }

    func testEmptyStopShapesRetrySameInlinePayloadAndCaptureStopBeforeFailure() async throws {
        let candidates: [[String: Any]] = [
            ["finishReason": "STOP"],
            ["finishReason": "STOP", "content": [:]],
            ["finishReason": "STOP", "content": ["parts": []]],
            ["finishReason": "STOP", "content": ["parts": [["text": ""]]]],
            ["finishReason": "STOP", "content": ["parts": [["text": " \n\t"]]]],
            ["finishReason": "STOP", "content": ["parts": [["thought": true, "text": "PRIVATE_THOUGHT"]]]]
        ]
        for (index, candidate) in candidates.enumerated() {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
            let response = try json(["candidates": [candidate], "usageMetadata": ["thoughtsTokenCount": 4883]])
            let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
            let collector = CloudDiagnosticCollector(history: history)
            var requests: [Data] = []
            let context = ["", "STOP", "OTHER", "PRIVATE_CONTEXT", "", "錄音主題參考"][index]
            var logs: [String] = []
            EmptyResponseProtocol.handler = { request in
                XCTAssertTrue(request.url!.path.hasSuffix("gemini-3.8-flash:generateContent"))
                requests.append(try self.json(contextRequestBody(request)))
                return (200, [:], requests.count == 1 ? response : self.success)
            }
            let result = try await CloudDiagnosticContext.$current.withValue(collector) {
                try await self.backend(session, clock: clock).transcribeDetailed(audioData: self.audio,
                    terms: ["測試術語"], customPrompt: "忠實轉錄。講者 1 是先前片段已確認的講者。",
                    recordingContext: context, timeOffsetSeconds: 1200,
                    logger: { _, message in logs.append(message) })
            }
            XCTAssertEqual(result.text, "講者 1：完整測試逐字稿。")
            XCTAssertEqual(result.metadata.retryCount, 1)
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.first, requests.last, "All audio, prompt and configuration fields must stay identical")
            let state = collector.snapshot(start: 1200, end: 2400, outcome: .completed, preparation: nil, cloud: nil)
            XCTAssertEqual(state.generationRequestCount, 2)
            XCTAssertEqual(state.retryReasons, [.emptyResponse])
            XCTAssertEqual(history.snapshot().events.count, 1)
            XCTAssertEqual(history.snapshot().events.first?.finishReason, "STOP")
            XCTAssertEqual(history.snapshot().events.first?.failure.category, .emptyResponse)
            XCTAssertEqual(history.snapshot().events.first?.responseMode, .unaryJSON)
            XCTAssertFalse(logs.joined().contains("PRIVATE_THOUGHT"))
            XCTAssertFalse(logs.joined().contains("PRIVATE_CONTEXT"))
            let saved = String(decoding: try JSONEncoder().encode(history.snapshot()), as: UTF8.self)
            XCTAssertFalse(saved.contains("PRIVATE_THOUGHT"))
            XCTAssertFalse(saved.contains("PRIVATE_CONTEXT"))
        }
    }

    func testFilesAudioIsUploadedOnceAndDeletedOnlyAfterGenerationFinishes() async throws {
        for succeeds in [true, false] {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
            var name = "", initializes = 0, uploads = 0, generates = 0, deletes = 0
            var uris: [String] = []
            EmptyResponseProtocol.handler = { request in
                if request.httpMethod == "DELETE" {
                    deletes += 1
                    XCTAssertEqual(generates, succeeds ? 2 : 4)
                    return (204, [:], Data())
                }
                if request.url!.path == "/upload/v1beta/files" {
                    initializes += 1
                    let body = try contextRequestBody(request)
                    name = try XCTUnwrap((body["file"] as? [String: Any])?["name"] as? String)
                    return (200, ["X-Goog-Upload-URL": "https://fixture.invalid/audio"], Data())
                }
                if request.url!.path == "/audio" {
                    uploads += 1
                    return (200, [:], try self.json(["file": self.file(name)]))
                }
                XCTAssertTrue(request.url!.path.contains(":generateContent"))
                XCTAssertEqual(deletes, 0, "A retry must not reference a deleted remote file")
                let body = try contextRequestBody(request)
                let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
                uris.append(try XCTUnwrap((parts.first?["fileData"] as? [String: Any])?["fileUri"] as? String))
                generates += 1
                return (200, [:], succeeds && generates == 2 ? self.success : self.empty)
            }
            do {
                let result = try await backend(session, clock: clock, files: true).transcribeDetailed(audioData: audio)
                XCTAssertTrue(succeeds)
                XCTAssertEqual(result.metadata.retryCount, 1)
            } catch let error as CloudEmptyResponseExhausted {
                XCTAssertFalse(succeeds)
                XCTAssertEqual(error.sendCount, 4)
            }
            XCTAssertEqual(initializes, 1)
            XCTAssertEqual(uploads, 1)
            XCTAssertEqual(generates, succeeds ? 2 : 4)
            XCTAssertEqual(deletes, 1)
            XCTAssertEqual(Set(uris).count, 1)
        }
    }

    func testNetworkEmptyStopAndRateLimitShareFourActualSends() async throws {
        for finalSucceeds in [true, false] {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
            let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
            let collector = CloudDiagnosticCollector(history: history)
            var sends = 0
            EmptyResponseProtocol.handler = { request in
                XCTAssertTrue(request.url!.path.hasSuffix("gemini-3.8-flash:generateContent"), "No fallback for empty STOP")
                sends += 1
                switch sends {
                case 1: throw URLError(.networkConnectionLost)
                case 2: return (200, [:], self.empty)
                case 3: return (429, [:], self.busy)
                case 4: return (200, [:], finalSucceeds ? self.success : self.empty)
                default: XCTFail("Fifth request escaped the shared quota"); return (200, [:], self.success)
                }
            }
            do {
                let result = try await CloudDiagnosticContext.$current.withValue(collector) {
                    try await self.backend(session, clock: clock).transcribeDetailed(audioData: self.audio)
                }
                XCTAssertTrue(finalSucceeds)
                XCTAssertEqual(result.metadata.retryCount, 3)
            } catch let error as CloudEmptyResponseExhausted {
                XCTAssertFalse(finalSucceeds)
                XCTAssertEqual(error.sendCount, 4)
            }
            XCTAssertEqual(sends, 4)
            XCTAssertEqual(history.snapshot().generationRequestCount, 4)
            XCTAssertGreaterThanOrEqual(clock.seconds, 140, "Network and service cooldowns must still run")
            XCTAssertTrue(history.snapshot().events.contains { $0.failure.category == .connectionLost })
            XCTAssertTrue(history.snapshot().events.contains { $0.httpStatus == 429 })
            XCTAssertTrue(history.snapshot().events.contains { $0.finishReason == "STOP" && $0.failure.category == .emptyResponse })
        }
    }

    func testRemainingQuotaAndOtherModelQuotaArePreserved() async throws {
        let clock = RecoveryClock(), session = session()
        defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
        let budget = CloudSegmentBudget(now: { clock.now })
        let network = CloudNetworkRecoveryContext(budget: budget, environment: clock.environment())
        let ledger = CloudModelAttempts()
        let quota = ledger.quota(for: "gemini-3.8-flash")
        for _ in 0..<3 { try quota.claim() }
        var sends = 0
        EmptyResponseProtocol.handler = { request in
            sends += 1
            XCTAssertTrue(request.url!.path.contains("gemini-3.8-flash:generateContent"))
            return (200, [:], self.empty)
        }
        do {
            _ = try await CloudBudgetContext.$current.withValue(budget) {
                try await CloudNetworkContext.$current.withValue(network) {
                    try await CloudNetworkContext.$segmentAttempts.withValue(ledger) {
                        try await self.backend(session, clock: clock).transcribeDetailed(audioData: self.audio)
                    }
                }
            }
            XCTFail("Expected the fourth send to exhaust the existing quota")
        } catch let error as CloudEmptyResponseExhausted { XCTAssertEqual(error.sendCount, 4) }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(quota.count, 4)
        XCTAssertEqual(ledger.quota(for: "gemini-3.6-flash").count, 0)
    }

    func testRemoteFileRebuildDoesNotResetEmptyStopQuota() async throws {
        let clock = RecoveryClock(), session = session()
        defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
        var name = "", initializes = 0, uploads = 0, sends = 0, checks = 0
        EmptyResponseProtocol.handler = { request in
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            if request.url!.path == "/upload/v1beta/files" {
                initializes += 1
                let body = try contextRequestBody(request)
                name = try XCTUnwrap((body["file"] as? [String: Any])?["name"] as? String)
                return (200, ["X-Goog-Upload-URL": "https://fixture.invalid/audio"], Data())
            }
            if request.url!.path == "/audio" {
                uploads += 1
                return (200, [:], try self.json(["file": self.file(name)]))
            }
            if request.httpMethod == "GET" { checks += 1; return (404, [:], Data()) }
            sends += 1
            if sends == 3 { return (404, [:], Data()) }
            XCTAssertLessThanOrEqual(sends, 4)
            return (200, [:], self.empty)
        }
        do {
            _ = try await backend(session, clock: clock, files: true).transcribeDetailed(audioData: audio)
            XCTFail("Expected shared generation quota exhaustion after rebuild")
        } catch let error as CloudEmptyResponseExhausted { XCTAssertEqual(error.sendCount, 4) }
        XCTAssertEqual(sends, 4)
        XCTAssertEqual(initializes, 2)
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(checks, 1)
    }

    func testOtherResponsesNeverEnterEmptyStopRetry() async throws {
        var cases: [(String, Data)] = [
            ("no candidates", Data(#"{"candidates":[]}"#.utf8)),
            ("missing finish reason", Data(#"{"candidates":[{"content":{"parts":[]}}]}"#.utf8)),
            ("blank finish reason", Data(#"{"candidates":[{"finishReason":"  "}]}"#.utf8)),
            ("invalid JSON", Data("{broken".utf8))
        ]
        for reason in ["SAFETY", "PROHIBITED_CONTENT", "RECITATION", "OTHER", "FUTURE_REASON", "MAX_TOKENS"] {
            cases.append(("candidate " + reason, try json(["candidates": [["finishReason": reason]]])))
        }
        for reason in ["OTHER", "SAFETY", "PROHIBITED_CONTENT", "PRIVATE_UNKNOWN_REASON"] {
            cases.append(("prompt " + reason, try json(["promptFeedback": ["blockReason": reason],
                                                         "candidates": [["finishReason": "STOP"]]])))
        }
        for (label, response) in cases {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
            var sends = 0
            EmptyResponseProtocol.handler = { _ in sends += 1; return (200, [:], response) }
            do {
                _ = try await backend(session, clock: clock).transcribeDetailed(audioData: audio)
                XCTFail("Accepted \(label)")
            } catch {
                XCTAssertFalse(error is CloudEmptyResponseExhausted, label)
                XCTAssertNotEqual(error as? GoogleAIStudioError, .emptyCompletedResponse, label)
                if label == "candidate MAX_TOKENS" { XCTAssertTrue(error is CloudOutputTruncatedError) }
            }
            XCTAssertEqual(sends, 1, label)
        }
    }

    func testContextEchoStopsWithoutRetryOrPublishingIt() async throws {
        let clock = RecoveryClock(), session = session()
        defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
        let context = "PRIVATE_BACKGROUND"
        let block = try CloudRecordingContext.referenceBlock(context)
        let response = try json(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": block]]]]]])
        var sends = 0
        EmptyResponseProtocol.handler = { _ in sends += 1; return (200, [:], response) }
        do {
            _ = try await backend(session, clock: clock).transcribeDetailed(audioData: audio, recordingContext: context)
            XCTFail("Context echo was accepted")
        } catch { XCTAssertTrue(error is OutputContractValidationError) }
        XCTAssertEqual(sends, 1)
    }

    func testEmptyStopRetryCannotRefreshFlashOrArgonRootBudget() async throws {
        for model in ["gemini-3.8-flash", "gemini-4-argon"] {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
            let limit = GeminiGenerationConfig.segmentBudget(modelID: model)
            let budget = CloudSegmentBudget(limit: limit, now: { clock.now })
            clock.advance(limit - .milliseconds(500))
            var sends = 0
            EmptyResponseProtocol.handler = { _ in sends += 1; return (200, [:], self.empty) }
            do {
                _ = try await CloudBudgetContext.$current.withValue(budget) {
                    try await self.backend(session, clock: clock, model: model).transcribeDetailed(audioData: self.audio)
                }
                XCTFail("Empty STOP reset an almost exhausted root budget")
            } catch let error as CloudSegmentDeadlineExceeded { XCTAssertEqual(error.stage, "backoff") }
            XCTAssertEqual(sends, 1, model)
            XCTAssertEqual(budget.remaining(), .milliseconds(500))
        }
    }

    func testCancellationDuringEmptyStopBackoffPreventsNextSend() async throws {
        let clock = RecoveryClock(), session = session()
        defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
        let waiting = expectation(description: "empty STOP retry planned")
        waiting.assertForOverFulfill = false
        let sends = RecoveryValue(0)
        EmptyResponseProtocol.handler = { _ in sends.value += 1; return (200, [:], self.empty) }
        let backend = backend(session, clock: clock)
        let task = Task {
            try await backend.transcribeDetailed(audioData: self.audio, logger: { _, message in
                if message.contains("重試") && (message.contains("STOP") || message.contains("稍後")) { waiting.fulfill() }
            })
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled backoff returned a transcript") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(sends.value, 1)
    }

    func testDeadlineAfterRetryAnnouncementPreventsNextSend() async throws {
        let clock = RecoveryClock(), session = session()
        defer { session.invalidateAndCancel(); EmptyResponseProtocol.handler = nil }
        let budget = CloudSegmentBudget(limit: .seconds(900), now: { clock.now })
        let announced = RecoveryValue(false)
        var sends = 0
        EmptyResponseProtocol.handler = { _ in sends += 1; return (200, [:], self.empty) }
        do {
            _ = try await CloudBudgetContext.$current.withValue(budget) {
                try await self.backend(session, clock: clock).transcribeDetailed(audioData: self.audio,
                    logger: { _, message in
                        if message.contains("重試") && (message.contains("STOP") || message.contains("稍後")) {
                            announced.value = true
                            clock.advance(.seconds(900))
                        }
                    })
            }
            XCTFail("Expired root sent another generation")
        } catch let error as CloudSegmentDeadlineExceeded { XCTAssertEqual(error.stage, "backoff") }
        XCTAssertTrue(announced.value)
        XCTAssertEqual(sends, 1)
    }
}
