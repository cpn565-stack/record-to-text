import Foundation
import CryptoKit

public enum GoogleAIStudioError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey(String)
    case requestFailed(statusCode: Int, message: String)
    case rateLimited(message: String, retryAfterSeconds: Double?)
    case quotaExceeded(String)
    case prohibitedContent(String)
    case promptBlocked(GeminiPromptBlockDiagnostics)
    case incompleteResponse(finishReason: String, message: String?)
    case emptyResponse
    case emptyCompletedResponse
    case invalidJSONResponse
    case invalidAudioReference
    case audioPayloadTooLarge(sizeBytes: Int, limitBytes: Int)
    case transportMessageTooLarge
    case fileUploadFailed(String)
    case filesAPIUnsupported
    case fileProcessingTimedOut
    case tooManyVocabularyTerms(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未設定 Google AI Studio API Key。請至設定頁面填入 API Key。"
        case .invalidAPIKey:
            return "Google AI Studio API Key 無效，請檢查設定與使用權限。"
        case let .requestFailed(statusCode, _):
            return "Google AI Studio 請求失敗（HTTP \(statusCode)）。"
        case let .rateLimited(_, retryAfterSeconds):
            let delay = retryAfterSeconds.map { "，建議至少等待 \(String(format: "%.1f", $0)) 秒" } ?? ""
            return "Google AI Studio 暫時達到速率限制\(delay)。"
        case .quotaExceeded:
            return "Google AI Studio 當日配額已用完，短時間重試不會成功。"
        case .prohibitedContent:
            return "Google 內容安全政策攔截。"
        case let .promptBlocked(diagnostics):
            return diagnostics.userFacingMessage
        case let .incompleteResponse(finishReason, _):
            let code = GeminiDiagnosticCode.sanitized(finishReason) ?? "UNKNOWN"
            return "Google AI Studio 回應未正常完成（\(code)）。為避免輸出不完整逐字稿，本次工作已停止。"
        case .emptyResponse:
            return "Google AI Studio 未回傳任何文字內容或候選結果。"
        case .emptyCompletedResponse:
            return "Google 已結束本次生成，但沒有產生逐字稿文字。"
        case .invalidJSONResponse:
            return "Google AI Studio 回傳的資料無法解讀為有效 JSON。"
        case .invalidAudioReference:
            return "無法建立 Google AI Studio 轉錄請求：音訊資料缺少檔案位置或格式。"
        case let .audioPayloadTooLarge(sizeBytes, limitBytes):
            let sizeMB = Double(sizeBytes) / (1024 * 1024)
            let limitMB = Double(limitBytes) / (1024 * 1024)
            return "音檔過大（\(String(format: "%.1f", sizeMB)) MB），超過直接傳輸上限（\(String(format: "%.1f", limitMB)) MB）。"
        case .transportMessageTooLarge:
            return "連到 Google 的傳輸通道失敗（本機無法送出這包資料）。這不是音檔超過 Gemini 時長上限。請重試；若持續發生，需要改為先上傳音檔再轉錄。"
        case .fileUploadFailed:
            return "Google AI Studio 音訊上傳失敗。"
        case .filesAPIUnsupported:
            return "目前服務不支援 Files API。"
        case .fileProcessingTimedOut:
            return "Google AI Studio 檔案處理超時，請稍後重試。"
        case let .tooManyVocabularyTerms(count):
            return "此轉錄模型最多支援 1000 個詞庫項目；目前有 \(count) 個，請先縮減詞庫。"
        case .cancelled:
            return "轉錄程序已取消。"
        }
    }

    public var isExplicitSafetyPolicyBlock: Bool {
        switch self {
        case .prohibitedContent:
            return true
        case let .promptBlocked(diagnostics):
            return diagnostics.isExplicitSafetyPolicy
        default:
            return false
        }
    }
}

