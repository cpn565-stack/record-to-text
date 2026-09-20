import Foundation

public enum CloudDiagnosticStage: String, Codable, CaseIterable, Sendable {
    case auth, upload, poll, generation, backoff
    case extract, probe, split, validate, commit, cleanup, unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum CloudRetryReason: String, Codable, Sendable {
    case rateLimited, serverError, network, emptyResponse
    case authenticationRefresh, transportReset, modelFallback, inlineUploadFallback, unknown
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct CloudStageTiming: Codable, Equatable, Sendable {
    public let stage: CloudDiagnosticStage
    public let seconds: Double
}

public struct CloudSegmentDiagnostic: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case completed, split, blocked, failed, cancelled, deadlineExceeded, unknown
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
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
    public var failure: CloudFailureDiagnostic?
    public var generationRequestCount: Int?

    public init(startSeconds: Double, endSeconds: Double, outcome: Outcome,
                reusedFromCheckpoint: Bool = false, preparationSeconds: Double? = nil,
                cloudSeconds: Double? = nil, stageTimings: [CloudStageTiming] = [],
                retryReasons: [CloudRetryReason] = [], timestampReview: TranscriptTimestampReview? = nil,
                failure: CloudFailureDiagnostic? = nil, generationRequestCount: Int? = nil) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.outcome = outcome
        self.reusedFromCheckpoint = reusedFromCheckpoint; self.preparationSeconds = preparationSeconds
        self.cloudSeconds = cloudSeconds; self.stageTimings = stageTimings
        self.retryReasons = retryReasons; self.timestampReview = timestampReview
        self.failure = failure; self.generationRequestCount = generationRequestCount
    }
}

public struct CloudJobDiagnostics: Codable, Equatable, Sendable {
    public let audioDurationSeconds: Double
    public let segments: [CloudSegmentDiagnostic]
    public let postprocessingSeconds: Double
    public var failureHistory: CloudFailureHistory?

