#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def replace_once(content: str, old: str, new: str, label: str) -> str:
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return content.replace(old, new, 1)


def replace_between(
    content: str,
    start_marker: str,
    end_marker: str,
    replacement: str,
    label: str,
) -> str:
    start = content.find(start_marker)
    if start < 0:
        raise RuntimeError(f"{label}: start marker not found")
    end = content.find(end_marker, start)
    if end < 0:
        raise RuntimeError(f"{label}: end marker not found")
    return content[:start] + replacement + content[end:]


transport = r'''import Foundation

public enum GeminiTransportHelper {
    /// 檢查錯誤是否為 POSIX 40 (EMSGSIZE: Message too long) 或相關底層 CFStream 錯誤
    public static func isPOSIXMessageTooLarge(_ error: Error) -> Bool {
        var current: Error? = error
        var visited = Set<String>()

        while let err = current {
            let nsError = err as NSError
            let errorIdentifier = "\(nsError.domain):\(nsError.code)"
            if visited.contains(errorIdentifier) {
                break
            }
            visited.insert(errorIdentifier)

            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 40 {
                return true
            }

            if let cfCode = nsError.userInfo["_kCFStreamErrorCodeKey"] {
                if let intVal = cfCode as? Int, intVal == 40 {
                    return true
                }
                if let numVal = cfCode as? NSNumber, numVal.intValue == 40 {
                    return true
                }
                if let strVal = cfCode as? String, strVal == "40" {
                    return true
                }
            }

            if nsError.domain == NSPOSIXErrorDomain
                && nsError.localizedDescription.contains("Message too long")
            {
                return true
            }

            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                current = underlying
            } else if let underlying = nsError.userInfo["NSUnderlyingError"] as? Error {
                current = underlying
            } else {
                current = nil
            }
        }

        return false
    }

    /// 將請求資料寫入暫存檔，並收緊權限為 0o600
    public static func writeTemporaryRequestFile(
        data: Data,
        in directory: URL? = nil,
        prefix: String = "gemini_req"
    ) throws -> URL {
        let fileManager = FileManager.default
        let targetDirectory: URL
        if let directory {
            targetDirectory = directory
        } else {
            targetDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("record-to-text-transport", isDirectory: true)
        }

        if !fileManager.fileExists(atPath: targetDirectory.path) {
            try fileManager.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let fileURL = targetDirectory.appendingPathComponent(
            "\(prefix)_\(UUID().uuidString).json"
        )
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return fileURL
    }

    /// 建立乾淨獨立的 Ephemeral Session，避開快取的 HTTP/3 連線池
    public static func makeEphemeralRetrySession(
        protocolClasses: [AnyClass]? = nil
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    /// Extracts a server-requested delay from Retry-After or google.rpc.RetryInfo.
    public static func retryAfterSeconds(
        response: HTTPURLResponse,
        data: Data
    ) -> Double? {
        if let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Double(raw),
           seconds >= 0
        {
            return seconds
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let error = object["error"] as? [String: Any],
            let details = error["details"] as? [[String: Any]]
        else {
            return nil
        }

        for detail in details {
            if let retryDelay = detail["retryDelay"] as? String,
               let seconds = parseDurationSeconds(retryDelay) {
                return seconds
            }
        }
        return nil
    }

    public static func isDailyQuotaExceeded(
        data: Data,
        message: String
    ) -> Bool {
        var searchable = message.lowercased()
        if let raw = String(data: data, encoding: .utf8) {
            searchable += " " + raw.lowercased()
        }
        let dailyMarkers = [
            "perday",
            "per_day",
            "per-day",
            "requests per day",
            "tokens per day",
            "daily quota",
            "daily limit"
        ]
        return dailyMarkers.contains { searchable.contains($0) }
    }

    private static func parseDurationSeconds(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("s"),
           let value = Double(trimmed.dropLast()),
           value >= 0 {
            return value
        }
        return nil
    }

    public enum RetryPolicy {
        public static let maximumAttempts = 4

        public static func isRetryableStatusCode(_ statusCode: Int) -> Bool {
            [408, 429, 500, 502, 503, 504].contains(statusCode)
        }

        /// Exponential backoff with bounded jitter. `jitterFraction` is exposed
        /// for deterministic tests; production callers use a random value.
        public static func backoffSeconds(
            forAttempt attempt: Int,
            retryAfterSeconds: Double? = nil,
            jitterFraction: Double = Double.random(in: 0...1)
        ) -> Double {
            let normalizedAttempt = max(attempt, 1)
            let exponential = pow(2.0, Double(normalizedAttempt - 1))
            let normalizedJitter = min(max(jitterFraction, 0), 1)
            let jitter = exponential * 0.5 * normalizedJitter
            let computed = exponential + jitter
            return min(max(computed, retryAfterSeconds ?? 0), 60)
        }
    }
}
'''
write("Sources/RecordToTextCore/GeminiTransportHelper.swift", transport)

