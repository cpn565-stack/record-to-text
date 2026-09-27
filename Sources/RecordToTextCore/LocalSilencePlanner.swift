import CoreFoundation
import Foundation

/// Phase 1 §2: which strategy produced a frozen plan.
///
/// Recorded in the manifest and folded into `planID`, so a resume can tell what
/// it is continuing without re-deriving a single boundary.
public enum LocalPlannerStrategy {
    /// Arithmetic cut points at exact multiples of the layer limit.
    public static let fixed = "local-fixed-v2"
    /// Cut points moved onto detected pauses.
    public static let silence = "local-silence-v1"
}

/// Reads a canonical `"%.6f"` string back as a `Double`.
///
/// The canonical subset has no float type, so every double these documents hold
/// is written as fixed-precision text. Accepting only that would be enough for
/// files Swift froze; accepting a JSON number too keeps hand-written fixtures
/// from failing for a reason that has nothing to do with what they test.
func decodeCanonicalSeconds<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    _ key: K
) throws -> Double {
    if let text = try? container.decode(String.self, forKey: key) {
        guard let value = Double(text), value.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue)「\(text)」不是可解析的秒數。"
            )
        }
        return value
    }
    return try container.decode(Double.self, forKey: key)
}

/// Every threshold §4's selection table depends on.
///
/// Persisted with the plan because a resume that silently used different
/// thresholds would produce different boundaries for the same audio, and the
/// committed root states would no longer describe the audio they sit next to.
public struct LocalSilenceThresholds: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let maximumRootSeconds: Double
    public let outerSearchSeconds: Double
    public let displayGroupSeconds: Double
    public let displaySearchSeconds: Double
    public let chunkSeconds: Double
    public let innerSearchSeconds: Double
    public let recursiveSearchSeconds: Double
    public let minimumChildSeconds: Double
    public let noiseProfile: String
    public let minimumSilenceDurationSeconds: Double
    public let maximumIntervalCount: Int

    /// §3.2 calls these engineering defaults, not validated recognition
    /// parameters. They are spelled out here so the manifest says which numbers
    /// a plan was built with instead of implying they are tuned.
    public static let current = LocalSilenceThresholds(
        maximumRootSeconds: 1_200,
        outerSearchSeconds: 30,
        displayGroupSeconds: LocalCheckpointSchema.displayGroupSeconds,
        displaySearchSeconds: 5,
        chunkSeconds: ASRRequest.defaultChunkDurationSeconds,
        innerSearchSeconds: 5,
        recursiveSearchSeconds: 5,
        minimumChildSeconds: 30,
        noiseProfile: JobSilenceAnalysisCache.defaultNoiseProfile,
        minimumSilenceDurationSeconds: JobSilenceAnalysisCache.defaultMinimumSilenceDuration,
        maximumIntervalCount: JobSilenceAnalysisCache.defaultMaximumIntervalCount
    )

    public init(
        maximumRootSeconds: Double,
        outerSearchSeconds: Double,
        displayGroupSeconds: Double,
        displaySearchSeconds: Double,
        chunkSeconds: Double,
        innerSearchSeconds: Double,
        recursiveSearchSeconds: Double,
        minimumChildSeconds: Double,
        noiseProfile: String,
        minimumSilenceDurationSeconds: Double,
        maximumIntervalCount: Int
    ) {
        self.maximumRootSeconds = maximumRootSeconds
        self.outerSearchSeconds = outerSearchSeconds
        self.displayGroupSeconds = displayGroupSeconds
        self.displaySearchSeconds = displaySearchSeconds
        self.chunkSeconds = chunkSeconds
        self.innerSearchSeconds = innerSearchSeconds
        self.recursiveSearchSeconds = recursiveSearchSeconds
        self.minimumChildSeconds = minimumChildSeconds
        self.noiseProfile = noiseProfile
        self.minimumSilenceDurationSeconds = minimumSilenceDurationSeconds
        self.maximumIntervalCount = maximumIntervalCount
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "chunkSeconds": .string(Self.seconds(chunkSeconds)),
            "displayGroupSeconds": .string(Self.seconds(displayGroupSeconds)),
            "displaySearchSeconds": .string(Self.seconds(displaySearchSeconds)),
            "innerSearchSeconds": .string(Self.seconds(innerSearchSeconds)),
            "maximumIntervalCount": .integer(Int64(maximumIntervalCount)),
            "maximumRootSeconds": .string(Self.seconds(maximumRootSeconds)),
            "minimumChildSeconds": .string(Self.seconds(minimumChildSeconds)),
            "minimumSilenceDurationSeconds": .string(Self.seconds(minimumSilenceDurationSeconds)),
            "noiseProfile": .string(noiseProfile),
            "outerSearchSeconds": .string(Self.seconds(outerSearchSeconds)),
            "recursiveSearchSeconds": .string(Self.seconds(recursiveSearchSeconds))
        ])
    }

    /// Doubles are excluded from the canonical subset, so thresholds travel as
    /// fixed-precision strings. Both languages must format them identically or
    /// the digest the helper verifies stops matching.
    public static func seconds(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private enum CodingKeys: String, CodingKey {
        case maximumRootSeconds
        case outerSearchSeconds
        case displayGroupSeconds
        case displaySearchSeconds
        case chunkSeconds
        case innerSearchSeconds
        case recursiveSearchSeconds
        case minimumChildSeconds
        case noiseProfile
        case minimumSilenceDurationSeconds
        case maximumIntervalCount
    }

    /// Doubles are excluded from the canonical subset, so every threshold this
    /// persists is a `"%.6f"` string. The synthesized `Decodable` would reject
    /// those exact bytes, which would make a frozen plan writable and digestible
    /// but never re-readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maximumRootSeconds = try decodeCanonicalSeconds(container, .maximumRootSeconds)
        outerSearchSeconds = try decodeCanonicalSeconds(container, .outerSearchSeconds)
        displayGroupSeconds = try decodeCanonicalSeconds(container, .displayGroupSeconds)
        displaySearchSeconds = try decodeCanonicalSeconds(container, .displaySearchSeconds)
        chunkSeconds = try decodeCanonicalSeconds(container, .chunkSeconds)
        innerSearchSeconds = try decodeCanonicalSeconds(container, .innerSearchSeconds)
        recursiveSearchSeconds = try decodeCanonicalSeconds(container, .recursiveSearchSeconds)
        minimumChildSeconds = try decodeCanonicalSeconds(container, .minimumChildSeconds)
        noiseProfile = try container.decode(String.self, forKey: .noiseProfile)
        minimumSilenceDurationSeconds = try decodeCanonicalSeconds(
            container,
            .minimumSilenceDurationSeconds
        )
        maximumIntervalCount = try container.decode(Int.self, forKey: .maximumIntervalCount)
    }

    /// Substitute the three values that come from injected services instead of
    /// from `current`.
    ///
    /// The outer cap is `TranscriptionEngine.maximumASRSegmentDuration` and the
    /// detector profile belongs to whichever `SilenceDetectionServicing` the
    /// engine was built with. Persisting `current` while planning with something
    /// else would make the manifest lie about how the boundaries were chosen.
    public func resolving(
        maximumRootSeconds: Double,
        noiseProfile: String,
        minimumSilenceDurationSeconds: Double
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
}

