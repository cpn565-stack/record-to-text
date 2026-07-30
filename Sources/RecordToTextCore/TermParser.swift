import Foundation

public enum TermParser {
    private static let separators = CharacterSet(charactersIn: ",，、;；\n\r")

    public static func parse(_ input: String) -> [String] {
        let parts = input.components(separatedBy: separators)
        return deduplicate(parts)
    }

    public static func merge(_ groups: [[String]]) -> [String] {
        deduplicate(groups.flatMap { $0 })
    }

    private static func deduplicate(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                continue
            }
            result.append(trimmed)
        }

        return result
    }
}

public struct PromptBuildResult: Equatable, Sendable {
    public let terms: [String]
    public let prompt: String

    public init(terms: [String], prompt: String) {
        self.terms = terms
        self.prompt = prompt
    }
}

public enum PromptBuilderError: LocalizedError, Equatable {
    case tooManyTerms(actual: Int, maximum: Int)
    case tooManyCharacters(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .tooManyTerms(actual, maximum):
            return "目前有 \(actual) 個詞彙，最多可使用 \(maximum) 個。"
        case let .tooManyCharacters(actual, maximum):
            return "詞彙共有 \(actual) 個 Unicode 字元，最多可使用 \(maximum) 個。"
        }
    }
}

public enum PromptBuilder {
    public static let maximumTerms = 500
    public static let maximumUnicodeScalars = 8_000

    private static let fidelityInstruction =
        "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。"

    public static func build(
        commonTerms: [String],
        glossaryTerms: [String],
        temporaryTerms: [String]
    ) throws -> PromptBuildResult {
        let terms = TermParser.merge([commonTerms, glossaryTerms, temporaryTerms])
        guard terms.count <= maximumTerms else {
            throw PromptBuilderError.tooManyTerms(
                actual: terms.count,
                maximum: maximumTerms
            )
        }

        let scalarCount = terms.reduce(0) { $0 + $1.unicodeScalars.count }
        guard scalarCount <= maximumUnicodeScalars else {
            throw PromptBuilderError.tooManyCharacters(
                actual: scalarCount,
                maximum: maximumUnicodeScalars
            )
        }

        guard !terms.isEmpty else {
            return PromptBuildResult(terms: [], prompt: fidelityInstruction)
        }

        let prompt = """
        \(fidelityInstruction)
        以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：

        \(terms.joined(separator: "\n"))
        """

        return PromptBuildResult(terms: terms, prompt: prompt)
    }
}
