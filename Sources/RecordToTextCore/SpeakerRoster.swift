import Foundation

public enum SpeakerIdentityConfidence: String, Codable, Equatable, Sendable {
    case explicit
    case inferred
    case generic
}

public struct SpeakerIdentity: Codable, Equatable, Sendable {
    public var canonicalLabel: String
    public var aliases: [String]
    public let firstSeenSegment: Int
    public var confidence: SpeakerIdentityConfidence

    public init(
        canonicalLabel: String,
        aliases: [String] = [],
        firstSeenSegment: Int,
        confidence: SpeakerIdentityConfidence
    ) {
        self.canonicalLabel = canonicalLabel
        self.aliases = Array(
            Set(aliases.map(Self.normalizedLabel).filter { !$0.isEmpty })
        ).sorted()
        self.firstSeenSegment = firstSeenSegment
        self.confidence = confidence
    }

    mutating func addAlias(_ label: String) {
        let normalized = Self.normalizedLabel(label)
        guard !normalized.isEmpty, normalized != canonicalLabel else {
            return
        }
        if !aliases.contains(normalized) {
            aliases.append(normalized)
            aliases.sort()
        }
    }

    static func normalizedLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
    }
}

/// Labels are contextual hints, not evidence of cross-segment voice identity.
/// Never infer a person's name from their utterance or rewrite model output.
public struct SpeakerRoster: Codable, Equatable, Sendable {
    public var identities: [SpeakerIdentity]

    public init(identities: [SpeakerIdentity] = []) {
        self.identities = identities
    }

    public var isEmpty: Bool { identities.isEmpty }

    public var promptInstruction: String? {
        let labels = identities.map(\.canonicalLabel).filter { !Self.isGenericLabel($0) }
        guard !labels.isEmpty else { return nil }
        return """
        【前段講者標籤參考】
        前段出現過以下標籤，僅供參考，並非已核實的聲音身分：
        \(labels.map { "- \($0)" }.joined(separator: "\n"))

        只有本段音訊能支持相同身分時才沿用姓名；有歧義或矛盾時保留不確定性。
        「講者 1／2」、主持人等泛稱只適用各自片段，編號相同不代表同一人。不得從「我是負責…」等普通句子猜姓名。
        """
    }

    public mutating func observe(
        transcript: String,
        segmentIndex: Int,
        knownTerms: [String] = []
    ) {
        for line in transcript.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(where: { $0 == "：" || $0 == ":" }) else { continue }
            let label = SpeakerIdentity.normalizedLabel(String(line[..<separator]))
            guard !label.isEmpty, label.count <= 24, !label.hasPrefix("["),
                  !label.contains("http"), !Self.isGenericLabel(label),
                  !identities.contains(where: { $0.canonicalLabel == label }) else { continue }
            identities.append(SpeakerIdentity(canonicalLabel: label,
                firstSeenSegment: segmentIndex, confidence: .inferred))
        }
    }

    // Retained for callers decoding older checkpoints. Legacy heuristic aliases
    // (including those marked explicit) are never sufficient to rewrite text.
    public func normalizingSpeakerLabels(in transcript: String) -> String {
        transcript
    }

    private static func isGenericLabel(_ label: String) -> Bool {
        let compact = label.replacingOccurrences(of: " ", with: "").lowercased()
        return compact.hasPrefix("講者") || compact.hasPrefix("speaker")
            || compact.hasPrefix("學員") || compact == "主持人" || compact == "來賓"
    }
}
