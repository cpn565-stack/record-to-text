import Foundation
import XCTest
@testable import RecordToTextCore

/// Phase 1 §8 acceptance for silence-aware local cut points.
///
/// Rows that need a real model or a human ear — the fixed-vs-silence A/B and the
/// default-on release gate — are not assertable here and are reported as
/// unverified; the feature stays an opt-out advanced setting until they pass.
final class LocalSilencePlannerTests: XCTestCase {

    // MARK: Fixtures

    private var rate: Int64 { Int64(LocalAudioCoordinates.sampleRate) }

    /// Whole seconds at the working sample rate.
    private func samples(_ seconds: Double) -> Int64 {
        Int64((seconds * Double(LocalAudioCoordinates.sampleRate)).rounded(.down))
    }

    /// A one-second pause whose midpoint lands exactly on `seconds`.
    private func pause(at seconds: Double) -> LocalSilenceInterval {
        let center = samples(seconds)
        return LocalSilenceInterval(
            startSample: center - rate / 2,
            endSample: center + rate / 2
        )
    }

    /// A pause whose midpoint lands exactly on a sample offset.
    private func pause(centeredAtSample center: Int64) -> LocalSilenceInterval {
        LocalSilenceInterval(startSample: center - rate / 2, endSample: center + rate / 2)
    }

    private func index(_ intervals: [LocalSilenceInterval]) -> LocalSilenceCandidateIndex {
        LocalSilenceCandidateIndex(intervals: intervals)
    }

    private func rootSource(
        order: Int = 0,
        sampleCount: Int64
    ) -> LocalRootSource {
        LocalRootSource(
            order: order,
            audioURL: URL(fileURLWithPath: "/tmp/normalized.wav"),
            sampleCount: sampleCount,
            pcmSHA256: String(repeating: "c", count: 64)
        )
    }

    private func group(_ start: Int64, _ end: Int64) -> LocalDisplayGroup {
        LocalDisplayGroup(
            groupID: LocalCheckpointID.displayGroup(
                order: 0,
                startSample: start,
                endSample: end
            ),
            startSample: start,
            endSample: end
        )
    }

    // MARK: §4 thresholds

    func testThresholdsTakeInjectedServiceValuesAndKeepTheRestVerbatim() {
        let current = LocalSilenceThresholds.current
        let resolved = current.resolving(
            maximumRootSeconds: 900,
            noiseProfile: "-42dB",
            minimumSilenceDurationSeconds: 0.5
        )
        XCTAssertEqual(resolved.maximumRootSeconds, 900)
        XCTAssertEqual(resolved.noiseProfile, "-42dB")
        XCTAssertEqual(resolved.minimumSilenceDurationSeconds, 0.5)
        // §4's table is fixed; substituting service values must not disturb it.
        XCTAssertEqual(resolved.outerSearchSeconds, 30)
        XCTAssertEqual(resolved.displayGroupSeconds, 600)
        XCTAssertEqual(resolved.displaySearchSeconds, 5)
        XCTAssertEqual(resolved.chunkSeconds, 120)
        XCTAssertEqual(resolved.innerSearchSeconds, 5)
        XCTAssertEqual(resolved.recursiveSearchSeconds, 5)
        XCTAssertEqual(resolved.minimumChildSeconds, 30)
        XCTAssertEqual(resolved.maximumIntervalCount, current.maximumIntervalCount)
    }

