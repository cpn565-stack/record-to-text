import Foundation

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
    public let splitDepths: [Int: Int]
    public let speakerRoster: SpeakerRoster?

    public init(
        recoveryDirectory: URL,
        plan: AudioSegmentationPlan,
        reusableSegments: [Int: ReusableCloudSegment],
        splitDepths: [Int: Int] = [:],
        speakerRoster: SpeakerRoster? = nil
    ) {
        self.recoveryDirectory = recoveryDirectory
        self.plan = plan
        self.reusableSegments = reusableSegments
        self.splitDepths = splitDepths
        self.speakerRoster = speakerRoster
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
        var splitDepths: [Int: Int] = [:]
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
            splitDepths[record.segmentIndex] = max(record.splitDepth ?? 0, 0)
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
            reusableSegments: reusable,
            splitDepths: splitDepths,
            speakerRoster: manifest.speakerRoster
        )
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
