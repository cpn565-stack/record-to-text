#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def replace_once(content: str, old: str, new: str, label: str) -> str:
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return content.replace(old, new, 1)


resume_source = r'''import Foundation

public struct ReusableCloudSegment: Equatable, Sendable {
    public let segmentIndex: Int
    public let transcript: String
    public let status: AudioSegmentStatus
    public let metadata: CloudTranscriptionMetadata?

    public init(
        segmentIndex: Int,
        transcript: String,
        status: AudioSegmentStatus,
        metadata: CloudTranscriptionMetadata?
    ) {
        self.segmentIndex = segmentIndex
        self.transcript = transcript
        self.status = status
        self.metadata = metadata
    }
}

public struct CloudResumeCheckpoint: Equatable, Sendable {
    public let recoveryDirectory: URL
    public let plan: AudioSegmentationPlan
    public let reusableSegments: [Int: ReusableCloudSegment]

    public init(
        recoveryDirectory: URL,
        plan: AudioSegmentationPlan,
        reusableSegments: [Int: ReusableCloudSegment]
    ) {
        self.recoveryDirectory = recoveryDirectory
        self.plan = plan
        self.reusableSegments = reusableSegments
    }
}

public enum CloudResumeCheckpointError: LocalizedError, Equatable {
    case outsideManagedRecoveryRoot
    case missingRecoveryMetadata
    case incompatibleRecovery(String)
    case missingManifest
    case invalidManifest(String)
    case noReusableSegments

    public var errorDescription: String? {
        switch self {
        case .outsideManagedRecoveryRoot:
            return "復原資料不在 record-to-text 管理的 Temp-Recovery 範圍內。"
        case .missingRecoveryMetadata:
            return "復原資料缺少有效的 recovery.json。"
        case let .incompatibleRecovery(reason):
            return "復原資料與目前工作不相容：\(reason)"
        case .missingManifest:
            return "復原資料缺少 segment-manifest.json。"
        case let .invalidManifest(reason):
            return "復原分段紀錄無法安全續跑：\(reason)"
        case .noReusableSegments:
            return "復原資料中沒有可安全重用的已完成片段。"
        }
    }
}

public enum CloudResumeCheckpointLoader {
    public static func load(
        recoveryDirectory: URL,
        job: TranscriptionJob,
        sourceDuration: TimeInterval,
        sourceTimeOffset: TimeInterval,
        maximumSegmentDuration: TimeInterval,
        paths: ApplicationPaths,
        fileManager: FileManager = .default
    ) throws -> CloudResumeCheckpoint {
        let managedRoot = paths.tempRecovery
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedDirectory = recoveryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard resolvedDirectory.deletingLastPathComponent().path
            == managedRoot.path
        else {
            throw CloudResumeCheckpointError.outsideManagedRecoveryRoot
        }

        let metadataURL = resolvedDirectory.appendingPathComponent(
            RecoveryScanner.recoveryJSONFileName
        )
        guard let metadataData = try? Data(contentsOf: metadataURL) else {
            throw CloudResumeCheckpointError.missingRecoveryMetadata
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(
            RecoveryScanner.RecoveryMetadata.self,
            from: metadataData
        ) else {
            throw CloudResumeCheckpointError.missingRecoveryMetadata
        }
        guard metadata.schemaVersion >= 2,
              metadata.recoveryKind == "cloudCheckpoint"
        else {
            throw CloudResumeCheckpointError.incompatibleRecovery(
                "不是可續跑的雲端片段檢查點"
            )
        }
        guard standardizedPath(metadata.sourcePath) == standardizedPath(job.sourcePath) else {
            throw CloudResumeCheckpointError.incompatibleRecovery(
                "來源錄音路徑不同"
            )
        }
        guard metadata.sourceSlice == job.sourceSlice else {
            throw CloudResumeCheckpointError.incompatibleRecovery(
                "來源時間範圍不同"
            )
        }
        guard metadata.backendType == job.snapshot.backendType,
              job.snapshot.backendType != .localQwen
        else {
            throw CloudResumeCheckpointError.incompatibleRecovery(
                "雲端後端不同"
            )
        }

        let manifestURL = resolvedDirectory.appendingPathComponent(
            RecoveryScanner.segmentManifestFileName
        )
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                  AudioSegmentManifest.self,
                  from: manifestData
              )
        else {
            throw CloudResumeCheckpointError.missingManifest
        }
        guard manifest.expectedSegmentCount > 0,
              manifest.segments.count == manifest.expectedSegmentCount
        else {
            throw CloudResumeCheckpointError.invalidManifest(
                "分段數量不一致"
            )
        }
        guard abs(manifest.sourceDurationSeconds - sourceDuration) <= 0.75 else {
            throw CloudResumeCheckpointError.incompatibleRecovery(
                "來源長度已改變"
            )
        }
        guard abs(
            manifest.maximumSegmentDurationSeconds
                - maximumSegmentDuration
        ) <= 0.75 else {
            throw CloudResumeCheckpointError.incompatibleRecovery(
                "分段上限已改變"
            )
        }

        let ordered = manifest.segments.sorted {
            $0.segmentIndex < $1.segmentIndex
        }
        var planSegments: [PlannedAudioSegment] = []
        var reusable: [Int: ReusableCloudSegment] = [:]
        var expectedAbsoluteStart = sourceTimeOffset
        let recoverySegmentsDirectory = resolvedDirectory
            .appendingPathComponent(
                RecoveryScanner.segmentsDirectoryName,
                isDirectory: true
            )
            .standardizedFileURL
            .resolvingSymlinksInPath()

        for (zeroBasedIndex, record) in ordered.enumerated() {
            let expectedIndex = zeroBasedIndex + 1
            guard record.segmentIndex == expectedIndex,
                  record.segmentCount == manifest.expectedSegmentCount,
                  record.startSeconds.isFinite,
                  record.endSeconds.isFinite,
                  abs(record.startSeconds - expectedAbsoluteStart) <= 0.75,
                  record.endSeconds > record.startSeconds
            else {
                throw CloudResumeCheckpointError.invalidManifest(
                    "分段編號、順序或邊界不連續"
                )
            }
            let duration = record.endSeconds - record.startSeconds
            guard duration <= maximumSegmentDuration + 0.75 else {
                throw CloudResumeCheckpointError.invalidManifest(
                    "第 \(record.segmentIndex) 段超過目前上限"
                )
            }
            let relativeStart = record.startSeconds - sourceTimeOffset
            guard relativeStart >= -0.75 else {
                throw CloudResumeCheckpointError.invalidManifest(
                    "第 \(record.segmentIndex) 段起點早於來源範圍"
                )
            }
            planSegments.append(
                PlannedAudioSegment(
                    index: record.segmentIndex,
                    startSeconds: max(relativeStart, 0),
                    durationSeconds: duration
                )
            )
            expectedAbsoluteStart = record.endSeconds

            guard
                (record.status == .completed
                    || record.status == .completedWithGaps),
                record.completedEventCount == 1
            else {
                continue
            }
            let transcriptURL = URL(fileURLWithPath: record.outputPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard transcriptURL.deletingLastPathComponent().path
                    == recoverySegmentsDirectory.path,
                  fileManager.fileExists(atPath: transcriptURL.path),
                  let transcript = try? TextFileValidator.readNonEmptyUTF8(
                      at: transcriptURL
                  )
            else {
                continue
            }
            reusable[record.segmentIndex] = ReusableCloudSegment(
                segmentIndex: record.segmentIndex,
                transcript: transcript,
                status: record.status,
                metadata: record.cloudMetadata
            )
        }

        guard abs(
            expectedAbsoluteStart
                - (sourceTimeOffset + sourceDuration)
        ) <= 0.75 else {
            throw CloudResumeCheckpointError.invalidManifest(
                "最後一段沒有覆蓋到來源結尾"
            )
        }
        guard !reusable.isEmpty else {
            throw CloudResumeCheckpointError.noReusableSegments
        }

        return CloudResumeCheckpoint(
            recoveryDirectory: resolvedDirectory,
            plan: AudioSegmentationPlan(
                sourceDurationSeconds: sourceDuration,
                maximumSegmentDurationSeconds: maximumSegmentDuration,
                segments: planSegments
            ),
            reusableSegments: reusable
        )
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
'''
write(
    "Sources/RecordToTextCore/CloudResumeCheckpoint.swift",
    resume_source,
)