    func testThresholdsArePersistedAsFixedPrecisionStringsNotDoubles() {
        XCTAssertEqual(LocalSilenceThresholds.seconds(0.35), "0.350000")
        XCTAssertEqual(LocalSilenceThresholds.seconds(1_200), "1200.000000")
        let encoded = LocalSilenceThresholds.current.canonicalString()
        XCTAssertTrue(encoded.contains(#""minimumSilenceDurationSeconds":"0.350000""#), encoded)
        XCTAssertTrue(encoded.contains(#""chunkSeconds":"120.000000""#), encoded)
        XCTAssertTrue(encoded.contains(#""noiseProfile":"-35dB""#), encoded)
        // The one integer stays an integer; quoting it would break the helper.
        XCTAssertTrue(encoded.contains(#""maximumIntervalCount":100000"#), encoded)
    }

    func testAThresholdDocumentRoundTripsThroughItsCanonicalBytes() throws {
        let original = LocalSilenceThresholds.current.resolving(
            maximumRootSeconds: 1_200,
            noiseProfile: "-35dB",
            minimumSilenceDurationSeconds: 0.35
        )
        let decoded = try JSONDecoder().decode(
            LocalSilenceThresholds.self,
            from: original.canonicalBytes()
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: Cross-language parity

    func testIntervalMidpointsTruncateExactlyLikePythonFloorDivision() {
        XCTAssertEqual(
            LocalSilenceInterval(startSample: 0, endSample: 3).midpointSample, 1
        )
        XCTAssertEqual(
            LocalSilenceInterval(startSample: 1, endSample: 4).midpointSample, 2
        )
        XCTAssertEqual(
            LocalSilenceInterval(startSample: 5, endSample: 6).midpointSample, 5
        )
    }

    // MARK: §3.3 candidate index

    func testTouchingAndOverlappingPausesMergeIntoOneCandidate() {
        let merged = index([
            LocalSilenceInterval(startSample: 0, endSample: 50),
            LocalSilenceInterval(startSample: 40, endSample: 100),
            LocalSilenceInterval(startSample: 100, endSample: 150)
        ])
        XCTAssertEqual(
            merged.intervals,
            [LocalSilenceInterval(startSample: 0, endSample: 150)]
        )
        XCTAssertEqual(merged.candidates, [75])
    }

    func testReversedAndEmptyIntervalsAreDroppedBeforePlanning() {
        let merged = index([
            LocalSilenceInterval(startSample: 200, endSample: 100),
            LocalSilenceInterval(startSample: 300, endSample: 300),
            LocalSilenceInterval(startSample: 400, endSample: 480)
        ])
        XCTAssertEqual(
            merged.intervals,
            [LocalSilenceInterval(startSample: 400, endSample: 480)]
        )
        XCTAssertEqual(merged.candidates, [440])
    }

    func testLatestCandidateIsInclusiveOnBothEnds() {
        let candidates = index([
            LocalSilenceInterval(startSample: 90, endSample: 110),
            LocalSilenceInterval(startSample: 190, endSample: 210)
        ])
        XCTAssertEqual(candidates.latestCandidate(atMost: 200, atLeast: 100), 200)
        XCTAssertEqual(candidates.latestCandidate(atMost: 199, atLeast: 100), 100)
        XCTAssertNil(candidates.latestCandidate(atMost: 99, atLeast: 100))
    }

    func testNearestCandidateBreaksTiesTowardTheEarlierPause() {
        // Midpoints 940 and 1060, both 60 from the target. Built as explicit
        // intervals: the `pause` helpers are one second wide, which at these
        // magnitudes would overlap and merge into a single candidate.
        let candidates = index([
            LocalSilenceInterval(startSample: 900, endSample: 980),
            LocalSilenceInterval(startSample: 1_020, endSample: 1_100)
        ])
        XCTAssertEqual(candidates.candidates, [940, 1_060])
        XCTAssertEqual(candidates.nearestCandidate(to: 1_000, atMost: 2_000, atLeast: 0), 940)
        XCTAssertEqual(candidates.nearestCandidate(to: 1_000, atMost: 1_000, atLeast: 0), 940)
        XCTAssertEqual(candidates.nearestCandidate(to: 1_000, atMost: 2_000, atLeast: 1_000), 1_060)
        XCTAssertEqual(candidates.nearestCandidate(to: 1_030, atMost: 2_000, atLeast: 0), 1_060)
    }

    func testCoverageRequiresTheWholeSpanInsideOnePause() {
        let candidates = index([
            LocalSilenceInterval(startSample: 0, endSample: 100),
            LocalSilenceInterval(startSample: 200, endSample: 300)
        ])
        XCTAssertTrue(candidates.covers(LocalSampleSpan(start: 0, end: 100)))
        XCTAssertTrue(candidates.covers(LocalSampleSpan(start: 10, end: 90)))
        XCTAssertFalse(
            candidates.covers(LocalSampleSpan(start: 0, end: 101)),
            "one sample of unproven audio is enough to refuse §6"
        )
        XCTAssertFalse(
            candidates.covers(LocalSampleSpan(start: 50, end: 250)),
            "two pauses with speech between them cover nothing together"
        )
        XCTAssertFalse(candidates.covers(LocalSampleSpan(start: 100, end: 100)))
        XCTAssertFalse(
            candidates.covers(LocalSampleSpan(start: 200, end: 100)),
            "an empty or reversed span proves nothing about any sample"
        )
    }

    func testEmptyIndexSelectsNothingAndCoversNothing() {
        let empty = LocalSilenceCandidateIndex.empty
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.latestCandidate(atMost: 1_000, atLeast: 0))
        XCTAssertNil(empty.nearestCandidate(to: 500, atMost: 1_000, atLeast: 0))
        XCTAssertFalse(empty.covers(LocalSampleSpan(start: 0, end: 1_000)))
    }

    /// The binary search behind `candidatesInRange` is hand-rolled and runs over
    /// up to `maximumIntervalCount` pauses, so it is checked against a linear
    /// scan rather than against a couple of hand-picked windows.
    func testRangeSearchMatchesALinearScanOverManyPauses() {
        var intervals: [LocalSilenceInterval] = []
        for position in 0..<1_000 {
            let start = Int64(position) * 32_000
            intervals.append(
                LocalSilenceInterval(startSample: start, endSample: start + 8_000)
            )
        }
        let candidates = index(intervals)
        XCTAssertEqual(candidates.candidates.count, 1_000)

        var lowers: [Int64] = []
        var cursor: Int64 = -40_000
        while cursor <= 32_040_000 {
            lowers.append(cursor)
            cursor += 7_919
        }
        for lower in lowers {
            for width: Int64 in [0, 1, 8_000, 32_000, 79_999, 1_000_000] {
                let upper = lower + width
                let inWindow = candidates.candidates.filter { $0 >= lower && $0 <= upper }
                let expectedLatest = inWindow.last
                XCTAssertEqual(
                    candidates.latestCandidate(atMost: upper, atLeast: lower),
                    expectedLatest,
                    "latest in [\(lower), \(upper)]"
                )
                if expectedLatest != nil {
                    let target = (lower + upper) / 2
                    var best: Int64?
                    var bestDistance: Int64?
                    for candidate in inWindow {
                        let distance = abs(candidate - target)
                        if let bestDistance, distance >= bestDistance { continue }
                        best = candidate
                        bestDistance = distance
                    }
                    XCTAssertEqual(
                        candidates.nearestCandidate(to: target, atMost: upper, atLeast: lower),
                        best,
                        "nearest to \(target) in [\(lower), \(upper)]"
                    )
                }
            }
        }
    }

    // MARK: §3.3 detector output → absolute samples

    func testDetectedSecondsBecomeAbsoluteSamplesWithANonZeroScanStart() {
        let absolute = LocalSilenceScanner.absoluteIntervals(
            detected: [DetectedSilence(startSeconds: 1, endSeconds: 2)],
            scanStartSample: samples(10),
            scanEndSample: samples(30)
        )
        XCTAssertEqual(
            absolute,
            [LocalSilenceInterval(startSample: samples(11), endSample: samples(12))]
        )
    }

    func testAPausePastTheScannedRangeIsClampedRatherThanDiscarded() {
        let absolute = LocalSilenceScanner.absoluteIntervals(
            detected: [DetectedSilence(startSeconds: 9, endSeconds: 12)],
            scanStartSample: 0,
            scanEndSample: samples(10)
        )
        XCTAssertEqual(
            absolute,
            [LocalSilenceInterval(startSample: samples(9), endSample: samples(10))]
        )
    }

    func testInvalidDetectedPausesAreDroppedWithoutDisturbingTheRest() {
        let absolute = LocalSilenceScanner.absoluteIntervals(
            detected: [
                DetectedSilence(startSeconds: 5, endSeconds: 3),
                DetectedSilence(startSeconds: .nan, endSeconds: 8),
                DetectedSilence(startSeconds: -1, endSeconds: 2),
                DetectedSilence(startSeconds: 20, endSeconds: 21),
                DetectedSilence(startSeconds: 4, endSeconds: 6)
            ],
            scanStartSample: 0,
            scanEndSample: samples(10)
        )
        XCTAssertEqual(
            absolute,
            [LocalSilenceInterval(startSample: samples(4), endSample: samples(6))]
        )
    }

    func testAnEmptyScanRangeProducesNoCandidates() {
        XCTAssertTrue(
            LocalSilenceScanner.absoluteIntervals(
                detected: [DetectedSilence(startSeconds: 0, endSeconds: 5)],
                scanStartSample: samples(10),
                scanEndSample: samples(10)
            ).isEmpty
        )
    }

    func testScannedPausesAreMergedBeforeTheyBecomeCandidates() {
        let absolute = LocalSilenceScanner.absoluteIntervals(
            detected: [
                DetectedSilence(startSeconds: 1, endSeconds: 2),
                DetectedSilence(startSeconds: 1.5, endSeconds: 3),
                DetectedSilence(startSeconds: 3, endSeconds: 4)
            ],
            scanStartSample: 0,
            scanEndSample: samples(10)
        )
        XCTAssertEqual(
            absolute,
            [LocalSilenceInterval(startSample: samples(1), endSample: samples(4))]
        )
        XCTAssertEqual(index(absolute).candidates, [samples(2) + rate / 2])
    }

    // MARK: H3 — the outer root plan selects from the same merged candidates

    /// Review F4. Two pauses the detector reports a hair apart merge into one
    /// candidate, so every layer selects the same midpoint. Handing the unmerged
    /// seconds to the outer planner picked 1199 s while the inner layers and the
    /// helper picked the merged midpoint 1198.5 s — one plan, two opinions about
    /// where the first root ends.
    func testTheOuterPlanSelectsTheMergedCandidateSoEveryLayerAgrees() throws {
        let candidates = index([
            LocalSilenceInterval(startSample: samples(1197), endSample: samples(1199)),
            LocalSilenceInterval(startSample: samples(1198), endSample: samples(1200))
        ])
        XCTAssertEqual(
            candidates.intervals,
            [LocalSilenceInterval(startSample: samples(1197), endSample: samples(1200))]
        )
        XCTAssertEqual(candidates.candidates, [samples(1197) + (samples(1200) - samples(1197)) / 2])

        let plan = try LocalSilenceScanner.makeOuterPlan(
            workStartSample: 0,
            sampleCount: samples(2400),
            candidates: candidates
        )
        XCTAssertEqual(plan.segments.map(\.startSeconds), [0, 1198.5, 2398.5])
        XCTAssertEqual(plan.segments.map(\.durationSeconds), [1198.5, 1200, 1.5])
        XCTAssertEqual(plan.segments.map(\.endSeconds).last, 2400)
        XCTAssertEqual(plan.sourceDurationSeconds, 2400)
        // The outer boundary is the merged midpoint, not the later pause's end.
        XCTAssertEqual(candidates.candidates[0], samples(1198.5))
    }

    /// §4 row 1: with nothing to move onto, the outer plan hard-cuts on the cap
    /// and still tiles the work range exactly. Coverage must not depend on a
    /// detector finding anything.
    func testTheOuterPlanHardCutsOnTheCapWhenNoCandidateIsInRange() throws {
        let plan = try LocalSilenceScanner.makeOuterPlan(
            workStartSample: 0,
            sampleCount: samples(2400),
            candidates: .empty
        )
        XCTAssertEqual(plan.segments.map(\.startSeconds), [0, 1200])
        XCTAssertEqual(plan.segments.map(\.durationSeconds), [1200, 1200])
        let counts = LocalSilenceScanner.countOuterCuts(
            plan: plan, maximumSegmentDuration: 1200
        )
        XCTAssertEqual(counts.silenceCuts, 0)
        XCTAssertEqual(counts.fallbacks, 1)
    }

    /// A pause beyond the 30-second search window must not move the cut, and a
    /// pause the window does reach must not push the root past its cap.
    func testTheOuterPlanIgnoresCandidatesOutsideItsSearchWindow() throws {
        let plan = try LocalSilenceScanner.makeOuterPlan(
            workStartSample: 0,
            sampleCount: samples(2400),
            // Midpoint at 1150 s: 50 s before the 1200 s cap, outside 30 s.
            candidates: index([pause(at: 1150)])
        )
        XCTAssertEqual(plan.segments.map(\.durationSeconds), [1200, 1200])

        let moved = try LocalSilenceScanner.makeOuterPlan(
            workStartSample: 0,
            sampleCount: samples(2400),
            candidates: index([pause(at: 1190)])
        )
        XCTAssertEqual(moved.segments.map(\.durationSeconds).first, 1190)
        XCTAssertLessThanOrEqual(moved.segments.map(\.durationSeconds).first ?? 0, 1200)
    }

    /// A nonzero slice start is the original-recording offset; segment seconds
    /// stay relative to the normalized PCM so the extraction adapter never
    /// applies the offset twice. Odd sample counts must still tile exactly.
    func testTheOuterPlanTilesExactlyFromANonZeroWorkStartWithOddLengths() throws {
        let workStart = samples(5)
        // 1198.5 s of audio: an odd number of samples, not a round second.
        let sampleCount = samples(1198.5) + 1
        let plan = try LocalSilenceScanner.makeOuterPlan(
            workStartSample: workStart,
            sampleCount: sampleCount,
            candidates: .empty
        )
        XCTAssertEqual(plan.segments.map(\.startSeconds).first, 0)
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(
            plan.segments.reduce(0.0) { $0 + $1.durationSeconds },
            LocalAudioCoordinates.seconds(forSamples: sampleCount),
            accuracy: 1e-9
        )

        // Two roots from a nonzero start, with a candidate inside the window.
        let candidates = index([pause(centeredAtSample: workStart + samples(1190))])
        let split = try LocalSilenceScanner.makeOuterPlan(
            workStartSample: workStart,
            sampleCount: samples(1300),
            candidates: candidates
        )
        XCTAssertEqual(split.segments.map(\.startSeconds), [0, 1190])
        XCTAssertEqual(split.segments.map(\.durationSeconds), [1190, 110])
        XCTAssertEqual(split.segments.map(\.endSeconds).last, 1300)
    }

    /// A degenerate range is a refusal, not a zero-segment plan that would make
    /// every later coverage check pass vacuously.
    func testTheOuterPlanRefusesADegenerateRange() throws {
        XCTAssertThrowsError(
            try LocalSilenceScanner.makeOuterPlan(
                workStartSample: 0, sampleCount: 0, candidates: .empty
            )
        )
        XCTAssertThrowsError(
            try LocalSilenceScanner.makeOuterPlan(
                workStartSample: -1, sampleCount: samples(60), candidates: .empty
            )
        )
        XCTAssertThrowsError(
            try LocalSilenceScanner.makeOuterPlan(
                workStartSample: Int64.max, sampleCount: Int64.max, candidates: .empty
            )
        )
    }

    // MARK: §7 outer cut tallies

    /// `SilenceAwareSegmentPlanner` accumulates from the previous boundary, so
    /// after one moved cut a later boundary can be a fixed cap-length step while
    /// sitting on a sample count that is not a multiple of the cap. Counting
    /// multiples instead would report that fallback as a silence cut.
    func testOuterCountsFollowTheAccumulatingNominalNotMultiplesOfTheCap() throws {
        let plan = try SilenceAwareSegmentPlanner.makePlan(
            sourceDuration: 300,
            maximumSegmentDuration: 120,
            silences: [DetectedSilence(startSeconds: 117.5, endSeconds: 118.5)],
            searchWindow: 30,
            minimumSilenceDuration: 0.35,
            minimumSegmentDuration: 60
        )
        XCTAssertEqual(
            plan.segments.map { ($0.startSeconds, $0.endSeconds) }.map { "\($0.0)-\($0.1)" },
            ["0.0-118.0", "118.0-238.0", "238.0-300.0"]
        )
        let counts = LocalSilenceScanner.countOuterCuts(
            plan: plan,
            maximumSegmentDuration: 120
        )
        XCTAssertEqual(counts.silenceCuts, 1)
        XCTAssertEqual(counts.fallbacks, 1, "238 is 118 + 120, so nothing moved here")
    }

    func testAnAllFixedOuterPlanCountsEveryCutAsAFallback() throws {
        let plan = try SilenceAwareSegmentPlanner.makePlan(
            sourceDuration: 300,
            maximumSegmentDuration: 120,
            silences: [],
            searchWindow: 30,
            minimumSilenceDuration: 0.35,
            minimumSegmentDuration: 60
        )
        let counts = LocalSilenceScanner.countOuterCuts(
            plan: plan,
            maximumSegmentDuration: 120
        )
        XCTAssertEqual(counts.silenceCuts, 0)
        XCTAssertEqual(counts.fallbacks, plan.segments.count - 1)
        // §8: the fixed fallback still covers exactly the same audio.
        XCTAssertEqual(plan.segments.first?.startSeconds, 0)
        XCTAssertEqual(plan.segments.last?.endSeconds, 300)
        XCTAssertEqual(
            plan.segments.reduce(0.0) { $0 + $1.durationSeconds },
            300,
            accuracy: 1e-9
        )
    }

    func testEveryMovedOuterBoundaryIsCountedOnce() throws {
        let plan = try SilenceAwareSegmentPlanner.makePlan(
            sourceDuration: 300,
            maximumSegmentDuration: 120,
            silences: [
                DetectedSilence(startSeconds: 117.5, endSeconds: 118.5),
                DetectedSilence(startSeconds: 235.5, endSeconds: 236.5)
            ],
            searchWindow: 30,
            minimumSilenceDuration: 0.35,
            minimumSegmentDuration: 60
        )
        let counts = LocalSilenceScanner.countOuterCuts(
            plan: plan,
            maximumSegmentDuration: 120
        )
        XCTAssertEqual(counts.silenceCuts, 2)
        XCTAssertEqual(counts.fallbacks, 0)
    }

    func testAZeroCapReportsNoOuterCounts() throws {
        let plan = try AudioSegmentPlanner.makePlan(
            sourceDuration: 300,
            maximumSegmentDuration: 120
        )
        let counts = LocalSilenceScanner.countOuterCuts(plan: plan, maximumSegmentDuration: 0)
        XCTAssertEqual(counts.silenceCuts, 0)
        XCTAssertEqual(counts.fallbacks, 0)
    }

    // MARK: §8 row 1 — a pause just before or after the cap

    func testALimitBoundaryTakesThePauseBeforeTheCapAndNeverOneAfterIt() {
        // The 122-second pause is nearer the *later* side of the cap; choosing it
        // would push the chunk past 120 seconds, which §4 forbids outright.
        let candidates = index([pause(at: 117), pause(at: 122)])
        let decision = LocalSilenceBoundarySelector.limitBoundary(
            limit: samples(120),
            searchSamples: samples(5),
            lowerBound: 0,
            upperBound: samples(300),
            candidates: candidates
        )
        XCTAssertEqual(decision.boundary, samples(117))
        XCTAssertTrue(decision.usedSilence)
        XCTAssertLessThanOrEqual(decision.boundary, samples(120))
    }

    func testALimitBoundaryWithNoCandidateKeepsTheCap() {
        let decision = LocalSilenceBoundarySelector.limitBoundary(
            limit: samples(120),
            searchSamples: samples(5),
            lowerBound: 0,
            upperBound: samples(300),
            candidates: index([pause(at: 60)])
        )
        XCTAssertEqual(decision.boundary, samples(120))
        XCTAssertFalse(decision.usedSilence)
    }

    func testAPauseExactlyOnTheCapMovedNothingAndIsNotCountedAsACut() {
        let decision = LocalSilenceBoundarySelector.limitBoundary(
            limit: samples(120),
            searchSamples: samples(5),
            lowerBound: 0,
            upperBound: samples(300),
            candidates: index([pause(at: 120)])
        )
        XCTAssertEqual(decision.boundary, samples(120))
        XCTAssertFalse(
            decision.usedSilence,
            "counting an unmoved boundary would overstate the effect of §4"
        )
    }

    func testALimitBoundaryNeverReturnsItsOwnLowerBound() {
        let decision = LocalSilenceBoundarySelector.limitBoundary(
            limit: samples(120),
            searchSamples: samples(5),
            lowerBound: samples(117),
            upperBound: samples(300),
            candidates: index([pause(at: 117)])
        )
        XCTAssertEqual(decision.boundary, samples(120))
        XCTAssertFalse(decision.usedSilence)
    }

    // MARK: §8 rows 3 and 4 — the recursion floor owns termination

    func testASixtySecondParentAtTheCapOnlyAdmitsThirtyPlusThirty() {
        let parent = samples(60)
        let floor = samples(30)
        // A pause at 29 s is inside the ±5 s search window but would leave a
        // 29-second child, and 30 s is the recursion floor.
        let decision = LocalSilenceBoundarySelector.nearestBoundary(
            target: parent / 2,
            searchSamples: samples(5),
            lowerBound: floor,
            upperBound: parent - floor,
            candidates: index([pause(at: 29)])
        )
        XCTAssertEqual(decision.boundary, floor)
        XCTAssertFalse(decision.usedSilence)
        XCTAssertEqual(decision.boundary, parent - decision.boundary)
    }

    func testAShortTailHasNoLegalWindowAndTheSelectorRefusesToGuess() {
        // A 45-second parent: the legal range [30, 15] is empty. Termination
        // belongs to the recursion guard (covered in the Python suite); the
        // selector's job is only to decline to invent a boundary.
        let decision = LocalSilenceBoundarySelector.nearestBoundary(
            target: samples(22),
            searchSamples: samples(5),
            lowerBound: samples(30),
            upperBound: samples(15),
            candidates: index([pause(at: 22)])
        )
        XCTAssertFalse(decision.usedSilence)
    }

    func testANearestBoundaryTakesTheCloserPauseInsideItsWindow() {
        let decision = LocalSilenceBoundarySelector.nearestBoundary(
            target: samples(60),
            searchSamples: samples(5),
            lowerBound: samples(30),
            upperBound: samples(90),
            candidates: index([pause(at: 57), pause(at: 64)])
        )
        XCTAssertEqual(decision.boundary, samples(57))
        XCTAssertTrue(decision.usedSilence)
    }

    func testANearestBoundaryIgnoresAPauseOutsideItsWindow() {
        let decision = LocalSilenceBoundarySelector.nearestBoundary(
            target: samples(60),
            searchSamples: samples(5),
            lowerBound: samples(30),
            upperBound: samples(90),
            candidates: index([pause(at: 50)])
        )
        XCTAssertEqual(decision.boundary, samples(60))
        XCTAssertFalse(decision.usedSilence)
    }

    func testARootBoundaryIsPreferredOverACloserPause() {
        let target = samples(600)
        let snapped = LocalSilenceBoundarySelector.nearestRootBoundary(
            to: target,
            searchSamples: samples(5),
            rootBoundaries: [target - samples(3)],
            lowerBound: 1,
            upperBound: samples(1_800)
        )
        XCTAssertEqual(snapped, target - samples(3))
        XCTAssertNil(
            LocalSilenceBoundarySelector.nearestRootBoundary(
                to: target,
                searchSamples: samples(5),
                rootBoundaries: [target - samples(20)],
                lowerBound: 1,
                upperBound: samples(1_800)
            )
        )
    }

    // MARK: §4 step 2 / §5 — the ten-minute display grid

    func testDisplayGroupTargetsStayOnTheAbsoluteGridWithNoAccumulatedDrift() throws {
        let workEnd = samples(1_800)
        // k=1 has two equidistant pauses (the earlier must win); k=2 has a single
        // pause four seconds *after* the absolute target. Planning from the
        // previous group's end instead would put that pause outside the window.
        let candidates = index([
            pause(centeredAtSample: samples(600) - samples(4)),
            pause(centeredAtSample: samples(600) + samples(4)),
            pause(centeredAtSample: samples(1_200) + samples(4))
        ])
        var tally: LocalPlannerCutTally? = LocalPlannerCutTally()
        let groups = try LocalCheckpointPlanner.makeDisplayGroups(
            workStartSample: 0,
            workEndSample: workEnd,
            candidates: candidates,
            tally: &tally
        )
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].startSample, 0)
        XCTAssertEqual(groups[0].endSample, samples(600) - samples(4))
        XCTAssertEqual(
            groups[1].endSample,
            samples(1_200) + samples(4),
            "the second target is 2×600 s from the work start, not from the first cut"
        )
        XCTAssertEqual(groups[2].endSample, workEnd)
        XCTAssertEqual(tally?.displayMovedBySilence, 2)
        XCTAssertEqual(tally?.displaySnappedToRoot, 0)
        // §5: no internal boundary drifts more than five seconds from its target.
        for position in 1..<groups.count {
            let target = samples(Double(position) * 600)
            XCTAssertLessThanOrEqual(abs(groups[position - 1].endSample - target), samples(5))
        }
    }

    func testDisplayGroupStartAndEndAreFixedAndNeverMoveToAPause() throws {
        let workStart = samples(30)
        let workEnd = workStart + samples(1_800)
        let candidates = index([
            pause(centeredAtSample: workStart + samples(600) - samples(4)),
            pause(centeredAtSample: workEnd)
        ])
        let groups = try LocalCheckpointPlanner.makeDisplayGroups(
            workStartSample: workStart,
            workEndSample: workEnd,
            candidates: candidates
        )
        XCTAssertEqual(groups.first?.startSample, workStart)
        XCTAssertEqual(groups.last?.endSample, workEnd)
        XCTAssertEqual(groups[0].endSample, workStart + samples(600) - samples(4))
        for position in 1..<groups.count {
            let target = workStart + samples(Double(position) * 600)
            XCTAssertLessThanOrEqual(abs(groups[position - 1].endSample - target), samples(5))
        }
    }

    func testWithNoRootsAndNoCandidatesTheGridIsTheExactTenMinuteGrid() throws {
        let planned = try LocalCheckpointPlanner.makeDisplayGroups(
            workStartSample: 0,
            workEndSample: samples(1_800)
        )
        let exact = try LocalCheckpointManifest.makeDisplayGroups(
            workStartSample: 0,
            workEndSample: samples(1_800)
        )
        XCTAssertEqual(planned.map(\.startSample), exact.map(\.startSample))
        XCTAssertEqual(planned.map(\.endSample), exact.map(\.endSample))
    }

    func testSnappingToARootBoundaryWinsOverACloserPause() throws {
        let target = samples(600)
        var tally: LocalPlannerCutTally? = LocalPlannerCutTally()
        let groups = try LocalCheckpointPlanner.makeDisplayGroups(
            workStartSample: 0,
            workEndSample: samples(1_800),
            rootBoundaries: [target - samples(3)],
            candidates: index([pause(centeredAtSample: target - samples(1))]),
            tally: &tally
        )
        XCTAssertEqual(groups[0].endSample, target - samples(3))
        XCTAssertEqual(tally?.displaySnappedToRoot, 1)
        XCTAssertEqual(tally?.displayMovedBySilence, 0)
    }

    func testTheSameInputAlwaysProducesTheSamePlan() throws {
        let candidates = index([
            pause(centeredAtSample: samples(600) - samples(4)),
            pause(centeredAtSample: samples(600) + samples(4)),
            pause(at: 117),
            pause(at: 1_300)
        ])
        let sources = [rootSource(sampleCount: samples(1_800))]
        func plan() throws -> ([LocalDisplayGroup], [LocalRootPlan]) {
            var tally: LocalPlannerCutTally? = LocalPlannerCutTally()
            let groups = try LocalCheckpointPlanner.makeDisplayGroups(
                workStartSample: 0,
                workEndSample: samples(1_800),
                candidates: candidates,
                tally: &tally
            )
            let roots = try LocalCheckpointPlanner.makeRootPlans(
                workStartSample: 0,
                sources: sources,
                chunkSeconds: 120,
                displayGroups: groups,
                candidates: candidates,
                tally: &tally
            )
            return (groups, roots)
        }
        let first = try plan()
        let second = try plan()
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
    }

    // MARK: §4 step 3 — initial chunks

    func testInitialChunksNeverCrossADisplayGroup() throws {
        let workEnd = samples(1_800)
        let groups = try LocalCheckpointManifest.makeDisplayGroups(
            workStartSample: 0,
            workEndSample: workEnd
        )
        var tally: LocalPlannerCutTally? = LocalPlannerCutTally()
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [rootSource(sampleCount: workEnd)],
            chunkSeconds: 120,
            displayGroups: groups,
            candidates: index([pause(at: 117), pause(at: 599), pause(at: 1_201)]),
            tally: &tally
        )
        XCTAssertEqual(roots.count, 1)
        let chunks = roots[0].initialChunks
        // 6 + 5 + 5: the moved cut inside the first group leaves a 3-second tail
        // against the group boundary, which §4 requires to be kept.
        XCTAssertEqual(chunks.count, 16)
        XCTAssertTrue(
            chunks.contains {
                $0.startSample == samples(117) + 4 * samples(120)
                    && $0.endSample == samples(600)
            },
            "the tail before a group boundary survives even though it is under 30 s"
        )
        for chunk in chunks {
            XCTAssertTrue(
                groups.contains {
                    $0.startSample <= chunk.startSample && chunk.endSample <= $0.endSample
                },
                "chunk \(chunk.startSample)–\(chunk.endSample) crosses a display group"
            )
            XCTAssertLessThanOrEqual(chunk.endSample - chunk.startSample, samples(120))
        }
        // The 599- and 1201-second pauses are near group boundaries, which are
        // cuts already; being near a boundary must not be counted as a move.
        XCTAssertEqual(tally?.innerSilenceCuts, 1)
    }

    func testAnInnerCutMovesOntoAPauseJustBeforeTheChunkCap() throws {
        var tally: LocalPlannerCutTally? = LocalPlannerCutTally()
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [rootSource(sampleCount: samples(1_800))],
            chunkSeconds: 120,
            displayGroups: [group(0, samples(1_800))],
            candidates: index([pause(at: 117)]),
            tally: &tally
        )
        let chunks = roots[0].initialChunks
        XCTAssertEqual(chunks[0].startSample, 0)
        XCTAssertEqual(chunks[0].endSample, samples(117))
        XCTAssertEqual(chunks[1].startSample, samples(117))
        XCTAssertEqual(tally?.innerSilenceCuts, 1)
        XCTAssertGreaterThan(tally?.innerFallbacks ?? 0, 0)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.endSample - chunk.startSample, samples(120))
        }
    }

    func testWithoutCandidatesChunksLandOnTheExactChunkGrid() throws {
        var tally: LocalPlannerCutTally? = LocalPlannerCutTally()
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [rootSource(sampleCount: samples(600))],
            chunkSeconds: 120,
            displayGroups: [group(0, samples(600))],
            candidates: .empty,
            tally: &tally
        )
        let chunks = roots[0].initialChunks
        XCTAssertEqual(chunks.map(\.startSample), (0..<5).map { Int64($0) * samples(120) })
        XCTAssertEqual(chunks.map(\.endSample), (1...5).map { Int64($0) * samples(120) })
        XCTAssertEqual(tally?.innerSilenceCuts, 0)
        XCTAssertEqual(
            tally?.innerFallbacks, 4,
            "the last chunk ends exactly on the sub-interval, so no decision is made"
        )
    }

    /// §4: the 30-second floor belongs to recursion. A tail created by a group
    /// boundary is real audio and must survive, however short.
    func testABoundaryTailShorterThanThirtySecondsIsKeptNotDeleted() throws {
        let workEnd = samples(1_800)
        let boundary = samples(120) + 10_000
        var tally: LocalPlannerCutTally? = LocalPlannerCutTally()
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [rootSource(sampleCount: workEnd)],
            chunkSeconds: 120,
            displayGroups: [group(0, boundary), group(boundary, workEnd)],
            candidates: .empty,
            tally: &tally
        )
        let chunks = roots[0].initialChunks
        XCTAssertTrue(
            chunks.contains {
                $0.startSample == samples(120) && $0.endSample == boundary
            },
            "the 0.625-second tail before the group boundary must not be dropped"
        )
        XCTAssertEqual(chunks.first?.startSample, 0)
        XCTAssertEqual(chunks.last?.endSample, workEnd)
        XCTAssertEqual(tally?.innerSilenceCuts, 0)
    }

    func testChunksTileTheirRootExactlyAndHaveUniqueIDs() throws {
        let workEnd = samples(1_800)
        let groups = try LocalCheckpointPlanner.makeDisplayGroups(
            workStartSample: 0,
            workEndSample: workEnd
        )
        var tally: LocalPlannerCutTally? = LocalPlannerCutTally()
        let roots = try LocalCheckpointPlanner.makeRootPlans(
            workStartSample: 0,
            sources: [
                rootSource(order: 0, sampleCount: samples(900)),
                LocalRootSource(
                    order: 1,
                    audioURL: URL(fileURLWithPath: "/tmp/b.wav"),
                    sampleCount: samples(900),
                    pcmSHA256: String(repeating: "d", count: 64)
                )
            ],
            chunkSeconds: 120,
            displayGroups: groups,
            candidates: index([pause(at: 117), pause(at: 1_017)]),
            tally: &tally
        )
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots[0].startSample, 0)
        XCTAssertEqual(roots[1].startSample, samples(900))
        XCTAssertEqual(
            tally?.innerSilenceCuts, 2,
            "one moved cut inside each root, so roots are planned independently"
        )
        var ids = Set<String>()
        for root in roots {
            XCTAssertEqual(root.initialChunks.first?.startSample, root.startSample)
            XCTAssertEqual(root.initialChunks.last?.endSample, root.endSample)
            var previous = root.startSample
            for chunk in root.initialChunks {
                XCTAssertEqual(chunk.startSample, previous)
                XCTAssertGreaterThan(chunk.endSample, chunk.startSample)
                previous = chunk.endSample
                XCTAssertTrue(ids.insert(chunk.nodeID).inserted, "duplicate \(chunk.nodeID)")
            }
        }
    }

