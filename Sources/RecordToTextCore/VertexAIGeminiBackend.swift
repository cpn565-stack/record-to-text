import Foundation

public enum VertexAIError: LocalizedError, Equatable {
    case invalidEndpointURL(String)
    case authenticationFailed(String)
    case audioPayloadTooLarge(sizeBytes: Int, limitBytes: Int)
    case requestFailed(statusCode: Int, message: String)
    case rateLimited(message: String, retryAfterSeconds: Double?)
    case quotaExceeded(String)
    case prohibitedContent(String)
    case promptBlocked(GeminiPromptBlockDiagnostics)
    case incompleteResponse(finishReason: String, message: String?)
    case emptyResponse
    case invalidJSONResponse
    case transportMessageTooLarge
    case gcsBucketRequired
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointURL(url):
            return "無效的 Vertex AI Endpoint URL：\(url)"
        case let .authenticationFailed(reason):
            return "Vertex AI 驗證失敗：\(reason)"
        case let .audioPayloadTooLarge(sizeBytes, limitBytes):
            let sizeMB = Double(sizeBytes) / (1024 * 1024)
            let limitMB = Double(limitBytes) / (1024 * 1024)
            return "音檔過大（\(String(format: "%.1f", sizeMB)) MB），超過直接傳輸上限（\(String(format: "%.1f", limitMB)) MB）。請設定 GCS Bucket 或縮短音檔長度。"
        case let .requestFailed(statusCode, message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Vertex AI 請求失敗（HTTP \(statusCode)）：\(trimmed)"
        case let .rateLimited(message, retryAfterSeconds):
            let delay = retryAfterSeconds.map { "，建議至少等待 \(String(format: "%.1f", $0)) 秒" } ?? ""
            return "Vertex AI 暫時達到速率限制\(delay)：\(message)"
        case let .quotaExceeded(message):
            return "Vertex AI 當日配額已用完，短時間重試不會成功：\(message)"
        case let .prohibitedContent(message):
            return "Google 內容安全政策攔截：\(message)"
        case let .promptBlocked(diagnostics):
            return diagnostics.userFacingMessage
        case let .incompleteResponse(finishReason, message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.map { "：\($0)" } ?? ""
            return "Vertex AI 回應未正常完成（\(finishReason)）\(suffix)。為避免輸出不完整逐字稿，本次工作已停止。"
        case .emptyResponse:
            return "Vertex AI 未回傳任何文字內容或候選結果。"
        case .invalidJSONResponse:
            return "Vertex AI 回傳的資料無法解讀為有效 JSON。"
        case .transportMessageTooLarge:
            return "連到 Google 的傳輸通道失敗（本機無法送出這包資料）。這不是音檔超過 Gemini 時長上限。請重試；若持續發生，需要改為先上傳音檔再轉錄。"
        case .gcsBucketRequired:
            return "Vertex AI 雲端轉錄需設定 GCS Bucket 以進行音訊上傳。請至設定填入 GCS Bucket 或改用 Google AI Studio 後端。"
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

public final class VertexAIGeminiBackend: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var projectID: String?
        public var location: String
        public var modelID: String
        public var gcsBucket: String?
        public var includeSummary: Bool
        public var thinkingLevel: GeminiThinkingLevel
        public var fallbackPolicy: CloudFallbackPolicy

        public init(
            projectID: String? = nil,
            location: String = "global",
            modelID: String = "gemini-3.7-flash",
            gcsBucket: String? = nil,
            includeSummary: Bool = false,
            thinkingLevel: GeminiThinkingLevel = .medium,
            fallbackPolicy: CloudFallbackPolicy = .disabled
        ) {
            self.projectID = projectID
            self.location = location
            self.modelID = modelID
            self.gcsBucket = gcsBucket
            self.includeSummary = includeSummary
            self.thinkingLevel = thinkingLevel
            self.fallbackPolicy = fallbackPolicy
        }

        public static let `default` = Configuration()
    }

    private var authService: GCloudAuthService
    private let urlSession: URLSession
    private let lock = NSLock()
    private var config: Configuration

    /// Inline Base64 限制通常建議在 20MB 以內
    public static let maximumInlineAudioBytes: Int = 20 * 1024 * 1024

    public init(
        authService: GCloudAuthService = GCloudAuthService(),
        urlSession: URLSession = .shared,
        configuration: Configuration = .default
    ) {
        self.authService = authService
        self.urlSession = urlSession
        self.config = configuration
    }

    public func updateConfiguration(_ newConfig: Configuration) {
        lock.withLock {
            config = newConfig
        }
    }

    public func updateAuthentication(
        customGCloudPath: String?,
        runner: ProcessRunner
    ) {
        lock.withLock {
            authService = GCloudAuthService(
                customGCloudPath: customGCloudPath,
                runner: runner
            )
        }
    }

    public func getConfiguration() -> Configuration {
        lock.withLock { config }
    }

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
        let authService = lock.withLock { self.authService }

        let resolvedProjectID: String
        if let explicitID = currentConfig.projectID,
           !explicitID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedProjectID = explicitID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        } else {
            do {
                resolvedProjectID = try await authService.getDefaultProjectID()
            } catch {
                throw VertexAIError.authenticationFailed(
                    "無法取得 GCP Project ID：\(error.localizedDescription)"
                )
            }
        }

