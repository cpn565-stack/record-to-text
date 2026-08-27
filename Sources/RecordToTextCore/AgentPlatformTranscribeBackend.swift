import Foundation

public enum AgentPlatformTranscribeError: LocalizedError, Equatable {
    case authenticationFailed(String)
    case invalidConfiguration(String)
    case invalidEndpoint(String)
    case gcsBucketRequired(sizeBytes: Int, limitBytes: Int)
    case requestFailed(statusCode: Int, message: String)
    case incompleteResponse(finishReason: String, message: String?)
    case invalidResponse(String)
    case emptyResponse
    case transportMessageTooLarge

    public var errorDescription: String? {
        switch self {
        case let .authenticationFailed(message):
            return "gcloud / Google Cloud 驗證失敗：\(message)"
        case let .invalidConfiguration(message):
            return "Gemini 3.5 Transcribe Preview 設定無效：\(message)"
        case let .invalidEndpoint(endpoint):
            return "無法建立 Agent Platform endpoint：\(endpoint)"
        case let .gcsBucketRequired(sizeBytes, limitBytes):
            let size = Double(sizeBytes) / 1_048_576
            let limit = Double(limitBytes) / 1_048_576
            return "音訊約 \(String(format: "%.1f", size)) MB，超過 inline 上限 \(String(format: "%.1f", limit)) MB；請設定 GCS Bucket。"
        case let .requestFailed(statusCode, message):
            return "Gemini 3.5 Transcribe Preview 請求失敗（HTTP \(statusCode)）：\(message)"
        case let .incompleteResponse(finishReason, message):
            let suffix = message.map { "：\($0)" } ?? ""
            return "專用轉錄回應未正常完成（\(finishReason)）\(suffix)。"
        case let .invalidResponse(message):
            return "專用轉錄回應格式無法解讀：\(message)"
        case .emptyResponse:
            return "Gemini 3.5 Transcribe Preview 未回傳任何逐字稿文字。"
        case .transportMessageTooLarge:
            return "連到 Google Cloud 的本機傳輸通道失敗（POSIX 40），使用乾淨連線重試後仍未成功。"
        }
    }
}

