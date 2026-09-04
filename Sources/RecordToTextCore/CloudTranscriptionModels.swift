import Foundation

public enum GeminiThinkingLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low:
            return "低（速度優先）"
        case .medium:
            return "中"
        case .high:
            return "高（預設／品質優先）"
        }
    }
}

public enum CloudFallbackPolicy: String, Codable, CaseIterable, Sendable {
    case disabled
    case flashOnly

    public var displayName: String {
        switch self {
        case .disabled:
            return "不自動切換模型（推薦）"
        case .flashOnly:
            return "3.8 / 3.7 忙碌時允許改用 3.6 Flash"
        }
    }
}

public struct CloudUsageMetadata: Codable, Equatable, Sendable {
    public let promptTokenCount: Int?
    public let cachedContentTokenCount: Int?
    public let candidatesTokenCount: Int?
    public let thoughtsTokenCount: Int?
    public let totalTokenCount: Int?
    public let serviceTier: String?

    public init(
        promptTokenCount: Int? = nil,
        cachedContentTokenCount: Int? = nil,
        candidatesTokenCount: Int? = nil,
        thoughtsTokenCount: Int? = nil,
        totalTokenCount: Int? = nil,
        serviceTier: String? = nil
    ) {
        self.promptTokenCount = promptTokenCount
        self.cachedContentTokenCount = cachedContentTokenCount
        self.candidatesTokenCount = candidatesTokenCount
        self.thoughtsTokenCount = thoughtsTokenCount
        self.totalTokenCount = totalTokenCount
        self.serviceTier = serviceTier
    }

    public func merged(with other: CloudUsageMetadata) -> CloudUsageMetadata {
        CloudUsageMetadata(
            promptTokenCount: Self.sum(promptTokenCount, other.promptTokenCount),
            cachedContentTokenCount: Self.sum(
                cachedContentTokenCount,
                other.cachedContentTokenCount
            ),
            candidatesTokenCount: Self.sum(
                candidatesTokenCount,
                other.candidatesTokenCount
            ),
            thoughtsTokenCount: Self.sum(
                thoughtsTokenCount,
                other.thoughtsTokenCount
            ),
            totalTokenCount: Self.sum(totalTokenCount, other.totalTokenCount),
            serviceTier: serviceTier == other.serviceTier
                ? serviceTier
                : serviceTier ?? other.serviceTier
        )
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else {
            return nil
        }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}

public struct CloudTranscriptionMetadata: Codable, Equatable, Sendable {
    public let requestedModelID: String
    public let effectiveModelID: String
    public let modelVersion: String?
    public let responseID: String?
    public let retryCount: Int
    public let fallbackReason: String?
    public let thinkingLevel: GeminiThinkingLevel
    public let latencySeconds: Double?
    public let usage: CloudUsageMetadata?

    public init(
        requestedModelID: String,
        effectiveModelID: String,
        modelVersion: String? = nil,
        responseID: String? = nil,
        retryCount: Int = 0,
        fallbackReason: String? = nil,
        thinkingLevel: GeminiThinkingLevel = .high,
        latencySeconds: Double? = nil,
        usage: CloudUsageMetadata? = nil
    ) {
        self.requestedModelID = requestedModelID
        self.effectiveModelID = effectiveModelID
        self.modelVersion = modelVersion
        self.responseID = responseID
        self.retryCount = max(retryCount, 0)
        self.fallbackReason = fallbackReason
        self.thinkingLevel = thinkingLevel
        self.latencySeconds = latencySeconds
        self.usage = usage
    }

    public var usedFallback: Bool {
        requestedModelID != effectiveModelID || fallbackReason != nil
    }
}

public struct CloudTranscriptionResult: Equatable, Sendable {
    public let text: String
    public let metadata: CloudTranscriptionMetadata

    public init(text: String, metadata: CloudTranscriptionMetadata) {
        self.text = text
        self.metadata = metadata
    }
}

public struct CloudOutputTruncatedError: LocalizedError, Equatable, Sendable {
    public let partialText: String
    public let finishMessage: String?

    public init(partialText: String, finishMessage: String? = nil) {
        self.partialText = partialText
        self.finishMessage = finishMessage
    }

    public var errorDescription: String? {
        let detail = finishMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.flatMap { $0.isEmpty ? nil : "：\($0)" } ?? ""
        return "Gemini 輸出達 maxOutputTokens，逐字稿可能被截斷\(suffix)。App 將切小該段後重試，不會把這份部分文字當成正式完成稿。"
    }
}

public enum CloudTranscriptionMetadataAggregator {
    public static func uniqueEffectiveModelIDs(
        _ metadata: [CloudTranscriptionMetadata]
    ) -> [String] {
        var seen = Set<String>()
        return metadata.compactMap { item in
            seen.insert(item.effectiveModelID).inserted
                ? item.effectiveModelID
                : nil
        }
    }

    public static func totalUsage(
        _ metadata: [CloudTranscriptionMetadata]
    ) -> CloudUsageMetadata? {
        metadata.compactMap(\.usage).reduce(nil) { partial, usage in
            partial?.merged(with: usage) ?? usage
        }
    }

    public static func totalRetryCount(
        _ metadata: [CloudTranscriptionMetadata]
    ) -> Int {
        metadata.reduce(0) { $0 + $1.retryCount }
    }
}

public extension JobSnapshot {
    var requestedModelID: String {
        switch backendType {
        case .googleAIStudio:
            return googleAIStudioModelID
        case .vertexAI:
            return vertexAIModelID
        case .localQwen:
            return modelID
        }
    }
}

public extension TranscriptionJob {
    var resolvedCloudSegmentMetadata: [CloudTranscriptionMetadata] {
        cloudSegmentMetadata ?? []
    }

