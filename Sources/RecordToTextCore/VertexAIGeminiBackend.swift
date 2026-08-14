import Foundation

public enum VertexAIError: LocalizedError, Equatable {
    case invalidEndpointURL(String)
    case authenticationFailed(String)
    case audioPayloadTooLarge(sizeBytes: Int, limitBytes: Int)
    case requestFailed(statusCode: Int, message: String)
    case prohibitedContent(String)
    case emptyResponse
    case invalidJSONResponse
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
        timeOffsetSeconds: Double = 0
    ) async throws -> String {
        let currentConfig = getConfiguration()

        do {
            return try await executeGenerateContent(
                modelID: currentConfig.modelID,
                audioData: audioData,
                mimeType: mimeType,
                terms: terms,
                customPrompt: customPrompt,
                timeOffsetSeconds: timeOffsetSeconds
            )
        } catch VertexAIError.prohibitedContent {
            // 若 3.7 Flash 遇到 Google 預先審查誤判（False Positive），自動切換至 Gemini 3.1 Pro 重試
            if currentConfig.modelID.contains("3.7") {
                return try await executeGenerateContent(
                    modelID: "gemini-3.1-pro-preview",
                    audioData: audioData,
                    mimeType: mimeType,
                    terms: terms,
                    customPrompt: customPrompt,
                    timeOffsetSeconds: timeOffsetSeconds
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
        timeOffsetSeconds: Double
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
        let accessToken: String
        do {
            accessToken = try await authService.getAccessToken()
        } catch {
            throw VertexAIError.authenticationFailed(error.localizedDescription)
        }

        // 3. 檢查音檔大小 (目前支援 inline base64)
        guard audioData.count <= Self.maximumInlineAudioBytes else {
            throw VertexAIError.audioPayloadTooLarge(
                sizeBytes: audioData.count,
                limitBytes: Self.maximumInlineAudioBytes
            )
        }

        // 4. 組裝 API Endpoint (全球端點為 aiplatform.googleapis.com，區域端點為 {location}-aiplatform.googleapis.com)
        let resolvedLocation = currentConfig.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "global" : currentConfig.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (resolvedLocation == "global") ? "aiplatform.googleapis.com" : "\(resolvedLocation)-aiplatform.googleapis.com"
        let endpointString = "https://\(host)/v1/projects/\(resolvedProjectID)/locations/\(resolvedLocation)/publishers/google/models/\(modelID):generateContent"
        guard let endpointURL = URL(string: endpointString) else {
            throw VertexAIError.invalidEndpointURL(endpointString)
        }

        // 5. 組裝 Prompt
        let systemInstructionText = buildSystemInstruction()
        let userPromptText = buildUserPrompt(terms: terms, customPrompt: customPrompt, timeOffsetSeconds: timeOffsetSeconds)

        let base64Audio = audioData.base64EncodedString()

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
                        [
                            "inlineData": [
                                "mimeType": mimeType,
                                "data": base64Audio
                            ]
                        ],
                        [
                            "text": userPromptText
                        ]
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

        // 6. 發送 HTTP 請求
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = requestData
        urlRequest.timeoutInterval = 300 // 5 分鐘超時

        var (data, response) = try await urlSession.data(for: urlRequest)

        guard var httpResponse = response as? HTTPURLResponse else {
            throw VertexAIError.invalidJSONResponse
        }

        // 若遇 401 Token 過期，自動刷新並重試一次
        if httpResponse.statusCode == 401 {
            authService.invalidateToken()
            if let freshToken = try? await authService.getAccessToken(forceRefresh: true) {
                urlRequest.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                let retryResult = try await urlSession.data(for: urlRequest)
                data = retryResult.0
                if let retryHTTP = retryResult.1 as? HTTPURLResponse {
                    httpResponse = retryHTTP
                }
            }
        }

        if httpResponse.statusCode != 200 {
            let errorMsg = parseErrorMessage(from: data)
            throw VertexAIError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMsg
            )
        }

        // 7. 解析回傳文字
        return try parseCandidateText(from: data)
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

        // 1. 若含有舊式 "## 📝 完整整理逐字稿" 或重複的草稿重啟標記，保留後方完整逐字內容
        if let range = text.range(of: "## 📝 完整整理逐字稿") {
            text = String(text[range.upperBound...])
        } else if let range = text.range(of: "## 完整整理逐字稿") {
            text = String(text[range.upperBound...])
        }

        // 2. 移除 Markdown 標題符號 (例如 ### [00:00 - 05:00] -> [00:00 - 05:00])
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*#{1,6}[ \t]*(\[\d{2}:\d{2})"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*#{1,6}[ \t]*"#, with: "", options: .regularExpression)

        // 3. 移除粗體語法 **講者** -> 講者
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)

        // 4. 移除水平分隔線
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*---[ \t]*$"#, with: "", options: .regularExpression)

        // 5. 正規化多餘空行
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
