import XCTest
@testable import RecordToTextCore

final class CloudServiceRecoveryTests: XCTestCase {
    private let success = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"完整測試逐字稿"}]}}]}"#.utf8)
    private let busy = Data(#"{"error":{"code":429,"message":"Resource exhausted"}}"#.utf8)
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func transcribe(_ type: ASRBackendType, clock: RecoveryClock, session: URLSession,
                            fallback: CloudFallbackPolicy = .disabled) async throws -> CloudTranscriptionResult {
        if type == .googleAIStudio {
            return try await GoogleAIStudioBackend(networkEnvironment: clock.environment(), urlSession: session,
                configuration: .init(apiKey: "fixture", modelID: "gemini-3.8-flash", useFilesAPI: false, fallbackPolicy: fallback))
                .transcribeDetailed(audioData: Data("fixture".utf8))
        }
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gcloud = root.appendingPathComponent("fake-gcloud")
        try "#!/bin/sh\necho fixture-token\n".write(to: gcloud, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gcloud.path)
        return try await VertexAIGeminiBackend(networkEnvironment: clock.environment(),
            authService: GCloudAuthService(customGCloudPath: gcloud.path), urlSession: session,
            configuration: .init(projectID: "fixture-project", modelID: "gemini-3.8-flash", fallbackPolicy: fallback))
            .transcribeDetailed(audioData: Data("fixture".utf8))
    }

    func testBothBackendsCoolDownThirtyAndSixtySecondsThenSucceed() async throws {
        for type in [ASRBackendType.googleAIStudio, .vertexAI] {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
            let sends = RecoveryValue<[Double]>([])
            RecoveryURLProtocol.handler = { _ in
                sends.value.append(clock.seconds)
                return sends.value.count < 3 ? (429, self.busy) : (200, self.success)
            }
            let result = try await transcribe(type, clock: clock, session: session)
            XCTAssertEqual(sends.value, [0, 30, 90])
            XCTAssertEqual(result.metadata.retryCount, 2)
            XCTAssertEqual(result.text, "完整測試逐字稿")
        }
    }

    func testFourRateLimitsPauseBothBackendsWithoutFifthSend() async throws {
        for type in [ASRBackendType.googleAIStudio, .vertexAI] {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
            let sends = RecoveryValue<[Double]>([])
            RecoveryURLProtocol.handler = { _ in sends.value.append(clock.seconds); return (429, self.busy) }
            do { _ = try await transcribe(type, clock: clock, session: session); XCTFail("Expected pause") }
            catch let error as CloudServiceRecoveryExhausted {
                XCTAssertEqual(error.recovery.stopReason, .attemptsExhausted)
                XCTAssertEqual(error.recovery.attempts, 4)
                XCTAssertEqual(error.recovery.waitedSeconds, 210)
            }
            XCTAssertEqual(sends.value, [0, 30, 90, 210])
        }
    }

    func testMixedFailuresKeepOneQuotaAndSeparateWaitAccounting() async throws {
        for failures in [2, 3] {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
            let budget = CloudSegmentBudget(now: { clock.now })
            let context = CloudNetworkRecoveryContext(budget: budget, environment: clock.environment())
            let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .googleAIStudio)
            let collector = CloudDiagnosticCollector(history: history, budget: budget, network: context)
            let sends = RecoveryValue(0)
            RecoveryURLProtocol.handler = { _ in
                sends.value += 1
                if sends.value <= failures { throw URLError(.networkConnectionLost) }
                return sends.value == failures + 1 ? (429, self.busy) : (200, self.success)
            }
            do {
                _ = try await CloudBudgetContext.$current.withValue(budget) {
                    try await CloudNetworkContext.$current.withValue(context) {
                        try await CloudDiagnosticContext.$current.withValue(collector) {
                            try await self.transcribe(.googleAIStudio, clock: clock, session: session)
                        }
                    }
                }
                XCTAssertEqual(failures, 2)
            } catch let error as CloudServiceRecoveryExhausted {
                XCTAssertEqual(failures, 3)
                XCTAssertTrue(error.recovery.resultUnknown)
                collector.failure(error, stage: .generation)
                XCTAssertEqual(history.snapshot().events.last?.serviceStopReason, .attemptsExhausted)
            }
            XCTAssertEqual(sends.value, 4)
            XCTAssertEqual(context.waitedSeconds, failures == 2 ? 60 : 180)
            XCTAssertEqual(context.service.snapshot.waitedSeconds, failures == 2 ? 120 : 0)
            XCTAssertTrue(history.snapshot().events.contains { $0.failure.category == .connectionLost })
            XCTAssertTrue(history.snapshot().events.contains { $0.failure.httpStatus == 429 })
        }
    }

    func testRetryAfterFormatsAndRetryInfoChooseLaterValidLowerBound() throws {
        let now = Date(timeIntervalSince1970: 784111777) // 1994-11-06 08:49:37 GMT
        for header in ["90", "Sun, 06 Nov 1994 08:51:07 GMT", "Sunday, 06-Nov-94 08:51:07 GMT", "Sun Nov 6 08:51:07 1994"] {
            let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: 429,
                httpVersion: nil, headerFields: ["Retry-After": header])!
            XCTAssertEqual(GeminiTransportHelper.retryAfterSeconds(response: response, data: Data(), now: now), 90)
            let data = Data(#"{"error":{"details":[{"retryDelay":"120.5s"}]}}"#.utf8)
            XCTAssertEqual(GeminiTransportHelper.retryAfterSeconds(response: response, data: data, now: now), 120.5)
        }
        for invalid in ["", "-1", "NaN", "inf", "1e309", "broken", "1.5"] {
            let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: 429,
                httpVersion: nil, headerFields: ["Retry-After": invalid])!
            XCTAssertNil(GeminiTransportHelper.retryAfterSeconds(response: response, data: Data()))
        }
        XCTAssertEqual(CloudServiceRecoveryPolicy.delay(after: 1, serverDelay: nil, jitter: 1), 36)
        XCTAssertEqual(CloudServiceRecoveryPolicy.delay(after: 3, serverDelay: 300, jitter: 1), 300)
    }

    func testUploadAndPollUseStageQuotaAndEffectiveDeadline() async throws {
        for stage in ["upload", "poll"] {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
            let budget = CloudSegmentBudget(now: { clock.now })
            let context = CloudNetworkRecoveryContext(budget: budget, environment: clock.environment())
            let quota = CloudRequestAttempts(stage: stage == "upload" ? .upload : .poll)
            let sends = RecoveryValue(0)
            RecoveryURLProtocol.handler = { _ in sends.value += 1; return (429, self.busy) }
            do {
                _ = try await CloudBudgetContext.$current.withValue(budget) {
                    try await CloudNetworkContext.$current.withValue(context) {
                        try await CloudNetworkContext.$polling.withValue(CloudPollingBudget(context: context)) {
                            try await GeminiTransportHelper.budgetedData(session: session,
                                request: URLRequest(url: URL(string: "https://fixture.invalid/metadata")!), stage: stage, attempts: quota)
                        }
                    }
                }
                XCTFail("Expected pause")
            } catch let error as CloudServiceRecoveryExhausted {
                XCTAssertEqual(error.recovery.stopReason, stage == "upload" ? .attemptsExhausted : .stageDeadline)
                XCTAssertEqual(error.recovery.stage.rawValue, stage)
            }
            XCTAssertEqual(sends.value, stage == "upload" ? 4 : 2)
            XCTAssertEqual(clock.seconds, stage == "upload" ? 210 : 30)
        }
    }

    func testDailyQuotaAndTooLongServerDelayPauseWithoutWaiting() async throws {
        for daily in [true, false] {
            let clock = RecoveryClock(), session = session()
            defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
            let sends = RecoveryValue(0)
            RecoveryURLProtocol.handler = { _ in
                sends.value += 1
                return (429, Data((daily ? #"{"error":{"message":"daily quota exceeded","details":[{"retryDelay":"1000s"}]}}"# :
                    #"{"error":{"message":"busy","details":[{"retryDelay":"1000s"}]}}"#).utf8))
            }
            do { _ = try await transcribe(.googleAIStudio, clock: clock, session: session, fallback: .flashOnly); XCTFail("Expected pause") }
            catch let error as CloudServiceRecoveryExhausted {
                XCTAssertEqual(error.recovery.stopReason, daily ? .dailyQuota : .rootDeadline)
                XCTAssertNotNil(error.recovery.serverNotBefore)
            }
            XCTAssertEqual(sends.value, 1)
            XCTAssertEqual(clock.seconds, 0)
        }
    }

    func testFallbackKeepsRootAndServerLowerBound() async throws {
        let clock = RecoveryClock(), session = session()
        defer { session.invalidateAndCancel(); RecoveryURLProtocol.handler = nil }
        let times = RecoveryValue<[Double]>([])
        RecoveryURLProtocol.handler = { request in
            times.value.append(clock.seconds)
            if request.url!.absoluteString.contains("3.6-flash") { return (200, self.success) }
            return (429, times.value.count == 4
                ? Data(#"{"error":{"message":"busy","details":[{"retryDelay":"300s"}]}}"#.utf8) : self.busy)
        }
        _ = try await transcribe(.googleAIStudio, clock: clock, session: session, fallback: .flashOnly)
        XCTAssertEqual(times.value, [0, 30, 90, 210, 510])
    }

    func testRootTimerSnapshotIncludesInflightWaitAndTerminalEvent() async throws {
        let clock = RecoveryClock()
        let environment = CloudNetworkEnvironment(now: { clock.now }, sleep: { _ in
            clock.advance(.seconds(100))
        }, jitter: { 0 })
        let budget = CloudSegmentBudget(limit: .seconds(100), now: { clock.now })
        let context = CloudNetworkRecoveryContext(budget: budget, environment: environment)
        let history = CloudFailureHistoryCollector(jobID: UUID(), backend: .vertexAI)
        let collector = CloudDiagnosticCollector(history: history, budget: budget, network: context)
        collector.requestStarted(stage: .generation)
        collector.failure(.http(429, stage: .generation))
        do { try await context.service.rateLimited(after: 1, stage: .generation, serverDelay: nil); XCTFail("Expected deadline") }
        catch let error as CloudServiceRecoveryExhausted {
            XCTAssertEqual(error.recovery.waitedSeconds, 100)
            XCTAssertEqual(error.recovery.stopReason, .rootDeadline)
            collector.failure(error, stage: .generation)
            collector.failure(error, stage: .generation)
        }
        XCTAssertEqual(history.snapshot().totalEventCount, 2)
        XCTAssertEqual(history.snapshot().events.last?.serviceWaitSeconds, 100)
        XCTAssertEqual(history.snapshot().events.last?.failure.httpStatus, 429)
    }

    func testCancellationDuringServiceCooldownFinishesUnderOneSecond() async throws {
        let entered = expectation(description: "cooling")
        let observed = RecoveryValue(false)
        let context = CloudServiceRecoveryContext(budget: CloudSegmentBudget(), environment: .init())
        context.configure(segment: 1, total: 1, completed: 0) {
            if $0.state == .coolingDown && !observed.value { observed.value = true; entered.fulfill() }
        }
        let task = Task { try await context.rateLimited(after: 1, stage: .generation, serverDelay: nil) }
        await fulfillment(of: [entered], timeout: 1)
        let start = ContinuousClock.now
        task.cancel()
        do { try await task.value; XCTFail("Ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }
}