    // MARK: §5 — the merger's contract, enforced at freeze time

    func testAChunkStraddlingADisplayGroupBoundaryIsRejected() throws {
        let identity = makeIdentityDocument(workStart: 0, workEnd: samples(120))
        let identityDigest = LocalDigest.sha256(identity.canonicalBytes())
        let rootID = LocalCheckpointID.root(order: 0, startSample: 0, endSample: samples(120))
        let straddling = LocalRootPlan(
            rootID: rootID,
            order: 0,
            startSample: 0,
            endSample: samples(120),
            pcmSHA256: String(repeating: "c", count: 64),
            audioRelativePath: "audio/\(rootID).wav",
            stateRelativePath: "roots/\(rootID).json",
            initialChunks: [
                LocalChunkPlan(
                    nodeID: LocalCheckpointID.chunk(
                        rootID: rootID,
                        order: 0,
                        startSample: 0,
                        endSample: samples(120)
                    ),
                    startSample: 0,
                    endSample: samples(120)
                )
            ]
        )
        let groups = [group(0, samples(60)), group(samples(60), samples(120))]
        let manifest = LocalCheckpointManifest(
            jobID: identity.jobID,
            identityDigest: identityDigest,
            inferenceDigest: identity.inference.digest,
            normalizationDigest: LocalDigest.sha256(identity.normalizationProfile),
            workStartSample: 0,
            workEndSample: samples(120),
            planID: LocalCheckpointManifest.computePlanID(
                workStartSample: 0,
                workEndSample: samples(120),
                roots: [straddling],
                displayGroups: groups
            ),
            roots: [straddling],
            displayGroups: groups,
            createdAt: "2026-09-27T00:00:00Z"
        )
        XCTAssertThrowsError(
            try LocalCheckpointValidator.validate(
                manifest: manifest,
                identity: identity,
                identityDigest: identityDigest
            )
        ) { error in
            guard case let LocalCheckpointError.invalidField(field, reason) = error else {
                return XCTFail("expected invalidField, got \(error)")
            }
            XCTAssertTrue(field.hasPrefix("chunk."), field)
            XCTAssertTrue(reason.contains("displayGroup"), reason)
        }
    }