response_parser = r'''import Foundation

public enum GeminiResponseMetadataParser {
    public static func makeMetadata(
        from data: Data,
        requestedModelID: String,
        effectiveModelID: String,
        retryCount: Int,
        fallbackReason: String?,
        thinkingLevel: GeminiThinkingLevel,
        latencySeconds: Double
    ) -> CloudTranscriptionMetadata {
        let json = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any]
        let usageObject = json?["usageMetadata"] as? [String: Any]

        func integer(_ key: String) -> Int? {
            if let number = usageObject?[key] as? NSNumber {
                return number.intValue
            }
            return usageObject?[key] as? Int
        }

        let prompt = integer("promptTokenCount")
        let cached = integer("cachedContentTokenCount")
        let candidates = integer("candidatesTokenCount")
        let thoughts = integer("thoughtsTokenCount")
        let total = integer("totalTokenCount")
        let serviceTier = usageObject?["trafficType"] as? String
            ?? json?["serviceTier"] as? String
        let usage: CloudUsageMetadata?
        if prompt == nil,
           cached == nil,
           candidates == nil,
           thoughts == nil,
           total == nil,
           serviceTier == nil {
            usage = nil
        } else {
            usage = CloudUsageMetadata(
                promptTokenCount: prompt,
                cachedContentTokenCount: cached,
                candidatesTokenCount: candidates,
                thoughtsTokenCount: thoughts,
                totalTokenCount: total,
                serviceTier: serviceTier
            )
        }

        return CloudTranscriptionMetadata(
            requestedModelID: requestedModelID,
            effectiveModelID: effectiveModelID,
            modelVersion: json?["modelVersion"] as? String,
            responseID: json?["responseId"] as? String,
            retryCount: retryCount,
            fallbackReason: fallbackReason,
            thinkingLevel: thinkingLevel,
            latencySeconds: latencySeconds,
            usage: usage
        )
    }
}
'''
write("Sources/RecordToTextCore/GeminiResponseMetadataParser.swift", response_parser)


