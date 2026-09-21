import Foundation

public struct CloudServiceRecovery: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case coolingDown, retrying, paused, resolved, unknown
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    public enum StopReason: String, Codable, Sendable {
        case attemptsExhausted, rootDeadline, stageDeadline, dailyQuota, appRestarted, unknown
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    public var state: State = .resolved
    public var stopReason: StopReason?
    public var stage: CloudDiagnosticStage = .generation
    public var attempts = 0
    public var waitedSeconds: Double = 0
    public var nextRetryAt: Date?
    public var serverNotBefore: Date?
    public var segmentIndex = 1
    public var segmentCount = 1
    public var completedSegmentCount = 0
    public var resultUnknown = false

    public init() {}
    public var message: String {
        switch state {
        case .coolingDown: return "Google 暫時忙碌，正在冷卻等待；已完成 \(completedSegmentCount)／\(segmentCount) 段。"
        case .retrying: return "正在重送第 \(segmentIndex)／\(segmentCount) 段；已完成片段會沿用。"
        case .resolved: return "Google 請求已完成。"
        case .paused, .unknown:
            return stopReason == .dailyQuota
                ? "Google 日額度已達限制，工作已保留；請檢查配額後手動重新送出。"
                : "Google 仍忙碌，已暫停並保留工作；已完成 \(completedSegmentCount)／\(segmentCount) 段，可稍後手動重送。"
        }
    }
}

public struct CloudServiceRecoveryExhausted: LocalizedError, Sendable {
    public let recovery: CloudServiceRecovery
    public var errorDescription: String? { recovery.message }
}

enum CloudServiceRecoveryPolicy {
    static func delay(after sends: Int, serverDelay: Double?, jitter: Double) -> Double {
        let base = [30.0, 60, 120][min(2, max(0, sends - 1))]
        return max(base * (1 + 0.2 * min(1, max(0, jitter))), serverDelay ?? 0)
    }
}

/// Root-scoped service waiting, separate from the network's 300-second allowance.
/// The existing network context owns this peer so all transport entry points
/// share the same root budget and injected clock without backend-wide state.
final class CloudServiceRecoveryContext: @unchecked Sendable {
    private let lock = NSLock()
    private let budget: CloudSegmentBudget
    private let environment: CloudNetworkEnvironment
    private let wallStart = Date()
    private let clockStart: ContinuousClock.Instant
    private var value = CloudServiceRecovery()
    private var waitStarted: ContinuousClock.Instant?
    private var observer: (@Sendable (CloudServiceRecovery) -> Void)?

    init(budget: CloudSegmentBudget, environment: CloudNetworkEnvironment) {
        self.budget = budget; self.environment = environment
        clockStart = environment.now()
    }
    private var date: Date { wallStart.addingTimeInterval(clockStart.duration(to: environment.now()).secondsValue) }
    var snapshot: CloudServiceRecovery {
        let now = environment.now()
        return lock.withLock { snapshot(at: now) }
    }
    private func snapshot(at now: ContinuousClock.Instant) -> CloudServiceRecovery {
        var copy = value
        if let waitStarted { copy.waitedSeconds += max(0, waitStarted.duration(to: now).secondsValue) }
        return copy
    }
    var isRecovering: Bool { [.coolingDown, .retrying, .paused].contains(snapshot.state) }

    func configure(segment: Int, total: Int, completed: Int,
                   observer: @escaping @Sendable (CloudServiceRecovery) -> Void) {
        lock.withLock {
            value.segmentIndex = segment; value.segmentCount = total
            value.completedSegmentCount = completed; self.observer = observer
        }
    }
    private func update(_ mutation: (inout CloudServiceRecovery) -> Void) {
        let now = environment.now()
        let pending = lock.withLock { () -> (CloudServiceRecovery, (@Sendable (CloudServiceRecovery) -> Void)?) in
            mutation(&value); return (snapshot(at: now), observer)
        }
        pending.1?(pending.0)
    }
    func resolve(stage: CloudDiagnosticStage? = nil) {
        guard snapshot.state != .paused, stage == nil || snapshot.stage == stage else { return }
        update { $0.state = .resolved; $0.stopReason = nil; $0.nextRetryAt = nil; $0.serverNotBefore = nil }
    }
    func beginFallback() {
        update { $0.state = .resolved; $0.stopReason = nil; $0.nextRetryAt = nil }
    }

