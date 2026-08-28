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
    private let silenceDetectionService: SilenceDetectionService
    private let openCCService: OpenCCService
    private let backend: HelperASRBackend
    private let googleAIStudioBackend: GoogleAIStudioBackend
    private let vertexAIBackend: VertexAIGeminiBackend
    private let sleepPrevention: SleepPreventionService
    private let maximumASRSegmentDuration: TimeInterval
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    static func resolvedVertexLocation(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "global" : trimmed
    }

    static func cloudSegmentStart(
        sourceSlice: TranscriptionSourceSlice?,
        plannedStart: Double
    ) -> Double {
        (sourceSlice?.startSeconds ?? 0) + plannedStart
    }

    /// 先合併所有分段逐字稿，再依設定最多產生一次摘要。
    /// 摘要屬於附加功能；任何摘要錯誤都不得使已完成的逐字稿失敗。
    static func finalizeVertexTranscript(
        segmentTexts: [String],
        includeSummary: Bool,
        summarize: (_ completeTranscript: String) async throws -> String,
        update: (PipelineUpdate) -> Void
    ) async -> String {
        let completeTranscript = segmentTexts.joined(separator: "\n\n")
        guard includeSummary else {
            return completeTranscript
        }

        do {
            let generated = try await summarize(completeTranscript)
            let validated = try OutputContractValidator.validate(
                text: generated,
                path: "Vertex AI 摘要"
            )
            var summaryBody = validated.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if summaryBody.hasPrefix("摘要：") {
                summaryBody.removeFirst(3)
            } else if summaryBody.hasPrefix("摘要:") {
                summaryBody.removeFirst(3)
            }
            summaryBody = summaryBody.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !summaryBody.isEmpty else {
                throw VertexAIError.emptyResponse
            }
            return "\(completeTranscript)\n\n摘要：\(summaryBody)"
        } catch {
            update(
                .warning(
                    code: "vertex_summary_failed",
                    message: "摘要產生失敗，已保留完整逐字稿：\(error.localizedDescription)"
                )
            )
            return completeTranscript
        }
    }

    public init(
        runtime: ResolvedRuntime,
        paths: ApplicationPaths,
        runner: ProcessRunner = ProcessRunner(),
        googleAIStudioBackend: GoogleAIStudioBackend? = nil,
        vertexAIBackend: VertexAIGeminiBackend? = nil,
        sleepPrevention: SleepPreventionService = SleepPreventionService(),
        maximumASRSegmentDuration: TimeInterval =
            AudioSegmentPlanner.productionMaximumDuration
    ) {
        self.runtime = runtime
        self.paths = paths
        self.runner = runner
        self.probeService = AudioProbeService(executableURL: runtime.ffprobe)
        self.ffmpegService = FFmpegService(executableURL: runtime.ffmpeg, runner: runner)
        self.silenceDetectionService = SilenceDetectionService(
            executableURL: runtime.ffmpeg,
            runner: runner
        )
        self.openCCService = OpenCCService(executableURL: runtime.opencc, runner: runner)
        self.backend = HelperASRBackend(runtime: runtime, paths: paths, runner: runner)
        self.googleAIStudioBackend = googleAIStudioBackend ?? GoogleAIStudioBackend()
        self.vertexAIBackend = vertexAIBackend ?? VertexAIGeminiBackend(authService: GCloudAuthService(runner: runner))
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
        let localRecoveryDirectory: URL = {
            guard job.snapshot.backendType == .localQwen,
                  let raw = job.resumeFromRecoveryDirectory
            else {
                return recoveryDirectory
            }
            let root = paths.tempRecovery.standardizedFileURL
                .resolvingSymlinksInPath()
            let candidate = URL(fileURLWithPath: raw, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard candidate.deletingLastPathComponent().path == root.path else {
                return recoveryDirectory
            }
            return candidate
        }()
        let localChunkCheckpointDirectory = LocalChunkCheckpoint.directory(
            in: localRecoveryDirectory
        )
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
        var shouldKeepWorkingDirectory = false

        sleepPrevention.begin()
        defer { sleepPrevention.end() }
        defer {
            if !shouldKeepWorkingDirectory,
               fileManager.fileExists(atPath: workingDirectory.path) {
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
            let sourceMetadata = try await probeService.probe(sourceURL)
            if let sourceSlice = job.sourceSlice {
                try sourceSlice.validate(sourceDuration: sourceMetadata.duration)
                update(
                    .log(
                        level: "info",
                        message: String(
                            format: "本工作處理來源第 %d／%d 段：%.1f–%.1f 分鐘。",
                            sourceSlice.partIndex,
                            sourceSlice.partCount,
                            sourceSlice.startSeconds / 60.0,
                            sourceSlice.endSeconds / 60.0
                        )
                    )
                )
            }
            let processingDuration = job.sourceSlice?.durationSeconds
                ?? sourceMetadata.duration
            let metadata = AudioMetadata(
                duration: processingDuration,
                codecName: sourceMetadata.codecName,
                sampleRate: sourceMetadata.sampleRate,
                channels: sourceMetadata.channels
            )
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

            if job.snapshot.backendType == .googleAIStudio {
                return try await runGoogleAIStudioPipeline(
                    job: job,
                    startedAt: startedAt,
                    sourceURL: sourceURL,
                    workingDirectory: workingDirectory,
                    outputDirectory: outputDirectory,
                    metadata: metadata,
                    currentStage: currentStage,
                    update: update
                )
            } else if job.snapshot.backendType == .vertexAI {
                return try await runVertexAIPipeline(
                    job: job,
                    startedAt: startedAt,
                    sourceURL: sourceURL,
                    workingDirectory: workingDirectory,
                    outputDirectory: outputDirectory,
                    metadata: metadata,
                    currentStage: currentStage,
                    update: update
                )
            }

            if job.resumeFromRecoveryDirectory != nil,
               localRecoveryDirectory != recoveryDirectory
            {
                update(
                    .log(
                        level: "info",
                        message: "本機 Qwen 將驗證既有內部 chunk checkpoints；相容的已完成音訊不會重新推論。"
                    )
                )
            }

            try probeService.validateDiskSpace(
                for: metadata,
                temporaryDirectory: workingDirectory,
                outputDirectory: outputDirectory,
                pcmWorkingCopies: segmentPlan.requiresSplitting ? 2 : 1
            )

            try Task.checkCancellation()
            currentStage.set(.convertingAudio)
            update(.stage(.convertingAudio))
            if let sourceSlice = job.sourceSlice {
                try await ffmpegService.extractSegment(
                    sourceURL: sourceURL,
                    destinationURL: normalizedAudioURL,
                    startSeconds: sourceSlice.startSeconds,
                    durationSeconds: sourceSlice.durationSeconds
                )
                update(.progress(current: 5, total: 100, unit: "percent"))
            } else {
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

            _ = try LocalChunkCheckpoint.createSecureDirectory(
                in: localRecoveryDirectory,
                fileManager: fileManager
            )

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
                    segmentCount: segmentPlan.expectedSegmentCount,
                    chunkCheckpointDirectory:
                        localChunkCheckpointDirectory.path
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
                suffix: outputSuffix(
                    job.snapshot.outputFilenameSuffix,
                    sourceSlice: job.sourceSlice
                )
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
                        suffix: outputSuffix(
                            job.snapshot.rawFilenameSuffix,
                            sourceSlice: job.sourceSlice
                        )
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
            if fileManager.fileExists(atPath: localRecoveryDirectory.path) {
                do {
                    try fileManager.removeItem(at: localRecoveryDirectory)
                } catch {
                    update(
                        .warning(
                            code: "chunk_checkpoint_cleanup_failed",
                            message: "逐字稿已完成，但無法清除內部 chunk checkpoint：\(localRecoveryDirectory.path)"
                        )
                    )
                }
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
        } catch {
            let wasCancelled = error is CancellationError
                || Task.isCancelled
                || cancellationLock.withLock({ cancellationRequested })
            if wasCancelled {
                runner.cancelCurrent()

                if job.snapshot.backendType == .localQwen,
                   fileManager.fileExists(atPath: localRecoveryDirectory.path),
                   !LocalChunkCheckpoint.containsUsableCheckpoint(
                       in: localRecoveryDirectory,
                       fileManager: fileManager
                   )
                {
                    // The directory is created before helper inference so its
                    // permissions are deterministic. Do not leave an empty
                    // recovery item when cancellation happened before the
                    // first chunk completed.
                    try? fileManager.removeItem(at: localRecoveryDirectory)
                }

                // A cancellation can arrive after one or more paid cloud
                // segments have completed. Preserve the same minimal text-only
                // checkpoint used for failures before the outer defer removes
                // the working directory. The job still reports cancellation;
                // RecoveryScanner exposes the partial transcript separately.
                if job.snapshot.backendType != .localQwen,
                   fileManager.fileExists(atPath: segmentManifestURL.path),
                   Self.cloudCheckpointContainsRecoverableText(
                       manifestURL: segmentManifestURL,
                       fileManager: fileManager
                   )
                {
                    do {
                        _ = try preserveCloudRecoveryData(
                            job: job,
                            stage: currentStage.current(),
                            error: CancellationError(),
                            segmentManifestURL: segmentManifestURL,
                            recoveryDirectory: recoveryDirectory
                        )
                    } catch {
                        shouldKeepWorkingDirectory = true
                        update(
                            .warning(
                                code: "cloud_recovery_incomplete",
                                message: "取消工作後無法完整保存雲端逐段檢查點；請立即檢查：\(workingDirectory.path)"
                            )
                        )
                    }
                }
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
                        recoveryDirectory: localRecoveryDirectory
                    )
                } catch {
                    shouldKeepWorkingDirectory = true
                    if fileManager.fileExists(atPath: localRecoveryDirectory.path) {
                        preservedRecovery = localRecoveryDirectory
                    }
                    update(
                        .warning(
                            code: "recovery_incomplete",
                            message: "無法完整建立失敗復原資料；原工作暫存已保留供人工檢查：\(workingDirectory.path)"
                        )
                    )
                }
            } else if job.snapshot.backendType != .localQwen,
                      fileManager.fileExists(atPath: segmentManifestURL.path) {
                do {
                    preservedRecovery = try preserveCloudRecoveryData(
                        job: job,
                        stage: currentStage.current(),
                        error: error,
                        segmentManifestURL: segmentManifestURL,
                        recoveryDirectory: recoveryDirectory
                    )
                } catch {
                    shouldKeepWorkingDirectory = true
                    if fileManager.fileExists(atPath: recoveryDirectory.path) {
                        preservedRecovery = recoveryDirectory
                    }
                    update(
                        .warning(
                            code: "cloud_recovery_incomplete",
                            message: "雲端逐段檢查點無法完整移至復原區；請立即檢查：\(workingDirectory.path)"
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

    private func outputSuffix(
        _ base: String,
        sourceSlice: TranscriptionSourceSlice?
    ) -> String {
        guard let sourceSlice else {
            return base
        }
        return "\(base)_第\(sourceSlice.partIndex)-\(sourceSlice.partCount)段"
    }

    private func runGoogleAIStudioPipeline(
        job: TranscriptionJob,
        startedAt: Date,
        sourceURL: URL,
        workingDirectory: URL,
        outputDirectory: URL,
        metadata: AudioMetadata,
        currentStage: PipelineStageTracker,
        update: @escaping (PipelineUpdate) -> Void
    ) async throws -> PipelineResult {
        googleAIStudioBackend.updateConfiguration(
            GoogleAIStudioBackend.Configuration(
                apiKey: job.snapshot.googleAIStudioAPIKey,
                modelID: job.snapshot.googleAIStudioModelID,
                thinkingLevel: job.snapshot.geminiThinkingLevel,
                fallbackPolicy: job.snapshot.cloudFallbackPolicy
            )
        )
        let modelDisplay = job.snapshot.googleAIStudioModelID
        return try await runCloudPipeline(
            job: job,
            startedAt: startedAt,
            sourceURL: sourceURL,
            workingDirectory: workingDirectory,
            outputDirectory: outputDirectory,
            metadata: metadata,
            currentStage: currentStage,
            serviceDisplay: "Google AI Studio",
            modelDisplay: modelDisplay,
            update: update
        ) { audioData, timeOffset, segmentLabel, speakerRoster in
            try await self.transcribeGoogleAIStudioWithStatus(
                audioData: audioData,
                job: job,
                modelDisplay: "\(modelDisplay)\(segmentLabel)",
                timeOffset: timeOffset,
                speakerRoster: speakerRoster,
                workingDirectory: workingDirectory,
                update: update
            )
        }
    }

    private func transcribeGoogleAIStudioWithStatus(
        audioData: Data,
        job: TranscriptionJob,
        modelDisplay: String,
        timeOffset: Double,
        speakerRoster: SpeakerRoster,
        workingDirectory: URL? = nil,
        update: @escaping (PipelineUpdate) -> Void
    ) async throws -> CloudTranscriptionResult {
        let statusUpdater = makeCloudStatusTask(
            modelDisplay: modelDisplay,
            update: update
        )
        do {
            let result = try await googleAIStudioBackend.transcribeDetailed(
                audioData: audioData,
                mimeType: "audio/mp3",
                terms: job.snapshot.terms,
                customPrompt:
                    GeminiTranscriptPrompt.promptByAppendingSpeakerContinuity(
                        job.snapshot.prompt,
                        roster: speakerRoster
                    ),
                timeOffsetSeconds: timeOffset,
                workingDirectory: workingDirectory,
                logger: { level, message in
                    update(.log(level: level, message: message))
                }
            )
            statusUpdater.cancel()
            await statusUpdater.value
            return result
        } catch {
            statusUpdater.cancel()
            await statusUpdater.value
            throw error
        }
    }

    private func runVertexAIPipeline(
        job: TranscriptionJob,
        startedAt: Date,
        sourceURL: URL,
        workingDirectory: URL,
        outputDirectory: URL,
        metadata: AudioMetadata,
        currentStage: PipelineStageTracker,
        update: @escaping (PipelineUpdate) -> Void
    ) async throws -> PipelineResult {
        let resolvedLocation = Self.resolvedVertexLocation(
            job.snapshot.vertexAILocation
        )

        vertexAIBackend.updateAuthentication(
            customGCloudPath: runtime.gcloud?.path,
            runner: runner
        )
        vertexAIBackend.updateConfiguration(
            VertexAIGeminiBackend.Configuration(
                projectID: job.snapshot.vertexAIProjectID,
                location: resolvedLocation,
                modelID: job.snapshot.vertexAIModelID,
                gcsBucket: job.snapshot.vertexAIGCSBucket,
                includeSummary: job.snapshot.vertexAIIncludeSummary,
                thinkingLevel: job.snapshot.geminiThinkingLevel,
                fallbackPolicy: job.snapshot.cloudFallbackPolicy
            )
        )
        let modelDisplay = job.snapshot.vertexAIModelID
        return try await runCloudPipeline(
            job: job,
            startedAt: startedAt,
            sourceURL: sourceURL,
            workingDirectory: workingDirectory,
            outputDirectory: outputDirectory,
            metadata: metadata,
            currentStage: currentStage,
            serviceDisplay: "Google Cloud Vertex AI (\(resolvedLocation))",
            modelDisplay: modelDisplay,
            update: update,
            finalizeTranscript: { segmentTexts in
                await Self.finalizeVertexTranscript(
                    segmentTexts: segmentTexts,
                    includeSummary: job.snapshot.vertexAIIncludeSummary,
                    summarize: { completeTranscript in
                        update(
                            .log(
                                level: "info",
                                message: "逐字稿已完整合併，正在產生一次全文摘要。"
                            )
                        )
                        return try await self.vertexAIBackend.summarizeTranscript(
                            completeTranscript,
                            workingDirectory: workingDirectory,
                            logger: { level, message in
                                update(.log(level: level, message: message))
                            }
                        )
                    },
                    update: update
                )
            },
            transcribe: { audioData, timeOffset, segmentLabel, speakerRoster in
                try await self.transcribeVertexWithStatus(
                    audioData: audioData,
                    job: job,
                    modelDisplay: "\(modelDisplay)\(segmentLabel)",
                    timeOffset: timeOffset,
                    speakerRoster: speakerRoster,
                    workingDirectory: workingDirectory,
                    update: update
                )
            }
        )
    }

    private func transcribeVertexWithStatus(
        audioData: Data,
        job: TranscriptionJob,
        modelDisplay: String,
        timeOffset: Double,
        speakerRoster: SpeakerRoster,
        workingDirectory: URL? = nil,
        update: @escaping (PipelineUpdate) -> Void
    ) async throws -> CloudTranscriptionResult {
        let statusUpdater = makeCloudStatusTask(
            modelDisplay: modelDisplay,
            update: update
        )
        do {
            let result = try await vertexAIBackend.transcribeDetailed(
                audioData: audioData,
                mimeType: "audio/mp3",
                terms: job.snapshot.terms,
                customPrompt:
                    GeminiTranscriptPrompt.promptByAppendingSpeakerContinuity(
                        job.snapshot.prompt,
                        roster: speakerRoster
                    ),
                timeOffsetSeconds: timeOffset,
                workingDirectory: workingDirectory,
                logger: { level, message in
                    update(.log(level: level, message: message))
                }
            )
            statusUpdater.cancel()
            await statusUpdater.value
            return result
        } catch {
            statusUpdater.cancel()
            await statusUpdater.value
            throw error
        }
    }

    /// Cloud APIs do not expose reliable generation progress. Keep an
    /// indeterminate segment state and report elapsed time without fabricating
    /// percentages that imply server-side progress.
    private func makeCloudStatusTask(
        modelDisplay: String,
        update: @escaping (PipelineUpdate) -> Void
    ) -> Task<Void, Never> {
        Task {
            var elapsedSeconds = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                elapsedSeconds += 30
                update(
                    .log(
                        level: "info",
                        message: "\(modelDisplay) 仍在處理中（已耗時 \(elapsedSeconds) 秒；Google 未提供實際完成百分比）。"
                    )
                )
            }
        }
    }

    private func makeCloudSegmentPlan(
        job: TranscriptionJob,
        sourceURL: URL,
        metadata: AudioMetadata,
        update: (PipelineUpdate) -> Void
    ) async throws -> AudioSegmentationPlan {
        let hardPlan = try AudioSegmentPlanner.makePlan(
            sourceDuration: metadata.duration,
            maximumSegmentDuration: maximumASRSegmentDuration
        )
        guard job.snapshot.silenceAwareCloudSegmentation,
              hardPlan.requiresSplitting
        else {
            return hardPlan
        }

        do {
            update(
                .log(
                    level: "info",
                    message: "正在分析 20 分鐘上限前的靜音位置，以降低句子被硬切的機率。"
                )
            )
            let silences = try await silenceDetectionService.detect(
                sourceURL: sourceURL,
                startSeconds: job.sourceSlice?.startSeconds ?? 0,
                durationSeconds: metadata.duration
            )
            let adjusted = try SilenceAwareSegmentPlanner.makePlan(
                sourceDuration: metadata.duration,
                maximumSegmentDuration: maximumASRSegmentDuration,
                silences: silences
            )
            guard adjusted != hardPlan else {
                update(
                    .log(
                        level: "info",
                        message: "未找到合適靜音切點，維持精確 20 分鐘硬切。"
                    )
                )
                return hardPlan
            }
            let boundaries = adjusted.segments.dropLast().map {
                String(format: "%.1f", $0.endSeconds)
            }.joined(separator: "、")
            update(
                .log(
                    level: "info",
                    message: "已採用靜音感知切點（秒）：\(boundaries)。每段仍不超過 20 分鐘。"
                )
            )
            return adjusted
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            update(
                .warning(
                    code: "silence_detection_failed",
                    message: "靜音分析失敗，已安全退回 20 分鐘硬切：\(error.localizedDescription)"
                )
            )
            return hardPlan
        }
    }

    private func adaptiveCloudSplitBoundary(
        for record: AudioSegmentRecord,
        sourceURL: URL
    ) async -> TimeInterval? {
        let silences = (try? await silenceDetectionService.detect(
            sourceURL: sourceURL,
            startSeconds: record.startSeconds,
            durationSeconds: record.durationSeconds
        )) ?? []
        return CloudAdaptiveSegmentPlanner.splitBoundary(
            duration: record.durationSeconds,
            splitDepth: record.splitDepth ?? 0,
            silences: silences
        )
    }

    static func adaptiveCloudChildRecords(
        for record: AudioSegmentRecord,
        boundaryOffset: TimeInterval,
        segmentsDirectory: URL
    ) -> [AudioSegmentRecord]? {
        guard boundaryOffset > 0,
              boundaryOffset < record.durationSeconds
        else {
            return nil
        }
        let boundary = record.startSeconds + boundaryOffset
        let nextDepth = max(record.splitDepth ?? 0, 0) + 1
        let parentStem = URL(fileURLWithPath: record.outputPath)
            .deletingPathExtension()
            .lastPathComponent

        func child(
            suffix: String,
            start: TimeInterval,
            end: TimeInterval
        ) -> AudioSegmentRecord {
            AudioSegmentRecord(
                segmentIndex: 0,
                segmentCount: 0,
                startSeconds: start,
                endSeconds: end,
                audioPath: segmentsDirectory
                    .appendingPathComponent("\(parentStem)-\(suffix).mp3")
                    .path,
                outputPath: segmentsDirectory
                    .appendingPathComponent("\(parentStem)-\(suffix).txt")
                    .path,
                splitDepth: nextDepth
            )
        }

        return [
            child(
                suffix: "a",
                start: record.startSeconds,
                end: boundary
            ),
            child(
                suffix: "b",
                start: boundary,
                end: record.endSeconds
            )
        ]
    }

    private func normalizeCompletedCloudSegmentFiles(
        in manifest: AudioSegmentManifest,
        roster: SpeakerRoster
    ) throws {
        for record in manifest.segments where
            record.status == .completed
                || record.status == .completedWithGaps
        {
            let url = URL(fileURLWithPath: record.outputPath)
            let original = try TextFileValidator.readNonEmptyUTF8(at: url)
            let normalized = roster.normalizingSpeakerLabels(in: original)
            if normalized != original {
                try AtomicFileWriter.writeText(normalized, to: url)
            }
        }
    }

    private func runCloudPipeline(
        job: TranscriptionJob,
        startedAt: Date,
        sourceURL: URL,
        workingDirectory: URL,
        outputDirectory: URL,
        metadata: AudioMetadata,
        currentStage: PipelineStageTracker,
        serviceDisplay: String,
        modelDisplay: String,
        update: @escaping (PipelineUpdate) -> Void,
        finalizeTranscript: (([String]) async -> String)? = nil,
        transcribe: (
            _ audioData: Data,
            _ timeOffset: Double,
            _ segmentLabel: String,
            _ speakerRoster: SpeakerRoster
        ) async throws -> CloudTranscriptionResult
    ) async throws -> PipelineResult {
        let fileManager = FileManager.default
        let sourceTimeOffset = Self.cloudSegmentStart(
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
        var speakerRoster = resumeCheckpoint?.speakerRoster ?? SpeakerRoster()
        let initialTotalSegments = segmentPlan.expectedSegmentCount
        let segmentsDirectory = workingDirectory.appendingPathComponent(
            RecoveryScanner.segmentsDirectoryName,
            isDirectory: true
        )
        let segmentManifestURL = workingDirectory.appendingPathComponent(
            RecoveryScanner.segmentManifestFileName
        )
        let cloudRawURL = workingDirectory.appendingPathComponent(
            "cloud-merged-raw.txt"
        )
        let cloudTraditionalURL = workingDirectory.appendingPathComponent(
            "cloud-merged-taiwan.txt"
        )

        try fileManager.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: segmentsDirectory.path
        )

        var segmentManifest = AudioSegmentManifest(
            schemaVersion: 3,
            jobID: job.id,
            sourceDurationSeconds: segmentPlan.sourceDurationSeconds,
            maximumSegmentDurationSeconds: segmentPlan.maximumSegmentDurationSeconds,
            expectedSegmentCount: initialTotalSegments,
            segments: segmentPlan.segments.map { segment in
                let audioURL = segmentsDirectory.appendingPathComponent(
                    String(format: "segment-%04d.mp3", segment.index)
                )
                let transcriptURL = segmentsDirectory.appendingPathComponent(
                    segment.transcriptFileName
                )
                return AudioSegmentRecord(
                    segmentIndex: segment.index,
                    segmentCount: initialTotalSegments,
                    startSeconds: sourceTimeOffset + segment.startSeconds,
                    endSeconds: sourceTimeOffset + segment.endSeconds,
                    audioPath: audioURL.path,
                    outputPath: transcriptURL.path,
                    splitDepth: resumeCheckpoint?.splitDepths[segment.index]
                )
            },
            speakerRoster: speakerRoster
        )
        if let resumeCheckpoint {
            for segmentIndex in resumeCheckpoint.reusableSegments.keys.sorted() {
                guard let reusable = resumeCheckpoint.reusableSegments[segmentIndex]
                else {
                    continue
                }
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
                speakerRoster.observe(
                    transcript: reusable.transcript,
                    segmentIndex: segmentIndex,
                    knownTerms: job.snapshot.terms
                )
            }
            segmentManifest.speakerRoster = speakerRoster
        }
        try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

        if segmentPlan.requiresSplitting {
            update(
                .log(
                    level: "info",
                    message: "音檔超過單段上限，將以最多 \(Int(maximumASRSegmentDuration / 60)) 分鐘切成 \(initialTotalSegments) 段；每段完成後會立即建立可取回的救援檢查點。"
                )
            )
        }

        var zeroBasedIndex = 0
        while zeroBasedIndex < segmentManifest.segments.count {
            try Task.checkCancellation()
            let totalSegments = segmentManifest.expectedSegmentCount
            let record = segmentManifest.segments[zeroBasedIndex]
            let segmentIndex = record.segmentIndex
            let audioURL = URL(fileURLWithPath: record.audioPath)
            let transcriptURL = URL(fileURLWithPath: record.outputPath)
            let absoluteStart = record.startSeconds
            let baseProgress = 8.0
                + (Double(zeroBasedIndex) / Double(totalSegments)) * 80.0
            let maxProgress = 8.0
                + (Double(segmentIndex) / Double(totalSegments)) * 80.0
            let segmentLabel = totalSegments > 1
                ? " 第 \(segmentIndex)/\(totalSegments) 段"
                : ""
            let waitingUnit = totalSegments > 1
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
                zeroBasedIndex += 1
                continue
            }

            do {
                currentStage.set(.convertingAudio)
                update(.stage(.convertingAudio))
                update(
                    .log(
                        level: "info",
                        message: totalSegments > 1
                            ? "［第 \(segmentIndex)/\(totalSegments) 段］正在截取並壓縮音訊。"
                            : "正在壓縮音訊為 16kHz 單聲道 MP3 以傳送至 \(serviceDisplay)。"
                    )
                )

                if totalSegments == 1, job.sourceSlice == nil {
                    try await ffmpegService.compressForCloud(
                        sourceURL: sourceURL,
                        destinationURL: audioURL,
                        duration: metadata.duration
                    ) { current, total in
                        let fraction = total > 0
                            ? min(max(current / total, 0), 1)
                            : 0
                        update(
                            .progress(
                                current: 2.0 + fraction * 6.0,
                                total: 100,
                                unit: "percent"
                            )
                        )
                    }
                } else {
                    try await ffmpegService.extractSegmentForCloud(
                        sourceURL: sourceURL,
                        destinationURL: audioURL,
                        startSeconds: absoluteStart,
                        durationSeconds: record.durationSeconds
                    )
                }

                let preparedMetadata = try await probeService.probe(audioURL)
                guard preparedMetadata.duration
                    <= maximumASRSegmentDuration + 1.0
                else {
                    throw AudioSegmentationError.segmentOutputTooLong(
                        index: segmentIndex,
                        duration: preparedMetadata.duration,
                        maximum: maximumASRSegmentDuration
                    )
                }
                try segmentManifest.mark(
                    segmentIndex: segmentIndex,
                    status: .prepared
                )
                try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

                try Task.checkCancellation()
                currentStage.set(.transcribing)
                update(.stage(.transcribing))
                update(
                    .progress(
                        current: baseProgress,
                        total: 100,
                        unit: waitingUnit
                    )
                )
                update(
                    .log(
                        level: "info",
                        message: "正在由 \(modelDisplay)\(segmentLabel) 忠實轉錄；等待期間顯示不確定進度，不虛構完成百分比。"
                    )
                )
                try segmentManifest.mark(
                    segmentIndex: segmentIndex,
                    status: .transcribing
                )
                try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

                let result = try await transcribe(
                    try Data(contentsOf: audioURL),
                    absoluteStart,
                    segmentLabel,
                    speakerRoster
                )
                let validatedText = try OutputContractValidator.validate(
                    text: result.text,
                    path: transcriptURL.path,
                    prompt: job.snapshot.prompt
                )
                speakerRoster.observe(
                    transcript: validatedText,
                    segmentIndex: segmentIndex,
                    knownTerms: job.snapshot.terms
                )
                let normalizedText = speakerRoster.normalizingSpeakerLabels(
                    in: validatedText
                )
                try normalizeCompletedCloudSegmentFiles(
                    in: segmentManifest,
                    roster: speakerRoster
                )
                try AtomicFileWriter.writeText(normalizedText, to: transcriptURL)
                segmentManifest.segments[segmentIndex - 1].cloudMetadata =
                    result.metadata
                segmentManifest.speakerRoster = speakerRoster
                try segmentManifest.mark(
                    segmentIndex: segmentIndex,
                    status: .completed,
                    completedEventCount: 1
                )
                try writeSegmentManifest(segmentManifest, to: segmentManifestURL)
                emitCloudMetadataLog(
                    result.metadata,
                    segmentIndex: segmentIndex,
                    segmentCount: totalSegments,
                    update: update
                )

                let checkpointStatus = NSError(
                    domain: "RecordToText.CloudCheckpoint",
                    code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "工作仍在進行；此檔為已完成片段的自動檢查點。"
                    ]
                )
                try writePartialTranscript(
                    from: segmentManifestURL,
                    error: checkpointStatus,
                    to: workingDirectory
                )
                update(
                    .progress(
                        current: maxProgress,
                        total: 100,
                        unit: totalSegments > 1
                            ? "percent|\(segmentIndex)|\(totalSegments)"
                            : "percent"
                    )
                )
                zeroBasedIndex += 1
            } catch let truncation as CloudOutputTruncatedError {
                let partialURL = URL(
                    fileURLWithPath: record.outputPath + ".partial.txt"
                )
                try? AtomicFileWriter.writeText(
                    truncation.partialText,
                    to: partialURL
                )

                let boundaryOffset = await adaptiveCloudSplitBoundary(
                    for: record,
                    sourceURL: sourceURL
                )
                if let boundaryOffset,
                   let children = Self.adaptiveCloudChildRecords(
                       for: record,
                       boundaryOffset: boundaryOffset,
                       segmentsDirectory: segmentsDirectory
                   )
                {
                    try segmentManifest.replaceSegment(
                        segmentIndex: segmentIndex,
                        with: children
                    )
                    try writeSegmentManifest(
                        segmentManifest,
                        to: segmentManifestURL
                    )
                    try? fileManager.removeItem(at: audioURL)
                    try? fileManager.removeItem(at: transcriptURL)
                    try? fileManager.removeItem(at: partialURL)
                    let boundary = record.startSeconds + boundaryOffset
                    update(
                        .warning(
                            code: "cloud_segment_split_max_tokens",
                            message: String(
                                format:
                                    "第 %d 段達輸出上限，已捨棄截斷稿並在 %.1f 秒處切成兩段重試；目前共 %d 段。",
                                segmentIndex,
                                boundary,
                                segmentManifest.expectedSegmentCount
                            )
                        )
                    )
                    continue
                }

                try? segmentManifest.mark(
                    segmentIndex: segmentIndex,
                    status: .failed,
                    failureMessage: truncation.localizedDescription
                )
                try? writeSegmentManifest(
                    segmentManifest,
                    to: segmentManifestURL
                )
                try? writePartialTranscript(
                    from: segmentManifestURL,
                    error: truncation,
                    to: workingDirectory
                )
                if totalSegments == 1 {
                    throw truncation
                }
                throw AudioSegmentationError.segmentTranscriptionFailed(
                    index: segmentIndex,
                    count: totalSegments,
                    reason: truncation.localizedDescription
                )
            } catch is CancellationError {
                try? segmentManifest.mark(
                    segmentIndex: segmentIndex,
                    status: .failed,
                    failureMessage: "使用者取消工作。"
                )
                try? writeSegmentManifest(segmentManifest, to: segmentManifestURL)
                throw CancellationError()
            } catch {
                try? segmentManifest.mark(
                    segmentIndex: segmentIndex,
                    status: .failed,
                    failureMessage: error.localizedDescription
                )
                try? writeSegmentManifest(segmentManifest, to: segmentManifestURL)
                try? writePartialTranscript(
                    from: segmentManifestURL,
                    error: error,
                    to: workingDirectory
                )
                if totalSegments == 1 {
                    throw error
                }
                throw AudioSegmentationError.segmentTranscriptionFailed(
                    index: segmentIndex,
                    count: totalSegments,
                    reason: error.localizedDescription
                )
            }
        }

        let completedSegments = try segmentManifest.validatedCompletedSegments()
        let completedSegmentTexts = try completedSegments.map { record in
            speakerRoster.normalizingSpeakerLabels(in: try TextFileValidator.readNonEmptyUTF8(
                at: URL(fileURLWithPath: record.outputPath)
            ))
        }
        let segmentMetadata = completedSegments.compactMap(\.cloudMetadata)
        let mergedText: String
        if let finalizeTranscript {
            mergedText = await finalizeTranscript(completedSegmentTexts)
        } else {
            mergedText = completedSegmentTexts.joined(separator: "\n\n")
        }

        let validatedRaw = try OutputContractValidator.validate(
            text: mergedText,
            path: cloudRawURL.path,
            prompt: job.snapshot.prompt
        )
        try AtomicFileWriter.writeText(validatedRaw, to: cloudRawURL)

        try Task.checkCancellation()
        update(.progress(current: 92, total: 100, unit: "percent"))
        currentStage.set(.convertingTraditionalChinese)
        update(.stage(.convertingTraditionalChinese))
        update(
            .log(
                level: "info",
                message: "正在以 OpenCC s2twp 統一轉為台灣繁體。"
            )
        )
        try await openCCService.convert(
            sourceURL: cloudRawURL,
            destinationURL: cloudTraditionalURL
        )
        let finalTranscribedText = try OutputContractValidator.readTranscript(
            at: cloudTraditionalURL,
            prompt: job.snapshot.prompt
        )

        try Task.checkCancellation()
        update(.progress(current: 98, total: 100, unit: "percent"))
        currentStage.set(.writingOutput)
        update(.stage(.writingOutput))
        let finalOutputURL = try writeUniqueText(
            finalTranscribedText,
            sourceURL: sourceURL,
            directory: outputDirectory,
            suffix: outputSuffix(
                job.snapshot.outputFilenameSuffix,
                sourceSlice: job.sourceSlice
            )
        )

        update(.progress(current: 100, total: 100, unit: "percent"))
        update(
            .log(
                level: "info",
                message: "轉錄完成！已儲存至：\(finalOutputURL.lastPathComponent)"
            )
        )
        update(.stage(.completed))
        return PipelineResult(
            outputURL: finalOutputURL,
            rawOutputURL: nil,
            duration: Date().timeIntervalSince(startedAt),
            containsSkippedAudio: false,
            cloudSegmentMetadata: segmentMetadata
        )
    }

    private func emitCloudMetadataLog(
        _ metadata: CloudTranscriptionMetadata,
        segmentIndex: Int,
        segmentCount: Int,
        update: (PipelineUpdate) -> Void
    ) {
        var details = [
            "第 \(segmentIndex)/\(segmentCount) 段實際模型 \(metadata.effectiveModelID)"
        ]
        if let version = metadata.modelVersion, !version.isEmpty {
            details.append("版本 \(version)")
        }
        if let responseID = metadata.responseID, !responseID.isEmpty {
            details.append("response \(responseID)")
        }
        if metadata.retryCount > 0 {
            details.append("重試 \(metadata.retryCount) 次")
        }
        if let usage = metadata.usage {
            if let total = usage.totalTokenCount {
                details.append("總 token \(total)")
            }
            if let thoughts = usage.thoughtsTokenCount {
                details.append("thinking token \(thoughts)")
            }
        }
        if let latency = metadata.latencySeconds {
            details.append(String(format: "API %.1f 秒", latency))
        }
        update(.log(level: "info", message: details.joined(separator: "；") + "。"))

        if metadata.usedFallback {
            update(
                .warning(
                    code: "cloud_model_fallback_used",
                    message: "本段要求 \(metadata.requestedModelID)，實際由 \(metadata.effectiveModelID) 完成。\(metadata.fallbackReason ?? "")"
                )
            )
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
            let sourceSlice: TranscriptionSourceSlice?
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
            sourceSlice: job.sourceSlice,
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

    func preserveCloudRecoveryData(
        job: TranscriptionJob,
        stage: TranscriptionStage,
        error: Error,
        segmentManifestURL: URL,
        recoveryDirectory: URL
    ) throws -> URL {
        struct CloudRecoveryMetadata: Codable {
            let schemaVersion: Int
            let recoveryKind: String
            let jobID: UUID
            let sourcePath: String
            let sourceSlice: TranscriptionSourceSlice?
            let backendType: ASRBackendType
            let failureStage: String
            let createdAt: Date
            let technicalError: String
            let checkpointFile: String
            let segmentsDirectory: String
            let partialTranscriptFile: String
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
        let staleNormalizedAudio = recoveryDirectory.appendingPathComponent(
            RecoveryScanner.normalizedWAVFileName
        )
        if fileManager.fileExists(atPath: staleNormalizedAudio.path) {
            try fileManager.removeItem(at: staleNormalizedAudio)
        }

        // 先從工作區中的 completed segment 輸出建立人可讀的救援稿，
        // 再由外層 defer 清除工作區，避免已付費完成的片段隨失敗消失。
        let recoveredPartial = recoveryDirectory.appendingPathComponent(
            RecoveryScanner.partialTranscriptFileName
        )
        if fileManager.fileExists(atPath: recoveredPartial.path) {
            try fileManager.removeItem(at: recoveredPartial)
        }
        try writePartialTranscript(
            from: segmentManifestURL,
            error: error,
            to: recoveryDirectory
        )

        let sourceManifestData = try Data(contentsOf: segmentManifestURL)
        let sourceManifest = try JSONDecoder().decode(
            AudioSegmentManifest.self,
            from: sourceManifestData
        )
        let recoveredSegments = recoveryDirectory.appendingPathComponent(
            RecoveryScanner.segmentsDirectoryName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: recoveredSegments.path) {
            try fileManager.removeItem(at: recoveredSegments)
        }
        try fileManager.createDirectory(
            at: recoveredSegments,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Recovery keeps only completed text. MP3 segments are intentionally
        // excluded because the original sourcePath can recreate them and audio
        // retention would unnecessarily duplicate sensitive data.
        var recoveredRecords: [AudioSegmentRecord] = []
        for sourceRecord in sourceManifest.segments {
            let transcriptName = String(
                format: "segment-%04d.txt",
                sourceRecord.segmentIndex
            )
            let recoveredTranscript = recoveredSegments.appendingPathComponent(
                transcriptName
            )
            let sourceTranscript = URL(fileURLWithPath: sourceRecord.outputPath)
            if fileManager.fileExists(atPath: sourceTranscript.path) {
                try fileManager.copyItem(
                    at: sourceTranscript,
                    to: recoveredTranscript
                )
            }
            recoveredRecords.append(
                AudioSegmentRecord(
                    segmentIndex: sourceRecord.segmentIndex,
                    segmentCount: sourceRecord.segmentCount,
                    startSeconds: sourceRecord.startSeconds,
                    endSeconds: sourceRecord.endSeconds,
                    audioPath: "",
                    outputPath: recoveredTranscript.path,
                    status: sourceRecord.status,
                    completedEventCount: sourceRecord.completedEventCount,
                    failureMessage: sourceRecord.failureMessage,
                    cloudMetadata: sourceRecord.cloudMetadata,
                    reusedFromCheckpoint: sourceRecord.reusedFromCheckpoint,
                    splitDepth: sourceRecord.splitDepth
                )
            )
        }

        let recoveredManifestValue = AudioSegmentManifest(
            schemaVersion: sourceManifest.schemaVersion,
            jobID: sourceManifest.jobID,
            sourceDurationSeconds: sourceManifest.sourceDurationSeconds,
            maximumSegmentDurationSeconds:
                sourceManifest.maximumSegmentDurationSeconds,
            expectedSegmentCount: sourceManifest.expectedSegmentCount,
            segments: recoveredRecords,
            speakerRoster: sourceManifest.speakerRoster
        )
        let recoveredManifest = recoveryDirectory.appendingPathComponent(
            RecoveryScanner.segmentManifestFileName
        )
        try writeSegmentManifest(recoveredManifestValue, to: recoveredManifest)

        let metadata = CloudRecoveryMetadata(
            schemaVersion: 2,
            recoveryKind: "cloudCheckpoint",
            jobID: job.id,
            sourcePath: job.sourcePath,
            sourceSlice: job.sourceSlice,
            backendType: job.snapshot.backendType,
            failureStage: stage.rawValue,
            createdAt: Date(),
            technicalError: error.localizedDescription,
            checkpointFile: RecoveryScanner.segmentManifestFileName,
            segmentsDirectory: RecoveryScanner.segmentsDirectoryName,
            partialTranscriptFile: RecoveryScanner.partialTranscriptFileName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(
            try encoder.encode(metadata),
            to: recoveryDirectory.appendingPathComponent(
                RecoveryScanner.recoveryJSONFileName
            )
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
            to: recoveryDirectory.appendingPathComponent(
                RecoveryScanner.partialTranscriptFileName
            )
        )
    }

    /// Cancellation creates recovery data only when there is actual text to
    /// retrieve. A freshly-created manifest with no completed output is not a
    /// useful checkpoint and should disappear with the normal temp cleanup.
    static func cloudCheckpointContainsRecoverableText(
        manifestURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(
                AudioSegmentManifest.self,
                from: data
            )
        else {
            return false
        }

        return manifest.segments.contains { segment in
            let completed = URL(fileURLWithPath: segment.outputPath)
            let partial = URL(fileURLWithPath: segment.outputPath + ".partial.txt")
            return [completed, partial].contains { url in
                guard fileManager.fileExists(atPath: url.path) else {
                    return false
                }
                return (try? TextFileValidator.readNonEmptyUTF8(at: url)) != nil
            }
        }
    }
}