def patch_google() -> None:
    path = "Sources/RecordToTextCore/GoogleAIStudioBackend.swift"
    text = read(path)
    text = replace_once(
        text,
        "    case requestFailed(statusCode: Int, message: String)\n    case prohibitedContent(String)\n",
        "    case requestFailed(statusCode: Int, message: String)\n    case rateLimited(message: String, retryAfterSeconds: Double?)\n    case quotaExceeded(String)\n    case prohibitedContent(String)\n",
        "AI Studio error cases",
    )
    text = replace_once(
        text,
        "        case let .requestFailed(statusCode, message):\n            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)\n            return \"Google AI Studio 請求失敗（HTTP \\(statusCode)）：\\(trimmed)\"\n        case let .prohibitedContent(message):\n",
        "        case let .requestFailed(statusCode, message):\n            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)\n            return \"Google AI Studio 請求失敗（HTTP \\(statusCode)）：\\(trimmed)\"\n        case let .rateLimited(message, retryAfterSeconds):\n            let delay = retryAfterSeconds.map { \"，建議至少等待 \\(String(format: \\\"%.1f\\\", $0)) 秒\" } ?? \"\"\n            return \"Google AI Studio 暫時達到速率限制\\(delay)：\\(message)\"\n        case let .quotaExceeded(message):\n            return \"Google AI Studio 當日配額已用完，短時間重試不會成功：\\(message)\"\n        case let .prohibitedContent(message):\n",
        "AI Studio error descriptions",
    )
    text = replace_once(
        text,
        "        public var useFilesAPI: Bool\n\n        public init(\n            apiKey: String? = nil,\n            modelID: String = \"gemini-3.7-flash\",\n            useFilesAPI: Bool = true\n        ) {\n            self.apiKey = apiKey\n            self.modelID = modelID\n            self.useFilesAPI = useFilesAPI\n",
        "        public var useFilesAPI: Bool\n        public var thinkingLevel: GeminiThinkingLevel\n        public var fallbackPolicy: CloudFallbackPolicy\n\n        public init(\n            apiKey: String? = nil,\n            modelID: String = \"gemini-3.7-flash\",\n            useFilesAPI: Bool = true,\n            thinkingLevel: GeminiThinkingLevel = .medium,\n            fallbackPolicy: CloudFallbackPolicy = .disabled\n        ) {\n            self.apiKey = apiKey\n            self.modelID = modelID\n            self.useFilesAPI = useFilesAPI\n            self.thinkingLevel = thinkingLevel\n            self.fallbackPolicy = fallbackPolicy\n",
        "AI Studio configuration",
    )

    transcribe_block = r'''    /// Executes transcription while preserving model/version/token provenance.
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

'''
    text = replace_between(
        text,
        "    /// 執行語音轉文字\n    public func transcribe(\n",
        "    private func runTranscriptionAttempts(\n",
        transcribe_block,
        "AI Studio transcription entry",
    )

    attempts_block = r'''    private func runTranscriptionAttempts(
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

'''
    text = replace_between(
        text,
        "    private func runTranscriptionAttempts(\n",
        "    private struct PreparedAudio {\n",
        attempts_block,
        "AI Studio fallback policy",
    )

    retry_block = r'''    private func executeWithRetries(
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
                    "Gemini \(effectiveModelID) 暫時忙碌，\(String(format: \"%.1f\", delay)) 秒後進行第 \(attempt + 1) 次嘗試。"
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

'''
    text = replace_between(
        text,
        "    private func executeWithRetries(\n",
        "    private func generateTranscript(\n",
        retry_block,
        "AI Studio retry loop",
    )

    generate_block = r'''    private func generateTranscript(
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

'''
    text = replace_between(
        text,
        "    private func generateTranscript(\n",
        "    private func sendGenerateContentRequest(\n",
        generate_block,
        "AI Studio generate",
    )

    send_block = r'''    private func sendGenerateContentRequest(
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
        var generationConfig: [String: Any] = [
            "maxOutputTokens": 16_384
        ]
        if effectiveModelID.contains("3.7") {
            generationConfig["thinkingConfig"] = [
                "thinkingLevel": thinkingLevel.rawValue
            ]
        }

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

        let text = try parseCandidateText(from: data)
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

'''
    text = replace_between(
        text,
        "    private func sendGenerateContentRequest(\n",
        "    /// 透過串流上傳將請求送出",
        send_block,
        "AI Studio request",
    )
    write(path, text)


