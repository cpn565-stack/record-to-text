import Foundation

public enum RuntimeComponent: String, CaseIterable, Codable, Hashable, Sendable {
    case python
    case ffmpeg
    case ffprobe
    case opencc
    case helper
    case gcloud

    public var displayName: String {
        switch self {
        case .python:
            return "Python"
        case .ffmpeg:
            return "ffmpeg"
        case .ffprobe:
            return "ffprobe"
        case .opencc:
            return "OpenCC"
        case .helper:
            return "Qwen ASR Helper"
        case .gcloud:
            return "Google Cloud CLI (gcloud)"
        }
    }
}

public struct ResolvedRuntime: Equatable, Sendable {
    public let python: URL
    public let ffmpeg: URL
    public let ffprobe: URL
    public let opencc: URL
    public let helper: URL
    public let gcloud: URL?
    public let isDeveloperRuntime: Bool
    /// Components selected from App-managed `Runtimes/current`. These paths
    /// require manifest/signature verification even when only a cloud backend
    /// needs ffmpeg/ffprobe.
    public let managedComponents: Set<RuntimeComponent>

    public init(
        python: URL,
        ffmpeg: URL,
        ffprobe: URL,
        opencc: URL,
        helper: URL,
        gcloud: URL? = nil,
        isDeveloperRuntime: Bool,
        managedComponents: Set<RuntimeComponent> = []
    ) {
        self.python = python
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.opencc = opencc
        self.helper = helper
        self.gcloud = gcloud
        self.isDeveloperRuntime = isDeveloperRuntime
        self.managedComponents = managedComponents
    }
}

/// Result of locating the two developer-owned executables that are not shipped
/// as ordinary App helpers. Discovery only chooses paths; it never executes
/// either program.
public struct DeveloperRuntimeDiscovery: Equatable, Sendable {
    public let python: URL
    public let openCC: URL
    public let pythonWasDetected: Bool
    public let openCCWasDetected: Bool

    public init(
        python: URL,
        openCC: URL,
        pythonWasDetected: Bool,
        openCCWasDetected: Bool
    ) {
        self.python = python
        self.openCC = openCC
        self.pythonWasDetected = pythonWasDetected
        self.openCCWasDetected = openCCWasDetected
    }
}

public struct EnvironmentComponentReport: Equatable, Identifiable, Sendable {
    public var id: RuntimeComponent { component }
    public let component: RuntimeComponent
    public let path: String
    public let isAvailable: Bool
    public let detail: String

    public init(
        component: RuntimeComponent,
        path: String,
        isAvailable: Bool,
        detail: String
    ) {
        self.component = component
        self.path = path
        self.isAvailable = isAvailable
        self.detail = detail
    }
}

public struct EnvironmentReport: Equatable, Sendable {
    public let architecture: CPUArchitecture
    public let components: [EnvironmentComponentReport]
    public let isDeveloperRuntime: Bool
    public let backendType: ASRBackendType

    public init(
        architecture: CPUArchitecture,
        components: [EnvironmentComponentReport],
        isDeveloperRuntime: Bool,
        backendType: ASRBackendType = .googleAIStudio
    ) {
        self.architecture = architecture
        self.components = components
        self.isDeveloperRuntime = isDeveloperRuntime
        self.backendType = backendType
    }

    public var isReady: Bool {
        components.allSatisfy(\.isAvailable)
    }
}

public enum RuntimeEnvironmentError: LocalizedError {
    case missingComponents([EnvironmentComponentReport])
    case releaseRuntimeNotVerified
    case releaseRuntimeVerificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .missingComponents(components):
            let names = components.map(\.component.displayName).joined(separator: "、")
            return "執行環境尚未準備完成：缺少 \(names)。"
        case .releaseRuntimeNotVerified:
            return "受管理 Runtime 尚未通過完整性與簽章驗證，因此拒絕執行。請安裝受信任 Runtime，或在設定中明確開啟「開發 Runtime」。"
        case let .releaseRuntimeVerificationFailed(reason):
            return "受管理 Runtime 完整性驗證失敗，因此拒絕執行：\(reason)"
        }
    }
}

