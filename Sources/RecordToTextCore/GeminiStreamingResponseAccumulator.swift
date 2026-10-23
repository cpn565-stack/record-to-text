import Foundation

/// Indicates that an HTTP 200 SSE stream reached normal EOF without any
/// terminal finishReason, prompt block, or explicit error event.
public struct CloudIncompleteStreamError: LocalizedError, Equatable, Sendable {
    public init() {}

    public var errorDescription: String? {
        "連到 Google 的串流回應在收到終止原因前結束。"
    }
}

/// Normalized server error emitted inside an HTTP 200 SSE event.
public struct GeminiStreamServerError: LocalizedError, Equatable, Sendable {
    public let statusCode: Int
    public let message: String
    public let errorData: Data
    public var httpResponse: HTTPURLResponse?

    public init(statusCode: Int, message: String, errorData: Data, httpResponse: HTTPURLResponse? = nil) {
        self.statusCode = statusCode
        self.message = message
        self.errorData = errorData
        self.httpResponse = httpResponse
    }

    public var errorDescription: String? {
        "Vertex AI 串流回報錯誤（HTTP \(statusCode)）：\(message)"
    }
}

/// Per-attempt SSE response accumulator for Vertex Gemini audio transcription.
/// Processes bytes incrementally and produces a single validated response
/// dictionary only after clean stream completion.
public final class GeminiStreamingResponseAccumulator {
    private static let rpcStatusToHTTP: [String: Int] = [
        "INVALID_ARGUMENT": 400,
        "FAILED_PRECONDITION": 400,
        "OUT_OF_RANGE": 400,
        "UNAUTHENTICATED": 401,
        "PERMISSION_DENIED": 403,
        "NOT_FOUND": 404,
        "ABORTED": 409,
        "ALREADY_EXISTS": 409,
        "RESOURCE_EXHAUSTED": 429,
        "INTERNAL": 500,
        "UNIMPLEMENTED": 501,
        "UNAVAILABLE": 503,
        "DEADLINE_EXCEEDED": 504
    ]

    public let limits: GeminiStreamingLimits
    private let onFirstTextDelta: (() -> Void)?
    private var sseParser: GeminiSSEParser!

    public private(set) var accumulatedText: String = ""
    public private(set) var accumulatedTextBytes: Int = 0
    public private(set) var finishReason: String?
    public private(set) var finishMessage: String?
    public private(set) var latestModelVersion: String?
    public private(set) var latestResponseID: String?
    public private(set) var latestServiceTier: String?
    public private(set) var sawDoneMarker: Bool = false

    private var candidateSafetyRatings: [[String: Any]]?
    private var mergedPromptFeedback: [String: Any] = [:]
    private var latestUsage: [String: Any] = [:]
    private var sawCandidateZero = false
    private var sawCandidateParts = false
    private var sawTextPart = false
    private var sawThoughtPart = false
    private var sawOtherCandidate = false
    private var sawOtherCandidateFinishReason = false
    private var sawEmptyCandidatesArray = false
    private var hasRecordedFirstTextDelta = false

    public var totalReceivedBytes: Int {
        sseParser.totalReceivedBytes
    }

    public var sseEventCount: Int {
        sseParser.dispatchedEventCount
    }

    public init(
        limits: GeminiStreamingLimits = .default,
        onFirstTextDelta: (() -> Void)? = nil
    ) {
        self.limits = limits
        self.onFirstTextDelta = onFirstTextDelta
        self.sseParser = GeminiSSEParser(limits: limits) { [weak self] payload in
            try self?.handleEventPayload(payload)
        }
    }

    public func append(_ data: Data) throws {
        try sseParser.append(data)
    }