    func testChunksAlignedToGroupBoundariesValidate() throws {
        let identity = makeIdentityDocument(workStart: 0, workEnd: samples(120))
        let identityDigest = LocalDigest.sha256(identity.canonicalBytes())
        let rootID = LocalCheckpointID.root(order: 0, startSample: 0, endSample: samples(120))
        let chunks = [Int64(0), samples(60)].enumerated().map { position, start -> LocalChunkPlan in
            let end = start + samples(60)
            return LocalChunkPlan(
                nodeID: LocalCheckpointID.chunk(
                    rootID: rootID,
                    order: position,
                    startSample: start,
                    endSample: end
                ),
                startSample: start,
                endSample: end
            )
        }
        let root = LocalRootPlan(
            rootID: rootID,
            order: 0,
            startSample: 0,
            endSample: samples(120),
            pcmSHA256: String(repeating: "c", count: 64),
            audioRelativePath: "audio/\(rootID).wav",
            stateRelativePath: "roots/\(rootID).json",
            initialChunks: chunks
        )
        let groups = [group(0, samples(60)), group(samples(60), samples(120))]
        let manifest = LocalCheckpointManifest(
            jobID: identity.jobID,
            identityDigest: identityDigest,
            inferenceDigest: identity.inference.digest,
            normalizationDigest: LocalDigest.sha256(identity.normalizationProfile),
            workStartSample: 0,
            workEndSample: samples(120),
            planID: LocalCheckpointManifest.computePlanID(
                workStartSample: 0,
                workEndSample: samples(120),
                roots: [root],
                displayGroups: groups
            ),
            roots: [root],
            displayGroups: groups,
            createdAt: "2026-09-27T00:00:00Z"
        )
        XCTAssertNoThrow(
            try LocalCheckpointValidator.validate(
                manifest: manifest,
                identity: identity,
                identityDigest: identityDigest
            )
        )
    }

