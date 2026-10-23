import Foundation
import Network

public enum CloudNetworkPath: String, Codable, Sendable {
    case satisfied, unsatisfied, unknown
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct CloudNetworkRecoveryPolicy: Sendable {
    public var maximumWaitSeconds: Double = 300
    public var retryDelaySeconds: Double = 20
    public var stabilitySeconds: Double = 3
    public init() {}
}

public struct CloudNetworkRecovery: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case waiting, retrying, paused, resolved, unknown
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    public enum StopReason: String, Codable, Sendable {
        case attemptsExhausted, waitExhausted, rootDeadline, appRestarted, unknown
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    public var state: State
    public var stopReason: StopReason?
    public var waitedSeconds: Double
    public var remainingWaitSeconds: Double
    public var nextRetryAt: Date?
    public var segmentIndex: Int
    public var segmentCount: Int
    public var completedSegmentCount: Int
    public var lastFailure: CloudFailureDiagnostic?
    public var resultUnknown: Bool
    public init(state: State, stopReason: StopReason? = nil, waitedSeconds: Double,
                remainingWaitSeconds: Double, nextRetryAt: Date? = nil, segmentIndex: Int,
                segmentCount: Int, completedSegmentCount: Int, lastFailure: CloudFailureDiagnostic? = nil,
                resultUnknown: Bool) {
        self.state = state; self.stopReason = stopReason; self.waitedSeconds = waitedSeconds
        self.remainingWaitSeconds = remainingWaitSeconds; self.nextRetryAt = nextRetryAt
        self.segmentIndex = segmentIndex; self.segmentCount = segmentCount; self.completedSegmentCount = completedSegmentCount
        self.lastFailure = lastFailure; self.resultUnknown = resultUnknown
    }
    public var message: String {
        switch state {
        case .paused, .unknown:
            return completedSegmentCount == 0
                ? "連線仍未恢復，工作已保留。恢復網路後可重新嘗試；目前尚未完成任何片段。"
                : "連線恢復等待已達上限，已暫停。已保存 \(completedSegmentCount)／\(segmentCount) 段，可稍後繼續。"
        case .waiting:
            return "連到 Google 的連線暫時不穩，正在等待恢復。已完成 \(completedSegmentCount)／\(segmentCount) 段。"
        case .retrying:
            return "正在重新嘗試第 \(segmentIndex)／\(segmentCount) 段；已完成的片段不會重做。"
        case .resolved: return "連線請求已完成。"
        }
    }
}

public struct CloudNetworkRecoveryExhausted: LocalizedError, Sendable {
    public let recovery: CloudNetworkRecovery
    public var errorDescription: String? { recovery.message }
}

/// Injectable monotonic time, sleeper, path hint and session creation.
public struct CloudNetworkEnvironment: @unchecked Sendable {
    public var now: @Sendable () -> ContinuousClock.Instant
    public var sleep: @Sendable (Duration) async throws -> Void
    public var path: @Sendable () -> CloudNetworkPath
    public var jitter: @Sendable () -> Double
    public var session: @Sendable ([AnyClass]?) -> URLSession
    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                path: (@Sendable () -> CloudNetworkPath)? = nil,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                session: @escaping @Sendable ([AnyClass]?) -> URLSession = { GeminiTransportHelper.makeEphemeralRetrySession(protocolClasses: $0) }) {
        self.now = now; self.sleep = sleep; self.path = path ?? { CloudPathHint.shared.value }; self.jitter = jitter; self.session = session
    }
}

final class CloudPathHint: @unchecked Sendable {
    static let shared = CloudPathHint()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var status: CloudNetworkPath = .unknown
    var value: CloudNetworkPath { lock.withLock { status } }
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.status = path.status == .satisfied ? .satisfied : .unsatisfied }
        }
        monitor.start(queue: DispatchQueue(label: "record-to-text.network-path"))
    }
}

