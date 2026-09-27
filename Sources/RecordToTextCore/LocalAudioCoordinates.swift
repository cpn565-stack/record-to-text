import Foundation

/// Sample-precise coordinate contract shared by Swift and the Python helper.
///
/// Every persisted audio boundary is a 64-bit sample index at 16 kHz, using
/// half-open `[start, end)` ranges expressed in *original recording* space.
/// Quantization happens exactly once, at the source-slice boundary; downstream
/// code must never re-quantize or accumulate floating point seconds.
public enum LocalAudioCoordinates {
    public static let sampleRate: Int64 = 16_000

    /// Container metadata may disagree slightly with decoded samples. Beyond
    /// this the work is rejected rather than silently re-timed.
    public static let maximumDurationMismatchSeconds: Double = 0.1

    public static func samples(forSeconds seconds: Double) -> Double {
        seconds * Double(sampleRate)
    }

    public static func seconds(forSamples samples: Int64) -> Double {
        Double(samples) / Double(sampleRate)
    }

    /// `floor(seconds * 16000 + 0.5)`, computed once per boundary.
    public static func quantize(seconds: Double) throws -> Int64 {
        guard seconds.isFinite else {
            throw LocalCoordinateError.nonFiniteSeconds(seconds)
        }
        guard seconds >= 0 else {
            throw LocalCoordinateError.negativeSeconds(seconds)
        }
        let scaled = seconds * Double(sampleRate) + 0.5
        guard scaled < Double(Int64.max) else {
            throw LocalCoordinateError.secondsOutOfRange(seconds)
        }
        return Int64(scaled.rounded(.down))
    }

    public static func formatTimestamp(samples: Int64) -> String {
        let clamped = max(samples, 0)
        let totalSeconds = clamped / sampleRate
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(
            format: "%02d:%02d:%02d",
            Int(hours),
            Int(minutes),
            Int(seconds)
        )
    }
}

public enum LocalCoordinateError: LocalizedError, Equatable {
    case nonFiniteSeconds(Double)
    case negativeSeconds(Double)
    case secondsOutOfRange(Double)
    case negativeSample(field: String, value: Int64)
    case emptySpan(field: String, start: Int64, end: Int64)
    case reversedSpan(field: String, start: Int64, end: Int64)
    case spanOutsideWork(field: String, start: Int64, end: Int64, workStart: Int64, workEnd: Int64)
    case overflow(field: String)
    case durationMismatch(containerSeconds: Double, decodedSeconds: Double)

    public var errorDescription: String? {
        switch self {
        case let .nonFiniteSeconds(value):
            return "音訊秒數不是有限數字：\(value)。"
        case let .negativeSeconds(value):
            return "音訊秒數不可為負：\(value)。"
        case let .secondsOutOfRange(value):
            return "音訊秒數超出可表示範圍：\(value)。"
        case let .negativeSample(field, value):
            return "\(field) 的 sample 座標不可為負：\(value)。"
        case let .emptySpan(field, start, end):
            return "\(field) 的區間為空：[\(start), \(end))。"
        case let .reversedSpan(field, start, end):
            return "\(field) 的區間起點晚於終點：[\(start), \(end))。"
        case let .spanOutsideWork(field, start, end, workStart, workEnd):
            return "\(field) 的區間 [\(start), \(end)) 超出工作範圍 [\(workStart), \(workEnd))。"
        case let .overflow(field):
            return "\(field) 的座標換算溢位。"
        case let .durationMismatch(container, decoded):
            return String(
                format: "容器宣告時長 %.3f 秒與實際解碼 %.3f 秒相差超過 %.0f 毫秒。",
                container,
                decoded,
                LocalAudioCoordinates.maximumDurationMismatchSeconds * 1000
            )
        }
    }
}

