import Foundation

public struct GeminiSafetyRating: Equatable, Sendable {
    public let category: String
    public let probability: String?
    public let blocked: Bool?

    public init(category: String, probability: String? = nil, blocked: Bool? = nil) {
        self.category = category
        self.probability = probability
        self.blocked = blocked
    }

    public var compactDescription: String {
        var parts = [category]
        if let probability, !probability.isEmpty {
            parts.append(probability)
        }
        if let blocked {
            parts.append(blocked ? "blocked=true" : "blocked=false")
        }
        return parts.joined(separator: ":")
    }
}

public struct GeminiPromptBlockDiagnostics: Equatable, Sendable {
    public let httpStatusCode: Int
    public let blockReason: String
    public let blockReasonMessage: String?
    public let safetyRatings: [GeminiSafetyRating]
    public let modelVersion: String?
    public let responseID: String?
    public let promptTokenCount: Int?
    public let audioTokenCount: Int?

    public init(
        httpStatusCode: Int,
        blockReason: String,
        blockReasonMessage: String? = nil,
        safetyRatings: [GeminiSafetyRating] = [],
        modelVersion: String? = nil,
        responseID: String? = nil,
        promptTokenCount: Int? = nil,
        audioTokenCount: Int? = nil
    ) {
        self.httpStatusCode = httpStatusCode
        self.blockReason = blockReason
        self.blockReasonMessage = blockReasonMessage
        self.safetyRatings = safetyRatings
        self.modelVersion = modelVersion
        self.responseID = responseID
        self.promptTokenCount = promptTokenCount
        self.audioTokenCount = audioTokenCount
    }

    public var normalizedBlockReason: String {
        blockReason.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public var isExplicitSafetyPolicy: Bool {
        [
            "SAFETY",
            "PROHIBITED_CONTENT",
            "BLOCKLIST",
            "IMAGE_SAFETY",
            "SPII",
            "MODEL_ARMOR"
        ].contains(normalizedBlockReason)
    }

    public var userFacingMessage: String {
        let extra = blockReasonMessage
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if isExplicitSafetyPolicy {
            let suffix = extra.map { "：\($0)" } ?? ""
            return "Google 內容安全政策攔截：\(blockReason)\(suffix)"
        }
        let unknownDetail = extra.map { "：\($0)" } ?? "（Google 未提供具體原因）"
        return "Google 已接受請求（HTTP \(httpStatusCode)），但未產生逐字稿：promptFeedback.blockReason=\(blockReason)\(unknownDetail)"
    }

    public var logSummary: String {
        let ratings = safetyRatings.isEmpty
            ? "-"
            : safetyRatings.map(\.compactDescription).joined(separator: ",")
        return [
            "Gemini promptFeedback 攔截：blockReason=\(blockReason)",
            "HTTP \(httpStatusCode)",
            "responseId=\(responseID ?? "-")",
            "modelVersion=\(modelVersion ?? "-")",
            "promptTokenCount=\(promptTokenCount.map(String.init) ?? "-")",
            "audioTokenCount=\(audioTokenCount.map(String.init) ?? "-")",
            "safetyRatings=\(ratings)"
        ].joined(separator: "；")
    }
}

public enum GeminiTranscriptFinishReason {
    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func isSafetyBlock(_ raw: String) -> Bool {
        [
            "SAFETY",
            "PROHIBITED_CONTENT",
            "BLOCKLIST",
            "SPII",
            "RECITATION"
        ].contains(normalized(raw))
    }

    public static func isTruncated(_ raw: String) -> Bool {
        normalized(raw) == "MAX_TOKENS"
    }

    public static func allowsUsableText(_ raw: String) -> Bool {
        normalized(raw) == "STOP"
    }
}

public enum GeminiPromptFeedbackParser {
    public static func diagnosticsIfBlocked(
        from json: [String: Any],
        httpStatusCode: Int
    ) -> GeminiPromptBlockDiagnostics? {
        guard let promptFeedback = json["promptFeedback"] as? [String: Any],
              let blockReason = blockReasonString(from: promptFeedback)
        else {
            return nil
        }
        let trimmed = blockReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.uppercased() != "BLOCK_REASON_UNSPECIFIED"
        else {
            return nil
        }

        let message = promptFeedback["blockReasonMessage"] as? String
        let ratings = parseSafetyRatings(promptFeedback["safetyRatings"])
        let usage = json["usageMetadata"] as? [String: Any]
        return GeminiPromptBlockDiagnostics(
            httpStatusCode: httpStatusCode,
            blockReason: trimmed,
            blockReasonMessage: message,
            safetyRatings: ratings,
            modelVersion: json["modelVersion"] as? String,
            responseID: json["responseId"] as? String,
            promptTokenCount: integer(usage?["promptTokenCount"]),
            audioTokenCount: audioTokenCount(from: usage)
        )
    }