def patch_vertex() -> None:
    path = "Sources/RecordToTextCore/VertexAIGeminiBackend.swift"
    text = read(path)
    text = replace_once(
        text,
        "    case requestFailed(statusCode: Int, message: String)\n    case prohibitedContent(String)\n",
        "    case requestFailed(statusCode: Int, message: String)\n    case rateLimited(message: String, retryAfterSeconds: Double?)\n    case quotaExceeded(String)\n    case prohibitedContent(String)\n",
        "Vertex error cases",
    )
    text = replace_once(
        text,
        "        case let .requestFailed(statusCode, message):\n            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)\n            return \"Vertex AI 請求失敗（HTTP \\(statusCode)）：\\(trimmed)\"\n        case let .prohibitedContent(message):\n",
        "        case let .requestFailed(statusCode, message):\n            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)\n            return \"Vertex AI 請求失敗（HTTP \\(statusCode)）：\\(trimmed)\"\n        case let .rateLimited(message, retryAfterSeconds):\n            let delay = retryAfterSeconds.map { \"，建議至少等待 \\(String(format: \\\"%.1f\\\", $0)) 秒\" } ?? \"\"\n            return \"Vertex AI 暫時達到速率限制\\(delay)：\\(message)\"\n        case let .quotaExceeded(message):\n            return \"Vertex AI 當日配額已用完，短時間重試不會成功：\\(message)\"\n        case let .prohibitedContent(message):\n",
        "Vertex error descriptions",
    )
    text = replace_once(
        text,
        "        public var includeSummary: Bool\n\n        public init(\n            projectID: String? = nil,\n            location: String = \"global\",\n            modelID: String = \"gemini-3.7-flash\",\n            gcsBucket: String? = nil,\n            includeSummary: Bool = false\n        ) {\n",
        "        public var includeSummary: Bool\n        public var thinkingLevel: GeminiThinkingLevel\n        public var fallbackPolicy: CloudFallbackPolicy\n\n        public init(\n            projectID: String? = nil,\n            location: String = \"global\",\n            modelID: String = \"gemini-3.7-flash\",\n            gcsBucket: String? = nil,\n            includeSummary: Bool = false,\n            thinkingLevel: GeminiThinkingLevel = .medium,\n            fallbackPolicy: CloudFallbackPolicy = .disabled\n        ) {\n",
        "Vertex config parameters",
    )
    text = replace_once(
        text,
        "            self.gcsBucket = gcsBucket\n            self.includeSummary = includeSummary\n",
        "            self.gcsBucket = gcsBucket\n            self.includeSummary = includeSummary\n            self.thinkingLevel = thinkingLevel\n            self.fallbackPolicy = fallbackPolicy\n",
        "Vertex config assignments",
    )

    detailed_start = r'''    /// 執行語音轉文字
    public func transcribe(
'''
    detailed_end = "    private func runTranscriptionAttempts(\n"
    transcribe_block = r'''    public func transcribeDetailed(
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

'''
    text = replace_between(
        text, detailed_start, detailed_end, transcribe_block,
        "Vertex transcription entry"
    )

    attempts_block = r'''    private func runTranscriptionAttempts(
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

'''
    text = replace_between(
        text,
        "    private func runTranscriptionAttempts(\n",
        "    private struct PreparedAudio {\n",
        attempts_block,
        "Vertex fallback policy",
    )

    retry_block = r'''    private func executeWithRetries(
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
                    "Vertex Gemini \(effectiveModelID) 暫時忙碌，\(String(format: \"%.1f\", delay)) 秒後進行第 \(attempt + 1) 次嘗試。"
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

'''
    text = replace_between(
        text,
        "    private func executeWithRetries(\n",
        "    private func generateTranscript(\n",
        retry_block,
        "Vertex retry loop",
    )

    generate_block = r'''    private func generateTranscript(
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

'''
    text = replace_between(
        text,
        "    private func generateTranscript(\n",
        "    /// 對已完成合併的逐字稿產生一次文字摘要。",
        generate_block,
        "Vertex generate",
    )

    # Summary call: provide metadata context and read the text from the result.
    text = replace_once(
        text,
        "        let result = try await sendGenerateContentRequest(\n            modelID: currentConfig.modelID,\n            resolvedLocation: location,\n",
        "        let result = try await sendGenerateContentRequest(\n            requestedModelID: currentConfig.modelID,\n            effectiveModelID: currentConfig.modelID,\n            retryCount: 0,\n            fallbackReason: nil,\n            resolvedLocation: location,\n",
        "Vertex summary call labels",
    )
    text = replace_once(
        text,
        "            maximumOutputTokens: 2_048,\n            workingDirectory: workingDirectory,\n",
        "            maximumOutputTokens: 2_048,\n            thinkingLevel: currentConfig.thinkingLevel,\n            workingDirectory: workingDirectory,\n",
        "Vertex summary thinking",
    )
    text = replace_once(
        text,
        "        return result.text\n    }\n\n    private func sendGenerateContentRequest(\n        modelID: String,\n",
        "        return result.result.text\n    }\n\n    private func sendGenerateContentRequest(\n        requestedModelID: String,\n        effectiveModelID: String,\n        retryCount: Int,\n        fallbackReason: String?,\n",
        "Vertex summary result and send signature",
    )
    text = replace_once(
        text,
        "        maximumOutputTokens: Int,\n        workingDirectory: URL?,\n",
        "        maximumOutputTokens: Int,\n        thinkingLevel: GeminiThinkingLevel,\n        workingDirectory: URL?,\n",
        "Vertex send thinking parameter",
    )
    text = replace_once(
        text,
        "    ) async throws -> (text: String, accessToken: String) {\n        var resolvedAccessToken = accessToken\n        let requestBody: [String: Any] = [\n",
        "    ) async throws -> (result: CloudTranscriptionResult, accessToken: String) {\n        var resolvedAccessToken = accessToken\n        var generationConfig: [String: Any] = [\n            \"maxOutputTokens\": maximumOutputTokens\n        ]\n        if effectiveModelID.contains(\"3.7\") {\n            generationConfig[\"thinkingConfig\"] = [\n                \"thinkingLevel\": thinkingLevel.rawValue\n            ]\n        }\n        let requestBody: [String: Any] = [\n",
        "Vertex send return and config",
    )
    text = replace_once(
        text,
        "            \"generationConfig\": [\n                \"maxOutputTokens\": maximumOutputTokens\n            ]\n",
        "            \"generationConfig\": generationConfig\n",
        "Vertex generation config body",
    )
    text = replace_once(
        text,
        "        var (data, httpResponse) = try await sendWithPOSIXRetry(\n",
        "        let startedAt = Date()\n        var (data, httpResponse) = try await sendWithPOSIXRetry(\n",
        "Vertex request timer",
    )
    text = replace_once(
        text,
        "            \"Vertex AI \\(requestDescription)請求回應：HTTP \\(httpResponse.statusCode), 輸入 \\(inputByteCount) bytes, JSON \\(requestData.count) bytes, 模型 \\(modelID), location \\(resolvedLocation)\"\n",
        "            \"Vertex AI \\(requestDescription)回應：HTTP \\(httpResponse.statusCode)，輸入 \\(inputByteCount) bytes，JSON \\(requestData.count) bytes，要求 \\(requestedModelID)，實際請求 \\(effectiveModelID)，location \\(resolvedLocation)。\"\n",
        "Vertex response log",
    )
    old_error = '''        if httpResponse.statusCode != 200 {
            let errorMsg = parseErrorMessage(from: data)
            throw VertexAIError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMsg
            )
        }

        return (try parseCandidateText(from: data), resolvedAccessToken)
'''
    new_error = '''        guard httpResponse.statusCode == 200 else {
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

        let text = try parseCandidateText(from: data)
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
'''
    text = replace_once(text, old_error, new_error, "Vertex response handling")
    write(path, text)