engine_path = "Sources/RecordToTextCore/TranscriptionEngine.swift"
engine = read(engine_path)
old_plan = '''        let segmentPlan = try await makeCloudSegmentPlan(
            job: job,
            sourceURL: sourceURL,
            metadata: metadata,
            update: update
        )
        let totalSegments = segmentPlan.expectedSegmentCount
        let sourceTimeOffset = Self.cloudSegmentStart(
            sourceSlice: job.sourceSlice,
            plannedStart: 0
        )
'''
new_plan = '''        let sourceTimeOffset = Self.cloudSegmentStart(
            sourceSlice: job.sourceSlice,
            plannedStart: 0
        )
        let resumeCheckpoint: CloudResumeCheckpoint?
        if let rawRecoveryPath = job.resumeFromRecoveryDirectory {
            let loaded = try CloudResumeCheckpointLoader.load(
                recoveryDirectory: URL(
                    fileURLWithPath: rawRecoveryPath,
                    isDirectory: true
                ),
                job: job,
                sourceDuration: metadata.duration,
                sourceTimeOffset: sourceTimeOffset,
                maximumSegmentDuration: maximumASRSegmentDuration,
                paths: paths,
                fileManager: fileManager
            )
            resumeCheckpoint = loaded
            update(
                .log(
                    level: "info",
                    message: "已驗證雲端復原檢查點，將重用 \(loaded.reusableSegments.count) 個已完成片段。"
                )
            )
        } else {
            resumeCheckpoint = nil
        }
        let segmentPlan = if let resumeCheckpoint {
            resumeCheckpoint.plan
        } else {
            try await makeCloudSegmentPlan(
                job: job,
                sourceURL: sourceURL,
                metadata: metadata,
                update: update
            )
        }
        let totalSegments = segmentPlan.expectedSegmentCount
'''
engine = replace_once(engine, old_plan, new_plan, "resume segment plan")