public enum RuntimeEnvironment {
    public static func homebrewPrefix(for architecture: CPUArchitecture = .current) -> String {
        architecture == .x86_64 ? "/usr/local/bin" : "/opt/homebrew/bin"
    }

    /// Find the conventional record-to-text Python environment and OpenCC.
    /// The dedicated virtual environment is preferred over ambient shell
    /// environments so launching the App from Terminal cannot silently change
    /// which Python is used.
    public static func discoverDeveloperRuntime(
        architecture: CPUArchitecture = .current,
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeStandardOpenCCLocations: Bool = true,
        fileManager: FileManager = .default
    ) -> DeveloperRuntimeDiscovery {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let environmentName = architecture == .x86_64
            ? "record-to-text-intel-env"
            : "mlx-audio-env"
        let fallbackPython = home
            .appendingPathComponent(environmentName, isDirectory: true)
            .appendingPathComponent("bin/python", isDirectory: false)

        var pythonCandidates = [fallbackPython]
        for key in ["VIRTUAL_ENV", "CONDA_PREFIX"] {
            guard let root = normalizedPath(environment[key]) else {
                continue
            }
            pythonCandidates.append(
                URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent("bin/python", isDirectory: false)
            )
        }

        let primaryPrefix = homebrewPrefix(for: architecture)
        let alternatePrefix = architecture == .x86_64
            ? "/opt/homebrew/bin"
            : "/usr/local/bin"
        let fallbackOpenCC = URL(fileURLWithPath: "\(primaryPrefix)/opencc")
        var openCCCandidates: [URL] = includeStandardOpenCCLocations
            ? [
                fallbackOpenCC,
                URL(fileURLWithPath: "\(alternatePrefix)/opencc")
            ]
            : []
        openCCCandidates.append(contentsOf: executableCandidates(
            named: "opencc",
            pathValue: environment["PATH"]
        ))

        let detectedPython = pythonCandidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
        let detectedOpenCC = openCCCandidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }

