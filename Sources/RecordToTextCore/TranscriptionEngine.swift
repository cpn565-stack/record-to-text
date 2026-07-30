import Foundation

public struct PipelineExecutionError: LocalizedError {
    public let stage: TranscriptionStage
    public let underlying: Error
    public let recoveryDirectory: URL?

    public init(
        stage: TranscriptionStage,
        underlying: Error,
        recoveryDirectory: URL?
    ) {
        self.stage = stage
        self.underlying = underlying
        self.recoveryDirectory = recoveryDirectory
    }

    public var errorDescription: String? {
        underlying.localizedDescription
    }
}

private final class PipelineStageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: TranscriptionStage

    init(_ stage: TranscriptionStage) {
        self.stage = stage
    }

    func set(_ stage: TranscriptionStage) {
        lock.withLock {
            self.stage = stage
        }
    }

    func current() -> TranscriptionStage {
        lock.withLock { stage }
    }
}

public final class SleepPreventionService {
    private var activity: NSObjectProtocol?
    private let lock = NSLock()

    public init() {}

    public func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard activity == nil else {
            return
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "record-to-text 正在進行本機語音轉錄"
        )
    }

    public func end() {
        lock.lock()
        let existing = activity
        activity = nil
        lock.unlock()

        if let existing {
            ProcessInfo.processInfo.endActivity(existing)
        }
    }

    deinit {
        end()
    }
}

public final class TranscriptionEngine {
    private static let helperLivenessTimeout: TimeInterval = 30
    private static let helperLivenessPollNanoseconds: UInt64 = 5_000_000_000

    private let runtime: ResolvedRuntime
    private let paths: ApplicationPaths
    private let runner: ProcessRunner
    private let probeService: AudioProbeService
    private let ffmpegService: FFmpegService
    private let openCCService: OpenCCService
    private let backend: HelperASRBackend
    private let sleepPrevention: SleepPreventionService
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    public init(
        runtime: ResolvedRuntime,
        paths: ApplicationPaths,
        runner: ProcessRunner = ProcessRunner(),
        sleepPrevention: SleepPreventionService = SleepPreventionService()
    ) {
        self.runtime = runtime
        self.paths = paths
        self.runner = runner
        self.probeService = AudioProbeService(executableURL: runtime.ffprobe)
        self.ffmpegService = FFmpegService(executableURL: runtime.ffmpeg, runner: runner)
        self.openCCService = OpenCCService(executableURL: runtime.opencc, runner: runner)
        self.backend = HelperASRBackend(runtime: runtime, paths: paths, runner: runner)
        self.sleepPrevention = sleepPrevention
    }

