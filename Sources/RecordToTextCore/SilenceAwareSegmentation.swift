import Foundation

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

public protocol SilenceDetectionServicing {
    /// The `-35dB`-style threshold the detector actually runs with.
    ///
    /// Phase 1 §3.2 persists the thresholds a plan was built from, and a
    /// recorded number that differs from the filter ffmpeg received would be
    /// false provenance. Defaults keep existing mocks honest without forcing
    /// every conformer to restate them.
    var noiseProfile: String { get }
    var minimumSilenceDuration: TimeInterval { get }

    func detect(
        sourceURL: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> [DetectedSilence]
}

public extension SilenceDetectionServicing {
    var noiseProfile: String { JobSilenceAnalysisCache.defaultNoiseProfile }
    var minimumSilenceDuration: TimeInterval {
        JobSilenceAnalysisCache.defaultMinimumSilenceDuration
    }
}

public final class SilenceDetectionService: SilenceDetectionServicing {
    private let executableURL: URL
    private let runner: ProcessRunner
    public let noiseProfile: String
    public let minimumSilenceDuration: TimeInterval

    public init(
        executableURL: URL,
        runner: ProcessRunner,
        noiseProfile: String = JobSilenceAnalysisCache.defaultNoiseProfile,
        minimumSilenceDuration: TimeInterval =
            JobSilenceAnalysisCache.defaultMinimumSilenceDuration
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.noiseProfile = noiseProfile
        self.minimumSilenceDuration = minimumSilenceDuration
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
            "-af", "silencedetect=noise=\(noiseProfile):d=\(Self.seconds(minimumSilenceDuration))",
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