/// gcloud-authenticated Gemini 3.5 Transcribe Preview transport.
///
/// The preview model uses the Agent Platform audio transcription contract,
/// not the normal prompt-driven Gemini transcription path. The effective
/// location is always `global`; requests use `v1beta1` and
/// `generationConfig.audioTranscriptionConfig`.
public final class AgentPlatformTranscribeBackend: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var projectID: String?
        public var modelID: String
        public var gcsBucket: String?
        public var options: DedicatedTranscriptionOptions

        public init(
            projectID: String? = nil,
            modelID: String = "gemini-3.5-transcribe-preview",
            gcsBucket: String? = nil,
            options: DedicatedTranscriptionOptions = .default
        ) {
            self.projectID = projectID
            self.modelID = modelID
            self.gcsBucket = gcsBucket
            self.options = options
        }

        public static let `default` = Configuration()
    }

    private struct PreparedAudio: Sendable {
        let inputPart: [String: SendableValue]
        let gcsBucket: String?
        let gcsObjectName: String?
    }

    /// Small value wrapper that keeps prepared request dictionaries Sendable.
    private enum SendableValue: @unchecked Sendable {
        case string(String)
        case object([String: SendableValue])

        var jsonValue: Any {
            switch self {
            case let .string(value):
                return value
            case let .object(value):
                return value.mapValues(\.jsonValue)
            }
        }
    }

    public static let maximumInlineAudioBytes = 20 * 1_024 * 1_024

    private let urlSession: URLSession
    private let lock = NSLock()
    private var configuration: Configuration
    private var authService: GCloudAuthService

    public init(
        authService: GCloudAuthService = GCloudAuthService(),
        urlSession: URLSession = .shared,
        configuration: Configuration = .default
    ) {
        self.authService = authService
        self.urlSession = urlSession
        self.configuration = configuration
    }

    public func updateConfiguration(_ value: Configuration) {
        lock.withLock {
            configuration = value
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
        lock.withLock { configuration }
    }

    public func transcribe(
        audioData: Data,
        mimeType: String = "audio/mp3",
        customVocabulary: [String] = [],
        workingDirectory: URL? = nil,
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) async throws -> CloudTranscriptionResult {
        let current = getConfiguration()
        let auth = lock.withLock { authService }
        let descriptor = CloudModelCatalog.resolvedDescriptor(
            provider: .vertexAI,
            modelID: current.modelID
        )
        guard descriptor.transport == .agentPlatformTranscribe else {
            throw AgentPlatformTranscribeError.invalidConfiguration(
                "模型 \(current.modelID) 不是 Agent Platform Transcribe 模型。"
            )
        }
        let normalizedOptions = current.options.normalizedForUI()
        let vocabulary: [String]
        do {
            vocabulary = try CloudTranscriptionPolicy.normalizedVocabulary(
                customVocabulary
            )
            try CloudTranscriptionPolicy.validate(
                descriptor: descriptor,
                options: normalizedOptions,
                vocabulary: vocabulary
            )
        } catch {
            throw AgentPlatformTranscribeError.invalidConfiguration(
                error.localizedDescription
            )
        }

        let projectID: String
        if let explicit = current.projectID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            projectID = explicit
        } else {
            do {
                projectID = try await auth.getDefaultProjectID()
            } catch {
                throw AgentPlatformTranscribeError.authenticationFailed(
                    error.localizedDescription
                )
            }
        }

        let accessToken: String
        do {
            accessToken = try await auth.getAccessToken()
        } catch {
            throw AgentPlatformTranscribeError.authenticationFailed(
                error.localizedDescription
            )
        }

        let prepared = try await prepareAudio(
            bucket: current.gcsBucket?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: accessToken,
            audioData: audioData,
            mimeType: mimeType,
            workingDirectory: workingDirectory,
            logger: logger
        )

        do {
            let result = try await executeWithRetries(
                projectID: projectID,
                descriptor: descriptor,
                preparedAudio: prepared,
                accessToken: accessToken,
                authService: auth,
                options: normalizedOptions,
                customVocabulary: vocabulary,
                audioByteCount: audioData.count,
                workingDirectory: workingDirectory,
                logger: logger
            )
            await deletePreparedGCSObject(
                prepared,
                fallbackAccessToken: accessToken,
                authService: auth,
                logger: logger
            )
            return result
        } catch {
            await deletePreparedGCSObject(
                prepared,
                fallbackAccessToken: accessToken,
                authService: auth,
                logger: logger
            )
            throw error
        }
    }

    private func executeWithRetries(
        projectID: String,
        descriptor: CloudModelDescriptor,
        preparedAudio: PreparedAudio,
        accessToken: String,
        authService: GCloudAuthService,
        options: DedicatedTranscriptionOptions,
        customVocabulary: [String],
        audioByteCount: Int,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        var token = accessToken
        var lastError: Error?
        for attempt in 1...GeminiTransportHelper.RetryPolicy.maximumAttempts {
            do {
                try Task.checkCancellation()
                let response = try await sendRequest(
                    projectID: projectID,
                    descriptor: descriptor,
                    preparedAudio: preparedAudio,
                    accessToken: token,
                    authService: authService,
                    options: options,
                    customVocabulary: customVocabulary,
                    audioByteCount: audioByteCount,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
                token = response.accessToken
                return response.result
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as AgentPlatformTranscribeError {
                guard case let .requestFailed(statusCode, _) = error,
                      Self.isRetryableStatus(statusCode) else {
                    throw error
                }
                lastError = error
                if attempt < GeminiTransportHelper.RetryPolicy.maximumAttempts {
                    let seconds = GeminiTransportHelper.RetryPolicy
                        .backoffSeconds(forAttempt: attempt)
                    logger?(
                        "info",
                        "Agent Platform Transcribe HTTP \(statusCode)，\(Int(seconds)) 秒後進行第 \(attempt + 1) 次同模型重試。"
                    )
                    try await Task.sleep(
                        nanoseconds: UInt64(seconds * 1_000_000_000)
                    )
                }
            }
        }
        if let lastError { throw lastError }
        throw AgentPlatformTranscribeError.requestFailed(
            statusCode: 503,
            message: "伺服器忙碌，重試後仍失敗。"
        )
    }

    static func isRetryableStatus(_ statusCode: Int) -> Bool {
        [429, 500, 502, 503].contains(statusCode)
    }

    func endpoint(
        projectID: String,
        descriptor: CloudModelDescriptor
    ) throws -> URL {
        let location = descriptor.requiredLocation ?? "global"
        let value = "https://aiplatform.googleapis.com/\(descriptor.apiVersion)/projects/\(projectID)/locations/\(location)/publishers/google/models/\(descriptor.id):generateContent"
        guard let url = URL(string: value) else {
            throw AgentPlatformTranscribeError.invalidEndpoint(value)
        }
        return url
    }

    func buildRequestBody(
        inputPart: [String: Any],
        options: DedicatedTranscriptionOptions,
        customVocabulary: [String]
    ) -> [String: Any] {
        var transcriptionConfig: [String: Any] = [:]
        if !options.resolvedLanguageCodes.isEmpty {
            transcriptionConfig["languageCodes"] = options.resolvedLanguageCodes
        }
        if !customVocabulary.isEmpty {
            transcriptionConfig["customVocabulary"] = customVocabulary
        }
        transcriptionConfig["mode"] = options.mode == .smart
            ? "SMART"
            : "VERBATIM"
        transcriptionConfig["wordTimestamp"] = options.wordTimestampsEnabled
        transcriptionConfig["diarization"] = options.diarizationEnabled

        return [
            "contents": [
                [
                    "role": "user",
                    "parts": [inputPart]
                ]
            ],
            "generationConfig": [
                "audioTranscriptionConfig": transcriptionConfig
            ]
        ]
    }

    private func sendRequest(
        projectID: String,
        descriptor: CloudModelDescriptor,
        preparedAudio: PreparedAudio,
        accessToken: String,
        authService: GCloudAuthService,
        options: DedicatedTranscriptionOptions,
        customVocabulary: [String],
        audioByteCount: Int,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> (result: CloudTranscriptionResult, accessToken: String) {
        let endpoint = try endpoint(
            projectID: projectID,
            descriptor: descriptor
        )
        let body = buildRequestBody(
            inputPart: preparedAudio.inputPart.mapValues(\.jsonValue),
            options: options,
            customVocabulary: customVocabulary
        )
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let requestFile = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: bodyData,
            in: workingDirectory,
            prefix: "agent_transcribe"
        )
        defer { try? FileManager.default.removeItem(at: requestFile) }

        var token = accessToken
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 300

        var (data, response) = try await sendWithPOSIXRetry(
            request: request,
            fileURL: requestFile,
            session: urlSession,
            logger: logger
        )
        if response.statusCode == 401 {
            authService.invalidateToken()
            do {
                token = try await authService.getAccessToken(forceRefresh: true)
            } catch {
                throw AgentPlatformTranscribeError.authenticationFailed(
                    "Access Token 已失效，重新取得仍失敗：\(error.localizedDescription)"
                )
            }
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
            (data, response) = try await sendWithPOSIXRetry(
                request: request,
                fileURL: requestFile,
                session: urlSession,
                logger: logger
            )
        }

        logger?(
            "info",
            "Agent Platform Transcribe 回應：HTTP \(response.statusCode)，音訊 \(audioByteCount) bytes，模型 \(descriptor.id)，location global。"
        )
        guard response.statusCode == 200 else {
            throw AgentPlatformTranscribeError.requestFailed(
                statusCode: response.statusCode,
                message: parseErrorMessage(data)
            )
        }
        return (
            try parseResponse(data, modelID: descriptor.id),
            token
        )
    }

    func parseResponse(
        _ data: Data,
        modelID: String = "gemini-3.5-transcribe-preview"
    ) throws -> CloudTranscriptionResult {
        guard let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            throw AgentPlatformTranscribeError.invalidResponse(
                "缺少 candidates。"
            )
        }
        let finishReason = (candidate["finishReason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let finishMessage = candidate["finishMessage"] as? String
        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AgentPlatformTranscribeError.emptyResponse
        }

        var textChunks: [String] = []
        var words: [TimedWord] = []
        var turns: [SpeakerTurn] = []
        var languageCodes: [String] = []
        var hasStructuredTranscription = false

        for part in parts {
            let transcription = (part["audioTranscription"]
                ?? part["audio_transcription"]) as? [String: Any]
            if let transcription {
                hasStructuredTranscription = true
                let text = (transcription["text"] as? String) ?? ""
                if !text.isEmpty {
                    textChunks.append(text)
                }
                if let language = (transcription["languageCode"]
                    ?? transcription["language_code"]) as? String {
                    appendUnique(language, to: &languageCodes)
                }
                let speaker = (transcription["speakerLabel"]
                    ?? transcription["speaker_label"]) as? String
                if let rawWords = transcription["words"] as? [[String: Any]] {
                    for rawWord in rawWords {
                        let word = (rawWord["word"] as? String)
                            ?? (rawWord["text"] as? String)
                            ?? ""
                        guard !word.isEmpty else { continue }
                        words.append(
                            TimedWord(
                                text: word,
                                speaker: (rawWord["speakerLabel"]
                                    ?? rawWord["speaker_label"]) as? String
                                    ?? speaker,
                                startSeconds: GoogleDurationParser.seconds(
                                    from: rawWord["startOffset"]
                                        ?? rawWord["start_offset"]
                                        ?? rawWord["startTime"]
                                ),
                                endSeconds: GoogleDurationParser.seconds(
                                    from: rawWord["endOffset"]
                                        ?? rawWord["end_offset"]
                                        ?? rawWord["endTime"]
                                )
                            )
                        )
                    }
                }
                if let speaker, !speaker.isEmpty, !text.isEmpty,
                   words.isEmpty {
                    turns.append(
                        SpeakerTurn(
                            speaker: speaker,
                            text: text
                        )
                    )
                }
            } else if let text = part["text"] as? String,
                      !text.isEmpty {
                textChunks.append(text)
            }
        }

        if let finishReason, !finishReason.isEmpty, finishReason != "STOP" {
            throw AgentPlatformTranscribeError.incompleteResponse(
                finishReason: finishReason,
                message: finishMessage
            )
        }
        if finishReason == nil, !hasStructuredTranscription {
            throw AgentPlatformTranscribeError.incompleteResponse(
                finishReason: "MISSING_FINISH_REASON",
                message: finishMessage
            )
        }

        let text = textChunks
            .joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgentPlatformTranscribeError.emptyResponse
        }
        if turns.isEmpty {
            turns = GoogleAIStudioTranscribeBackend.buildSpeakerTurns(
                from: words
            )
        }
        return CloudTranscriptionResult(
            text: text,
            modelID: modelID,
            transport: .agentPlatformTranscribe,
            detectedLanguageCodes: languageCodes,
            speakerTurns: turns,
            words: words,
            providerResponseID: json["responseId"] as? String
                ?? json["response_id"] as? String
        )
    }

    private func prepareAudio(
        bucket: String?,
        accessToken: String,
        audioData: Data,
        mimeType: String,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> PreparedAudio {
        if let bucket, !bucket.isEmpty {
            let objectName = "record-to-text-\(UUID().uuidString).mp3"
            logger?("info", "上傳專用轉錄音訊至 GCS Bucket \(bucket)。")
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
                _ = await deleteGCSObject(
                    bucket: bucket,
                    objectName: objectName,
                    accessToken: accessToken
                )
                throw error
            }
            return PreparedAudio(
                inputPart: [
                    "fileData": .object([
                        "mimeType": .string(mimeType),
                        "fileUri": .string("gs://\(bucket)/\(objectName)")
                    ])
                ],
                gcsBucket: bucket,
                gcsObjectName: objectName
            )
        }

        guard audioData.count <= Self.maximumInlineAudioBytes else {
            throw AgentPlatformTranscribeError.gcsBucketRequired(
                sizeBytes: audioData.count,
                limitBytes: Self.maximumInlineAudioBytes
            )
        }
        return PreparedAudio(
            inputPart: [
                "inlineData": .object([
                    "mimeType": .string(mimeType),
                    "data": .string(audioData.base64EncodedString())
                ])
            ],
            gcsBucket: nil,
            gcsObjectName: nil
        )
    }

    private func uploadToGCS(
        bucket: String,
        objectName: String,
        audioData: Data,
        mimeType: String,
        accessToken: String,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws {
        let tempAudio = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: audioData,
            in: workingDirectory,
            prefix: "agent_gcs_audio"
        )
        defer { try? FileManager.default.removeItem(at: tempAudio) }
        guard let encoded = objectName.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ),
        let endpoint = URL(
            string: "https://storage.googleapis.com/upload/storage/v1/b/\(bucket)/o?uploadType=media&name=\(encoded)"
        ) else {
            throw AgentPlatformTranscribeError.invalidEndpoint(
                "GCS upload"
            )
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\(audioData.count)",
            forHTTPHeaderField: "Content-Length"
        )
        request.timeoutInterval = 300
        let (data, response) = try await sendWithPOSIXRetry(
            request: request,
            fileURL: tempAudio,
            session: urlSession,
            logger: logger
        )
        guard (200..<300).contains(response.statusCode) else {
            throw AgentPlatformTranscribeError.requestFailed(
                statusCode: response.statusCode,
                message: "GCS 音訊上傳失敗：\(parseErrorMessage(data))"
            )
        }
    }

    private func deletePreparedGCSObject(
        _ prepared: PreparedAudio,
        fallbackAccessToken: String,
        authService: GCloudAuthService,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async {
        guard let bucket = prepared.gcsBucket,
              let objectName = prepared.gcsObjectName else {
            return
        }
        let failure = await Task.detached(priority: .utility) { [self] in
            let token = (try? await authService.getAccessToken())
                ?? fallbackAccessToken
            return await deleteGCSObject(
                bucket: bucket,
                objectName: objectName,
                accessToken: token
            )
        }.value
        if let failure {
            logger?(
                "warning",
                "清理 GCS 暫存音訊（\(objectName)）失敗：\(failure)"
            )
        }
    }

    private func deleteGCSObject(
        bucket: String,
        objectName: String,
        accessToken: String
    ) async -> String? {
        guard let encoded = objectName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ),
        let endpoint = URL(
            string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encoded)"
        ) else {
            return "無法建立 GCS DELETE endpoint"
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.timeoutInterval = 30
        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "GCS 未回傳有效 HTTP 回應"
            }
            return [200, 204, 404].contains(http.statusCode)
                ? nil
                : "HTTP \(http.statusCode)"
        } catch {
            return error.localizedDescription
        }
    }

    private func sendWithPOSIXRetry(
        request: URLRequest,
        fileURL: URL,
        session: URLSession,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.upload(
                for: request,
                fromFile: fileURL
            )
            guard let http = response as? HTTPURLResponse else {
                throw AgentPlatformTranscribeError.invalidResponse(
                    "沒有有效 HTTP 回應。"
                )
            }
            return (data, http)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard GeminiTransportHelper.isPOSIXMessageTooLarge(error) else {
                throw error
            }
            logger?("info", "遇到 POSIX 40，改用全新 TCP/Ephemeral 連線重試。")
            let retrySession = GeminiTransportHelper.makeEphemeralRetrySession(
                protocolClasses: session.configuration.protocolClasses
            )
            defer { retrySession.finishTasksAndInvalidate() }
            var retryRequest = request
            retryRequest.assumesHTTP3Capable = false
            do {
                let (data, response) = try await retrySession.upload(
                    for: retryRequest,
                    fromFile: fileURL
                )
                guard let http = response as? HTTPURLResponse else {
                    throw AgentPlatformTranscribeError.invalidResponse(
                        "重試沒有有效 HTTP 回應。"
                    )
                }
                return (data, http)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if GeminiTransportHelper.isPOSIXMessageTooLarge(error) {
                    throw AgentPlatformTranscribeError.transportMessageTooLarge
                }
                throw error
            }
        }
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !values.contains(where: {
                  $0.caseInsensitiveCompare(normalized) == .orderedSame
              }) else {
            return
        }
        values.append(normalized)
    }

    private func parseErrorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
