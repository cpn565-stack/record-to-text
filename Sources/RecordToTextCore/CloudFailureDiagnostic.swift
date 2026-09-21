import Foundation

struct CloudHTTPFailure: LocalizedError {
    let status: Int
    let stage: CloudDiagnosticStage
    var errorDescription: String? { CloudFailureDiagnostic.http(status, stage: stage).userMessage + "（HTTP \(status)）" }
}

/// An App wall-clock limit, deliberately distinct from URLSession's -1001.
public struct CloudRequestDeadlineExceeded: LocalizedError, Sendable {
    public let stage: String
    public var errorDescription: String? { "本次雲端操作已達等待期限。" }
}

/// Fixed values only. Raw NSError.userInfo and provider messages never enter this model.
public struct CloudFailureDiagnostic: Codable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable {
        case connectionLost, offline, dnsFailure, hostUnreachable
        case urlSessionTimeout, requestDeadlineExceeded, segmentDeadlineExceeded
        case authentication, authUnavailable, tlsFailure, rateLimited, serverError
        case emptyResponse, contentBlocked, invalidResponse, transportFailure, cancelled, unknown

        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    public enum TimeoutSource: String, Codable, Sendable {
        case urlSession, requestDeadline, segmentDeadline, unknown
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    public struct ErrorCode: Codable, Equatable, Sendable {
        public let domain: String
        public let code: Int
    }

    public let category: Category
    public let stage: CloudDiagnosticStage
    public let errorChain: [ErrorCode]
    public let httpStatus: Int?
    public let timeoutSource: TimeoutSource?

    public var isTransientNetworkFailure: Bool {
        [.connectionLost, .offline, .dnsFailure, .hostUnreachable, .urlSessionTimeout,
         .requestDeadlineExceeded].contains(category)
    }

    public var userMessage: String {
        switch category {
        case .connectionLost: return "連到 Google 的連線中斷。"
        case .offline: return "目前無法建立網路連線。"
        case .dnsFailure, .hostUnreachable: return "無法連到 Google。"
        case .urlSessionTimeout: return "連到 Google 的請求逾時。"
        case .requestDeadlineExceeded: return "本次雲端操作已達 App 等待期限。"
        case .segmentDeadlineExceeded: return "本片段已達總等待期限，已停止自動重試。"
        case .authentication: return "Google 認證或存取權限失敗。"
        case .authUnavailable: return "目前無法取得 Google 驗證資訊。"
        case .tlsFailure: return "無法與 Google 建立安全連線。"
        case .rateLimited: return "Google 請求或配額已達限制。"
        case .serverError: return "Google 服務暫時無法完成請求。"
        case .emptyResponse: return "Google 未提供可用的逐字稿文字。"
        case .contentBlocked: return "Google 未允許處理本片段。"
        case .invalidResponse: return "Google 回應內容無法使用。"
        case .transportFailure: return "本機傳輸通道失敗。"
        case .cancelled: return "使用者取消工作。"
        case .unknown: return "雲端操作失敗，原因尚未確認。"
        }
    }

    public var debugSummary: String {
        var parts = ["stage=\(stage.rawValue)", "category=\(category.rawValue)"]
        if let httpStatus { parts.append("HTTP=\(httpStatus)") }
        if let timeoutSource { parts.append("timeout=\(timeoutSource.rawValue)") }
        parts += errorChain.map { "\($0.domain):\($0.code)" }
        return parts.joined(separator: "；")
    }

    public static func classify(_ error: Error, stage: CloudDiagnosticStage = .unknown) -> Self {
        if let service = error as? CloudServiceRecoveryExhausted { return .http(429, stage: service.recovery.stage) }
        if let http = error as? CloudHTTPFailure { return .http(http.status, stage: http.stage) }
        if let exhausted = error as? CloudNetworkRecoveryExhausted {
            return exhausted.recovery.lastFailure ?? .init(category: .offline, stage: stage)
        }
        if let pipeline = error as? PipelineExecutionError {
            return pipeline.failureDiagnostic ?? classify(pipeline.underlying, stage: stage)
        }
        if let segment = error as? CloudSegmentExecutionError { return segment.diagnostic }
        if error is CancellationError { return .init(category: .cancelled, stage: stage) }
        if let deadline = error as? CloudRequestDeadlineExceeded {
            return .init(category: .requestDeadlineExceeded,
                         stage: .init(rawValue: deadline.stage) ?? stage, timeoutSource: .requestDeadline)
        }
        if let deadline = error as? CloudSegmentDeadlineExceeded {
            return .init(category: .segmentDeadlineExceeded,
                         stage: .init(rawValue: deadline.stage) ?? stage, timeoutSource: .segmentDeadline)
        }
        // Only inspect a bounded chain and copy an allowlist of domains/codes.
        // Identity detection stops cycles without reading localizedDescription.
        var chain: [ErrorCode] = []
        var visited = Set<ObjectIdentifier>()
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let value = current, visited.insert(ObjectIdentifier(value)).inserted else { break }
            if [NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain, kCFErrorDomainCFNetwork as String].contains(value.domain) {
                chain.append(.init(domain: value.domain, code: value.code))
            }
            current = (value.userInfo[NSUnderlyingErrorKey] as? NSError)
                ?? (value.userInfo["NSUnderlyingError"] as? NSError)
        }
        if let code = chain.first(where: { $0.domain == NSURLErrorDomain })?.code {
            let category: Category
            switch code {
            case URLError.cancelled.rawValue: category = .cancelled
            case URLError.networkConnectionLost.rawValue: category = .connectionLost
            case URLError.notConnectedToInternet.rawValue: category = .offline
            case URLError.dnsLookupFailed.rawValue: category = .dnsFailure
            case URLError.cannotFindHost.rawValue, URLError.cannotConnectToHost.rawValue: category = .hostUnreachable
            case URLError.timedOut.rawValue: category = .urlSessionTimeout
            case URLError.secureConnectionFailed.rawValue,
                 URLError.serverCertificateHasBadDate.rawValue, URLError.serverCertificateUntrusted.rawValue,
                 URLError.serverCertificateHasUnknownRoot.rawValue, URLError.serverCertificateNotYetValid.rawValue,
                 URLError.clientCertificateRejected.rawValue, URLError.clientCertificateRequired.rawValue:
                category = .tlsFailure
            case URLError.userAuthenticationRequired.rawValue: category = .authentication
            default: category = .unknown
            }
            return .init(category: category, stage: stage, errorChain: chain,
                         timeoutSource: category == .urlSessionTimeout ? .urlSession : nil)
        }
        if let vertex = error as? VertexAIError {
            switch vertex {
            case let .requestFailed(status, _): return http(status, stage: stage)
            case .rateLimited, .quotaExceeded: return http(429, stage: stage)
            case .authenticationFailed: return .init(category: .authUnavailable, stage: .auth)
            case .emptyCompletedResponse: return .init(category: .emptyResponse, stage: stage)
            case .prohibitedContent, .promptBlocked: return .init(category: .contentBlocked, stage: stage)
            case .cancelled: return .init(category: .cancelled, stage: stage)
            case .transportMessageTooLarge: return .init(category: .transportFailure, stage: stage)
            default: return .init(category: .invalidResponse, stage: stage)
            }
        }
        if let studio = error as? GoogleAIStudioError {
            switch studio {
            case let .requestFailed(status, _): return http(status, stage: stage)
            case .rateLimited, .quotaExceeded: return http(429, stage: stage)
            case .emptyResponse: return .init(category: .emptyResponse, stage: stage)
            case .missingAPIKey, .invalidAPIKey: return .init(category: .authentication, stage: .auth)
            case .prohibitedContent, .promptBlocked: return .init(category: .contentBlocked, stage: stage)
            case .cancelled: return .init(category: .cancelled, stage: stage)
            case .transportMessageTooLarge: return .init(category: .transportFailure, stage: stage)
            default: return .init(category: .invalidResponse, stage: stage)
            }
        }
        return .init(category: chain.contains { $0.domain == NSPOSIXErrorDomain && $0.code == 40 }
                     ? .transportFailure : .unknown, stage: stage, errorChain: chain)
    }

    static func http(_ status: Int, stage: CloudDiagnosticStage) -> Self {
        .init(category: [401, 403].contains(status) ? .authentication
              : status == 429 ? .rateLimited : status >= 500 || status == 408 ? .serverError : .invalidResponse,
              stage: stage, httpStatus: status)
    }

    init(category: Category, stage: CloudDiagnosticStage, errorChain: [ErrorCode] = [],
         httpStatus: Int? = nil, timeoutSource: TimeoutSource? = nil) {
        self.category = category; self.stage = stage; self.errorChain = errorChain
        self.httpStatus = httpStatus; self.timeoutSource = timeoutSource
    }
}

/// Keeps the typed cause when a failed segment is wrapped with its position.
public struct CloudSegmentExecutionError: LocalizedError {
    public let segmentIndex: Int
    public let segmentCount: Int
    public let underlying: Error
    public let diagnostic: CloudFailureDiagnostic
    public var errorDescription: String? {
        let message = [.unknown, .invalidResponse].contains(diagnostic.category)
            ? underlying.localizedDescription : diagnostic.userMessage
        return "第 \(segmentIndex)/\(segmentCount) 段失敗：\(message)"
    }
}
