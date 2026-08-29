import Foundation

public struct ModelCacheInventory: Equatable, Sendable {
    public let isAppManagedModelAvailable: Bool
    public let isDefaultCacheModelAvailable: Bool

    public init(
        isAppManagedModelAvailable: Bool,
        isDefaultCacheModelAvailable: Bool
    ) {
        self.isAppManagedModelAvailable = isAppManagedModelAvailable
        self.isDefaultCacheModelAvailable = isDefaultCacheModelAvailable
    }
}

/// Filesystem inventory used after the first App frame.
///
/// These operations are synchronous by design so callers can choose their own
/// executor. The App runs them in utility-priority detached tasks and only
/// publishes the finished value on the main actor.
public enum StartupInventory {
    public static func modelCache(
        modelID: String,
        revision: String?,
        modelsDirectory: URL,
        fileManager: FileManager = .default
    ) -> ModelCacheInventory {
        ModelCacheInventory(
            isAppManagedModelAvailable: ModelCache.isDownloaded(
                modelID: modelID,
                revision: revision,
                modelsDirectory: modelsDirectory,
                fileManager: fileManager
            ),
            isDefaultCacheModelAvailable:
                ModelCache.isDownloadedInDefaultCache(
                    modelID: modelID,
                    revision: revision,
                    fileManager: fileManager
                )
        )
    }

    public static func recoveryReport(
        paths: ApplicationPaths,
        activeRecoveryDirectoryPaths: Set<String>,
        fileManager: FileManager = .default,
        systemTempRoot: URL? = nil
    ) -> RecoveryScanReport {
        excludingActiveRecoveryDirectories(
            from: RecoveryScanner.scan(
                paths: paths,
                fileManager: fileManager,
                systemTempRoot: systemTempRoot
            ),
            activeRecoveryDirectoryPaths: activeRecoveryDirectoryPaths
        )
    }

    public static func excludingActiveRecoveryDirectories(
        from report: RecoveryScanReport,
        activeRecoveryDirectoryPaths: Set<String>
    ) -> RecoveryScanReport {
        guard !activeRecoveryDirectoryPaths.isEmpty else {
            return report
        }
        return RecoveryScanReport(
            scannedAt: report.scannedAt,
            systemTempRoot: report.systemTempRoot,
            tempRecoveryRoot: report.tempRecoveryRoot,
            items: report.items.filter { item in
                guard item.location == .tempRecovery else {
                    return true
                }
                let path = URL(
                    fileURLWithPath: item.directoryPath,
                    isDirectory: true
                ).standardizedFileURL.path
                return !activeRecoveryDirectoryPaths.contains(path)
            },
            ignoredNonUUIDDirectoryCount:
                report.ignoredNonUUIDDirectoryCount
        )
    }
}
