import Foundation

/// Vertex GenerateContent request/response shape for the dedicated audio-only
/// model. Do not send the prompts and thinking settings used by Gemini Flash.
enum VertexTranscribeRequest {
    static let modelID = "gemini-3.5-transcribe"

    static func matches(modelID: String) -> Bool {
        modelID == Self.modelID
    }

    static func body(inputPart: [String: Any], terms: [String]) throws -> [String: Any] {
        let vocabulary = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard vocabulary.count <= 1_000 else {
            throw VertexAIError.vocabularyTooLarge(count: vocabulary.count)
        }
        var transcription: [String: Any] = ["mode": "VERBATIM"]
        // Google's current Developer API docs reject vocabulary combined with
        // diarization. Vertex docs conflict, so use the compatible subset.
        if vocabulary.isEmpty {
            transcription["diarization"] = true
        } else {
            transcription["customVocabulary"] = vocabulary
        }
        return [
            "contents": [["role": "user", "parts": [inputPart]]],
            "generationConfig": ["audioTranscriptionConfig": transcription]
        ]
    }

    static func transcript(
        from data: Data,
        segmentStartSeconds: Double,
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) throws -> String {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VertexAIError.invalidJSONResponse
        }
        if var candidates = json["candidates"] as? [[String: Any]], !candidates.isEmpty,
           var content = candidates[0]["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            if parts.contains(where: { $0["audioTranscription"] is [String: Any] }) {
                let segment = TranscriptTimestampValidator.timestamp(
                    segmentStartSeconds.isFinite && segmentStartSeconds < Double(Int.max / 2)
                        ? max(segmentStartSeconds, 0) : 0)
                content["parts"] = parts.map { part -> [String: Any] in
                    guard part["thought"] as? Bool != true,
                          let audio = part["audioTranscription"] as? [String: Any] else { return part }
                    // A provider part may expose the spoken text in either
                    // field, with audioTranscription carrying only metadata.
                    // Treat them as alternate representations of the same
                    // turn, rather than discarding or duplicating part.text.
                    let partText = part["text"] as? String ?? ""
                    let audioText = audio["text"] as? String ?? ""
                    let rawText = partText.isEmpty ? audioText : partText
                    let wordsText = textFromWords(audio["words"] as? [[String: Any]] ?? [])
                    // An independent part may repeat a prior spoken phrase.
                    // Text similarity cannot distinguish this from duplicated
                    // annotations, so never silently drop it.
                    let text = !rawText.isEmpty ? rawText : wordsText
                    if rawText.isEmpty && !wordsText.isEmpty {
                        logger?("warning", "轉錄回應包含僅有逐字資料的片段；已完整保留，請核對是否有重複。")
                    }
                    let label = audio["speakerLabel"] as? String ?? ""
                    // Speaker IDs are local to each model request. Make that
                    // scope visible instead of suggesting cross-segment identity.
                    let safeLabel = label.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
                        ? label : ""
                    if !safeLabel.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return ["text": "\n\n[片段 \(segment)・\(safeLabel)]\n\(text)"]
                    }
                    return ["text": text]
                }
                candidates[0]["content"] = content
                json["candidates"] = candidates
            }
        }
        // Reuse the established STOP / MAX_TOKENS / safety checks. In
        // particular, never treat a blocked or truncated transcript as complete.
        return try GeminiResponseParser.transcript(
            fromJSON: json, rawByteCount: data.count, errors: VertexAIError.self,
            httpStatusCode: 200, collapseBlankLines: true, logger: logger)
    }

    private static func textFromWords(_ words: [[String: Any]]) -> String {
        words.compactMap { $0["word"] as? String }.reduce(into: "") { result, word in
            // Some responses provide only word annotations. Insert spaces
            // between Latin words, but do not split Chinese characters.
            if let previous = result.unicodeScalars.last, let next = word.unicodeScalars.first,
               previous.isASCII, next.isASCII,
               CharacterSet.alphanumerics.contains(previous), CharacterSet.alphanumerics.contains(next) {
                result += " "
            }
            result += word
        }
    }
}
