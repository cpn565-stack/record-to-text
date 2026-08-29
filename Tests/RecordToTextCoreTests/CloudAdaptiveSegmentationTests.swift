import Foundation
import XCTest
@testable import RecordToTextCore

final class CloudAdaptiveSegmentationTests: XCTestCase {
    func testSplitBoundaryPrefersNearestEligibleSilence() throws {
        let boundary = try XCTUnwrap(
            CloudAdaptiveSegmentPlanner.splitBoundary(
                duration: 1_200,
                splitDepth: 0,
                silences: [
                    DetectedSilence(startSeconds: 480, endSeconds: 481),
                    DetectedSilence(startSeconds: 618, endSeconds: 620),
                    DetectedSilence(startSeconds: 900, endSeconds: 901)
                ]
            )
        )
        XCTAssertEqual(boundary, 619, accuracy: 0.001)
    }

    func testSplitBoundaryStopsAtMaximumDepthAndMinimumDuration() {
        XCTAssertNil(
            CloudAdaptiveSegmentPlanner.splitBoundary(
                duration: 1_200,
                splitDepth:
                    CloudAdaptiveSegmentPlanner.productionMaximumSplitDepth
            )
        )
        XCTAssertNil(
            CloudAdaptiveSegmentPlanner.splitBoundary(
                duration:
                    CloudAdaptiveSegmentPlanner.productionMinimumChildDuration
                        * 2 - 1,
                splitDepth: 0
            )
        )
    }

    func testManifestSplitRenumbersContiguousChildren() throws {
        let directory = URL(fileURLWithPath: "/tmp/adaptive")
        let original = AudioSegmentRecord(
            segmentIndex: 1,
            segmentCount: 2,
            startSeconds: 0,
            endSeconds: 1_200,
            audioPath: "/tmp/adaptive/segment-0001.mp3",
            outputPath: "/tmp/adaptive/segment-0001.txt"
        )
        let trailing = AudioSegmentRecord(
            segmentIndex: 2,
            segmentCount: 2,
            startSeconds: 1_200,
            endSeconds: 1_800,
            audioPath: "/tmp/adaptive/segment-0002.mp3",
            outputPath: "/tmp/adaptive/segment-0002.txt"
        )
        let children = try XCTUnwrap(
            TranscriptionEngine.adaptiveCloudChildRecords(
                for: original,
                boundaryOffset: 600,
                segmentsDirectory: directory
            )
        )
        var manifest = AudioSegmentManifest(
            schemaVersion: 3,
            jobID: UUID(),
            sourceDurationSeconds: 1_800,
            maximumSegmentDurationSeconds: 1_200,
            expectedSegmentCount: 2,
            segments: [original, trailing]
        )
        try manifest.replaceSegment(segmentIndex: 1, with: children)

        XCTAssertEqual(manifest.expectedSegmentCount, 3)
        XCTAssertEqual(manifest.segments.map(\.segmentIndex), [1, 2, 3])
        XCTAssertTrue(manifest.segments.allSatisfy { $0.segmentCount == 3 })
        XCTAssertEqual(manifest.segments.map(\.startSeconds), [0, 600, 1_200])
        XCTAssertEqual(manifest.segments.map(\.endSeconds), [600, 1_200, 1_800])
        XCTAssertEqual(manifest.segments[0].splitDepth, 1)
        XCTAssertEqual(manifest.segments[1].splitDepth, 1)
        XCTAssertNotEqual(
            manifest.segments[0].outputPath,
            manifest.segments[1].outputPath
        )
    }
}