/// One detected pause, already in absolute original-recording samples.
public struct LocalSilenceInterval: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let startSample: Int64
    public let endSample: Int64

    public init(startSample: Int64, endSample: Int64) {
        self.startSample = startSample
        self.endSample = endSample
    }

    /// Integer midpoint. Truncation matches Python's ``//`` for the
    /// non-negative coordinates this type only ever holds, which is what keeps
    /// the helper's candidate list identical to Swift's.
    public var midpointSample: Int64 {
        startSample + (endSample - startSample) / 2
    }

    public var span: LocalSampleSpan {
        LocalSampleSpan(start: startSample, end: endSample)
    }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "endSample": .integer(endSample),
            "startSample": .integer(startSample)
        ])
    }
}

/// Merged silence intervals plus the candidate midpoints §4 selects from.
///
/// Selection is deliberately the only thing this type does. It never decides
/// whether a span was "silent enough to skip" — §6 restricts that to a
/// whole-leaf coverage test, which is `covers(_:)` and nothing else.
public struct LocalSilenceCandidateIndex: Equatable, Sendable {
    /// Merged, sorted, non-overlapping.
    public let intervals: [LocalSilenceInterval]
    /// Sorted unique interval midpoints.
    public let candidates: [Int64]

    public static let empty = LocalSilenceCandidateIndex(intervals: [])