old_manifest_write = '''        try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

        if segmentPlan.requiresSplitting {
'''
new_manifest_write = '''        if let resumeCheckpoint {
            for (segmentIndex, reusable) in resumeCheckpoint.reusableSegments {
                guard segmentManifest.segments.indices.contains(segmentIndex - 1) else {
                    continue
                }
                let destination = URL(
                    fileURLWithPath:
                        segmentManifest.segments[segmentIndex - 1].outputPath
                )
                try AtomicFileWriter.writeText(
                    reusable.transcript,
                    to: destination
                )
                segmentManifest.segments[segmentIndex - 1].status = reusable.status
                segmentManifest.segments[segmentIndex - 1].completedEventCount = 1
                segmentManifest.segments[segmentIndex - 1].failureMessage = nil
                segmentManifest.segments[segmentIndex - 1].cloudMetadata =
                    reusable.metadata
                segmentManifest.segments[segmentIndex - 1].reusedFromCheckpoint = true
            }
        }
        try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

        if segmentPlan.requiresSplitting {
'''
engine = replace_once(
    engine,
    old_manifest_write,
    new_manifest_write,
    "hydrate resumed manifest",
)

loop_marker = '''            let waitingUnit = totalSegments > 1
                ? "waiting|\(segmentIndex)|\(totalSegments)"
                : "waiting"

            do {
'''
loop_replacement = '''            let waitingUnit = totalSegments > 1
                ? "waiting|\(segmentIndex)|\(totalSegments)"
                : "waiting"

            if
                (record.status == .completed
                    || record.status == .completedWithGaps),
                record.completedEventCount == 1,
                record.reusedFromCheckpoint == true,
                (try? TextFileValidator.readNonEmptyUTF8(at: transcriptURL)) != nil
            {
                update(
                    .log(
                        level: "info",
                        message: "［第 \(segmentIndex)/\(totalSegments) 段］沿用已完成檢查點，不重新壓縮、上傳或計費轉錄。"
                    )
                )
                if let metadata = record.cloudMetadata {
                    emitCloudMetadataLog(
                        metadata,
                        segmentIndex: segmentIndex,
                        segmentCount: totalSegments,
                        update: update
                    )
                }
                update(
                    .progress(
                        current: maxProgress,
                        total: 100,
                        unit: totalSegments > 1
                            ? "percent|\(segmentIndex)|\(totalSegments)"
                            : "percent"
                    )
                )
                continue
            }

            do {
'''
engine = replace_once(
    engine,
    loop_marker,
    loop_replacement,
    "skip reused segments",
)

