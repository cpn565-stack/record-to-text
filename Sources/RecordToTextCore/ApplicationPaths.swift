import Foundation

public struct ApplicationPaths: Equatable, Sendable {
    public let root: URL
    public let models: URL
    public let runtimes: URL
    public let logs: URL
    public let tempRecovery: URL
    public let settings: URL
    public let glossaries: URL
    public let recentJobs: URL
    public let jobLedger: URL

    public init(root: URL) {
        self.root = root
        self.models = root.appendingPathComponent("Models", isDirectory: true)
        self.runtimes = root.appendingPathComponent("Runtimes", isDirectory: true)
        self.logs = root.appendingPathComponent("Logs", isDirectory: true)
        self.tempRecovery = root.appendingPathComponent("Temp-Recovery", isDirectory: true)
        self.settings = root.appendingPathComponent("settings.json")
        self.glossaries = root.appendingPathComponent("glossaries.json")
        self.recentJobs = root.appendingPathComponent("recent-jobs.json")
        self.jobLedger = root.appendingPathComponent("job-ledger.json")
    }

    public static func live(fileManager: FileManager = .default) -> ApplicationPaths {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return ApplicationPaths(
            root: support.appendingPathComponent("record-to-text", isDirectory: true)
        )
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, models, runtimes, logs, tempRecovery] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}