patch_google()
patch_vertex()

# Update the existing fallback self-test to opt in explicitly and account for
# the new four-attempt retry budget before the one permitted fallback.
self_test = read("Tools/SelfTest/main.swift")
old_config = '''            configuration: GoogleAIStudioBackend.Configuration(
                apiKey: "AIzaTestKey",
                modelID: "gemini-3.7-flash",
                useFilesAPI: false
            )
        )

        do {
            _ = try blockingAwait {
'''
new_config = '''            configuration: GoogleAIStudioBackend.Configuration(
                apiKey: "AIzaTestKey",
                modelID: "gemini-3.7-flash",
                useFilesAPI: false,
                fallbackPolicy: .flashOnly
            )
        )

        do {
            _ = try blockingAwait {
'''
# There are several similar configurations; only the final fallback test is
# followed by the exact `_ = try blockingAwait` sequence.
self_test = replace_once(
    self_test,
    old_config,
    new_config,
    "fallback self-test opt-in",
)
self_test = replace_once(
    self_test,
    "            if generateCalls <= 3 {\n                // Primary model exhausts its retry budget with server errors.\n",
    "            if generateCalls <= 4 {\n                // Primary model exhausts its retry budget with server errors.\n",
    "fallback self-test retry count",
)
write("Tools/SelfTest/main.swift", self_test)

