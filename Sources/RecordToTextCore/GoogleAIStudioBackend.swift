import Foundation

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
    case invalidJSONResponse
    case audioPayloadTooLarge(sizeBytes: Int, limitBytes: Int)
    case transportMessageTooLarge
    case fileUploadFailed(String)
    case fileProcessingTimedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未設定 Google AI Studio API Key。請至設定頁面填入 API Key。"
        case let .invalidAPIKey(reason):
            return "Google AI Studio API Key 無效：\(reason)"
        case let .requestFailed(statusCode, message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Google AI Studio 請求失敗（HTTP \(statusCode)）：\(trimmed)"
        case let .rateLimited(message, retryAfterSeconds):
            let delay = retryAfterSeconds.map { "，建議至少等待 \(String(format: "%.1f", $0)) 秒" } ?? ""
            return "Google AI Studio 暫時達到速率限制\(delay)：\(message)"
        case let .quotaExceeded(message):
            return "Google AI Studio 當日配額已用完，短時間重試不會成功：\(message)"
        case let .prohibitedContent(message):
            return "Google 內容安全政策攔截：\(message)"
        case let .promptBlocked(diagnostics):
            return diagnostics.userFacingMessage
        case let .incompleteResponse(finishReason, message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.map { "：\($0)" } ?? ""
            return "Google AI Studio 回應未正常完成（\(finishReason)）\(suffix)。為避免輸出不完整逐字稿，本次工作已停止。"
        case .emptyResponse:
            return "Google AI Studio 未回傳任何文字內容或候選結果。"
        case .invalidJSONResponse:
            return "Google AI Studio 回傳的資料無法解讀為有效 JSON。"
        case let .audioPayloadTooLarge(sizeBytes, limitBytes):
            let sizeMB = Double(sizeBytes) / (1024 * 1024)
            let limitMB = Double(limitBytes) / (1024 * 1024)
            return "音檔過大（\(String(format: "%.1f", sizeMB)) MB），超過直接傳輸上限（\(String(format: "%.1f", limitMB)) MB）。"
        case .transportMessageTooLarge:
            return "連到 Google 的傳輸通道失敗（本機無法送出這包資料）。這不是音檔超過 Gemini 時長上限。請重試；若持續發生，需要改為先上傳音檔再轉錄。"
        case let .fileUploadFailed(message):
            return "Google AI Studio 音訊上傳失敗：\(message)"
        case .fileProcessingTimedOut:
            return "Google AI Studio 檔案處理超時，請稍後重試。"
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
            thinkingLevel: GeminiThinkingLevel = .medium,
            fallbackPolicy: CloudFallbackPolicy = .disabled
        ) {
            self.apiKey = apiKey
            self.modelID = modelID
            self.useFilesAPI = useFilesAPI
            self.thinkingLevel = thinkingLevel
            self.fallbackPolicy = fallbackPolicy
        }

        public static let `default` = Configuration()
    }

    private let urlSession: URLSession
    private let lock = NSLock()
    private var config: Configuration

    public static let maximumInlineAudioBytes: Int = 20 * 1024 * 1024 // 20 MB

    public init(
        urlSession: URLSession = .shared,
        configuration: Configuration = .default
    ) {
        self.urlSession = urlSession
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
        let errorMsg = parseErrorMessage(from: data)
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
        timeOffsetSeconds: Double = 0,
        workingDirectory: URL? = nil,
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) async throws -> CloudTranscriptionResult {
        let currentConfig = getConfiguration()

        guard let apiKey = currentConfig.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            throw GoogleAIStudioError.missingAPIKey
        }

        let preparedAudio = try await prepareAudioPart(
            apiKey: apiKey,
            audioData: audioData,
            mimeType: mimeType,
            useFilesAPI: currentConfig.useFilesAPI,
            workingDirectory: workingDirectory,
            logger: logger
        )

        let result: CloudTranscriptionResult
        do {
            result = try await runTranscriptionAttempts(
                preferredModelID: currentConfig.modelID,
                preparedAudio: preparedAudio.audioPart,
                apiKey: apiKey,
                audioByteCount: audioData.count,
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds,
                thinkingLevel: currentConfig.thinkingLevel,
                fallbackPolicy: currentConfig.fallbackPolicy,
                workingDirectory: workingDirectory,
                logger: logger
            )
        } catch {
            await deletePreparedRemoteFile(
                preparedAudio,
                apiKey: apiKey,
                logger: logger
            )
            throw error
        }
        await deletePreparedRemoteFile(
            preparedAudio,
            apiKey: apiKey,
            logger: logger
        )
        return result
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
        timeOffsetSeconds: Double,
        thinkingLevel: GeminiThinkingLevel,
        fallbackPolicy: CloudFallbackPolicy,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        do {
            return try await executeWithRetries(
                requestedModelID: preferredModelID,
                effectiveModelID: preferredModelID,
                fallbackReason: nil,
                priorRetryCount: 0,
                preparedAudio: preparedAudio,
                apiKey: apiKey,
                audioByteCount: audioByteCount,
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds,
                thinkingLevel: thinkingLevel,
                workingDirectory: workingDirectory,
                logger: logger
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GoogleAIStudioError {
            guard
                fallbackPolicy == .flashOnly,
                preferredModelID.contains("3.7"),
                Self.isRetryableServerFailure(error)
            else {
                throw error
            }

            let fallbackModel = "gemini-3.6-flash"
            let reason = error.localizedDescription
            logger?(
                "warning",
                "Gemini 3.7 重試後仍不可用；依使用者設定改用 \(fallbackModel)。原始原因：\(reason)"
            )
            return try await executeWithRetries(
                requestedModelID: preferredModelID,
                effectiveModelID: fallbackModel,
                fallbackReason: reason,
                priorRetryCount:
                    GeminiTransportHelper.RetryPolicy.maximumAttempts - 1,
                preparedAudio: preparedAudio,
                apiKey: apiKey,
                audioByteCount: audioByteCount,
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds,
                thinkingLevel: thinkingLevel,
                workingDirectory: workingDirectory,
                logger: logger
            )
        }
    }

    static func isRetryableServerFailure(_ error: GoogleAIStudioError) -> Bool {
        switch error {
        case .rateLimited:
            return true
        case let .requestFailed(statusCode, _):
            return GeminiTransportHelper.RetryPolicy
                .isRetryableStatusCode(statusCode)
        default:
            return false
        }
    }

    private struct PreparedAudio {
        let audioPart: [String: Any]
        let uploadedFileName: String?
    }

    /// Uploads once per transcribe() call; retries reuse the result.
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
            } catch {
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

    private func executeWithRetries(
        requestedModelID: String,
        effectiveModelID: String,
        fallbackReason: String?,
        priorRetryCount: Int,
        preparedAudio: [String: Any],
        apiKey: String,
        audioByteCount: Int,
        terms: [String],
        customPrompt: String,
        timeOffsetSeconds: Double,
        thinkingLevel: GeminiThinkingLevel,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        let policy = GeminiTransportHelper.RetryPolicy.self
        var lastError: Error?

        for attempt in 1...policy.maximumAttempts {
            do {
                return try await generateTranscript(
                    requestedModelID: requestedModelID,
                    effectiveModelID: effectiveModelID,
                    retryCount: priorRetryCount + attempt - 1,
                    fallbackReason: fallbackReason,
                    preparedAudio: preparedAudio,
                    apiKey: apiKey,
                    audioByteCount: audioByteCount,
                    terms: terms,
                    customPrompt: customPrompt,
                    timeOffsetSeconds: timeOffsetSeconds,
                    thinkingLevel: thinkingLevel,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GoogleAIStudioError {
                let retryAfter: Double?
                let retryable: Bool
                switch error {
                case let .rateLimited(_, delay):
                    retryAfter = delay
                    retryable = true
                case let .requestFailed(statusCode, _):
                    retryAfter = nil
                    retryable = policy.isRetryableStatusCode(statusCode)
                default:
                    retryAfter = nil
                    retryable = false
                }
                guard retryable else {
                    throw error
                }
                lastError = error
                guard attempt < policy.maximumAttempts else {
                    break
                }
                let delay = policy.backoffSeconds(
                    forAttempt: attempt,
                    retryAfterSeconds: retryAfter
                )
                logger?(
                    "info",
                    "Gemini \(effectiveModelID) 暫時忙碌，\(String(format: "%.1f", delay)) 秒後進行第 \(attempt + 1) 次嘗試。"
                )
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
        }

        if let lastError {
            throw lastError
        }
        throw GoogleAIStudioError.requestFailed(
            statusCode: 503,
            message: "伺服器忙碌，重試後仍失敗。"
        )
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
        timeOffsetSeconds: Double,
        thinkingLevel: GeminiThinkingLevel,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
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
            workingDirectory: workingDirectory,
            logger: logger
        )
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
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        let generationConfig = GeminiGenerationConfig.make(
            maxOutputTokens: 16_384,
            modelID: effectiveModelID,
            thinkingLevel: thinkingLevel
        )
        logger?(
            "info",
            "轉錄請求送出 thinkingConfig=\(thinkingLevel.rawValue)（模型 \(effectiveModelID)）。"
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
        urlRequest.timeoutInterval = 300

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
            let errorMsg = parseErrorMessage(from: data)
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
            logger: logger
        )
        let metadata = GeminiResponseMetadataParser.makeMetadata(
            from: data,
            requestedModelID: requestedModelID,
            effectiveModelID: effectiveModelID,
            retryCount: retryCount,
            fallbackReason: fallbackReason,
            thinkingLevel: thinkingLevel,
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
            let (data, response) = try await session.upload(for: request, fromFile: fileURL)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GoogleAIStudioError.invalidJSONResponse
            }
            return (data, httpResponse)
        } catch {
            if GeminiTransportHelper.isPOSIXMessageTooLarge(error) {
                logger?("info", "本機傳輸通道失敗（POSIX 40），正改用全新連線 (TCP/Ephemeral) 重試，非音檔時長問題。")
                let retrySession = GeminiTransportHelper.makeEphemeralRetrySession(protocolClasses: session.configuration.protocolClasses)
                // The retry session owns a connection pool; release it as soon
                // as this single retry finishes instead of leaking one per hit.
                defer { retrySession.finishTasksAndInvalidate() }
                var retryRequest = request
                retryRequest.assumesHTTP3Capable = false

                do {
                    let (data, response) = try await retrySession.upload(for: retryRequest, fromFile: fileURL)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw GoogleAIStudioError.invalidJSONResponse
                    }
                    logger?("info", "傳輸通道重試成功（HTTP \(httpResponse.statusCode)）。")
                    return (data, httpResponse)
                } catch let retryError {
                    if GeminiTransportHelper.isPOSIXMessageTooLarge(retryError) {
                        logger?("warning", "重試後仍為 POSIX 40 傳輸失敗。")
                        throw GoogleAIStudioError.transportMessageTooLarge
                    }
                    throw retryError
                }
            } else {
                throw error
            }
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

        // 1. 初始化 Resumable Upload
        guard let initURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files") else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        var initRequest = URLRequest(url: initURL)
        initRequest.httpMethod = "POST"
        initRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        initRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        initRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        initRequest.setValue("\(audioData.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        initRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        initRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let initMetadata: [String: Any] = [
            "file": ["display_name": "audio_\(UUID().uuidString)"]
        ]
        initRequest.httpBody = try JSONSerialization.data(withJSONObject: initMetadata)
        initRequest.timeoutInterval = 30

        let (initData, initResponse) = try await urlSession.data(for: initRequest)
        guard let initHTTP = initResponse as? HTTPURLResponse else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        let headerUploadURL = initHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL")
            ?? initHTTP.value(forHTTPHeaderField: "x-goog-upload-url")
            ?? (initHTTP.allHeaderFields["X-Goog-Upload-URL"] as? String)
            ?? (initHTTP.allHeaderFields["x-goog-upload-url"] as? String)

        guard initHTTP.statusCode == 200,
              let uploadURLString = headerUploadURL,
              let uploadURL = URL(string: uploadURLString) else {
            let errorMsg = parseErrorMessage(from: initData)
            throw GoogleAIStudioError.fileUploadFailed("無法初始化 Files API 上傳：\(errorMsg)")
        }

        // 2. 串流上傳音訊檔案資料
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("\(audioData.count)", forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.timeoutInterval = 300

        let (uploadData, uploadHTTP) = try await sendWithPOSIXRetry(
            request: uploadRequest,
            fileURL: tempAudioFile,
            session: urlSession,
            logger: logger
        )

        guard uploadHTTP.statusCode == 200 else {
            let errorMsg = parseErrorMessage(from: uploadData)
            throw GoogleAIStudioError.fileUploadFailed("Files API 音訊上傳失敗（HTTP \(uploadHTTP.statusCode)）：\(errorMsg)")
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
            let pollingDeadline = Date().addingTimeInterval(60)
            while currentState == "PROCESSING" && Date() < pollingDeadline {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_500_000_000)

                guard let pollURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)") else {
                    throw GoogleAIStudioError.invalidJSONResponse
                }
                var pollRequest = URLRequest(url: pollURL)
                pollRequest.httpMethod = "GET"
                pollRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                pollRequest.timeoutInterval = 15

                let (pollData, pollResponse) = try await urlSession.data(for: pollRequest)
                guard let pollHTTP = pollResponse as? HTTPURLResponse else {
                    throw GoogleAIStudioError.invalidJSONResponse
                }
                guard pollHTTP.statusCode == 200,
                      let pollJson = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any]
                else {
                    let errorMsg = parseErrorMessage(from: pollData)
                    throw GoogleAIStudioError.fileUploadFailed("查詢檔案處理狀態失敗（HTTP \(pollHTTP.statusCode)）：\(errorMsg)")
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
        request.timeoutInterval = 30

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

    private func parseErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return message
        }
        return String(decoding: data, as: UTF8.self)
    }

    func parseCandidateText(
        from data: Data,
        httpStatusCode: Int = 200,
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        if let diagnostics = GeminiPromptFeedbackParser.diagnosticsIfBlocked(
            from: json,
            httpStatusCode: httpStatusCode
        ) {
            logger?("warning", diagnostics.logSummary)
            throw GoogleAIStudioError.promptBlocked(diagnostics)
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            logger?(
                "warning",
                GeminiResponseInventory.summary(
                    from: json,
                    reason: "no_candidates",
                    rawByteCount: data.count
                )
            )
            throw GoogleAIStudioError.emptyResponse
        }

        guard let finishReason = firstCandidate["finishReason"] as? String,
              !finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            logger?(
                "warning",
                GeminiResponseInventory.summary(
                    from: json,
                    reason: "missing_finish_reason",
                    rawByteCount: data.count
                )
            )
            throw GoogleAIStudioError.incompleteResponse(
                finishReason: "MISSING_FINISH_REASON",
                message: firstCandidate["finishMessage"] as? String
            )
        }
        let normalizedFinishReason = GeminiTranscriptFinishReason.normalized(finishReason)
        if GeminiTranscriptFinishReason.isSafetyBlock(normalizedFinishReason) {
            throw GoogleAIStudioError.prohibitedContent(
                firstCandidate["finishMessage"] as? String ?? normalizedFinishReason
            )
        }

        guard let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            logger?(
                "warning",
                GeminiResponseInventory.summary(
                    from: json,
                    reason: "missing_candidate_parts",
                    rawByteCount: data.count
                )
            )
            throw GoogleAIStudioError.emptyResponse
        }

        var textChunks: [String] = []
        for part in parts {
            if part["thought"] as? Bool == true {
                continue
            }
            if let text = part["text"] as? String {
                textChunks.append(text)
            }
        }

        let combined = textChunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = sanitizeTranscript(combined)
        guard !sanitized.isEmpty else {
            logger?(
                "warning",
                GeminiResponseInventory.summary(
                    from: json,
                    reason: "empty_transcript_text",
                    rawByteCount: data.count
                )
            )
            throw GoogleAIStudioError.emptyResponse
        }

        if GeminiTranscriptFinishReason.isTruncated(normalizedFinishReason) {
            logger?(
                "warning",
                "Gemini 輸出達 maxOutputTokens；現有文字只保存為未完成草稿，將由 coordinator 切小重試。"
            )
            throw CloudOutputTruncatedError(
                partialText: sanitized,
                finishMessage: firstCandidate["finishMessage"] as? String
            )
        }
        guard GeminiTranscriptFinishReason.allowsUsableText(normalizedFinishReason) else {
            throw GoogleAIStudioError.incompleteResponse(
                finishReason: normalizedFinishReason,
                message: firstCandidate["finishMessage"] as? String
            )
        }
        return sanitized
    }

    private func sanitizeTranscript(_ rawText: String) -> String {
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

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
