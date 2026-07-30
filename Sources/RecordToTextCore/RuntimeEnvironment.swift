import Foundation

public enum RuntimeComponent: String, CaseIterable, Codable, Sendable {
    case python
    case ffmpeg
    case ffprobe
    case opencc
    case helper

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

    public init(
        architecture: CPUArchitecture,
        components: [EnvironmentComponentReport],
        isDeveloperRuntime: Bool
    ) {
        self.architecture = architecture
        self.components = components
        self.isDeveloperRuntime = isDeveloperRuntime
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
    public static func resolve(
        paths: ApplicationPaths,
        settings: AppSettings,
        bundledHelperURL: URL?,
        releaseRuntimeVerifier: ((ResolvedRuntime) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> ResolvedRuntime {
        let releaseBin = paths.runtimes
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)

        let releaseHelperName = CPUArchitecture.current == .x86_64
            ? "qwen_asr_transformers_runner.py"
            : "qwen_asr_mlx_runner.py"

        var isDeveloperRuntime = false
        let python: URL
        let ffmpeg: URL
        let ffprobe: URL
        let opencc: URL
        let helper: URL

        if settings.developerMode {
            isDeveloperRuntime = true
            let home = fileManager.homeDirectoryForCurrentUser
            let prefix = CPUArchitecture.current == .x86_64 ? "/usr/local/bin" : "/opt/homebrew/bin"
            let defaultEnvironmentName = CPUArchitecture.current == .x86_64
                ? "record-to-text-intel-env"
                : "mlx-audio-env"

            python = URL(
                fileURLWithPath: settings.customPythonPath
                    ?? home.appendingPathComponent(
                        "\(defaultEnvironmentName)/bin/python"
                    ).path
            )
            ffmpeg = URL(fileURLWithPath: "\(prefix)/ffmpeg")
            ffprobe = URL(fileURLWithPath: "\(prefix)/ffprobe")
            opencc = URL(fileURLWithPath: "\(prefix)/opencc")
            helper = URL(
                fileURLWithPath: settings.customHelperPath
                    ?? bundledHelperURL?.path
                    ?? releaseBin.appendingPathComponent(releaseHelperName).path
            )
        } else {
            python = releaseBin.appendingPathComponent("python")
            ffmpeg = releaseBin.appendingPathComponent("ffmpeg")
            ffprobe = releaseBin.appendingPathComponent("ffprobe")
            opencc = releaseBin.appendingPathComponent("opencc")
            helper = releaseBin.appendingPathComponent(releaseHelperName)
        }

        let runtime = ResolvedRuntime(
            python: python,
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            opencc: opencc,
            helper: helper,
            isDeveloperRuntime: isDeveloperRuntime
        )
        // At this point we only need a physical-file check. Trust is enforced
        // immediately below by the injected verifier for release runtimes.
        let report = inspect(
            runtime,
            releaseRuntimeVerified: true,
            fileManager: fileManager
        )
        let missing = report.components.filter { !$0.isAvailable }
        guard missing.isEmpty else {
            throw RuntimeEnvironmentError.missingComponents(missing)
        }
        if !runtime.isDeveloperRuntime {
            guard let releaseRuntimeVerifier else {
                throw RuntimeEnvironmentError.releaseRuntimeNotVerified
            }
            try releaseRuntimeVerifier(runtime)
        }
        return runtime
    }

    public static func inspect(
        _ runtime: ResolvedRuntime,
        releaseRuntimeVerified: Bool = false,
        fileManager: FileManager = .default
    ) -> EnvironmentReport {
        let pairs: [(RuntimeComponent, URL)] = [
            (.python, runtime.python),
            (.ffmpeg, runtime.ffmpeg),
            (.ffprobe, runtime.ffprobe),
            (.opencc, runtime.opencc),
            (.helper, runtime.helper)
        ]

        let components = pairs.map { component, url in
            let exists = fileManager.fileExists(atPath: url.path)
            let executable = component == .helper
                ? exists
                : fileManager.isExecutableFile(atPath: url.path)
            let trusted = runtime.isDeveloperRuntime || releaseRuntimeVerified
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
            isDeveloperRuntime: runtime.isDeveloperRuntime
        )
    }
}
