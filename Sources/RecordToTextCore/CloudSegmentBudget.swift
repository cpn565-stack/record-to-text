import Foundation

public struct CloudSegmentDeadlineExceeded: LocalizedError, Sendable {
    public let rootSegmentID: UUID
    public let segmentIndex: Int
    public let splitDepth: Int
    public let elapsedSeconds: Double
    public let limitSeconds: Double
    public let stage: String
    public var errorDescription: String? {
        "本片段已達等待上限（\(Int(limitSeconds)) 秒），已停止自動重試。已完成的片段已保留，可稍後從未完成處續跑。"
    }
}

extension Duration {
    var secondsValue: Double {
        let whole: Double = Double(components.seconds)
        let fraction: Double = Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return whole + fraction
    }
}

/// The same instance follows a root and every adaptive descendant. Instants
/// never leave the process. Only external operations race the deadline: their
/// late results cannot enter the engine's manifest/publication code.
public final class CloudSegmentBudget: @unchecked Sendable {
    public let rootSegmentID: UUID
    public let startedAtInstant: ContinuousClock.Instant
    public let deadlineInstant: ContinuousClock.Instant
    public let limit: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let lock = NSRecursiveLock()
    private var exhaustedError: CloudSegmentDeadlineExceeded?
    private let event: ((String) -> Void)?
    private var index = 0
    private var depth = 0
    private var activeStage = "preparing"
    public var stage: String { lock.withLock { activeStage } }
    public init(rootSegmentID: UUID = UUID(), limit: Duration = .seconds(900),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                event: ((String) -> Void)? = nil) {
        self.event = event
        self.rootSegmentID = rootSegmentID
        self.limit = limit
        self.now = now
        self.sleeper = sleeper
        startedAtInstant = now()
        deadlineInstant = startedAtInstant.advanced(by: limit)
    }
    public func remaining() -> Duration { max(.zero, now().duration(to: deadlineInstant)) }
    public func elapsed() -> Duration { startedAtInstant.duration(to: now()) }
    public func setSegment(index: Int, depth: Int) {
        lock.withLock { self.index = index; self.depth = depth }
    }
    public func deadlineError(stage: String) -> CloudSegmentDeadlineExceeded {
        lock.withLock {
            if let exhaustedError { return exhaustedError }
            let error = CloudSegmentDeadlineExceeded(rootSegmentID: rootSegmentID,
                segmentIndex: index, splitDepth: depth, elapsedSeconds: elapsed().secondsValue,
                limitSeconds: limit.secondsValue, stage: stage)
            exhaustedError = error
            event?("deadline exhausted root=\(rootSegmentID) segment=\(index) depth=\(depth) stage=\(stage) elapsed=\(elapsed().secondsValue)")
            return error
        }
    }
    public func checkRemaining(stage: String) throws {
        try Task.checkCancellation()
        try lock.withLock {
            if exhaustedError != nil || remaining() <= .zero { throw deadlineError(stage: stage) }
        }
    }
    public func timeout(_ maximum: TimeInterval, stage: String) throws -> TimeInterval {
        try checkRemaining(stage: stage)
        return min(maximum, remaining().secondsValue)
    }
    /// Synchronous manifest commit and deadline decision share the same gate.
    public func commit<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            try checkRemaining(stage: "commit")
            return try body()
        }
    }
    public func withDeadline<T>(stage: String, operationLimit: Duration? = nil, operation: @escaping () async throws -> T) async throws -> T {
        try checkRemaining(stage: stage)
        lock.withLock { activeStage = stage }
        let operationDeadline = operationLimit.map { now().advanced(by: $0) }
        let gate = DeadlineCompletion<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.install(continuation)
                let worker = Task<Void, Never> {
                    do {
                        let value: T = try await CloudBudgetContext.$current.withValue(self) {
                            try await operation()
                        }
                        try self.checkRemaining(stage: stage)
                        if let operationDeadline, self.now() >= operationDeadline { throw CloudRequestDeadlineExceeded(stage: stage) }
                        gate.finish(.success(value))
                    } catch {
                        let failure: Error = !Task.isCancelled && self.remaining() <= .zero
                            ? self.deadlineError(stage: stage) : error
                        let wasCancelled = Task.isCancelled
                        gate.finish(.failure(failure))
                        if wasCancelled { self.event?("cancel completed root=\(self.rootSegmentID) stage=\(stage)") }
                    }
                }
                let timer = Task<Void, Never> {
                    do {
                        let allowance = operationDeadline.map { min(self.remaining(), max(.zero, self.now().duration(to: $0))) } ?? self.remaining()
                        try await self.sleeper(allowance)
                        try Task.checkCancellation()
                        let error: Error = self.remaining() <= .zero ? self.deadlineError(stage: stage) : CloudRequestDeadlineExceeded(stage: stage)
                        self.event?("cancel requested root=\(self.rootSegmentID) stage=\(stage)")
                        gate.finish(.failure(error))
                    } catch { }
                }
                gate.register(worker: worker, timer: timer)
            }
        } onCancel: {
            self.event?("cancel requested root=\(self.rootSegmentID) stage=\(stage) reason=user")
            gate.finish(.failure(CancellationError()))
        }
    }
}