    public init(intervals: [LocalSilenceInterval]) {
        let merged = Self.merged(intervals)
        self.intervals = merged
        self.candidates = Array(Set(merged.map(\.midpointSample))).sorted()
    }

    public var isEmpty: Bool { candidates.isEmpty }

    /// §3.3: merge touching or overlapping intervals so a pause reported twice
    /// by the detector cannot become two candidates a hair apart.
    public static func merged(_ intervals: [LocalSilenceInterval]) -> [LocalSilenceInterval] {
        let sorted = intervals
            .filter { $0.endSample > $0.startSample }
            .sorted {
                if $0.startSample == $1.startSample {
                    return $0.endSample < $1.endSample
                }
                return $0.startSample < $1.startSample
            }
        var result: [LocalSilenceInterval] = []
        result.reserveCapacity(sorted.count)
        for interval in sorted {
            guard let last = result.last, interval.startSample <= last.endSample else {
                result.append(interval)
                continue
            }
            result[result.count - 1] = LocalSilenceInterval(
                startSample: last.startSample,
                endSample: max(last.endSample, interval.endSample)
            )
        }
        return result
    }

    /// Largest candidate inside `[lower, upper]`.
    ///
    /// Both the outer-root and inner-chunk rows of §4 search the window that
    /// *ends* at the layer limit and take the pause closest to it, which on a
    /// one-sided window is simply the largest.
    public func latestCandidate(atMost upper: Int64, atLeast lower: Int64) -> Int64? {
        guard lower <= upper else {
            return nil
        }
        var best: Int64?
        for candidate in candidatesInRange(lower...upper) {
            best = candidate
        }
        return best
    }

    /// Candidate closest to `target` inside `[lower, upper]`; ties go earlier.
    ///
    /// Used by the display-group and token-recursion rows, whose windows
    /// straddle the target. Ties must break deterministically or the same audio
    /// could plan two ways.
    public func nearestCandidate(to target: Int64, atMost upper: Int64, atLeast lower: Int64) -> Int64? {
        guard lower <= upper else {
            return nil
        }
        var best: Int64?
        var bestDistance: Int64?
        for candidate in candidatesInRange(lower...upper) {
            let distance = abs(candidate - target)
            // Strict `<` keeps the first (earliest) of an equidistant pair.
            if let bestDistance, distance >= bestDistance {
                continue
            }
            best = candidate
            bestDistance = distance
        }
        return best
    }

    /// §6: the whole span lies inside one verified silence interval.
    ///
    /// Partial coverage is not evidence. A leaf that is 90% silent can still
    /// hold a word, and deleting it is exactly the failure §1 forbids. An empty
    /// or reversed span is not evidence either: it proves nothing about any
    /// sample, and Python's `SilenceCandidateIndex.covers` answers `False` for
    /// it, so the two sides would otherwise disagree about the same leaf.
    public func covers(_ span: LocalSampleSpan) -> Bool {
        guard span.end > span.start else {
            return false
        }
        return intervals.contains {
            $0.startSample <= span.start && $0.endSample >= span.end
        }
    }

    private func candidatesInRange(_ range: ClosedRange<Int64>) -> ArraySlice<Int64> {
        guard !candidates.isEmpty else {
            return candidates[...]
        }
        let first = lowerBound(range.lowerBound)
        guard first < candidates.endIndex else {
            return candidates[0..<0]
        }
        var last = first
        while last + 1 < candidates.endIndex, candidates[last + 1] <= range.upperBound {
            last += 1
        }
        guard candidates[first] <= range.upperBound else {
            return candidates[0..<0]
        }
        return candidates[first...last]
    }

