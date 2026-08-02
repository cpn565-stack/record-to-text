import Foundation

public enum OutputContractValidationError: LocalizedError, Equatable {
    case utf8BOM(String)
    case nulByte(String)
    case promptEcho(String)

    public var errorDescription: String? {
        switch self {
        case let .utf8BOM(path):
            return "文字輸出含有不應存在的 UTF-8 BOM：\(path)"
        case let .nulByte(path):
            return "文字輸出含有 NUL 控制字元：\(path)"
        case let .promptEcho(path):
            return "文字輸出開頭或末尾疑似回吐了送入模型的 Prompt／詞庫：\(path)"
        }
    }
}

public enum OutputContractValidator {
    @discardableResult
    public static func readTranscript(
        at url: URL,
        prompt: String? = nil
    ) throws -> String {
        let text = try TextFileValidator.readNonEmptyUTF8(at: url)
        return try validate(text: text, path: url.path, prompt: prompt)
    }

    @discardableResult
    public static func validate(
        text: String,
        path: String,
        prompt: String? = nil
    ) throws -> String {
        guard text.first != "\u{FEFF}" else {
            throw OutputContractValidationError.utf8BOM(path)
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OutputContractValidationError.nulByte(path)
        }
        if let prompt, hasPromptEcho(text: text, prompt: prompt) {
            throw OutputContractValidationError.promptEcho(path)
        }
        return text
    }

    private static func hasPromptEcho(text: String, prompt: String) -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return false
        }

        let promptLines = trimmedPrompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !promptLines.isEmpty else {
            return false
        }

        var candidates = [trimmedPrompt]
        if promptLines.count > 1 {
            for lineCount in stride(from: promptLines.count - 1, through: 1, by: -1) {
                let candidate = promptLines.prefix(lineCount).joined(separator: " ")
                if candidate.count >= 40 {
                    candidates.append(candidate)
                }
            }
        }

        let normalizedText = removingWhitespace(from: text)
        if candidates.enumerated().contains(where: { index, candidate in
            let normalizedCandidate = removingWhitespace(from: candidate)
            let minimumLength = index == 0 ? 1 : 40
            return normalizedCandidate.count >= minimumLength
                && (
                    normalizedText.hasPrefix(normalizedCandidate)
                        || normalizedText.hasSuffix(normalizedCandidate)
                )
        }) {
            return true
        }

        let glossaryTerms = linesAfterGlossaryMarker(in: promptLines)
        guard glossaryTerms.count >= 2 else {
            return false
        }
        return hasLeadingGlossaryEcho(text: text, terms: glossaryTerms)
    }

    private static func linesAfterGlossaryMarker(in lines: [String]) -> [String] {
        guard let markerIndex = lines.firstIndex(where: {
            $0.contains("以下詞彙可能出現在錄音中")
        }) else {
            return []
        }

        return lines.dropFirst(markerIndex + 1)
            .filter { !$0.isEmpty }
            .flatMap(splitImplicitCJKTerms)
    }

    private static func splitImplicitCJKTerms(_ value: String) -> [String] {
        let pieces = value.split { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
        }
        guard pieces.count >= 2,
              pieces.allSatisfy({ piece in
                  piece.unicodeScalars.allSatisfy(isCJKScalar)
              })
        else {
            return [value]
        }
        return pieces.map(String.init)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func hasLeadingGlossaryEcho(
        text: String,
        terms: [String]
    ) -> Bool {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var consumedSeparatorAfterTerm = false

        for term in terms {
            while let first = remainder.first,
                  isGlossarySeparator(first)
            {
                remainder.removeFirst()
                consumedSeparatorAfterTerm = true
            }
            guard remainder.hasPrefix(term) else {
                return false
            }
            remainder.removeFirst(term.count)
            consumedSeparatorAfterTerm = false
        }

        while let first = remainder.first,
              isGlossarySeparator(first)
        {
            remainder.removeFirst()
            consumedSeparatorAfterTerm = true
        }

        return remainder.isEmpty || consumedSeparatorAfterTerm
    }

    private static func removingWhitespace(from value: String) -> String {
        String(
            value.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
        )
    }

    private static func isGlossarySeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || "。．.!！?？；;,:：,，、|/".unicodeScalars.contains(scalar)
        }
    }
}