    func noteServerDelay(_ seconds: Double?, stage: CloudDiagnosticStage) {
        let until = seconds.flatMap { $0.isFinite && $0 >= 0 ? date.addingTimeInterval($0) : nil }
        update { $0.stage = stage; $0.serverNotBefore = until }
    }

    /// Model fallback still honors a server lower bound from the prior request.
    func waitBeforeFallback() async throws {
        guard let until = snapshot.serverNotBefore else { return }
        let delay = until.timeIntervalSince(date)
        guard delay > 0 else { return }
        guard delay < budget.remaining().secondsValue else { throw exhausted(.rootDeadline) }
        try await wait(seconds: delay, stage: .generation)
    }
    func exhausted(_ reason: CloudServiceRecovery.StopReason) -> CloudServiceRecoveryExhausted {
        update { $0.state = .paused; $0.stopReason = reason; $0.nextRetryAt = nil }
        return .init(recovery: snapshot)
    }

    func rateLimited(after sends: Int, stage: CloudDiagnosticStage, serverDelay: Double?,
                     dailyQuota: Bool = false, canRetry: Bool = true,
                     resultUnknown: Bool = false) async throws {
        try Task.checkCancellation()
        let serverDelay = serverDelay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let notBefore = serverDelay.map { date.addingTimeInterval($0) }
        update {
            $0.stage = stage; $0.attempts = sends; $0.resultUnknown = $0.resultUnknown || resultUnknown
            if let notBefore { $0.serverNotBefore = notBefore }
            $0.stopReason = nil
        }
        if dailyQuota { throw exhausted(.dailyQuota) }
        guard sends < 4, canRetry else { throw exhausted(.attemptsExhausted) }
        let delay = CloudServiceRecoveryPolicy.delay(after: sends, serverDelay: serverDelay, jitter: environment.jitter())
        guard delay < budget.remaining().secondsValue else { throw exhausted(.rootDeadline) }
        if stage == .poll, let polling = CloudNetworkContext.polling, delay >= polling.remaining {
            throw exhausted(.stageDeadline)
        }
        CloudDiagnosticContext.current?.retry(.rateLimited)
        try await wait(seconds: delay, stage: stage)
    }

    private func wait(seconds delay: Double, stage: CloudDiagnosticStage) async throws {
        let started = environment.now()
        lock.withLock { waitStarted = started }
        update { $0.state = .coolingDown; $0.nextRetryAt = date.addingTimeInterval(delay) }
        defer { finishWait() }
        do {
            try await environment.sleep(.seconds(delay))
            finishWait()
            try budget.checkRemaining(stage: "backoff")
            if stage == .poll, let polling = CloudNetworkContext.polling, polling.remaining <= 0 {
                throw exhausted(.stageDeadline)
            }
            update { $0.state = .retrying; $0.nextRetryAt = nil }
        } catch is CloudSegmentDeadlineExceeded {
            finishWait()
            throw exhausted(.rootDeadline)
        }
    }

    private func finishWait() {
        let now = environment.now()
        let elapsed: Double? = lock.withLock {
            guard let started = waitStarted else { return nil }
            waitStarted = nil
            let elapsed = max(0, started.duration(to: now).secondsValue)
            value.waitedSeconds += elapsed
            return elapsed
        }
        if let elapsed {
            update { _ in }
            CloudDiagnosticContext.current?.record(stage: .backoff, seconds: elapsed)
        }
    }
}
