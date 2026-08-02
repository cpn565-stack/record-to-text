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
    private let maximumASRSegmentDuration: TimeInterval
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    public init(
        runtime: ResolvedRuntime,
        paths: ApplicationPaths,
        runner: ProcessRunner = ProcessRunner(),
        sleepPrevention: SleepPreventionService = SleepPreventionService(),
        maximumASRSegmentDuration: TimeInterval =
            AudioSegmentPlanner.productionMaximumDuration
    ) {
        self.runtime = runtime
        self.paths = paths
        self.runner = runner
        self.probeService = AudioProbeService(executableURL: runtime.ffprobe)
        self.ffmpegService = FFmpegService(executableURL: runtime.ffmpeg, runner: runner)
        self.openCCService = OpenCCService(executableURL: runtime.opencc, runner: runner)
        self.backend = HelperASRBackend(runtime: runtime, paths: paths, runner: runner)
        self.sleepPrevention = sleepPrevention
        self.maximumASRSegmentDuration = maximumASRSegmentDuration
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
        let segmentsDirectory = workingDirectory.appendingPathComponent(
            "segments",
            isDirectory: true
        )
        let segmentManifestURL = workingDirectory.appendingPathComponent(
            "segment-manifest.json"
        )
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
            let segmentPlan = try AudioSegmentPlanner.makePlan(
                sourceDuration: metadata.duration,
                maximumSegmentDuration: maximumASRSegmentDuration
            )
            update(
                .log(
                    level: "info",
                    message: String(
                        format: "分段計畫：來源 %.1f 分鐘，每段最長 %.0f 分鐘（%.0f 秒），共 %d 段。",
                        metadata.duration / 60.0,
                        maximumASRSegmentDuration / 60.0,
                        maximumASRSegmentDuration,
                        segmentPlan.expectedSegmentCount
                    )
                )
            )
            let outputDirectory = try resolvedOutputDirectory(
                for: sourceURL,
                snapshot: job.snapshot
            )
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try probeService.validateDiskSpace(
                for: metadata,
                temporaryDirectory: workingDirectory,
                outputDirectory: outputDirectory,
                pcmWorkingCopies: segmentPlan.requiresSplitting ? 2 : 1
            )

            try Task.checkCancellation()
            currentStage.set(.convertingAudio)
            update(.stage(.convertingAudio))
            try await ffmpegService.normalize(
                sourceURL: sourceURL,
                destinationURL: normalizedAudioURL,
                duration: metadata.duration
            ) { current, total in
                // Audio conversion is a small prefix of overall work.
                let fraction = total > 0 ? min(max(current / total, 0), 1) : 0
                update(
                    .progress(
                        current: fraction * 5,
                        total: 100,
                        unit: "percent"
                    )
                )
            }

            if segmentPlan.requiresSplitting {
                try fileManager.createDirectory(
                    at: segmentsDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: segmentsDirectory.path
                )
            }

            var segmentManifest = AudioSegmentManifest(
                jobID: job.id,
                sourceDurationSeconds: segmentPlan.sourceDurationSeconds,
                maximumSegmentDurationSeconds:
                    segmentPlan.maximumSegmentDurationSeconds,
                expectedSegmentCount: segmentPlan.expectedSegmentCount,
                segments: segmentPlan.segments.map { segment in
                    let audioURL = segmentPlan.requiresSplitting
                        ? segmentsDirectory.appendingPathComponent(
                            segment.audioFileName
                        )
                        : normalizedAudioURL
                    let outputURL = segmentPlan.requiresSplitting
                        ? segmentsDirectory.appendingPathComponent(
                            segment.transcriptFileName
                        )
                        : rawTranscriptURL
                    return AudioSegmentRecord(
                        segmentIndex: segment.index,
                        segmentCount: segmentPlan.expectedSegmentCount,
                        startSeconds: segment.startSeconds,
                        endSeconds: segment.endSeconds,
                        audioPath: audioURL.path,
                        outputPath: outputURL.path
                    )
                }
            )
            try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

            if segmentPlan.requiresSplitting {
                update(
                    .log(
                        level: "info",
                        message: "音檔超過 20 分鐘，將切成 \(segmentPlan.expectedSegmentCount) 段後逐段轉錄。"
                    )
                )
                for segment in segmentPlan.segments {
                    try Task.checkCancellation()
                    let record = segmentManifest.segments[segment.index - 1]
                    do {
                        update(
                            overallProgress(
                                segmentIndex: segment.index,
                                segmentCount: segmentPlan.expectedSegmentCount,
                                withinSegment: 0,
                                requiresSplitting: true
                            )
                        )
                        update(
                            .log(
                                level: "info",
                                message: "正在準備第 \(segment.index)／\(segmentPlan.expectedSegmentCount) 段音訊。"
                            )
                        )
                        try await ffmpegService.extractSegment(
                            sourceURL: normalizedAudioURL,
                            destinationURL: URL(fileURLWithPath: record.audioPath),
                            startSeconds: segment.startSeconds,
                            durationSeconds: segment.durationSeconds
                        )
                        let preparedMetadata = try await probeService.probe(
                            URL(fileURLWithPath: record.audioPath)
                        )
                        if preparedMetadata.duration
                            > maximumASRSegmentDuration + 0.01 {
                            throw AudioSegmentationError.segmentOutputTooLong(
                                index: segment.index,
                                duration: preparedMetadata.duration,
                                maximum: maximumASRSegmentDuration
                            )
                        }
                        try segmentManifest.mark(
                            segmentIndex: segment.index,
                            status: .prepared
                        )
                        try writeSegmentManifest(
                            segmentManifest,
                            to: segmentManifestURL
                        )
                    } catch {
                        try? segmentManifest.mark(
                            segmentIndex: segment.index,
                            status: .failed,
                            failureMessage: error.localizedDescription
                        )
                        try? writeSegmentManifest(
                            segmentManifest,
                            to: segmentManifestURL
                        )
                        throw error
                    }
                }
            } else {
                try segmentManifest.mark(segmentIndex: 1, status: .prepared)
                try writeSegmentManifest(segmentManifest, to: segmentManifestURL)
            }

            var segmentTexts: [Int: String] = [:]
            for segment in segmentPlan.segments {
                try Task.checkCancellation()
                let record = segmentManifest.segments[segment.index - 1]
                let perSegmentRequestURL = segmentPlan.requiresSplitting
                    ? segmentsDirectory.appendingPathComponent(
                        segment.requestFileName
                    )
                    : requestURL
                let withinSegmentProgress = SegmentProgressBox()

                if segment.index == 1 {
                    currentStage.set(.loadingModel)
                    update(.stage(.loadingModel))
                }
                if segmentPlan.requiresSplitting {
                    update(
                        .log(
                            level: "info",
                            message: "正在轉錄第 \(segment.index)／\(segmentPlan.expectedSegmentCount) 段。"
                        )
                    )
                }
                // Start of segment N = completed N-1 segments (not N/N full bar).
                update(
                    overallProgress(
                        segmentIndex: segment.index,
                        segmentCount: segmentPlan.expectedSegmentCount,
                        withinSegment: 0,
                        requiresSplitting: segmentPlan.requiresSplitting
                    )
                )
                try segmentManifest.mark(
                    segmentIndex: segment.index,
                    status: .transcribing
                )
                try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

                let request = ASRRequest(
                    jobID: String(
                        format: "%@-segment-%04d-of-%04d",
                        job.id.uuidString,
                        segment.index,
                        segmentPlan.expectedSegmentCount
                    ),
                    audioPath: record.audioPath,
                    outputPath: record.outputPath,
                    modelID: job.snapshot.modelID,
                    modelRevision: job.snapshot.modelRevision,
                    language: job.snapshot.language,
                    prompt: job.snapshot.prompt,
                    terms: job.snapshot.terms,
                    modelCacheDirectory: paths.models.path,
                    offline: offline,
                    allowMissingPrompt: allowMissingPrompt,
                    segmentIndex: segment.index,
                    segmentCount: segmentPlan.expectedSegmentCount
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
                            let segmentPrefix = segmentPlan.requiresSplitting
                                ? "第 \(segment.index)／\(segmentPlan.expectedSegmentCount) 段 "
                                : ""
                            update(
                                .warning(
                                    code: "helper_unresponsive",
                                    message: "\(segmentPrefix)ASR 已超過 30 秒沒有回報活動；工作仍在執行，可繼續等待或取消。"
                                )
                            )
                        }
                    }
                }
                do {
                    let transcriptionResult = try await backend.transcribe(
                        request: request,
                        requestURL: perSegmentRequestURL
                    ) { event in
                        livenessMonitor.recordActivity()
                        var shouldForward = true
                        if event.type == "stage",
                           let value = event.value,
                           let stage = self.helperStage(value) {
                            if
                                segmentPlan.requiresSplitting,
                                segment.index > 1,
                                stage == .loadingModel
                            {
                                shouldForward = false
                            } else {
                                currentStage.set(stage)
                            }
                        }
                        if event.type == "progress",
                           let current = event.current,
                           let total = event.total,
                           total > 0
                        {
                            withinSegmentProgress.value = min(
                                max(current / total, 0),
                                1
                            )
                            update(
                                self.overallProgress(
                                    segmentIndex: segment.index,
                                    segmentCount: segmentPlan.expectedSegmentCount,
                                    withinSegment: withinSegmentProgress.value,
                                    requiresSplitting: segmentPlan.requiresSplitting
                                )
                            )
                            shouldForward = false
                        } else if
                            segmentPlan.requiresSplitting,
                            event.type == "stage" || event.type == "heartbeat"
                        {
                            // Keep the bar at the current segment floor while
                            // waiting for finer helper progress events.
                            update(
                                self.overallProgress(
                                    segmentIndex: segment.index,
                                    segmentCount: segmentPlan.expectedSegmentCount,
                                    withinSegment: withinSegmentProgress.value,
                                    requiresSplitting: true
                                )
                            )
                        }
                        if shouldForward {
                            self.forward(
                                event: event,
                                suppressProgress: true,
                                update: update
                            )
                        }
                    }
                    livenessTask.cancel()

                    let segmentText = try OutputContractValidator.readTranscript(
                        at: URL(fileURLWithPath: record.outputPath),
                        prompt: job.snapshot.prompt
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    segmentTexts[segment.index] = segmentText
                    try segmentManifest.mark(
                        segmentIndex: segment.index,
                        status: transcriptionResult.containsSkippedAudio
                            ? .completedWithGaps
                            : .completed,
                        completedEventCount: 1
                    )
                    try writeSegmentManifest(
                        segmentManifest,
                        to: segmentManifestURL
                    )
                    update(
                        overallProgress(
                            segmentIndex: segment.index,
                            segmentCount: segmentPlan.expectedSegmentCount,
                            withinSegment: 1,
                            requiresSplitting: segmentPlan.requiresSplitting
                        )
                    )
                } catch {
                    livenessTask.cancel()
                    try? segmentManifest.mark(
                        segmentIndex: segment.index,
                        status: .failed,
                        failureMessage: error.localizedDescription
                    )
                    try? writeSegmentManifest(
                        segmentManifest,
                        to: segmentManifestURL
                    )
                    if
                        let backendError = error as? ASRBackendError,
                        case .glossaryPromptUnsupported = backendError
                    {
                        throw backendError
                    }
                    throw AudioSegmentationError.segmentTranscriptionFailed(
                        index: segment.index,
                        count: segmentPlan.expectedSegmentCount,
                        reason: error.localizedDescription
                    )
                }
            }

            let completedSegments = try segmentManifest
                .validatedCompletedSegments()
            let mergedRawText = try completedSegments.map { segment in
                guard let text = segmentTexts[segment.segmentIndex] else {
                    throw AudioSegmentationError.segmentTranscriptMissing(
                        segment.segmentIndex
                    )
                }
                return text
            }.joined(separator: "\n")
            let validatedMergedRawText = try OutputContractValidator.validate(
                text: mergedRawText,
                path: rawTranscriptURL.path,
                prompt: job.snapshot.prompt
            )
            try AtomicFileWriter.writeText(
                validatedMergedRawText,
                to: rawTranscriptURL
            )
            update(.progress(current: 95, total: 100, unit: "percent"))

            try Task.checkCancellation()
            currentStage.set(.convertingTraditionalChinese)
            update(.stage(.convertingTraditionalChinese))
            try await openCCService.convert(
                sourceURL: rawTranscriptURL,
                destinationURL: convertedTranscriptURL
            )
            update(.progress(current: 98, total: 100, unit: "percent"))

            try Task.checkCancellation()
            currentStage.set(.writingOutput)
            update(.stage(.writingOutput))
            let convertedText = try OutputContractValidator.readTranscript(
                at: convertedTranscriptURL
            )
            let finalOutputURL = try writeUniqueText(
                convertedText,
                sourceURL: sourceURL,
                directory: outputDirectory,
                suffix: job.snapshot.outputFilenameSuffix
            )
            update(.progress(current: 100, total: 100, unit: "percent"))

            var preservedRawURL: URL?
            if job.snapshot.keepRawTranscript {
                do {
                    let rawText = try OutputContractValidator.readTranscript(
                        at: rawTranscriptURL
                    )
                    preservedRawURL = try writeUniqueText(
                        rawText,
                        sourceURL: sourceURL,
                        directory: outputDirectory,
                        suffix: job.snapshot.rawFilenameSuffix
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
                duration: Date().timeIntervalSince(startedAt),
                containsSkippedAudio: segmentManifest.segments.contains {
                    $0.status == .completedWithGaps
                }
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
                        segmentManifestURL: segmentManifestURL,
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
        backend.cancelCurrentJob()
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
        suppressProgress: Bool = false,
        update: @escaping (PipelineUpdate) -> Void
    ) {
        switch event.type {
        case "stage":
            if let value = event.value, let stage = helperStage(value) {
                update(.stage(stage))
            }
        case "progress":
            if
                !suppressProgress,
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

    /// Maps segment-local progress into a continuous 0…100% job bar.
    ///
    /// Budget: 0–5% conversion, 5–95% ASR (split evenly across segments),
    /// 95–100% traditional conversion and write. Starting segment N uses
    /// completed (N-1) segments so the bar is never full at the start of
    /// the final segment.
    private func overallProgress(
        segmentIndex: Int,
        segmentCount: Int,
        withinSegment: Double,
        requiresSplitting: Bool
    ) -> PipelineUpdate {
        let count = max(segmentCount, 1)
        let within = min(max(withinSegment, 0), 1)
        let asrStart = 5.0
        let asrSpan = 90.0
        let segmentSpan = asrSpan / Double(count)
        let completedSegments = Double(max(segmentIndex - 1, 0))
        let current = asrStart + (completedSegments + within) * segmentSpan
        let unit: String
        if requiresSplitting {
            unit = "percent|\(segmentIndex)|\(count)"
        } else {
            unit = "percent"
        }
        return .progress(
            current: min(max(current, 0), 95),
            total: 100,
            unit: unit
        )
    }
}

/// Thread-safe holder for in-segment progress while helper events arrive.
private final class SegmentProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0.0

    var value: Double {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

extension TranscriptionEngine {
    private func writeSegmentManifest(
        _ manifest: AudioSegmentManifest,
        to destinationURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFileWriter.write(
            try encoder.encode(manifest),
            to: destinationURL
        )
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
        segmentManifestURL: URL,
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

        if fileManager.fileExists(atPath: segmentManifestURL.path) {
            let recoveredManifest = recoveryDirectory.appendingPathComponent(
                "segment-manifest.json"
            )
            if fileManager.fileExists(atPath: recoveredManifest.path) {
                try fileManager.removeItem(at: recoveredManifest)
            }
            try fileManager.copyItem(
                at: segmentManifestURL,
                to: recoveredManifest
            )
        }

        try writePartialTranscript(
            from: segmentManifestURL,
            error: error,
            to: recoveryDirectory
        )

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

    private func writePartialTranscript(
        from manifestURL: URL,
        error: Error,
        to recoveryDirectory: URL
    ) throws {
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(
                AudioSegmentManifest.self,
                from: data
            )
        else {
            return
        }

        var sections: [String] = []
        let fileManager = FileManager.default
        for segment in manifest.segments.sorted(by: {
            $0.segmentIndex < $1.segmentIndex
        }) {
            let outputURL = URL(fileURLWithPath: segment.outputPath)
            let partialURL = URL(
                fileURLWithPath: segment.outputPath + ".partial.txt"
            )
            let outputText = fileManager.fileExists(atPath: outputURL.path)
                ? try? TextFileValidator.readNonEmptyUTF8(at: outputURL)
                : nil
            let partialText = fileManager.fileExists(atPath: partialURL.path)
                ? try? TextFileValidator.readNonEmptyUTF8(at: partialURL)
                : nil
            let text = outputText ?? partialText
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let label: String
            switch segment.status {
            case .completed:
                label = "已完成"
            case .completedWithGaps:
                label = "完成但有缺口"
            default:
                label = "未完成草稿"
            }
            sections.append(
                "【第 \(segment.segmentIndex) 段｜\(label)】\n\(text)"
            )
        }

        guard !sections.isEmpty else {
            return
        }

        let header = """
        【未完成逐字稿｜可能缺漏】
        失敗原因：\(error.localizedDescription)
        此檔僅供救援與人工整理，不代表完整正式逐字稿。

        """
        try AtomicFileWriter.writeText(
            header + sections.joined(separator: "\n\n"),
            to: recoveryDirectory.appendingPathComponent("partial-transcript.txt")
        )
    }
}