        let accessToken: String
        do {
            accessToken = try await authService.getAccessToken()
        } catch {
            throw VertexAIError.authenticationFailed(error.localizedDescription)
        }

        let preparedAudio = try await prepareAudioPart(
            bucket: currentConfig.gcsBucket?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            authService: authService,
            accessToken: accessToken,
            audioData: audioData,
            mimeType: mimeType,
            workingDirectory: workingDirectory,
            logger: logger
        )

        let rawLocation = currentConfig.location
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let location = rawLocation.isEmpty ? "global" : rawLocation

        let result: CloudTranscriptionResult
        do {
            result = try await runTranscriptionAttempts(
                preferredModelID: currentConfig.modelID,
                projectID: resolvedProjectID,
                location: location,
                preparedAudio: preparedAudio.audioPart,
                accessToken: accessToken,
                authService: authService,
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
            await deletePreparedGCSObject(
                preparedAudio,
                accessToken: accessToken,
                authService: authService,
                logger: logger
            )
            throw error
        }
        await deletePreparedGCSObject(
            preparedAudio,
            accessToken: accessToken,
            authService: authService,
            logger: logger
        )
        return result
    }

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
        projectID: String,
        location: String,
        preparedAudio: [String: Any],
        accessToken: String,
        authService: GCloudAuthService,
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
                projectID: projectID,
                location: location,
                preparedAudio: preparedAudio,
                accessToken: accessToken,
                authService: authService,
                inputByteCount: audioByteCount,
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds,
                thinkingLevel: thinkingLevel,
                workingDirectory: workingDirectory,
                logger: logger
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VertexAIError {
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
                projectID: projectID,
                location: location,
                preparedAudio: preparedAudio,
                accessToken: accessToken,
                authService: authService,
                inputByteCount: audioByteCount,
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds,
                thinkingLevel: thinkingLevel,
                workingDirectory: workingDirectory,
                logger: logger
            )
        }
    }

    static func isRetryableServerFailure(_ error: VertexAIError) -> Bool {
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
        let gcsBucket: String?
        let gcsObjectName: String?
    }

    /// Uploads once per transcribe() call; retries reuse the result.
    private func prepareAudioPart(
        bucket: String?,
        authService: GCloudAuthService,
        accessToken: String,
        audioData: Data,
        mimeType: String,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> PreparedAudio {
        // 第二層優先：若有設定 GCS Bucket 則走 GCS 上傳
        if let bucket, !bucket.isEmpty {
            let objectName = "record_to_text_\(UUID().uuidString).mp3"
            logger?("info", "使用 GCS Bucket (\(bucket)) 串流上傳音訊...")

            do {
                try await uploadToGCS(
                    bucket: bucket,
                    objectName: objectName,
                    audioData: audioData,
                    mimeType: mimeType,
                    accessToken: accessToken,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
            } catch {
                await deleteGCSObjectShielded(
                    bucket: bucket,
                    objectName: objectName,
                    accessToken: accessToken,
                    authService: authService,
                    logger: logger
                )
                throw error
            }

            return PreparedAudio(
                audioPart: [
                    "fileData": [
                        "mimeType": mimeType,
                        "fileUri": "gs://\(bucket)/\(objectName)"
                    ]
                ],
                gcsBucket: bucket,
                gcsObjectName: objectName
            )
        }

        // 第一層路徑：Inline Base64 透過檔案串流 POST
        guard audioData.count <= Self.maximumInlineAudioBytes else {
            throw VertexAIError.audioPayloadTooLarge(
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
            gcsBucket: nil,
            gcsObjectName: nil
        )
    }

    private func deletePreparedGCSObject(
        _ prepared: PreparedAudio,
        accessToken: String,
        authService: GCloudAuthService,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async {
        guard let bucket = prepared.gcsBucket, let objectName = prepared.gcsObjectName else {
            return
        }
        await deleteGCSObjectShielded(
            bucket: bucket,
            objectName: objectName,
            accessToken: accessToken,
            authService: authService,
            logger: logger
        )
    }

    private func executeWithRetries(
        requestedModelID: String,
        effectiveModelID: String,
        fallbackReason: String?,
        priorRetryCount: Int,
        projectID: String,
        location: String,
        preparedAudio: [String: Any],
        accessToken: String,
        authService: GCloudAuthService,
        inputByteCount: Int,
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
                let generated = try await generateTranscript(
                    requestedModelID: requestedModelID,
                    effectiveModelID: effectiveModelID,
                    retryCount: priorRetryCount + attempt - 1,
                    fallbackReason: fallbackReason,
                    projectID: projectID,
                    location: location,
                    preparedAudio: preparedAudio,
                    accessToken: accessToken,
                    authService: authService,
                    inputByteCount: inputByteCount,
                    terms: terms,
                    customPrompt: customPrompt,
                    timeOffsetSeconds: timeOffsetSeconds,
                    thinkingLevel: thinkingLevel,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
                return generated.result
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as VertexAIError {
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
                    "Vertex Gemini \(effectiveModelID) 暫時忙碌，\(String(format: "%.1f", delay)) 秒後進行第 \(attempt + 1) 次嘗試。"
                )
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
        }

        if let lastError {
            throw lastError
        }
        throw VertexAIError.requestFailed(
            statusCode: 503,
            message: "伺服器忙碌，重試後仍失敗。"
        )
    }

    private func generateTranscript(
        requestedModelID: String,
        effectiveModelID: String,
        retryCount: Int,
        fallbackReason: String?,
        projectID: String,
        location: String,
        preparedAudio: [String: Any],
        accessToken: String,
        authService: GCloudAuthService,
        inputByteCount: Int,
        terms: [String],
        customPrompt: String,
        timeOffsetSeconds: Double,
        thinkingLevel: GeminiThinkingLevel,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> (result: CloudTranscriptionResult, accessToken: String) {
        let host = location == "global"
            ? "aiplatform.googleapis.com"
            : "\(location)-aiplatform.googleapis.com"
        let endpointString = "https://\(host)/v1/projects/\(projectID)/locations/\(location)/publishers/google/models/\(effectiveModelID):generateContent"
        guard let endpointURL = URL(string: endpointString) else {
            throw VertexAIError.invalidEndpointURL(endpointString)
        }

        return try await sendGenerateContentRequest(
            requestedModelID: requestedModelID,
            effectiveModelID: effectiveModelID,
            retryCount: retryCount,
            fallbackReason: fallbackReason,
            resolvedLocation: location,
            endpointURL: endpointURL,
            accessToken: accessToken,
            authService: authService,
            inputByteCount: inputByteCount,
            inputPart: preparedAudio,
            systemInstructionText: buildSystemInstruction(),
            userPromptText: buildUserPrompt(
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds
            ),
            requestDescription: "轉錄",
            maximumOutputTokens: 16_384,
            thinkingLevel: thinkingLevel,
            workingDirectory: workingDirectory,
            logger: logger
        )
    }

    /// 對已完成合併的逐字稿產生一次文字摘要。
    ///
    /// 這個 API 與音訊轉錄分開，避免每個音訊分段都各自摘要，
    /// 也確保逐字稿回應不會被摘要內容混入。
    func summarizeTranscript(
        _ transcript: String,
        workingDirectory: URL? = nil,
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) async throws -> String {
        let trimmedTranscript = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedTranscript.isEmpty else {
            throw VertexAIError.emptyResponse
        }

        let currentConfig = getConfiguration()
        let authService = lock.withLock { self.authService }
        let resolvedProjectID: String
        if let explicitID = currentConfig.projectID,
           !explicitID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedProjectID = explicitID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        } else {
            do {
                resolvedProjectID = try await authService.getDefaultProjectID()
            } catch {
                throw VertexAIError.authenticationFailed(
                    "無法取得 GCP Project ID：\(error.localizedDescription)"
                )
            }
        }

        let accessToken: String
        do {
            accessToken = try await authService.getAccessToken()
        } catch {
            throw VertexAIError.authenticationFailed(error.localizedDescription)
        }

        let resolvedLocation = currentConfig.location
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let location = resolvedLocation.isEmpty ? "global" : resolvedLocation
        let host = location == "global"
            ? "aiplatform.googleapis.com"
            : "\(location)-aiplatform.googleapis.com"
        let endpointString = "https://\(host)/v1/projects/\(resolvedProjectID)/locations/\(location)/publishers/google/models/\(currentConfig.modelID):generateContent"
        guard let endpointURL = URL(string: endpointString) else {
            throw VertexAIError.invalidEndpointURL(endpointString)
        }

        let result = try await sendGenerateContentRequest(
            requestedModelID: currentConfig.modelID,
            effectiveModelID: currentConfig.modelID,
            retryCount: 0,
            fallbackReason: nil,
            resolvedLocation: location,
            endpointURL: endpointURL,
            accessToken: accessToken,
            authService: authService,
            inputByteCount: trimmedTranscript.utf8.count,
            inputPart: ["text": trimmedTranscript],
            systemInstructionText: """
你是逐字稿摘要工具。請根據完整逐字稿整理精簡、忠於原文的繁體中文摘要。不得補充原文沒有的事實，不使用 Markdown，不要輸出「摘要：」前綴。
""",
            userPromptText: "請直接輸出這份完整逐字稿的精簡摘要。",
            requestDescription: "摘要",
            maximumOutputTokens: 2_048,
            thinkingLevel: currentConfig.thinkingLevel,
            workingDirectory: workingDirectory,
            logger: logger
        )
        return result.result.text
    }

    private func sendGenerateContentRequest(
        requestedModelID: String,
        effectiveModelID: String,
        retryCount: Int,
        fallbackReason: String?,
        resolvedLocation: String,
        endpointURL: URL,
        accessToken: String,
        authService: GCloudAuthService,
        inputByteCount: Int,
        inputPart: [String: Any],
        systemInstructionText: String,
        userPromptText: String,
        requestDescription: String,
        maximumOutputTokens: Int,
        thinkingLevel: GeminiThinkingLevel,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> (result: CloudTranscriptionResult, accessToken: String) {
        var resolvedAccessToken = accessToken
        let generationConfig = GeminiGenerationConfig.make(
            maxOutputTokens: maximumOutputTokens,
            modelID: effectiveModelID,
            thinkingLevel: thinkingLevel
        )
        logger?(
            "info",
            "轉錄請求送出 thinkingConfig=\(thinkingLevel.rawValue)（模型 \(effectiveModelID)）。"
        )
        let requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemInstructionText]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        inputPart,
                        ["text": userPromptText]
                    ]
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

        // 將請求寫入工作暫存檔進行串流上傳，禁止整包塞進 URLRequest.httpBody
        let tempRequestFile = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: requestData,
            in: workingDirectory,
            prefix: "vertex_generate"
        )
        defer {
            try? FileManager.default.removeItem(at: tempRequestFile)
        }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(resolvedAccessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300 // 5 分鐘超時

        let startedAt = Date()
        var (data, httpResponse) = try await sendWithPOSIXRetry(
            request: urlRequest,
            fileURL: tempRequestFile,
            session: urlSession,
            logger: logger
        )

        // 若遇 401 Token 過期，自動刷新並重試一次
        if httpResponse.statusCode == 401 {
            authService.invalidateToken()
            do {
                let freshToken = try await authService.getAccessToken(forceRefresh: true)
                resolvedAccessToken = freshToken
                urlRequest.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                let retryResult = try await sendWithPOSIXRetry(
                    request: urlRequest,
                    fileURL: tempRequestFile,
                    session: urlSession,
                    logger: logger
                )
                data = retryResult.0
                httpResponse = retryResult.1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw VertexAIError.authenticationFailed(
                    "Access Token 已失效，重新驗證仍失敗：\(error.localizedDescription)"
                )
            }
        }

        logger?(
            "info",
            "Vertex AI \(requestDescription)回應：HTTP \(httpResponse.statusCode)，輸入 \(inputByteCount) bytes，JSON \(requestData.count) bytes，要求 \(requestedModelID)，實際請求 \(effectiveModelID)，location \(resolvedLocation)。"
        )

        guard httpResponse.statusCode == 200 else {
            let errorMsg = parseErrorMessage(from: data)
            if httpResponse.statusCode == 429 {
                if GeminiTransportHelper.isDailyQuotaExceeded(
                    data: data,
                    message: errorMsg
                ) {
                    throw VertexAIError.quotaExceeded(errorMsg)
                }
                throw VertexAIError.rateLimited(
                    message: errorMsg,
                    retryAfterSeconds: GeminiTransportHelper.retryAfterSeconds(
                        response: httpResponse,
                        data: data
                    )
                )
            }
            throw VertexAIError.requestFailed(
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
            latencySeconds: Date().timeIntervalSince(startedAt)
        )
        return (
            CloudTranscriptionResult(text: text, metadata: metadata),
            resolvedAccessToken
        )
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
                throw VertexAIError.invalidJSONResponse
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
                        throw VertexAIError.invalidJSONResponse
                    }
                    logger?("info", "傳輸通道重試成功（HTTP \(httpResponse.statusCode)）。")
                    return (data, httpResponse)
                } catch let retryError {
                    if GeminiTransportHelper.isPOSIXMessageTooLarge(retryError) {
                        logger?("warning", "重試後仍為 POSIX 40 傳輸失敗。")
                        throw VertexAIError.transportMessageTooLarge
                    }
                    throw retryError
                }
            } else {
                throw error
            }
        }
    }

    /// 上傳音檔至 Google Cloud Storage
    private func uploadToGCS(
        bucket: String,
        objectName: String,
        audioData: Data,
        mimeType: String,
        accessToken: String,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws {
        let tempAudioFile = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: audioData,
            in: workingDirectory,
            prefix: "gcs_audio"
        )
        defer {
            try? FileManager.default.removeItem(at: tempAudioFile)
        }

        guard let encodedName = objectName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let uploadURL = URL(string: "https://storage.googleapis.com/upload/storage/v1/b/\(bucket)/o?uploadType=media&name=\(encodedName)") else {
            throw VertexAIError.invalidEndpointURL("GCS Upload URL 格式錯誤")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(audioData.count)", forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 300

        let (data, httpResponse) = try await sendWithPOSIXRetry(
            request: request,
            fileURL: tempAudioFile,
            session: urlSession,
            logger: logger
        )

        if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            let errorMsg = parseErrorMessage(from: data)
            throw VertexAIError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: "GCS 音訊上傳失敗：\(errorMsg)"
            )
        }
    }

    /// 刪除 GCS 遠端暫存物件
    private func deleteGCSObjectShielded(
        bucket: String,
        objectName: String,
        accessToken: String,
        authService: GCloudAuthService,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async {
        let cleanupFailure = await Task.detached(priority: .utility) { [self] in
            // A generateContent 401 may have refreshed the cached token before
            // a later retry failed. Resolve inside the detached cleanup task so
            // cancellation cannot force DELETE to reuse the stale token.
            let cleanupToken = (try? await authService.getAccessToken())
                ?? accessToken
            return await deleteGCSObject(
                bucket: bucket,
                objectName: objectName,
                accessToken: cleanupToken
            )
        }.value
        if let cleanupFailure {
            logger?("warning", "清理 GCS 暫存檔 (\(objectName)) 失敗：\(cleanupFailure)")
        }
    }

    private func deleteGCSObject(
        bucket: String,
        objectName: String,
        accessToken: String
    ) async -> String? {
        guard let encodedName = objectName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let deleteURL = URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encodedName)") else {
            return "無法建立 DELETE URL"
        }

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 || httpResponse.statusCode == 404 {
                    return nil
                }
                return "HTTP \(httpResponse.statusCode)"
            }
            return "Google Cloud Storage 未回傳有效的 HTTP 回應"
        } catch {
            return error.localizedDescription
        }
    }

    func buildSystemInstruction() -> String {
        GeminiTranscriptPrompt.systemInstruction
    }

    func buildUserPrompt(
        terms: [String],
        customPrompt: String,
        timeOffsetSeconds: Double
    ) -> String {
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
            throw VertexAIError.invalidJSONResponse
        }

        if let diagnostics = GeminiPromptFeedbackParser.diagnosticsIfBlocked(
            from: json,
            httpStatusCode: httpStatusCode
        ) {
            logger?("warning", diagnostics.logSummary)
            throw VertexAIError.promptBlocked(diagnostics)
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
            throw VertexAIError.emptyResponse
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
            throw VertexAIError.incompleteResponse(
                finishReason: "MISSING_FINISH_REASON",
                message: firstCandidate["finishMessage"] as? String
            )
        }
        let normalizedFinishReason = GeminiTranscriptFinishReason.normalized(finishReason)
        if GeminiTranscriptFinishReason.isSafetyBlock(normalizedFinishReason) {
            throw VertexAIError.prohibitedContent(
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
            throw VertexAIError.emptyResponse
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
            throw VertexAIError.emptyResponse
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
            throw VertexAIError.incompleteResponse(
                finishReason: normalizedFinishReason,
                message: firstCandidate["finishMessage"] as? String
            )
        }
        return sanitized
    }

    /// 淨化逐字稿：去除 Markdown 標題、粗體符號、分隔線及偶發之重複草稿開頭
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
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
