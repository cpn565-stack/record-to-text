import Foundation

public enum GoogleAIStudioTranscribeError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidConfiguration(String)
    case requestFailed(statusCode: Int, message: String)
    case fileUploadFailed(String)
    case fileProcessingTimedOut
    case interactionNotCompleted(status: String, message: String?)
    case invalidResponse(String)
    case emptyResponse
    case transportMessageTooLarge

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未設定 Google AI Studio API Key。"
        case let .invalidConfiguration(message):
            return "Gemini 3.5 Transcribe 設定無效：\(message)"
        case let .requestFailed(statusCode, message):
            return "Gemini 3.5 Transcribe 請求失敗（HTTP \(statusCode)）：\(message)"
        case let .fileUploadFailed(message):
            return "Google AI Studio 音訊上傳失敗：\(message)"
        case .fileProcessingTimedOut:
            return "Google AI Studio 音訊檔案處理超時，請稍後重試。"
        case let .interactionNotCompleted(status, message):
            let suffix = message.map { "：\($0)" } ?? ""
            return "Gemini 3.5 Transcribe 工作未正常完成（\(status)）\(suffix)。"
        case let .invalidResponse(message):
            return "Gemini 3.5 Transcribe 回應格式無法解讀：\(message)"
        case .emptyResponse:
            return "Gemini 3.5 Transcribe 未回傳任何逐字稿文字。"
        case .transportMessageTooLarge:
            return "連到 Google 的本機傳輸通道失敗（POSIX 40）。已改用乾淨連線重試，但仍未成功。"
        }
    }
}

