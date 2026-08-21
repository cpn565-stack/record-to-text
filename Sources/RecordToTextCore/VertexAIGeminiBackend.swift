import Foundation

public enum VertexAIError: LocalizedError, Equatable {
    case invalidEndpointURL(String)
    case authenticationFailed(String)
    case audioPayloadTooLarge(sizeBytes: Int, limitBytes: Int)
    case requestFailed(statusCode: Int, message: String)
    case prohibitedContent(String)
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
        case let .prohibitedContent(message):
            return "Google 內容安全政策攔截：\(message)"
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
}

public final class VertexAIGeminiBackend: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var projectID: String?
        public var location: String
        public var modelID: String
        public var gcsBucket: String?
        public var includeSummary: Bool

        public init(
            projectID: String? = nil,
            location: String = "global",
            modelID: String = "gemini-3.7-flash",
            gcsBucket: String? = nil,
            includeSummary: Bool = false
        ) {
            self.projectID = projectID
            self.location = location
            self.modelID = modelID
            self.gcsBucket = gcsBucket
            self.includeSummary = includeSummary
        }

        public static let `default` = Configuration()
    }

    private let authService: GCloudAuthService
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

    public func getConfiguration() -> Configuration {
        lock.withLock { config }
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
            return try await executeGenerateContent(
                modelID: currentConfig.modelID,
                audioData: audioData,
                mimeType: mimeType,
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds,
                workingDirectory: workingDirectory,
                logger: logger
            )
        } catch VertexAIError.prohibitedContent {
            // 若 3.7 Flash 遇到 Google 預先審查誤判（False Positive），自動切換至 Gemini 3.1 Pro 重試
            if currentConfig.modelID.contains("3.7") {
                logger?("info", "遇到內容安全政策誤判，自動切換至 Gemini 3.1 Pro 重試。")
                return try await executeGenerateContent(
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
            throw VertexAIError.prohibitedContent("Google 內容安全誤判，建議切換至 Gemini 3.1 Pro。")
        }
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

        // 1. 取得 Project ID
        let resolvedProjectID: String
        if let explicitID = currentConfig.projectID, !explicitID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedProjectID = explicitID.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            do {
                resolvedProjectID = try await authService.getDefaultProjectID()
            } catch {
                throw VertexAIError.authenticationFailed("無法取得 GCP Project ID：\(error.localizedDescription)")
            }
        }

        // 2. 取得 Access Token
        var accessToken: String
        do {
            accessToken = try await authService.getAccessToken()
        } catch {
            throw VertexAIError.authenticationFailed(error.localizedDescription)
        }

        // 3. 組裝 API Endpoint
        let resolvedLocation = currentConfig.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "global" : currentConfig.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (resolvedLocation == "global") ? "aiplatform.googleapis.com" : "\(resolvedLocation)-aiplatform.googleapis.com"
        let endpointString = "https://\(host)/v1/projects/\(resolvedProjectID)/locations/\(resolvedLocation)/publishers/google/models/\(modelID):generateContent"
        guard let endpointURL = URL(string: endpointString) else {
            throw VertexAIError.invalidEndpointURL(endpointString)
        }

        let systemInstructionText = buildSystemInstruction()
        let userPromptText = buildUserPrompt(terms: terms, customPrompt: customPrompt, timeOffsetSeconds: timeOffsetSeconds)

        let audioPart: [String: Any]
        var uploadedGCSObjectName: String? = nil
        let bucket = currentConfig.gcsBucket?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 第二層優先：若有設定 GCS Bucket 則走 GCS 上傳
        if let bucket, !bucket.isEmpty {
            let objectName = "record_to_text_\(UUID().uuidString).mp3"
            uploadedGCSObjectName = objectName
            logger?("info", "使用 GCS Bucket (\(bucket)) 串流上傳音訊...")

            try await uploadToGCS(
                bucket: bucket,
                objectName: objectName,
                audioData: audioData,
                mimeType: mimeType,
                accessToken: accessToken,
                workingDirectory: workingDirectory,
                logger: logger
            )

            audioPart = [
                "fileData": [
                    "mimeType": mimeType,
                    "fileUri": "gs://\(bucket)/\(objectName)"
                ]
            ]
        } else {
            // 第一層路徑：Inline Base64 透過檔案串流 POST
            guard audioData.count <= Self.maximumInlineAudioBytes else {
                throw VertexAIError.audioPayloadTooLarge(
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
            // 清理 GCS 遠端暫存物件
            if let bucket, !bucket.isEmpty, let objectName = uploadedGCSObjectName {
                Task {
                    await self.deleteGCSObject(
                        bucket: bucket,
                        objectName: objectName,
                        accessToken: accessToken,
                        logger: logger
                    )
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
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300 // 5 分鐘超時

        var (data, httpResponse) = try await sendWithPOSIXRetry(
            request: urlRequest,
            fileURL: tempRequestFile,
            session: urlSession,
            logger: logger
        )

        // 若遇 401 Token 過期，自動刷新並重試一次
        if httpResponse.statusCode == 401 {
            authService.invalidateToken()
            if let freshToken = try? await authService.getAccessToken(forceRefresh: true) {
                accessToken = freshToken
                urlRequest.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                let retryResult = try await sendWithPOSIXRetry(
                    request: urlRequest,
                    fileURL: tempRequestFile,
                    session: urlSession,
                    logger: logger
                )
                data = retryResult.0
                httpResponse = retryResult.1
            }
        }

        logger?(
            "info",
            "Vertex AI 請求回應：HTTP \(httpResponse.statusCode), MP3 \(audioData.count) bytes, JSON \(requestData.count) bytes, 模型 \(modelID), location \(resolvedLocation)"
        )

        if httpResponse.statusCode != 200 {
            let errorMsg = parseErrorMessage(from: data)
            throw VertexAIError.requestFailed(
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
                throw VertexAIError.invalidJSONResponse
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
    private func deleteGCSObject(
        bucket: String,
        objectName: String,
        accessToken: String,
        logger: ((_ level: String, _ message: String) -> Void)?
    ) async {
        guard let encodedName = objectName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let deleteURL = URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encodedName)") else {
            return
        }

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (httpResponse.statusCode == 200 || httpResponse.statusCode == 204 || httpResponse.statusCode == 404) {
                // 刪除成功或已不存在
                return
            }
        } catch {
            logger?("warning", "清理 GCS 暫存檔 (\(objectName)) 失敗：\(error.localizedDescription)")
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
            throw VertexAIError.invalidJSONResponse
        }

        if let promptFeedback = json["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String {
            let msg = promptFeedback["blockReasonMessage"] as? String ?? blockReason
            throw VertexAIError.requestFailed(statusCode: 400, message: "Google 內容安全政策攔截：\(msg)")
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
