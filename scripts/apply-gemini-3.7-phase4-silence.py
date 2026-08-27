#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def replace_once(content: str, old: str, new: str, label: str) -> str:
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return content.replace(old, new, 1)


silence_source = r'''import Foundation

public struct DetectedSilence: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var durationSeconds: Double {
        max(endSeconds - startSeconds, 0)
    }

    public var midpointSeconds: Double {
        startSeconds + durationSeconds / 2
    }
}

public enum SilenceDetectionParser {
    public static func parse(_ stderr: String) -> [DetectedSilence] {
        var pendingStart: Double?
        var result: [DetectedSilence] = []

        for line in stderr.components(separatedBy: .newlines) {
            if let start = value(after: "silence_start:", in: line) {
                pendingStart = start
                continue
            }
            guard let end = value(after: "silence_end:", in: line),
                  let start = pendingStart,
                  end >= start
            else {
                continue
            }
            result.append(
                DetectedSilence(startSeconds: start, endSeconds: end)
            )
            pendingStart = nil
        }

        return result.sorted {
            if $0.startSeconds == $1.startSeconds {
                return $0.endSeconds < $1.endSeconds
            }
            return $0.startSeconds < $1.startSeconds
        }
    }

    private static func value(after marker: String, in line: String) -> Double? {
        guard let range = line.range(of: marker) else {
            return nil
        }
        let tail = line[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tail.prefix { character in
            character.isNumber || character == "." || character == "-"
        }
        return Double(token)
    }
}

public enum SilenceAwareSegmentPlanner {
    public static let defaultSearchWindow: TimeInterval = 30
    public static let defaultMinimumSilenceDuration: TimeInterval = 0.35
    public static let defaultMinimumSegmentDuration: TimeInterval = 60

    public static func makePlan(
        sourceDuration: TimeInterval,
        maximumSegmentDuration: TimeInterval,
        silences: [DetectedSilence],
        searchWindow: TimeInterval = defaultSearchWindow,
        minimumSilenceDuration: TimeInterval = defaultMinimumSilenceDuration,
        minimumSegmentDuration: TimeInterval = defaultMinimumSegmentDuration
    ) throws -> AudioSegmentationPlan {
        let hardPlan = try AudioSegmentPlanner.makePlan(
            sourceDuration: sourceDuration,
            maximumSegmentDuration: maximumSegmentDuration
        )
        guard hardPlan.requiresSplitting else {
            return hardPlan
        }

        let eligible = silences.filter {
            $0.startSeconds.isFinite
                && $0.endSeconds.isFinite
                && $0.startSeconds >= 0
                && $0.endSeconds <= sourceDuration + 0.5
                && $0.durationSeconds >= minimumSilenceDuration
        }
        guard !eligible.isEmpty else {
            return hardPlan
        }

        var segments: [PlannedAudioSegment] = []
        var segmentStart = 0.0
        var index = 1

        while sourceDuration - segmentStart > maximumSegmentDuration {
            let nominalBoundary = segmentStart + maximumSegmentDuration
            let windowStart = max(
                segmentStart + minimumSegmentDuration,
                nominalBoundary - max(searchWindow, 0)
            )
            let boundary = eligible
                .filter {
                    $0.midpointSeconds >= windowStart
                        && $0.midpointSeconds <= nominalBoundary
                }
                .max { $0.midpointSeconds < $1.midpointSeconds }?
                .midpointSeconds
                ?? nominalBoundary

            let duration = boundary - segmentStart
            guard duration > 0, duration <= maximumSegmentDuration + 0.001 else {
                return hardPlan
            }
            segments.append(
                PlannedAudioSegment(
                    index: index,
                    startSeconds: segmentStart,
                    durationSeconds: duration
                )
            )
            index += 1
            segmentStart = boundary
        }

        let finalDuration = sourceDuration - segmentStart
        guard finalDuration > 0,
              finalDuration <= maximumSegmentDuration + 0.001
        else {
            return hardPlan
        }
        segments.append(
            PlannedAudioSegment(
                index: index,
                startSeconds: segmentStart,
                durationSeconds: finalDuration
            )
        )

        return AudioSegmentationPlan(
            sourceDurationSeconds: sourceDuration,
            maximumSegmentDurationSeconds: maximumSegmentDuration,
            segments: segments
        )
    }
}

public final class SilenceDetectionService {
    private let executableURL: URL
    private let runner: ProcessRunner

    public init(executableURL: URL, runner: ProcessRunner) {
        self.executableURL = executableURL
        self.runner = runner
    }

    public func detect(
        sourceURL: URL,
        startSeconds: Double = 0,
        durationSeconds: Double
    ) async throws -> [DetectedSilence] {
        var arguments = ["-hide_banner", "-nostats"]
        if startSeconds > 0 {
            arguments += ["-ss", Self.seconds(startSeconds)]
        }
        arguments += ["-i", sourceURL.path]
        if durationSeconds > 0 {
            arguments += ["-t", Self.seconds(durationSeconds)]
        }
        arguments += [
            "-vn",
            "-af", "silencedetect=noise=-35dB:d=0.35",
            "-f", "null",
            "-"
        ]

        let result = try await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            timeout: max(120, durationSeconds * 3 + 120),
            inactivityTimeout: 5 * 60
        )
        return SilenceDetectionParser.parse(result.standardErrorText)
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
'''
write(
    "Sources/RecordToTextCore/SilenceAwareSegmentation.swift",
    silence_source,
)