    // MARK: §2 — a resume cuts where the frozen plan says

    func testAFrozenPlanResumesWithoutApplyingTheSliceOffsetTwice() throws {
        let workStart = samples(30)
        let workEnd = workStart + samples(180)
        let roots = [
            makeRootPlan(order: 0, start: workStart, end: workStart + samples(120)),
            makeRootPlan(order: 1, start: workStart + samples(120), end: workEnd)
        ]
        let manifest = LocalCheckpointManifest(
            jobID: "job-1",
            identityDigest: String(repeating: "0", count: 64),
            inferenceDigest: String(repeating: "1", count: 64),
            normalizationDigest: String(repeating: "2", count: 64),
            workStartSample: workStart,
            workEndSample: workEnd,
            planID: "plan-" + String(repeating: "3", count: 59),
            plannerVersion: LocalPlannerStrategy.silence,
            roots: roots,
            displayGroups: [group(workStart, workEnd)],
            createdAt: "2026-09-27T00:00:00Z"
        )
        let plan = try LocalCheckpointPlanner.segmentPlan(
            from: manifest,
            maximumSegmentDuration: 1_200
        )
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].startSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(plan.segments[0].durationSeconds, 120, accuracy: 1e-9)
        XCTAssertEqual(plan.segments[1].startSeconds, 120, accuracy: 1e-9)
        XCTAssertEqual(plan.segments[1].durationSeconds, 60, accuracy: 1e-9)
        XCTAssertEqual(plan.sourceDurationSeconds, 180, accuracy: 1e-9)
        XCTAssertEqual(plan.maximumSegmentDurationSeconds, 1_200)
    }

    func testAFrozenPlanWithoutRootsIsRefusedRatherThanCutToNothing() {
        let manifest = LocalCheckpointManifest(
            jobID: "job-1",
            identityDigest: String(repeating: "0", count: 64),
            inferenceDigest: String(repeating: "1", count: 64),
            normalizationDigest: String(repeating: "2", count: 64),
            workStartSample: 0,
            workEndSample: samples(120),
            planID: "plan-" + String(repeating: "3", count: 59),
            roots: [],
            displayGroups: [],
            createdAt: "2026-09-27T00:00:00Z"
        )
        XCTAssertThrowsError(
            try LocalCheckpointPlanner.segmentPlan(
                from: manifest,
                maximumSegmentDuration: 1_200
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalPlannerError,
                .frozenPlanUnusable(reason: "計畫沒有任何 root。")
            )
        }
    }

    // MARK: §3.7 / §7 — the persisted analysis

    private func makeSilencePlan(
        intervals: [LocalSilenceInterval],
        truncated: Bool = false
    ) -> LocalSilencePlan {
        LocalSilencePlan(
            coveredStartSample: 0,
            coveredEndSample: samples(1_800),
            scanPCMSHA256: String(repeating: "c", count: 64),
            normalizationDigest: LocalDigest.sha256(
                LocalNormalizationProfile.current
            ),
            sourceSHA256: String(repeating: "f", count: 64),
            truncated: truncated,
            intervals: intervals,
            scanCount: 1,
            scannedAudioSeconds: 1_800,
            scanElapsedMilliseconds: 1_234.5,
            cacheHitCount: 0,
            outerSilenceCuts: 2,
            outerFallbacks: 1,
            innerSilenceCuts: 3,
            innerFallbacks: 4
        )
    }

    func testASilencePlanRoundTripsThroughItsOwnDigest() throws {
        let plan = makeSilencePlan(intervals: [pause(at: 117), pause(at: 700)])
        let layout = LocalCheckpointLayout(
            recoveryDirectory: makeTemporaryDirectory()
        )
        try LocalSilencePlanStore.write(plan, to: layout)
        let loaded = try LocalSilencePlanStore.load(
            from: layout,
            expectedDigest: plan.digest
        )
        XCTAssertEqual(loaded, plan)
        XCTAssertEqual(loaded?.intervals, plan.intervals)
        XCTAssertEqual(loaded?.thresholds, LocalSilenceThresholds.current)
        XCTAssertEqual(loaded?.scanElapsedMilliseconds, 1_234.5)
        // The helper reads these numbers, so the digest must cover the real bytes.
        let bytes = try Data(contentsOf: layout.silencePlanURL)
        XCTAssertEqual(LocalDigest.sha256(bytes), plan.digest)
        let summary = loaded?.metricsSummary() ?? ""
        for key in [
            "silence_scan_count=1",
            "silence_scanned_audio_seconds=1800.000",
            "silence_scan_elapsed_ms=1234.500",
            "silence_cache_hits=0",
            "outer_silence_cuts=2",
            "outer_fallbacks=1",
            "inner_silence_cuts=3",
            "inner_fallbacks=4",
            "intervals=2"
        ] {
            XCTAssertTrue(summary.contains(key), "\(key) missing from \(summary)")
        }
    }

    func testATamperedSilencePlanIsRefused() throws {
        let plan = makeSilencePlan(intervals: [pause(at: 117)])
        let layout = LocalCheckpointLayout(recoveryDirectory: makeTemporaryDirectory())
        try LocalSilencePlanStore.write(plan, to: layout)
        let bytes = try Data(contentsOf: layout.silencePlanURL)
        let needle = Data(String(repeating: "c", count: 64).utf8)
        let replacement = Data(String(repeating: "d", count: 64).utf8)
        guard let range = bytes.firstRange(of: needle) else {
            return XCTFail("the fixture must contain its own PCM digest")
        }
        var tampered = bytes
        tampered.replaceSubrange(range, with: replacement)
        try tampered.write(to: layout.silencePlanURL)
        XCTAssertThrowsError(
            try LocalSilencePlanStore.load(from: layout, expectedDigest: plan.digest)
        ) { error in
            guard case let LocalCheckpointError.digestMismatch(kind, _, _) = error else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
            XCTAssertEqual(kind, "silence-plan.json")
        }
    }

    func testARecordedDigestWithNoFileIsRefusedButNoDigestLoadsAsNil() throws {
        let empty = LocalCheckpointLayout(recoveryDirectory: makeTemporaryDirectory())
        XCTAssertNil(try LocalSilencePlanStore.load(from: empty, expectedDigest: nil))
        XCTAssertThrowsError(
            try LocalSilencePlanStore.load(
                from: empty,
                expectedDigest: String(repeating: "0", count: 64)
            )
        ) { error in
            guard case LocalCheckpointError.missingFile = error else {
                return XCTFail("expected missingFile, got \(error)")
            }
        }
    }

    /// §3.7: past the storage cap the *cut plan* survives and only the interval
    /// list is dropped, so the helper finds no candidates and takes a legal
    /// midpoint instead of a second detector pipeline.
    func testATruncatedScanKeepsTheCutPlanAndDropsTheIntervalList() throws {
        let intervals = [pause(at: 117), pause(at: 700)]
        let scan = LocalSilenceScan(
            outerPlan: try AudioSegmentPlanner.makePlan(
                sourceDuration: 1_800,
                maximumSegmentDuration: 1_200
            ),
            candidates: index(intervals),
            intervals: intervals,
            truncated: true,
            thresholds: .current,
            metrics: SilenceAnalysisMetrics(scanCount: 1, scannedAudioSeconds: 1_800),
            scanPCMSHA256: String(repeating: "c", count: 64),
            normalizationDigest: LocalDigest.sha256(
                LocalNormalizationProfile.current
            ),
            sourceSHA256: String(repeating: "f", count: 64),
            coveredStartSample: 0,
            coveredEndSample: samples(1_800),
            outerSilenceCuts: 0,
            outerFallbacks: 0
        )
        let plan = scan.silencePlan(inner: LocalPlannerCutTally())
        XCTAssertTrue(plan.truncated)
        XCTAssertTrue(
            plan.intervals.isEmpty,
            "the persisted list is what the helper reads, so it must really be empty"
        )
        XCTAssertTrue(plan.candidateIndex.isEmpty)
        XCTAssertTrue(plan.metricsSummary().contains("已超過保存上限"))
        // The cut plan the truncation could not keep is still in these counts.
        XCTAssertEqual(plan.scanCount, 1)
        XCTAssertEqual(plan.scannedAudioSeconds, 1_800)

        let kept = scan.truncatedKeepingTheList()
        XCTAssertFalse(kept.intervals.isEmpty)
        XCTAssertEqual(kept.candidateIndex.candidates, index(intervals).candidates)
    }

    // MARK: H1 — the shared silence-evidence contract
    //
    // Python's `SilenceHardeningTests` mutates the same fields and expects the
    // same refusals. Two validators that disagree about one fixture is worse
    // than one validator, so both sides are pinned here.

    /// A frozen triple that agrees with itself: identity, manifest and silence
    /// plan share one source digest, one work PCM digest, one normalization
    /// profile digest and one work range. The manifest always records the digest
    /// of the bytes actually written, so a refusal below can never be blamed on
    /// a digest that was simply left stale.
    private struct SilenceFixture {
        let layout: LocalCheckpointLayout
        let identity: LocalIdentityDocument
        let manifest: LocalCheckpointManifest
        let plan: LocalSilencePlan
        let root: LocalRootPlan
        let groups: [LocalDisplayGroup]
        let digest: String
        let normalizedPCMSHA256: String
        let identityDigest: String
        let inferenceDigest: String
        let normalizationDigest: String
        let planID: String
        let workStart: Int64
        let workEnd: Int64

        /// The same manifest with its reference to the plan changed. This is how
        /// "fixed planner carrying a plan", "digest recorded but file absent" and
        /// "path escapes the v2 directory" are built without touching plan bytes.
        func manifest(
            plannerVersion: String = LocalPlannerStrategy.silence,
            digest: String? = nil,
            path: String? = nil,
            pcm: String? = nil,
            omitReference: Bool = false
        ) -> LocalCheckpointManifest {
            LocalCheckpointManifest(
                jobID: identity.jobID,
                identityDigest: identityDigest,
                inferenceDigest: inferenceDigest,
                normalizationDigest: normalizationDigest,
                workStartSample: workStart,
                workEndSample: workEnd,
                planID: planID,
                plannerVersion: plannerVersion,
                roots: [root],
                displayGroups: groups,
                silencePlanDigest: omitReference ? nil : (digest ?? self.digest),
                silencePlanRelativePath: omitReference
                    ? nil
                    : (path ?? LocalCheckpointSchema.silencePlanFileName),
                normalizedPCMSHA256: pcm ?? normalizedPCMSHA256,
                createdAt: "2026-09-27T00:00:00Z"
            )
        }
    }

    private func makeSilenceFixture(
        workStart: Int64 = 0,
        workSeconds: Double = 1_800,
        intervals: [LocalSilenceInterval] = [],
        sourceSHA256: String? = nil,
        scanPCMSHA256: String? = nil,
        normalizationDigest: String? = nil,
        coveredStartSample: Int64? = nil,
        coveredEndSample: Int64? = nil,
        enabled: Bool = true,
        truncated: Bool = false,
        detector: String = LocalSilencePlan.ffmpegDetector,
        plannerVersion: String = LocalPlannerStrategy.silence,
        thresholds: LocalSilenceThresholds = .current,
        normalizedPCMSHA256: String = String(repeating: "c", count: 64),
        scanCount: Int = 1,
        writePlanFile: Bool = true
    ) throws -> SilenceFixture {
        let workEnd = workStart + samples(workSeconds)
        let identity = makeIdentityDocument(workStart: workStart, workEnd: workEnd)
        let root = makeRootPlan(order: 0, start: workStart, end: workEnd)
        let plan = LocalSilencePlan(
            plannerVersion: plannerVersion,
            enabled: enabled,
            detector: detector,
            thresholds: thresholds,
            coveredStartSample: coveredStartSample ?? workStart,
            coveredEndSample: coveredEndSample ?? workEnd,
            scanPCMSHA256: scanPCMSHA256 ?? normalizedPCMSHA256,
            normalizationDigest: normalizationDigest
                ?? LocalDigest.sha256(identity.normalizationProfile),
            sourceSHA256: sourceSHA256 ?? identity.source.sourceSHA256,
            truncated: truncated,
            intervals: intervals,
            scanCount: scanCount,
            scannedAudioSeconds: workSeconds,
            scanElapsedMilliseconds: 12.5,
            cacheHitCount: 0,
            outerSilenceCuts: 1,
            outerFallbacks: 0,
            innerSilenceCuts: 0,
            innerFallbacks: 1
        )
        let layout = LocalCheckpointLayout(recoveryDirectory: makeTemporaryDirectory())
        if writePlanFile {
            try LocalSilencePlanStore.write(plan, to: layout)
        }
        let identityDigest = LocalDigest.sha256(identity.canonicalBytes())
        let manifestDigest = LocalDigest.sha256(identity.normalizationProfile)
        let groups = [group(workStart, workEnd)]
        // The real planID, so the fixture also survives a full manifest
        // validation rather than only the silence-specific checks.
        let planID = LocalCheckpointManifest.computePlanID(
            plannerVersion: LocalPlannerStrategy.silence,
            workStartSample: workStart,
            workEndSample: workEnd,
            roots: [root],
            displayGroups: groups
        )
        let manifest = LocalCheckpointManifest(
            jobID: identity.jobID,
            identityDigest: identityDigest,
            inferenceDigest: identity.inference.digest,
            normalizationDigest: manifestDigest,
            workStartSample: workStart,
            workEndSample: workEnd,
            planID: planID,
            plannerVersion: LocalPlannerStrategy.silence,
            roots: [root],
            displayGroups: groups,
            silencePlanDigest: plan.digest,
            silencePlanRelativePath: LocalCheckpointSchema.silencePlanFileName,
            normalizedPCMSHA256: normalizedPCMSHA256,
            createdAt: "2026-09-27T00:00:00Z"
        )
        return SilenceFixture(
            layout: layout,
            identity: identity,
            manifest: manifest,
            plan: plan,
            root: root,
            groups: groups,
            digest: plan.digest,
            normalizedPCMSHA256: normalizedPCMSHA256,
            identityDigest: identityDigest,
            inferenceDigest: identity.inference.digest,
            normalizationDigest: manifestDigest,
            planID: planID,
            workStart: workStart,
            workEnd: workEnd
        )
    }

    private func thresholds(
        maximumRootSeconds: Double = LocalSilenceThresholds.current.maximumRootSeconds,
        outerSearchSeconds: Double = LocalSilenceThresholds.current.outerSearchSeconds,
        displayGroupSeconds: Double = LocalSilenceThresholds.current.displayGroupSeconds,
        displaySearchSeconds: Double = LocalSilenceThresholds.current.displaySearchSeconds,
        chunkSeconds: Double = LocalSilenceThresholds.current.chunkSeconds,
        innerSearchSeconds: Double = LocalSilenceThresholds.current.innerSearchSeconds,
        recursiveSearchSeconds: Double = LocalSilenceThresholds.current.recursiveSearchSeconds,
        minimumChildSeconds: Double = LocalSilenceThresholds.current.minimumChildSeconds,
        noiseProfile: String = LocalSilenceThresholds.current.noiseProfile,
        minimumSilenceDurationSeconds: Double = LocalSilenceThresholds.current.minimumSilenceDurationSeconds,
        maximumIntervalCount: Int = LocalSilenceThresholds.current.maximumIntervalCount
    ) -> LocalSilenceThresholds {
        LocalSilenceThresholds(
            maximumRootSeconds: maximumRootSeconds,
            outerSearchSeconds: outerSearchSeconds,
            displayGroupSeconds: displayGroupSeconds,
            displaySearchSeconds: displaySearchSeconds,
            chunkSeconds: chunkSeconds,
            innerSearchSeconds: innerSearchSeconds,
            recursiveSearchSeconds: recursiveSearchSeconds,
            minimumChildSeconds: minimumChildSeconds,
            noiseProfile: noiseProfile,
            minimumSilenceDurationSeconds: minimumSilenceDurationSeconds,
            maximumIntervalCount: maximumIntervalCount
        )
    }

    func testAConsistentSilencePlanBecomesVerifiedEvidence() throws {
        let fixture = try makeSilenceFixture(intervals: [pause(at: 117), pause(at: 700)])
        let verified = try XCTUnwrap(
            LocalSilenceValidation.load(
                layout: fixture.layout,
                manifest: fixture.manifest,
                identity: fixture.identity
            )
        )
        XCTAssertEqual(verified.digest, fixture.digest)
        XCTAssertEqual(verified.plan.intervals, fixture.plan.intervals)
        // The bytes on disk are the bytes the digest describes.
        XCTAssertEqual(
            LocalDigest.sha256(try Data(contentsOf: fixture.layout.silencePlanURL)),
            fixture.digest
        )
        XCTAssertNoThrow(
            try LocalCheckpointValidator.validate(
                manifest: fixture.manifest,
                identity: fixture.identity,
                identityDigest: fixture.identityDigest
            )
        )
    }

    /// Review F2, from the Swift side. Each row is one field of an otherwise
    /// consistent fixture, and the file digest always matches the manifest, so
    /// what fails is the contract check and not a stale hash. The expected code
    /// is part of the assertion: Python's `SilenceHardeningTests` mutates the
    /// same fields and must report the same codes.
    func testProvenanceAndContractMutationsAreRefused() throws {
        let covered = LocalSilenceInterval(startSample: 0, endSample: samples(1_800))
        let invalid = "local_checkpoint_invalid"
        let cases: [(name: String, code: String, build: () throws -> SilenceFixture)] = [
            ("sourceSHA256", "local_source_changed", {
                try self.makeSilenceFixture(
                    intervals: [covered], sourceSHA256: String(repeating: "a", count: 64))
            }),
            ("scanPCMSHA256", "local_identity_mismatch", {
                try self.makeSilenceFixture(
                    intervals: [covered], scanPCMSHA256: String(repeating: "b", count: 64))
            }),
            ("normalizationDigest", "local_identity_mismatch", {
                try self.makeSilenceFixture(
                    intervals: [covered],
                    // Review F3: hashing only the profile's version string is a
                    // different definition from the manifest's full-profile hash.
                    normalizationDigest: LocalDigest.sha256(
                        LocalNormalizationProfile.current.version))
            }),
            ("covered range excludes the work", invalid, {
                try self.makeSilenceFixture(
                    intervals: [covered],
                    coveredStartSample: self.samples(1_800) + 1,
                    coveredEndSample: self.samples(1_800) + 100)
            }),
            ("enabled=false", invalid, {
                try self.makeSilenceFixture(intervals: [covered], enabled: false)
            }),
            ("truncated=true with intervals", invalid, {
                try self.makeSilenceFixture(intervals: [covered], truncated: true)
            }),
            ("unknown detector", invalid, {
                try self.makeSilenceFixture(intervals: [covered], detector: "webrtc-vad")
            }),
            ("unknown plannerVersion", invalid, {
                try self.makeSilenceFixture(intervals: [covered], plannerVersion: "local-silence-v9")
            }),
            ("interval outside the covered range", invalid, {
                try self.makeSilenceFixture(intervals: [
                    LocalSilenceInterval(startSample: 0, endSample: self.samples(1_800) + 1),
                ])
            }),
            ("reversed interval", invalid, {
                try self.makeSilenceFixture(intervals: [
                    LocalSilenceInterval(startSample: self.samples(100), endSample: self.samples(50)),
                ])
            }),
            ("unsorted intervals", invalid, {
                try self.makeSilenceFixture(intervals: [
                    self.pause(at: 700), self.pause(at: 117),
                ])
            }),
            ("overlapping intervals", invalid, {
                try self.makeSilenceFixture(intervals: [
                    LocalSilenceInterval(startSample: 0, endSample: self.samples(100)),
                    LocalSilenceInterval(startSample: self.samples(50), endSample: self.samples(200)),
                ])
            }),
            ("negative search window", invalid, {
                try self.makeSilenceFixture(
                    intervals: [covered], thresholds: self.thresholds(outerSearchSeconds: -1))
            }),
            ("non-positive chunk length", invalid, {
                try self.makeSilenceFixture(
                    intervals: [covered], thresholds: self.thresholds(chunkSeconds: 0))
            }),
            ("noiseProfile without dB", invalid, {
                try self.makeSilenceFixture(
                    intervals: [covered], thresholds: self.thresholds(noiseProfile: "-35"))
            }),
            ("positive noiseProfile", invalid, {
                try self.makeSilenceFixture(
                    intervals: [covered], thresholds: self.thresholds(noiseProfile: "35dB"))
            }),
            ("negative scan metric", invalid, {
                try self.makeSilenceFixture(intervals: [covered], scanCount: -1)
            }),
            ("interval count past the storage cap", invalid, {
                try self.makeSilenceFixture(
                    intervals: [covered],
                    thresholds: self.thresholds(maximumIntervalCount: 0))
            }),
        ]
        for testCase in cases {
            let fixture = try testCase.build()
            XCTAssertThrowsError(
                try LocalSilenceValidation.load(
                    layout: fixture.layout,
                    manifest: fixture.manifest,
                    identity: fixture.identity
                ),
                testCase.name
            ) { error in
                guard let error = error as? LocalCheckpointError else {
                    return XCTFail("\(testCase.name): expected LocalCheckpointError, got \(error)")
                }
                XCTAssertEqual(error.code, testCase.code, testCase.name)
            }
        }
    }

    /// §3.7 with the storage cap exceeded: the cut plan survives, the interval
    /// list is empty, and an empty leaf may not borrow evidence from a list that
    /// was deliberately dropped.
    func testATruncatedPlanIsValidButProvesNoLeafSilence() throws {
        let fixture = try makeSilenceFixture(truncated: true)
        let verified = try XCTUnwrap(
            LocalSilenceValidation.load(
                layout: fixture.layout,
                manifest: fixture.manifest,
                identity: fixture.identity
            )
        )
        XCTAssertTrue(verified.plan.intervals.isEmpty)
        let node = LocalCheckpointNode(
            nodeID: "node-1",
            startSample: fixture.workStart,
            endSample: fixture.workEnd,
            state: .verifiedSilence,
            result: LocalLeafResult(
                text: "",
                textSHA256: LocalDigest.sha256(""),
                pcmSHA256: fixture.root.pcmSHA256,
                finishEvidence: nil,
                silenceEvidence: LocalSilenceEvidence(
                    detector: LocalSilencePlan.ffmpegDetector,
                    coveredStartSample: fixture.workStart,
                    coveredEndSample: fixture.workEnd,
                    thresholdDB: -35,
                    minimumDurationSeconds: 0.35,
                    silencePlanDigest: fixture.digest
                )
            )
        )
        XCTAssertThrowsError(
            try verified.validate(node: node, manifest: fixture.manifest, root: fixture.root)
        ) { error in
            XCTAssertEqual(error as? LocalCheckpointError, .emptyUnverified(nodeID: "node-1"))
        }
    }

    /// H1.4: the reference is a pair. A fixed planner must carry neither half, a
    /// silence planner must carry both, and a file nobody references is never
    /// evidence no matter how valid its contents are.
    func testTheSilenceReferenceIsAPairAndAnOrphanFileIsNotEvidence() throws {
        let fixture = try makeSilenceFixture(intervals: [pause(at: 117)])

        // A fixed-cut plan that nevertheless carries a silence reference.
        XCTAssertThrowsError(
            try LocalSilenceValidation.validateReference(
                fixture.manifest(
                    plannerVersion: LocalPlannerStrategy.fixed
                )
            )
        )
        // Fixed with no reference at all loads as "no silence evidence".
        let fixed = fixture.manifest(
            plannerVersion: LocalPlannerStrategy.fixed, omitReference: true
        )
        XCTAssertNoThrow(try LocalSilenceValidation.validateReference(fixed))
        XCTAssertNil(
            try LocalSilenceValidation.load(
                layout: fixture.layout, manifest: fixed, identity: fixture.identity
            )
        )

        // Silence planner missing either half.
        XCTAssertThrowsError(
            try LocalSilenceValidation.validateReference(
                fixture.manifest(omitReference: true)
            )
        )
        XCTAssertThrowsError(
            try LocalSilenceValidation.validateReference(fixture.manifest(path: ""))
        )
        // Unknown planner strategy.
        XCTAssertThrowsError(
            try LocalSilenceValidation.validateReference(
                fixture.manifest(plannerVersion: "local-silence-v9")
            )
        )

        // An orphan file: valid bytes, digest recorded, but the manifest says
        // fixed, so nothing may treat it as proof of silence.
        XCTAssertNil(
            try LocalSilenceValidation.load(
                layout: fixture.layout, manifest: fixed, identity: fixture.identity
            )
        )

        // Digest recorded, file absent: a refusal, not "no candidates".
        try FileManager.default.removeItem(at: fixture.layout.silencePlanURL)
        XCTAssertThrowsError(
            try LocalSilenceValidation.load(
                layout: fixture.layout,
                manifest: fixture.manifest(),
                identity: fixture.identity
            )
        ) { error in
            guard case LocalCheckpointError.missingFile = error else {
                return XCTFail("expected missingFile, got \(error)")
            }
        }
    }

    /// H1.8: the path is resolved against the v2 root only.
    func testASilencePlanPathThatEscapesTheCheckpointRootIsRefused() throws {
        let fixture = try makeSilenceFixture()
        for path in ["../../escape.json", "/etc/passwd", "roots/../../escape.json"] {
            XCTAssertThrowsError(
                try LocalSilenceValidation.load(
                    layout: fixture.layout,
                    manifest: fixture.manifest(path: path),
                    identity: fixture.identity
                ),
                path
            ) { error in
                guard case LocalCheckpointError.pathEscape = error else {
                    return XCTFail("\(path): expected pathEscape, got \(error)")
                }
            }
        }
    }

    /// H1.10: an empty leaf is silence only when *this* frozen plan proves the
    /// leaf's whole span. The helper's own coveredStart/End are not trusted.
    func testALeafIsSilenceOnlyWhenTheFrozenPlanProvesItsWholeSpan() throws {
        let full = LocalSilenceInterval(startSample: 0, endSample: samples(1_800))
        let fixture = try makeSilenceFixture(intervals: [full])
        let verified = try XCTUnwrap(
            LocalSilenceValidation.load(
                layout: fixture.layout,
                manifest: fixture.manifest,
                identity: fixture.identity
            )
        )

        func leaf(
            start: Int64 = 0,
            end: Int64? = nil,
            state: LocalNodeState = .verifiedSilence,
            text: String = "",
            evidence: LocalSilenceEvidence?
        ) -> LocalCheckpointNode {
            LocalCheckpointNode(
                nodeID: "node-1",
                startSample: start,
                endSample: end ?? samples(1_800),
                state: state,
                result: LocalLeafResult(
                    text: text,
                    textSHA256: LocalDigest.sha256(text),
                    pcmSHA256: fixture.root.pcmSHA256,
                    finishEvidence: nil,
                    silenceEvidence: evidence
                )
            )
        }
        func evidence(
            detector: String = LocalSilencePlan.ffmpegDetector,
            start: Int64 = 0,
            end: Int64? = nil,
            // -35 dB / 0.35 s are `LocalSilenceThresholds.current`'s values,
            // which is what the frozen plan records.
            thresholdDB: Double = -35,
            minimumDurationSeconds: Double = 0.35,
            digest: String? = nil,
            omitDigest: Bool = false
        ) -> LocalSilenceEvidence {
            LocalSilenceEvidence(
                detector: detector,
                coveredStartSample: start,
                coveredEndSample: end ?? samples(1_800),
                thresholdDB: thresholdDB,
                minimumDurationSeconds: minimumDurationSeconds,
                silencePlanDigest: omitDigest ? nil : (digest ?? fixture.digest)
            )
        }

        XCTAssertNoThrow(
            try verified.validate(
                node: leaf(evidence: evidence()),
                manifest: fixture.manifest,
                root: fixture.root
            )
        )
        let refusals: [(String, LocalCheckpointNode)] = [
            ("another plan's digest", leaf(evidence: evidence(digest: String(repeating: "0", count: 64)))),
            ("no digest recorded", leaf(evidence: evidence(omitDigest: true))),
            ("partial cover", leaf(evidence: evidence(end: samples(900)))),
            ("cover shifted off the leaf", leaf(evidence: evidence(start: samples(1)))),
            ("another detector", leaf(evidence: evidence(detector: "webrtc-vad"))),
            ("another threshold", leaf(evidence: evidence(thresholdDB: -50))),
            ("another minimum duration", leaf(evidence: evidence(minimumDurationSeconds: 0.5))),
            ("no result at all", LocalCheckpointNode(
                nodeID: "node-1", startSample: 0, endSample: samples(1_800), state: .verifiedSilence)),
            ("no silence evidence", leaf(evidence: nil)),
            ("text that contradicts the empty leaf", leaf(text: "講者 1：喂。", evidence: evidence())),
        ]
        for (name, node) in refusals {
            XCTAssertThrowsError(
                try verified.validate(node: node, manifest: fixture.manifest, root: fixture.root),
                name
            ) { error in
                XCTAssertEqual(
                    error as? LocalCheckpointError,
                    .emptyUnverified(nodeID: "node-1"),
                    name
                )
            }
        }

        // A plan whose intervals do not cover the leaf proves nothing, even when
        // the helper's self-reported span says otherwise.
        let partial = try makeSilenceFixture(
            intervals: [LocalSilenceInterval(startSample: 0, endSample: samples(900))]
        )
        let partialVerified = try XCTUnwrap(
            LocalSilenceValidation.load(
                layout: partial.layout,
                manifest: partial.manifest,
                identity: partial.identity
            )
        )
        XCTAssertThrowsError(
            try partialVerified.validate(
                node: leaf(evidence: evidence()),
                manifest: partial.manifest,
                root: partial.root
            )
        )
    }

    /// The verified evidence is bound to the manifest it was loaded against, so
    /// a leaf from one plan cannot be justified by another's analysis.
    func testVerifiedEvidenceIsBoundToThePlanItWasLoadedFrom() throws {
        let covered = LocalSilenceInterval(startSample: 0, endSample: samples(1_800))
        let fixture = try makeSilenceFixture(intervals: [covered])
        let verified = try XCTUnwrap(
            LocalSilenceValidation.load(
                layout: fixture.layout,
                manifest: fixture.manifest,
                identity: fixture.identity
            )
        )
        let node = LocalCheckpointNode(
            nodeID: "node-1",
            startSample: 0,
            endSample: samples(1_800),
            state: .verifiedSilence,
            result: LocalLeafResult(
                text: "",
                textSHA256: LocalDigest.sha256(""),
                pcmSHA256: fixture.root.pcmSHA256,
                finishEvidence: nil,
                silenceEvidence: LocalSilenceEvidence(
                    detector: LocalSilencePlan.ffmpegDetector,
                    coveredStartSample: 0,
                    coveredEndSample: samples(1_800),
                    thresholdDB: -35,
                    minimumDurationSeconds: 0.35,
                    silencePlanDigest: fixture.digest
                )
            )
        )
        let otherPlanID = fixture.manifest(
            digest: String(repeating: "9", count: 64)
        )
        XCTAssertThrowsError(
            try verified.validate(node: node, manifest: otherPlanID, root: fixture.root)
        )
        // A root decoded from different PCM is not the audio that was scanned,
        // even when every other number lines up.
        let otherRoot = LocalRootPlan(
            rootID: fixture.root.rootID,
            order: 0,
            startSample: 0,
            endSample: samples(1_800),
            pcmSHA256: String(repeating: "e", count: 64),
            audioRelativePath: fixture.root.audioRelativePath,
            stateRelativePath: fixture.root.stateRelativePath,
            initialChunks: fixture.root.initialChunks
        )
        XCTAssertThrowsError(
            try verified.validate(node: node, manifest: fixture.manifest, root: otherRoot)
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    /// Freeze once with the production writer, then hand the exact same mutated
    /// bytes to both production loaders. Re-encoding a Double through
    /// JSONSerialization would erase `.0`, hiding the regression we need to test.
    func testPersistedIntegerRepresentationsAgreeWithPythonOnSharedBytes() async throws {
        let directory = makeTemporaryDirectory()
        let baseline = LocalCheckpointLayout(recoveryDirectory: directory.appendingPathComponent("baseline"))
        let end: Int64 = 120 * 16_000
        let identity = makeIdentityDocument(workStart: 0, workEnd: end)
        let plan = LocalSilencePlan(
            coveredStartSample: 0, coveredEndSample: end,
            scanPCMSHA256: String(repeating: "c", count: 64),
            normalizationDigest: LocalDigest.sha256(identity.normalizationProfile),
            sourceSHA256: identity.source.sourceSHA256,
            intervals: [LocalSilenceInterval(startSample: 0, endSample: end)]
        )
        let manifest = try LocalCheckpointPlanner.freeze(
            layout: baseline, identity: identity,
            roots: [makeRootPlan(order: 0, start: 0, end: end)],
            createdAt: "2026-09-27T00:00:00Z",
            plannerVersion: LocalPlannerStrategy.silence, silencePlan: plan,
            normalizedPCMSHA256: plan.scanPCMSHA256
        )
        let original = String(decoding: try Data(contentsOf: baseline.silencePlanURL), as: UTF8.self)
        let fields: [(String, Int64)] = [
            ("schemaVersion", 2), ("coveredStartSample", 0), ("coveredEndSample", end),
            ("scanCount", 0), ("cacheHitCount", 0), ("outerSilenceCuts", 0),
            ("outerFallbacks", 0), ("innerSilenceCuts", 0), ("innerFallbacks", 0),
            ("maximumIntervalCount", 100_000), ("startSample", 0), ("endSample", end),
        ]
        var cases: [(name: String, text: String, expected: String)] = [("baseline", original, "accepted")]
        for (field, value) in fields {
            let before = "\"\(field)\":\(value)"
            XCTAssertEqual(original.components(separatedBy: before).count, 2, field)
            for token in ["\(value).0", "\(value)e0", "\(value).00000000000000000001",
                          "true", "false", "\"\(value)\"", "null",
                          "9223372036854775808", "-9223372036854775809"] {
                cases.append(("\(field)=\(token)", original.replacingOccurrences(of: before, with: "\"\(field)\":\(token)"), "local_checkpoint_invalid"))
            }
        }
        // Durations deliberately accept JSON numbers as well as canonical
        // strings. Strict integer validation must not reject these fields.
        cases.append(("numeric duration", original.replacingOccurrences(of: "\"minimumSilenceDurationSeconds\":\"0.350000\"", with: "\"minimumSilenceDurationSeconds\":0.35"), "accepted"))
        cases.append(("numeric elapsed", original.replacingOccurrences(of: "\"scanElapsedMilliseconds\":\"0.000000\"", with: "\"scanElapsedMilliseconds\":12.5"), "accepted"))
        cases.append(("maximum Int64 metric", original.replacingOccurrences(of: "\"scanCount\":0", with: "\"scanCount\":9223372036854775807"), "accepted"))
        cases.append(("integer negative zero", original.replacingOccurrences(of: "\"coveredStartSample\":0", with: "\"coveredStartSample\":-0"), "accepted"))

        var layouts: [LocalCheckpointLayout] = []
        var verdicts: [String] = []
        for (index, item) in cases.enumerated() {
            let layout = LocalCheckpointLayout(recoveryDirectory: directory.appendingPathComponent("case-\(index)"))
            try layout.createDirectories()
            let bytes = Data(item.text.utf8)
            let manifestText = manifest.canonicalString().replacingOccurrences(of: plan.digest, with: LocalDigest.sha256(bytes))
            try identity.canonicalBytes().write(to: layout.identityURL)
            try Data(manifestText.utf8).write(to: layout.manifestURL)
            try bytes.write(to: layout.silencePlanURL)
            layouts.append(layout)
            do {
                let loaded = try LocalCheckpointPlanner.loadFrozenManifest(layout: layout)
                XCTAssertNotNil(loaded)
                verdicts.append("accepted")
            } catch let error as LocalCheckpointError {
                verdicts.append(error.code)
            }
            XCTAssertEqual(verdicts.last, item.expected, "Swift: \(item.name)")
            // The alternate persisted-plan reader must apply the same type gate.
            if item.expected == "accepted" {
                XCTAssertNotNil(try LocalSilencePlanStore.load(from: layout, expectedDigest: LocalDigest.sha256(bytes)))
            } else {
                XCTAssertThrowsError(try LocalSilencePlanStore.load(from: layout, expectedDigest: LocalDigest.sha256(bytes)), item.name)
            }
        }

        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = """
        import json, sys
        from pathlib import Path
        sys.path.insert(0, sys.argv[1])
        import qwen_asr_local_checkpoint as cp
        verdicts = []
        for raw in sys.argv[2:]:
            directory = Path(raw)
            try:
                _, digest = cp.load_identity(directory)
                manifest = cp.load_manifest(directory, identity_digest=digest)
                assert cp.load_silence_plan(directory, manifest) is not None
                verdicts.append("accepted")
            except cp.CheckpointContractError as error:
                verdicts.append(error.code)
        print(json.dumps(verdicts))
        """
        let result = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-B", "-c", script, repo.appendingPathComponent("Sources/RecordToTextApp/Resources").path] + layouts.map { $0.root.path },
            timeout: 30
        )
        let python = try JSONDecoder().decode([String].self, from: result.standardOutput)
        XCTAssertEqual(python.count, cases.count)
        for (index, verdict) in python.enumerated() {
            XCTAssertEqual(verdict, cases[index].expected, "Python: \(cases[index].name)")
            XCTAssertEqual(verdict, verdicts[index], "Shared bytes: \(cases[index].name)")
            XCTAssertEqual(try Data(contentsOf: layouts[index].silencePlanURL), Data(cases[index].text.utf8), "Readers must preserve evidence")
        }
    }

    // MARK: Identity fixtures

    private func makeIdentityDocument(workStart: Int64, workEnd: Int64) -> LocalIdentityDocument {
        LocalIdentityDocument(
            jobID: "job-1",
            source: LocalSourceIdentity(
                sourceSHA256: String(repeating: "f", count: 64),
                sourceByteCount: 1_000_000,
                sourceLocator: "/tmp/recording.m4a",
                normalizationProfile: .current,
                decoder: LocalDecoderIdentity(
                    executablePath: "/usr/local/bin/ffmpeg",
                    versionLine: "ffmpeg version 7.1",
                    signature: String(repeating: "d", count: 64)
                ),
                sliceStartSeconds: nil,
                workStartSample: workStart,
                workEndSample: workEnd
            ),
            normalizationProfile: .current,
            inference: LocalInferenceIdentity(
                runtimeKind: "mlx",
                modelID: "mlx-community/Qwen3-ASR-1.7B-8bit",
                modelRevision: String(repeating: "a", count: 40),
                modelManifestDigest: "m" + String(repeating: "0", count: 63),
                language: "Chinese",
                promptDigest: "p" + String(repeating: "0", count: 63),
                termsDigest: "t" + String(repeating: "0", count: 63),
                promptChannel: "system-prompt",
                allowMissingPrompt: false,
                maximumTokens: 16_384,
                samplerDigest: "s" + String(repeating: "0", count: 63),
                mlxVersion: "0.30.1",
                mlxAudioVersion: "0.4.6"
            ),
            presentation: LocalPresentationOptions(
                openCCConfiguration: "s2twp.json",
                outputLocatorHint: "/tmp/out.txt",
                jobUUID: "uuid-1"
            )
        )
    }

    private func makeRootPlan(order: Int, start: Int64, end: Int64) -> LocalRootPlan {
        let rootID = LocalCheckpointID.root(order: order, startSample: start, endSample: end)
        return LocalRootPlan(
            rootID: rootID,
            order: order,
            startSample: start,
            endSample: end,
            pcmSHA256: String(repeating: "c", count: 64),
            audioRelativePath: "audio/\(rootID).wav",
            stateRelativePath: "roots/\(rootID).json",
            initialChunks: [
                LocalChunkPlan(
                    nodeID: LocalCheckpointID.chunk(
                        rootID: rootID,
                        order: 0,
                        startSample: start,
                        endSample: end
                    ),
                    startSample: start,
                    endSample: end
                )
            ]
        )
    }
}

private extension LocalSilenceScan {
    /// The same scan with §3.7's drop disabled, to prove the drop is the only
    /// thing that removes the candidate list.
    func truncatedKeepingTheList() -> LocalSilencePlan {
        LocalSilencePlan(
            thresholds: thresholds,
            coveredStartSample: coveredStartSample,
            coveredEndSample: coveredEndSample,
            scanPCMSHA256: scanPCMSHA256,
            normalizationDigest: normalizationDigest,
            sourceSHA256: sourceSHA256,
            truncated: false,
            intervals: intervals,
            scanCount: metrics.scanCount,
            scannedAudioSeconds: metrics.scannedAudioSeconds,
            scanElapsedMilliseconds: metrics.scanElapsedMilliseconds,
            cacheHitCount: metrics.cacheHitCount,
            outerSilenceCuts: outerSilenceCuts,
            outerFallbacks: outerFallbacks,
            innerSilenceCuts: 0,
            innerFallbacks: 0
        )
    }
}
