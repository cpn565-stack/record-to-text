import Foundation

public enum GeminiTransportHelper {
    static func budgetedUpload(session: URLSession, request: URLRequest, fileURL: URL,
                              attempts: CloudRequestAttempts? = nil,
                              confirmUpload: (() async throws -> (Data, URLResponse)?)? = nil,
                              restartUpload: (() async throws -> URLRequest)? = nil) async throws -> (Data, URLResponse) {
        let stage = request.url?.absoluteString.contains("generateContent") == true ? "generation" : "upload"
        return try await send(session: session, request: request, fileURL: fileURL, stage: stage,
                              attempts: attempts, confirmUpload: confirmUpload, restartUpload: restartUpload)
    }
    static func budgetedData(session: URLSession, request: URLRequest, stage: String, attempts: CloudRequestAttempts? = nil) async throws -> (Data, URLResponse) {
        try await send(session: session, request: request, fileURL: nil, stage: stage, attempts: attempts)
    }
    private static func send(session: URLSession, request: URLRequest, fileURL: URL?, stage: String,
                             attempts: CloudRequestAttempts? = nil,
                             confirmUpload: (() async throws -> (Data, URLResponse)?)? = nil,
                             restartUpload: (() async throws -> URLRequest)? = nil) async throws -> (Data, URLResponse) {
        let context = CloudNetworkContext.current
        let generation = stage == "generation"
        let quota = attempts ?? (generation ? CloudNetworkContext.generation : nil)
        var previousError: Error?
        var request = request
        for attempt in 1...4 {
            try CloudBudgetContext.check(stage)
            if let quota, quota.count >= 4 {
                if let context, context.lastFailure != nil { throw context.exhausted(.attemptsExhausted) }
                throw CloudRequestLimitExceeded(stage: quota.stage)
            }
            try await context?.wait()
            if previousError != nil, let confirmUpload {
                let unresolved = context?.lastFailure
                if let confirmed = try await confirmUpload() {
                    context?.requestSucceeded()
                    return confirmed
                }
                if let unresolved { context?.noteFailure(unresolved, generation: false) }
                if let restartUpload { request = try await restartUpload() }
            }
            var bounded = request
            var maximum = min(300, request.timeoutInterval)
            if stage == "poll", let polling = CloudNetworkContext.polling {
                guard polling.remaining > 0 else { throw GoogleAIStudioError.fileProcessingTimedOut }
                maximum = min(maximum, polling.remaining)
            }
            bounded.timeoutInterval = try CloudBudgetContext.timeout(maximum, stage: stage)
            let finalRequest = bounded
            let ownedSession = context?.session(using: session, resetFor: previousError) ?? session
            let activeSession = request.httpMethod == "GET"
                ? context?.metadataTransport(using: ownedSession) ?? ownedSession : ownedSession
            do {
                let result = try await CloudBudgetContext.perform(stage: stage, maximumDuration: .seconds(maximum)) {
                    try await CancellableCloudRequest().run(session: activeSession, request: finalRequest, fileURL: fileURL, attempts: quota)
                }
                if let http = result.1 as? HTTPURLResponse, http.statusCode >= 400 {
                    CloudDiagnosticContext.current?.failure(.http(http.statusCode, stage: .init(rawValue: stage) ?? .unknown))
                    // Upload and metadata requests own their retry scope. Generation
                    // HTTP/model policy remains in the backend; sends still share quota.
                    if !generation, RetryPolicy.isRetryableStatusCode(http.statusCode), attempt < 4 {
                        let delay = RetryPolicy.backoffSeconds(forAttempt: attempt, retryAfterSeconds: retryAfterSeconds(response: http, data: result.0))
                        try await CloudBudgetContext.backoff(seconds: delay)
                        continue
                    }
                }
                context?.requestSucceeded()
                return result
            } catch {
                if Task.isCancelled || isNetworkCancellation(error) { throw CancellationError() }
                if let deadline = error as? CloudSegmentDeadlineExceeded {
                    if let context, context.isWaiting || context.lastFailure != nil { throw context.exhausted(.rootDeadline) }
                    throw deadline
                }
                guard let context else { throw error }
                let transient = isTransientNetworkFailure(error)
                let posix = isPOSIXMessageTooLarge(error)
                guard transient || posix else { throw error }
                if transient { context.noteFailure(.classify(error, stage: .init(rawValue: stage) ?? .unknown), generation: generation) }
                let sends = quota?.count ?? attempt
                guard attempt < 4, sends < 4 else {
                    if transient {
                        // The final body may have reached the server even though
                        // its response was lost. A read-only confirmation is not
                        // a fifth upload and still consumes the same root budget.
                        if let confirmUpload {
                            let unresolved = context.lastFailure
                            try await context.wait()
                            if let confirmed = try await confirmUpload() {
                                context.requestSucceeded()
                                return confirmed
                            }
                            if let unresolved { context.noteFailure(unresolved, generation: false) }
                        }
                        throw context.exhausted(.attemptsExhausted)
                    }
                    throw error
                }
                if posix {
                    guard !context.sessionWasReset else { throw error }
                    _ = context.session(using: session, resetFor: NSError(domain: NSPOSIXErrorDomain, code: 40))
                } else {
                    try await context.retry(after: sends, error: error, generation: generation)
                }
                previousError = error
            }
        }
        throw CloudRequestLimitExceeded(stage: .init(rawValue: stage) ?? .unknown)
    }

    /// 檢查錯誤是否為 POSIX 40 (EMSGSIZE: Message too long) 或相關底層 CFStream 錯誤
    /// Retry only temporary URL loading failures. Unknown errors and cancellation
    /// must not become automatic generation retries.
    public static func isTransientNetworkFailure(_ error: Error) -> Bool {
        guard !(error is CloudNetworkRecoveryExhausted) else { return false }
        return CloudFailureDiagnostic.classify(error).isTransientNetworkFailure
    }

    public static func isNetworkCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue
    }

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

    /// Creates an App-owned connection pool; transport protocol is chosen by URLSession.
    public static func makeEphemeralRetrySession(
        protocolClasses: [AnyClass]? = nil
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        config.waitsForConnectivity = true
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
            return max(min(computed, 60), retryAfterSeconds ?? 0)
        }
    }
}