engine_path = "Sources/RecordToTextCore/TranscriptionEngine.swift"
engine = read(engine_path)
engine = replace_once(
    engine,
    "    private let ffmpegService: FFmpegService\n    private let openCCService: OpenCCService\n",
    "    private let ffmpegService: FFmpegService\n    private let silenceDetectionService: SilenceDetectionService\n    private let openCCService: OpenCCService\n",
    "silence service property",
)
engine = replace_once(
    engine,
    "        self.ffmpegService = FFmpegService(executableURL: runtime.ffmpeg, runner: runner)\n        self.openCCService = OpenCCService(executableURL: runtime.opencc, runner: runner)\n",
    "        self.ffmpegService = FFmpegService(executableURL: runtime.ffmpeg, runner: runner)\n        self.silenceDetectionService = SilenceDetectionService(\n            executableURL: runtime.ffmpeg,\n            runner: runner\n        )\n        self.openCCService = OpenCCService(executableURL: runtime.opencc, runner: runner)\n",
    "silence service init",
)
engine = replace_once(
    engine,
    "        let segmentPlan = try AudioSegmentPlanner.makePlan(\n            sourceDuration: metadata.duration,\n            maximumSegmentDuration: maximumASRSegmentDuration\n        )\n        let totalSegments = segmentPlan.expectedSegmentCount\n",
    "        let segmentPlan = try await makeCloudSegmentPlan(\n            job: job,\n            sourceURL: sourceURL,\n            metadata: metadata,\n            update: update\n        )\n        let totalSegments = segmentPlan.expectedSegmentCount\n",
    "cloud plan integration",
)
helper_marker = "    private func runCloudPipeline(\n"
helper = r'''    private func makeCloudSegmentPlan(
        job: TranscriptionJob,
        sourceURL: URL,
        metadata: AudioMetadata,
        update: (PipelineUpdate) -> Void
    ) async throws -> AudioSegmentationPlan {
        let hardPlan = try AudioSegmentPlanner.makePlan(
            sourceDuration: metadata.duration,
            maximumSegmentDuration: maximumASRSegmentDuration
        )
        guard job.snapshot.silenceAwareCloudSegmentation,
              hardPlan.requiresSplitting
        else {
            return hardPlan
        }

        do {
            update(
                .log(
                    level: "info",
                    message: "正在分析 20 分鐘上限前的靜音位置，以降低句子被硬切的機率。"
                )
            )
            let silences = try await silenceDetectionService.detect(
                sourceURL: sourceURL,
                startSeconds: job.sourceSlice?.startSeconds ?? 0,
                durationSeconds: metadata.duration
            )
            let adjusted = try SilenceAwareSegmentPlanner.makePlan(
                sourceDuration: metadata.duration,
                maximumSegmentDuration: maximumASRSegmentDuration,
                silences: silences
            )
            guard adjusted != hardPlan else {
                update(
                    .log(
                        level: "info",
                        message: "未找到合適靜音切點，維持精確 20 分鐘硬切。"
                    )
                )
                return hardPlan
            }
            let boundaries = adjusted.segments.dropLast().map {
                String(format: "%.1f", $0.endSeconds)
            }.joined(separator: "、")
            update(
                .log(
                    level: "info",
                    message: "已採用靜音感知切點（秒）：\(boundaries)。每段仍不超過 20 分鐘。"
                )
            )
            return adjusted
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            update(
                .warning(
                    code: "silence_detection_failed",
                    message: "靜音分析失敗，已安全退回 20 分鐘硬切：\(error.localizedDescription)"
                )
            )
            return hardPlan
        }
    }

'''
if helper_marker not in engine:
    raise RuntimeError("cloud pipeline marker missing for silence helper")
engine = engine.replace(helper_marker, helper + helper_marker, 1)
write(engine_path, engine)

settings_path = "Sources/RecordToTextApp/SettingsView.swift"
settings = read(settings_path)
settings = replace_once(
    settings,
    "                    Text(\"目前先保存此工作設定；靜音偵測與切點調整會在本分支下一階段接入。沒有可用靜音時仍採 20 分鐘硬切。\")\n",
    "                    Text(\"開啟後會掃描每個 20 分鐘上限前 30 秒，優先在至少 0.35 秒的靜音中切分；找不到時安全退回硬切。\")\n",
    "silence UI live description",
)
write(settings_path, settings)

silence_tests = r'''import Foundation
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
        XCTAssertEqual(plan.segments.last?.endSeconds, 4_000, accuracy: 0.001)
    }
}
'''
write(
    "Tests/RecordToTextCoreTests/SilenceAwareSegmentationTests.swift",
    silence_tests,
)

print("Applied silence-aware cloud segmentation")
