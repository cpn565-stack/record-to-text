import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import RecordToTextCore

private final class StreamingChunkURLProtocol: URLProtocol {
    struct Step {
        enum Action {
            case response(statusCode: Int, headers: [String: String])
            case data(Data)
            case delay(TimeInterval)
            case finish
            case fail(Error)
        }
        let action: Action
    }

    static var handler: ((URLRequest) throws -> [Step])?
    static var onStopLoading: (() -> Void)?
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("StreamingChunkURLProtocol.handler not configured")
            return
        }
        let steps: [Step]
        do {
            steps = try handler(request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for step in steps {
                if self.cancelled { return }
                switch step.action {
                case let .response(statusCode, headers):
                    let response = HTTPURLResponse(
                        url: self.request.url!,
                        statusCode: statusCode,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    )!
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                case let .data(chunk):
                    self.client?.urlProtocol(self, didLoad: chunk)
                case let .delay(seconds):
                    Thread.sleep(forTimeInterval: seconds)
                case .finish:
                    if !self.cancelled {
                        self.client?.urlProtocolDidFinishLoading(self)
                    }
                    return
                case let .fail(error):
                    if !self.cancelled {
                        self.client?.urlProtocol(self, didFailWithError: error)
                    }
                    return
                }
            }
        }
    }

    override func stopLoading() {
        cancelled = true
        Self.onStopLoading?()
    }
}

final class VertexStreamingTests: XCTestCase {
    private var fakeGCloudURL: URL!

