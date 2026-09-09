import Foundation
import XCTest
@testable import RecordToTextCore

private final class CountingSilenceDetector: SilenceDetectionServicing, @unchecked Sendable {
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
        lock.withLock {
            calls.append((startSeconds, durationSeconds))
        }
        return try result.get()
    }
}

final class JobSilenceAnalysisCacheTests: XCTestCase {
    func testSuccessfulEmptyScanIsCachedAndReturnedInAbsoluteCoordinates() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = CountingSilenceDetector(result: .success([]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        let first = try await cache.cachedOrDetect(
            startSeconds: 10,
            durationSeconds: 20,
            detector: detector
        )
        let second = try await cache.cachedOrDetect(
            startSeconds: 12,
            durationSeconds: 4,
            detector: detector
        )

        XCTAssertTrue(cache.isEnabled)
        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [])
        XCTAssertEqual(detector.calls.count, 1)
        XCTAssertEqual(cache.metrics.scanCount, 1)
        XCTAssertEqual(cache.metrics.cacheHitCount, 1)
    }

    func testCacheConvertsDetectorRelativeTimesToAbsoluteTimes() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = CountingSilenceDetector(result: .success([
            DetectedSilence(startSeconds: 2, endSeconds: 4)
        ]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        let silences = try await cache.cachedOrDetect(
            startSeconds: 100,
            durationSeconds: 20,
            detector: detector
        )

        XCTAssertEqual(
            silences,
            [DetectedSilence(startSeconds: 102, endSeconds: 104)]
        )
        XCTAssertEqual(detector.calls.count, 1)
    }

    func testCacheHitClipsSilencesToRequestedRange() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = CountingSilenceDetector(result: .success([
            DetectedSilence(startSeconds: 2, endSeconds: 4),
            DetectedSilence(startSeconds: 12, endSeconds: 14)
        ]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        _ = try await cache.cachedOrDetect(
            startSeconds: 100,
            durationSeconds: 20,
            detector: detector
        )
        let childRange = try XCTUnwrap(
            cache.cachedSilences(startSeconds: 100, endSeconds: 110)
        )

        XCTAssertEqual(
            childRange,
            [DetectedSilence(startSeconds: 102, endSeconds: 104)]
        )
        XCTAssertEqual(detector.calls.count, 1)
    }

    func testSeparateCachesDoNotShareEntries() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let firstDetector = CountingSilenceDetector(result: .success([]))
        let secondDetector = CountingSilenceDetector(result: .success([]))
        let firstCache = JobSilenceAnalysisCache(sourceURL: sourceURL)
        let secondCache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        _ = try await firstCache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: firstDetector
        )
        _ = try await secondCache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: secondDetector
        )