/// A half-open `[start, end)` sample range in original-recording coordinates.
public struct LocalSampleSpan: Hashable, Sendable, Codable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var sampleCount: Int64 { end - start }

    public var seconds: Double {
        LocalAudioCoordinates.seconds(forSamples: sampleCount)
    }

    public var isEmpty: Bool { end <= start }

    public func contains(sample: Int64) -> Bool {
        sample >= start && sample < end
    }

    public func contains(_ other: LocalSampleSpan) -> Bool {
        other.start >= start && other.end <= end
    }

    public func intersects(_ other: LocalSampleSpan) -> Bool {
        start < other.end && other.start < end
    }

    /// True when `other` begins exactly where this span ends.
    public func isImmediatelyFollowedBy(_ other: LocalSampleSpan) -> Bool {
        end == other.start
    }

    public func translated(by offset: Int64) throws -> LocalSampleSpan {
        let shiftedStart = start.addingReportingOverflow(offset)
        let shiftedEnd = end.addingReportingOverflow(offset)
        guard !shiftedStart.overflow, !shiftedEnd.overflow else {
            throw LocalCoordinateError.overflow(field: "span")
        }
        return LocalSampleSpan(start: shiftedStart.partialValue, end: shiftedEnd.partialValue)
    }

    /// Validate on its own terms: finite by construction, non-negative, non-empty.
    public func validated(field: String) throws -> LocalSampleSpan {
        guard start >= 0 else {
            throw LocalCoordinateError.negativeSample(field: field, value: start)
        }
        guard end >= 0 else {
            throw LocalCoordinateError.negativeSample(field: field, value: end)
        }
        guard end != start else {
            throw LocalCoordinateError.emptySpan(field: field, start: start, end: end)
        }
        guard start < end else {
            throw LocalCoordinateError.reversedSpan(field: field, start: start, end: end)
        }
        return self
    }

    public func validatedWithin(work: LocalSampleSpan, field: String) throws -> LocalSampleSpan {
        try validated(field: field)
        guard work.contains(self) else {
            throw LocalCoordinateError.spanOutsideWork(
                field: field,
                start: start,
                end: end,
                workStart: work.start,
                workEnd: work.end
            )
        }
        return self
    }
}

extension Array where Element == LocalSampleSpan {
    /// Confirm the spans tile `work` exactly: ordered, non-overlapping, no holes.
    ///
    /// Coverage is derived from the terminal nodes themselves; a single boolean
    /// or a progress percentage is never accepted as evidence.
    public func validatedTiling(of work: LocalSampleSpan) throws {
        var cursor = work.start
        for span in self {
            guard span.start >= cursor else {
                throw LocalCoverageError.overlap(
                    previousEnd: cursor,
                    nextStart: span.start,
                    nextEnd: span.end
                )
            }
            guard span.end > span.start else {
                throw LocalCoverageError.emptySpan(start: span.start, end: span.end)
            }
            guard span.end <= work.end else {
                throw LocalCoverageError.outsideWork(
                    start: span.start,
                    end: span.end,
                    workStart: work.start,
                    workEnd: work.end
                )
            }
            if span.start > cursor {
                throw LocalCoverageError.hole(from: cursor, to: span.start)
            }
            cursor = span.end
        }
        guard cursor == work.end else {
            throw LocalCoverageError.hole(from: cursor, to: work.end)
        }
    }
}

public enum LocalCoverageError: LocalizedError, Equatable {
    case overlap(previousEnd: Int64, nextStart: Int64, nextEnd: Int64)
    case hole(from: Int64, to: Int64)
    case emptySpan(start: Int64, end: Int64)
    case outsideWork(start: Int64, end: Int64, workStart: Int64, workEnd: Int64)

    public var errorDescription: String? {
        switch self {
        case let .overlap(previousEnd, nextStart, nextEnd):
            return "終端區間重疊：前一段結束於 \(previousEnd)，下一段起始於 \(nextStart)（終點 \(nextEnd)）。"
        case let .hole(from, to):
            return "終端區間遺漏 [\(from), \(to))，共 \(to - from) 個 sample。"
        case let .emptySpan(start, end):
            return "終端區間為空：[\(start), \(end))。"
        case let .outsideWork(start, end, workStart, workEnd):
            return "終端區間 [\(start), \(end)) 超出工作範圍 [\(workStart), \(workEnd))。"
        }
    }
}
