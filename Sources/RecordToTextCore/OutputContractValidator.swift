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
            return "文字輸出末尾疑似回吐了送入模型的 Prompt：\(path)"
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
        return candidates.contains { candidate in
            let normalizedCandidate = removingWhitespace(from: candidate)
            return normalizedCandidate.count >= 40
                && normalizedText.hasSuffix(normalizedCandidate)
        }
    }

    private static func removingWhitespace(from value: String) -> String {
        String(
            value.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
        )
    }
}