/// One root owns this object, including its adaptive descendants. Waiting
/// intervals are unioned by reference count so delegates and backoff cannot
/// count the same time twice. No path hint can cancel an in-flight request.
public final class CloudNetworkRecoveryContext: @unchecked Sendable {
    public let environment: CloudNetworkEnvironment
    public let policy: CloudNetworkRecoveryPolicy
    let waitForCleanup: Bool
    let service: CloudServiceRecoveryContext
    private let budget: CloudSegmentBudget
    private let lock = NSRecursiveLock()
    private var accumulated: Double = 0
    private var waitStarted: ContinuousClock.Instant?
    private var waits = Set<UUID>()
    private var replacementSession: URLSession?
    private var metadataSession: URLSession?
    private var didReset = false
    private var status: CloudNetworkRecovery
    private var observer: (@Sendable (CloudNetworkRecovery) -> Void)?
    // Only our explicit wait loop can be interrupted. A URLSession task that
    // is already in flight must never be duplicated by the UI button.
    private var explicitWaitActive = false
    private var receivingResponse = false
    private var immediateRetryRequested = false
    private var skipNextPathWait = false
    private var retrySleeper: Task<Void, Error>?

    public init(budget: CloudSegmentBudget, policy: CloudNetworkRecoveryPolicy = .init(),
                environment: CloudNetworkEnvironment = .init(), waitForCleanup: Bool = true) {
        self.budget = budget; self.policy = policy; self.environment = environment
        self.service = CloudServiceRecoveryContext(budget: budget, environment: environment)
        self.waitForCleanup = waitForCleanup
        status = .init(state: .resolved, waitedSeconds: 0, remainingWaitSeconds: policy.maximumWaitSeconds,
                       segmentIndex: 1, segmentCount: 1, completedSegmentCount: 0, resultUnknown: false)
    }
    deinit { replacementSession?.invalidateAndCancel(); metadataSession?.invalidateAndCancel() }
    public var waitedSeconds: Double {
        lock.withLock { accumulated + (waitStarted?.duration(to: environment.now()).secondsValue ?? 0) }
    }
    var sessionWasReset: Bool { lock.withLock { didReset } }
    var lastFailure: CloudFailureDiagnostic? { lock.withLock { status.lastFailure } }
    var isWaiting: Bool { lock.withLock { !waits.isEmpty } }
    var isReceivingResponse: Bool { lock.withLock { receivingResponse } }
    func setReceivingResponse(_ value: Bool) { lock.withLock { receivingResponse = value } }
    public var canRetryImmediately: Bool {
        lock.withLock {
            explicitWaitActive && !receivingResponse && status.state == .waiting && !immediateRetryRequested
                && budget.remaining() > .zero && waitedSeconds < policy.maximumWaitSeconds
        }
    }

