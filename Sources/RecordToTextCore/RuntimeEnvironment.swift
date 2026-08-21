import Foundation

public enum RuntimeComponent: String, CaseIterable, Codable, Sendable {
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
    public let isDeveloperRuntime: Bool

    public init(
        python: URL,
        ffmpeg: URL,
        ffprobe: URL,
        opencc: URL,
        helper: URL,
        isDeveloperRuntime: Bool
    ) {
        self.python = python
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.opencc = opencc
        self.helper = helper
        self.isDeveloperRuntime = isDeveloperRuntime
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

    public var errorDescription: String? {
        switch self {
        case let .missingComponents(components):
            let names = components.map(\.component.displayName).joined(separator: "、")
            return "執行環境尚未準備完成：缺少 \(names)。"
        case .releaseRuntimeNotVerified:
            return "正式 Runtime 尚未通過完整性與簽章驗證，因此拒絕執行。請完成受信任 Runtime 安裝，或明確開啟開發者模式。"
        }
    }
}

public enum RuntimeEnvironment {
    public static func homebrewPrefix(for architecture: CPUArchitecture = .current) -> String {
        architecture == .x86_64 ? "/usr/local/bin" : "/opt/homebrew/bin"
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
        fileManager: FileManager = .default
    ) -> ResolvedRuntime {
        let releaseBin = paths.runtimes
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let releaseHelperName = CPUArchitecture.current == .x86_64
            ? "qwen_asr_transformers_runner.py"
            : "qwen_asr_mlx_runner.py"
        let prefix = homebrewPrefix()
        let home = fileManager.homeDirectoryForCurrentUser
        let defaultEnvironmentName = CPUArchitecture.current == .x86_64
            ? "record-to-text-intel-env"
            : "mlx-audio-env"

        let python: URL
        let opencc: URL
        let helper: URL
        let isDeveloperRuntime: Bool

        if settings.developerMode {
            isDeveloperRuntime = true
            python = URL(
                fileURLWithPath: settings.customPythonPath
                    ?? home.appendingPathComponent(
                        "\(defaultEnvironmentName)/bin/python"
                    ).path
            )
            opencc = URL(fileURLWithPath: "\(prefix)/opencc")
            helper = URL(
                fileURLWithPath: settings.customHelperPath
                    ?? bundledHelperURL?.path
                    ?? releaseBin.appendingPathComponent(releaseHelperName).path
            )
        } else {
            isDeveloperRuntime = false
            python = releaseBin.appendingPathComponent("python")
            opencc = releaseBin.appendingPathComponent("opencc")
            helper = releaseBin.appendingPathComponent(releaseHelperName)
        }

        var ffmpegCandidates: [URL?] = [bundledFFmpegURL]
        var ffprobeCandidates: [URL?] = [bundledFFprobeURL]
        if includeSystemAudioTools {
            ffmpegCandidates.append(URL(fileURLWithPath: "\(prefix)/ffmpeg"))
            ffprobeCandidates.append(URL(fileURLWithPath: "\(prefix)/ffprobe"))
        }
        ffmpegCandidates.append(releaseBin.appendingPathComponent("ffmpeg"))
        ffprobeCandidates.append(releaseBin.appendingPathComponent("ffprobe"))

        let ffmpeg = firstExecutable(ffmpegCandidates, fileManager: fileManager)
        let ffprobe = firstExecutable(ffprobeCandidates, fileManager: fileManager)

        return ResolvedRuntime(
            python: python,
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            opencc: opencc,
            helper: helper,
            isDeveloperRuntime: isDeveloperRuntime
        )
    }

    public static func resolve(
        paths: ApplicationPaths,
        settings: AppSettings,
        bundledHelperURL: URL?,
        bundledFFmpegURL: URL? = nil,
        bundledFFprobeURL: URL? = nil,
        includeSystemAudioTools: Bool = true,
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
            fileManager: fileManager
        )

        let usesCloudAudioTools = settings.backendType == .googleAIStudio
            || settings.backendType == .vertexAI

        let report = inspect(
            runtime,
            backendType: settings.backendType,
            customGCloudPath: settings.customGCloudPath,
            releaseRuntimeVerified: usesCloudAudioTools || runtime.isDeveloperRuntime,
            fileManager: fileManager
        )
        let missing = report.components.filter { !$0.isAvailable }
        guard missing.isEmpty else {
            throw RuntimeEnvironmentError.missingComponents(missing)
        }

        // Cloud backends only need ffmpeg/ffprobe (plus gcloud for Vertex).
        // The old MLX release-runtime verifier does not apply.
        if !runtime.isDeveloperRuntime && !usesCloudAudioTools {
            guard let releaseRuntimeVerifier else {
                throw RuntimeEnvironmentError.releaseRuntimeNotVerified
            }
            try releaseRuntimeVerifier(runtime)
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
            let gcloudURL = GCloudAuthService(customGCloudPath: customGCloudPath).resolveGCloudURL(fileManager: fileManager)
            pairs.append((.gcloud, gcloudURL))
        } else if backendType == .googleAIStudio {
            // Google AI Studio API 僅需 ffmpeg/ffprobe 進行音訊壓縮與切片
        }

        let usesCloudAudioTools = backendType == .googleAIStudio || backendType == .vertexAI

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
            let trusted = runtime.isDeveloperRuntime
                || releaseRuntimeVerified
                || usesCloudAudioTools
                || component == .gcloud
            let available = executable && trusted
            let detail: String
            if !executable {
                detail = "找不到或無法執行"
            } else if trusted {
                detail = "可用"
            } else {
                detail = "檔案存在，但正式 Runtime 尚未通過驗證"
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
        _ candidates: [URL?],
        fileManager: FileManager
    ) -> URL {
        let urls = candidates.compactMap { $0 }
        if let match = urls.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return match
        }
        return urls.last ?? URL(fileURLWithPath: "/usr/bin/false")
    }
}
