import Foundation
import XCTest
@testable import RecordToTextCore

final class SilenceAwareSegmentationTests: XCTestCase {
    func testParserPairsSilenceStartAndEnd() {
        let stderr = """
        [silencedetect @ 0x1] silence_start: 11.250
        [silencedetect @ 0x1] silence_end: 12.000 | silence_duration: 0.750
        [silencedetect @ 0x1] silence_start: 99.000
        [silencedetect @ 0x1] silence_end: 100.200 | silence_duration: 1.200
        """
        XCTAssertEqual(
            SilenceDetectionParser.parse(stderr),
            [
                DetectedSilence(startSeconds: 11.25, endSeconds: 12),
                DetectedSilence(startSeconds: 99, endSeconds: 100.2)
            ]
        )
    }

    func testPlannerChoosesClosestEligibleSilenceBeforeLimit() throws {
        let plan = try SilenceAwareSegmentPlanner.makePlan(
            sourceDuration: 1_850,
            maximumSegmentDuration: 1_200,
            silences: [
                DetectedSilence(startSeconds: 1_170, endSeconds: 1_171),
                DetectedSilence(startSeconds: 1_190, endSeconds: 1_191)
            ]
        )

        XCTAssertEqual(plan.expectedSegmentCount, 2)
        XCTAssertEqual(plan.segments[0].endSeconds, 1_190.5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            plan.segments.map(\.durationSeconds).max() ?? .infinity,
            1_200.001
        )
    }

    func testPlannerFallsBackWhenNoEligibleSilenceExists() throws {
        let hard = try AudioSegmentPlanner.makePlan(
            sourceDuration: 2_500,
            maximumSegmentDuration: 1_200
        )
        let adjusted = try SilenceAwareSegmentPlanner.makePlan(
            sourceDuration: 2_500,
            maximumSegmentDuration: 1_200,
            silences: [
                DetectedSilence(startSeconds: 600, endSeconds: 600.1),
                DetectedSilence(startSeconds: 1_100, endSeconds: 1_100.2)
            ]
        )
        XCTAssertEqual(adjusted, hard)
    }

    func testPlannerKeepsEverySegmentWithinMaximumAcrossMultipleBoundaries() throws {
        let plan = try SilenceAwareSegmentPlanner.makePlan(
            sourceDuration: 4_000,
            maximumSegmentDuration: 1_200,
            silences: [
                DetectedSilence(startSeconds: 1_185, endSeconds: 1_186),
                DetectedSilence(startSeconds: 2_360, endSeconds: 2_361),
                DetectedSilence(startSeconds: 3_540, endSeconds: 3_541)
            ]
        )
        XCTAssertTrue(
            plan.segments.allSatisfy {
                $0.durationSeconds > 0 && $0.durationSeconds <= 1_200.001
            }
        )
        XCTAssertEqual(plan.segments.first?.startSeconds, 0)
        let finalSegment = try XCTUnwrap(plan.segments.last)
        XCTAssertEqual(finalSegment.endSeconds, 4_000, accuracy: 0.001)
    }
}