/// Dedicated pre-recorded transcription transport for the Gemini API.
///
/// This backend deliberately does not reuse `generateContent`: Gemini 3.5
/// Transcribe is exposed through the Interactions API and has a distinct
/// request/response contract. Audio is uploaded once through Files API and is
/// reused by all same-model retries; the remote file is deleted before this
/// method returns, including cancellation and error paths.
public final class GoogleAIStudioTranscribeBackend: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var apiKey: String?
        public var modelID: String
        public var options: DedicatedTranscriptionOptions

        public init(
            apiKey: String? = nil,
            modelID: String = "gemini-3.5-transcribe",
            options: DedicatedTranscriptionOptions = .default
        ) {
            self.apiKey = apiKey
            self.modelID = modelID
            self.options = options
        }

        public static let `default` = Configuration()
    }

    private struct UploadedFile: Sendable {
        let uri: String
        let name: String
    }

    private let urlSession: URLSession
    private let lock = NSLock()
    private var configuration: Configuration

    public init(
        urlSession: URLSession = .shared,
        configuration: Configuration = .default
    ) {
        self.urlSession = urlSession
        self.configuration = configuration
    }

    public func updateConfiguration(_ value: Configuration) {
        lock.withLock {
            configuration = value
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
        guard let apiKey = current.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw GoogleAIStudioTranscribeError.missingAPIKey
        }

        let descriptor = CloudModelCatalog.resolvedDescriptor(
            provider: .googleAIStudio,
            modelID: current.modelID
        )
        guard descriptor.transport == .geminiInteractionsTranscribe else {
            throw GoogleAIStudioTranscribeError.invalidConfiguration(
                "模型 \(current.modelID) 不是 Interactions Transcribe 模型。"
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
            throw GoogleAIStudioTranscribeError.invalidConfiguration(
                error.localizedDescription
            )
        }

        let uploaded = try await uploadFile(
            apiKey: apiKey,
            audioData: audioData,
            mimeType: mimeType,
            workingDirectory: workingDirectory,
            logger: logger
        )

        do {
            let result = try await executeWithRetries(
                apiKey: apiKey,
                modelID: current.modelID,
                uploadedFile: uploaded,
                mimeType: mimeType,
                options: normalizedOptions,
                customVocabulary: vocabulary,
                audioByteCount: audioData.count,
                workingDirectory: workingDirectory,
                logger: logger
            )
            await deleteFileShielded(
                apiKey: apiKey,
                fileName: uploaded.name,
                logger: logger
            )
            return result
        } catch {
            await deleteFileShielded(
                apiKey: apiKey,
                fileName: uploaded.name,
                logger: logger
            )
            throw error
        }
    }

    private func executeWithRetries(
        apiKey: String,
        modelID: String,
        uploadedFile: UploadedFile,
        mimeType: String,
        options: DedicatedTranscriptionOptions,
        customVocabulary: [String],
        audioByteCount: Int,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        var lastError: Error?
        for attempt in 1...GeminiTransportHelper.RetryPolicy.maximumAttempts {
            do {
                try Task.checkCancellation()
                return try await sendInteraction(
                    apiKey: apiKey,
                    modelID: modelID,
                    uploadedFile: uploadedFile,
                    mimeType: mimeType,
                    options: options,
                    customVocabulary: customVocabulary,
                    audioByteCount: audioByteCount,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as GoogleAIStudioTranscribeError {
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
                        "Gemini Transcribe HTTP \(statusCode)，\(Int(seconds)) 秒後進行第 \(attempt + 1) 次同模型重試。"
                    )
                    try await Task.sleep(
                        nanoseconds: UInt64(seconds * 1_000_000_000)
                    )
                }
            }
        }
        if let lastError {
            throw lastError
        }
        throw GoogleAIStudioTranscribeError.requestFailed(
            statusCode: 503,
            message: "伺服器忙碌，重試後仍失敗。"
        )
    }

    static func isRetryableStatus(_ statusCode: Int) -> Bool {
        [429, 500, 502, 503].contains(statusCode)
    }

    func buildInteractionRequestBody(
        modelID: String,
        fileURI: String,
        mimeType: String,
        options: DedicatedTranscriptionOptions,
        customVocabulary: [String]
    ) -> [String: Any] {
        var transcriptionConfig: [String: Any] = [:]
        let languageCodes = options.resolvedLanguageCodes
        if !languageCodes.isEmpty {
            transcriptionConfig["language_codes"] = languageCodes
        }
        if !customVocabulary.isEmpty {
            transcriptionConfig["custom_vocabulary"] = customVocabulary
        }

        var mode: [String: Any] = ["type": options.mode.rawValue]
        if options.mode == .verbatim {
            if options.diarizationEnabled {
                mode["diarization_mode"] = "speaker"
            }
            if options.wordTimestampsEnabled {
                mode["timestamp_granularities"] = ["word"]
            }
        }
        transcriptionConfig["mode"] = mode

        return [
            "model": modelID,
            "input": [
                [
                    "type": "audio",
                    "uri": fileURI,
                    "mime_type": mimeType
                ]
            ],
            "generation_config": [
                "transcription_config": transcriptionConfig
            ]
        ]
    }

    private func sendInteraction(
        apiKey: String,
        modelID: String,
        uploadedFile: UploadedFile,
        mimeType: String,
        options: DedicatedTranscriptionOptions,
        customVocabulary: [String],
        audioByteCount: Int,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> CloudTranscriptionResult {
        guard let endpoint = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/interactions"
        ) else {
            throw GoogleAIStudioTranscribeError.invalidResponse(
                "無法建立 Interactions endpoint。"
            )
        }
        let body = buildInteractionRequestBody(
            modelID: modelID,
            fileURI: uploadedFile.uri,
            mimeType: mimeType,
            options: options,
            customVocabulary: customVocabulary
        )
        let data = try JSONSerialization.data(withJSONObject: body)
        let requestFile = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: data,
            in: workingDirectory,
            prefix: "aistudio_interaction"
        )
        defer { try? FileManager.default.removeItem(at: requestFile) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 300

        let (responseData, response) = try await sendWithPOSIXRetry(
            request: request,
            fileURL: requestFile,
            session: urlSession,
            logger: logger
        )
        logger?(
            "info",
            "Google AI Studio Interactions 回應：HTTP \(response.statusCode)，音訊 \(audioByteCount) bytes，模型 \(modelID)。"
        )
        guard response.statusCode == 200 else {
            throw GoogleAIStudioTranscribeError.requestFailed(
                statusCode: response.statusCode,
                message: parseErrorMessage(responseData)
            )
        }
        return try parseInteractionResponse(
            responseData,
            modelID: modelID
        )
    }

    func parseInteractionResponse(
        _ data: Data,
        modelID: String = "gemini-3.5-transcribe"
    ) throws -> CloudTranscriptionResult {
        guard let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw GoogleAIStudioTranscribeError.invalidResponse(
                "頂層不是 JSON object。"
            )
        }
        let status = (json["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let status, !status.isEmpty, status != "completed" {
            throw GoogleAIStudioTranscribeError.interactionNotCompleted(
                status: status,
                message: interactionErrorMessage(json)
            )
        }

        var textChunks: [String] = []
        var words: [TimedWord] = []
        var languageCodes: [String] = []

        if let steps = json["steps"] as? [[String: Any]] {
            for step in steps {
                let type = (step["type"] as? String)?.lowercased()
                guard type == nil || type == "model_output" else { continue }
                if let code = step["language_code"] as? String {
                    appendUnique(code, to: &languageCodes)
                }
                collectContent(
                    step["content"],
                    textChunks: &textChunks,
                    words: &words,
                    languageCodes: &languageCodes
                )
            }
        }

        if textChunks.isEmpty,
           let fallback = json["output_text"] as? String,
           !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textChunks.append(fallback)
        }

        let combined = textChunks
            .joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw GoogleAIStudioTranscribeError.emptyResponse
        }

        return CloudTranscriptionResult(
            text: combined,
            modelID: modelID,
            transport: .geminiInteractionsTranscribe,
            detectedLanguageCodes: languageCodes,
            speakerTurns: Self.buildSpeakerTurns(from: words),
            words: words,
            providerResponseID: json["id"] as? String
        )
    }

    private func collectContent(
        _ value: Any?,
        textChunks: inout [String],
        words: inout [TimedWord],
        languageCodes: inout [String]
    ) {
        let contentItems: [[String: Any]]
        if let array = value as? [[String: Any]] {
            contentItems = array
        } else if let object = value as? [String: Any] {
            contentItems = [object]
        } else {
            return
        }

        for content in contentItems {
            if let text = content["text"] as? String,
               !text.isEmpty {
                textChunks.append(text)
            }
            if let code = content["language_code"] as? String {
                appendUnique(code, to: &languageCodes)
            }
            guard let annotations = content["annotations"]
                as? [[String: Any]] else {
                continue
            }
            for annotation in annotations {
                guard (annotation["type"] as? String)?.lowercased()
                    == "word_info" else {
                    continue
                }
                let text = (annotation["text"] as? String)
                    ?? (annotation["word"] as? String)
                    ?? ""
                guard !text.isEmpty else { continue }
                if let code = annotation["language_code"] as? String {
                    appendUnique(code, to: &languageCodes)
                }
                words.append(
                    TimedWord(
                        text: text,
                        speaker: annotation["speaker"] as? String,
                        startSeconds: GoogleDurationParser.seconds(
                            from: annotation["start_offset"]
                                ?? annotation["startOffset"]
                        ),
                        endSeconds: GoogleDurationParser.seconds(
                            from: annotation["end_offset"]
                                ?? annotation["endOffset"]
                        )
                    )
                )
            }
        }
    }

    static func buildSpeakerTurns(from words: [TimedWord]) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for word in words {
            guard let speaker = word.speaker, !speaker.isEmpty else { continue }
            if let index = turns.indices.last,
               turns[index].speaker == speaker {
                turns[index].text = appendToken(
                    word.text,
                    to: turns[index].text
                )
                turns[index].endSeconds = word.endSeconds
            } else {
                turns.append(
                    SpeakerTurn(
                        speaker: speaker,
                        text: word.text,
                        startSeconds: word.startSeconds,
                        endSeconds: word.endSeconds
                    )
                )
            }
        }
        return turns
    }

    private static func appendToken(_ token: String, to text: String) -> String {
        guard !text.isEmpty else { return token }
        guard let previous = text.unicodeScalars.last,
              let next = token.unicodeScalars.first else {
            return text + token
        }
        let needsSpace = previous.isASCII
            && next.isASCII
            && CharacterSet.alphanumerics.contains(previous)
            && CharacterSet.alphanumerics.contains(next)
        return text + (needsSpace ? " " : "") + token
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !values.contains(where: {
                  $0.caseInsensitiveCompare(trimmed) == .orderedSame
              }) else {
            return
        }
        values.append(trimmed)
    }

    private func interactionErrorMessage(_ json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return json["status_message"] as? String
            ?? json["message"] as? String
    }

    private func uploadFile(
        apiKey: String,
        audioData: Data,
        mimeType: String,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> UploadedFile {
        let tempAudio = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: audioData,
            in: workingDirectory,
            prefix: "aistudio_transcribe_audio"
        )
        defer { try? FileManager.default.removeItem(at: tempAudio) }

        guard let initializeURL = URL(
            string: "https://generativelanguage.googleapis.com/upload/v1beta/files"
        ) else {
            throw GoogleAIStudioTranscribeError.fileUploadFailed(
                "無法建立 Files API endpoint。"
            )
        }
        var initializeRequest = URLRequest(url: initializeURL)
        initializeRequest.httpMethod = "POST"
        initializeRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        initializeRequest.setValue(
            "resumable",
            forHTTPHeaderField: "X-Goog-Upload-Protocol"
        )
        initializeRequest.setValue(
            "start",
            forHTTPHeaderField: "X-Goog-Upload-Command"
        )
        initializeRequest.setValue(
            "\(audioData.count)",
            forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length"
        )
        initializeRequest.setValue(
            mimeType,
            forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type"
        )
        initializeRequest.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        initializeRequest.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "file": [
                    "display_name": "record-to-text-\(UUID().uuidString)"
                ]
            ]
        )
        initializeRequest.timeoutInterval = 30

        logger?("info", "使用 Google AI Studio Files API 上傳專用轉錄音訊。")
        let (initializeData, initializeResponse) = try await urlSession.data(
            for: initializeRequest
        )
        guard let initializeHTTP = initializeResponse as? HTTPURLResponse else {
            throw GoogleAIStudioTranscribeError.fileUploadFailed(
                "初始化上傳時沒有有效 HTTP 回應。"
            )
        }
        let uploadURLText = initializeHTTP.value(
            forHTTPHeaderField: "X-Goog-Upload-URL"
        ) ?? initializeHTTP.value(forHTTPHeaderField: "x-goog-upload-url")
        guard initializeHTTP.statusCode == 200,
              let uploadURLText,
              let uploadURL = URL(string: uploadURLText) else {
            throw GoogleAIStudioTranscribeError.fileUploadFailed(
                "無法初始化 resumable upload：\(parseErrorMessage(initializeData))"
            )
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(
            "\(audioData.count)",
            forHTTPHeaderField: "Content-Length"
        )
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue(
            "upload, finalize",
            forHTTPHeaderField: "X-Goog-Upload-Command"
        )
        uploadRequest.timeoutInterval = 300
        let (uploadData, uploadHTTP) = try await sendWithPOSIXRetry(
            request: uploadRequest,
            fileURL: tempAudio,
            session: urlSession,
            logger: logger
        )
        guard uploadHTTP.statusCode == 200 else {
            throw GoogleAIStudioTranscribeError.fileUploadFailed(
                "Files API 回傳 HTTP \(uploadHTTP.statusCode)：\(parseErrorMessage(uploadData))"
            )
        }
        guard let uploadJSON = try? JSONSerialization.jsonObject(with: uploadData)
            as? [String: Any],
              let file = uploadJSON["file"] as? [String: Any],
              let name = file["name"] as? String else {
            throw GoogleAIStudioTranscribeError.fileUploadFailed(
                "Files API 回應缺少 file.name。"
            )
        }

        do {
            guard let uri = file["uri"] as? String else {
                throw GoogleAIStudioTranscribeError.fileUploadFailed(
                    "Files API 回應缺少 file.uri。"
                )
            }
            var state = (file["state"] as? String ?? "ACTIVE").uppercased()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(60))
            while state == "PROCESSING", clock.now < deadline {
                try Task.checkCancellation()
                try await clock.sleep(for: .milliseconds(1_500))
                guard let pollURL = URL(
                    string: "https://generativelanguage.googleapis.com/v1beta/\(name)"
                ) else {
                    throw GoogleAIStudioTranscribeError.fileUploadFailed(
                        "無法建立檔案狀態 endpoint。"
                    )
                }
                var poll = URLRequest(url: pollURL)
                poll.httpMethod = "GET"
                poll.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                poll.timeoutInterval = 15
                let (pollData, pollResponse) = try await urlSession.data(for: poll)
                guard let pollHTTP = pollResponse as? HTTPURLResponse,
                      pollHTTP.statusCode == 200,
                      let pollJSON = try? JSONSerialization.jsonObject(
                          with: pollData
                      ) as? [String: Any] else {
                    throw GoogleAIStudioTranscribeError.fileUploadFailed(
                        "查詢檔案處理狀態失敗：\(parseErrorMessage(pollData))"
                    )
                }
                state = (pollJSON["state"] as? String ?? "PROCESSING")
                    .uppercased()
            }
            if state == "PROCESSING" {
                throw GoogleAIStudioTranscribeError.fileProcessingTimedOut
            }
            guard state == "ACTIVE" else {
                throw GoogleAIStudioTranscribeError.fileUploadFailed(
                    "Google 回傳未知或失敗的檔案狀態：\(state)"
                )
            }
            return UploadedFile(uri: uri, name: name)
        } catch {
            await deleteFileShielded(
                apiKey: apiKey,
                fileName: name,
                logger: logger
            )
            throw error
        }
    }

    private func deleteFileShielded(
        apiKey: String,
        fileName: String,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async {
        let failure = await Task.detached(priority: .utility) { [self] in
            await deleteFile(apiKey: apiKey, fileName: fileName)
        }.value
        if let failure {
            logger?(
                "warning",
                "清理 Gemini Files API 暫存音訊（\(fileName)）失敗：\(failure)"
            )
        }
    }

    private func deleteFile(apiKey: String, fileName: String) async -> String? {
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)"
        ) else {
            return "無法建立 DELETE endpoint"
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30
        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Google 未回傳有效 HTTP 回應"
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
                throw GoogleAIStudioTranscribeError.invalidResponse(
                    "沒有有效 HTTP 回應。"
                )
            }
            return (data, http)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
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
                    throw GoogleAIStudioTranscribeError.invalidResponse(
                        "重試沒有有效 HTTP 回應。"
                    )
                }
                return (data, http)
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if GeminiTransportHelper.isPOSIXMessageTooLarge(error) {
                    throw GoogleAIStudioTranscribeError.transportMessageTooLarge
                }
                throw error
            }
        }
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