        XCTAssertEqual(firstDetector.calls.count, 1)
        XCTAssertEqual(secondDetector.calls.count, 1)
        XCTAssertEqual(firstCache.metrics.cacheHitCount, 0)
        XCTAssertEqual(secondCache.metrics.cacheHitCount, 0)
    }

    func testFailedDetectionIsNotCachedAndCanBeRetried() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = CountingSilenceDetector(
            result: .failure(NSError(domain: "silence-test", code: 1))
        )
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        do {
            _ = try await cache.cachedOrDetect(
                startSeconds: 0,
                durationSeconds: 10,
                detector: detector
            )
            XCTFail("Expected detection failure")
        } catch {
            XCTAssertEqual(detector.calls.count, 1)
            XCTAssertNil(cache.cachedSilences(startSeconds: 0, endSeconds: 10))
            XCTAssertEqual(cache.metrics.scanCount, 1)
            XCTAssertEqual(cache.metrics.cacheHitCount, 0)
        }

        detector.result = .success([
            DetectedSilence(startSeconds: 1, endSeconds: 2)
        ])
        let retried = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: detector
        )
        XCTAssertEqual(
            retried,
            [DetectedSilence(startSeconds: 1, endSeconds: 2)]
        )
        XCTAssertEqual(detector.calls.count, 2)
        XCTAssertEqual(cache.metrics.scanCount, 2)
    }

    func testOverLimitIntervalsRemainUsableWithoutCaching() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let tooMany = (0...100_000).map {
            DetectedSilence(
                startSeconds: Double($0) * 0.001,
                endSeconds: Double($0) * 0.001 + 0.0001
            )
        }
        let detector = CountingSilenceDetector(result: .success(tooMany))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        let first = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 200,
            detector: detector
        )
        XCTAssertEqual(first.count, tooMany.count)
        XCTAssertNil(cache.cachedSilences(startSeconds: 0, endSeconds: 200))

        _ = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 200,
            detector: detector
        )
        XCTAssertEqual(detector.calls.count, 2)
        XCTAssertEqual(cache.metrics.cacheHitCount, 0)
    }

    func testPartialCoverageDoesNotCountAsCacheHit() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = CountingSilenceDetector(result: .success([]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        _ = try await cache.cachedOrDetect(
            startSeconds: 10,
            durationSeconds: 10,
            detector: detector
        )
        _ = try await cache.cachedOrDetect(
            startSeconds: 15,
            durationSeconds: 10,
            detector: detector
        )

        XCTAssertEqual(detector.calls.count, 2)
        XCTAssertEqual(cache.metrics.cacheHitCount, 0)
    }

    func testSourceIdentityChangeInvalidatesExistingEntries() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = CountingSilenceDetector(result: .success([]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        _ = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: detector
        )
        try Data("changed-source-with-a-different-size".utf8)
            .write(to: sourceURL)
        _ = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: detector
        )

        XCTAssertEqual(detector.calls.count, 2)
        XCTAssertEqual(cache.metrics.cacheHitCount, 0)
    }

    func testSourceIdentityChangePermanentlyDropsPriorEntries() async throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let detector = CountingSilenceDetector(result: .success([]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        _ = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: detector
        )
        try Data("changed".utf8).write(to: sourceURL)
        _ = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: detector
        )
        try Data("source".utf8).write(to: sourceURL)
        _ = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: detector
        )

        XCTAssertEqual(detector.calls.count, 3)
        XCTAssertFalse(cache.isEnabled)
        XCTAssertEqual(cache.metrics.cacheHitCount, 0)
    }

    func testUnknownSourceIdentityNeverUsesCache() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-silence-source-\(UUID().uuidString).m4a")
        let detector = CountingSilenceDetector(result: .success([]))
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        _ = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: detector
        )
        _ = try await cache.cachedOrDetect(
            startSeconds: 0,
            durationSeconds: 10,
            detector: detector
        )

        XCTAssertFalse(cache.isEnabled)
        XCTAssertEqual(detector.calls.count, 2)
        XCTAssertEqual(cache.metrics.cacheHitCount, 0)
    }

    func testInvalidIntervalsAndIntervalLimitAreNotCached() throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        XCTAssertFalse(
            cache.store(
                silences: [DetectedSilence(startSeconds: .nan, endSeconds: 2)],
                startSeconds: 0,
                endSeconds: 10
            )
        )
        XCTAssertFalse(
            cache.store(
                silences: [DetectedSilence(startSeconds: 8, endSeconds: 2)],
                startSeconds: 0,
                endSeconds: 10
            )
        )
        let tooMany = (0...100_000).map {
            DetectedSilence(startSeconds: Double($0) * 0.001,
                            endSeconds: Double($0) * 0.001 + 0.0001)
        }
        XCTAssertFalse(
            cache.store(
                silences: tooMany,
                startSeconds: 0,
                endSeconds: 200
            )
        )
        XCTAssertNil(cache.cachedSilences(startSeconds: 0, endSeconds: 10))
    }

    func testMetricsTrackScansAndFallbacks() throws {
        let sourceURL = try makeSourceFile(contents: "source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let cache = JobSilenceAnalysisCache(sourceURL: sourceURL)

        cache.recordScan(durationSeconds: 12.5, elapsedMilliseconds: 83.25)
        cache.recordSkippedIneligible()
        cache.recordFallback()

        XCTAssertEqual(cache.metrics.scanCount, 1)
        XCTAssertEqual(cache.metrics.scannedAudioSeconds, 12.5, accuracy: 0.001)
        XCTAssertEqual(cache.metrics.scanElapsedMilliseconds, 83.25, accuracy: 0.001)
        XCTAssertEqual(cache.metrics.skipIneligibleCount, 1)
        XCTAssertEqual(cache.metrics.fallbackCount, 1)
        XCTAssertTrue(cache.metricsSummary.contains("silence_scan_count=1"))
    }

    private func makeSourceFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-cache-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: url)
        return url
    }
}
