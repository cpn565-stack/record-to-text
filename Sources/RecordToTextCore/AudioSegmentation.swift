import Foundation

public struct PlannedAudioSegment: Codable, Equatable, Sendable {
    public let index: Int
    public let startSeconds: Double
    public let durationSeconds: Double

    public init(index: Int, startSeconds: Double, durationSeconds: Double) {
        self.index = index
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }

    public var endSeconds: Double {
        startSeconds + durationSeconds
    }

    public var audioFileName: String {
        String(format: "segment-%04d.wav", index)
    }

    public var transcriptFileName: String {
        String(format: "segment-%04d.txt", index)
    }

    public var requestFileName: String {
        String(format: "segment-%04d-request.json", index)
    }
}

public struct AudioSegmentationPlan: Codable, Equatable, Sendable {
    public let sourceDurationSeconds: Double
    public let maximumSegmentDurationSeconds: Double
    public let segments: [PlannedAudioSegment]

    public init(
        sourceDurationSeconds: Double,
        maximumSegmentDurationSeconds: Double,
        segments: [PlannedAudioSegment]
    ) {
        self.sourceDurationSeconds = sourceDurationSeconds
        self.maximumSegmentDurationSeconds = maximumSegmentDurationSeconds
        self.segments = segments
    }

    public var expectedSegmentCount: Int {
        segments.count
    }

    public var requiresSplitting: Bool {
        segments.count > 1
    }
}

public enum AudioSegmentStatus: String, Codable, Equatable, Sendable {
    case planned
    case prepared
    case transcribing
    case completed
    case completedWithGaps
    case failed
}

public struct AudioSegmentRecord: Codable, Equatable, Sendable {
    public let segmentIndex: Int
    public let segmentCount: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let audioPath: String
    public let outputPath: String
    public var status: AudioSegmentStatus
    public var completedEventCount: Int
    public var failureMessage: String?

    public init(
        segmentIndex: Int,
        segmentCount: Int,
        startSeconds: Double,
        endSeconds: Double,
        audioPath: String,
        outputPath: String,
        status: AudioSegmentStatus = .planned,
        completedEventCount: Int = 0,
        failureMessage: String? = nil
    ) {
        self.segmentIndex = segmentIndex
        self.segmentCount = segmentCount
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.audioPath = audioPath
        self.outputPath = outputPath
        self.status = status
        self.completedEventCount = completedEventCount
        self.failureMessage = failureMessage
    }
}

public struct AudioSegmentManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let jobID: UUID
    public let sourceDurationSeconds: Double
    public let maximumSegmentDurationSeconds: Double
    public let expectedSegmentCount: Int
    public var segments: [AudioSegmentRecord]

    public init(
        schemaVersion: Int = 1,
        jobID: UUID,
        sourceDurationSeconds: Double,
        maximumSegmentDurationSeconds: Double,
        expectedSegmentCount: Int,
        segments: [AudioSegmentRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.sourceDurationSeconds = sourceDurationSeconds
        self.maximumSegmentDurationSeconds = maximumSegmentDurationSeconds
        self.expectedSegmentCount = expectedSegmentCount
        self.segments = segments
    }

    public mutating func mark(
        segmentIndex: Int,
        status: AudioSegmentStatus,
        completedEventCount: Int? = nil,
        failureMessage: String? = nil
    ) throws {
        guard let index = segments.firstIndex(where: {
            $0.segmentIndex == segmentIndex
        }) else {
            throw AudioSegmentationError.segmentMissing(segmentIndex)
        }
        segments[index].status = status
        if let completedEventCount {
            segments[index].completedEventCount = completedEventCount
        }
        segments[index].failureMessage = failureMessage
    }

    public func validatedCompletedSegments() throws -> [AudioSegmentRecord] {
        guard expectedSegmentCount > 0, segments.count == expectedSegmentCount else {
            throw AudioSegmentationError.segmentCountMismatch(
                expected: expectedSegmentCount,
                actual: segments.count
            )
        }
        let actualIndices = segments.map(\.segmentIndex)
        let expectedIndices = Array(1...expectedSegmentCount)
        guard actualIndices == expectedIndices else {
            throw AudioSegmentationError.invalidSegmentIndices(
                expected: expectedIndices,
                actual: actualIndices
            )
        }
        for segment in segments {
            guard
                (segment.status == .completed
                    || segment.status == .completedWithGaps),
                segment.completedEventCount == 1
            else {
                throw AudioSegmentationError.segmentIncomplete(
                    index: segment.segmentIndex,
                    status: segment.status,
                    completedEventCount: segment.completedEventCount
                )
            }
        }
        return segments
    }
}

