import Foundation
import XCTest
@testable import RecordToTextCore

final class StartupInventoryTests: XCTestCase {
    func testRecoveryInventoryExcludesActiveRecoveryDirectoryOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "startup-inventory-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("support"))
        let tempJobs = root.appendingPathComponent("temp-jobs", isDirectory: true)
        try paths.createDirectories()
        try FileManager.default.createDirectory(
            at: tempJobs,
            withIntermediateDirectories: true
        )

        let activeID = UUID()
        let activeDirectory = paths.tempRecovery.appendingPathComponent(
            activeID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: activeDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: activeDirectory.appendingPathComponent(
                LocalChunkCheckpoint.directoryName,
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let stoppedID = UUID()
        let stoppedDirectory = paths.tempRecovery.appendingPathComponent(
            stoppedID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stoppedDirectory,
            withIntermediateDirectories: true
        )
        try Data("wav".utf8).write(
            to: stoppedDirectory.appendingPathComponent(
                RecoveryScanner.normalizedWAVFileName
            )
        )

        let report = StartupInventory.recoveryReport(
            paths: paths,
            activeRecoveryDirectoryPaths: [activeDirectory.path],
            systemTempRoot: tempJobs
        )

        XCTAssertFalse(report.items.contains { $0.jobID == activeID })
        XCTAssertTrue(report.items.contains { $0.jobID == stoppedID })
    }
}
