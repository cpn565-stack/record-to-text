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

public struct SpeakerRoster: Codable, Equatable, Sendable {
    public var identities: [SpeakerIdentity]

    public init(identities: [SpeakerIdentity] = []) {
        self.identities = identities
    }

    public var isEmpty: Bool { identities.isEmpty }

    public var promptInstruction: String? {
        guard !identities.isEmpty else {
            return nil
        }
        let rows = identities.map { identity in
            let aliases = identity.aliases.isEmpty
                ? ""
                : "（曾出現：\(identity.aliases.joined(separator: "、"))）"
            return "- \(identity.canonicalLabel)\(aliases)"
        }
        return """
        【跨段講者名稱鎖定】
        先前片段已確認以下講者標籤：
        \(rows.joined(separator: "\n"))

        後續片段若是同一位講者，行首必須使用上列 canonical label；即使音訊稱呼簡稱、暱稱或同音字，也不要改名或重新編成「講者 1／2」。只有確定出現新聲音時才能新增講者。
        """
    }

    public mutating func observe(
        transcript: String,
        segmentIndex: Int,
        knownTerms: [String] = []
    ) {
        for turn in Self.speakerTurns(in: transcript) {
            let rawLabel = SpeakerIdentity.normalizedLabel(turn.label)
            guard !rawLabel.isEmpty else {
                continue
            }
            if let index = matchingIdentityIndex(for: rawLabel) {
                identities[index].addAlias(rawLabel)
                continue
            }

            let knownName = Self.knownName(
                matching: rawLabel,
                content: turn.content,
                terms: knownTerms
            )
            let introducedName = Self.selfIntroducedName(
                in: turn.content,
                label: rawLabel
            )
            let canonical = knownName ?? introducedName ?? rawLabel
            let confidence: SpeakerIdentityConfidence
            if knownName != nil || introducedName != nil {
                confidence = .explicit
            } else if Self.isGenericLabel(rawLabel) {
                confidence = .generic
            } else {
                confidence = .inferred
            }
            var identity = SpeakerIdentity(
                canonicalLabel: canonical,
                firstSeenSegment: segmentIndex,
                confidence: confidence
            )
            identity.addAlias(rawLabel)
            identities.append(identity)
        }
    }

    public func normalizingSpeakerLabels(in transcript: String) -> String {
        transcript.components(separatedBy: .newlines).map { line in
            guard let turn = Self.speakerTurn(from: line),
                  let index = matchingIdentityIndex(for: turn.label)
            else {
                return line
            }
            return "\(identities[index].canonicalLabel)：\(turn.content)"
        }.joined(separator: "\n")
    }

    private func matchingIdentityIndex(for rawLabel: String) -> Int? {
        let label = SpeakerIdentity.normalizedLabel(rawLabel)
        if let exact = identities.firstIndex(where: { identity in
            identity.canonicalLabel == label || identity.aliases.contains(label)
        }) {
            return exact
        }
        if let suffix = identities.firstIndex(where: { identity in
            identity.canonicalLabel.hasSuffix(label)
                || identity.aliases.contains(where: { $0.hasSuffix(label) })
        }) {
            return suffix
        }

        guard Self.isTitledLabel(label) else {
            return nil
        }
        let approximate = identities.indices.filter { index in
            let identity = identities[index]
            return ([identity.canonicalLabel] + identity.aliases).contains {
                Self.editDistance($0, label) <= 1
            }
        }
        return approximate.count == 1 ? approximate[0] : nil
    }

    private struct SpeakerTurn {
        let label: String
        let content: String
    }

    private static func speakerTurns(in transcript: String) -> [SpeakerTurn] {
        transcript.components(separatedBy: .newlines).compactMap(speakerTurn)
    }

    private static func speakerTurn(from line: String) -> SpeakerTurn? {
        let separators = ["：", ":"]
        guard let separator = separators.compactMap({ line.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else {
            return nil
        }
        let label = String(line[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              label.count <= 24,
              !label.hasPrefix("["),
              !label.contains("http")
        else {
            return nil
        }
        return SpeakerTurn(
            label: label,
            content: String(line[separator.upperBound...])
        )
    }

    private static func knownName(
        matching label: String,
        content: String,
        terms: [String]
    ) -> String? {
        let candidates = terms.map(SpeakerIdentity.normalizedLabel).filter {
            (2...12).contains($0.count)
                && !$0.contains(where: { $0.isWhitespace })
        }
        if let exact = candidates.first(where: { $0 == label }) {
            return exact
        }
        if let introduced = candidates.first(where: {
            content.contains("我是\($0)") || content.contains("我叫\($0)")
        }) {
            return introduced
        }
        let stem = titleStem(label)
        guard !stem.isEmpty else {
            return candidates.first(where: { $0.hasSuffix(label) })
        }
        let sameStem = candidates.filter { $0.hasPrefix(stem) }
        return sameStem.count == 1 ? sameStem[0] : nil
    }

    private static func selfIntroducedName(
        in content: String,
        label: String
    ) -> String? {
        for marker in ["我是", "我叫"] {
            guard let range = content.range(of: marker) else {
                continue
            }
            let tail = content[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let token = String(tail.prefix { character in
                character.isLetter || character == "·" || character == "・"
            })
            guard token.count >= 2 else {
                continue
            }
            if token.hasPrefix(label), !isTitledLabel(label) {
                return label
            }
            let stem = titleStem(label)
            if !stem.isEmpty,
               token.hasPrefix(stem),
               let repeatedStem = token.dropFirst().firstIndex(of: stem.first!)
            {
                let candidate = String(token[..<repeatedStem])
                if (2...4).contains(candidate.count) {
                    return candidate
                }
            }
            if (2...4).contains(token.count) {
                return token
            }
            if token.count > 4 {
                return String(token.prefix(3))
            }
        }
        return nil
    }

    private static func isGenericLabel(_ label: String) -> Bool {
        let compact = label.replacingOccurrences(of: " ", with: "")
        return compact.hasPrefix("講者")
            || compact.hasPrefix("Speaker")
            || compact.hasPrefix("學員")
            || compact == "主持人"
            || compact == "來賓"
    }

    private static func isTitledLabel(_ label: String) -> Bool {
        ["哥", "姐", "老師", "先生", "小姐", "總", "董"].contains {
            label.hasSuffix($0)
        }
    }

    private static func titleStem(_ label: String) -> String {
        for suffix in ["老師", "先生", "小姐", "哥", "姐", "總", "董"]
        where label.hasSuffix(suffix) {
            return String(label.dropLast(suffix.count))
        }
        return ""
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex]
                            + (leftCharacter == rightCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous.last ?? 0
    }
}
