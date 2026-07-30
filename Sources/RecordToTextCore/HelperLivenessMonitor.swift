import Foundation

public final class HelperLivenessMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivityAt: Date
    private var hasEmittedWarning = false

    public init(startedAt: Date = Date()) {
        self.lastActivityAt = startedAt
    }

    public func recordActivity(at date: Date = Date()) {
        lock.withLock {
            lastActivityAt = date
            hasEmittedWarning = false
        }
    }

    public func consumeWarningIfInactive(
        now: Date = Date(),
        timeout: TimeInterval
    ) -> Bool {
        lock.withLock {
            guard !hasEmittedWarning else {
                return false
            }
            guard now.timeIntervalSince(lastActivityAt) >= timeout else {
                return false
            }
            hasEmittedWarning = true
            return true
        }
    }
}
