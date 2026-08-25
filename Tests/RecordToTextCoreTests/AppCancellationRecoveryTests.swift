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
}