backend_tests = r'''import Foundation
import XCTest
@testable import RecordToTextCore

final class GeminiBackendObservabilityTests: XCTestCase {
    func testMetadataParserCapturesModelVersionResponseAndUsage() throws {
        let data = Data(
            #"{"modelVersion":"gemini-3.7-flash-202608","responseId":"resp-123","usageMetadata":{"promptTokenCount":120,"cachedContentTokenCount":20,"candidatesTokenCount":50,"thoughtsTokenCount":12,"totalTokenCount":182,"trafficType":"ON_DEMAND"}}"#.utf8
        )
        let metadata = GeminiResponseMetadataParser.makeMetadata(
            from: data,
            requestedModelID: "gemini-3.7-flash",
            effectiveModelID: "gemini-3.6-flash",
            retryCount: 4,
            fallbackReason: "HTTP 503",
            thinkingLevel: .low,
            latencySeconds: 3.5
        )

        XCTAssertEqual(metadata.modelVersion, "gemini-3.7-flash-202608")
        XCTAssertEqual(metadata.responseID, "resp-123")
        XCTAssertEqual(metadata.retryCount, 4)
        XCTAssertEqual(metadata.thinkingLevel, .low)
        XCTAssertEqual(metadata.usage?.thoughtsTokenCount, 12)
        XCTAssertEqual(metadata.usage?.totalTokenCount, 182)
        XCTAssertTrue(metadata.usedFallback)
    }

    func testRetryPolicyUsesExponentialBackoffJitterAndRetryInfo() {
        XCTAssertEqual(
            GeminiTransportHelper.RetryPolicy.backoffSeconds(
                forAttempt: 1,
                jitterFraction: 0
            ),
            1
        )
        XCTAssertEqual(
            GeminiTransportHelper.RetryPolicy.backoffSeconds(
                forAttempt: 3,
                jitterFraction: 0
            ),
            4
        )
        XCTAssertEqual(
            GeminiTransportHelper.RetryPolicy.backoffSeconds(
                forAttempt: 2,
                retryAfterSeconds: 9,
                jitterFraction: 0
            ),
            9
        )
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(
                GeminiTransportHelper.RetryPolicy
                    .isRetryableStatusCode(status)
            )
        }
        XCTAssertFalse(
            GeminiTransportHelper.RetryPolicy.isRetryableStatusCode(403)
        )
    }

    func testRetryInfoAndDailyQuotaClassification() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test"))
        let response = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )!
        let retryData = Data(
            #"{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"7.5s"}]}}"#.utf8
        )
        XCTAssertEqual(
            GeminiTransportHelper.retryAfterSeconds(
                response: response,
                data: retryData
            ),
            7.5
        )
        XCTAssertTrue(
            GeminiTransportHelper.isDailyQuotaExceeded(
                data: Data(#"{"quotaId":"GenerateRequestsPerDay"}"#.utf8),
                message: "quota exhausted"
            )
        )
        XCTAssertFalse(
            GeminiTransportHelper.isDailyQuotaExceeded(
                data: Data(),
                message: "rate limit exceeded per minute"
            )
        )
    }

    func testFallbackDefaultsOffAndMayBeExplicitlyEnabled() {
        XCTAssertEqual(
            GoogleAIStudioBackend.Configuration.default.fallbackPolicy,
            .disabled
        )
        XCTAssertEqual(
            VertexAIGeminiBackend.Configuration.default.fallbackPolicy,
            .disabled
        )
        XCTAssertEqual(
            GoogleAIStudioBackend.Configuration(
                fallbackPolicy: .flashOnly
            ).fallbackPolicy,
            .flashOnly
        )
    }
}
'''
write(
    "Tests/RecordToTextCoreTests/GeminiBackendObservabilityTests.swift",
    backend_tests,
)

print("Applied Gemini 3.7 backend observability and retry hardening")