    @discardableResult
    public func retryImmediately() -> Bool {
        let accepted: (Bool, Task<Void, Error>?) = lock.withLock {
            guard canRetryImmediately else { return (false, nil) }
            immediateRetryRequested = true
            return (true, retrySleeper)
        }
        accepted.1?.cancel() // Wakes the wait; does not cancel any HTTP request.
        return accepted.0
    }
    func configure(segment: Int, total: Int, completed: Int,
                   observer: (@Sendable (CloudNetworkRecovery) -> Void)? = nil) {
        lock.withLock {
            status.segmentIndex = segment; status.segmentCount = total; status.completedSegmentCount = completed
            self.observer = observer
        }
    }
    func snapshot() -> CloudNetworkRecovery {
        lock.withLock {
            var value = status
            value.waitedSeconds = min(policy.maximumWaitSeconds, waitedSeconds)
            value.remainingWaitSeconds = max(0, min(policy.maximumWaitSeconds - waitedSeconds, budget.remaining().secondsValue))
            return value
        }
    }
    func publish(_ state: CloudNetworkRecovery.State, nextRetryAt: Date? = nil) {
        let callback = lock.withLock { () -> (@Sendable (CloudNetworkRecovery) -> Void)? in
            status.state = state; status.nextRetryAt = nextRetryAt; return observer
        }
        callback?(snapshot())
    }
    func requestSucceeded() {
        lock.withLock { receivingResponse = false; status.lastFailure = nil; status.stopReason = nil }
        publish(.resolved)
    }
    func noteFailure(_ failure: CloudFailureDiagnostic, generation: Bool) {
        lock.withLock {
            receivingResponse = false
            status.lastFailure = failure
            if generation { status.resultUnknown = true }
        }
    }
    func exhausted(_ reason: CloudNetworkRecovery.StopReason) -> CloudNetworkRecoveryExhausted {
        lock.withLock { status.stopReason = reason }
        publish(.paused)
        return .init(recovery: snapshot())
    }
    func check() throws {
        try Task.checkCancellation()
        if budget.remaining() <= .zero {
            if lastFailure != nil || isWaiting { throw exhausted(.rootDeadline) }
            throw budget.deadlineError(stage: "networkWait")
        }
        if waitedSeconds >= policy.maximumWaitSeconds { throw exhausted(.waitExhausted) }
    }
    @discardableResult
    func beginWait() -> UUID {
        lock.withLock {
            let id = UUID()
            if waits.isEmpty { waitStarted = environment.now() }
            waits.insert(id)
            return id
        }
    }
    func endWait(_ id: UUID) {
        lock.withLock {
            guard waits.remove(id) != nil else { return }
            if waits.isEmpty, let start = waitStarted {
                accumulated += max(0, start.duration(to: environment.now()).secondsValue)
                waitStarted = nil
            }
        }
    }
    func wait(minimumSeconds: Double = 0) async throws {
        try check()
        if minimumSeconds == 0, lock.withLock({
            let skip = skipNextPathWait
            skipNextPathWait = false
            return skip
        }) { return }
        guard minimumSeconds > 0 || environment.path() == .unsatisfied else { return }
        let id = beginWait()
        lock.withLock { explicitWaitActive = true; immediateRetryRequested = false }
        defer {
            lock.withLock { explicitWaitActive = false; immediateRetryRequested = false; retrySleeper = nil }
            endWait(id)
        }
        let start = environment.now()
        var stableSince: ContinuousClock.Instant? = environment.path() == .unsatisfied ? nil : start
        while true {
            try check()
            if lock.withLock({ immediateRetryRequested }) {
                // retry() is followed by send()'s preflight wait. Skip that one
                // path hint as well, so one click makes exactly one real attempt.
                lock.withLock { skipNextPathWait = minimumSeconds > 0 }
                break
            }
            let now = environment.now()
            let path = environment.path()
            if path == .unsatisfied { stableSince = nil }
            else if stableSince == nil { stableSince = now }
            let elapsed = start.duration(to: now).secondsValue
            let stable = stableSince.map { $0.duration(to: now).secondsValue >= policy.stabilitySeconds } ?? false
            if elapsed >= minimumSeconds && path != .unsatisfied && stable { break }
            let retryAt = elapsed < minimumSeconds ? Date().addingTimeInterval(minimumSeconds - elapsed) : nil
            publish(.waiting, nextRetryAt: retryAt)
            let remaining = min(1, policy.maximumWaitSeconds - waitedSeconds, budget.remaining().secondsValue)
            try await sleepUntilRetryOrClick(.seconds(max(0, remaining)))
        }
        publish(.retrying)
    }
    func retry(after attempt: Int, error: Error, generation: Bool) async throws {
        if lastFailure == nil { noteFailure(.classify(error), generation: generation) }
        CloudDiagnosticContext.current?.retry(.network)
        let start = waitedSeconds
        defer { CloudDiagnosticContext.current?.record(stage: .backoff, seconds: max(0, waitedSeconds - start)) }
        try await wait(minimumSeconds: policy.retryDelaySeconds)
    }

