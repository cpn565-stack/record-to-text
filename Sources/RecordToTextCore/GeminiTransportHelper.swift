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

            // 1. 直接是 POSIX 40
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 40 {
                return true
            }

            // 2. CFStream 底層錯誤碼為 40
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

            // 3. 檢查 localizedDescription 是否包含底層 EMSGSIZE
            if nsError.domain == NSPOSIXErrorDomain && nsError.localizedDescription.contains("Message too long") {
                return true
            }

            // 4. 遞迴尋找 underlying error
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

        let fileURL = targetDirectory.appendingPathComponent("\(prefix)_\(UUID().uuidString).json")
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return fileURL
    }

    /// 建立乾淨獨立的 Ephemeral Session，避開快取的 HTTP/3 連線池
    public static func makeEphemeralRetrySession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    /// Shared transient-failure policy for both Gemini cloud backends.
    public enum RetryPolicy {
        public static let maximumAttempts = 3

        /// Server-side busy/quota conditions worth retrying with backoff.
        public static func isRetryableStatusCode(_ statusCode: Int) -> Bool {
            statusCode == 429 || statusCode == 500 || statusCode == 503
        }

        public static func backoffSeconds(forAttempt attempt: Int) -> Double {
            Double(attempt * 2)
        }
    }
}