    /// First index whose value is `>= target`, by binary search.
    ///
    /// A three-hour recording can hold thousands of pauses and the cap allows
    /// 100,000; scanning the whole list per boundary would turn planning into
    /// the slowest step in the pipeline for no benefit.
    private func lowerBound(_ target: Int64) -> Int {
        var low = 0
        var high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if candidates[middle] < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

/// Scan-relative detector output → absolute sample coordinates (§3.3).
///
/// `SilenceDetectionService` reports seconds relative to whatever it was asked
/// to scan. Those numbers are *not* sample indices and are not relative to the
/// original recording, so every value passes through quantization, clamping and
/// validation here before anything plans against it.
public enum LocalSilenceScanner {
    /// All local layers share these already merged, absolute sample candidates.
    /// Seconds exist only at the extraction adapter, relative to normalized PCM.
    public static func makeOuterPlan(
        workStartSample: Int64,
        sampleCount: Int64,
        candidates: LocalSilenceCandidateIndex,
        thresholds: LocalSilenceThresholds = .current
    ) throws -> AudioSegmentationPlan {
        let cap = try LocalAudioCoordinates.quantize(seconds: thresholds.maximumRootSeconds)
        let search = try LocalAudioCoordinates.quantize(seconds: thresholds.outerSearchSeconds)
        let end = workStartSample.addingReportingOverflow(sampleCount)
        guard workStartSample >= 0, sampleCount > 0, cap > 0, !end.overflow else {
            throw LocalSilenceValidation.invalid("outer.range")
        }
        var cursor = workStartSample
        var segments: [PlannedAudioSegment] = []
        while cursor < end.partialValue {
            let remaining = end.partialValue - cursor
            let boundary = remaining <= cap ? end.partialValue : LocalSilenceBoundarySelector.limitBoundary(
                limit: cursor + cap, searchSamples: search, lowerBound: cursor,
                upperBound: end.partialValue, candidates: candidates
            ).boundary
            segments.append(PlannedAudioSegment(
                index: segments.count + 1,
                startSeconds: LocalAudioCoordinates.seconds(forSamples: cursor - workStartSample),
                durationSeconds: LocalAudioCoordinates.seconds(forSamples: boundary - cursor)
            ))
            cursor = boundary
        }
        return AudioSegmentationPlan(
            sourceDurationSeconds: LocalAudioCoordinates.seconds(forSamples: sampleCount),
            maximumSegmentDurationSeconds: thresholds.maximumRootSeconds,
            segments: segments
        )
    }

    public static func absoluteIntervals(
        detected: [DetectedSilence],
        scanStartSample: Int64,
        scanEndSample: Int64
    ) -> [LocalSilenceInterval] {
        guard scanEndSample > scanStartSample else {
            return []
        }
        var result: [LocalSilenceInterval] = []
        result.reserveCapacity(detected.count)
        for silence in detected {
            guard silence.startSeconds.isFinite,
                  silence.endSeconds.isFinite,
                  silence.startSeconds >= 0,
                  silence.endSeconds > silence.startSeconds,
                  let startOffset = try? LocalAudioCoordinates.quantize(
                      seconds: silence.startSeconds
                  ),
                  let endOffset = try? LocalAudioCoordinates.quantize(
                      seconds: silence.endSeconds
                  )
            else {
                continue
            }
            let startAbsolute = scanStartSample.addingReportingOverflow(startOffset)
            let endAbsolute = scanStartSample.addingReportingOverflow(endOffset)
            guard !startAbsolute.overflow, !endAbsolute.overflow else {
                continue
            }
            // Clamped, not discarded: a pause the detector reports slightly past
            // the scanned range still marks a real boundary inside it.
            let start = max(startAbsolute.partialValue, scanStartSample)
            let end = min(endAbsolute.partialValue, scanEndSample)
            guard end > start else {
                continue
            }
            result.append(
                LocalSilenceInterval(startSample: start, endSample: end)
            )
        }
        return LocalSilenceCandidateIndex.merged(result)
    }

    /// §7: separate outer silence-cut and fallback counts.
    ///
    /// `SilenceAwareSegmentPlanner` accumulates from the previous boundary, so
    /// only the first nominal cut is a multiple of the cap. The running nominal
    /// is resynced after every moved boundary to match.
    public static func countOuterCuts(
        plan: AudioSegmentationPlan,
        maximumSegmentDuration: TimeInterval
    ) -> (silenceCuts: Int, fallbacks: Int) {
        guard maximumSegmentDuration > 0 else {
            return (0, 0)
        }
        var silenceCuts = 0
        var fallbacks = 0
        var nominal = 0.0
        for segment in plan.segments.dropLast() {
            nominal += maximumSegmentDuration
            if abs(segment.endSeconds - nominal) <= 1e-9 {
                fallbacks += 1
            } else {
                silenceCuts += 1
            }
            nominal = segment.endSeconds
        }
        return (silenceCuts, fallbacks)
    }
}

/// One boundary decision plus whether a pause caused it (§7 metrics).
public struct LocalBoundaryDecision: Equatable, Sendable {
    public let boundary: Int64
    /// True only when the boundary sits on a detected pause *and* differs from
    /// the arithmetic limit. A pause that lands exactly on the limit moved
    /// nothing, so counting it as a silence cut would overstate the effect.
    public let usedSilence: Bool

    public static func fallback(_ boundary: Int64) -> LocalBoundaryDecision {
        LocalBoundaryDecision(boundary: boundary, usedSilence: false)
    }
}

/// §4's selection rules. Each returns a boundary that already respects the
/// caller's hard bounds, so no layer can be pushed past its own limit.
public enum LocalSilenceBoundarySelector {
    /// Window ends at the limit: outer root (§4 row 1) and initial chunk
    /// (§4 row 3).
    public static func limitBoundary(
        limit: Int64,
        searchSamples: Int64,
        lowerBound: Int64,
        upperBound: Int64,
        candidates: LocalSilenceCandidateIndex
    ) -> LocalBoundaryDecision {
        let capped = min(limit, upperBound)
        guard capped > lowerBound else {
            return .fallback(max(capped, lowerBound))
        }
        let windowStart = max(lowerBound + 1, capped - max(searchSamples, 0))
        guard let chosen = candidates.latestCandidate(
            atMost: capped,
            atLeast: windowStart
        ), chosen > lowerBound, chosen != capped else {
            return .fallback(capped)
        }
        return LocalBoundaryDecision(boundary: chosen, usedSilence: true)
    }

    /// Window straddles the target: display group (§4 row 2) and token
    /// recursion (§4 row 4).
    public static func nearestBoundary(
        target: Int64,
        searchSamples: Int64,
        lowerBound: Int64,
        upperBound: Int64,
        candidates: LocalSilenceCandidateIndex
    ) -> LocalBoundaryDecision {
        let search = max(searchSamples, 0)
        let windowStart = max(lowerBound, target - search)
        let windowEnd = min(upperBound, target + search)
        guard windowStart <= windowEnd else {
            return .fallback(min(max(target, lowerBound), upperBound))
        }
        guard let chosen = candidates.nearestCandidate(
            to: target,
            atMost: windowEnd,
            atLeast: windowStart
        ), chosen != target else {
            return .fallback(min(max(target, lowerBound), upperBound))
        }
        return LocalBoundaryDecision(boundary: chosen, usedSilence: true)
    }

    /// §4 row 2's first preference: an existing root boundary near the target.
    ///
    /// Snapping to a root the plan already cuts there avoids a display group
    /// that differs from it by a couple of seconds and so creates a fragment
    /// for no reading benefit.
    public static func nearestRootBoundary(
        to target: Int64,
        searchSamples: Int64,
        rootBoundaries: [Int64],
        lowerBound: Int64,
        upperBound: Int64
    ) -> Int64? {
        let search = max(searchSamples, 0)
        let windowStart = max(lowerBound, target - search)
        let windowEnd = min(upperBound, target + search)
        guard windowStart <= windowEnd else {
            return nil
        }
        var best: Int64?
        var bestDistance: Int64?
        for boundary in rootBoundaries.sorted() {
            guard boundary >= windowStart, boundary <= windowEnd else {
                continue
            }
            let distance = abs(boundary - target)
            if let bestDistance, distance >= bestDistance {
                continue
            }
            best = boundary
            bestDistance = distance
        }
        return best
    }
}

/// `silence-plan.json`: the frozen analysis Swift hands the helper (§7).
///
/// The helper never calls ffmpeg for candidates. It loads this file, checks the
/// digest the manifest records, and slices by real samples. When the interval
/// list was dropped for overabundance the plan still stands — only the
/// recursive chooser degrades to a legal midpoint, which §7 allows and requires
/// to be logged.
public struct LocalSilencePlan: Codable, Equatable, Sendable, CanonicalJSONRepresentable {
    public let schemaVersion: Int
    public let plannerVersion: String
    public let enabled: Bool
    public let detector: String
    public let thresholds: LocalSilenceThresholds
    public let coveredStartSample: Int64
    public let coveredEndSample: Int64
    /// Digest of the PCM actually scanned, so a later run can prove the pauses
    /// belong to this audio rather than to a same-named file.
    public let scanPCMSHA256: String
    public let normalizationDigest: String
    public let sourceSHA256: String
    /// §3.7: intervals exceeded the cap. The cut plan derived from them is in
    /// the manifest; only the list is gone.
    public let truncated: Bool
    public let intervals: [LocalSilenceInterval]
    public let scanCount: Int
    public let scannedAudioSeconds: Double
    public let scanElapsedMilliseconds: Double
    public let cacheHitCount: Int
    public let outerSilenceCuts: Int
    public let outerFallbacks: Int
    public let innerSilenceCuts: Int
    public let innerFallbacks: Int

    public init(
        schemaVersion: Int = LocalCheckpointSchema.version,
        plannerVersion: String = LocalPlannerStrategy.silence,
        enabled: Bool = true,
        detector: String = LocalSilencePlan.ffmpegDetector,
        thresholds: LocalSilenceThresholds = .current,
        coveredStartSample: Int64,
        coveredEndSample: Int64,
        scanPCMSHA256: String,
        normalizationDigest: String,
        sourceSHA256: String,
        truncated: Bool = false,
        intervals: [LocalSilenceInterval] = [],
        scanCount: Int = 0,
        scannedAudioSeconds: Double = 0,
        scanElapsedMilliseconds: Double = 0,
        cacheHitCount: Int = 0,
        outerSilenceCuts: Int = 0,
        outerFallbacks: Int = 0,
        innerSilenceCuts: Int = 0,
        innerFallbacks: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.plannerVersion = plannerVersion
        self.enabled = enabled
        self.detector = detector
        self.thresholds = thresholds
        self.coveredStartSample = coveredStartSample
        self.coveredEndSample = coveredEndSample
        self.scanPCMSHA256 = scanPCMSHA256
        self.normalizationDigest = normalizationDigest
        self.sourceSHA256 = sourceSHA256
        self.truncated = truncated
        self.intervals = intervals
        self.scanCount = scanCount
        self.scannedAudioSeconds = scannedAudioSeconds
        self.scanElapsedMilliseconds = scanElapsedMilliseconds
        self.cacheHitCount = cacheHitCount
        self.outerSilenceCuts = outerSilenceCuts
        self.outerFallbacks = outerFallbacks
        self.innerSilenceCuts = innerSilenceCuts
        self.innerFallbacks = innerFallbacks
    }

    public static let ffmpegDetector = "ffmpeg-silencedetect"

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case plannerVersion
        case enabled
        case detector
        case thresholds
        case coveredStartSample
        case coveredEndSample
        case scanPCMSHA256
        case normalizationDigest
        case sourceSHA256
        case truncated
        case intervals
        case scanCount
        case scannedAudioSeconds
        case scanElapsedMilliseconds
        case cacheHitCount
        case outerSilenceCuts
        case outerFallbacks
        case innerSilenceCuts
        case innerFallbacks
    }

    /// Mirrors `canonicalValue` field for field, with the two measured durations
    /// read back from the `"%.6f"` strings they were written as.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        plannerVersion = try container.decode(String.self, forKey: .plannerVersion)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        detector = try container.decode(String.self, forKey: .detector)
        thresholds = try container.decode(
            LocalSilenceThresholds.self,
            forKey: .thresholds
        )
        coveredStartSample = try container.decode(Int64.self, forKey: .coveredStartSample)
        coveredEndSample = try container.decode(Int64.self, forKey: .coveredEndSample)
        scanPCMSHA256 = try container.decode(String.self, forKey: .scanPCMSHA256)
        normalizationDigest = try container.decode(String.self, forKey: .normalizationDigest)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        intervals = try container.decode([LocalSilenceInterval].self, forKey: .intervals)
        scanCount = try container.decode(Int.self, forKey: .scanCount)
        scannedAudioSeconds = try decodeCanonicalSeconds(container, .scannedAudioSeconds)
        scanElapsedMilliseconds = try decodeCanonicalSeconds(
            container,
            .scanElapsedMilliseconds
        )
        cacheHitCount = try container.decode(Int.self, forKey: .cacheHitCount)
        outerSilenceCuts = try container.decode(Int.self, forKey: .outerSilenceCuts)
        outerFallbacks = try container.decode(Int.self, forKey: .outerFallbacks)
        innerSilenceCuts = try container.decode(Int.self, forKey: .innerSilenceCuts)
        innerFallbacks = try container.decode(Int.self, forKey: .innerFallbacks)
    }

