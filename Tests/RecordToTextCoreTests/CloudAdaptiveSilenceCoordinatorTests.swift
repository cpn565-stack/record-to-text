import Foundation
import XCTest
@testable import RecordToTextCore

private final class AdaptiveSilenceDetectorSpy: SilenceDetectionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(start: Double, duration: Double)] = []
    var result: Result<[DetectedSilence], Error>

    init(result: Result<[DetectedSilence], Error>) {
        self.result = result
    }

    func detect(
        sourceURL: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> [DetectedSilence] {
        lock.withLock { calls.append((startSeconds, durationSeconds)) }
        return try result.get()
    }
}

private struct AdaptiveSilenceAnalysisFailure: Error {}

final class CloudAdaptiveSilenceCoordinatorTests: XCTestCase {
    func testIneligibleSegmentsSkipSilenceDetection() async throws {
        let sourceURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = AdaptiveSilenceDetectorSpy(result: .success([]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)
        let minimumChildDuration =
            CloudAdaptiveSegmentPlanner.productionMinimumChildDuration

        let tooShort = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: minimumChildDuration * 2 - 1,
            splitDepth: 0,
            startSeconds: 0,
            silenceAware: true,
            minimumChildDuration: minimumChildDuration,
            cache: cache,
            detector: detector
        )
        XCTAssertNil(tooShort)
        XCTAssertEqual(detector.calls.count, 0)
        XCTAssertEqual(cache.metrics.skipIneligibleCount, 1)
    }

    func testMaximumDepthAndDisabledSilenceAwareDoNotCallDetector() async throws {
        let sourceURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = AdaptiveSilenceDetectorSpy(result: .success([
            DetectedSilence(startSeconds: 4, endSeconds: 6)
        ]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        let depthBoundary = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 300,
            splitDepth: CloudAdaptiveSegmentPlanner.productionMaximumSplitDepth,
            startSeconds: 0,
            silenceAware: true,
            minimumChildDuration: 60,
            cache: cache,
            detector: detector
        )
        let disabledBoundary = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 300,
            splitDepth: 0,
            startSeconds: 0,
            silenceAware: false,
            minimumChildDuration: 60,
            cache: cache,
            detector: detector
        )

        XCTAssertNil(depthBoundary)
        XCTAssertEqual(disabledBoundary, 150)
        XCTAssertEqual(detector.calls.count, 0)
        XCTAssertEqual(cache.metrics.skipIneligibleCount, 1)
    }

    func testRelativeSilenceTimesUseRecordOffsetOnlyOnce() async throws {
        let sourceURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = AdaptiveSilenceDetectorSpy(result: .success([
            DetectedSilence(startSeconds: 9, endSeconds: 11)
        ]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        let optionalBoundary = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 20,
            splitDepth: 0,
            startSeconds: 100,
            silenceAware: true,
            minimumChildDuration: 5,
            cache: cache,
            detector: detector
        )
        let boundary = try XCTUnwrap(optionalBoundary)

        XCTAssertEqual(boundary, 10, accuracy: 0.001)
        let call = try XCTUnwrap(detector.calls.first)
        XCTAssertEqual(call.start, 100, accuracy: 0.001)
        XCTAssertEqual(call.duration, 20, accuracy: 0.001)
    }

    func testCachedParentAnalysisIsReusedByChild() async throws {
        let sourceURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = AdaptiveSilenceDetectorSpy(result: .success([
            DetectedSilence(startSeconds: 9, endSeconds: 11)
        ]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        _ = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 20,
            splitDepth: 0,
            startSeconds: 100,
            silenceAware: true,
            minimumChildDuration: 5,
            cache: cache,
            detector: detector
        )
        _ = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 10,
            splitDepth: 1,
            startSeconds: 100,
            silenceAware: true,
            minimumChildDuration: 5,
            cache: cache,
            detector: detector
        )

        XCTAssertEqual(detector.calls.count, 1)
        XCTAssertEqual(cache.metrics.cacheHitCount, 1)
    }

    func testRightChildReusesParentAbsoluteCoverage() async throws {
        let sourceURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = AdaptiveSilenceDetectorSpy(result: .success([
            DetectedSilence(startSeconds: 9, endSeconds: 11)
        ]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        _ = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 20,
            splitDepth: 0,
            startSeconds: 100,
            silenceAware: true,
            minimumChildDuration: 5,
            cache: cache,
            detector: detector
        )
        _ = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 10,
            splitDepth: 1,
            startSeconds: 110,
            silenceAware: true,
            minimumChildDuration: 5,
            cache: cache,
            detector: detector
        )

        XCTAssertEqual(detector.calls.count, 1)
        let parentScan = try XCTUnwrap(detector.calls.first)
        XCTAssertEqual(parentScan.start, 100, accuracy: 0.001)
        XCTAssertEqual(cache.metrics.cacheHitCount, 1)
    }

    func testFailedAnalysisIsNotCachedAndCanBeRetried() async throws {
        let sourceURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = AdaptiveSilenceDetectorSpy(
            result: .failure(AdaptiveSilenceAnalysisFailure())
        )
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)
        var fallbackCount = 0

        let firstBoundary = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 20,
            splitDepth: 0,
            startSeconds: 40,
            silenceAware: true,
            minimumChildDuration: 5,
            cache: cache,
            detector: detector,
            onFallback: { _ in fallbackCount += 1 }
        )
        XCTAssertEqual(firstBoundary, 10)
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertEqual(detector.calls.count, 1)
        XCTAssertEqual(cache.metrics.cacheHitCount, 0)
        XCTAssertEqual(cache.metrics.fallbackCount, 1)
        XCTAssertNil(cache.cachedSilences(startSeconds: 40, endSeconds: 60))

        detector.result = .success([
            DetectedSilence(startSeconds: 9, endSeconds: 11)
        ])
        let retriedOptional = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
            duration: 20,
            splitDepth: 0,
            startSeconds: 40,
            silenceAware: true,
            minimumChildDuration: 5,
            cache: cache,
            detector: detector
        )
        let retried = try XCTUnwrap(retriedOptional)

        XCTAssertEqual(retried, 10, accuracy: 0.001)
        XCTAssertEqual(detector.calls.count, 2)
        XCTAssertEqual(cache.metrics.scanCount, 2)
        XCTAssertEqual(cache.metrics.cacheHitCount, 0)
    }

    func testCancellationIsNotConvertedToMidpointFallback() async throws {
        let sourceURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = AdaptiveSilenceDetectorSpy(result: .failure(CancellationError()))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        do {
            _ = try await CloudAdaptiveSilenceCoordinator.splitBoundary(
                duration: 20,
                splitDepth: 0,
                startSeconds: 0,
                silenceAware: true,
                minimumChildDuration: 5,
                cache: cache,
                detector: detector
            )
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            XCTAssertEqual(cache.metrics.fallbackCount, 0)
        }
    }

    private func makeSourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-silence-\(UUID().uuidString).m4a")
        try Data("source".utf8).write(to: url)
        return url
    }
}
