import XCTest
@testable import RecordToTextCore

private final class BudgetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

final class CloudSegmentBudgetTests: XCTestCase {
    func testLateUncooperativeResultCannotPassDeadline() async throws {
        let budget = CloudSegmentBudget(limit: .milliseconds(30))
        let start = ContinuousClock.now
        do {
            let _: Int = try await budget.withDeadline(stage: "generation") {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        continuation.resume(returning: 42)
                    }
                }
            }
            XCTFail("Late response accepted")
        } catch let error as CloudSegmentDeadlineExceeded {
            XCTAssertEqual(error.stage, "generation")
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(200))
        }
        XCTAssertThrowsError(try budget.checkRemaining(stage: "split"))
    }

    func testFiveSecondBudgetStopsLocalProcessWithinStopTarget() async throws {
        let runner = ProcessRunner()
        let start = ContinuousClock.now
        do {
            _ = try await CloudSegmentBudget(limit: .seconds(5)).withDeadline(stage: "extract") {
                try await runner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"])
            }
            XCTFail("Process exceeded deadline")
        } catch let error as CloudSegmentDeadlineExceeded {
            XCTAssertEqual(error.stage, "extract")
        }
        while runner.isRunning, start.duration(to: .now) < .seconds(9) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(runner.isRunning)
        XCTAssertLessThan(start.duration(to: .now), .seconds(10))
    }

    func testInjectedMonotonicClockRejectsNewWorkAfterAdvance() throws {
        let clock = BudgetTestClock()
        let budget = CloudSegmentBudget(limit: .seconds(900), now: { clock.now })
        clock.advance(.seconds(899))
        XCTAssertEqual(budget.remaining(), .seconds(1))
        clock.advance(.seconds(2))
        XCTAssertThrowsError(try budget.checkRemaining(stage: "upload"))
        XCTAssertThrowsError(try budget.commit { XCTFail("Late commit accepted") })
    }

    func testPerRequestWallLimitDoesNotResetOrExhaustRoot() async throws {
        let budget = CloudSegmentBudget(limit: .seconds(10))
        do {
            _ = try await budget.withDeadline(stage: "generation", operationLimit: .milliseconds(30)) {
                try await Task.sleep(for: .seconds(1))
            }
            XCTFail("Single request exceeded wall limit")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        try budget.checkRemaining(stage: "retry")
        XCTAssertGreaterThan(budget.remaining(), .seconds(9))
    }

    func testCancellationIsNotDeadline() async throws {
        let budget = CloudSegmentBudget()
        let task = Task {
            try await budget.withDeadline(stage: "upload") {
                try await Task.sleep(for: .seconds(20))
            }
        }
        task.cancel()
        do { try await task.value; XCTFail("Accepted cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRetryAfterDoesNotStartAnEarlyRetry() async throws {
        let budget = CloudSegmentBudget(limit: .seconds(1))
        do {
            try await CloudBudgetContext.$current.withValue(budget) {
                try await CloudBudgetContext.backoff(seconds: 2)
            }
            XCTFail("Exceeded remaining budget")
        } catch let error as CloudSegmentDeadlineExceeded {
            XCTAssertEqual(error.stage, "backoff")
        }
    }
}
