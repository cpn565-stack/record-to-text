import XCTest
@testable import RecordToTextCore

final class RecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Double = 0
    var seconds: Double { lock.withLock { elapsed } }
    var now: ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }
    func advance(_ duration: Duration) { lock.withLock { elapsed += duration.secondsValue } }
    func environment(path: @escaping @Sendable (Double) -> CloudNetworkPath = { _ in .satisfied }) -> CloudNetworkEnvironment {
        .init(now: { self.now }, sleep: { self.advance($0); await Task.yield(); try Task.checkCancellation() },
              path: { path(self.seconds) }, jitter: { 0 })
    }
}

final class RecoveryURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CloudNetworkRecoveryTests: XCTestCase {
    func testImmediateRetryWakesCurrentWaitOnceWithoutLeakingToNextWait() async throws {
        let waiting = expectation(description: "retry countdown")
        waiting.assertForOverFulfill = false
        let context = CloudNetworkRecoveryContext(budget: CloudSegmentBudget(), environment: .init(path: { .satisfied }))
        context.configure(segment: 1, total: 1, completed: 0,
            observer: { if $0.state == .waiting { waiting.fulfill() } })
        XCTAssertFalse(context.retryImmediately())
        let task = Task { try await context.retry(after: 3, error: URLError(.networkConnectionLost), generation: true) }
        await fulfillment(of: [waiting], timeout: 1)
        let start = ContinuousClock.now
        XCTAssertTrue(context.retryImmediately())
        XCTAssertFalse(context.retryImmediately())
        try await task.value
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        XCTAssertFalse(context.canRetryImmediately)
        try await context.wait() // Consume the one preflight bypass.

        let nextWaiting = expectation(description: "new countdown")
        nextWaiting.assertForOverFulfill = false
        context.configure(segment: 1, total: 1, completed: 0,
            observer: { if $0.state == .waiting { nextWaiting.fulfill() } })
        let next = Task { try await context.retry(after: 2, error: URLError(.networkConnectionLost), generation: true) }
        await fulfillment(of: [nextWaiting], timeout: 1)
        XCTAssertTrue(context.canRetryImmediately)
        next.cancel()
        _ = context.retryImmediately() // A simultaneous click cannot override cancellation.
        do { try await next.value; XCTFail("Cancelled wait resumed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(context.retryImmediately())
    }

    func testImmediateRetriesPreserveFourSendLimit() async throws {
        let clock = RecoveryClock(), session = session()
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        let budget = CloudSegmentBudget(now: { clock.now })
        let context = CloudNetworkRecoveryContext(budget: budget, environment: clock.environment())
        let clicks = RecoveryValue(0)
        context.configure(segment: 1, total: 1, completed: 0, observer: { [weak context] state in
            if state.state == .waiting, context?.retryImmediately() == true { clicks.value += 1 }
        })
        let sends = RecoveryValue(0)
        RecoveryURLProtocol.handler = { _ in sends.value += 1; throw URLError(.networkConnectionLost) }
        let backend = GoogleAIStudioBackend(urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false))
        do {
            _ = try await CloudBudgetContext.$current.withValue(budget) {
                try await CloudNetworkContext.$current.withValue(context) {
                    try await backend.transcribe(audioData: Data())
                }
            }
            XCTFail("Exceeded request quota")
        } catch let error as CloudNetworkRecoveryExhausted {
            XCTAssertEqual(error.recovery.stopReason, .attemptsExhausted)
        }
        XCTAssertEqual(sends.value, 4)
        XCTAssertEqual(clicks.value, 3)
        XCTAssertLessThan(clock.seconds, 20)
        XCTAssertFalse(context.retryImmediately())
    }

    func testImmediateRetrySkipsOfflineHintForOnlyOnePreflight() async throws {
        let context = CloudNetworkRecoveryContext(budget: CloudSegmentBudget(), environment: .init(path: { .unsatisfied }))
        let waiting = expectation(description: "offline wait")
        waiting.assertForOverFulfill = false
        context.configure(segment: 1, total: 1, completed: 0,
            observer: { if $0.state == .waiting { waiting.fulfill() } })
        let task = Task { try await context.retry(after: 1, error: URLError(.networkConnectionLost), generation: true) }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertTrue(context.retryImmediately())
        try await task.value
        try await context.wait()

        let nextWaiting = expectation(description: "later offline wait is not skipped")
        nextWaiting.assertForOverFulfill = false
        context.configure(segment: 1, total: 1, completed: 0,
            observer: { if $0.state == .waiting { nextWaiting.fulfill() } })
        let next = Task { try await context.wait() }
        await fulfillment(of: [nextWaiting], timeout: 1)
        next.cancel()
        do { try await next.value; XCTFail("Offline preflight leaked a bypass") } catch { XCTAssertTrue(error is CancellationError) }
    }

    private let success = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"完整逐字稿"}]}}]}"#.utf8)
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testOfflineBeforeSendWaitsForThirtyOr120SecondsAndStability() async throws {
        for offlineDuration in [30.0, 120.0] {
            let clock = RecoveryClock()
            let environment = clock.environment { $0 < offlineDuration ? .unsatisfied : .satisfied }
            let session = session()
            defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
            var count = 0
            RecoveryURLProtocol.handler = { _ in
                count += 1
                XCTAssertGreaterThanOrEqual(clock.seconds, offlineDuration + 3)
                return (200, self.success)
            }
            let backend = GoogleAIStudioBackend(networkEnvironment: environment, urlSession: session,
                configuration: .init(apiKey: "fixture", useFilesAPI: false))
            _ = try await backend.transcribe(audioData: Data("fixture".utf8))
            XCTAssertEqual(count, 1)
        }
    }

    func testSatisfiedPathStillRetriesServiceAndOnlyResetsSessionOnce() async throws {
        let clock = RecoveryClock()
        let session = session()
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        var times: [Double] = []
        let resets = RecoveryValue(0)
        var env = clock.environment()
        env.jitter = { 1 } // Network retry is fixed even at maximum jitter.
        env.session = { protocols in resets.value += 1; return GeminiTransportHelper.makeEphemeralRetrySession(protocolClasses: protocols) }
        RecoveryURLProtocol.handler = { _ in
            times.append(clock.seconds)
            if clock.seconds < 60 { throw URLError(.networkConnectionLost) }
            return (200, self.success)
        }
        let backend = GoogleAIStudioBackend(networkEnvironment: env, urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false, fallbackPolicy: .flashOnly))
        let result = try await backend.transcribeDetailed(audioData: Data("fixture".utf8))
        XCTAssertEqual(times, [0, 20, 40, 60])
        XCTAssertEqual(resets.value, 1)
        XCTAssertEqual(result.metadata.retryCount, 3)
    }

    func testFourSendsPauseWithoutFifthOrModelFallback() async throws {
        let clock = RecoveryClock()
        let session = session()
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        var sends = 0
        RecoveryURLProtocol.handler = { _ in sends += 1; throw URLError(.networkConnectionLost) }
        let backend = GoogleAIStudioBackend(networkEnvironment: clock.environment(), urlSession: session,
            configuration: .init(apiKey: "fixture", useFilesAPI: false, fallbackPolicy: .flashOnly))
        do { _ = try await backend.transcribe(audioData: Data()); XCTFail("Expected pause") }
        catch let error as CloudNetworkRecoveryExhausted {
            XCTAssertEqual(error.recovery.stopReason, .attemptsExhausted)
            XCTAssertEqual(error.recovery.lastFailure?.category, .connectionLost)
            XCTAssertTrue(error.recovery.resultUnknown)
        }
        XCTAssertEqual(sends, 4)
        XCTAssertEqual(clock.seconds, 60)
    }

    func testFlappingWaitIsBoundedAndOverlappingWaitCountsOnce() async throws {
        let clock = RecoveryClock()
        let budget = CloudSegmentBudget(now: { clock.now })
        let context = CloudNetworkRecoveryContext(budget: budget, environment: clock.environment { Int($0) % 4 < 2 ? .unsatisfied : .satisfied })
        let overlapping = context.beginWait()
        do { try await context.wait(); XCTFail("Unstable path accepted") }
        catch let error as CloudNetworkRecoveryExhausted {
            XCTAssertEqual(error.recovery.stopReason, .waitExhausted)
        }
        context.endWait(overlapping)
        XCTAssertEqual(clock.seconds, 300)
        XCTAssertEqual(context.waitedSeconds, 300)
        XCTAssertEqual(budget.remaining(), .seconds(600))
    }

    func testRootTwentySecondsStopsBeforeRetrySend() async throws {
        let clock = RecoveryClock()
        let budget = CloudSegmentBudget(limit: .seconds(20), now: { clock.now })
        let context = CloudNetworkRecoveryContext(budget: budget, environment: clock.environment())
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
        let collector = CloudDiagnosticCollector(history: history, budget: budget, network: context)
        collector.requestStarted(stage: .generation)
        collector.failure(URLError(.networkConnectionLost), stage: .generation)
        do { try await context.retry(after: 2, error: URLError(.networkConnectionLost), generation: true); XCTFail("Exceeded root") }
        catch let error as CloudNetworkRecoveryExhausted {
            XCTAssertEqual(error.recovery.stopReason, .rootDeadline)
            XCTAssertEqual(error.recovery.lastFailure?.category, .connectionLost)
            collector.failure(error, stage: .generation)
            collector.failure(error, stage: .generation)
            let terminal = try XCTUnwrap(history.snapshot().events.last)
            XCTAssertEqual(terminal.recoveryStopReason, .rootDeadline)
            XCTAssertEqual(terminal.failure.category, .connectionLost)
            XCTAssertEqual(terminal.rootRemainingSeconds, 0)
            XCTAssertEqual(terminal.networkWaitSeconds, 20)
            XCTAssertEqual(history.snapshot().totalEventCount, 2)
        }
        XCTAssertEqual(clock.seconds, 20)
    }

    func testCancellationDuringWaitStopsPromptly() async throws {
        let entered = expectation(description: "waiting")
        let context = CloudNetworkRecoveryContext(budget: CloudSegmentBudget(), environment: .init(path: { .unsatisfied }))
        context.configure(segment: 1, total: 1, completed: 0, observer: { if $0.state == .waiting { entered.fulfill() } })
        let task = Task { try await context.wait() }
        await fulfillment(of: [entered], timeout: 1)
        let start = ContinuousClock.now
        task.cancel()
        do { try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testPollingExcludes120SecondsOfNetworkWait() async throws {
        let clock = RecoveryClock()
        let context = CloudNetworkRecoveryContext(budget: CloudSegmentBudget(now: { clock.now }), environment: clock.environment())
        let polling = CloudPollingBudget(context: context)
        clock.advance(.seconds(10))
        try await context.wait(minimumSeconds: 120)
        XCTAssertEqual(polling.remaining, 50, accuracy: 0.001)
        clock.advance(.seconds(12))
        XCTAssertEqual(polling.remaining, 38, accuracy: 0.001)
    }

    func testPathBecomingOfflineDoesNotCancelHealthyInflightResponse() async throws {
        let clock = RecoveryClock(), session = session()
        let offline = RecoveryValue(false)
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        var sends = 0
        RecoveryURLProtocol.handler = { _ in
            sends += 1
            offline.value = true
            return (200, self.success)
        }
        let backend = GoogleAIStudioBackend(networkEnvironment: clock.environment { _ in offline.value ? .unsatisfied : .satisfied },
            urlSession: session, configuration: .init(apiKey: "fixture", useFilesAPI: false))
        let result = try await backend.transcribe(audioData: Data())
        XCTAssertEqual(result, "完整逐字稿")
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(clock.seconds, 0)
    }

    func testResolvedFailureDoesNotMisclassifyLaterRootDeadlineAsOffline() async throws {
        let clock = RecoveryClock()
        let context = CloudNetworkRecoveryContext(budget: CloudSegmentBudget(limit: .seconds(100), now: { clock.now }),
            environment: clock.environment())
        try await context.retry(after: 1, error: URLError(.networkConnectionLost), generation: true)
        context.requestSucceeded()
        clock.advance(.seconds(85))
        XCTAssertThrowsError(try context.check()) { XCTAssertTrue($0 is CloudSegmentDeadlineExceeded) }
        XCTAssertEqual(context.waitedSeconds, 20)
    }

    func testConnectivityDelegateEndsWaitAtBodyProgressAndIgnoresLateWaitCallback() throws {
        let clock = RecoveryClock(), session = session()
        defer { session.invalidateAndCancel() }
        let context = CloudNetworkRecoveryContext(budget: CloudSegmentBudget(now: { clock.now }), environment: clock.environment())
        let delegate = CloudConnectivityDelegate(context: context) { _ in XCTFail("Unexpected exhaustion") }
        let task = session.dataTask(with: URL(string: "https://fixture.invalid/")!)
        delegate.urlSession(session, taskIsWaitingForConnectivity: task)
        XCTAssertFalse(context.canRetryImmediately, "An in-flight URLSession task cannot be duplicated")
        XCTAssertFalse(context.retryImmediately())
        clock.advance(.seconds(120))
        delegate.urlSession(session, task: task, didSendBodyData: 1, totalBytesSent: 1, totalBytesExpectedToSend: 1)
        clock.advance(.seconds(60))
        XCTAssertEqual(context.waitedSeconds, 120)
        XCTAssertEqual(context.snapshot().state, .resolved)
        delegate.urlSession(session, taskIsWaitingForConnectivity: task)
        XCTAssertFalse(context.isWaiting)
        delegate.stop()
        task.cancel()
    }

    func testMetadataTransportUsesExplicitRecoveryInsteadOfUnmeasurableConnectivityWait() {
        let session = session()
        defer { session.invalidateAndCancel() }
        let context = CloudNetworkRecoveryContext(budget: CloudSegmentBudget())
        XCTAssertFalse(context.metadataTransport(using: session).configuration.waitsForConnectivity)
        XCTAssertTrue(GeminiTransportHelper.makeEphemeralRetrySession().configuration.waitsForConnectivity)
    }
}
