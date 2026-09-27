import Foundation

public enum LocalMergeError: LocalizedError, Equatable {
    case coverageFailure(reason: String)
    case unrenderableLeaf(nodeID: String, state: String)
    case noSpeechContent

    public var errorDescription: String? {
        switch self {
        case let .coverageFailure(reason):
            return "已完成 leaf 未精確覆蓋工作範圍，拒絕發布：\(reason)"
        case let .unrenderableLeaf(nodeID, state):
            return "leaf \(nodeID) 的狀態 \(state) 不可進入正式稿。"
        case .noSpeechContent:
            return "整份輸出只有時間標題、缺口或靜音標記，沒有任何已驗證的辨識文字，拒絕當成正式稿。"
        }
    }
}

/// A terminal leaf reduced to what rendering needs.
public struct LocalMergedLeaf: Equatable, Sendable {
    public let nodeID: String
    public let startSample: Int64
    public let endSample: Int64
    public let state: LocalNodeState
    /// Recognized text only: no headings, no gap markers, no timestamps.
    public let text: String

    public init(
        nodeID: String,
        startSample: Int64,
        endSample: Int64,
        state: LocalNodeState,
        text: String
    ) {
        self.nodeID = nodeID
        self.startSample = startSample
        self.endSample = endSample
        self.state = state
        self.text = text
    }

    public var span: LocalSampleSpan {
        LocalSampleSpan(start: startSample, end: endSample)
    }
}

public struct LocalMergedTranscript: Equatable, Sendable {
    public let text: String
    public let containsGaps: Bool
    public let gapSampleCount: Int64
    /// End of the last leaf that actually contributed, for partial drafts.
    public let lastRenderedEndSample: Int64

    public var gapSeconds: Double {
        LocalAudioCoordinates.seconds(forSamples: gapSampleCount)
    }
}

/// Builds the published transcript from committed leaves and frozen display groups.
///
/// Positions come only from absolute sample coordinates, so a resumed run, a
/// recursively split tree, and a non-zero slice all lay out identically. Nothing
/// here may reconstruct a boundary from `segmentIndex * 1200` or `index * 120`.
public enum LocalTranscriptMerger {

    // MARK: Seam rule shared with the Python helper

    /// Operates on a single code point, matching Python's `str[-1]` / `str[0]`.
    /// A Swift `Character` is a grapheme cluster, which would diverge on
    /// combining marks.
    private static func isCJKToken(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func isCJKPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// Chinese flows without spaces, so a separator is inserted only where it
    /// keeps Latin or digit words from gluing together.
    static func needsWordSeparator(left: String, right: String) -> Bool {
        guard let leftLast = left.unicodeScalars.last,
              let rightFirst = right.unicodeScalars.first
        else { return false }
        if isCJKPunctuation(leftLast) || isCJKPunctuation(rightFirst) { return false }
        if isCJKToken(leftLast) && isCJKToken(rightFirst) { return false }
        return true
    }

    /// Byte-for-byte equivalent of `join_transcript_parts` in the helper, so a
    /// merged transcript reads the same whether Swift or Python rendered it.
    public static func joinTranscriptParts(_ parts: [String]) -> String {
        var joined = ""
        for part in parts {
            if part.isEmpty { continue }
            if !joined.isEmpty, needsWordSeparator(left: joined, right: part) {
                joined += " "
            }
            joined += part.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rendered from the gap's own measured span, never from stored prose.
    public static func gapMarker(
        startSample: Int64,
        endSample: Int64
    ) -> String {
        let seconds = LocalAudioCoordinates.seconds(forSamples: endSample - startSample)
        return String(
            format: "【此處約缺少 %.0f 秒：模型達到 token 上限，已跳過此片段】",
            seconds
        )
    }

    // MARK: Rendering

    public static func render(
        leaves: [LocalMergedLeaf],
        displayGroups: [LocalDisplayGroup],
        workSpan: LocalSampleSpan
    ) throws -> LocalMergedTranscript {
        let ordered = leaves.sorted { $0.startSample < $1.startSample }
        try ordered.map(\.span).validatedTiling(of: workSpan)
        for leaf in ordered {
            guard leaf.state.contributesCoverage else {
                throw LocalMergeError.unrenderableLeaf(
                    nodeID: leaf.nodeID,
                    state: leaf.state.rawValue
                )
            }
        }

        var sections: [String] = []
        var hasSpeech = false
        var gapSamples: Int64 = 0
        var lastRenderedEnd = workSpan.start

        for group in displayGroups {
            var parts: [String] = []
            var firstStart: Int64?
            var lastEnd = group.startSample
            for leaf in ordered {
                guard leaf.startSample >= group.startSample,
                      leaf.startSample < group.endSample
                else { continue }
                switch leaf.state {
                case .gap:
                    parts.append(
                        gapMarker(startSample: leaf.startSample, endSample: leaf.endSample)
                    )
                    gapSamples += leaf.span.sampleCount
                case .verifiedSilence:
                    // Proven silence contributes no text and no marker.
                    break
                default:
                    let text = leaf.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        parts.append(text)
                        hasSpeech = true
                    }
                }
                if firstStart == nil { firstStart = leaf.startSample }
                lastEnd = max(lastEnd, leaf.endSample)
            }
            let body = joinTranscriptParts(parts)
            guard let sectionStart = firstStart, !body.isEmpty else { continue }
            // A heading must never turn an empty ASR result into a transcript.
            sections.append(
                "[\(LocalAudioCoordinates.formatTimestamp(samples: sectionStart))"
                    + " - \(LocalAudioCoordinates.formatTimestamp(samples: lastEnd))]\n\n"
                    + body
            )
            lastRenderedEnd = max(lastRenderedEnd, lastEnd)
        }

        guard hasSpeech else {
            throw LocalMergeError.noSpeechContent
        }
        return LocalMergedTranscript(
            text: sections.joined(separator: "\n\n"),
            containsGaps: gapSamples > 0,
            gapSampleCount: gapSamples,
            lastRenderedEndSample: lastRenderedEnd
        )
    }

    /// Flatten every root's effective leaves into one ordered, coverage-checked list.
    public static func collectLeaves(
        from states: [LocalRootState],
        manifest: LocalCheckpointManifest,
        silence: VerifiedLocalSilence? = nil
    ) throws -> [LocalMergedLeaf] {
        guard states.count == manifest.roots.count else {
            throw LocalMergeError.coverageFailure(
                reason: "root state 數量 \(states.count) 與 manifest 的 \(manifest.roots.count) 不符。"
            )
        }
        var leaves: [LocalMergedLeaf] = []
        for (plan, state) in zip(manifest.roots, states) {
            let outcome = try LocalCheckpointValidator.validate(
                rootState: state,
                plan: plan,
                manifest: manifest,
                silence: silence
            )
            guard outcome != .incomplete else {
                throw LocalMergeError.coverageFailure(
                    reason: "root \(plan.rootID) 尚未完成。"
                )
            }
            for leaf in LocalCheckpointValidator.effectiveLeaves(in: state)
            where leaf.state.contributesCoverage {
                leaves.append(
                    LocalMergedLeaf(
                        nodeID: leaf.nodeID,
                        startSample: leaf.startSample,
                        endSample: leaf.endSample,
                        state: leaf.state,
                        text: leaf.result?.text ?? ""
                    )
                )
            }
        }
        // Coverage across roots is the merger's own check, not the per-root one.
        try leaves
            .sorted { $0.startSample < $1.startSample }
            .map(\.span)
            .validatedTiling(of: manifest.workSpan)
        return leaves.sorted { $0.startSample < $1.startSample }
    }
}
