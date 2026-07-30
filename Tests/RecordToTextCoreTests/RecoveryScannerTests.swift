import Foundation
import XCTest
@testable import RecordToTextCore

final class RecoveryScannerTests: XCTestCase {
    private var root: URL!
    private var paths: ApplicationPaths!
    private var tempJobs: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-recovery-scan-\(UUID().uuidString)")
        paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        tempJobs = root.appendingPathComponent("system-temp-jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: tempJobs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testIgnoresNonUUIDDirectories() throws {
        try FileManager.default.createDirectory(
            at: tempJobs.appendingPathComponent("not-a-uuid"),
            withIntermediateDirectories: true
        )
        let jobID = UUID()
        let jobDir = tempJobs.appendingPathComponent(jobID.uuidString)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try Data().write(to: jobDir.appendingPathComponent("normalized.wav"))

        let report = RecoveryScanner.scan(
            paths: paths,
            systemTempRoot: tempJobs
        )

        XCTAssertEqual(report.ignoredNonUUIDDirectoryCount, 1)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items[0].kind, .orphaned)
        XCTAssertEqual(report.items[0].location, .systemTemp)
    }

    func testTempRecoveryWithValidMetadataIsRecoverable() throws {
        let jobID = UUID()
        let dir = paths.tempRecovery.appendingPathComponent(jobID.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: dir.appendingPathComponent("normalized.wav"))

        let metadata = RecoveryScanner.RecoveryMetadata(
            schemaVersion: 1,
            jobID: jobID,
            sourcePath: "/Users/mike/meeting.m4a",
            failureStage: "transcribing",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            technicalError: "mock failure"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: dir.appendingPathComponent("recovery.json")
        )

        let report = RecoveryScanner.scan(
            paths: paths,
            systemTempRoot: tempJobs
        )

        XCTAssertEqual(report.recoverableCount, 1)
        XCTAssertEqual(report.items[0].kind, .recoverable)
        XCTAssertEqual(report.items[0].sourcePath, "/Users/mike/meeting.m4a")
        XCTAssertEqual(report.items[0].failureStage, "transcribing")
        XCTAssertTrue(report.items[0].hasNormalizedWAV)
        XCTAssertTrue(report.items[0].hasRecoveryJSON)
    }

    func testMismatchedJobIDInRecoveryJSONIsDamaged() throws {
        let folderID = UUID()
        let metadataID = UUID()
        let dir = paths.tempRecovery.appendingPathComponent(folderID.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: dir.appendingPathComponent("normalized.wav"))

        let metadata = RecoveryScanner.RecoveryMetadata(
            schemaVersion: 1,
            jobID: metadataID,
            sourcePath: "/tmp/a.m4a",
            failureStage: "failed",
            createdAt: Date(),
            technicalError: "x"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: dir.appendingPathComponent("recovery.json")
        )

        let report = RecoveryScanner.scan(
            paths: paths,
            systemTempRoot: tempJobs
        )

        XCTAssertEqual(report.damagedCount, 1)
        XCTAssertEqual(report.items[0].kind, .damaged)
    }

    func testInvalidRecoveryJSONIsDamaged() throws {
        let jobID = UUID()
        let dir = paths.tempRecovery.appendingPathComponent(jobID.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: dir.appendingPathComponent("recovery.json")
        )

        let report = RecoveryScanner.scan(
            paths: paths,
            systemTempRoot: tempJobs
        )

        XCTAssertEqual(report.damagedCount, 1)
        XCTAssertTrue(report.items[0].summary.contains("無法解析"))
    }

    func testDoesNotScanOutsideManagedRoots() {
        let outside = URL(fileURLWithPath: "/tmp")
        XCTAssertFalse(
            RecoveryScanner.isPathInsideManagedRoot(
                outside,
                roots: [paths.tempRecovery, tempJobs]
            )
        )
        let inside = paths.tempRecovery.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(
            RecoveryScanner.isPathInsideManagedRoot(
                inside,
                roots: [paths.tempRecovery, tempJobs]
            )
        )
    }

    func testParseJobDirectoryName() {
        let id = UUID()
        XCTAssertEqual(RecoveryScanner.parseJobDirectoryName(id.uuidString), id)
        XCTAssertNil(RecoveryScanner.parseJobDirectoryName("abc"))
        XCTAssertNil(RecoveryScanner.parseJobDirectoryName(""))
    }
}