private final class DeadlineCompletion<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var cancel: (() -> Void)?
    func install(_ continuation: CheckedContinuation<T, Error>) {
        let result = lock.withLock { () -> Result<T, Error>? in
            if let result = self.result { return result }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func register(worker: Task<Void, Never>, timer: Task<Void, Never>) {
        let action = { worker.cancel(); timer.cancel() }
        let done = lock.withLock { () -> Bool in
            if result != nil { return true }
            cancel = action
            return false
        }
        if done { action() }
    }
    func finish(_ value: Result<T, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<T, Error>?, (() -> Void)?) in
            guard result == nil else { return (nil, nil) }
            result = value
            let pending = (continuation, cancel)
            continuation = nil; cancel = nil
            return pending
        }
        pending.1?()
        pending.0?.resume(with: value)
    }
}

/// Task-local propagation keeps retry/fallback/process helpers on exactly the
/// engine's budget without mutable backend-wide state or cross-job sharing.
public enum CloudBudgetContext {
    @TaskLocal public static var current: CloudSegmentBudget?
    public static func check(_ stage: String) throws {
        try Task.checkCancellation()
        try current?.checkRemaining(stage: stage)
    }
    public static func timeout(_ maximum: TimeInterval, stage: String) throws -> TimeInterval {
        try current?.timeout(maximum, stage: stage) ?? maximum
    }
    public static func validateBackoff(seconds: Double) throws {
        try check("backoff")
        if let current, seconds >= current.remaining().secondsValue {
            throw current.deadlineError(stage: "backoff")
        }
    }
    public static func backoff(seconds: Double) async throws {
        try validateBackoff(seconds: seconds)
        try await perform(stage: "backoff") { try await Task.sleep(for: .seconds(seconds)) }
    }
    public static func perform<T>(stage: String, maximumDuration: Duration? = nil, operation: @escaping () async throws -> T) async throws -> T {
        let diagnosticStart = ContinuousClock.now
        let collector = CloudDiagnosticContext.current
        defer {
            if let measuredStage = CloudDiagnosticStage(rawValue: stage) {
                collector?.record(stage: measuredStage, seconds: diagnosticStart.duration(to: .now).secondsValue)
            }
        }
        do {
            if let current { return try await current.withDeadline(stage: stage, operationLimit: maximumDuration, operation: operation) }
            if let maximumDuration {
                return try await CloudSegmentBudget().withDeadline(stage: stage, operationLimit: maximumDuration, operation: operation)
            }
            try Task.checkCancellation()
            return try await operation()
        } catch {
            collector?.failure(error, stage: .init(rawValue: stage) ?? .unknown)
            throw error
        }
    }
}