    public func run(
        job: TranscriptionJob,
        offline: Bool = false,
        allowMissingPrompt: Bool = false,
        update: @escaping (PipelineUpdate) -> Void
    ) async throws -> PipelineResult {
        cancellationLock.withLock {
            cancellationRequested = false
        }
        let startedAt = Date()
        let sourceURL = job.sourceURL.standardizedFileURL
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text", isDirectory: true)
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
        let recoveryDirectory = paths.tempRecovery
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
        let normalizedAudioURL = workingDirectory.appendingPathComponent("normalized.wav")
        let rawTranscriptURL = workingDirectory.appendingPathComponent("raw.txt")
        let convertedTranscriptURL = workingDirectory.appendingPathComponent("traditional.txt")
        let requestURL = workingDirectory.appendingPathComponent("request.json")
        let currentStage = PipelineStageTracker(.validating)
        let fileManager = FileManager.default
        var cleanupWarningWasEmitted = false

        sleepPrevention.begin()
        defer { sleepPrevention.end() }
        defer {
            if fileManager.fileExists(atPath: workingDirectory.path) {
                do {
                    try fileManager.removeItem(at: workingDirectory)
                } catch {
                    if !cleanupWarningWasEmitted {
                        update(
                            .warning(
                                code: "temporary_cleanup_failed",
                                message: "無法清除工作暫存資料：\(workingDirectory.path)"
                            )
                        )
                    }
                }
            }
        }

        do {
            try Task.checkCancellation()
            try paths.createDirectories()
            try fileManager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: workingDirectory.path
            )

            update(.stage(.validating))
            let metadata = try await probeService.probe(sourceURL)
            try probeService.validateDiskSpace(
                for: metadata,
                temporaryDirectory: workingDirectory
            )

            let outputDirectory = try resolvedOutputDirectory(
                for: sourceURL,
                snapshot: job.snapshot
            )
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            try Task.checkCancellation()
            currentStage.set(.convertingAudio)
            update(.stage(.convertingAudio))
            try await ffmpegService.normalize(
                sourceURL: sourceURL,
                destinationURL: normalizedAudioURL,
                duration: metadata.duration
            ) { current, total in
                update(.progress(current: current, total: total, unit: "seconds"))
            }

            try Task.checkCancellation()
            currentStage.set(.loadingModel)
            update(.stage(.loadingModel))
            let request = ASRRequest(
                jobID: job.id.uuidString,
                audioPath: normalizedAudioURL.path,
                outputPath: rawTranscriptURL.path,
                modelID: job.snapshot.modelID,
                modelRevision: job.snapshot.modelRevision,
                language: job.snapshot.language,
                prompt: job.snapshot.prompt,
                terms: job.snapshot.terms,
                modelCacheDirectory: paths.models.path,
                offline: offline,
                allowMissingPrompt: allowMissingPrompt
            )

            let livenessMonitor = HelperLivenessMonitor()
            let livenessTask = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(
                            nanoseconds: Self.helperLivenessPollNanoseconds
                        )
                    } catch {
                        return
                    }
                    if livenessMonitor.consumeWarningIfInactive(
                        timeout: Self.helperLivenessTimeout
                    ) {
                        update(
                            .warning(
                                code: "helper_unresponsive",
                                message: "ASR 已超過 30 秒沒有回報活動；工作仍在執行，可繼續等待或取消。"
                            )
                        )
                    }
                }
            }
            do {
                _ = try await backend.transcribe(
                    request: request,
                    requestURL: requestURL
                ) { event in
                    livenessMonitor.recordActivity()
                    if event.type == "stage",
                       let value = event.value,
                       let stage = self.helperStage(value) {
                        currentStage.set(stage)
                    }
                    self.forward(event: event, update: update)
                }
            } catch {
                livenessTask.cancel()
                throw error
            }
            livenessTask.cancel()

            try Task.checkCancellation()
            currentStage.set(.convertingTraditionalChinese)
            update(.stage(.convertingTraditionalChinese))
            try await openCCService.convert(
                sourceURL: rawTranscriptURL,
                destinationURL: convertedTranscriptURL
            )

            try Task.checkCancellation()
            currentStage.set(.writingOutput)
            update(.stage(.writingOutput))
            let convertedText = try TextFileValidator.readNonEmptyUTF8(
                at: convertedTranscriptURL
            )
            let finalOutputURL = try writeUniqueText(
                convertedText,
                sourceURL: sourceURL,
                directory: outputDirectory,
                suffix: "_繁體"
            )

            var preservedRawURL: URL?
            if job.snapshot.keepRawTranscript {
                do {
                    let rawText = try TextFileValidator.readNonEmptyUTF8(
                        at: rawTranscriptURL
                    )
                    preservedRawURL = try writeUniqueText(
                        rawText,
                        sourceURL: sourceURL,
                        directory: outputDirectory,
                        suffix: "_Qwen原始"
                    )
                } catch {
                    update(
                        .warning(
                            code: "raw_transcript_write_failed",
                            message: "正式繁體逐字稿已完成，但無法另外保留 Qwen 原始稿：\(error.localizedDescription)"
                        )
                    )
                }
            }

            do {
                try fileManager.removeItem(at: workingDirectory)
            } catch {
                cleanupWarningWasEmitted = true
                update(
                    .warning(
                        code: "temporary_cleanup_failed",
                        message: "逐字稿已完成，但無法清除工作暫存資料：\(workingDirectory.path)"
                    )
                )
            }
            update(.stage(.completed))

            return PipelineResult(
                outputURL: finalOutputURL,
                rawOutputURL: preservedRawURL,
                duration: Date().timeIntervalSince(startedAt)
            )
        } catch is CancellationError {
            runner.cancelCurrent()
            throw CancellationError()
        } catch {
            if Task.isCancelled || cancellationLock.withLock({ cancellationRequested }) {
                runner.cancelCurrent()
                throw CancellationError()
            }
            var preservedRecovery: URL?
            if fileManager.fileExists(atPath: normalizedAudioURL.path) {
                do {
                    preservedRecovery = try preserveRecoveryData(
                        job: job,
                        stage: currentStage.current(),
                        error: error,
                        normalizedAudioURL: normalizedAudioURL,
                        recoveryDirectory: recoveryDirectory
                    )
                } catch {
                    if fileManager.fileExists(atPath: recoveryDirectory.path) {
                        preservedRecovery = recoveryDirectory
                    }
                    update(
                        .warning(
                            code: "recovery_incomplete",
                            message: "無法完整建立失敗復原資料；工作暫存會立即清除。"
                        )
                    )
                }
            }
            throw PipelineExecutionError(
                stage: currentStage.current(),
                underlying: error,
                recoveryDirectory: preservedRecovery
            )
        }
    }

    public func cancelCurrentJob() {
        cancellationLock.withLock {
            cancellationRequested = true
        }
        runner.cancelCurrent()
    }

    private func resolvedOutputDirectory(
        for sourceURL: URL,
        snapshot: JobSnapshot
    ) throws -> URL {
        switch snapshot.outputLocationMode {
        case .sameAsSource:
            return sourceURL.deletingLastPathComponent()
        case .fixedDirectory, .askEveryTime:
            guard !snapshot.outputDirectory.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            return URL(fileURLWithPath: snapshot.outputDirectory, isDirectory: true)
        }
    }

    private func writeUniqueText(
        _ text: String,
        sourceURL: URL,
        directory: URL,
        suffix: String
    ) throws -> URL {
        while true {
            let candidate = OutputNameBuilder.availableOutputURL(
                sourceURL: sourceURL,
                directory: directory,
                suffix: suffix
            )
            do {
                try AtomicFileWriter.writeTextNew(text, to: candidate)
                return candidate
            } catch AtomicFileWriterError.destinationExists {
                continue
            }
        }
    }

    private func forward(
        event: HelperEvent,
        update: @escaping (PipelineUpdate) -> Void
    ) {
        switch event.type {
        case "stage":
            if let value = event.value, let stage = helperStage(value) {
                update(.stage(stage))
            }
        case "progress":
            if
                let current = event.current,
                let total = event.total,
                let unit = event.unit
            {
                update(.progress(current: current, total: total, unit: unit))
            }
        case "log":
            update(
                .log(
                    level: event.level ?? "info",
                    message: event.message ?? ""
                )
            )
        case "warning":
            update(
                .warning(
                    code: event.code ?? "helper_warning",
                    message: event.message ?? "Helper 回報警告。"
                )
            )
        case "heartbeat":
            update(.log(level: "heartbeat", message: event.message ?? "ASR 執行中"))
        default:
            break
        }
    }

    private func helperStage(_ value: String) -> TranscriptionStage? {
        switch value {
        case "validating":
            return .validating
        case "preparing_runtime":
            return .preparingRuntime
        case "downloading_model":
            return .downloadingModel
        case "loading_model":
            return .loadingModel
        case "transcribing":
            return .transcribing
        default:
            return nil
        }
    }

    private func preserveRecoveryData(
        job: TranscriptionJob,
        stage: TranscriptionStage,
        error: Error,
        normalizedAudioURL: URL,
        recoveryDirectory: URL
    ) throws -> URL {
        struct RecoveryMetadata: Codable {
            let schemaVersion: Int
            let jobID: UUID
            let sourcePath: String
            let failureStage: String
            let createdAt: Date
            let technicalError: String
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: recoveryDirectory.path
        )

        let recoveredWAV = recoveryDirectory.appendingPathComponent("normalized.wav")
        if fileManager.fileExists(atPath: recoveredWAV.path) {
            try fileManager.removeItem(at: recoveredWAV)
        }
        try fileManager.moveItem(at: normalizedAudioURL, to: recoveredWAV)

        let metadata = RecoveryMetadata(
            schemaVersion: 1,
            jobID: job.id,
            sourcePath: job.sourcePath,
            failureStage: stage.rawValue,
            createdAt: Date(),
            technicalError: error.localizedDescription
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(
            try encoder.encode(metadata),
            to: recoveryDirectory.appendingPathComponent("recovery.json")
        )

        return recoveryDirectory
    }
}