    /// Finalizes the SSE stream at normal EOF and returns the synthesized
    /// GenerateContentResponse JSON object.
    public func finishJSON(httpStatusCode: Int = 200) throws -> [String: Any] {
        try sseParser.finish()

        var synthesized = buildMetadataDictionary()

        if GeminiPromptFeedbackParser.diagnosticsIfBlocked(
            from: synthesized,
            httpStatusCode: httpStatusCode
        ) != nil {
            return synthesized
        }

        if !sawCandidateZero {
            if sawOtherCandidateFinishReason || sawEmptyCandidatesArray {
                synthesized["candidates"] = [] as [[String: Any]]
                return synthesized
            }
            throw CloudIncompleteStreamError()
        }

        guard let finishReason else {
            throw CloudIncompleteStreamError()
        }

        var candidate: [String: Any] = [
            "index": 0,
            "finishReason": finishReason
        ]
        if let finishMessage {
            candidate["finishMessage"] = finishMessage
        }
        if let candidateSafetyRatings {
            candidate["safetyRatings"] = candidateSafetyRatings
        }
        if sawTextPart {
            candidate["content"] = [
                "role": "model",
                "parts": [["text": accumulatedText]]
            ]
        } else if sawThoughtPart {
            candidate["content"] = [
                "role": "model",
                "parts": [["thought": true]]
            ]
        } else if sawCandidateParts {
            candidate["content"] = [
                "role": "model",
                "parts": [] as [[String: Any]]
            ]
        }

        synthesized["candidates"] = [candidate]
        return synthesized
    }

    public func finishData(httpStatusCode: Int = 200) throws -> Data {
        let json = try finishJSON(httpStatusCode: httpStatusCode)
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func buildMetadataDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let latestModelVersion {
            dict["modelVersion"] = latestModelVersion
        }
        if let latestResponseID {
            dict["responseId"] = latestResponseID
        }
        if let latestServiceTier {
            dict["serviceTier"] = latestServiceTier
        }
        if !mergedPromptFeedback.isEmpty {
            dict["promptFeedback"] = mergedPromptFeedback
        }
        if !latestUsage.isEmpty {
            dict["usageMetadata"] = latestUsage
        }
        return dict
    }

    private func handleEventPayload(_ rawPayload: String) throws {
        var payload = rawPayload
        if payload.first == "\u{FEFF}" {
            payload.removeFirst()
        }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return
        }
        if trimmed == "[DONE]" {
            sawDoneMarker = true
            return
        }

        guard let data = payload.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let json = rawObject as? [String: Any]
        else {
            throw GeminiSSEError.invalidEventJSON
        }

        if let rawError = json["error"] {
            try Self.throwNormalizedStreamError(rawError)
        }