    public static func load(manifestURL: URL) -> Self? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AudioSegmentManifest.self, from: data) else { return nil }
        return .init(audioDurationSeconds: manifest.sourceDurationSeconds,
                     segments: (manifest.discardedDiagnostics ?? []) + manifest.segments.compactMap(\.diagnostic),
                     postprocessingSeconds: 0, failureHistory: manifest.failureHistory)
    }

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
            if let count = segment.generationRequestCount { parts.append("App 生成發送=\(count)") }
            if let failure = segment.failure { parts.append(failure.debugSummary) }
            lines.append(parts.joined(separator: "；"))
        }
        if let history = failureHistory {
            lines.append("失敗事件=\(history.totalEventCount)；保留=\(history.events.count)；App 生成發送=\(history.generationRequestCount)")
            lines += history.events.map {
                "\($0.timestamp.ISO8601Format())；root=\($0.rootSegmentID?.uuidString ?? "unknown")；segment=\($0.segmentIndex ?? 0)；attempt=\($0.attempt)；path=\($0.path?.rawValue ?? "unknown")；wait=\($0.networkWaitSeconds ?? 0)；sessionReset=\($0.sessionWasReset ?? false)；resultUnknown=\($0.resultUnknown)；" + $0.failure.debugSummary
                    + ($0.recoveryStopReason.map { "；recoveryStopReason=\($0.rawValue)" } ?? "")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Per-call task-local collector. It accepts only fixed enums, never logger text.
final class CloudDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var timings: [CloudDiagnosticStage: Double] = [:]
    private var reasons: [CloudRetryReason] = []
    private var generationRequestCount = 0
    private var attempt = 0
    private var stageAttempts: [CloudDiagnosticStage: Int] = [:]
    private var lastFailure: CloudFailureDiagnostic?
    private var lastRecoveryStopReason: CloudNetworkRecovery.StopReason?
    private let history: CloudFailureHistoryCollector?
    private let rootSegmentID: UUID?
    private let segmentIndex: Int?
    private let completedSegmentCount: Int
    private let budget: CloudSegmentBudget?
    private let network: CloudNetworkRecoveryContext?
    private var modelID: String?

    init(history: CloudFailureHistoryCollector? = nil, rootSegmentID: UUID? = nil,
         segmentIndex: Int? = nil, completedSegmentCount: Int = 0, budget: CloudSegmentBudget? = nil,
         network: CloudNetworkRecoveryContext? = nil) {
        self.history = history; self.rootSegmentID = rootSegmentID
        self.segmentIndex = segmentIndex; self.completedSegmentCount = completedSegmentCount
        self.budget = budget
        self.network = network
    }

    func setModel(_ model: String) {
        let safe = model.count <= 120 && model.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
        lock.withLock { modelID = safe ? model : "custom" }
    }

    func requestStarted(stage: CloudDiagnosticStage) {
        lock.withLock {
            stageAttempts[stage, default: 0] += 1
            attempt = stageAttempts[stage, default: 0]
            lastFailure = nil
            lastRecoveryStopReason = nil
            if stage == .generation { generationRequestCount += 1; history?.generationStarted() }
        }
    }

    @discardableResult
    func failure(_ error: Error, stage: CloudDiagnosticStage) -> CloudFailureDiagnostic {
        if let pipeline = error as? PipelineExecutionError {
            return failure(pipeline.underlying, stage: stage)
        }
        if let segment = error as? CloudSegmentExecutionError {
            return failure(segment.diagnostic, recoveryStopReason:
                (segment.underlying as? CloudNetworkRecoveryExhausted)?.recovery.stopReason)
        }
        return failure(CloudFailureDiagnostic.classify(error, stage: stage), recoveryStopReason:
            (error as? CloudNetworkRecoveryExhausted)?.recovery.stopReason)
    }

    @discardableResult
    func failure(_ diagnostic: CloudFailureDiagnostic,
                 recoveryStopReason: CloudNetworkRecovery.StopReason? = nil) -> CloudFailureDiagnostic {
        let context = network ?? CloudNetworkContext.current
        let stopReason = recoveryStopReason ?? context?.snapshot().stopReason
        // Read context before taking the collector lock: session replacement
        // can record a retry while holding the context lock.
        let path = context?.environment.path() ?? .unknown
        let waitedSeconds = context?.waitedSeconds
        let sessionWasReset = context?.sessionWasReset
        let rootRemainingSeconds = (budget ?? CloudBudgetContext.current)?.remaining().secondsValue
        return lock.withLock {
            // Transport, retry loop and engine can observe the same failure.
            // Exhausting recovery is a separate terminal event, even if its
            // underlying network failure is unchanged.
            guard lastFailure != diagnostic || lastRecoveryStopReason != stopReason else { return diagnostic }
            lastFailure = diagnostic
            lastRecoveryStopReason = stopReason
            history?.record(.init(timestamp: Date(), rootSegmentID: rootSegmentID,
                                  segmentIndex: segmentIndex, modelID: modelID, attempt: attempt,
                                  completedSegmentCount: completedSegmentCount,
                                  rootRemainingSeconds: rootRemainingSeconds,
                                  resultUnknown: generationRequestCount > 0 && diagnostic.isTransientNetworkFailure,
                                  failure: diagnostic, path: path,
                                  networkWaitSeconds: waitedSeconds,
                                  sessionWasReset: sessionWasReset,
                                  recoveryStopReason: stopReason))
            return diagnostic
        }
    }

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
                  }, retryReasons: reasons, timestampReview: review,
                  failure: lastFailure, generationRequestCount: generationRequestCount)
        }
    }
}

public struct CloudFailureEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let rootSegmentID: UUID?
    public let segmentIndex: Int?
    public let modelID: String?
    public let attempt: Int
    public let completedSegmentCount: Int
    public let rootRemainingSeconds: Double?
    public let resultUnknown: Bool
    public let failure: CloudFailureDiagnostic
    public var path: CloudNetworkPath?
    public var networkWaitSeconds: Double?
    public var sessionWasReset: Bool?
    public var recoveryStopReason: CloudNetworkRecovery.StopReason?
}

public struct CloudFailureHistory: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let appBuild: String?
    public let jobID: UUID
    public let backend: ASRBackendType
    public let totalEventCount: Int
    public let generationRequestCount: Int
    public let events: [CloudFailureEvent]
}

/// The event cap is per job, shared by all root segments and adaptive children.
final class CloudFailureHistoryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let jobID: UUID
    private let backend: ASRBackendType
    private var events: [CloudFailureEvent] = []
    private var totalEventCount = 0
    private var generationRequestCount = 0
    init(jobID: UUID, backend: ASRBackendType) { self.jobID = jobID; self.backend = backend }
    func generationStarted() { lock.withLock { generationRequestCount += 1 } }
    func record(_ event: CloudFailureEvent) {
        lock.withLock {
            totalEventCount += 1
            events.append(event)
            if events.count > 100 { events.removeFirst(events.count - 100) }
        }
    }
    func snapshot() -> CloudFailureHistory {
        lock.withLock {
            .init(schemaVersion: 1, appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  jobID: jobID, backend: backend, totalEventCount: totalEventCount,
                  generationRequestCount: generationRequestCount, events: events)
        }
    }
}

enum CloudDiagnosticContext {
    @TaskLocal static var current: CloudDiagnosticCollector?
}
