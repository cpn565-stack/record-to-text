import Foundation

public struct InvalidStageTransitionError: LocalizedError, Equatable {
    public let from: TranscriptionStage
    public let to: TranscriptionStage

    public init(from: TranscriptionStage, to: TranscriptionStage) {
        self.from = from
        self.to = to
    }

    public var errorDescription: String? {
        "工作狀態不能從「\(from.displayName)」直接變成「\(to.displayName)」。"
    }
}

public enum JobStateMachine {
    private static let allowedTransitions: [TranscriptionStage: Set<TranscriptionStage>] = [
        .queued: [.validating, .cancelled, .interrupted],
        .validating: [.preparingRuntime, .convertingAudio, .failed, .cancelled],
        .preparingRuntime: [.downloadingModel, .convertingAudio, .failed, .cancelled],
        .downloadingModel: [.convertingAudio, .loadingModel, .failed, .cancelled],
        .convertingAudio: [.loadingModel, .failed, .cancelled],
        .loadingModel: [.transcribing, .failed, .cancelled],
        .transcribing: [.convertingTraditionalChinese, .failed, .cancelled],
        .convertingTraditionalChinese: [.writingOutput, .failed, .cancelled],
        .writingOutput: [.completed, .failed, .cancelled],
        .completed: [],
        .failed: [.queued],
        .cancelled: [.queued],
        .interrupted: [.queued, .cancelled]
    ]

    public static func canTransition(
        from: TranscriptionStage,
        to: TranscriptionStage
    ) -> Bool {
        allowedTransitions[from]?.contains(to) == true
    }

    public static func transition(
        _ job: inout TranscriptionJob,
        to next: TranscriptionStage,
        at date: Date = Date()
    ) throws {
        guard canTransition(from: job.stage, to: next) else {
            throw InvalidStageTransitionError(from: job.stage, to: next)
        }

        job.stage = next
        if next == .validating, job.startedAt == nil {
            job.startedAt = date
        }
        if next.isTerminal {
            job.completedAt = date
        }
    }
}
