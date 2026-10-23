import Foundation

/// Backend errors retain their public types and user-facing messages while
/// sharing the rules for accepting a complete Gemini transcript.
protocol GeminiResponseError: Error {
    static var invalidJSONResponse: Self { get }
    static var emptyResponse: Self { get }
    static func emptyTranscript(finishReason: String) -> Self
    static func promptBlocked(_ diagnostics: GeminiPromptBlockDiagnostics) -> Self
    static func prohibitedContent(_ message: String) -> Self
    static func incompleteResponse(finishReason: String, message: String?) -> Self
}

extension GoogleAIStudioError: GeminiResponseError {
    static func emptyTranscript(finishReason: String) -> Self { .emptyResponse }
}

extension VertexAIError: GeminiResponseError {
    static func emptyTranscript(finishReason: String) -> Self {
        finishReason == "STOP" ? .emptyCompletedResponse : .emptyResponse
    }
}

enum GeminiResponseParser {
    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func transcript<Failure: GeminiResponseError>(
        from data: Data,
        errors: Failure.Type,
        httpStatusCode: Int,
        collapseBlankLines: Bool = false,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidJSONResponse
        }
        return try transcript(
            fromJSON: json,
            rawByteCount: data.count,
            errors: errors,
            httpStatusCode: httpStatusCode,
            collapseBlankLines: collapseBlankLines,
            logger: logger
        )
    }

    static func transcript<Failure: GeminiResponseError>(
        fromJSON json: [String: Any],
        rawByteCount: Int,
        errors: Failure.Type,
        httpStatusCode: Int,
        collapseBlankLines: Bool = false,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) throws -> String {
        func warn(_ reason: String) {
            logger?("warning", GeminiResponseInventory.summary(
                from: json, reason: reason, rawByteCount: rawByteCount))
        }
        if let diagnostics = GeminiPromptFeedbackParser.diagnosticsIfBlocked(
            from: json, httpStatusCode: httpStatusCode
        ) {
            logger?("warning", diagnostics.logSummary)
            throw Failure.promptBlocked(diagnostics)
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            warn("no_candidates")
            throw Failure.emptyResponse
        }
        let finishMessage = candidate["finishMessage"] as? String
        guard let finishReason = candidate["finishReason"] as? String,
              !finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            warn("missing_finish_reason")
            throw Failure.incompleteResponse(finishReason: "MISSING_FINISH_REASON", message: finishMessage)
        }
        let reason = GeminiTranscriptFinishReason.normalized(finishReason)
        if GeminiTranscriptFinishReason.isSafetyBlock(reason) {
            throw Failure.prohibitedContent(finishMessage ?? reason)
        }
        let truncated = GeminiTranscriptFinishReason.isTruncated(reason)
        guard truncated || GeminiTranscriptFinishReason.allowsUsableText(reason) else {
            warn(reason)
            throw Failure.incompleteResponse(finishReason: reason, message: finishMessage)
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        if !truncated, parts == nil {
            warn("missing_candidate_parts")
            throw Failure.emptyTranscript(finishReason: reason)
        }
        let text = (parts ?? []).compactMap { part -> String? in
            part["thought"] as? Bool == true ? nil : part["text"] as? String
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = sanitize(text, collapseBlankLines: collapseBlankLines)
        if truncated {
            warn("MAX_TOKENS")
            throw CloudOutputTruncatedError(partialText: sanitized, finishMessage: finishMessage)
        }
        guard !sanitized.isEmpty else {
            warn("empty_transcript_text")
            throw Failure.emptyTranscript(finishReason: reason)
        }
        return sanitized
    }

    private static func sanitize(_ rawText: String, collapseBlankLines: Bool) -> String {
        var text = rawText
        if let range = text.range(of: "## 📝 完整整理逐字稿") {
            text = String(text[range.upperBound...])
        } else if let range = text.range(of: "## 完整整理逐字稿") {
            text = String(text[range.upperBound...])
        }
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*#{1,6}[ \t]*(\[\d{2}:\d{2})"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*#{1,6}[ \t]*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*---[ \t]*$"#, with: "", options: .regularExpression)
        if collapseBlankLines {
            text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
