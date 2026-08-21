import Foundation

public enum GoogleAIStudioError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey(String)
    case requestFailed(statusCode: Int, message: String)
    case prohibitedContent(String)
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
        case let .prohibitedContent(message):
            return "Google 內容安全政策攔截：\(message)"
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
}

public final class GoogleAIStudioBackend: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var apiKey: String?
        public var modelID: String
        public var useFilesAPI: Bool

        public init(
            apiKey: String? = nil,
            modelID: String = "gemini-3.7-flash",
            useFilesAPI: Bool = true
        ) {
            self.apiKey = apiKey
            self.modelID = modelID
            self.useFilesAPI = useFilesAPI
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
        } else {
            let errorMsg = parseErrorMessage(from: data)
            throw GoogleAIStudioError.invalidAPIKey(errorMsg)
        }
    }

    /// 執行語音轉文字
    public func transcribe(
        audioData: Data,
        mimeType: String = "audio/mp3",
        terms: [String] = [],
        customPrompt: String = "",
        timeOffsetSeconds: Double = 0,
        workingDirectory: URL? = nil,
        logger: ((_ level: String, _ message: String) -> Void)? = nil
    ) async throws -> String {
        let currentConfig = getConfiguration()

        do {
            return try await executeWithRetries(
                modelID: currentConfig.modelID,
                audioData: audioData,
                mimeType: mimeType,
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds,
                workingDirectory: workingDirectory,
                logger: logger
            )
        } catch GoogleAIStudioError.prohibitedContent {
            // 若遇到音訊假陽性安全阻擋，自動 Fallback 至 3.1 Pro 重試
            if !currentConfig.modelID.contains("pro") {
                logger?("info", "遇到內容安全政策誤判，自動 Fallback 至 Gemini 3.1 Pro 重試。")
                return try await executeWithRetries(
                    modelID: "gemini-3.1-pro-preview",
                    audioData: audioData,
                    mimeType: mimeType,
                    terms: terms,
                    customPrompt: customPrompt,
                    timeOffsetSeconds: timeOffsetSeconds,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
            }
            throw GoogleAIStudioError.prohibitedContent("Google 內容安全誤判，建議切換至 Gemini 3.1 Pro。")
        } catch let error as GoogleAIStudioError {
            // 若 3.7 Flash 在多次重試後依然遇到 503 High Demand，自動 Fallback 至 3.6 Flash 或 3.1 Pro
            if case let .requestFailed(statusCode, _) = error, (statusCode == 503 || statusCode == 429) {
                if currentConfig.modelID.contains("3.7") {
                    let fallbackModel = "gemini-3.6-flash"
                    logger?("info", "Gemini 3.7 伺服器尖峰 (HTTP \(statusCode))，自動 Fallback 至 \(fallbackModel) 重試。")
                    do {
                        return try await executeWithRetries(
                            modelID: fallbackModel,
                            audioData: audioData,
                            mimeType: mimeType,
                            terms: terms,
                            customPrompt: customPrompt,
                            timeOffsetSeconds: timeOffsetSeconds,
                            workingDirectory: workingDirectory,
                            logger: logger
                        )
                    } catch {
                        // 若 3.6 也尖峰，再嘗試 3.1 Pro
                        logger?("info", "\(fallbackModel) 重試失敗，再次 Fallback 至 gemini-3.1-pro-preview 重試。")
                        return try await executeWithRetries(
                            modelID: "gemini-3.1-pro-preview",
                            audioData: audioData,
                            mimeType: mimeType,
                            terms: terms,
                            customPrompt: customPrompt,
                            timeOffsetSeconds: timeOffsetSeconds,
                            workingDirectory: workingDirectory,
                            logger: logger
                        )
                    }
                }
            }
            throw error
        }
    }

    private func executeWithRetries(
        modelID: String,
        audioData: Data,
        mimeType: String,
        terms: [String],
        customPrompt: String,
        timeOffsetSeconds: Double,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> String {
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await executeGenerateContent(
                    modelID: modelID,
                    audioData: audioData,
                    mimeType: mimeType,
                    terms: terms,
                    customPrompt: customPrompt,
                    timeOffsetSeconds: timeOffsetSeconds,
                    workingDirectory: workingDirectory,
                    logger: logger
                )
            } catch let error as GoogleAIStudioError {
                if case let .requestFailed(statusCode, _) = error, (statusCode == 503 || statusCode == 429 || statusCode == 500) {
                    lastError = error
                    if attempt < maxAttempts {
                        let backoffSeconds = Double(attempt * 2)
                        logger?("info", "HTTP \(statusCode) 伺服器忙碌，等候 \(Int(backoffSeconds)) 秒後進行第 \(attempt + 1) 次重試...")
                        try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                        continue
                    }
                }
                throw error
            } catch {
                throw error
            }
        }

        if let lastError {
            throw lastError
        }
        throw GoogleAIStudioError.requestFailed(statusCode: 503, message: "伺服器忙碌，重試後仍失敗。")
    }

    private func executeGenerateContent(
        modelID: String,
        audioData: Data,
        mimeType: String,
        terms: [String],
        customPrompt: String,
        timeOffsetSeconds: Double,
        workingDirectory: URL?,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async throws -> String {
        let currentConfig = getConfiguration()

        guard let apiKey = currentConfig.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw GoogleAIStudioError.missingAPIKey
        }

        let endpointString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent"
        guard let endpointURL = URL(string: endpointString) else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        let systemInstructionText = buildSystemInstruction()
        let userPromptText = buildUserPrompt(terms: terms, customPrompt: customPrompt, timeOffsetSeconds: timeOffsetSeconds)

        let audioPart: [String: Any]
        var uploadedFileName: String? = nil

        // 第二層優先：若啟用 Files API 則使用官方 Files API 上傳音訊
        if currentConfig.useFilesAPI {
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
                audioPart = [
                    "fileData": [
                        "mimeType": mimeType,
                        "fileUri": fileUri
                    ]
                ]
            } catch {
                logger?("warning", "Files API 上傳未成功，降級至串流 Inline Base64 路徑：\(error.localizedDescription)")
                guard audioData.count <= Self.maximumInlineAudioBytes else {
                    throw GoogleAIStudioError.audioPayloadTooLarge(
                        sizeBytes: audioData.count,
                        limitBytes: Self.maximumInlineAudioBytes
                    )
                }
                let base64Audio = audioData.base64EncodedString()
                audioPart = [
                    "inlineData": [
                        "mimeType": mimeType,
                        "data": base64Audio
                    ]
                ]
            }
        } else {
            // 第一層路徑：Inline Base64 透過檔案串流 POST
            guard audioData.count <= Self.maximumInlineAudioBytes else {
                throw GoogleAIStudioError.audioPayloadTooLarge(
                    sizeBytes: audioData.count,
                    limitBytes: Self.maximumInlineAudioBytes
                )
            }

            let base64Audio = audioData.base64EncodedString()
            audioPart = [
                "inlineData": [
                    "mimeType": mimeType,
                    "data": base64Audio
                ]
            ]
        }

        defer {
            if let fileName = uploadedFileName {
                Task {
                    await self.deleteRemoteFile(fileName: fileName, apiKey: apiKey, logger: logger)
                }
            }
        }

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
                        audioPart,
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
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 8192
            ]
        ]

        let requestData = try JSONSerialization.data(withJSONObject: requestBody)

        let tempRequestFile = try GeminiTransportHelper.writeTemporaryRequestFile(
            data: requestData,
            in: workingDirectory,
            prefix: "aistudio_generate"
        )
        defer {
            try? FileManager.default.removeItem(at: tempRequestFile)
        }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300 // 5 分鐘超時

        let (data, httpResponse) = try await sendWithPOSIXRetry(
            request: urlRequest,
            fileURL: tempRequestFile,
            session: urlSession,
            logger: logger
        )

        logger?(
            "info",
            "Google AI Studio 請求回應：HTTP \(httpResponse.statusCode), MP3 \(audioData.count) bytes, JSON \(requestData.count) bytes, 模型 \(modelID)"
        )

        if httpResponse.statusCode != 200 {
            let errorMsg = parseErrorMessage(from: data)
            throw GoogleAIStudioError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMsg
            )
        }

        return try parseCandidateText(from: data)
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
              let fileUri = fileObj["uri"] as? String,
              let fileName = fileObj["name"] as? String else {
            throw GoogleAIStudioError.fileUploadFailed("無法解析 Files API 回傳結構")
        }

        var currentState = fileObj["state"] as? String ?? "ACTIVE"

        // 3. 輪詢檔案狀態直到 ACTIVE
        var waitedSeconds = 0
        while currentState == "PROCESSING" && waitedSeconds < 60 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            waitedSeconds += 2

            guard let pollURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)") else {
                break
            }
            var pollRequest = URLRequest(url: pollURL)
            pollRequest.httpMethod = "GET"
            pollRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            pollRequest.timeoutInterval = 15

            if let (pollData, pollResponse) = try? await urlSession.data(for: pollRequest),
               let pollHTTP = pollResponse as? HTTPURLResponse, pollHTTP.statusCode == 200,
               let pollJson = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any] {
                currentState = pollJson["state"] as? String ?? "ACTIVE"
            }
        }

        if currentState == "FAILED" {
            throw GoogleAIStudioError.fileUploadFailed("Google 伺服器處理音訊檔案失敗")
        }

        if currentState == "PROCESSING" {
            throw GoogleAIStudioError.fileProcessingTimedOut
        }

        return (fileUri: fileUri, fileName: fileName)
    }

    /// 刪除 Files API 遠端暫存檔案
    private func deleteRemoteFile(
        fileName: String,
        apiKey: String,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async {
        guard let deleteURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)") else {
            return
        }

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (httpResponse.statusCode == 200 || httpResponse.statusCode == 204 || httpResponse.statusCode == 404) {
                return
            }
        } catch {
            logger?("warning", "清理 Files API 暫存檔 (\(fileName)) 失敗：\(error.localizedDescription)")
        }
    }

    private func buildSystemInstruction() -> String {
        return """
你是一位專業的高精度語音逐字稿轉錄專家。請仔細聆聽這段音訊，直接將其轉錄為排版乾淨整齊的「純文字逐字稿 (Plain Text Transcript)」。

【排版與輸出規範】
1. 純文字輸出：嚴禁使用任何 Markdown 格式標記（禁止使用 **粗體**、### 標題、--- 分隔線、Markdown 標題文字等）。
2. 時間標記：大約每 3 至 5 分鐘（或對話主題轉換時）標註一次時間區間，格式固定為：
[00:00 - 05:00]
3. 講者分辨與分段：
   - 請根據不同說話者的聲音特徵區分講者（例如「講者 1：」、「講者 2：」；若音訊中或專有名詞詞庫有提及姓名則標註姓名，如「Tina：」、「David：」）。
   - 禁止在講者名稱外包覆任何符號（嚴禁寫成 **講者**：）。
   - 請依據講者輪替與語意對話自然分段換行。
4. 語言與用詞：一律使用標準「台灣繁體中文 (zh-TW)」輸出，英文專有名詞維持正確大小寫與拼寫。
5. 嚴禁多餘內容：從音訊第一秒直接開始輸出逐字內容，嚴禁輸出重複內容、前言草稿、開場白（如「好的，以下是逐字稿」）、結尾客套話、背景說明、會議摘要或待辦事項。

【格式範例】
[00:00 - 05:00]
講師：大家早，今天我們主要是對齊進度...

學員 1：我學到的是對話、聚焦、對策...

[05:00 - 10:00]
學員 2：我學到兩點，第一個是...
"""
    }

    private func buildUserPrompt(terms: [String], customPrompt: String, timeOffsetSeconds: Double) -> String {
        var parts: [String] = []

        if timeOffsetSeconds > 0 {
            let startMin = Int(timeOffsetSeconds) / 60
            let startSec = Int(timeOffsetSeconds) % 60
            let startFormatted = String(format: "%02d:%02d", startMin, startSec)
            parts.append("【時間基準通知】：本音訊片段在整場錄音中的起始時間為 \(startFormatted)（第 \(Int(timeOffsetSeconds)) 秒）。請將輸出中的所有時間碼依據此起始時間計算與標註（例如起始標記為 [\(startFormatted) - ...]）。")
        }

        if !terms.isEmpty {
            let termsFormatted = terms.map { "- \($0)" }.joined(separator: "\n")
            parts.append("【專有名詞與詞庫參考（若音訊中有提及，請優先採用以下標準用字與講者姓名）】：\n\(termsFormatted)")
        }

        if !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("【補充指示】：\n\(customPrompt)")
        }

        parts.append("請直接開始轉錄上述音訊。")
        return parts.joined(separator: "\n\n")
    }

    private func parseErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return message
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func parseCandidateText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleAIStudioError.invalidJSONResponse
        }

        if let promptFeedback = json["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String {
            let msg = promptFeedback["blockReasonMessage"] as? String ?? blockReason
            if blockReason == "PROHIBITED_CONTENT" {
                throw GoogleAIStudioError.prohibitedContent(msg)
            }
            throw GoogleAIStudioError.requestFailed(statusCode: 400, message: "Google 內容安全政策攔截：\(msg)")
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            return ""
        }

        guard let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ""
        }

        var textChunks: [String] = []
        for part in parts {
            if let text = part["text"] as? String {
                textChunks.append(text)
            }
        }

        let combined = textChunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitizeTranscript(combined)
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
