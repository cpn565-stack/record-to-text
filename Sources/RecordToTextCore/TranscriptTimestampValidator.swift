import Foundation

public enum TranscriptTimestampIssue: String, Codable, Equatable, Sendable {
    case missingIntervals
    case invalidOrder
    case outsideSegment
    case malformedMarker
}

public struct TranscriptTimestampReview: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable {
        case unchanged
        case boundsCorrected
        case segmentRangeOnly
    }
    public let disposition: Disposition
    public let issues: [TranscriptTimestampIssue]
    public var needsReview: Bool { disposition == .segmentRangeOnly }
}

public struct TranscriptTimestampResult: Equatable, Sendable {
    public let text: String
    public let review: TranscriptTimestampReview
}

/// Checks heading structure, not acoustic alignment or transcript completeness.
/// Only audio boundaries are authoritative; missing internal alignment is never invented.
public enum TranscriptTimestampValidator {
    public static let reviewNotice = "[時間標記提示：本段時間標記不完整或不可靠，以下僅標示實際音訊範圍；段內時間待核對。]"
    private static let marker = try! NSRegularExpression(
        pattern: #"^\s*\[(\d{1,6}:\d{2}(?::\d{2})?)\s*[-–—－]\s*(\d{1,6}:\d{2}(?::\d{2})?)\]\s*$"#
    )
    private static let markerLike = try! NSRegularExpression(pattern: #"^\s*\[\d[^\]]*[:：][^\]]*[-–—－][^\]]*\]\s*$"#)

    public static func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds).rounded(.down))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    public static func range(start: Double, end: Double) -> String {
        "[\(timestamp(start)) - \(timestamp(end))]"
    }

    public static func validate(text: String, startSeconds: Double, endSeconds: Double) -> TranscriptTimestampResult {
        // Invalid media bounds are handled by the audio planner, never guessed here.
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
              endSeconds > startSeconds, endSeconds < Double(Int.max / 2) else {
            return .init(text: text, review: .init(disposition: .unchanged, issues: []))
        }
        let start = floor(startSeconds)
        let end = floor(endSeconds)
        var lines = text.components(separatedBy: "\n")
        var headings: [(line: Int, start: Double, end: Double)] = []
        var headingLines = Set<Int>()
        var issues: [TranscriptTimestampIssue] = []
        func flag(_ issue: TranscriptTimestampIssue) {
            if !issues.contains(issue) { issues.append(issue) }
        }
        for (index, line) in lines.enumerated() {
            let nsRange = NSRange(line.startIndex..., in: line)
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == reviewNotice {
                headingLines.insert(index)
                flag(.missingIntervals)
            } else if let match = marker.firstMatch(in: line, range: nsRange) {
                headingLines.insert(index)
                guard let a = Range(match.range(at: 1), in: line),
                      let b = Range(match.range(at: 2), in: line),
                      let from = seconds(String(line[a])), let to = seconds(String(line[b])) else {
                    flag(.malformedMarker)
                    continue
                }
                headings.append((index, from, to))
            } else if markerLike.firstMatch(in: line, range: nsRange) != nil {
                headingLines.insert(index)
                flag(.malformedMarker)
            }
        }

        if headings.isEmpty { flag(.missingIntervals) }
        var corrected = false
        for index in headings.indices {
            let original = headings[index]
            // Only the outer endpoints can be corrected without guessing which
            // utterance belongs to an internal five-minute boundary.
            if index == 0, abs(original.start - start) <= 1 {
                headings[index].start = start
            }
            if index == headings.count - 1, original.end >= end - 1 {
                headings[index].end = end
            }
            let item = headings[index]
            if item.start < start || item.start >= end || item.end > end {
                flag(.outsideSegment)
            }
            if item.end <= item.start { flag(.invalidOrder) }
            if item.end - item.start > 301 { flag(.missingIntervals) }
            if index > 0 {
                let previous = headings[index - 1]
                if item.start < previous.end { flag(.invalidOrder) }
                if item.start > previous.end { flag(.missingIntervals) }
            }
            if item.start != original.start || item.end != original.end {
                lines[item.line] = range(start: item.start, end: item.end)
                corrected = true
            }
        }
        if let first = headings.first {
            if first.start != start { flag(.missingIntervals) }
            if lines[..<first.line].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                flag(.missingIntervals)
            }
        }
        if let last = headings.last, last.end != end { flag(.missingIntervals) }

        guard issues.isEmpty else {
            // Preserve every non-heading line in order, including speaker labels,
            // blank lines and incomplete utterances. This operation is idempotent.
            let body = lines.enumerated().filter { !headingLines.contains($0.offset) }
                .map(\.element).joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            return .init(text: "\(range(start: start, end: end))\n\n\(reviewNotice)\n\n\(body)",
                         review: .init(disposition: .segmentRangeOnly, issues: issues))
        }
        return .init(text: corrected ? lines.joined(separator: "\n") : text,
                     review: .init(disposition: corrected ? .boundsCorrected : .unchanged, issues: []))
    }

    private static func seconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count), parts.last! < 60,
              parts.count == 2 || parts[1] < 60 else { return nil }
        return Double(parts.reduce(0) { $0 * 60 + $1 })
    }
}
