import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import RecordToTextCore

private final class RetryLogProtocol: URLProtocol {
    enum Action {
        case response(status: Int, headers: [String: String], body: Data, chunks: [Data] = [])
        case error(Error)
    }

    static var handler: ((URLRequest) throws -> Action)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            switch try handler(request) {
            case let .response(status, headers, body, chunks):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !chunks.isEmpty {
                    for chunk in chunks {
                        client?.urlProtocol(self, didLoad: chunk)
                    }
                } else if !body.isEmpty {
                    client?.urlProtocol(self, didLoad: body)
                }
                client?.urlProtocolDidFinishLoading(self)
            case let .error(error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RetryLogClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Double = 0

    var now: ContinuousClock.Instant {
        lock.withLock { start.advanced(by: .seconds(elapsed)) }
    }

    func advance(_ duration: Duration) {
        lock.withLock { elapsed += duration.secondsValue }
    }

    func environment(
        sessionFactory: (@Sendable ([AnyClass]?) -> URLSession)? = nil
    ) -> CloudNetworkEnvironment {
        CloudNetworkEnvironment(
            now: { self.now },
            sleep: { duration in
                self.advance(duration)
                await Task.yield()
                try Task.checkCancellation()
            },
            path: { .satisfied },
            jitter: { 0 },
            session: sessionFactory ?? { GeminiTransportHelper.makeEphemeralRetrySession(protocolClasses: $0) }
        )
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        storage = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

final class CloudTransportRetryLoggingTests: XCTestCase {
    private var fakeGCloudURL: URL!

    override func setUp() {
        super.setUp()
        fakeGCloudURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-log-gcloud-\(UUID().uuidString)")
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
        RetryLogProtocol.handler = nil
        if let fakeGCloudURL {
            try? FileManager.default.removeItem(at: fakeGCloudURL)
        }
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetryLogProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeVertexBackend(
        clock: RetryLogClock,
        session: URLSession
    ) -> VertexAIGeminiBackend {
        let auth = GCloudAuthService(
            customGCloudPath: fakeGCloudURL.path,
            runner: ProcessRunner()
        )
        return VertexAIGeminiBackend(
            networkEnvironment: clock.environment(),
            authService: auth,
            urlSession: session,
            configuration: .init(
                projectID: "fixture-project",
                location: "global",
                modelID: "gemini-4-hydrogen",
                thinkingLevel: .high
            )
        )
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func sseEvent(_ object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    func testVertexIncompleteStreamLogsRetryCauseAndSucceedsOnSecondAttempt() async throws {
        let clock = RetryLogClock()
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let attempts = LockedBox(0)
        let thoughtChunk = try sseEvent([
            "candidates": [["index": 0, "content": ["role": "model", "parts": [["thought": true, "text": "internal thought"]]]]]
        ])
        let finalChunk = try sseEvent([
            "candidates": [[
                "index": 0,
                "finishReason": "STOP",
                "content": ["role": "model", "parts": [["text": "[00:00 - 00:05]\n講者 1：測試完成。"]]]
            ]]
        ])

        RetryLogProtocol.handler = { _ in
            let attempt = attempts.withLock { value -> Int in
                value += 1
                return value
            }
            if attempt == 1 {
                return .response(
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: Data(),
                    chunks: [thoughtChunk]
                )
            }
            return .response(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(),
                chunks: [finalChunk]
            )
        }

        let backend = makeVertexBackend(clock: clock, session: session)
        let logs = LockedBox([String]())
        let result = try await backend.transcribeDetailed(
            audioData: Data("fixture-audio".utf8),
            logger: { _, message in logs.withLock { $0.append(message) } }
        )
        XCTAssertEqual(result.text, "[00:00 - 00:05]\n講者 1：測試完成。")
        XCTAssertEqual(attempts.withLock { $0 }, 2)

        let retryLogs = logs.withLock { $0 }.filter { $0.contains("incompleteStream") }
        XCTAssertEqual(retryLogs.count, 1)
        XCTAssertTrue(retryLogs[0].contains("1／4"))
        XCTAssertTrue(retryLogs[0].contains("約 20 秒後重試"))
    }

    func testConnectionLostLogsDomainCodeAndSessionResetNotice() async throws {
        let clock = RetryLogClock()
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let attempts = LockedBox(0)
        RetryLogProtocol.handler = { _ in
            let attempt = attempts.withLock { value -> Int in
                value += 1
                return value
            }
            if attempt == 1 {
                return .error(URLError(.networkConnectionLost))
            }
            let body = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"完整逐字稿"}]}}]}"#.utf8)
            return .response(status: 200, headers: ["Content-Type": "application/json"], body: body)
        }

        let backend = GoogleAIStudioBackend(
            networkEnvironment: clock.environment(),
            urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false)
        )
        let logs = LockedBox([String]())
        let result = try await backend.transcribeDetailed(
            audioData: Data("fixture-audio".utf8),
            logger: { _, message in logs.withLock { $0.append(message) } }
        )
        XCTAssertEqual(result.text, "完整逐字稿")
        XCTAssertEqual(attempts.withLock { $0 }, 2)

        let retryLogs = logs.withLock { $0 }.filter { $0.contains("NSURLErrorDomain:-1005") }
        XCTAssertEqual(retryLogs.count, 1)
        XCTAssertTrue(retryLogs[0].contains("準備重設連線"))
        XCTAssertTrue(retryLogs[0].contains("1／4"))
        XCTAssertTrue(retryLogs[0].contains("約 20 秒後重試"))
    }