        try mergeTopLevelMetadata(from: json)
        try mergeUsageMetadata(from: json["usageMetadata"])
        try mergePromptFeedback(from: json["promptFeedback"])
        try processCandidates(from: json["candidates"])
    }

    private func mergeTopLevelMetadata(from json: [String: Any]) throws {
        if let rawModelVersion = json["modelVersion"], !(rawModelVersion is NSNull) {
            guard let modelVersion = rawModelVersion as? String else {
                throw GeminiSSEError.invalidEventJSON
            }
            if !modelVersion.isEmpty {
                latestModelVersion = modelVersion
            }
        }

        if let rawResponseID = json["responseId"], !(rawResponseID is NSNull) {
            guard let responseID = rawResponseID as? String else {
                throw GeminiSSEError.invalidEventJSON
            }
            if !responseID.isEmpty {
                latestResponseID = responseID
            }
        }

        if let rawServiceTier = json["serviceTier"], !(rawServiceTier is NSNull) {
            guard let serviceTier = rawServiceTier as? String else {
                throw GeminiSSEError.invalidEventJSON
            }
            if !serviceTier.isEmpty {
                latestServiceTier = serviceTier
            }
        }
    }

    private func mergeUsageMetadata(from rawUsage: Any?) throws {
        guard let rawUsage, !(rawUsage is NSNull) else { return }
        guard let usage = rawUsage as? [String: Any] else {
            throw GeminiSSEError.invalidEventJSON
        }

        let tokenKeys = [
            "promptTokenCount",
            "cachedContentTokenCount",
            "candidatesTokenCount",
            "thoughtsTokenCount",
            "totalTokenCount"
        ]
        for key in tokenKeys {
            guard let rawValue = usage[key], !(rawValue is NSNull) else { continue }
            guard let intValue = Self.strictInteger(rawValue), intValue >= 0 else {
                throw GeminiSSEError.invalidEventJSON
            }
            latestUsage[key] = intValue
        }

        if let rawTrafficType = usage["trafficType"], !(rawTrafficType is NSNull) {
            guard let trafficType = rawTrafficType as? String else {
                throw GeminiSSEError.invalidEventJSON
            }
            if !trafficType.isEmpty {
                latestUsage["trafficType"] = trafficType
                latestServiceTier = trafficType
            }
        }

        for detailKey in ["promptTokensDetails", "promptTokenDetails", "candidatesTokensDetails", "candidatesTokenDetails"] {
            guard let rawDetails = usage[detailKey], !(rawDetails is NSNull) else { continue }
            guard let details = rawDetails as? [[String: Any]] else {
                throw GeminiSSEError.invalidEventJSON
            }
            latestUsage[detailKey] = details
        }
    }

    private func mergePromptFeedback(from rawFeedback: Any?) throws {
        guard let rawFeedback, !(rawFeedback is NSNull) else { return }
        guard let feedback = rawFeedback as? [String: Any] else {
            throw GeminiSSEError.invalidEventJSON
        }
        for (key, value) in feedback where !(value is NSNull) {
            mergedPromptFeedback[key] = value
        }
    }

    private func processCandidates(from rawCandidates: Any?) throws {
        guard let rawCandidates, !(rawCandidates is NSNull) else { return }
        guard let candidates = rawCandidates as? [[String: Any]] else {
            throw GeminiSSEError.invalidEventJSON
        }
        if candidates.isEmpty {
            sawEmptyCandidatesArray = true
            return
        }

        var explicitZeroCandidate: [String: Any]?
        for candidate in candidates {
            if let rawIndex = candidate["index"], !(rawIndex is NSNull) {
                guard let idx = Self.strictInteger(rawIndex) else {
                    throw GeminiSSEError.invalidEventJSON
                }
                if idx == 0 {
                    if explicitZeroCandidate == nil {
                        explicitZeroCandidate = candidate
                    }
                } else {
                    noteOtherCandidate(candidate)
                }
            } else if candidates.count > 1 {
                noteOtherCandidate(candidate)
            }
        }

        let selectedCandidate: [String: Any]?
        if let explicitZeroCandidate {
            selectedCandidate = explicitZeroCandidate
        } else if candidates.count == 1, let first = candidates.first, first["index"] == nil || first["index"] is NSNull {
            selectedCandidate = first
        } else {
            selectedCandidate = nil
        }

        guard let candidateZero = selectedCandidate else { return }
        sawCandidateZero = true

        if let rawFinishMessage = candidateZero["finishMessage"], !(rawFinishMessage is NSNull) {
            guard let msg = rawFinishMessage as? String else {
                throw GeminiSSEError.invalidEventJSON
            }
            if !msg.isEmpty {
                finishMessage = msg
            }
        }

        if let rawRatings = candidateZero["safetyRatings"], !(rawRatings is NSNull) {
            guard let ratings = rawRatings as? [[String: Any]] else {
                throw GeminiSSEError.invalidEventJSON
            }
            if !ratings.isEmpty {
                candidateSafetyRatings = ratings
            }
        }

        let priorFinishReason = self.finishReason
        if let rawReason = candidateZero["finishReason"], !(rawReason is NSNull) {
            guard let reasonStr = rawReason as? String else {
                throw GeminiSSEError.invalidEventJSON
            }
            let normalized = GeminiTranscriptFinishReason.normalized(reasonStr)
            if !normalized.isEmpty && normalized != "FINISH_REASON_UNSPECIFIED" {
                if let existing = self.finishReason {
                    if GeminiTranscriptFinishReason.normalized(existing) != normalized {
                        throw GeminiSSEError.contradictoryFinishReason(first: existing, second: reasonStr)
                    }
                } else {
                    self.finishReason = reasonStr
                }
            }
        }

        if let rawContent = candidateZero["content"], !(rawContent is NSNull) {
            guard let content = rawContent as? [String: Any] else {
                throw GeminiSSEError.invalidEventJSON
            }
            if let rawParts = content["parts"], !(rawParts is NSNull) {
                guard let parts = rawParts as? [[String: Any]] else {
                    throw GeminiSSEError.invalidEventJSON
                }
                sawCandidateParts = true
                for part in parts {
                    if let rawThought = part["thought"], !(rawThought is NSNull) {
                        guard let isThought = Self.strictBool(rawThought) else {
                            throw GeminiSSEError.invalidEventJSON
                        }
                        if isThought {
                            sawThoughtPart = true
                            continue
                        }
                    }

                    if let rawText = part["text"], !(rawText is NSNull) {
                        guard let text = rawText as? String else {
                            throw GeminiSSEError.invalidEventJSON
                        }
                        sawTextPart = true
                        if !text.isEmpty {
                            if let priorFinishReason {
                                throw GeminiSSEError.textAfterFinishReason(priorFinishReason)
                            }
                            let deltaBytes = text.utf8.count
                            if accumulatedTextBytes + deltaBytes > limits.maxPublishableTextBytes {
                                throw GeminiSSEError.publishableTextTooLarge(limitBytes: limits.maxPublishableTextBytes)
                            }
                            accumulatedTextBytes += deltaBytes
                            accumulatedText.append(text)
                            if !hasRecordedFirstTextDelta {
                                hasRecordedFirstTextDelta = true
                                onFirstTextDelta?()
                            }
                        }
                    }
                }
            }
        }
    }

    private func noteOtherCandidate(_ candidate: [String: Any]) {
        sawOtherCandidate = true
        if let reason = candidate["finishReason"] as? String {
            let normalized = GeminiTranscriptFinishReason.normalized(reason)
            if !normalized.isEmpty && normalized != "FINISH_REASON_UNSPECIFIED" {
                sawOtherCandidateFinishReason = true
            }
        }
    }

    private static func throwNormalizedStreamError(_ rawError: Any) throws -> Never {
        guard let errorDict = rawError as? [String: Any] else {
            throw GeminiSSEError.invalidEventJSON
        }

        var statusString: String?
        if let rawStatus = errorDict["status"], !(rawStatus is NSNull) {
            guard let str = rawStatus as? String else {
                throw GeminiSSEError.invalidEventJSON
            }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !trimmed.isEmpty {
                statusString = trimmed
            }
        }

        var httpCode: Int?
        if let rawCode = errorDict["code"], !(rawCode is NSNull) {
            guard let code = strictInteger(rawCode) else {
                throw GeminiSSEError.invalidEventJSON
            }
            if (400...599).contains(code) {
                httpCode = code
            }
        }

        let resolvedStatus: Int
        if let statusString {
            guard let mapped = rpcStatusToHTTP[statusString] else {
                throw GeminiSSEError.invalidEventJSON
            }
            if let httpCode, httpCode != mapped {
                throw GeminiSSEError.invalidEventJSON
            }
            resolvedStatus = mapped
        } else if let httpCode {
            resolvedStatus = httpCode
        } else {
            throw GeminiSSEError.invalidEventJSON
        }

        var message = ""
        if let rawMessage = errorDict["message"], !(rawMessage is NSNull) {
            guard let str = rawMessage as? String else {
                throw GeminiSSEError.invalidEventJSON
            }
            message = str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if message.isEmpty {
            message = statusString ?? "HTTP \(resolvedStatus)"
        }

        if let rawDetails = errorDict["details"], !(rawDetails is NSNull) {
            guard rawDetails is [[String: Any]] else {
                throw GeminiSSEError.invalidEventJSON
            }
        }

        let errorPayload: [String: Any] = ["error": errorDict]
        let errorData = (try? JSONSerialization.data(withJSONObject: errorPayload)) ?? Data()
        throw GeminiStreamServerError(
            statusCode: resolvedStatus,
            message: message,
            errorData: errorData
        )
    }

    private static func strictInteger(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let doubleVal = number.doubleValue
            guard doubleVal.isFinite, floor(doubleVal) == doubleVal,
                  doubleVal >= Double(Int.min), doubleVal <= Double(Int.max) else {
                return nil
            }
            return number.intValue
        }
        return value as? Int
    }

    private static func strictBool(_ value: Any) -> Bool? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        return value as? Bool
    }
}
