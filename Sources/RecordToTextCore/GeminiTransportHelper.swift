import Foundation

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