    override func setUp() {
        super.setUp()
        fakeGCloudURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vertex-stream-gcloud-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "print-access-token" ]; then
          echo mock-access-token
          exit 0
        fi
        exit 0
        """
        try! script.write(to: fakeGCloudURL, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGCloudURL.path)
    }

    override func tearDown() {
        StreamingChunkURLProtocol.handler = nil
        StreamingChunkURLProtocol.onStopLoading = nil
        if let fakeGCloudURL {
            try? FileManager.default.removeItem(at: fakeGCloudURL)
        }
        fakeGCloudURL = nil
        super.tearDown()
    }

    private func makeStreamingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingChunkURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - S01: SSE Framing, Chunking, Delimiters, BOM, Multi-data Lines & Comments

    func testS01_SSEFramingChunkingDelimitersBOMCommentsAndMultiDataLines() throws {
        var rawBytes = Data([0xEF, 0xBB, 0xBF])
        let part1 = ": comment before event\r\nevent: message\rid: 1\nretry: 3000\r\nunknown: ignored\n"
        let part2 = "data: {\r\ndata:   \"candidates\": [\r"
        let part3 = "data:     {\"index\": 0, \"content\": {\"parts\": [{\"text\": \"第一段：繁體中文與  空白\\n\"}]}}\n"
        let part4 = "data:   ]\r\ndata: }\r\n\r\n"
        let part5 = ":heartbeat\n\n"
        let part6 = "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"第二段：無損接合。\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":12,\"candidatesTokenCount\":34,\"totalTokenCount\":46}}\r\r"
        rawBytes.append(Data((part1 + part2 + part3 + part4 + part5 + part6).utf8))

        func runWithChunking(_ chunkSizes: [Int]) throws -> (eventCount: Int, text: String) {
            let accumulator = GeminiStreamingResponseAccumulator()
            var offset = 0
            var sizeIndex = 0
            while offset < rawBytes.count {
                let size = chunkSizes[sizeIndex % chunkSizes.count]
                sizeIndex += 1
                let end = min(offset + size, rawBytes.count)
                let slice = rawBytes.subdata(in: offset..<end)
                offset = end
                try accumulator.append(slice)
            }
            let json = try accumulator.finishJSON()
            let text = try GeminiResponseParser.transcript(
                fromJSON: json,
                rawByteCount: accumulator.totalReceivedBytes,
                errors: VertexAIError.self,
                httpStatusCode: 200
            ) { _, _ in }
            return (accumulator.sseEventCount, text)
        }

        let allAtOnce = try runWithChunking([rawBytes.count])
        let byteByByte = try runWithChunking([1])
        let primeChunks = try runWithChunking([3, 7, 2, 11, 5, 1, 13])

        XCTAssertEqual(allAtOnce.eventCount, 2)
        XCTAssertEqual(allAtOnce.eventCount, byteByByte.eventCount)
        XCTAssertEqual(allAtOnce.eventCount, primeChunks.eventCount)
        XCTAssertEqual(allAtOnce.text, "第一段：繁體中文與  空白\n第二段：無損接合。")
        XCTAssertEqual(byteByByte.text, allAtOnce.text)
        XCTAssertEqual(primeChunks.text, allAtOnce.text)

        // Verify `data` without colon produces empty line between two data lines
        var bareEvents: [String] = []
        let bareDataParser = GeminiSSEParser { payload in
            bareEvents.append(payload)
        }
        try bareDataParser.append(Data("data: line1\ndata\ndata: line3\n\n".utf8))
        try bareDataParser.finish()
        XCTAssertEqual(bareEvents, ["line1\n\nline3"])
    }

    // MARK: - S02: Text + Thought + Metadata-only + STOP Tail Event & Usage

    func testS02_TextThoughtMetadataOnlyAndStopTailAggregation() throws {
        let accumulator = GeminiStreamingResponseAccumulator()

        let events = [
            """
            {"candidates":[{"index":0,"content":{"parts":[{"thought":true,"text":"正在思考時間戳與分段..."},{"text":"[00:00 - 00:10]\\n講者 1：早安"}]}}],"usageMetadata":{"promptTokenCount":500,"candidatesTokenCount":10,"thoughtsTokenCount":120,"totalTokenCount":630}}
            """,
            """
            {"candidates":[{"index":0,"content":{"parts":[{"text":"，今天討論串流規格。\\n"}]}}],"usageMetadata":{"promptTokenCount":500,"candidatesTokenCount":25,"thoughtsTokenCount":120,"totalTokenCount":645}}
            """,
            """
            {"modelVersion":"gemini-3.8-flash-001","responseId":"resp-s02"}
            """,
            """
            {"candidates":[{"index":0,"content":{"parts":[]},"finishReason":"STOP"}]}
            """,
            """
            {"usageMetadata":{"promptTokenCount":500,"candidatesTokenCount":28,"thoughtsTokenCount":120,"totalTokenCount":648}}
            """
        ]
        for event in events {
            let line = event.replacingOccurrences(of: "\n", with: "")
            try accumulator.append(Data("data: \(line)\n\n".utf8))
        }

        let json = try accumulator.finishJSON()
        let text = try GeminiResponseParser.transcript(
            fromJSON: json,
            rawByteCount: accumulator.totalReceivedBytes,
            errors: VertexAIError.self,
            httpStatusCode: 200
        ) { _, _ in }
        XCTAssertEqual(text, "[00:00 - 00:10]\n講者 1：早安，今天討論串流規格。")
        XCTAssertFalse(text.contains("正在思考"))

        let metadata = GeminiResponseMetadataParser.makeMetadata(
            fromJSON: json,
            requestedModelID: "gemini-3.8-flash",
            effectiveModelID: "gemini-3.8-flash",
            retryCount: 0,
            fallbackReason: nil,
            thinkingLevel: .high,
            latencySeconds: 1.5
        )
        XCTAssertEqual(metadata.usage?.promptTokenCount, 500)
        XCTAssertEqual(metadata.usage?.candidatesTokenCount, 28)
        XCTAssertEqual(metadata.usage?.thoughtsTokenCount, 120)
        XCTAssertEqual(metadata.usage?.totalTokenCount, 648)
        XCTAssertEqual(metadata.responseID, "resp-s02")
        XCTAssertEqual(metadata.modelVersion, "gemini-3.8-flash-001")
    }

    // MARK: - S03: Multiple Candidates, Duplicate Text Deltas & Omitted Index

    func testS03_MultipleCandidatesDuplicateTextDeltasAndOmittedIndex() throws {
        let accumulator = GeminiStreamingResponseAccumulator()

        let sse =
            "data: {\"candidates\":[{\"index\":1,\"content\":{\"parts\":[{\"text\":\"候選一不應混入\"}]}},{\"index\":0,\"content\":{\"parts\":[{\"text\":\"重複詞彙\"}]}}]}\n\n" +
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"重複詞彙\"}]}}],\"usageMetadata\":{\"totalTokenCount\":10}}\n\n" +
            "data: {\"candidates\":[{\"index\":1,\"finishReason\":\"SAFETY\"},{\"index\":0,\"finishReason\":\"STOP\"}]}\n\n"
        try accumulator.append(Data(sse.utf8))
        let json = try accumulator.finishJSON()
        let text = try GeminiResponseParser.transcript(
            fromJSON: json,
            rawByteCount: accumulator.totalReceivedBytes,
            errors: VertexAIError.self,
            httpStatusCode: 200
        ) { _, _ in }
        XCTAssertEqual(text, "重複詞彙重複詞彙")

        // Multiple candidates all omitting index -> none selected as candidate 0, rejected by parser as empty/invalid
        let nonZeroAccumulator = GeminiStreamingResponseAccumulator()
        let nonZeroSSE = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"A\"}]},\"finishReason\":\"STOP\"},{\"content\":{\"parts\":[{\"text\":\"B\"}]},\"finishReason\":\"STOP\"}]}\n\n"
        try nonZeroAccumulator.append(Data(nonZeroSSE.utf8))
        let nonZeroJSON = try nonZeroAccumulator.finishJSON()
        XCTAssertThrowsError(try GeminiResponseParser.transcript(
            fromJSON: nonZeroJSON,
            rawByteCount: nonZeroAccumulator.totalReceivedBytes,
            errors: VertexAIError.self,
            httpStatusCode: 200
        ) { _, _ in })
    }

    // MARK: - S04: Mid-stream -1005 or Normal EOF Without FinishReason

    func testS04_MidStreamConnectionLostOrEOFWithoutFinishReasonRetriesAndDiscardsPartialText() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let clock = RecoveryClock()
        var attempt = 0

        StreamingChunkURLProtocol.handler = { _ in
            attempt += 1
            if attempt == 1 {
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"第一輪殘留半截文字\"}]}}]}\n\n".utf8))),
                    .init(action: .fail(URLError(.networkConnectionLost)))
                ]
            }
            if attempt == 2 {
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"第二輪無終止原因文字\"}]}}]}\n\n".utf8))),
                    .init(action: .finish)
                ]
            }
            return [
                .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"第三輪完整逐字稿前半，\"}]}}]}\n\n".utf8))),
                .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"後半完整結束。\"}]},\"finishReason\":\"STOP\"}]}\n\n".utf8))),
                .init(action: .finish)
            ]
        }

        let backend = VertexAIGeminiBackend(
            networkEnvironment: clock.environment(),
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash")
        )
        let result = try await backend.transcribeDetailed(audioData: Data("audio".utf8))
        XCTAssertEqual(attempt, 3)
        XCTAssertEqual(result.text, "第三輪完整逐字稿前半，後半完整結束。")
        XCTAssertFalse(result.text.contains("第一輪"))
        XCTAssertFalse(result.text.contains("第二輪"))
    }

    // MARK: - S05: Post-STOP Disconnect, Incomplete SSE Event, Malformed JSON/UTF-8 & Contradictory Tail Events

    func testS05_PostStopDisconnectIncompleteSSEMalformedJSONInvalidUTF8AndContradictoryTailEvents() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let clock = RecoveryClock()

        // 1. Post-STOP disconnect and incomplete SSE event at EOF both retry as transport/incomplete stream
        var attempt = 0
        StreamingChunkURLProtocol.handler = { _ in
            attempt += 1
            if attempt == 1 {
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"STOP後斷線文字\"}]},\"finishReason\":\"STOP\"}]}\n\n".utf8))),
                    .init(action: .fail(URLError(.networkConnectionLost)))
                ]
            }
            if attempt == 2 {
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"未封閉事件\"}]},\"finishReason\":\"STOP\"}]}\n".utf8))),
                    .init(action: .finish)
                ]
            }
            return [
                .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"最終乾淨完成\"}]},\"finishReason\":\"STOP\"}]}\n\n".utf8))),
                .init(action: .finish)
            ]
        }

        let backend = VertexAIGeminiBackend(
            networkEnvironment: clock.environment(),
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash")
        )
        let text = try await backend.transcribe(audioData: Data("audio".utf8))
        XCTAssertEqual(attempt, 3)
        XCTAssertEqual(text, "最終乾淨完成")

        // 2. Malformed JSON, invalid UTF-8, post-STOP text delta, and contradictory finishReason must fail immediately without retry
        let nonRetryableStreams: [Data] = [
            Data("data: {bad json\n\n".utf8),
            Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0xFF, 0xFE, 0x0A, 0x0A]),
            Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"A\"}]},\"finishReason\":\"STOP\"}]}\n\ndata: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"B\"}]}}]}\n\n".utf8),
            Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"A\"}]},\"finishReason\":\"STOP\"}]}\n\ndata: {\"candidates\":[{\"finishReason\":\"MAX_TOKENS\"}]}\n\n".utf8)
        ]

        for payload in nonRetryableStreams {
            var count = 0
            StreamingChunkURLProtocol.handler = { _ in
                count += 1
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(payload)),
                    .init(action: .finish)
                ]
            }
            do {
                _ = try await backend.transcribe(audioData: Data("audio".utf8))
                XCTFail("Expected non-retryable failure for payload")
            } catch is VertexAIError {
                XCTAssertEqual(count, 1)
            }
        }
    }

    // MARK: - S06: FinishReasons MAX_TOKENS, CONTINUATION, SAFETY, OTHER & Unknown

    func testS06_FinishReasonsMaxTokensContinuationSafetyOtherAndUnknown() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let backend = VertexAIGeminiBackend(
            networkEnvironment: RecoveryClock().environment(),
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash", fallbackPolicy: .flashOnly)
        )

        var maxTokenRequests = 0
        StreamingChunkURLProtocol.handler = { _ in
            maxTokenRequests += 1
            let sse = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"截斷文字\"}]},\"finishReason\":\"MAX_TOKENS\"}]}\n\n"
            return [
                .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                .init(action: .data(Data(sse.utf8))),
                .init(action: .finish)
            ]
        }
        do {
            _ = try await backend.transcribe(audioData: Data("audio".utf8))
            XCTFail("Expected CloudOutputTruncatedError for MAX_TOKENS")
        } catch let error as CloudOutputTruncatedError {
            XCTAssertEqual(error.partialText, "截斷文字")
        }
        XCTAssertEqual(maxTokenRequests, 1)

        for reason in ["CONTINUATION", "SAFETY", "OTHER", "FUTURE_UNKNOWN_REASON"] {
            var count = 0
            StreamingChunkURLProtocol.handler = { _ in
                count += 1
                let sse = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"不可發布\"}]},\"finishReason\":\"\(reason)\"}]}\n\n"
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data(sse.utf8))),
                    .init(action: .finish)
                ]
            }
            do {
                _ = try await backend.transcribe(audioData: Data("audio".utf8))
                XCTFail("Expected rejection for \(reason)")
            } catch is VertexAIError {
                XCTAssertEqual(count, 1, "Unexpected retry for \(reason)")
            }
        }
    }

    // MARK: - S07: Empty STOP & Heartbeat/Thought Only Respect Retry Quota and Root Budget

    func testS07_EmptyStopAndHeartbeatOrThoughtOnlyRespectRetryAndRootBudget() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let auth = GCloudAuthService(customGCloudPath: fakeGCloudURL.path)
        _ = try await auth.getAccessToken()
        let backend = VertexAIGeminiBackend(
            authService: auth,
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash", fallbackPolicy: .flashOnly)
        )

        var sends = 0
        StreamingChunkURLProtocol.handler = { _ in
            sends += 1
            return [
                .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                .init(action: .data(Data(":heartbeat\n\n".utf8))),
                .init(action: .delay(0.1)),
                .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"thinking\"}]}}]}\n\n".utf8))),
                .init(action: .delay(0.5)),
                .init(action: .finish)
            ]
        }

        do {
            _ = try await CloudBudgetContext.$current.withValue(CloudSegmentBudget(limit: .milliseconds(250))) {
                try await backend.transcribe(audioData: Data("audio".utf8))
            }
            XCTFail("Expected root budget deadline exceeded")
        } catch let error as CloudSegmentDeadlineExceeded {
            XCTAssertEqual(error.stage, "generation")
        }
        XCTAssertEqual(sends, 1)
    }

    // MARK: - S08: HTTP 401 -> Refresh -> Disconnect -> POSIX Reset Share 4-Send Quota

    func testS08_HTTP401RefreshDisconnectAndPOSIXResetShareFourGenerationSends() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let clock = RecoveryClock()
        var sends = 0

        StreamingChunkURLProtocol.handler = { _ in
            sends += 1
            switch sends {
            case 1:
                return [
                    .init(action: .response(statusCode: 401, headers: ["Content-Type": "application/json"])),
                    .init(action: .data(Data(#"{"error":{"code":401,"message":"Token expired"}}"#.utf8))),
                    .init(action: .finish)
                ]
            case 2:
                return [
                    .init(action: .fail(NSError(domain: NSPOSIXErrorDomain, code: 40)))
                ]
            case 3:
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"半截\"}]}}]}\n\n".utf8))),
                    .init(action: .fail(URLError(.networkConnectionLost)))
                ]
            default:
                return [
                    .init(action: .fail(URLError(.networkConnectionLost)))
                ]
            }
        }

        let backend = VertexAIGeminiBackend(
            networkEnvironment: clock.environment(),
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash", fallbackPolicy: .flashOnly)
        )

        do {
            _ = try await backend.transcribe(audioData: Data("audio".utf8))
            XCTFail("Expected network recovery exhaustion after 4 sends")
        } catch let error as CloudNetworkRecoveryExhausted {
            XCTAssertEqual(error.recovery.lastFailure?.category, .connectionLost)
            XCTAssertEqual(error.recovery.stopReason, .attemptsExhausted)
        }
        XCTAssertEqual(sends, 4)
    }

    // MARK: - S09: HTTP 429 JSON & HTTP 200 SSE RESOURCE_EXHAUSTED Share Service Cooldown

    func testS09_HTTP429JSONAndHTTP200SSEErrorResourceExhaustedShareServiceCooldown() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let clock = RecoveryClock()
        var sendTimes: [Double] = []

        StreamingChunkURLProtocol.handler = { _ in
            sendTimes.append(clock.seconds)
            if sendTimes.count == 1 {
                return [
                    .init(action: .response(statusCode: 429, headers: ["Content-Type": "application/json", "Retry-After": "45"])),
                    .init(action: .data(Data(#"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Rate limit"}}"#.utf8))),
                    .init(action: .finish)
                ]
            }
            if sendTimes.count == 2 {
                let sseError = #"data: {"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota busy","details":[{"retryDelay":"75s"}]}}"# + "\n\n"
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data(sseError.utf8))),
                    .init(action: .finish)
                ]
            }
            let sseSuccess = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"冷卻後成功\"}]},\"finishReason\":\"STOP\"}]}\n\n"
            return [
                .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                .init(action: .data(Data(sseSuccess.utf8))),
                .init(action: .finish)
            ]
        }

        let backend = VertexAIGeminiBackend(
            networkEnvironment: clock.environment(),
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash")
        )
        let result = try await backend.transcribeDetailed(audioData: Data("audio".utf8))
        XCTAssertEqual(sendTimes, [0, 45, 120])
        XCTAssertEqual(result.text, "冷卻後成功")
        XCTAssertEqual(result.metadata.retryCount, 2)
    }

    // MARK: - S10: Cancellation in All States & Race With Completion

    func testS10_CancellationBeforeStartWaitingFirstByteMidStreamInCooldownAndRaceWithCompletion() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let auth = GCloudAuthService(customGCloudPath: fakeGCloudURL.path)
        _ = try await auth.getAccessToken()
        let backend = VertexAIGeminiBackend(
            authService: auth,
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash")
        )

        var preCancelSends = 0
        StreamingChunkURLProtocol.handler = { _ in
            preCancelSends += 1
            return [.init(action: .finish)]
        }
        let preCancelledTask = Task {
            try await backend.transcribe(audioData: Data("audio".utf8))
        }
        preCancelledTask.cancel()
        do {
            _ = try await preCancelledTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError { }
        XCTAssertEqual(preCancelSends, 0)

        let chunkReceived = expectation(description: "first SSE chunk received")
        let taskStopped = expectation(description: "URLProtocol stopLoading called")
        StreamingChunkURLProtocol.onStopLoading = {
            taskStopped.fulfill()
        }
        StreamingChunkURLProtocol.handler = { _ in
            chunkReceived.fulfill()
            return [
                .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"取消前文字\"}]}}]}\n\n".utf8))),
                .init(action: .delay(5.0)),
                .init(action: .finish)
            ]
        }

        let midStreamTask = Task {
            try await backend.transcribe(audioData: Data("audio".utf8))
        }
        await fulfillment(of: [chunkReceived], timeout: 2.0)
        midStreamTask.cancel()
        await fulfillment(of: [taskStopped], timeout: 2.0)
        do {
            _ = try await midStreamTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError { }
    }

    // MARK: - S11: Resource Limits (Single Event, Total Response, Publishable Text)

    func testS11_SingleEventTotalResponseAndPublishableTextLimitsEnforcedImmediately() throws {
        let smallLimits = GeminiStreamingLimits(
            maxSingleEventBytes: 64,
            maxTotalResponseBytes: 128,
            maxPublishableTextBytes: 32
        )

        // 1. Single event exceeds 64 bytes
        let eventLimitParser = GeminiSSEParser(limits: smallLimits) { _ in }
        let oversizedLine = "data: " + String(repeating: "x", count: 70) + "\n\n"
        XCTAssertThrowsError(try eventLimitParser.append(Data(oversizedLine.utf8))) { error in
            XCTAssertEqual(error as? GeminiSSEError, .singleEventTooLarge(limitBytes: 64))
        }

        // 2. Total stream exceeds 128 bytes across multiple smaller events
        let totalLimitParser = GeminiSSEParser(limits: smallLimits) { _ in }
        let smallEvent = "data: " + String(repeating: "a", count: 40) + "\n\n"
        try totalLimitParser.append(Data(smallEvent.utf8))
        try totalLimitParser.append(Data(smallEvent.utf8))
        XCTAssertThrowsError(try totalLimitParser.append(Data(smallEvent.utf8))) { error in
            XCTAssertEqual(error as? GeminiSSEError, .totalResponseTooLarge(limitBytes: 128))
        }

        // 3. Publishable text exceeds 32 bytes
        let textLimitAccumulator = GeminiStreamingResponseAccumulator(limits: smallLimits)
        let eventSSE = "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"01234567890123456789\"}]}}]}\n\n"
        let bigLimitsForEvent = GeminiStreamingLimits(
            maxSingleEventBytes: 4096,
            maxTotalResponseBytes: 8192,
            maxPublishableTextBytes: 32
        )
        let textAcc = GeminiStreamingResponseAccumulator(limits: bigLimitsForEvent)
        try textAcc.append(Data(eventSSE.utf8))
        XCTAssertThrowsError(try textAcc.append(Data(eventSSE.utf8))) { error in
            XCTAssertEqual(error as? GeminiSSEError, .publishableTextTooLarge(limitBytes: 32))
        }
        _ = textLimitAccumulator
    }

    // MARK: - S12: Endpoint Stage Routing, Argon Timeout & Event Count vs Request Count

    func testS12_EndpointStageRoutingArgonTimeoutAndEventCountDoesNotInflateRequestCount() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        var seenEndpoints: [String] = []

        var streamThinkingConfig: [String: Any]?
        var unaryThinkingConfig: [String: Any]?

        StreamingChunkURLProtocol.handler = { request in
            let urlString = request.url!.absoluteString
            seenEndpoints.append(urlString)
            let bodyData: Data? = {
                if let body = request.httpBody { return body }
                guard let stream = request.httpBodyStream else { return nil }
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read > 0 { data.append(buffer, count: read) } else { break }
                }
                return data
            }()
            let parsedBody = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let genConfig = parsedBody?["generationConfig"] as? [String: Any]
            let thinkingCfg = genConfig?["thinkingConfig"] as? [String: Any]

            if urlString.contains(":streamGenerateContent?alt=sse") {
                streamThinkingConfig = thinkingCfg
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"think\"}]}}]}\n\n".utf8))),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"第一段 \"}]}}]}\n\n".utf8))),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"第二段\"}]}}]}\n\n".utf8))),
                    .init(action: .data(Data("data: {\"candidates\":[{\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"totalTokenCount\":15}}\n\n".utf8))),
                    .init(action: .finish)
                ]
            } else {
                unaryThinkingConfig = thinkingCfg
                XCTAssertTrue(urlString.contains(":generateContent"))
                XCTAssertFalse(urlString.contains("streamGenerateContent"))
                let unary = #"{"candidates":[{"content":{"parts":[{"text":"摘要內容"}]},"finishReason":"STOP"}]}"#
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "application/json"])),
                    .init(action: .data(Data(unary.utf8))),
                    .init(action: .finish)
                ]
            }
        }

        XCTAssertEqual(GeminiGenerationConfig.requestTimeout(modelID: "gemini-4-argon"), 1_200)
        XCTAssertEqual(GeminiGenerationConfig.requestTimeout(modelID: "gemini-3.8-flash"), 300)

        let backend = VertexAIGeminiBackend(
            networkEnvironment: RecoveryClock().environment(),
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-4-argon")
        )
        let collector = CloudDiagnosticCollector()
        let result = try await CloudDiagnosticContext.$current.withValue(collector) {
            try await backend.transcribeDetailed(audioData: Data("audio".utf8))
        }
        let summary = try await backend.summarizeTranscript("第一段 第二段")
        XCTAssertEqual(result.text, "第一段 第二段")
        XCTAssertEqual(summary, "摘要內容")
        XCTAssertEqual(seenEndpoints.count, 2)
        XCTAssertEqual(streamThinkingConfig?["thinkingLevel"] as? String, "high")
        XCTAssertEqual(streamThinkingConfig?["includeThoughts"] as? Bool, true)
        XCTAssertEqual(unaryThinkingConfig?["thinkingLevel"] as? String, "high")
        XCTAssertNil(unaryThinkingConfig?["includeThoughts"])

        let diag = collector.snapshot(start: 0, end: 5, outcome: .completed, preparation: nil, cloud: result.metadata.latencySeconds)
        XCTAssertEqual(diag.generationRequestCount, 1, "Multiple SSE events must not inflate generationRequestCount")
        XCTAssertEqual(diag.attempts?.count, 1)
        XCTAssertEqual(diag.attempts?.first?.responseMode, .geminiSSE)
        XCTAssertEqual(diag.attempts?.first?.stage, .generation)
        XCTAssertEqual(diag.attempts?.first?.sseEventCount, 4)
        XCTAssertEqual(diag.attempts?.first?.finishReason, "STOP")
        XCTAssertNotNil(diag.attempts?.first?.firstResponseByteSeconds)
        XCTAssertNotNil(diag.attempts?.first?.firstTextDeltaSeconds)
        XCTAssertNotNil(diag.attempts?.first?.completedSeconds)
    }

    // MARK: - S13: GCS Upload Reused Across Streaming Generation Retry & Cleaned Up

    func testS13_GCSUploadReusedAcrossStreamingGenerationRetryAndCleanedUp() async throws {
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let clock = RecoveryClock()
        let audio = Data("gcs-test-audio".utf8)
        var uploads = 0, generations = 0, deletes = 0

        StreamingChunkURLProtocol.handler = { request in
            let url = request.url!
            if request.httpMethod == "DELETE" {
                deletes += 1
                return [
                    .init(action: .response(statusCode: 204, headers: [:])),
                    .init(action: .finish)
                ]
            }
            if url.path.hasPrefix("/upload/storage/") {
                uploads += 1
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "application/json"])),
                    .init(action: .data(Data("{}".utf8))),
                    .init(action: .finish)
                ]
            }
            if url.path.contains(":streamGenerateContent") {
                generations += 1
                if generations == 1 {
                    return [
                        .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                        .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"半段\"}]}}]}\n\n".utf8))),
                        .init(action: .fail(URLError(.networkConnectionLost)))
                    ]
                }
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"GCS重試成功\"}]},\"finishReason\":\"STOP\"}]}\n\n".utf8))),
                    .init(action: .finish)
                ]
            }
            return [
                .init(action: .response(statusCode: 404, headers: [:])),
                .init(action: .finish)
            ]
        }

        let backend = VertexAIGeminiBackend(
            networkEnvironment: clock.environment(),
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash", gcsBucket: "test-bucket")
        )
        let text = try await backend.transcribe(audioData: audio)
        XCTAssertEqual(text, "GCS重試成功")
        XCTAssertEqual(uploads, 1, "GCS upload must be reused across streaming generation retry")
        XCTAssertEqual(generations, 2)
        XCTAssertEqual(deletes, 1, "GCS object must be deleted after completion")
    }

    // MARK: - S14: Multi-Segment Checkpoint Preserves Segment 1 When Segment 2 Stream Fails & Resumes Cleanly

    func testS14_MultiSegmentCheckpointPreservesSegment1WhenSegment2StreamFailsAndResumesCleanly() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let outputDirectory = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let candidate = RuntimeEnvironment.candidate(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: true),
            bundledHelperURL: nil
        )
        guard FileManager.default.isExecutableFile(atPath: candidate.ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: candidate.ffprobe.path),
              FileManager.default.isExecutableFile(atPath: candidate.opencc.path)
        else {
            return XCTFail("Required audio tools are not available")
        }

        let sourceURL = root.appendingPathComponent("two_segments.wav")
        _ = try await ProcessRunner().run(
            executableURL: candidate.ffmpeg,
            arguments: ["-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-y", sourceURL.path]
        )

        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let clock = RecoveryClock()

        var run1Requests = 0
        StreamingChunkURLProtocol.handler = { _ in
            run1Requests += 1
            if run1Requests == 1 {
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"父段截斷\"}]},\"finishReason\":\"MAX_TOKENS\"}]}\n\n".utf8))),
                    .init(action: .finish)
                ]
            }
            if run1Requests == 2 {
                return [
                    .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                    .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"[00:00 - 00:02]\\n講者 1：第一段已完成且寫入檢查點。\"}]},\"finishReason\":\"STOP\"}]}\n\n".utf8))),
                    .init(action: .finish)
                ]
            }
            return [
                .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"第二段不應保留的半截稿\"}]}}]}\n\n".utf8))),
                .init(action: .fail(URLError(.networkConnectionLost)))
            ]
        }

        let backend = VertexAIGeminiBackend(
            networkEnvironment: clock.environment(),
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: session,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash", fallbackPolicy: .disabled)
        )
        let engine = TranscriptionEngine(
            cloudNetworkEnvironment: clock.environment(),
            runtime: candidate,
            paths: paths,
            vertexAIBackend: backend,
            cloudAdaptiveMinimumChildDuration: 1.0
        )
        let snapshot = JobSnapshot(
            modelID: "gemini-3.8-flash",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "忠實轉錄",
            outputLocationMode: .fixedDirectory,
            outputDirectory: outputDirectory.path,
            keepRawTranscript: false,
            backendType: .vertexAI,
            vertexAIProjectID: "mock-project",
            vertexAILocation: "global",
            vertexAIModelID: "gemini-3.8-flash"
        )
        let job = TranscriptionJob(id: UUID(), sourcePath: sourceURL.path, snapshot: snapshot)

        var recoveryDir: URL?
        do {
            _ = try await engine.run(job: job) { _ in }
            XCTFail("Expected Run 1 to pause on Segment 2 network failure")
        } catch let error as PipelineExecutionError {
            recoveryDir = error.recoveryDirectory
        }
        XCTAssertEqual(run1Requests, 6, "1 parent + 1 left child + 4 right child attempts")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).count, 0, "No final TXT may be published before all segments complete")

        let unwrappedRecovery = try XCTUnwrap(recoveryDir)
        let manifestData = try Data(contentsOf: unwrappedRecovery.appendingPathComponent(RecoveryScanner.segmentManifestFileName))
        let manifest = try JSONDecoder().decode(AudioSegmentManifest.self, from: manifestData)
        XCTAssertEqual(manifest.segments.count, 2)
        XCTAssertEqual(manifest.segments[0].status, .completed)
        XCTAssertEqual(manifest.segments[1].status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.segments[1].outputPath), "Failed streaming segment must not write partial transcript to disk")

        var run2Requests = 0
        StreamingChunkURLProtocol.handler = { _ in
            run2Requests += 1
            return [
                .init(action: .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"])),
                .init(action: .data(Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"[00:02 - 00:04]\\n講者 1：第二段重啟後完整完成。\"}]},\"finishReason\":\"STOP\"}]}\n\n".utf8))),
                .init(action: .finish)
            ]
        }

        var resumedJob = job
        resumedJob.resumeFromRecoveryDirectory = unwrappedRecovery.path
        let resumedResult = try await engine.run(job: resumedJob) { _ in }
        XCTAssertEqual(run2Requests, 1, "Resume must only send the unfinished Segment 2")
        let finalTranscript = try String(contentsOf: resumedResult.outputURL, encoding: .utf8)
        XCTAssertTrue(finalTranscript.contains("第一段已完成且寫入檢查點"))
        XCTAssertTrue(finalTranscript.contains("第二段重啟後完整完成"))
        XCTAssertFalse(finalTranscript.contains("第二段不應保留的半截稿"))
    }

    // MARK: - S15: Legacy Journal, Recent History & Checkpoint Backward Compatibility

    func testS15_LegacyJournalRecentHistoryAndCheckpointDecodeWithoutNewStreamingFields() throws {
        let legacyDiagnosticJSON = """
        {
          "startSeconds": 0,
          "endSeconds": 60,
          "reusedFromCheckpoint": false,
          "stageTimings": [{"stage": "generation", "seconds": 12.3}],
          "outcome": "completed",
          "retryReasons": []
        }
        """
        let decodedDiag = try JSONDecoder().decode(CloudSegmentDiagnostic.self, from: Data(legacyDiagnosticJSON.utf8))
        XCTAssertEqual(decodedDiag.outcome, .completed)
        XCTAssertNil(decodedDiag.attempts)

        let legacyHistoryJSON = """
        {
          "schemaVersion": 1,
          "jobID": "00000000-0000-0000-0000-000000000001",
          "backend": "vertexAI",
          "totalEventCount": 1,
          "generationRequestCount": 1,
          "events": [{
            "timestamp": 0,
            "attempt": 1,
            "completedSegmentCount": 0,
            "resultUnknown": true,
            "failure": {
              "category": "connectionLost",
              "stage": "generation",
              "errorChain": [{"domain": "NSURLErrorDomain", "code": -1005}]
            }
          }]
        }
        """
        let decodedHistory = try JSONDecoder().decode(CloudFailureHistory.self, from: Data(legacyHistoryJSON.utf8))
        XCTAssertEqual(decodedHistory.events.count, 1)
        XCTAssertNil(decodedHistory.events.first?.responseMode)
        XCTAssertNil(decodedHistory.events.first?.sseEventCount)
    }

    // MARK: - S16: Real Localhost HTTP Server Streaming Delayed SSE Across >60 Seconds & Cancellation/Deadline

    func testS16_RealLoopbackHTTPServerStreamsDelayedSSEChunksOverSixtySecondsAndSupportsCancellation() async throws {
        let server = try LoopbackSSEServer { clientSocket in
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            guard Self.writeAll(clientSocket, Data(header.utf8)) else { return }

            Thread.sleep(forTimeInterval: 0.1)
            let chunk1 = "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"跨六十秒真實串流第一塊，\"}]}}]}\r\n\r\n"
            guard Self.writeAll(clientSocket, Data(chunk1.utf8)) else { return }

            Thread.sleep(forTimeInterval: 20.0)
            let chunk2 = ":keepalive\r\n\r\ndata: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"第二塊（20秒），\"}]}}]}\r\n\r\n"
            guard Self.writeAll(clientSocket, Data(chunk2.utf8)) else { return }

            Thread.sleep(forTimeInterval: 20.0)
            let chunk3 = "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"第三塊（40秒），\"}]}}]}\r\n\r\n"
            guard Self.writeAll(clientSocket, Data(chunk3.utf8)) else { return }

            Thread.sleep(forTimeInterval: 20.5)
            let chunk4 = "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"第四塊（超過60秒完成）。\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":20,\"totalTokenCount\":30}}\r\n\r\n"
            _ = Self.writeAll(clientSocket, Data(chunk4.utf8))
        }
        defer { server.stop() }

        let requestURL = URL(string: "http://127.0.0.1:\(server.port)/v1/streamGenerateContent?alt=sse")!
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 1_200

        let collector = CloudDiagnosticCollector()
        let start = ContinuousClock.now
        let (data, response) = try await CloudDiagnosticContext.$current.withValue(collector) {
            try await GeminiTransportHelper.budgetedData(
                session: .shared,
                request: request,
                stage: "generation",
                responseMode: .geminiSSE
            )
        }
        let elapsedSeconds = Double(start.duration(to: .now).components.seconds)
        XCTAssertGreaterThanOrEqual(elapsedSeconds, 60.0, "S16 stream must sustain across >60 seconds without truncation")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let text = try GeminiResponseParser.transcript(
            from: data,
            errors: VertexAIError.self,
            httpStatusCode: 200
        ) { _, _ in }
        XCTAssertEqual(text, "跨六十秒真實串流第一塊，第二塊（20秒），第三塊（40秒），第四塊（超過60秒完成）。")

        let diag = collector.snapshot(start: 0, end: elapsedSeconds, outcome: .completed, preparation: nil, cloud: elapsedSeconds)
        let attemptDiag = try XCTUnwrap(diag.attempts?.first)
        let firstByte = try XCTUnwrap(attemptDiag.firstResponseByteSeconds)
        let completed = try XCTUnwrap(attemptDiag.completedSeconds)
        XCTAssertLessThan(firstByte, 5.0, "First response bytes must arrive long before 60s EOF")
        XCTAssertGreaterThan(completed - firstByte, 55.0, "Incremental callbacks must span the >60s stream window")
        XCTAssertEqual(attemptDiag.sseEventCount, 4)

        // Part B: Verify deadline termination against a stalled loopback server
        let stalledServer = try LoopbackSSEServer { clientSocket in
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
            guard Self.writeAll(clientSocket, Data(header.utf8)) else { return }
            let chunk1 = "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"半截\"}]}}]}\r\n\r\n"
            guard Self.writeAll(clientSocket, Data(chunk1.utf8)) else { return }
            Thread.sleep(forTimeInterval: 10.0)
        }
        defer { stalledServer.stop() }

        var stalledRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(stalledServer.port)/v1/streamGenerateContent?alt=sse")!)
        stalledRequest.httpMethod = "POST"
        stalledRequest.httpBody = Data("{}".utf8)

        do {
            _ = try await CloudBudgetContext.$current.withValue(CloudSegmentBudget(limit: .milliseconds(400))) {
                try await GeminiTransportHelper.budgetedData(
                    session: .shared,
                    request: stalledRequest,
                    stage: "generation",
                    responseMode: .geminiSSE
                )
            }
            XCTFail("Expected deadline exceeded on stalled loopback SSE server")
        } catch let error as CloudSegmentDeadlineExceeded {
            XCTAssertEqual(error.stage, "generation")
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var written = 0
            while written < rawBuffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }
}

private final class LoopbackSSEServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(fd, $0, &clientLen)
                    }
                }
                guard clientFD >= 0 else { break }
                var noSigPipe: Int32 = 1
                _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var buf = [UInt8](repeating: 0, count: 4096)
                _ = Darwin.read(clientFD, &buf, buf.count)
                handler(clientFD)
                Darwin.close(clientFD)
                if self?.isStopped == true { break }
            }
        }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    func stop() {
        let shouldClose = lock.withLock { () -> Bool in
            if stopped { return false }
            stopped = true
            return true
        }
        if shouldClose {
            Darwin.close(listenFD)
        }
    }
}
