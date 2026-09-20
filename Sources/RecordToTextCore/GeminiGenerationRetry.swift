import Foundation

/// Owns generation service retries and the user's optional model fallback.
/// Transport recovery remains in GeminiTransportHelper; both consume the same
/// per-segment/model task quota and root deadline.
enum GeminiGenerationRetry {
    private struct Retry {
        let reason: CloudRetryReason
        var retryAfterSeconds: Double?

        var message: String {
            switch reason {
            case .emptyResponse: return "回報 STOP 但沒有逐字稿文字，將沿用同一模型與音訊重試"
            case .network: return "網路暫時中斷"
            default: return "暫時忙碌"
            }
        }
    }

    static func run(
        preferredModelID: String,
        fallbackPolicy: CloudFallbackPolicy,
        serviceName: String,
        logger: ((_ level: String, _ message: String) -> Void)?,
        operation: (_ modelID: String, _ retryCount: Int, _ fallbackReason: String?) async throws -> CloudTranscriptionResult
    ) async throws -> CloudTranscriptionResult {
        do {
            return try await attempts(modelID: preferredModelID, priorRetryCount: 0,
                fallbackReason: nil, serviceName: serviceName, logger: logger, operation: operation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard fallbackPolicy == .flashOnly,
                  preferredModelID.contains("3.7") || preferredModelID.contains("3.8"),
                  isRetryableServerFailure(error) else { throw error }
            let model = "gemini-3.6-flash"
            let reason = error.localizedDescription
            CloudDiagnosticContext.current?.retry(.modelFallback)
            logger?("warning", "Gemini 重試後仍不可用；依使用者設定改用 \(model)。原始原因：\(reason)")
            return try await attempts(modelID: model,
                priorRetryCount: GeminiTransportHelper.RetryPolicy.maximumAttempts - 1,
                fallbackReason: reason, serviceName: serviceName, logger: logger, operation: operation)
        }
    }

    static func isRetryableServerFailure(_ error: Error) -> Bool {
        guard let retry = retry(for: error) else { return false }
        return retry.reason == .rateLimited || retry.reason == .serverError
    }

    private static func attempts(
        modelID: String,
        priorRetryCount: Int,
        fallbackReason: String?,
        serviceName: String,
        logger: ((_ level: String, _ message: String) -> Void)?,
        operation: (String, Int, String?) async throws -> CloudTranscriptionResult
    ) async throws -> CloudTranscriptionResult {
        let quota = CloudNetworkContext.segmentAttempts?.quota(for: modelID) ?? CloudRequestAttempts()
        return try await CloudNetworkContext.$generation.withValue(quota) {
            let policy = GeminiTransportHelper.RetryPolicy.self
            CloudDiagnosticContext.current?.setModel(modelID)
            var attempt = 1
            while true {
                try CloudBudgetContext.check("generation")
                if let budget = CloudBudgetContext.current {
                    logger?("info", "budget root=\(budget.rootSegmentID) model=\(modelID) attempt=\(attempt) elapsed=\(budget.elapsed().secondsValue) remaining=\(budget.remaining().secondsValue)")
                }
                do {
                    return try await operation(modelID, priorRetryCount + attempt - 1, fallbackReason)
                } catch {
                    if error is CancellationError || Task.isCancelled || GeminiTransportHelper.isNetworkCancellation(error) {
                        throw CancellationError()
                    }
                    CloudDiagnosticContext.current?.failure(error, stage: .generation)
                    guard let retry = retry(for: error) else { throw error }
                    guard attempt < policy.maximumAttempts, quota.count < policy.maximumAttempts else {
                        if retry.reason == .emptyResponse {
                            logger?("warning", "Vertex Gemini 連續嘗試後仍回傳 STOP 空內容，已達最多 \(policy.maximumAttempts) 次嘗試；停止自動重試並保留已完成片段。")
                        }
                        throw error
                    }
                    let delay = policy.backoffSeconds(forAttempt: attempt, retryAfterSeconds: retry.retryAfterSeconds)
                    try CloudBudgetContext.validateBackoff(seconds: delay)
                    CloudDiagnosticContext.current?.retry(retry.reason)
                    logger?("info", "\(serviceName) \(modelID) \(retry.message)，\(String(format: "%.1f", delay)) 秒後進行第 \(attempt + 1) 次嘗試。")
                    try await CloudBudgetContext.backoff(seconds: delay)
                    attempt += 1
                }
            }
        }
    }

    private static func retry(for error: Error) -> Retry? {
        switch error {
        case let error as GoogleAIStudioError:
            switch error {
            case let .rateLimited(_, delay): return .init(reason: .rateLimited, retryAfterSeconds: delay)
            case let .requestFailed(status, _) where GeminiTransportHelper.RetryPolicy.isRetryableStatusCode(status):
                return .init(reason: .serverError)
            default: return nil
            }
        case let error as VertexAIError:
            switch error {
            case let .rateLimited(_, delay): return .init(reason: .rateLimited, retryAfterSeconds: delay)
            case let .requestFailed(status, _) where GeminiTransportHelper.RetryPolicy.isRetryableStatusCode(status):
                return .init(reason: .serverError)
            case .emptyCompletedResponse: return .init(reason: .emptyResponse)
            default: return nil
            }
        default:
            return GeminiTransportHelper.isTransientNetworkFailure(error) ? .init(reason: .network) : nil
        }
    }
}