public final class GoogleAIStudioBackend: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var apiKey: String?
        public var modelID: String
        public var useFilesAPI: Bool
        public var thinkingLevel: GeminiThinkingLevel
        public var fallbackPolicy: CloudFallbackPolicy

        public init(
            apiKey: String? = nil,
            modelID: String = "gemini-3.7-flash",
            useFilesAPI: Bool = true,
            thinkingLevel: GeminiThinkingLevel? = nil,
            fallbackPolicy: CloudFallbackPolicy = .disabled
        ) {
            self.apiKey = apiKey
            self.modelID = modelID
            self.useFilesAPI = useFilesAPI
            self.thinkingLevel = GeminiGenerationConfig.resolvedThinkingLevel(
                thinkingLevel ?? GeminiGenerationConfig.defaultThinkingLevel(modelID: modelID), modelID: modelID)
            self.fallbackPolicy = fallbackPolicy
        }

        public static let `default` = Configuration()
    }

    private let urlSession: URLSession
    private let networkEnvironment: CloudNetworkEnvironment
    private let lock = NSLock()
    private var config: Configuration

    public static let maximumInlineAudioBytes: Int = 20 * 1024 * 1024 // 20 MB

    public init(
        networkEnvironment: CloudNetworkEnvironment = .init(),
        urlSession: URLSession = GeminiTransportHelper.makeEphemeralRetrySession(),
        configuration: Configuration = .default
    ) {
        self.urlSession = urlSession
        self.networkEnvironment = networkEnvironment
        self.config = configuration
    }

    public func updateConfiguration(_ newConfig: Configuration) {
        lock.withLock {
            config = newConfig
        }
    }

    public func getConfiguration() -> Configuration {
        lock.withLock { config }
    }

    /// 驗證 API Key 是否有效
    public func validateAPIKey(_ apiKey: String) async throws -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GoogleAIStudioError.missingAPIKey
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        guard let url = URL(string: urlString) else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": "Ping"]]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 5
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        if httpResponse.statusCode == 200 {
            return true
        }
        let errorMsg = GeminiResponseParser.errorMessage(from: data)
        switch httpResponse.statusCode {
        case 400, 401, 403:
            // These statuses are how Google reports a rejected key.
            throw GoogleAIStudioError.invalidAPIKey(errorMsg)
        default:
            // Outages and quota errors are not key problems; reporting them
            // as invalidAPIKey misleads the user into regenerating a good key.
            throw GoogleAIStudioError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMsg
            )
        }
    }

    /// Executes transcription while preserving model/version/token provenance.
    public func transcribeDetailed(
        audioData: Data,
        mimeType: String = "audio/mp3",
        terms: [String] = [],
        customPrompt: String = "",
        recordingContext: String = "",
        timeOffsetSeconds: Double = 0,
        workingDirectory: URL? = nil,
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) async throws -> CloudTranscriptionResult {
        if CloudNetworkContext.current == nil || CloudNetworkContext.segmentAttempts == nil {
            let budget = CloudBudgetContext.current ?? CloudSegmentBudget(
                limit: GeminiGenerationConfig.segmentBudget(modelID: getConfiguration().modelID),
                now: networkEnvironment.now)
            let context = CloudNetworkContext.current ?? CloudNetworkRecoveryContext(budget: budget, environment: networkEnvironment)
            return try await CloudBudgetContext.$current.withValue(budget) {
                try await CloudNetworkContext.$current.withValue(context) {
                    try await CloudNetworkContext.$segmentAttempts.withValue(CloudModelAttempts()) {
                        try await self.transcribeDetailed(audioData: audioData, mimeType: mimeType, terms: terms, customPrompt: customPrompt, recordingContext: recordingContext, timeOffsetSeconds: timeOffsetSeconds, workingDirectory: workingDirectory, logger: logger)
                    }
                }
            }
        }
        let customPrompt = try GeminiTranscriptPrompt.promptByPrependingRecordingContext(
            customPrompt, context: recordingContext, terms: terms)
        let logger = logger.map { destination in
            { (level: String, message: String) in
                destination(level, CloudRecordingContext.redactedDiagnostic(message, context: recordingContext))
            }
        }
        let currentConfig = getConfiguration()
        if currentConfig.modelID == "gemini-3.5-transcribe" {
            logger?("info", "此模型使用專用語音轉錄，無法套用自訂提示與錄音背景；詞庫與講者區分無法同時使用。")
            let vocabularyCount = terms.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            guard vocabularyCount <= 1000 else { throw GoogleAIStudioError.tooManyVocabularyTerms(vocabularyCount) }
        }

        guard let apiKey = currentConfig.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            throw GoogleAIStudioError.missingAPIKey
        }

        var preparedAudio = try await prepareAudioPart(
            apiKey: apiKey,
            audioData: audioData,
            mimeType: mimeType,
            useFilesAPI: currentConfig.useFilesAPI,
            workingDirectory: workingDirectory,
            logger: logger
        )

        var rebuilt = false
        while true {
            let result: CloudTranscriptionResult
            do {
                result = try await runTranscriptionAttempts(
                    preferredModelID: currentConfig.modelID,
                    preparedAudio: preparedAudio.audioPart,
                    apiKey: apiKey,
                    audioByteCount: audioData.count,
                    terms: terms,
                    customPrompt: customPrompt,
                    recordingContext: recordingContext,
                    timeOffsetSeconds: timeOffsetSeconds,
                    thinkingLevel: currentConfig.thinkingLevel,
                    fallbackPolicy: currentConfig.fallbackPolicy,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
            } catch {
                var failure = error
                let priorStage = CloudBudgetContext.current?.stage
                do {
                    if !rebuilt, case let .requestFailed(statusCode, _) = error as? GoogleAIStudioError,
                       [400, 403, 404, 410].contains(statusCode), let name = preparedAudio.uploadedFileName,
                       (CloudNetworkContext.segmentAttempts?.quota(for: currentConfig.modelID).count ?? 4) < 4,
                       try await remoteFileIsMissing(name: name, apiKey: apiKey) {
                        rebuilt = true
                        preparedAudio = try await prepareAudioPart(apiKey: apiKey, audioData: audioData,
                            mimeType: mimeType, useFilesAPI: true, workingDirectory: workingDirectory, logger: logger)
                        continue
                    }
                    if let priorStage { CloudBudgetContext.current?.restoreStage(priorStage) }
                } catch { failure = error }
                await deletePreparedRemoteFile(
                    preparedAudio,
                    apiKey: apiKey,
                    logger: logger
                )
                throw failure
            }
            await deletePreparedRemoteFile(
                preparedAudio,
                apiKey: apiKey,
                logger: logger
            )
            return result
        }
    }

    /// Backward-compatible text-only entry point used by existing callers.
    public func transcribe(
        audioData: Data,
        mimeType: String = "audio/mp3",
        terms: [String] = [],
        customPrompt: String = "",
        timeOffsetSeconds: Double = 0,
        workingDirectory: URL? = nil,
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) async throws -> String {
        try await transcribeDetailed(
            audioData: audioData,
            mimeType: mimeType,
            terms: terms,
            customPrompt: customPrompt,
            timeOffsetSeconds: timeOffsetSeconds,
            workingDirectory: workingDirectory,
            logger: logger
        ).text
    }

    private func runTranscriptionAttempts(
        preferredModelID: String,
        preparedAudio: [String: Any],
        apiKey: String,
        audioByteCount: Int,
        terms: [String],
        customPrompt: String,
        recordingContext: String,
        timeOffsetSeconds: Double,
        thinkingLevel: GeminiThinkingLevel,
        fallbackPolicy: CloudFallbackPolicy,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        try await GeminiGenerationRetry.run(
            preferredModelID: preferredModelID, fallbackPolicy: fallbackPolicy,
            serviceName: "Gemini", logger: logger
        ) { modelID, retryCount, fallbackReason in
            do {
                return try await self.generateTranscript(
                    requestedModelID: preferredModelID,
                    effectiveModelID: modelID,
                    retryCount: retryCount,
                    fallbackReason: fallbackReason,
                    preparedAudio: preparedAudio,
                    apiKey: apiKey,
                    audioByteCount: audioByteCount,
                    terms: terms,
                    customPrompt: customPrompt,
                    recordingContext: recordingContext,
                    timeOffsetSeconds: timeOffsetSeconds,
                    thinkingLevel: thinkingLevel,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
            } catch {
                throw CloudRecordingContext.redactedError(error, context: recordingContext)
            }
        }
    }

    static func isRetryableServerFailure(_ error: GoogleAIStudioError) -> Bool {
        GeminiGenerationRetry.isRetryableServerFailure(error)
    }

    private struct PreparedAudio {
        let audioPart: [String: Any]
        let uploadedFileName: String?
    }

    /// Generation retries reuse preparation; only a confirmed missing URI is rebuilt.
    private func prepareAudioPart(
        apiKey: String,
        audioData: Data,
        mimeType: String,
        useFilesAPI: Bool,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> PreparedAudio {
        var uploadedFileName: String?

        if useFilesAPI {
            do {
                logger?("info", "使用 Google AI Studio Files API 串流上傳音訊...")
                let (fileUri, fileName) = try await uploadToFilesAPI(
                    apiKey: apiKey,
                    audioData: audioData,
                    mimeType: mimeType,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
                uploadedFileName = fileName
                return PreparedAudio(
                    audioPart: [
                        "fileData": [
                            "mimeType": mimeType,
                            "fileUri": fileUri
                        ]
                    ],
                    uploadedFileName: fileName
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CloudSegmentDeadlineExceeded {
                throw error
            } catch {
                try CloudBudgetContext.check("upload")
                guard error as? GoogleAIStudioError == .filesAPIUnsupported else { throw error }
                CloudDiagnosticContext.current?.retry(.inlineUploadFallback)
                logger?("warning", "Files API 上傳未成功，降級至串流 Inline Base64 路徑：\(error.localizedDescription)")
            }
        }

        // Inline Base64 透過檔案串流 POST
        guard audioData.count <= Self.maximumInlineAudioBytes else {
            throw GoogleAIStudioError.audioPayloadTooLarge(
                sizeBytes: audioData.count,
                limitBytes: Self.maximumInlineAudioBytes
            )
        }
        let base64Audio = audioData.base64EncodedString()
        return PreparedAudio(
            audioPart: [
                "inlineData": [
                    "mimeType": mimeType,
                    "data": base64Audio
                ]
            ],
            uploadedFileName: uploadedFileName
        )
    }

    private func deletePreparedRemoteFile(
        _ prepared: PreparedAudio,
        apiKey: String,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async {
        guard let fileName = prepared.uploadedFileName else {
            return
        }
        await deleteRemoteFileShielded(fileName: fileName, apiKey: apiKey, logger: logger)
    }

    private func generateTranscript(
        requestedModelID: String,
        effectiveModelID: String,
        retryCount: Int,
        fallbackReason: String?,
        preparedAudio: [String: Any],
        apiKey: String,
        audioByteCount: Int,
        terms: [String],
        customPrompt: String,
        recordingContext: String,
        timeOffsetSeconds: Double,
        thinkingLevel: GeminiThinkingLevel,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        if effectiveModelID == "gemini-3.5-transcribe" {
            return try await sendTranscribeInteraction(
                requestedModelID: requestedModelID, effectiveModelID: effectiveModelID,
                retryCount: retryCount, fallbackReason: fallbackReason,
                apiKey: apiKey, audioPart: preparedAudio, terms: terms,
                timeOffsetSeconds: timeOffsetSeconds, thinkingLevel: thinkingLevel,
                workingDirectory: workingDirectory, logger: logger
            )
        }
        let endpointString = "https://generativelanguage.googleapis.com/v1beta/models/\(effectiveModelID):generateContent"
        guard let endpointURL = URL(string: endpointString) else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        return try await sendGenerateContentRequest(
            requestedModelID: requestedModelID,
            effectiveModelID: effectiveModelID,
            retryCount: retryCount,
            fallbackReason: fallbackReason,
            endpointURL: endpointURL,
            apiKey: apiKey,
            audioByteCount: audioByteCount,
            audioPart: preparedAudio,
            systemInstructionText: buildSystemInstruction(),
            userPromptText: buildUserPrompt(
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds
            ),
            thinkingLevel: thinkingLevel,
            recordingContext: recordingContext,
            workingDirectory: workingDirectory,
            logger: logger
        )
    }

    /// The Developer API transcription model uses Interactions, whose request
    /// and response schemas differ from GenerateContent. It cannot combine
    /// custom vocabulary with diarization or word timestamps.
    static func transcribeInteractionBody(audioPart: [String: Any], terms: [String]) throws -> [String: Any] {
        let input: [String: Any]
        if let file = audioPart["fileData"] as? [String: Any],
           let uri = file["fileUri"] as? String, !uri.isEmpty,
           let mime = file["mimeType"] as? String, !mime.isEmpty {
            // Interactions uses AudioContent for uploaded audio, not the
            // GenerateContent fileData wrapper.
            input = ["type": "audio", "uri": uri, "mime_type": mime]
        } else if let inline = audioPart["inlineData"] as? [String: Any],
                  let data = inline["data"] as? String, let mime = inline["mimeType"] as? String {
            input = ["type": "audio", "data": data, "mime_type": mime]
        } else {
            throw GoogleAIStudioError.invalidAudioReference
        }
        let vocabulary = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard vocabulary.count <= 1000 else { throw GoogleAIStudioError.tooManyVocabularyTerms(vocabulary.count) }
        let transcription: [String: Any]
        if vocabulary.isEmpty {
            transcription = ["mode": ["type": "verbatim", "diarization_mode": "speaker"]]
        } else {
            // The Developer API's vocabulary example omits mode; verbatim is
            // the documented default. A verbatim mode, when explicit, is an
            // object rather than the string used by the older implementation.
            transcription = ["custom_vocabulary": vocabulary]
        }
        return ["model": "models/gemini-3.5-transcribe", "input": [input],
                "store": false, "generation_config": ["transcription_config": transcription]]
    }

    static func transcribeInteractionText(from data: Data, timeOffsetSeconds: Double = 0) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAIStudioError.invalidJSONResponse
        }
        guard let status = json["status"] as? String else {
            throw GoogleAIStudioError.incompleteResponse(finishReason: "MISSING_STATUS", message: nil)
        }
        guard status == "completed" else {
            throw GoogleAIStudioError.incompleteResponse(finishReason: status.uppercased(), message: nil)
        }
        let steps = json["steps"] as? [[String: Any]] ?? []
        let pieces = steps.filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "text" }
        let text = pieces.map { part -> String in
            let original = part["text"] as? String ?? ""
            return textWithSpeakerLabels(original, annotations: part["annotations"] as? [[String: Any]] ?? [],
                                         timeOffsetSeconds: timeOffsetSeconds)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // Interactions `completed` is not GenerateContent `finishReason=STOP`.
        // Do not invent STOP or trigger the latter's empty-STOP retry policy.
        guard !text.isEmpty else { throw GoogleAIStudioError.emptyResponse }
        return text
    }

    /// Insert labels at validated UTF-8 byte offsets without reconstructing the
    /// transcript from annotations: punctuation and unannotated text survive.
    private static func textWithSpeakerLabels(_ text: String, annotations: [[String: Any]], timeOffsetSeconds: Double) -> String {
        let bytes = Array(text.utf8)
        var insertions: [(Int, String)] = []
        var previous: String?
        var lastPosition = 0
        var usedTextAlignment = false
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        let words = annotations.filter { $0["type"] as? String == "word_info" }
        guard !words.isEmpty else { return text }
        for annotation in words {
            guard let speaker = annotation["speaker"] as? String,
                  speaker.range(of: #"^spk_[0-9]+$"#, options: .regularExpression) != nil else { return text }
            let start: Int
            let end: Int
            if let first = annotation["start_index"] as? Int, let last = annotation["end_index"] as? Int {
                start = first
                end = last
            } else {
                // Google's REST example may omit byte offsets. Align every
                // annotated word in sequence, accepting only punctuation and
                // whitespace between words. Otherwise return the unaltered text.
                guard let word = annotation["text"] as? String, !word.isEmpty,
                      let suffix = String(bytes: bytes[lastPosition...], encoding: .utf8),
                      let range = suffix.range(of: word) else { return text }
                let gap = suffix[..<range.lowerBound]
                guard gap.unicodeScalars.allSatisfy({ separators.contains($0) }) else { return text }
                start = lastPosition + gap.utf8.count
                end = start + word.utf8.count
                usedTextAlignment = true
            }
            guard start >= lastPosition, end > start, end <= bytes.count,
                  String(bytes: bytes[0..<start], encoding: .utf8) != nil,
                  String(bytes: bytes[0..<end], encoding: .utf8) != nil else { return text }
            if speaker != previous {
                let seconds = timeOffsetSeconds.isFinite ? Int(max(0, timeOffsetSeconds)) : 0
                let segmentStart = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
                insertions.append((start, "\n\n[片段 \(segmentStart)・講者 \(speaker.dropFirst(4))]："))
                previous = speaker
            }
            lastPosition = end
        }
        if usedTextAlignment {
            guard let tail = String(bytes: bytes[lastPosition...], encoding: .utf8),
                  tail.unicodeScalars.allSatisfy({ separators.contains($0) }) else { return text }
        }
        guard !insertions.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for (position, label) in insertions {
            guard let slice = String(bytes: bytes[cursor..<position], encoding: .utf8) else { return text }
            result += slice + label
            cursor = position
        }
        guard let tail = String(bytes: bytes[cursor...], encoding: .utf8) else { return text }
        return result + tail
    }

    private func sendTranscribeInteraction(
        requestedModelID: String, effectiveModelID: String, retryCount: Int,
        fallbackReason: String?, apiKey: String, audioPart: [String: Any], terms: [String],
        timeOffsetSeconds: Double, thinkingLevel: GeminiThinkingLevel, workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        let body = try Self.transcribeInteractionBody(audioPart: audioPart, terms: terms)
        let requestData = try JSONSerialization.data(withJSONObject: body)
        let file = try GeminiTransportHelper.writeTemporaryRequestFile(data: requestData,
            in: workingDirectory, prefix: "aistudio_transcribe")
        defer { try? FileManager.default.removeItem(at: file) }
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = GeminiGenerationConfig.requestTimeout(modelID: effectiveModelID)
        let started = Date()
        let (data, response) = try await sendWithPOSIXRetry(request: request, fileURL: file,
            session: urlSession, logger: logger)
        guard response.statusCode == 200 else {
            let message = GeminiResponseParser.errorMessage(from: data)
            if response.statusCode == 429 {
                if GeminiTransportHelper.isDailyQuotaExceeded(data: data, message: message) {
                    throw GoogleAIStudioError.quotaExceeded(message)
                }
                throw GoogleAIStudioError.rateLimited(message: message,
                    retryAfterSeconds: GeminiTransportHelper.retryAfterSeconds(response: response, data: data))
            }
            throw GoogleAIStudioError.requestFailed(statusCode: response.statusCode, message: message)
        }
        let text = try Self.transcribeInteractionText(from: data, timeOffsetSeconds: timeOffsetSeconds)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let usage = json?["usage"] as? [String: Any]
        let usageMetadata = usage.map { CloudUsageMetadata(
            promptTokenCount: $0["total_input_tokens"] as? Int,
            cachedContentTokenCount: $0["total_cached_tokens"] as? Int,
            candidatesTokenCount: $0["total_output_tokens"] as? Int,
            thoughtsTokenCount: $0["total_thought_tokens"] as? Int,
            totalTokenCount: $0["total_tokens"] as? Int) }
        let metadata = CloudTranscriptionMetadata(requestedModelID: requestedModelID,
            effectiveModelID: effectiveModelID, modelVersion: json?["model"] as? String,
            responseID: json?["id"] as? String,
            retryCount: max(retryCount, (CloudNetworkContext.generation?.count ?? 1) - 1),
            fallbackReason: fallbackReason, thinkingLevel: thinkingLevel,
            latencySeconds: Date().timeIntervalSince(started), usage: usageMetadata)
        return CloudTranscriptionResult(text: text, metadata: metadata)
    }

    private func sendGenerateContentRequest(
        requestedModelID: String,
        effectiveModelID: String,
        retryCount: Int,
        fallbackReason: String?,
        endpointURL: URL,
        apiKey: String,
        audioByteCount: Int,
        audioPart: [String: Any],
        systemInstructionText: String,
        userPromptText: String,
        thinkingLevel: GeminiThinkingLevel,
        recordingContext: String = "",
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        let effectiveThinkingLevel = GeminiGenerationConfig.resolvedThinkingLevel(
            thinkingLevel, modelID: effectiveModelID)
        let generationConfig = GeminiGenerationConfig.make(
            maxOutputTokens: GeminiGenerationConfig.transcriptionOutputTokens(modelID: effectiveModelID),
            modelID: effectiveModelID,
            thinkingLevel: effectiveThinkingLevel
        )
        logger?(
            "info",
            "轉錄請求送出 maxOutputTokens=\(generationConfig["maxOutputTokens"] as? Int ?? 0)，thinkingConfig=\(effectiveThinkingLevel.rawValue)（模型 \(effectiveModelID)）。"
        )

        let requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemInstructionText]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [audioPart, ["text": userPromptText]]
                ]
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_CIVIC_INTEGRITY", "threshold": "BLOCK_NONE"]
            ],
            "generationConfig": generationConfig
        ]

        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let tempRequestFile = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: requestData,
            in: workingDirectory,
            prefix: "aistudio_generate"
        )
        defer { try? FileManager.default.removeItem(at: tempRequestFile) }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.timeoutInterval = GeminiGenerationConfig.requestTimeout(modelID: effectiveModelID)

        let startedAt = Date()
        let (data, httpResponse) = try await sendWithPOSIXRetry(
            request: urlRequest,
            fileURL: tempRequestFile,
            session: urlSession,
            logger: logger
        )
        let latency = Date().timeIntervalSince(startedAt)

        logger?(
            "info",
            "Google AI Studio 回應：HTTP \(httpResponse.statusCode)，MP3 \(audioByteCount) bytes，JSON \(requestData.count) bytes，要求 \(requestedModelID)，實際請求 \(effectiveModelID)。"
        )

        guard httpResponse.statusCode == 200 else {
            let errorMsg = GeminiResponseParser.errorMessage(from: data)
            if httpResponse.statusCode == 429 {
                if GeminiTransportHelper.isDailyQuotaExceeded(
                    data: data,
                    message: errorMsg
                ) {
                    throw GoogleAIStudioError.quotaExceeded(errorMsg)
                }
                throw GoogleAIStudioError.rateLimited(
                    message: errorMsg,
                    retryAfterSeconds: GeminiTransportHelper.retryAfterSeconds(
                        response: httpResponse,
                        data: data
                    )
                )
            }
            throw GoogleAIStudioError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMsg
            )
        }

        let text = try parseCandidateText(
            from: data,
            httpStatusCode: httpResponse.statusCode,
            recordingContextBlock: try CloudRecordingContext.referenceBlock(recordingContext),
            logger: logger
        )
        let metadata = GeminiResponseMetadataParser.makeMetadata(
            from: data,
            requestedModelID: requestedModelID,
            effectiveModelID: effectiveModelID,
            retryCount: max(retryCount, (CloudNetworkContext.generation?.count ?? 1) - 1),
            fallbackReason: fallbackReason,
            thinkingLevel: effectiveThinkingLevel,
            latencySeconds: latency
        )
        return CloudTranscriptionResult(text: text, metadata: metadata)
    }

    /// 透過串流上傳將請求送出，若遇到 POSIX 40 自動建立全新 Ephemeral Session 重試一次
    private func sendWithPOSIXRetry(
        request: URLRequest,
        fileURL: URL,
        session: URLSession,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await GeminiTransportHelper.budgetedUpload(
                session: session,
                request: request,
                fileURL: fileURL,
                stage: .generation,
                responseMode: .unaryJSON
            )
            guard let http = response as? HTTPURLResponse else { throw GoogleAIStudioError.invalidJSONResponse }
            return (data, http)
        } catch {
            if GeminiTransportHelper.isPOSIXMessageTooLarge(error) { throw GoogleAIStudioError.transportMessageTooLarge }
            throw error
        }
    }

    /// 上傳檔案至 Google AI Studio Files API
    private func uploadToFilesAPI(
        apiKey: String,
        audioData: Data,
        mimeType: String,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> (fileUri: String, fileName: String) {
        let tempAudioFile = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: audioData,
            in: workingDirectory,
            prefix: "aistudio_audio"
        )
        defer {
            try? FileManager.default.removeItem(at: tempAudioFile)
        }

        // A client-assigned name lets files.get confirm a lost final response.
        let requestedName = "files/" + UUID().uuidString.lowercased()
        let makeRequest = {
            try await self.startFilesUpload(apiKey: apiKey, name: requestedName,
                byteCount: audioData.count, mimeType: mimeType)
        }
        let uploadRequest = try await makeRequest()
        let expectedHash = Data(SHA256.hash(data: audioData)).base64EncodedString()
        let (uploadData, uploadResponse) = try await GeminiTransportHelper.budgetedUpload(
            session: urlSession,
            request: uploadRequest,
            fileURL: tempAudioFile,
            stage: .upload,
            responseMode: .unaryJSON,
            attempts: CloudNetworkContext.segmentAttempts?.quota(for: "preparation:filesUpload", stage: .upload),
            confirmUpload: {
                let (data, response) = try await self.remoteFileMetadata(name: requestedName, apiKey: apiKey)
                guard response.statusCode == 200,
                      let file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      file["name"] as? String == requestedName,
                      file["sizeBytes"] as? String == String(audioData.count),
                      file["sha256Hash"] as? String == expectedHash else { return nil }
                return (try JSONSerialization.data(withJSONObject: ["file": file]), response)
            }, restartUpload: makeRequest)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse else { throw GoogleAIStudioError.invalidJSONResponse }

        return try await finishFilesUpload(data: uploadData, response: uploadHTTP, apiKey: apiKey, logger: logger)
    }

    private func startFilesUpload(apiKey: String, name: String, byteCount: Int, mimeType: String) async throws -> URLRequest {
        // Each initialization has its own bounded transport scope. Recreating
        // a session does not recreate the root budget or generation ledger.
        guard let initURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files") else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        var initRequest = URLRequest(url: initURL)
        initRequest.httpMethod = "POST"
        initRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        initRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        initRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        initRequest.setValue("\(byteCount)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        initRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        initRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let initMetadata: [String: Any] = [
            "file": ["name": name, "display_name": "record-to-text audio"]
        ]
        initRequest.httpBody = try JSONSerialization.data(withJSONObject: initMetadata)
        initRequest.timeoutInterval = 30

        let (_, initResponse) = try await GeminiTransportHelper.budgetedData(
            session: urlSession,
            request: initRequest,
            stage: "upload",
            responseMode: .rawData,
            attempts: CloudNetworkContext.segmentAttempts?.quota(for: "preparation:filesInit", stage: .upload)
        )
        guard let initHTTP = initResponse as? HTTPURLResponse else {
            throw GoogleAIStudioError.invalidJSONResponse
        }
        if [404, 405, 501].contains(initHTTP.statusCode) { throw GoogleAIStudioError.filesAPIUnsupported }
        guard initHTTP.statusCode == 200 else { throw CloudHTTPFailure(status: initHTTP.statusCode, stage: .upload) }

        let headerUploadURL = initHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL")
            ?? initHTTP.value(forHTTPHeaderField: "x-goog-upload-url")
            ?? (initHTTP.allHeaderFields["X-Goog-Upload-URL"] as? String)
            ?? (initHTTP.allHeaderFields["x-goog-upload-url"] as? String)

        guard initHTTP.statusCode == 200,
              let uploadURLString = headerUploadURL,
              let uploadURL = URL(string: uploadURLString) else {
            throw GoogleAIStudioError.fileUploadFailed("初始化回應缺少上傳位置。")
        }

        // 2. 串流上傳音訊檔案資料
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("\(byteCount)", forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.timeoutInterval = 300

        return uploadRequest
    }

    private func remoteFileMetadata(name: String, apiKey: String) async throws -> (Data, HTTPURLResponse) {
        guard name.range(of: #"^files/[a-z0-9-]{1,40}$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)") else {
            throw GoogleAIStudioError.invalidJSONResponse
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 15
        let (data, response) = try await GeminiTransportHelper.budgetedData(
            session: urlSession,
            request: request,
            stage: "poll",
            responseMode: .unaryJSON
        )
        guard let http = response as? HTTPURLResponse else { throw GoogleAIStudioError.invalidJSONResponse }
        return (data, http)
    }

    private func remoteFileIsMissing(name: String, apiKey: String) async throws -> Bool {
        let (_, response) = try await remoteFileMetadata(name: name, apiKey: apiKey)
        return [404, 410].contains(response.statusCode)
    }

    private func finishFilesUpload(data uploadData: Data, response uploadHTTP: HTTPURLResponse,
                                   apiKey: String, logger: ((_ level: String, _ message: String) -> Void)?) async throws -> (fileUri: String, fileName: String) {
        guard uploadHTTP.statusCode == 200 else {
            throw CloudHTTPFailure(status: uploadHTTP.statusCode, stage: .upload)
        }

        guard let json = try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any],
              let fileObj = json["file"] as? [String: Any],
              let fileName = fileObj["name"] as? String else {
            throw GoogleAIStudioError.fileUploadFailed("無法解析 Files API 回傳結構")
        }

        do {
            // Once the server gives us a file name, this scope owns cleanup.
            // Validate the rest of the response only after entering it so a
            // malformed response cannot orphan the uploaded remote file.
            guard let fileUri = fileObj["uri"] as? String else {
                throw GoogleAIStudioError.fileUploadFailed(
                    "Files API 回傳檔案名稱，但缺少可用的 URI"
                )
            }
            var currentState = fileObj["state"] as? String ?? "ACTIVE"

            // 3. 輪詢檔案狀態直到 ACTIVE。取消必須向外傳遞，才能立即清理遠端檔案。
            //    以單調時鐘計算預算，避免睡眠秒數與累加值漂移。
            let polling = CloudPollingBudget(context: CloudNetworkContext.current)
            while currentState == "PROCESSING" && polling.remaining > 0 {
                try Task.checkCancellation()
                try await CloudBudgetContext.perform(stage: "poll") {
                    let delay = Duration.seconds(min(1.5, polling.remaining))
                    if let context = CloudNetworkContext.current { try await context.environment.sleep(delay) }
                    else { try await Task.sleep(for: delay) }
                }
                guard polling.remaining > 0 else { break }

                guard let pollURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)") else {
                    throw GoogleAIStudioError.invalidJSONResponse
                }
                var pollRequest = URLRequest(url: pollURL)
                pollRequest.httpMethod = "GET"
                pollRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                pollRequest.timeoutInterval = min(15, polling.remaining)

                let (pollData, pollResponse) = try await CloudNetworkContext.$polling.withValue(polling) {
                    try await GeminiTransportHelper.budgetedData(
                        session: urlSession,
                        request: pollRequest,
                        stage: "poll",
                        responseMode: .unaryJSON
                    )
                }
                guard let pollHTTP = pollResponse as? HTTPURLResponse else {
                    throw GoogleAIStudioError.invalidJSONResponse
                }
                guard pollHTTP.statusCode == 200 else { throw CloudHTTPFailure(status: pollHTTP.statusCode, stage: .poll) }
                guard let pollJson = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any]
                else {
                    throw GoogleAIStudioError.invalidJSONResponse
                }
                currentState = pollJson["state"] as? String ?? "PROCESSING"
            }

            if currentState == "FAILED" {
                throw GoogleAIStudioError.fileUploadFailed("Google 伺服器處理音訊檔案失敗")
            }

            if currentState == "PROCESSING" {
                throw GoogleAIStudioError.fileProcessingTimedOut
            }

            guard currentState == "ACTIVE" else {
                throw GoogleAIStudioError.fileUploadFailed("Google 伺服器回傳未知的檔案狀態：\(currentState)")
            }

            return (fileUri: fileUri, fileName: fileName)
        } catch {
            await deleteRemoteFileShielded(
                fileName: fileName,
                apiKey: apiKey,
                logger: logger
            )
            throw error
        }
    }

    /// Cleanup must not inherit the transcription task's cancellation state.
    /// Otherwise URLSession may reject DELETE immediately after the user cancels.
    private func deleteRemoteFileShielded(
        fileName: String,
        apiKey: String,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async {
        if CloudNetworkContext.current?.waitForCleanup == false {
            // Cleanup has its own bounded allowance and cannot delay failure UI.
            Task.detached(priority: .utility) {
                let cleanupBudget = CloudSegmentBudget(limit: .seconds(5))
                _ = try? await cleanupBudget.withDeadline(stage: "cleanup") {
                    await self.deleteRemoteFile(fileName: fileName, apiKey: apiKey)
                }
            }
            return
        }
        let cleanupFailure = await Task.detached(priority: .utility) { [self] in
            await deleteRemoteFile(
                fileName: fileName,
                apiKey: apiKey
            )
        }.value
        if let cleanupFailure {
            logger?("warning", "清理 Files API 暫存檔 (\(fileName)) 失敗：\(cleanupFailure)")
        }
    }

    /// 刪除 Files API 遠端暫存檔案
    private func deleteRemoteFile(
        fileName: String,
        apiKey: String
    ) async -> String? {
        guard let deleteURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)") else {
            return "無法建立 DELETE URL"
        }

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 5

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 || httpResponse.statusCode == 404 {
                    return nil
                }
                return "HTTP \(httpResponse.statusCode)"
            }
            return "Google 未回傳有效的 HTTP 回應"
        } catch {
            return error.localizedDescription
        }
    }

    func buildSystemInstruction() -> String {
        GeminiTranscriptPrompt.systemInstruction
    }

    func buildUserPrompt(terms: [String], customPrompt: String, timeOffsetSeconds: Double) -> String {
        GeminiTranscriptPrompt.buildUserPrompt(
            terms: terms,
            canonicalPrompt: customPrompt,
            timeOffsetSeconds: timeOffsetSeconds
        )
    }

    func parseCandidateText(
        from data: Data,
        httpStatusCode: Int = 200,
        recordingContextBlock: String = "",
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) throws -> String {
        try GeminiResponseParser.transcript(from: data, errors: GoogleAIStudioError.self,
            httpStatusCode: httpStatusCode, recordingContextBlock: recordingContextBlock, logger: logger)
    }
}
