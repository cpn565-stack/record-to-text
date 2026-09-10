import Foundation
import XCTest
@testable import RecordToTextCore
@testable import RecordToTextApp

@MainActor
final class OutputCompletenessTests: XCTestCase {
    func testCompletionPersistsNormalLocalGapAndCloudGapAcrossAppRestart() async throws {
        for kind in ["normal", "localGap", "cloudGap"] {
            let root = try TestSupport.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ApplicationPaths(root: root)
            let model = AppViewModel(paths: paths, credentialStore: EmptyCompletionCredentialStore())
            await model.waitForCredentialLoading()
            model.setSetting(\.outputLocationMode, to: .fixedDirectory)
            model.setSetting(\.defaultOutputDirectory, to: root.path)
            model.setSetting(\.showNotificationWhenCompleted, to: false)
            model.setSetting(\.revealInFinderWhenCompleted, to: false)
            model.setSetting(\.openTextWhenCompleted, to: false)
            model.setSetting(\.backendType, to: kind == "cloudGap" ? .googleAIStudio : .localQwen)
            model.addFiles([root.appendingPathComponent("source.wav")])
            let job = try XCTUnwrap(model.jobs.first)
            let sourceBytes = Data("source fixture".utf8)
            try sourceBytes.write(to: job.sourceURL)
            let output = root.appendingPathComponent("final.txt")
            let outputBytes = Data("既有稿件不得被修改".utf8)
            try outputBytes.write(to: output)
            let recovery = kind == "cloudGap" ? try makeCheckpoint(job: job, paths: paths) : nil
            let result = PipelineResult(outputURL: output, rawOutputURL: nil, duration: 1,
                containsSkippedAudio: kind != "normal", incompleteCloudSegmentIndices: kind == "cloudGap" ? [2] : [],
                recoveryDirectory: recovery)
            let accepted = await model.acceptCompletedResult(result, id: job.id)
            XCTAssertTrue(accepted)
            let next = AppViewModel(paths: paths, credentialStore: EmptyCompletionCredentialStore())
            await next.waitForCredentialLoading()
            let summary = try XCTUnwrap(next.recentJobs.first { $0.id == job.id })
            XCTAssertEqual(summary.resolvedOutputCompleteness, kind == "normal" ? .complete : .hasGaps)
            XCTAssertEqual(summary.statusWithCompletionTime().contains("含缺口"), kind != "normal")
            if kind == "cloudGap" {
                let retained = try XCTUnwrap(next.jobs.first { $0.id == job.id })
                XCTAssertTrue(next.canResumeCloudJob(retained))
                next.setSetting(\.recentJobLimit, to: 0)
                next.persistJobs()
                try await next.flushJobPersistence()
                let third = AppViewModel(paths: paths, credentialStore: EmptyCompletionCredentialStore())
                await third.waitForCredentialLoading()
                let durable = try XCTUnwrap(third.jobs.first { $0.id == job.id })
                XCTAssertTrue(third.canResumeCloudJob(durable))
                third.removeFinishedJob(job.id)
                try await third.flushJobPersistence()
                let fourth = AppViewModel(paths: paths, credentialStore: EmptyCompletionCredentialStore())
                await fourth.waitForCredentialLoading()
                XCTAssertFalse(fourth.jobs.contains { $0.id == job.id })
                XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recovery).path))
            }
            XCTAssertEqual(try Data(contentsOf: output), outputBytes)
            XCTAssertEqual(try Data(contentsOf: job.sourceURL), sourceBytes)
        }
    }

    func testMissingCorruptAndCompleteCheckpointDoNotOfferGapResume() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        try paths.createDirectories()
        var job = TranscriptionJob(sourcePath: root.appendingPathComponent("source.wav").path, snapshot: snapshot(root: root))
        try Data("source".utf8).write(to: job.sourceURL)
        let recovery = try makeCheckpoint(job: job, paths: paths)
        job.stage = .completed
        job.outputCompleteness = .hasGaps
        job.failure = JobFailure(stage: .completed, userMessage: "含缺口", technicalDetails: "",
            recoverable: true, recoveryDirectory: recovery.path)
        XCTAssertTrue(CloudResumeCheckpointLoader.containsUsableCheckpoint(for: job, paths: paths))
        let manifestURL = recovery.appendingPathComponent(RecoveryScanner.segmentManifestFileName)
        let original = try Data(contentsOf: manifestURL)
        try Data("{}".utf8).write(to: manifestURL)
        XCTAssertFalse(CloudResumeCheckpointLoader.containsUsableCheckpoint(for: job, paths: paths))
        var manifest = try JSONDecoder().decode(AudioSegmentManifest.self, from: original)
        manifest.segments[1].status = .completed
        manifest.segments[1].completedEventCount = 1
        try Data("第二段".utf8).write(to: URL(fileURLWithPath: manifest.segments[1].outputPath))
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        XCTAssertFalse(CloudResumeCheckpointLoader.containsUsableCheckpoint(for: job, paths: paths))
        try FileManager.default.removeItem(at: manifestURL)
        XCTAssertFalse(CloudResumeCheckpointLoader.containsUsableCheckpoint(for: job, paths: paths))
    }

    func testLegacyCompletedRecordsDecodeAsUnknown() throws {
        let root = URL(fileURLWithPath: "/fixture")
        var job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot(root: root))
        job.stage = .completed
        let encoded = try JSONEncoder().encode(job)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("outputCompleteness"))
        let decoded = try JSONDecoder().decode(TranscriptionJob.self, from: encoded)
        XCTAssertEqual(decoded.resolvedOutputCompleteness, .unknown)
        let summary = RecentJobSummary(id: job.id, sourcePath: job.sourcePath, outputPath: nil,
            stage: .completed, startedAt: nil, completedAt: nil, modelID: "fixture", glossaryName: nil)
        let restored = try JSONDecoder().decode(RecentJobSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(restored.resolvedOutputCompleteness, .unknown)
        XCTAssertEqual(restored.statusWithCompletionTime(), "完成（完整性未確認）")
    }

    func testPublicationRecoveryPreservesCompleteness() throws {
        for hasGaps in [false, true] {
            let root = try TestSupport.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ApplicationPaths(root: root)
            let job = TranscriptionJob(sourcePath: "/fixture.wav", snapshot: snapshot(root: root))
            let output = root.appendingPathComponent("final.txt")
            let store = OutputPublicationStore(paths: paths)
            try store.prepare(job: job, result: .init(outputURL: output, rawOutputURL: nil, duration: 1,
                containsSkippedAudio: hasGaps), text: "完成稿")
            try AtomicFileWriter.writeTextNew("完成稿", to: output)
            let recovered = try XCTUnwrap(store.recover(job: job))
            XCTAssertEqual(recovered.resolvedOutputCompleteness, hasGaps ? .hasGaps : .complete)
            let canonical = PersistenceSnapshot(revision: 1, jobs: [recovered], recentJobs: [], recentHistoryLimit: 10).canonical()
            XCTAssertEqual(canonical.recentJobs.first?.resolvedOutputCompleteness, hasGaps ? .hasGaps : .complete)
        }
    }

    private func snapshot(root: URL) -> JobSnapshot {
        JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil, terms: [], prompt: "",
            outputLocationMode: .fixedDirectory, outputDirectory: root.path, keepRawTranscript: false,
            backendType: .googleAIStudio)
    }

    private func makeCheckpoint(job: TranscriptionJob, paths: ApplicationPaths) throws -> URL {
        let directory = paths.tempRecovery.appendingPathComponent(job.id.uuidString)
        let segments = directory.appendingPathComponent(RecoveryScanner.segmentsDirectoryName)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let first = segments.appendingPathComponent("segment-0001.txt")
        try Data("第一段已完成".utf8).write(to: first)
        let manifest = AudioSegmentManifest(jobID: job.id, sourceDurationSeconds: 2400,
            maximumSegmentDurationSeconds: 1200, expectedSegmentCount: 2, segments: [
                AudioSegmentRecord(segmentIndex: 1, segmentCount: 2, startSeconds: 0, endSeconds: 1200,
                    audioPath: "", outputPath: first.path, status: .completed, completedEventCount: 1),
                AudioSegmentRecord(segmentIndex: 2, segmentCount: 2, startSeconds: 1200, endSeconds: 2400,
                    audioPath: "", outputPath: segments.appendingPathComponent("segment-0002.txt").path, status: .blockedBySafety)
            ])
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(RecoveryScanner.segmentManifestFileName))
        let metadata = RecoveryScanner.RecoveryMetadata(schemaVersion: 2, jobID: job.id, sourcePath: job.sourcePath,
            failureStage: "transcribing", createdAt: Date(), technicalError: "safety fixture",
            recoveryKind: "cloudCheckpoint", backendType: job.snapshot.backendType,
            checkpointFile: RecoveryScanner.segmentManifestFileName, segmentsDirectory: RecoveryScanner.segmentsDirectoryName,
            partialTranscriptFile: RecoveryScanner.partialTranscriptFileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: directory.appendingPathComponent(RecoveryScanner.recoveryJSONFileName))
        return directory
    }
}

private struct EmptyCompletionCredentialStore: GoogleAIStudioCredentialStoring {
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ apiKey: String?) throws {}
}
