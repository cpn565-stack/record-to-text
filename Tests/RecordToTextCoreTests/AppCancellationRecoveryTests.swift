import Foundation
import XCTest
@testable import RecordToTextApp
@testable import RecordToTextCore

@MainActor
final class AppCancellationRecoveryTests: XCTestCase {
    func testValidManagedCancellationCheckpointIsVisibleOnCancelledJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cancelled-job-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let jobID = UUID()
        let directory = paths.tempRecovery.appendingPathComponent(
            jobID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let partial = directory.appendingPathComponent(
            RecoveryScanner.partialTranscriptFileName
        )
        try Data("已完成的部分稿".utf8).write(to: partial)
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent(
                RecoveryScanner.segmentManifestFileName
            )
        )
        let metadata = RecoveryScanner.RecoveryMetadata(
            schemaVersion: 2,
            jobID: jobID,
            sourcePath: "/recordings/source.m4a",
            failureStage: TranscriptionStage.transcribing.rawValue,
            createdAt: Date(),
            technicalError: "cancelled",
            recoveryKind: "cloudCheckpoint",
            backendType: .googleAIStudio,
            checkpointFile: RecoveryScanner.segmentManifestFileName,
            segmentsDirectory: RecoveryScanner.segmentsDirectoryName,
            partialTranscriptFile: RecoveryScanner.partialTranscriptFileName
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: directory.appendingPathComponent(
                RecoveryScanner.recoveryJSONFileName
            )
        )

        let failure = AppViewModel.cancellationRecoveryFailure(
            jobID: jobID,
            paths: paths
        )
        XCTAssertEqual(failure?.stage, .cancelled)
        XCTAssertEqual(failure?.recoveryDirectory, directory.path)
        XCTAssertEqual(failure?.partialTranscriptPath, partial.path)
    }

    func testEmptyOrMismatchedCancellationCheckpointStaysHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "empty-cancelled-job-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let jobID = UUID()
        let directory = paths.tempRecovery.appendingPathComponent(
            jobID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("   \n".utf8).write(
            to: directory.appendingPathComponent(
                RecoveryScanner.partialTranscriptFileName
            )
        )
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent(
                RecoveryScanner.segmentManifestFileName
            )
        )
        let metadata = RecoveryScanner.RecoveryMetadata(
            schemaVersion: 2,
            jobID: UUID(),
            sourcePath: "/recordings/source.m4a",
            failureStage: TranscriptionStage.transcribing.rawValue,
            createdAt: Date(),
            technicalError: "cancelled",
            recoveryKind: "cloudCheckpoint",
            backendType: .googleAIStudio
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: directory.appendingPathComponent(
                RecoveryScanner.recoveryJSONFileName
            )
        )

        XCTAssertEqual(
            AppViewModel.cancellationRecoveryFailure(
                jobID: jobID,
                paths: paths
            ),
            nil
        )
    }

    func testLocalChunkCheckpointIsVisibleOnCancelledJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cancelled-local-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let jobID = UUID()
        let recovery = paths.tempRecovery.appendingPathComponent(
            jobID.uuidString,
            isDirectory: true
        )
        let checkpointDirectory = try LocalChunkCheckpoint.createSecureDirectory(
            in: recovery
        )
        try Data(
            """
            {
              "schemaVersion": 1,
              "fingerprint": "\(String(repeating: "c", count: 64))",
              "totalChunks": 3,
              "completedChunks": [
                {"index": 0, "text": "第一塊。", "containsSkippedAudio": false}
              ]
            }
            """.utf8
        ).write(
            to: checkpointDirectory.appendingPathComponent(
                "segment-0001-of-0001.chunks.json"
            )
        )

        let failure = AppViewModel.localChunkRecoveryFailure(
            jobID: jobID,
            stage: .cancelled,
            paths: paths,
            technicalDetails: "cancelled"
        )
        XCTAssertEqual(failure?.stage, .cancelled)
        XCTAssertEqual(failure?.recoveryDirectory, recovery.path)
        XCTAssertNil(failure?.partialTranscriptPath)
    }

    func testRecoveryReportHidesOnlyActiveTempRecoveryDirectory() {
        let activeID = UUID()
        let stoppedID = UUID()
        let active = RecoveryScanItem(
            jobID: activeID,
            location: .tempRecovery,
            kind: .orphaned,
            directoryPath: "/recovery/\(activeID.uuidString)",
            summary: "active",
            detail: "",
            hasNormalizedWAV: false,
            hasRecoveryJSON: false,
            hasSegmentManifest: false,
            recognizedFileNames: [LocalChunkCheckpoint.directoryName],
            unknownEntryNames: []
        )
        let stopped = RecoveryScanItem(
            jobID: stoppedID,
            location: .tempRecovery,
            kind: .orphaned,
            directoryPath: "/recovery/\(stoppedID.uuidString)",
            summary: "stopped",
            detail: "",
            hasNormalizedWAV: false,
            hasRecoveryJSON: false,
            hasSegmentManifest: false,
            recognizedFileNames: [LocalChunkCheckpoint.directoryName],
            unknownEntryNames: []
        )
        let report = RecoveryScanReport(
            systemTempRoot: "/tmp/jobs",
            tempRecoveryRoot: "/recovery",
            items: [active, stopped],
            ignoredNonUUIDDirectoryCount: 0
        )

        let filtered = AppViewModel.excludingActiveJobDirectories(
            from: report,
            activeRecoveryDirectoryPaths: [active.directoryPath]
        )
        XCTAssertEqual(filtered.items, [stopped])
    }
}
