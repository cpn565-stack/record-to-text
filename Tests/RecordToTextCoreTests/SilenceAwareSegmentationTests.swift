import Foundation
import XCTest
@testable import RecordToTextCore

final class SilenceAwareSegmentationTests: XCTestCase {
    func testDetectionServiceReportsTimesRelativeToTrimmedStart() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let runtime = RuntimeEnvironment.candidate(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: true),
            bundledHelperURL: nil
        )
        guard FileManager.default.isExecutableFile(atPath: runtime.ffmpeg.path) else {
            throw XCTSkip("ffmpeg is not available")
        }

        let sourceURL = root.appendingPathComponent("silence-offset.wav")
        let runner = ProcessRunner()
        _ = try await runner.run(
            executableURL: runtime.ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi",
                "-i",
                "anullsrc=r=16000:cl=mono:d=2[s0];sine=frequency=440:sample_rate=16000:d=2[s1];anullsrc=r=16000:cl=mono:d=2[s2];[s0][s1][s2]concat=n=3:v=0:a=1",
                "-c:a", "pcm_s16le",
                sourceURL.path
            ]
        )

        let service = SilenceDetectionService(
            executableURL: runtime.ffmpeg,
            runner: runner
        )
        let silences = try await service.detect(
            sourceURL: sourceURL,
            startSeconds: 2,
            durationSeconds: 4
        )

        XCTAssertEqual(silences.count, 1)
        XCTAssertEqual(silences[0].startSeconds, 2, accuracy: 0.1)
        XCTAssertEqual(silences[0].endSeconds, 4, accuracy: 0.1)
    }

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