    func testPOSIX40LogsResetOnceAndStopsWithoutRetryLogOnSecondFailure() async throws {
        let clock = RetryLogClock()
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let wrappedPOSIX40 = NSError(
            domain: NSURLErrorDomain,
            code: URLError.networkConnectionLost.rawValue,
            userInfo: ["_kCFStreamErrorCodeKey": 40]
        )

        // Case 1: first POSIX 40 resets and succeeds on attempt 2.
        let attempts = LockedBox(0)
        RetryLogProtocol.handler = { _ in
            let attempt = attempts.withLock { value -> Int in
                value += 1
                return value
            }
            if attempt == 1 {
                return .error(wrappedPOSIX40)
            }
            let body = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"重設後完成"}]}}]}"#.utf8)
            return .response(status: 200, headers: ["Content-Type": "application/json"], body: body)
        }
        let backend = GoogleAIStudioBackend(
            networkEnvironment: clock.environment(),
            urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false)
        )
        let logs = LockedBox([String]())
        let result = try await backend.transcribeDetailed(
            audioData: Data("fixture-audio".utf8),
            logger: { _, message in logs.withLock { $0.append(message) } }
        )
        XCTAssertEqual(result.text, "重設後完成")
        let resetLogs = logs.withLock { $0 }.filter { $0.contains("NSPOSIXErrorDomain:40") }
        XCTAssertEqual(resetLogs.count, 1)
        XCTAssertTrue(resetLogs[0].contains("已重設連線並重新嘗試"))

        // Case 2: consecutive POSIX 40 does not emit a second retry log.
        RetryLogProtocol.handler = { _ in .error(wrappedPOSIX40) }
        let failLogs = LockedBox([String]())
        do {
            _ = try await backend.transcribeDetailed(
                audioData: Data("fixture-audio".utf8),
                logger: { _, message in failLogs.withLock { $0.append(message) } }
            )
            XCTFail("Expected second POSIX 40 failure")
        } catch let error as GoogleAIStudioError {
            XCTAssertEqual(error, .transportMessageTooLarge)
        }
        let failResetLogs = failLogs.withLock { $0 }.filter { $0.contains("NSPOSIXErrorDomain:40") }
        XCTAssertEqual(failResetLogs.count, 1)
    }

    func testUploadCooldownAnd5xxLogWhileGenerationRetriesDoNotDoubleLog() async throws {
        let clock = RetryLogClock()
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let audio = Data("fixture-audio".utf8)
        let expectedHash = Data(SHA256.hash(data: audio)).base64EncodedString()
        let initCalls = LockedBox(0)
        let uploadCalls = LockedBox(0)
        let pollCalls = LockedBox(0)
        let genCalls = LockedBox(0)
        let requestedNameBox = LockedBox("")

        RetryLogProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "DELETE" {
                return .response(status: 204, headers: [:], body: Data())
            }
            if path == "/upload/v1beta/files" {
                let count = initCalls.withLock { $0 += 1; return $0 }
                if count == 1 {
                    return .response(status: 503, headers: [:], body: Data())
                }
                if let bodyData = Self.readBody(from: request),
                   let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                   let file = obj["file"] as? [String: Any],
                   let name = file["name"] as? String {
                    requestedNameBox.withLock { $0 = name }
                }
                return .response(status: 200, headers: ["X-Goog-Upload-URL": "https://fixture.invalid/upload"], body: Data())
            }
            if path == "/upload" {
                let count = uploadCalls.withLock { $0 += 1; return $0 }
                if count == 1 {
                    return .response(status: 429, headers: ["Retry-After": "5"], body: Data())
                }
                let name = requestedNameBox.withLock { $0 }
                let fileJSON = try JSONSerialization.data(withJSONObject: [
                    "file": [
                        "name": name,
                        "uri": "https://generativelanguage.googleapis.com/v1beta/\(name)",
                        "state": "PROCESSING",
                        "sizeBytes": String(audio.count),
                        "sha256Hash": expectedHash
                    ]
                ])
                return .response(status: 200, headers: ["Content-Type": "application/json"], body: fileJSON)
            }
            if request.httpMethod == "GET", path.hasPrefix("/v1beta/files/") {
                let count = pollCalls.withLock { $0 += 1; return $0 }
                if count == 1 {
                    return .response(status: 429, headers: ["Retry-After": "2"], body: Data())
                }
                let name = requestedNameBox.withLock { $0 }
                let fileJSON = try JSONSerialization.data(withJSONObject: [
                    "name": name,
                    "uri": "https://generativelanguage.googleapis.com/v1beta/\(name)",
                    "state": "ACTIVE",
                    "sizeBytes": String(audio.count),
                    "sha256Hash": expectedHash
                ])
                return .response(status: 200, headers: ["Content-Type": "application/json"], body: fileJSON)
            }
            if path.contains(":generateContent") {
                let count = genCalls.withLock { $0 += 1; return $0 }
                if count == 1 {
                    return .response(status: 503, headers: [:], body: Data(#"{"error":{"message":"busy"}}"#.utf8))
                }
                return .response(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"成功"}]}}]}"#.utf8)
                )
            }
            return .response(status: 404, headers: [:], body: Data())
        }

        let backend = GoogleAIStudioBackend(
            networkEnvironment: clock.environment(),
            urlSession: session,
            configuration: .init(apiKey: "fixture")
        )
        let logs = LockedBox([String]())
        let result = try await backend.transcribeDetailed(
            audioData: audio,
            logger: { _, message in logs.withLock { $0.append(message) } }
        )
        XCTAssertEqual(result.text, "成功")

        let allLogs = logs.withLock { $0 }
        XCTAssertEqual(allLogs.filter { $0.contains("上傳音訊收到 HTTP 503") }.count, 1)
        XCTAssertEqual(allLogs.filter { $0.contains("上傳音訊收到 HTTP 429") }.count, 1)
        XCTAssertEqual(allLogs.filter { $0.contains("查詢雲端檔案狀態收到 HTTP 429") }.count, 1)
        let gen503Logs = allLogs.filter { $0.contains("暫時忙碌") }
        XCTAssertEqual(gen503Logs.count, 1, "Generation 503 must be logged once by GeminiGenerationRetry, not duplicated by GeminiTransportHelper")
        XCTAssertTrue(allLogs.filter { $0.contains("雲端生成") && $0.contains("503") }.isEmpty)

        // Generation STOP with empty text logs once via GeminiGenerationRetry.
        let emptyGenCalls = LockedBox(0)
        RetryLogProtocol.handler = { request in
            if request.url!.path.contains(":generateContent") {
                let count = emptyGenCalls.withLock { $0 += 1; return $0 }
                if count == 1 {
                    return .response(
                        status: 200,
                        headers: ["Content-Type": "application/json"],
                        body: Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":""}]}}]}"#.utf8)
                    )
                }
                return .response(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"空重試成功"}]}}]}"#.utf8)
                )
            }
            return .response(status: 404, headers: [:], body: Data())
        }
        let inlineBackend = GoogleAIStudioBackend(
            networkEnvironment: clock.environment(),
            urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false)
        )
        let emptyStopLogs = LockedBox([String]())
        let emptyStopResult = try await inlineBackend.transcribeDetailed(
            audioData: audio,
            logger: { _, message in emptyStopLogs.withLock { $0.append(message) } }
        )
        XCTAssertEqual(emptyStopResult.text, "空重試成功")
        XCTAssertEqual(
            emptyStopLogs.withLock { $0 }.filter { $0.contains("回報 STOP 但沒有逐字稿文字") }.count,
            1
        )
    }

    func testExhaustionCancellationAndShortBudgetDoNotLogMisleadingRetryCountdown() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        RetryLogProtocol.handler = { _ in .error(URLError(.networkConnectionLost)) }

        // 1. 4th attempt exhaustion logs 3 retries (1/4, 2/4, 3/4) and never logs 4/4 retry.
        let clock = RetryLogClock()
        let backend = GoogleAIStudioBackend(
            networkEnvironment: clock.environment(),
            urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false)
        )
        let exhaustedLogs = LockedBox([String]())
        do {
            _ = try await backend.transcribeDetailed(
                audioData: Data("fixture".utf8),
                logger: { _, message in exhaustedLogs.withLock { $0.append(message) } }
            )
            XCTFail("Expected exhausted failure")
        } catch is CloudNetworkRecoveryExhausted {}
        let retryCountdownLogs = exhaustedLogs.withLock { $0 }.filter { $0.contains("秒後重試") }
        XCTAssertEqual(retryCountdownLogs.count, 3)
        XCTAssertFalse(retryCountdownLogs.contains { $0.contains("4／4") })

        // 2. Budget <= 20s remaining must NOT emit "約 X 秒後重試".
        let shortClock = RetryLogClock()
        let shortBudget = CloudSegmentBudget(limit: .seconds(15), now: { shortClock.now })
        let shortContext = CloudNetworkRecoveryContext(budget: shortBudget, environment: shortClock.environment())
        let shortLogs = LockedBox([String]())
        do {
            _ = try await CloudBudgetContext.$current.withValue(shortBudget) {
                try await CloudNetworkContext.$current.withValue(shortContext) {
                    try await backend.transcribeDetailed(
                        audioData: Data("fixture".utf8),
                        logger: { _, message in shortLogs.withLock { $0.append(message) } }
                    )
                }
            }
            XCTFail("Expected rootDeadline failure")
        } catch is CloudNetworkRecoveryExhausted {}
        XCTAssertTrue(shortLogs.withLock { $0 }.filter { $0.contains("秒後重試") }.isEmpty)

        // 3. Cancellation emits zero retry countdown logs.
        let cancelClock = RetryLogClock()
        let cancelContext = CloudNetworkRecoveryContext(
            budget: CloudSegmentBudget(now: { cancelClock.now }),
            environment: cancelClock.environment()
        )
        let cancelTask = Task {
            try await CloudNetworkContext.$current.withValue(cancelContext) {
                try await backend.transcribeDetailed(
                    audioData: Data("fixture".utf8),
                    logger: { _, message in
                        if message.contains("秒後重試") {
                            XCTFail("Cancelled request must not log retry countdown")
                        }
                    }
                )
            }
        }
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
        } catch is CancellationError {}
    }

    func testTransientErrorLogsNeverLeakURLKeysTokensOrRecordingContext() async throws {
        let clock = RetryLogClock()
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let attempts = LockedBox(0)
        let secretError = NSError(
            domain: NSURLErrorDomain,
            code: URLError.networkConnectionLost.rawValue,
            userInfo: [
                NSURLErrorFailingURLErrorKey: URL(string: "https://secret.invalid/v1?key=SECRET_API_KEY")!,
                NSLocalizedDescriptionKey: "Bearer SECRET_BEARER_TOKEN PRIVATE_CONTEXT_SECRET"
            ]
        )
        RetryLogProtocol.handler = { _ in
            let attempt = attempts.withLock { value -> Int in
                value += 1
                return value
            }
            if attempt == 1 {
                return .error(secretError)
            }
            let body = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"安全輸出"}]}}]}"#.utf8)
            return .response(status: 200, headers: ["Content-Type": "application/json"], body: body)
        }

        let backend = GoogleAIStudioBackend(
            networkEnvironment: clock.environment(),
            urlSession: session,
            configuration: .init(apiKey: "SECRET_API_KEY", useFilesAPI: false)
        )
        let logs = LockedBox([String]())
        let result = try await backend.transcribeDetailed(
            audioData: Data("fixture".utf8),
            recordingContext: "PRIVATE_CONTEXT_SECRET",
            logger: { _, message in logs.withLock { $0.append(message) } }
        )
        XCTAssertEqual(result.text, "安全輸出")

        let joined = logs.withLock { $0 }.joined(separator: "\n")
        XCTAssertTrue(joined.contains("NSURLErrorDomain:-1005"))
        XCTAssertFalse(joined.contains("SECRET_API_KEY"))
        XCTAssertFalse(joined.contains("SECRET_BEARER_TOKEN"))
        XCTAssertFalse(joined.contains("secret.invalid"))
        XCTAssertFalse(joined.contains("PRIVATE_CONTEXT_SECRET"))
    }
}