    public var coveredSpan: LocalSampleSpan {
        LocalSampleSpan(start: coveredStartSample, end: coveredEndSample)
    }

    /// Validate JSON number types before Decodable erases their representation.
    /// JSONDecoder accepts `0.0` and `0e0` as Int64, whereas Python's persisted
    /// contract rejects both. JSONSerialization preserves those as floating
    /// NSNumbers, so inspect only the integer fields, then do the typed decode.
    /// Durations still accept canonical strings or JSON fractional numbers.
    static func decodePersisted(from bytes: Data) throws -> LocalSilencePlan {
        let value = try JSONSerialization.jsonObject(with: bytes)
        guard let object = value as? [String: Any],
              let thresholds = object["thresholds"] as? [String: Any],
              let intervals = object["intervals"] as? [[String: Any]] else {
            throw LocalSilenceValidation.invalid("silencePlan.structure")
        }
        func requireIntegers(_ object: [String: Any], keys: [String], path: String) throws {
            for key in keys {
                guard let number = object[key] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      !["f", "d"].contains(String(cString: number.objCType)),
                      Int64(number.stringValue) != nil else {
                    throw LocalCheckpointError.invalidField(
                        field: "\(path).\(key)",
                        reason: "必須是 Int64 範圍內的 JSON 整數，不接受浮點、指數、布林或字串。"
                    )
                }
            }
        }
        try requireIntegers(object, keys: [
            "schemaVersion", "coveredStartSample", "coveredEndSample", "scanCount",
            "cacheHitCount", "outerSilenceCuts", "outerFallbacks", "innerSilenceCuts", "innerFallbacks",
        ], path: "silencePlan")
        try requireIntegers(thresholds, keys: ["maximumIntervalCount"], path: "thresholds")
        for (index, interval) in intervals.enumerated() {
            try requireIntegers(interval, keys: ["startSample", "endSample"], path: "intervals[\(index)]")
        }
        return try JSONDecoder().decode(LocalSilencePlan.self, from: bytes)
    }

