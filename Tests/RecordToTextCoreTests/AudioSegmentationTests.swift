import XCTest
@testable import RecordToTextCore

final class AudioSegmentationTests: XCTestCase {
    func testTwentyOneMinutesProducesTwoSegments() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 21 * 60)

        XCTAssertEqual(plan.expectedSegmentCount, 2)
        XCTAssertTrue(plan.requiresSplitting)
        XCTAssertEqual(plan.segments.map(\.index), [1, 2])
        XCTAssertEqual(plan.segments.map(\.durationSeconds), [1_200, 60])
        XCTAssertEqual(
            plan.segments.map(\.audioFileName),
            ["segment-0001.wav", "segment-0002.wav"]
        )
    }

    func testThirtyOneMinutesProducesTwoSegmentsWithTwentyMinuteCap() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 31 * 60)

        XCTAssertEqual(plan.expectedSegmentCount, 2)
        XCTAssertEqual(plan.segments.map(\.durationSeconds), [1_200, 660])
    }

    func testSixtyFiveMinutesProducesFourSegments() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 65 * 60)

        XCTAssertEqual(plan.expectedSegmentCount, 4)
        XCTAssertEqual(
            plan.segments.map(\.startSeconds),
            [0, 1_200, 2_400, 3_600]
        )
        XCTAssertEqual(
            plan.segments.map(\.durationSeconds),
            [1_200, 1_200, 1_200, 300]
        )
        XCTAssertEqual(plan.segments[0].endSeconds, plan.segments[1].startSeconds)
        XCTAssertEqual(plan.segments[1].endSeconds, plan.segments[2].startSeconds)
        XCTAssertEqual(plan.segments[2].endSeconds, plan.segments[3].startSeconds)
        XCTAssertEqual(plan.segments[3].endSeconds, 65 * 60)
    }

    func testOneHundredTwentyMinutesProducesSixFullSegments() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 120 * 60)

        XCTAssertEqual(plan.expectedSegmentCount, 6)
        XCTAssertEqual(
            plan.segments.map(\.durationSeconds),
            [1_200, 1_200, 1_200, 1_200, 1_200, 1_200]
        )
        XCTAssertEqual(plan.segments.last?.endSeconds, 7_200)
    }

    func testExactlyTwentyMinutesDoesNotRequireSplitting() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 20 * 60)

        XCTAssertEqual(plan.expectedSegmentCount, 1)
        XCTAssertFalse(plan.requiresSplitting)
        XCTAssertEqual(plan.segments[0].durationSeconds, 1_200)
        XCTAssertEqual(
            AudioSegmentPlanner.productionMaximumDuration,
            20 * 60
        )
    }

    func testManifestRequiresEverySegmentCompletedExactlyOnce() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 65 * 60)
        var manifest = makeManifest(plan: plan)

        for segment in plan.segments {
            try manifest.mark(
                segmentIndex: segment.index,
                status: .completed,
                completedEventCount: 1
            )
        }

        XCTAssertEqual(
            try manifest.validatedCompletedSegments().map(\.segmentIndex),
            [1, 2, 3, 4]
        )
    }

    func testManifestRejectsMissingSegment() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 65 * 60)
        var manifest = makeManifest(plan: plan)
        manifest.segments.remove(at: 1)

        XCTAssertThrowsError(try manifest.validatedCompletedSegments()) { error in
            guard
                case let AudioSegmentationError.segmentCountMismatch(
                    expected,
                    actual
                ) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, 4)
            XCTAssertEqual(actual, 3)
        }
    }

    func testManifestRejectsDuplicateOrOutOfOrderIndices() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 65 * 60)
        var manifest = makeManifest(plan: plan)
        manifest.segments.swapAt(0, 1)

        XCTAssertThrowsError(try manifest.validatedCompletedSegments()) { error in
            guard
                case let AudioSegmentationError.invalidSegmentIndices(
                    expected,
                    actual
                ) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, [1, 2, 3, 4])
            XCTAssertEqual(actual, [2, 1, 3, 4])
        }
    }

    func testManifestRejectsFailedSegment() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 31 * 60)
        var manifest = makeManifest(plan: plan)
        try manifest.mark(
            segmentIndex: 1,
            status: .completed,
            completedEventCount: 1
        )
        try manifest.mark(
            segmentIndex: 2,
            status: .failed,
            completedEventCount: 0,
            failureMessage: "tail failed"
        )

        XCTAssertThrowsError(try manifest.validatedCompletedSegments()) { error in
            guard
                case let AudioSegmentationError.segmentIncomplete(
                    index,
                    status,
                    completedEventCount
                ) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(index, 2)
            XCTAssertEqual(status, .failed)
            XCTAssertEqual(completedEventCount, 0)
        }
    }

    func testManifestAllowsOnlyExplicitSafetyGapForPartialCloudOutput() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 31 * 60)
        var manifest = makeManifest(plan: plan)
        try manifest.mark(
            segmentIndex: 2,
            status: .blockedBySafety,
            completedEventCount: 0,
            failureMessage: "Google safety block"
        )

        XCTAssertThrowsError(try manifest.validatedCompletedSegments())
        XCTAssertEqual(
            try manifest.validatedSegmentsAllowingSafetyBlocks()
                .map(\.status),
            [.completed, .blockedBySafety]
        )

        try manifest.mark(
            segmentIndex: 2,
            status: .failed,
            completedEventCount: 0,
            failureMessage: "HTTP 503"
        )
        XCTAssertThrowsError(
            try manifest.validatedSegmentsAllowingSafetyBlocks()
        )
    }

    func testManifestRejectsRepeatedCompletionEvent() throws {
        let plan = try AudioSegmentPlanner.makePlan(sourceDuration: 31 * 60)
        var manifest = makeManifest(plan: plan)
        try manifest.mark(
            segmentIndex: 2,
            status: .completed,
            completedEventCount: 2
        )

        XCTAssertThrowsError(try manifest.validatedCompletedSegments()) { error in
            guard
                case let AudioSegmentationError.segmentIncomplete(
                    index,
                    status,
                    completedEventCount
                ) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(index, 2)
            XCTAssertEqual(status, .completed)
            XCTAssertEqual(completedEventCount, 2)
        }
    }

    func testPlannerRejectsInvalidDurations() {
        XCTAssertThrowsError(
            try AudioSegmentPlanner.makePlan(sourceDuration: 0)
        )
        XCTAssertThrowsError(
            try AudioSegmentPlanner.makePlan(
                sourceDuration: 60,
                maximumSegmentDuration: .infinity
            )
        )
    }

    private func makeManifest(
        plan: AudioSegmentationPlan
    ) -> AudioSegmentManifest {
        AudioSegmentManifest(
            jobID: UUID(),
            sourceDurationSeconds: plan.sourceDurationSeconds,
            maximumSegmentDurationSeconds:
                plan.maximumSegmentDurationSeconds,
            expectedSegmentCount: plan.expectedSegmentCount,
            segments: plan.segments.map { segment in
                AudioSegmentRecord(
                    segmentIndex: segment.index,
                    segmentCount: plan.expectedSegmentCount,
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds,
                    audioPath: "/tmp/\(segment.audioFileName)",
                    outputPath: "/tmp/\(segment.transcriptFileName)",
                    status: .completed,
                    completedEventCount: 1
                )
            }
        )
    }
}