    public static func blockReasonString(from promptFeedback: [String: Any]) -> String? {
        if let value = promptFeedback["blockReason"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let number = promptFeedback["blockReason"] as? NSNumber else {
            return nil
        }
        switch number.intValue {
        case 0:
            return "BLOCK_REASON_UNSPECIFIED"
        case 1:
            return "SAFETY"
        case 2:
            return "OTHER"
        case 3:
            return "BLOCKLIST"
        case 4:
            return "PROHIBITED_CONTENT"
        case 5:
            return "IMAGE_SAFETY"
        default:
            return "UNMAPPED_\(number.intValue)"
        }
    }

    public static func audioTokenCount(from usage: [String: Any]?) -> Int? {
        guard let usage else {
            return nil
        }
        let detailKeys = ["promptTokensDetails", "promptTokenDetails"]
        for key in detailKeys {
            guard let details = usage[key] as? [[String: Any]] else {
                continue
            }
            for detail in details {
                let modality = (detail["modality"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                if modality == "AUDIO" {
                    return integer(detail["tokenCount"])
                }
            }
        }
        return nil
    }

    private static func parseSafetyRatings(_ raw: Any?) -> [GeminiSafetyRating] {
        guard let items = raw as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let category = item["category"] as? String,
                  !category.isEmpty
            else {
                return nil
            }
            let blocked: Bool?
            if let value = item["blocked"] as? Bool {
                blocked = value
            } else {
                blocked = nil
            }
            return GeminiSafetyRating(
                category: category,
                probability: item["probability"] as? String,
                blocked: blocked
            )
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }
}

public enum GeminiResponseInventory {
    public static func summary(
        from json: [String: Any],
        reason: String,
        rawByteCount: Int? = nil
    ) -> String {
        let keys = json.keys.sorted().joined(separator: ",")
        let promptFeedback = json["promptFeedback"] as? [String: Any]
        let feedbackKeys = promptFeedback.map {
            $0.keys.sorted().joined(separator: ",")
        } ?? "-"
        let blockReason = promptFeedback.flatMap {
            GeminiPromptFeedbackParser.blockReasonString(from: $0)
        } ?? "-"
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let usage = json["usageMetadata"] as? [String: Any]
        let candidateShape = candidates.first.map(describeCandidate) ?? "-"
        return [
            "Gemini 回應無法形成逐字稿：\(reason)",
            "rawBytes=\(rawByteCount.map(String.init) ?? "-")",
            "keys=\(keys.isEmpty ? "-" : keys)",
            "promptFeedback.keys=\(feedbackKeys)",
            "blockReason=\(blockReason)",
            "candidateCount=\(candidates.count)",
            "firstCandidate=\(candidateShape)",
            "responseId=\(json["responseId"] as? String ?? "-")",
            "modelVersion=\(json["modelVersion"] as? String ?? "-")",
            "promptTokenCount=\(stringify(usage?["promptTokenCount"]))",
            "candidatesTokenCount=\(stringify(usage?["candidatesTokenCount"]))",
            "thoughtsTokenCount=\(stringify(usage?["thoughtsTokenCount"]))",
            "audioTokenCount=\(GeminiPromptFeedbackParser.audioTokenCount(from: usage).map(String.init) ?? "-")"
        ].joined(separator: "；")
    }

    private static func describeCandidate(_ candidate: [String: Any]) -> String {
        let finish = candidate["finishReason"] as? String ?? "-"
        let content = candidate["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        let partShapes = parts.map(describePart).joined(separator: "|")
        return "finishReason=\(finish),parts=\(parts.count)[\(partShapes)]"
    }

    private static func describePart(_ part: [String: Any]) -> String {
        var flags: [String] = part.keys.sorted()
        if let thought = part["thought"] as? Bool {
            flags.append(thought ? "thought=true" : "thought=false")
        }
        if let text = part["text"] as? String {
            flags.append("textChars=\(text.count)")
        }
        return flags.joined(separator: ",")
    }

    private static func stringify(_ value: Any?) -> String {
        if let number = value as? NSNumber {
            return String(number.intValue)
        }
        if let value {
            return String(describing: value)
        }
        return "-"
    }
}