public enum AudioSegmentationError: LocalizedError {
    case invalidSourceDuration(Double)
    case invalidMaximumDuration(Double)
    case segmentMissing(Int)
    case segmentCountMismatch(expected: Int, actual: Int)
    case invalidSegmentIndices(expected: [Int], actual: [Int])
    case segmentIncomplete(
        index: Int,
        status: AudioSegmentStatus,
        completedEventCount: Int
    )
    case segmentOutputTooLong(index: Int, duration: Double, maximum: Double)
    case segmentTranscriptMissing(Int)
    case segmentTranscriptionFailed(index: Int, count: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSourceDuration(duration):
            return "音檔時長無效，無法建立切分計畫：\(duration)"
        case let .invalidMaximumDuration(duration):
            return "音訊片段上限無效：\(duration)"
        case let .segmentMissing(index):
            return "找不到第 \(index) 段的分段紀錄。"
        case let .segmentCountMismatch(expected, actual):
            return "音訊片段數量不完整。預期 \(expected) 段，實際 \(actual) 段。"
        case let .invalidSegmentIndices(expected, actual):
            return "音訊片段編號缺漏、重複或錯序。預期 \(expected)，實際 \(actual)。"
        case let .segmentIncomplete(index, status, completedEventCount):
            return "第 \(index) 段未完整完成。狀態：\(status.rawValue)，完成事件：\(completedEventCount)。"
        case let .segmentOutputTooLong(index, duration, maximum):
            return "第 \(index) 段長度 \(duration) 秒，超過 \(maximum) 秒上限。"
        case let .segmentTranscriptMissing(index):
            return "第 \(index) 段的逐字稿缺漏，無法合併正式輸出。"
        case let .segmentTranscriptionFailed(index, count, reason):
            return "第 \(index)／\(count) 段轉錄失敗：\(reason)"
        }
    }
}

public enum AudioSegmentPlanner {
    /// Coordinator pre-split length: 20 minutes (1200 seconds).
    /// Shorter than the original 30-minute cap to reduce per-segment token pressure.
    public static let productionMaximumDuration: TimeInterval = 1_200

    public static func makePlan(
        sourceDuration: TimeInterval,
        maximumSegmentDuration: TimeInterval = productionMaximumDuration
    ) throws -> AudioSegmentationPlan {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            throw AudioSegmentationError.invalidSourceDuration(sourceDuration)
        }
        guard maximumSegmentDuration.isFinite, maximumSegmentDuration > 0 else {
            throw AudioSegmentationError.invalidMaximumDuration(
                maximumSegmentDuration
            )
        }

        let rawCount = ceil(sourceDuration / maximumSegmentDuration)
        guard rawCount.isFinite, rawCount <= Double(Int.max) else {
            throw AudioSegmentationError.invalidSourceDuration(sourceDuration)
        }
        let count = max(Int(rawCount), 1)
        let segments = (0..<count).map { zeroBasedIndex in
            let start = Double(zeroBasedIndex) * maximumSegmentDuration
            return PlannedAudioSegment(
                index: zeroBasedIndex + 1,
                startSeconds: start,
                durationSeconds: min(
                    maximumSegmentDuration,
                    sourceDuration - start
                )
            )
        }
        return AudioSegmentationPlan(
            sourceDurationSeconds: sourceDuration,
            maximumSegmentDurationSeconds: maximumSegmentDuration,
            segments: segments
        )
    }
}