    /// Empty when `truncated`, which is the signal to fall back to midpoints.
    public var candidateIndex: LocalSilenceCandidateIndex {
        LocalSilenceCandidateIndex(intervals: intervals)
    }

    /// SHA-256 over the exact bytes written to disk. The helper recomputes it
    /// from the file and compares against the manifest, the same way
    /// `identityDigest` works.
    public var digest: String { LocalDigest.sha256(self) }

    public var canonicalValue: CanonicalJSONValue {
        .object([
            "cacheHitCount": .integer(Int64(cacheHitCount)),
            "coveredEndSample": .integer(coveredEndSample),
            "coveredStartSample": .integer(coveredStartSample),
            "detector": .string(detector),
            "enabled": .bool(enabled),
            "innerFallbacks": .integer(Int64(innerFallbacks)),
            "innerSilenceCuts": .integer(Int64(innerSilenceCuts)),
            "intervals": .representables(intervals),
            "normalizationDigest": .string(normalizationDigest),
            "outerFallbacks": .integer(Int64(outerFallbacks)),
            "outerSilenceCuts": .integer(Int64(outerSilenceCuts)),
            "plannerVersion": .string(plannerVersion),
            "scanCount": .integer(Int64(scanCount)),
            "scanElapsedMilliseconds": .string(
                LocalSilenceThresholds.seconds(scanElapsedMilliseconds)
            ),
            "scanPCMSHA256": .string(scanPCMSHA256),
            "scannedAudioSeconds": .string(
                LocalSilenceThresholds.seconds(scannedAudioSeconds)
            ),
            "schemaVersion": .integer(Int64(schemaVersion)),
            "sourceSHA256": .string(sourceSHA256),
            "thresholds": thresholds.canonicalValue,
            "truncated": .bool(truncated)
        ])
    }
}

