import Foundation

enum TestSupport {
    @MainActor
    static func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw TestTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private struct TestTimeout: Error {}
    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "record-to-text-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

/// Suspends a fake countdown or final flush until the test explicitly releases
/// it. Cancellation removes the waiter, so stale callbacks can be tested too.
actor RecoveryTestGate {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var calls = 0
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                calls += 1
                waiters[id] = continuation
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
