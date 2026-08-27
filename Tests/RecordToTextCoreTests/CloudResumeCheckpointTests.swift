import Foundation
import XCTest
@testable import RecordToTextCore

final class CloudResumeCheckpointTests: XCTestCase {
    func testLoadsOnlyCompletedNonEmptyManagedSegments() throws {
        let fixture = try makeFixture()
        let checkpoint = try CloudResumeCheckpointLoader.load(
            recoveryDirectory: fixture.recoveryDirectory,
            job: fixture.job,
            sourceDuration: 2_400,
            sourceTimeOffset: 0,
            maximumSegmentDuration: 1_200,
            paths: fixture.paths
        )

        XCTAssertEqual(checkpoint.plan.expectedSegmentCount, 2)
        XCTAssertEqual(
            checkpoint.reusableSegments[1]?.transcript,
            "第一段已完成"
        )
        XCTAssertEqual(
            checkpoint.reusableSegments[1]?.metadata?.effectiveModelID,
            "gemini-3.7-flash"
        )
        XCTAssertNil(checkpoint.reusableSegments[2])
    }

    func testRejectsDifferentSourceBackendAndOutsideDirectory() throws {
        let fixture = try makeFixture()
        var differentSnapshot = fixture.job.snapshot
        differentSnapshot = JobSnapshot(
            modelID: differentSnapshot.modelID,
            glossaryID: differentSnapshot.glossaryID,
            glossaryName: differentSnapshot.glossaryName,
            terms: differentSnapshot.terms,
            prompt: differentSnapshot.prompt,
            outputLocationMode: differentSnapshot.outputLocationMode,
            outputDirectory: differentSnapshot.outputDirectory,
            keepRawTranscript: differentSnapshot.keepRawTranscript,
            backendType: .vertexAI
        )
        let differentJob = TranscriptionJob(
            sourcePath: fixture.job.sourcePath,
            snapshot: differentSnapshot
        )
        XCTAssertThrowsError(
            try CloudResumeCheckpointLoader.load(
                recoveryDirectory: fixture.recoveryDirectory,
                job: differentJob,
                sourceDuration: 2_400,
                sourceTimeOffset: 0,
                maximumSegmentDuration: 1_200,
                paths: fixture.paths
            )
        )

        let outside = fixture.root.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(
            try CloudResumeCheckpointLoader.load(
                recoveryDirectory: outside,
                job: fixture.job,
                sourceDuration: 2_400,
                sourceTimeOffset: 0,
                maximumSegmentDuration: 1_200,
                paths: fixture.paths
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudResumeCheckpointError,
                .outsideManagedRecoveryRoot
            )
        }
    }

    func testBlankCompletedSegmentIsNotReusable() throws {
        let fixture = try makeFixture(firstTranscript: "   \n")
        XCTAssertThrowsError(
            try CloudResumeCheckpointLoader.load(
                recoveryDirectory: fixture.recoveryDirectory,
                job: fixture.job,
                sourceDuration: 2_400,
                sourceTimeOffset: 0,
                maximumSegmentDuration: 1_200,
                paths: fixture.paths
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudResumeCheckpointError,
                .noReusableSegments
            )
        }
    }

    private struct Fixture {
        let root: URL
        let paths: ApplicationPaths
        let recoveryDirectory: URL
        let job: TranscriptionJob
    }

    private func makeFixture(
        firstTranscript: String = "第一段已完成"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "record-to-text-resume-\(UUID().uuidString)",
                isDirectory: true
            )
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        let oldJobID = UUID()
        let recovery = paths.tempRecovery.appendingPathComponent(
            oldJobID.uuidString,
            isDirectory: true
        )
        let segments = recovery.appendingPathComponent(
            RecoveryScanner.segmentsDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: segments,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let sourcePath = root.appendingPathComponent("source.m4a").path
        try Data("source".utf8).write(to: URL(fileURLWithPath: sourcePath))
        let firstURL = segments.appendingPathComponent("segment-0001.txt")
        try Data(firstTranscript.utf8).write(to: firstURL)
        let secondURL = segments.appendingPathComponent("segment-0002.txt")

        let metadata = RecoveryScanner.RecoveryMetadata(
            schemaVersion: 2,
            jobID: oldJobID,
            sourcePath: sourcePath,
            sourceSlice: nil,
            failureStage: TranscriptionStage.transcribing.rawValue,
            createdAt: Date(),
            technicalError: "HTTP 503",
            recoveryKind: "cloudCheckpoint",
            backendType: .googleAIStudio,
            checkpointFile: RecoveryScanner.segmentManifestFileName,
            segmentsDirectory: RecoveryScanner.segmentsDirectoryName,
            partialTranscriptFile: RecoveryScanner.partialTranscriptFileName
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: recovery.appendingPathComponent(
                RecoveryScanner.recoveryJSONFileName
            )
        )

        let cloudMetadata = CloudTranscriptionMetadata(
            requestedModelID: "gemini-3.7-flash",
            effectiveModelID: "gemini-3.7-flash",
            modelVersion: "gemini-3.7-flash-test"
        )
        let manifest = AudioSegmentManifest(
            jobID: oldJobID,
            sourceDurationSeconds: 2_400,
            maximumSegmentDurationSeconds: 1_200,
            expectedSegmentCount: 2,
            segments: [
                AudioSegmentRecord(
                    segmentIndex: 1,
                    segmentCount: 2,
                    startSeconds: 0,
                    endSeconds: 1_200,
                    audioPath: "",
                    outputPath: firstURL.path,
                    status: .completed,
                    completedEventCount: 1,
                    cloudMetadata: cloudMetadata
                ),
                AudioSegmentRecord(
                    segmentIndex: 2,
                    segmentCount: 2,
                    startSeconds: 1_200,
                    endSeconds: 2_400,
                    audioPath: "",
                    outputPath: secondURL.path,
                    status: .failed,
                    failureMessage: "HTTP 503"
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: recovery.appendingPathComponent(
                RecoveryScanner.segmentManifestFileName
            )
        )

        let snapshot = JobSnapshot(
            modelID: "local-placeholder",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "prompt",
            outputLocationMode: .sameAsSource,
            outputDirectory: "",
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioModelID: "gemini-3.7-flash"
        )
        return Fixture(
            root: root,
            paths: paths,
            recoveryDirectory: recovery,
            job: TranscriptionJob(
                sourcePath: sourcePath,
                snapshot: snapshot
            )
        )
    }
}