public enum LocalSilencePlanStore {
    public static func write(
        _ plan: LocalSilencePlan,
        to layout: LocalCheckpointLayout,
        fileManager: FileManager = .default
    ) throws {
        try layout.createDirectories(fileManager: fileManager)
        try AtomicFileWriter.write(plan.canonicalBytes(), to: layout.silencePlanURL)
    }

    /// Returns `nil` when no plan was frozen, which is the normal state for a
    /// fixed-cut job and for anything planned before phase 1.
    public static func load(
        from layout: LocalCheckpointLayout,
        expectedDigest: String?,
        fileManager: FileManager = .default
    ) throws -> LocalSilencePlan? {
        guard fileManager.fileExists(atPath: layout.silencePlanURL.path) else {
            guard expectedDigest == nil else {
                throw LocalCheckpointError.missingFile(path: layout.silencePlanURL.path)
            }
            return nil
        }
        let bytes = try LocalCheckpointValidator.readBytes(
            at: layout.silencePlanURL,
            fileManager: fileManager
        )
        let plan: LocalSilencePlan
        do {
            plan = try LocalSilencePlan.decodePersisted(from: bytes)
        } catch let error as LocalCheckpointError {
            throw error
        } catch {
            throw LocalCheckpointError.invalidJSON(
                path: layout.silencePlanURL.path,
                reason: error.localizedDescription
            )
        }
        guard plan.schemaVersion == LocalCheckpointSchema.version else {
            throw LocalCheckpointError.unknownSchemaVersion(
                found: plan.schemaVersion,
                path: layout.silencePlanURL.path
            )
        }
        if let expectedDigest {
            let actual = LocalDigest.sha256(bytes)
            guard actual == expectedDigest else {
                throw LocalCheckpointError.digestMismatch(
                    kind: "silence-plan.json",
                    expected: expectedDigest,
                    actual: actual
                )
            }
        }
        return plan
    }
}

extension LocalSilencePlan {
    /// The §7 aggregate line. Kept as one formatted string so the numbers a
    /// user reads in the log are the numbers that were measured, and so scan
    /// cost is never folded into inference time.
    public func metricsSummary() -> String {
        String(
            format:
                "silence_scan_count=%d；silence_scanned_audio_seconds=%.3f；silence_scan_elapsed_ms=%.3f；silence_cache_hits=%d；outer_silence_cuts=%d；outer_fallbacks=%d；inner_silence_cuts=%d；inner_fallbacks=%d；intervals=%d%@",
            scanCount,
            scannedAudioSeconds,
            scanElapsedMilliseconds,
            cacheHitCount,
            outerSilenceCuts,
            outerFallbacks,
            innerSilenceCuts,
            innerFallbacks,
            intervals.count,
            truncated ? "（已超過保存上限，僅保留切點方案）" : ""
        )
    }
}
