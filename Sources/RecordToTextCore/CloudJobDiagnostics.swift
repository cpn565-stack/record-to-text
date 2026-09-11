import Foundation

public enum CloudDiagnosticStage: String, Codable, CaseIterable, Sendable {
    case auth, upload, poll, generation, backoff
}

public enum CloudRetryReason: String, Codable, Sendable {
    case rateLimited, serverError, network, emptyResponse
    case authenticationRefresh, transportReset, modelFallback, inlineUploadFallback
}

public struct CloudStageTiming: Codable, Equatable, Sendable {
    public let stage: CloudDiagnosticStage
    public let seconds: Double
}

public struct CloudSegmentDiagnostic: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, split, blocked }
    public let startSeconds: Double
    public let endSeconds: Double
    public let outcome: Outcome
    public var reusedFromCheckpoint: Bool
    public let preparationSeconds: Double?
    /// Includes authentication, transfer, server processing, retries and cleanup.
    public let cloudSeconds: Double?
    /// Observed request durations; generation includes network transfer.
    public let stageTimings: [CloudStageTiming]
    public let retryReasons: [CloudRetryReason]
    public var timestampReview: TranscriptTimestampReview?

    public init(startSeconds: Double, endSeconds: Double, outcome: Outcome,
                reusedFromCheckpoint: Bool = false, preparationSeconds: Double? = nil,
                cloudSeconds: Double? = nil, stageTimings: [CloudStageTiming] = [],
                retryReasons: [CloudRetryReason] = [], timestampReview: TranscriptTimestampReview? = nil) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.outcome = outcome
        self.reusedFromCheckpoint = reusedFromCheckpoint; self.preparationSeconds = preparationSeconds
        self.cloudSeconds = cloudSeconds; self.stageTimings = stageTimings
        self.retryReasons = retryReasons; self.timestampReview = timestampReview
    }
}

public struct CloudJobDiagnostics: Codable, Equatable, Sendable {
    public let audioDurationSeconds: Double
    public let segments: [CloudSegmentDiagnostic]
    public let postprocessingSeconds: Double

    public var timestampNotice: String? {
        let count = segments.filter { $0.outcome == .completed && $0.timestampReview?.needsReview == true }.count
        return count > 0 ? "\(count) 個片段的段內時間待核對；全文已保留，請依稿內實際音訊範圍回查。" : nil
    }

    /// Fixed fields only: no audio, transcript, prompt, paths, URLs or raw errors.
    public var debugSummary: String {
        var lines = ["音訊長度：\(String(format: "%.1f", audioDurationSeconds)) 秒",
                     "後處理：\(String(format: "%.2f", postprocessingSeconds)) 秒",
                     "生成請求耗時包含網路傳輸與伺服器處理；沿用片段的耗時屬前次執行。"]
        for segment in segments {
            var parts = [TranscriptTimestampValidator.range(start: segment.startSeconds, end: segment.endSeconds),
                         segment.outcome.rawValue]
            if segment.reusedFromCheckpoint { parts.append("沿用檢查點") }
            if let seconds = segment.preparationSeconds { parts.append(String(format: "前處理=%.2fs", seconds)) }
            if let seconds = segment.cloudSeconds { parts.append(String(format: "雲端呼叫=%.2fs", seconds)) }
            for timing in segment.stageTimings { parts.append(String(format: "%@=%.2fs", timing.stage.rawValue, timing.seconds)) }
            if !segment.retryReasons.isEmpty { parts.append("重試／切換原因=" + segment.retryReasons.map(\.rawValue).joined(separator: ",")) }
            if let review = segment.timestampReview { parts.append("時間標記=" + review.disposition.rawValue) }
            lines.append(parts.joined(separator: "；"))
        }
        return lines.joined(separator: "\n")
    }
}

/// Per-call task-local collector. It accepts only fixed enums, never logger text.
final class CloudDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var timings: [CloudDiagnosticStage: Double] = [:]
    private var reasons: [CloudRetryReason] = []

    func record(stage: CloudDiagnosticStage, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.withLock { timings[stage, default: 0] += seconds }
    }
    func retry(_ reason: CloudRetryReason) {
        lock.withLock { if reasons.count < 64 { reasons.append(reason) } }
    }
    func snapshot(start: Double, end: Double, outcome: CloudSegmentDiagnostic.Outcome,
                  preparation: Double?, cloud: Double?, review: TranscriptTimestampReview? = nil) -> CloudSegmentDiagnostic {
        lock.withLock {
            .init(startSeconds: start, endSeconds: end, outcome: outcome,
                  preparationSeconds: preparation, cloudSeconds: cloud,
                  stageTimings: CloudDiagnosticStage.allCases.compactMap { stage in
                      timings[stage].map { .init(stage: stage, seconds: $0) }
                  }, retryReasons: reasons, timestampReview: review)
        }
    }
}

enum CloudDiagnosticContext {
    @TaskLocal static var current: CloudDiagnosticCollector?
}
