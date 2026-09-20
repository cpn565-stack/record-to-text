import XCTest
@testable import RecordToTextCore

private final class SuspendedRecoveryProtocol: URLProtocol {
    static var entered: (() -> Void)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.entered?() }
    override func stopLoading() { Self.stopped?() }
}

final class CloudRequestCancellationTests: XCTestCase {
    func testCancellationStopsUploadPollAndGenerationWithinOneSecond() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("request.json")
        try Data("{}".utf8).write(to: file)
        for stage in ["upload", "poll", "generation"] {
            let started = expectation(description: stage + " started")
            let stopped = expectation(description: stage + " stopped")
            let sends = RecoveryValue(0)
            SuspendedRecoveryProtocol.entered = { sends.value += 1; started.fulfill() }
            SuspendedRecoveryProtocol.stopped = { stopped.fulfill() }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SuspendedRecoveryProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let budget = CloudSegmentBudget()
            let context = CloudNetworkRecoveryContext(budget: budget, environment: .init(path: { .satisfied }))
            var request = URLRequest(url: URL(string: "https://fixture.invalid/" + (stage == "generation" ? "generateContent" : stage))!)
            request.httpMethod = stage == "poll" ? "GET" : "POST"
            let finalRequest = request
            let task = Task {
                try await CloudBudgetContext.$current.withValue(budget) {
                    try await CloudNetworkContext.$current.withValue(context) {
                        if stage == "poll" {
                            return try await GeminiTransportHelper.budgetedData(session: session, request: finalRequest, stage: stage)
                        }
                        return try await GeminiTransportHelper.budgetedUpload(session: session, request: finalRequest, fileURL: file)
                    }
                }
            }
            await fulfillment(of: [started], timeout: 1)
            let start = ContinuousClock.now
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled request returned a result") }
            catch { XCTAssertTrue(error is CancellationError) }
            await fulfillment(of: [stopped], timeout: 1)
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
            XCTAssertEqual(sends.value, 1)
            XCTAssertFalse(context.isWaiting)
        }
        SuspendedRecoveryProtocol.entered = nil
        SuspendedRecoveryProtocol.stopped = nil
    }
}