    var cloudModelSummary: String? {
        guard snapshot.backendType != .localQwen else {
            return nil
        }
        let metadata = resolvedCloudSegmentMetadata
        guard !metadata.isEmpty else {
            return snapshot.requestedModelID
        }
        let effective = CloudTranscriptionMetadataAggregator
            .uniqueEffectiveModelIDs(metadata)
        if effective == [snapshot.requestedModelID] {
            return snapshot.requestedModelID
        }
        return "要求：\(snapshot.requestedModelID)；實際：\(effective.joined(separator: ", "))"
    }

    var cloudTokenSummary: String? {
        guard snapshot.backendType != .localQwen else {
            return nil
        }
        let metadata = resolvedCloudSegmentMetadata
        guard !metadata.isEmpty else {
            return nil
        }
        let usage = CloudTranscriptionMetadataAggregator.totalUsage(metadata)
        let effective = CloudTranscriptionMetadataAggregator.uniqueEffectiveModelIDs(metadata)
        let model = effective.first ?? snapshot.requestedModelID
        return usage?.summaryDisplay(modelID: model)
    }
}

public extension RecentJobSummary {
    var cloudModelSummary: String? {
        guard backendType != .localQwen else {
            return nil
        }
        guard let effectiveModelIDs, !effectiveModelIDs.isEmpty else {
            return modelID
        }
        if effectiveModelIDs == [modelID] {
            return modelID
        }
        return "要求：\(modelID)；實際：\(effectiveModelIDs.joined(separator: ", "))"
    }

    var cloudTokenSummary: String? {
        guard backendType != .localQwen else {
            return nil
        }
        let model = effectiveModelIDs?.first ?? modelID
        return cloudUsage?.summaryDisplay(modelID: model)
    }
}

public extension CloudUsageMetadata {
    /// 依據 Google 官方定價（美元 / 1M Tokens）估算任務成本
    func estimatedCostUSD(modelID: String) -> Double? {
        guard let total = totalTokenCount, total > 0 else {
            return nil
        }

        let inputRatePer1M: Double
        let outputRatePer1M: Double

        if modelID.contains("3.8") || modelID.contains("3.7") {
            // Gemini 3.8 Flash & 3.7 Flash: Input $0.75/1M, Output $3.75/1M
            inputRatePer1M = 0.75
            outputRatePer1M = 3.75
        } else if modelID.contains("3.6") {
            // Gemini 3.6 Flash: Audio input $0.70/1M, Output $0.40/1M
            inputRatePer1M = 0.70
            outputRatePer1M = 0.40
        } else if modelID.contains("pro") {
            // Gemini 3.1 Pro: Input $1.25/1M, Output $5.00/1M
            inputRatePer1M = 1.25
            outputRatePer1M = 5.00
        } else {
            // 預設以最新 Flash 費率標準計算
            inputRatePer1M = 0.75
            outputRatePer1M = 3.75
        }

        if let prompt = promptTokenCount, let candidates = candidatesTokenCount {
            let promptCost = (Double(prompt) / 1_000_000.0) * inputRatePer1M
            let candidateCost = (Double(candidates) / 1_000_000.0) * outputRatePer1M
            return promptCost + candidateCost
        } else {
            // 若只有 totalTokenCount，錄音輸入約佔 95%，輸出約佔 5%
            let estimatedPrompt = Double(total) * 0.95
            let estimatedCandidate = Double(total) * 0.05
            let promptCost = (estimatedPrompt / 1_000_000.0) * inputRatePer1M
            let candidateCost = (estimatedCandidate / 1_000_000.0) * outputRatePer1M
            return promptCost + candidateCost
        }
    }

    /// 格式化 Token 數量（例如：79228 -> "79.2k", 1212 -> "1.2k", 500 -> "500"）
    static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let val = Double(count) / 1_000_000.0
            return String(format: "%.1fm", val)
        } else if count >= 1_000 {
            let val = Double(count) / 1_000.0
            return String(format: "%.1fk", val)
        } else {
            return "\(count)"
        }
    }

    /// 格式化美元金額（例如：0.072 -> "$0.07"；若小於 0.01 則顯示 "< $0.01"）
    static func formatCostUSD(_ cost: Double) -> String {
        if cost <= 0 {
            return "$0.00"
        } else if cost < 0.01 {
            return "< $0.01"
        } else {
            return String(format: "$%.2f", cost)
        }
    }

    /// 產生格式如「79.2k tokens (思考 1.2k)，預估 $0.07」的完整顯示字串
    func summaryDisplay(modelID: String) -> String? {
        guard let total = totalTokenCount, total > 0 else {
            return nil
        }
        var parts: [String] = []
        let totalFormatted = Self.formatTokenCount(total)
        if let thoughts = thoughtsTokenCount, thoughts > 0 {
            let thoughtsFormatted = Self.formatTokenCount(thoughts)
            parts.append("\(totalFormatted) tokens (思考 \(thoughtsFormatted))")
        } else {
            parts.append("\(totalFormatted) tokens")
        }

        if let cost = estimatedCostUSD(modelID: modelID) {
            parts.append("預估 \(Self.formatCostUSD(cost))")
        }

        return parts.joined(separator: "，")
    }
}