old_recovery_record = '''                    status: sourceRecord.status,
                    completedEventCount: sourceRecord.completedEventCount,
                    failureMessage: sourceRecord.failureMessage
                )
'''
new_recovery_record = '''                    status: sourceRecord.status,
                    completedEventCount: sourceRecord.completedEventCount,
                    failureMessage: sourceRecord.failureMessage,
                    cloudMetadata: sourceRecord.cloudMetadata,
                    reusedFromCheckpoint: sourceRecord.reusedFromCheckpoint
                )
'''
engine = replace_once(
    engine,
    old_recovery_record,
    new_recovery_record,
    "preserve resume metadata",
)
write(engine_path, engine)

vm_path = "Sources/RecordToTextApp/AppViewModel.swift"
vm = read(vm_path)
insert_after = '''    func retryWithoutGlossaryPrompt() {
'''
resume_methods = r'''    func canResumeCloudJob(_ job: TranscriptionJob) -> Bool {
        guard job.snapshot.backendType != .localQwen,
              job.stage == .failed
                || job.stage == .cancelled
                || job.stage == .interrupted,
              let recoveryDirectory = job.failure?.recoveryDirectory
        else {
            return false
        }
        let recoveryURL = URL(
            fileURLWithPath: recoveryDirectory,
            isDirectory: true
        )
        return fileManager.fileExists(
            atPath: recoveryURL
                .appendingPathComponent(
                    RecoveryScanner.segmentManifestFileName
                )
                .path
        )
    }

    func resumeCloudJobFromCheckpoint(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldJob = jobs[index]
        guard canResumeCloudJob(oldJob),
              let recoveryDirectory = oldJob.failure?.recoveryDirectory
        else {
            alert = UserFacingAlert(
                title: "沒有可續跑的片段",
                message: "這筆工作沒有通過基本檢查的雲端片段檢查點。"
            )
            return
        }
        guard fileManager.fileExists(atPath: oldJob.sourcePath) else {
            alert = UserFacingAlert(
                title: "來源錄音不存在",
                message: "找不到原始錄音，無法重新建立尚未完成的音訊片段。"
            )
            return
        }

        var resumed = TranscriptionJob(
            sourcePath: oldJob.sourcePath,
            snapshot: oldJob.snapshot.withGoogleAIStudioAPIKey(nil),
            sourceSlice: oldJob.sourceSlice,
            resumeFromRecoveryDirectory: recoveryDirectory
        )
        resumed.logLines.append(
            "從雲端檢查點續跑；已完成片段會先驗證，只有未完成片段會重新上傳與轉錄。"
        )
        jobs.insert(resumed, at: min(index + 1, jobs.count))
        persistJobs()
        manualDrainRequested = true
        scheduleQueueIfNeeded()
    }

'''
if insert_after not in vm:
    raise RuntimeError("retryWithoutGlossaryPrompt marker missing")
vm = vm.replace(insert_after, resume_methods + insert_after, 1)
write(vm_path, vm)

main_path = "Sources/RecordToTextApp/MainView.swift"
main = read(main_path)
ui_marker = '''                        if failure.partialTranscriptPath != nil {
                            Button("打開未完成稿") {
                                viewModel.openPartialTranscript(for: job)
                            }
                        }

                        Button("在 Finder 顯示復原資料") {
'''
ui_replacement = '''                        if failure.partialTranscriptPath != nil {
                            Button("打開未完成稿") {
                                viewModel.openPartialTranscript(for: job)
                            }
                        }

                        if viewModel.canResumeCloudJob(job) {
                            Button("從已完成片段續跑") {
                                viewModel.resumeCloudJobFromCheckpoint(job.id)
                            }
                            .buttonStyle(.link)
                        }

                        Button("在 Finder 顯示復原資料") {
'''
main = replace_once(
    main,
    ui_marker,
    ui_replacement,
    "resume UI button",
)
write(main_path, main)

resume_tests = r'''import Foundation
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
            recoveryKind: "cloudCheckpoint",
            jobID: oldJobID,
            sourcePath: sourcePath,
            sourceSlice: nil,
            backendType: .googleAIStudio,
            failureStage: TranscriptionStage.transcribing.rawValue,
            createdAt: Date(),
            technicalError: "HTTP 503",
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
'''
write(
    "Tests/RecordToTextCoreTests/CloudResumeCheckpointTests.swift",
    resume_tests,
)

print("Applied cloud checkpoint resume support")