        return DeveloperRuntimeDiscovery(
            python: detectedPython ?? fallbackPython,
            openCC: detectedOpenCC ?? fallbackOpenCC,
            pythonWasDetected: detectedPython != nil,
            openCCWasDetected: detectedOpenCC != nil
        )
    }

    /// Locate ffmpeg / ffprobe / helper without executing them.
    /// Audio tools prefer: bundled app Helpers → Homebrew → App-managed Runtime.
    /// Set `includeSystemAudioTools` to false in tests so Homebrew cannot mask missing fixtures.
    public static func candidate(
        paths: ApplicationPaths,
        settings: AppSettings,
        bundledHelperURL: URL?,
        bundledFFmpegURL: URL? = nil,
        bundledFFprobeURL: URL? = nil,
        includeSystemAudioTools: Bool = true,
        developerRuntimeDiscovery: DeveloperRuntimeDiscovery? = nil,
        fileManager: FileManager = .default
    ) -> ResolvedRuntime {
        let releaseBin = paths.runtimes
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let releaseHelperName = CPUArchitecture.current == .x86_64
            ? "qwen_asr_transformers_runner.py"
            : "qwen_asr_mlx_runner.py"
        let prefix = homebrewPrefix()

        let python: URL
        let opencc: URL
        let helper: URL
        let isDeveloperRuntime: Bool
        var managedComponents = Set<RuntimeComponent>()

        if settings.developerMode {
            isDeveloperRuntime = true
            let discovery = developerRuntimeDiscovery ?? discoverDeveloperRuntime(
                fileManager: fileManager
            )
            python = URL(
                fileURLWithPath: normalizedPath(settings.customPythonPath)
                    ?? discovery.python.path
            )
            opencc = discovery.openCC
            if let customHelperPath = normalizedPath(settings.customHelperPath) {
                helper = URL(fileURLWithPath: customHelperPath)
            } else if let bundledHelperURL {
                helper = bundledHelperURL
            } else {
                helper = releaseBin.appendingPathComponent(releaseHelperName)
                managedComponents.insert(.helper)
            }
        } else {
            isDeveloperRuntime = false
            python = releaseBin.appendingPathComponent("python")
            opencc = releaseBin.appendingPathComponent("opencc")
            helper = releaseBin.appendingPathComponent(releaseHelperName)
            managedComponents.formUnion([.python, .opencc, .helper])
        }

        var ffmpegCandidates: [(url: URL?, managed: Bool)] = [
            (bundledFFmpegURL, false)
        ]
        var ffprobeCandidates: [(url: URL?, managed: Bool)] = [
            (bundledFFprobeURL, false)
        ]
        if includeSystemAudioTools {
            ffmpegCandidates.append((URL(fileURLWithPath: "\(prefix)/ffmpeg"), false))
            ffprobeCandidates.append((URL(fileURLWithPath: "\(prefix)/ffprobe"), false))
        }
        ffmpegCandidates.append((releaseBin.appendingPathComponent("ffmpeg"), true))
        ffprobeCandidates.append((releaseBin.appendingPathComponent("ffprobe"), true))

        let selectedFFmpeg = firstExecutable(
            ffmpegCandidates,
            fileManager: fileManager
        )
        let selectedFFprobe = firstExecutable(
            ffprobeCandidates,
            fileManager: fileManager
        )
        if selectedFFmpeg.managed {
            managedComponents.insert(.ffmpeg)
        }
        if selectedFFprobe.managed {
            managedComponents.insert(.ffprobe)
        }

        let gcloud = settings.backendType == .vertexAI
            ? GCloudAuthService(customGCloudPath: settings.customGCloudPath)
                .resolveGCloudURL(fileManager: fileManager)
            : nil

        return ResolvedRuntime(
            python: python,
            ffmpeg: selectedFFmpeg.url,
            ffprobe: selectedFFprobe.url,
            opencc: opencc,
            helper: helper,
            gcloud: gcloud,
            isDeveloperRuntime: isDeveloperRuntime,
            managedComponents: managedComponents
        )
    }

    public static func resolve(
        paths: ApplicationPaths,
        settings: AppSettings,
        bundledHelperURL: URL?,
        bundledFFmpegURL: URL? = nil,
        bundledFFprobeURL: URL? = nil,
        includeSystemAudioTools: Bool = true,
        developerRuntimeDiscovery: DeveloperRuntimeDiscovery? = nil,
        releaseRuntimeVerifier: ((ResolvedRuntime) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> ResolvedRuntime {
        let runtime = candidate(
            paths: paths,
            settings: settings,
            bundledHelperURL: bundledHelperURL,
            bundledFFmpegURL: bundledFFmpegURL,
            bundledFFprobeURL: bundledFFprobeURL,
            includeSystemAudioTools: includeSystemAudioTools,
            developerRuntimeDiscovery: developerRuntimeDiscovery,
            fileManager: fileManager
        )

        let requiredComponents = requiredComponents(for: settings.backendType)
        let managedRequiredComponents = runtime.managedComponents.intersection(
            requiredComponents
        )
        let requiresManagedRuntimeVerification = !managedRequiredComponents.isEmpty

        // This first pass checks only the physical files. Trust is handled by
        // the verifier immediately below for a managed local runtime.
        let report = inspect(
            runtime,
            backendType: settings.backendType,
            customGCloudPath: settings.customGCloudPath,
            releaseRuntimeVerified: requiresManagedRuntimeVerification,
            fileManager: fileManager
        )
        let missing = report.components.filter { !$0.isAvailable }
        guard missing.isEmpty else {
            throw RuntimeEnvironmentError.missingComponents(missing)
        }

        // App-managed files are never trusted merely because they exist. This
        // applies to local Qwen and to a cloud job that falls back to managed
        // ffmpeg/ffprobe.
        if requiresManagedRuntimeVerification {
            guard let releaseRuntimeVerifier else {
                throw RuntimeEnvironmentError.releaseRuntimeNotVerified
            }
            do {
                try releaseRuntimeVerifier(runtime)
            } catch {
                throw RuntimeEnvironmentError.releaseRuntimeVerificationFailed(
                    error.localizedDescription
                )
            }
        }
        return runtime
    }

    public static func inspect(
        _ runtime: ResolvedRuntime,
        backendType: ASRBackendType = .googleAIStudio,
        customGCloudPath: String? = nil,
        releaseRuntimeVerified: Bool = false,
        fileManager: FileManager = .default
    ) -> EnvironmentReport {
        var pairs: [(RuntimeComponent, URL?)] = [
            (.ffmpeg, runtime.ffmpeg),
            (.ffprobe, runtime.ffprobe)
        ]

        if backendType == .vertexAI {
            let gcloudURL = runtime.gcloud
                ?? GCloudAuthService(customGCloudPath: customGCloudPath)
                    .resolveGCloudURL(fileManager: fileManager)
            pairs.append((.gcloud, gcloudURL))
        } else if backendType == .localQwen {
            // 本機 Qwen 需要完整 Runtime：python / ffmpeg / ffprobe / opencc / helper
            pairs.append((.python, runtime.python))
            pairs.append((.opencc, runtime.opencc))
            pairs.append((.helper, runtime.helper))
        } else if backendType == .googleAIStudio {
            // Google AI Studio API 僅需 ffmpeg/ffprobe 進行音訊壓縮與切片
        }

        let components = pairs.map { component, url in
            guard let url else {
                return EnvironmentComponentReport(
                    component: component,
                    path: "",
                    isAvailable: false,
                    detail: "找不到或無法執行"
                )
            }
            let exists = fileManager.fileExists(atPath: url.path)
            let executable = component == .helper
                ? exists
                : fileManager.isExecutableFile(atPath: url.path)
            let trusted = !runtime.managedComponents.contains(component)
                || releaseRuntimeVerified
            let available = executable && trusted
            let detail: String
            if !executable {
                detail = "找不到或無法執行"
            } else if trusted {
                detail = "可用"
            } else {
                detail = "檔案存在，但受管理 Runtime 尚未通過完整性驗證"
            }
            return EnvironmentComponentReport(
                component: component,
                path: url.path,
                isAvailable: available,
                detail: detail
            )
        }

        return EnvironmentReport(
            architecture: .current,
            components: components,
            isDeveloperRuntime: runtime.isDeveloperRuntime,
            backendType: backendType
        )
    }

    private static func firstExecutable(
        _ candidates: [(url: URL?, managed: Bool)],
        fileManager: FileManager
    ) -> (url: URL, managed: Bool) {
        let candidates = candidates.compactMap { candidate -> (URL, Bool)? in
            guard let url = candidate.url else {
                return nil
            }
            return (url, candidate.managed)
        }
        if let match = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.0.path)
        }) {
            return match
        }
        return candidates.last ?? (URL(fileURLWithPath: "/usr/bin/false"), false)
    }

    private static func requiredComponents(
        for backendType: ASRBackendType
    ) -> Set<RuntimeComponent> {
        switch backendType {
        case .googleAIStudio:
            return [.ffmpeg, .ffprobe]
        case .vertexAI:
            return [.ffmpeg, .ffprobe, .gcloud]
        case .localQwen:
            return [.python, .ffmpeg, .ffprobe, .opencc, .helper]
        }
    }

    private static func executableCandidates(
        named executableName: String,
        pathValue: String?
    ) -> [URL] {
        guard let pathValue else {
            return []
        }
        return pathValue
            .split(separator: ":", omittingEmptySubsequences: true)
            .map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent(executableName, isDirectory: false)
            }
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            ? nil
            : (normalized as NSString).expandingTildeInPath
    }
}