    private func sleepUntilRetryOrClick(_ duration: Duration) async throws {
        let sleeper = Task { try await environment.sleep(duration) }
        let alreadyRequested = lock.withLock {
            retrySleeper = sleeper
            return immediateRetryRequested
        }
        if alreadyRequested { sleeper.cancel() }
        defer { lock.withLock { retrySleeper = nil } }
        do {
            try await withTaskCancellationHandler {
                try await sleeper.value
            } onCancel: { sleeper.cancel() }
        } catch {
            try Task.checkCancellation()
            guard error is CancellationError, lock.withLock({ immediateRetryRequested }) else { throw error }
        }
    }
    func session(using original: URLSession, resetFor error: Error? = nil) -> URLSession {
        lock.withLock {
            if let error, !didReset,
               [.connectionLost, .hostUnreachable, .dnsFailure, .transportFailure].contains(CloudFailureDiagnostic.classify(error).category) {
                replacementSession = environment.session(original.configuration.protocolClasses)
                metadataSession?.invalidateAndCancel()
                metadataSession = nil
                didReset = true
                CloudDiagnosticContext.current?.retry(.transportReset)
            }
            return replacementSession ?? original
        }
    }
    /// URLSession exposes a connectivity-start callback but no connection-ready
    /// callback for bodyless GETs. Fail fast there and let the common recovery
    /// loop measure its waits, so normal metadata server time is never deducted
    /// from the Files processing budget as connectivity time.
    func metadataTransport(using original: URLSession) -> URLSession {
        lock.withLock {
            if let metadataSession { return metadataSession }
            let config = original.configuration
            config.waitsForConnectivity = false
            let session = URLSession(configuration: config)
            metadataSession = session
            return session
        }
    }
}

enum CloudNetworkContext {
    @TaskLocal static var current: CloudNetworkRecoveryContext?
    @TaskLocal static var generation: CloudRequestAttempts?
    @TaskLocal static var polling: CloudPollingBudget?
    @TaskLocal static var segmentAttempts: CloudModelAttempts?
}

/// A prepared URI may be rebuilt, but the pending segment/model send quota is
/// retained. A new adaptive child receives a new ledger from transcribeDetailed.
final class CloudModelAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: CloudRequestAttempts] = [:]
    func quota(for model: String, stage: CloudDiagnosticStage = .generation) -> CloudRequestAttempts {
        lock.withLock {
            if let quota = models[model] { return quota }
            let quota = CloudRequestAttempts(stage: stage)
            models[model] = quota
            return quota
        }
    }
}

final class CloudRequestAttempts: @unchecked Sendable {
    private let lock = NSLock()
    let stage: CloudDiagnosticStage
    private var sent = 0
    init(stage: CloudDiagnosticStage = .generation) { self.stage = stage }
    var count: Int { lock.withLock { sent } }
    func claim() throws {
        try lock.withLock {
            guard sent < 4 else { throw CloudRequestLimitExceeded(stage: stage) }
            sent += 1
        }
    }
}

struct CloudRequestLimitExceeded: LocalizedError {
    let stage: CloudDiagnosticStage
    var errorDescription: String? { stage == .generation ? "本片段已達四次生成發送上限。" : "本片段已達四次上傳階段發送上限。" }
}

/// Effective poll time excludes only measured network wait intervals.
final class CloudPollingBudget {
    private let context: CloudNetworkRecoveryContext?
    private let started: ContinuousClock.Instant
    private let initialWait: Double
    init(context: CloudNetworkRecoveryContext?) {
        self.context = context
        started = context?.environment.now() ?? .now
        initialWait = context?.waitedSeconds ?? 0
    }
    var remaining: Double {
        max(0, 60 - started.duration(to: context?.environment.now() ?? .now).secondsValue
            + (context?.waitedSeconds ?? 0) - initialWait)
    }
}
