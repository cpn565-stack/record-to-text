import Foundation

public enum GCloudAuthError: LocalizedError, Equatable {
    case gcloudNotFound
    case commandFailed(status: Int32, message: String)
    case tokenEmpty
    case projectNotFound
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .gcloudNotFound:
            return "找不到 gcloud CLI 工具。請確認已安裝 Google Cloud SDK，且位於 PATH 或常用路徑（如 /opt/homebrew/bin/gcloud）。"
        case let .commandFailed(status, message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "gcloud 執行失敗（結束碼 \(status)）：\(trimmed.isEmpty ? "未登入或憑證已過期，請於終端機執行 `gcloud auth login` 或 `gcloud auth application-default login`" : trimmed)"
        case .tokenEmpty:
            return "gcloud 回傳的 Access Token 為空。"
        case .projectNotFound:
            return "找不到當前已設定的 GCP Project ID。請於終端機執行 `gcloud config set project <PROJECT_ID>` 或於設定中手動指定。"
        case .cancelled:
            return "gcloud 驗證程序已取消。"
        }
    }
}

public final class GCloudAuthService: @unchecked Sendable {
    /// Standard gcloud user tokens live about an hour, but the CLI does not
    /// report the real expiry of the token it prints (impersonation policies
    /// can issue shorter-lived ones). Cache conservatively; anything shorter
    /// is recovered by the 401 auto-refresh path in the Vertex backend.
    private static let cachedTokenTTL: TimeInterval = 30 * 60
    public static let cachedProjectTTL: TimeInterval = 5 * 60

    private static let allowlistedEnvironmentKeys: [String] = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "TZ",
        "CLOUDSDK_CONFIG", "CLOUDSDK_PYTHON", "CLOUDSDK_PYTHON_ARGS", "CLOUDSDK_ACTIVE_CONFIG_NAME",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR"
    ]

    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    private struct CachedProject {
        let projectID: String
        let expiresAt: Date
    }

    private let runner: ProcessRunner
    private let customGCloudPath: String?
    private let inheritedEnvironmentProvider: @Sendable () -> [String: String]
    private let nowProvider: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedToken: CachedToken?
    private var cachedProject: CachedProject?

    public var configuredCustomGCloudPath: String? {
        customGCloudPath
    }

    public init(
        customGCloudPath: String? = nil,
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.customGCloudPath = customGCloudPath
        self.runner = runner
        self.inheritedEnvironmentProvider = { ProcessInfo.processInfo.environment }
        self.nowProvider = { Date() }
    }

    internal init(
        customGCloudPath: String? = nil,
        runner: ProcessRunner = ProcessRunner(),
        inheritedEnvironmentProvider: @escaping @Sendable () -> [String: String],
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.customGCloudPath = customGCloudPath
        self.runner = runner
        self.inheritedEnvironmentProvider = inheritedEnvironmentProvider
        self.nowProvider = nowProvider
    }

    internal func gcloudEnvironment(executableURL: URL) -> [String: String] {
        let inherited = inheritedEnvironmentProvider()
        var environment: [String: String] = [:]
        for key in Self.allowlistedEnvironmentKeys {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        var seenPaths = Set<String>()
        let pathEntries = [
            executableURL.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].filter { !$0.isEmpty && seenPaths.insert($0).inserted }
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }

    /// 尋找系統中的 gcloud 執行檔路徑
    public func resolveGCloudURL(fileManager: FileManager = .default) -> URL? {
        if let custom = customGCloudPath, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let customURL = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            if fileManager.isExecutableFile(atPath: customURL.path) {
                return customURL
            }
            return nil
        }

        let candidates = [
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            "/usr/bin/gcloud",
            (NSHomeDirectory() as NSString).appendingPathComponent("google-cloud-sdk/bin/gcloud"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".google-cloud-sdk/bin/gcloud")
        ]

        for candidate in candidates {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        // 嘗試透過 which gcloud 搜尋
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for pathDir in pathEnv.split(separator: ":") {
                let checkURL = URL(fileURLWithPath: String(pathDir)).appendingPathComponent("gcloud")
                if fileManager.isExecutableFile(atPath: checkURL.path) {
                    return checkURL
                }
            }
        }

        return nil
    }

    /// 清除 Token 快取
    public func invalidateToken() {
        lock.withLock {
            cachedToken = nil
        }
    }

    /// 獲取 GCP OAuth2 Access Token (具快取機制)
    public func getAccessToken(
        forceRefresh: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> String {
        let currentNow = nowProvider()
        if !forceRefresh {
            let cached = lock.withLock { () -> String? in
                if let cached = cachedToken, cached.expiresAt > currentNow {
                    return cached.token
                }
                return nil
            }
            if let cached {
                return cached
            }
        }

        guard let executableURL = resolveGCloudURL() else {
            throw GCloudAuthError.gcloudNotFound
        }

        do {
            let result = try await runner.run(
                executableURL: executableURL,
                arguments: ["auth", "print-access-token"],
                environment: gcloudEnvironment(executableURL: executableURL),
                timeout: timeout,
                inactivityTimeout: 15
            )

            let token = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw GCloudAuthError.tokenEmpty
            }

            let savedAt = nowProvider()
            lock.withLock {
                cachedToken = CachedToken(
                    token: token,
                    expiresAt: savedAt.addingTimeInterval(Self.cachedTokenTTL)
                )
            }

            return token
        } catch let error as ProcessRunnerError {
            if Task.isCancelled {
                throw GCloudAuthError.cancelled
            }
            switch error {
            case .cancelledBeforeLaunch:
                throw GCloudAuthError.cancelled
            case let .nonZeroExit(_, status, stderr):
                throw GCloudAuthError.commandFailed(status: status, message: stderr)
            default:
                throw GCloudAuthError.commandFailed(status: -1, message: error.localizedDescription)
            }
        } catch is CancellationError {
            throw GCloudAuthError.cancelled
        }
    }

    /// 獲取當前 gcloud active project ID（具 5 分鐘快取 TTL）
    public func getDefaultProjectID(
        forceRefresh: Bool = false,
        timeout: TimeInterval = 15
    ) async throws -> String {
        let currentNow = nowProvider()
        if !forceRefresh {
            let cached = lock.withLock { () -> String? in
                if let cached = cachedProject, cached.expiresAt > currentNow {
                    return cached.projectID
                }
                return nil
            }
            if let cached {
                return cached
            }
        }

        guard let executableURL = resolveGCloudURL() else {
            throw GCloudAuthError.gcloudNotFound
        }

        do {
            let result = try await runner.run(
                executableURL: executableURL,
                arguments: ["config", "get-value", "project"],
                environment: gcloudEnvironment(executableURL: executableURL),
                timeout: timeout,
                inactivityTimeout: 10
            )

            if result.terminationStatus != 0 {
                throw GCloudAuthError.commandFailed(
                    status: result.terminationStatus,
                    message: result.standardErrorText
                )
            }

            let project = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
            // gcloud 若未設定 project 會輸出 (unset)
            if project.isEmpty || project == "(unset)" {
                throw GCloudAuthError.projectNotFound
            }

            let savedAt = nowProvider()
            lock.withLock {
                cachedProject = CachedProject(
                    projectID: project,
                    expiresAt: savedAt.addingTimeInterval(Self.cachedProjectTTL)
                )
            }

            return project
        } catch let error as ProcessRunnerError {
            if Task.isCancelled {
                throw GCloudAuthError.cancelled
            }
            switch error {
            case .cancelledBeforeLaunch:
                throw GCloudAuthError.cancelled
            case let .nonZeroExit(_, status, stderr):
                throw GCloudAuthError.commandFailed(status: status, message: stderr)
            default:
                throw GCloudAuthError.commandFailed(status: -1, message: error.localizedDescription)
            }
        } catch is CancellationError {
            throw GCloudAuthError.cancelled
        }
    }

    /// 清除 Token 與 Project 快取
    public func clearCache() {
        lock.withLock {
            cachedToken = nil
            cachedProject = nil
        }
    }
}
