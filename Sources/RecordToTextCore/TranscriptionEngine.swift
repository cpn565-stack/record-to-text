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
    private let googleAIStudioBackend: GoogleAIStudioBackend
    private let googleAIStudioTranscribeBackend: GoogleAIStudioTranscribeBackend
    private let vertexAIBackend: VertexAIGeminiBackend
    private let agentPlatformTranscribeBackend: AgentPlatformTranscribeBackend
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
        googleAIStudioTranscribeBackend: GoogleAIStudioTranscribeBackend? = nil,
        vertexAIBackend: VertexAIGeminiBackend? = nil,
        agentPlatformTranscribeBackend: AgentPlatformTranscribeBackend? = nil,
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
        self.googleAIStudioBackend = googleAIStudioBackend ?? GoogleAIStudioBackend()
        self.googleAIStudioTranscribeBackend = googleAIStudioTranscribeBackend
            ?? GoogleAIStudioTranscribeBackend()
        self.vertexAIBackend = vertexAIBackend
            ?? VertexAIGeminiBackend(authService: GCloudAuthService(runner: runner))
        self.agentPlatformTranscribeBackend = agentPlatformTranscribeBackend
            ?? AgentPlatformTranscribeBackend(
                authService: GCloudAuthService(runner: runner)
            )
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
                        recoveryDirectory: recoveryDirectory
                    )
                } catch {
                    shouldKeepWorkingDirectory = true
                    if fileManager.fileExists(atPath: recoveryDirectory.path) {
                        preservedRecovery = recoveryDirectory
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

    static func effectiveCloudSegmentDuration(
        for snapshot: JobSnapshot,
        productMaximum: TimeInterval =
            AudioSegmentPlanner.productionMaximumDuration
    ) -> TimeInterval {
        let modelID = snapshot.backendType == .googleAIStudio
            ? snapshot.googleAIStudioModelID
            : snapshot.vertexAIModelID
        let descriptor = CloudModelCatalog.resolvedDescriptor(
            provider: snapshot.backendType,
            modelID: modelID
        )
        let captured = snapshot.modelRecommendedSegmentDurationSeconds
            ?? descriptor.recommendedSegmentDurationSeconds
        guard captured.isFinite, captured > 0 else {
            return productMaximum
        }
        return min(productMaximum, captured)
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
        let descriptor = CloudModelCatalog.resolvedDescriptor(
            provider: .googleAIStudio,
            modelID: job.snapshot.googleAIStudioModelID
        )
        switch job.snapshot.cloudTransport {
        case .geminiInteractionsTranscribe:
            googleAIStudioTranscribeBackend.updateConfiguration(
                GoogleAIStudioTranscribeBackend.Configuration(
                    apiKey: job.snapshot.googleAIStudioAPIKey,
                    modelID: job.snapshot.googleAIStudioModelID,
                    options: job.snapshot.transcriptionOptions
                )
            )
        case .geminiGenerateContent:
            googleAIStudioBackend.updateConfiguration(
                GoogleAIStudioBackend.Configuration(
                    apiKey: job.snapshot.googleAIStudioAPIKey,
                    modelID: job.snapshot.googleAIStudioModelID
                )
            )
        case .agentPlatformTranscribe:
            throw GoogleAIStudioTranscribeError.invalidConfiguration(
                "Google AI Studio 工作不能使用 Agent Platform transport。"
            )
        }

        let modelDisplay = descriptor.displayName
        return try await runCloudPipeline(
            job: job,
            descriptor: descriptor,
            startedAt: startedAt,
            sourceURL: sourceURL,
            workingDirectory: workingDirectory,
            outputDirectory: outputDirectory,
            metadata: metadata,
            currentStage: currentStage,
            serviceDisplay: "Google AI Studio",
            modelDisplay: modelDisplay,
            update: update
        ) { audioData, timeOffset, basePercent, maxPercent, segmentLabel in
            try await self.transcribeGoogleAIStudioWithLiveProgress(
                audioData: audioData,
                job: job,
                modelDisplay: "\(modelDisplay)\(segmentLabel)",
                timeOffset: timeOffset,
                basePercent: basePercent,
                maxPercent: maxPercent,
                workingDirectory: workingDirectory,
                update: update
            )
        }
    }

    private func transcribeGoogleAIStudioWithLiveProgress(
        audioData: Data,
        job: TranscriptionJob,
        modelDisplay: String,
        timeOffset: Double,
        basePercent: Double,
        maxPercent: Double,
        workingDirectory: URL? = nil,
        update: @escaping (PipelineUpdate) -> Void
    ) async throws -> CloudTranscriptionResult {
        try await withCloudLiveProgress(
            modelDisplay: modelDisplay,
            basePercent: basePercent,
            maxPercent: maxPercent,
            update: update
        ) {
            switch job.snapshot.cloudTransport {
            case .geminiInteractionsTranscribe:
                return try await self.googleAIStudioTranscribeBackend.transcribe(
                    audioData: audioData,
                    mimeType: "audio/mp3",
                    customVocabulary: job.snapshot.resolvedCustomVocabulary,
                    workingDirectory: workingDirectory,
                    logger: { level, message in
                        update(.log(level: level, message: message))
                    }
                )
            case .geminiGenerateContent:
                let text = try await self.googleAIStudioBackend.transcribe(
                    audioData: audioData,
                    mimeType: "audio/mp3",
                    terms: job.snapshot.terms,
                    customPrompt: job.snapshot.prompt,
                    timeOffsetSeconds: timeOffset,
                    workingDirectory: workingDirectory,
                    logger: { level, message in
                        update(.log(level: level, message: message))
                    }
                )
                return CloudTranscriptionResult(
                    text: text,
                    modelID: job.snapshot.googleAIStudioModelID,
                    transport: .geminiGenerateContent
                )
            case .agentPlatformTranscribe:
                throw GoogleAIStudioTranscribeError.invalidConfiguration(
                    "Google AI Studio 工作不能使用 Agent Platform transport。"
                )
            }
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
        let descriptor = CloudModelCatalog.resolvedDescriptor(
            provider: .vertexAI,
            modelID: job.snapshot.vertexAIModelID
        )
        let resolvedLocation = descriptor.effectiveLocation(
            requestedLocation: job.snapshot.vertexAILocation
        )

        vertexAIBackend.updateAuthentication(
            customGCloudPath: runtime.gcloud?.path,
            runner: runner
        )
        agentPlatformTranscribeBackend.updateAuthentication(
            customGCloudPath: runtime.gcloud?.path,
            runner: runner
        )

        switch job.snapshot.cloudTransport {
        case .agentPlatformTranscribe:
            agentPlatformTranscribeBackend.updateConfiguration(
                AgentPlatformTranscribeBackend.Configuration(
                    projectID: job.snapshot.vertexAIProjectID,
                    modelID: job.snapshot.vertexAIModelID,
                    gcsBucket: job.snapshot.vertexAIGCSBucket,
                    options: job.snapshot.transcriptionOptions
                )
            )
        case .geminiGenerateContent:
            vertexAIBackend.updateConfiguration(
                VertexAIGeminiBackend.Configuration(
                    projectID: job.snapshot.vertexAIProjectID,
                    location: resolvedLocation,
                    modelID: job.snapshot.vertexAIModelID,
                    gcsBucket: job.snapshot.vertexAIGCSBucket,
                    includeSummary: job.snapshot.vertexAIIncludeSummary
                )
            )
        case .geminiInteractionsTranscribe:
            throw AgentPlatformTranscribeError.invalidConfiguration(
                "gcloud 工作不能使用 Gemini API Interactions transport。"
            )
        }

        let modelDisplay = descriptor.displayName
        return try await runCloudPipeline(
            job: job,
            descriptor: descriptor,
            startedAt: startedAt,
            sourceURL: sourceURL,
            workingDirectory: workingDirectory,
            outputDirectory: outputDirectory,
            metadata: metadata,
            currentStage: currentStage,
            serviceDisplay: "Google Cloud (\(resolvedLocation))",
            modelDisplay: modelDisplay,
            update: update,
            finalizeTranscript: { segmentTexts in
                await Self.finalizeVertexTranscript(
                    segmentTexts: segmentTexts,
                    includeSummary: job.snapshot.vertexAIIncludeSummary,
                    summarize: { completeTranscript in
                        let summaryDescriptor = CloudModelCatalog.resolvedDescriptor(
                            provider: .vertexAI,
                            modelID: job.snapshot.vertexAISummaryModelID
                        )
                        guard summaryDescriptor.supportsSummary else {
                            throw VertexAIError.requestFailed(
                                statusCode: 400,
                                message: "摘要模型 \(summaryDescriptor.id) 不支援一般文字生成。"
                            )
                        }
                        update(
                            .log(
                                level: "info",
                                message: "逐字稿已完整合併，正使用 \(summaryDescriptor.displayName) 產生一次全文摘要。"
                            )
                        )
                        self.vertexAIBackend.updateConfiguration(
                            VertexAIGeminiBackend.Configuration(
                                projectID: job.snapshot.vertexAIProjectID,
                                location: summaryDescriptor.effectiveLocation(
                                    requestedLocation: job.snapshot.vertexAILocation
                                ),
                                modelID: summaryDescriptor.id,
                                gcsBucket: job.snapshot.vertexAIGCSBucket,
                                includeSummary: false
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
            transcribe: { audioData, timeOffset, basePercent, maxPercent, segmentLabel in
                try await self.transcribeVertexWithLiveProgress(
                    audioData: audioData,
                    job: job,
                    modelDisplay: "\(modelDisplay)\(segmentLabel)",
                    timeOffset: timeOffset,
                    basePercent: basePercent,
                    maxPercent: maxPercent,
                    workingDirectory: workingDirectory,
                    update: update
                )
            }
        )
    }

    private func transcribeVertexWithLiveProgress(
        audioData: Data,
        job: TranscriptionJob,
        modelDisplay: String,
        timeOffset: Double,
        basePercent: Double,
        maxPercent: Double,
        workingDirectory: URL? = nil,
        update: @escaping (PipelineUpdate) -> Void
    ) async throws -> CloudTranscriptionResult {
        try await withCloudLiveProgress(
            modelDisplay: modelDisplay,
            basePercent: basePercent,
            maxPercent: maxPercent,
            update: update
        ) {
            switch job.snapshot.cloudTransport {
            case .agentPlatformTranscribe:
                return try await self.agentPlatformTranscribeBackend.transcribe(
                    audioData: audioData,
                    mimeType: "audio/mp3",
                    customVocabulary: job.snapshot.resolvedCustomVocabulary,
                    workingDirectory: workingDirectory,
                    logger: { level, message in
                        update(.log(level: level, message: message))
                    }
                )
            case .geminiGenerateContent:
                let text = try await self.vertexAIBackend.transcribe(
                    audioData: audioData,
                    mimeType: "audio/mp3",
                    terms: job.snapshot.terms,
                    customPrompt: job.snapshot.prompt,
                    timeOffsetSeconds: timeOffset,
                    workingDirectory: workingDirectory,
                    logger: { level, message in
                        update(.log(level: level, message: message))
                    }
                )
                return CloudTranscriptionResult(
                    text: text,
                    modelID: job.snapshot.vertexAIModelID,
                    transport: .geminiGenerateContent
                )
            case .geminiInteractionsTranscribe:
                throw AgentPlatformTranscribeError.invalidConfiguration(
                    "gcloud 工作不能使用 Gemini API Interactions transport。"
                )
            }
        }
    }

    private func withCloudLiveProgress<T>(
        modelDisplay: String,
        basePercent: Double,
        maxPercent: Double,
        update: @escaping (PipelineUpdate) -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        let progressUpdater = Task {
            var currentPercent = basePercent
            var elapsedSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                elapsedSeconds += 2
                currentPercent = min(currentPercent + 3.0, maxPercent)
                update(
                    .progress(
                        current: currentPercent,
                        total: 100,
                        unit: "percent"
                    )
                )
                update(
                    .log(
                        level: "info",
                        message: "正在由 \(modelDisplay) 轉錄中... (已耗時 \(elapsedSeconds) 秒)"
                    )
                )
            }
        }

        do {
            let result = try await operation()
            progressUpdater.cancel()
            await progressUpdater.value
            return result
        } catch {
            progressUpdater.cancel()
            await progressUpdater.value
            throw error
        }
    }

    private func runCloudPipeline(
        job: TranscriptionJob,
        descriptor: CloudModelDescriptor,
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
            _ basePercent: Double,
            _ maxPercent: Double,
            _ segmentLabel: String
        ) async throws -> CloudTranscriptionResult
    ) async throws -> PipelineResult {
        let fileManager = FileManager.default
        let effectiveSegmentDuration = Self.effectiveCloudSegmentDuration(
            for: job.snapshot,
            productMaximum: maximumASRSegmentDuration
        )
        let segmentPlan = try AudioSegmentPlanner.makePlan(
            sourceDuration: metadata.duration,
            maximumSegmentDuration: effectiveSegmentDuration
        )
        let totalSegments = segmentPlan.expectedSegmentCount
        let sourceTimeOffset = Self.cloudSegmentStart(
            sourceSlice: job.sourceSlice,
            plannedStart: 0
        )
        let segmentsDirectory = workingDirectory.appendingPathComponent(
            RecoveryScanner.segmentsDirectoryName,
            isDirectory: true
        )
        let segmentManifestURL = workingDirectory.appendingPathComponent(
            RecoveryScanner.segmentManifestFileName
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

        let writesMetadata = descriptor.isDedicatedTranscription
            && job.snapshot.transcriptionOptions.writeMetadataJSON
        var segmentManifest = AudioSegmentManifest(
            jobID: job.id,
            sourceDurationSeconds: segmentPlan.sourceDurationSeconds,
            maximumSegmentDurationSeconds: segmentPlan.maximumSegmentDurationSeconds,
            expectedSegmentCount: totalSegments,
            segments: segmentPlan.segments.map { segment in
                let audioURL = segmentsDirectory.appendingPathComponent(
                    String(format: "segment-%04d.mp3", segment.index)
                )
                let transcriptURL = segmentsDirectory.appendingPathComponent(
                    segment.transcriptFileName
                )
                let metadataURL = segmentsDirectory.appendingPathComponent(
                    String(
                        format: "segment-%04d.metadata.json",
                        segment.index
                    )
                )
                return AudioSegmentRecord(
                    segmentIndex: segment.index,
                    segmentCount: totalSegments,
                    startSeconds: sourceTimeOffset + segment.startSeconds,
                    endSeconds: sourceTimeOffset + segment.endSeconds,
                    audioPath: audioURL.path,
                    outputPath: transcriptURL.path,
                    metadataPath: writesMetadata ? metadataURL.path : nil
                )
            }
        )
        try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

        update(
            .log(
                level: "info",
                message: "雲端模型契約：\(descriptor.transport.displayName)，API \(descriptor.apiVersion)，單段安全上限 \(Int(effectiveSegmentDuration / 60)) 分鐘。"
            )
        )
        if segmentPlan.requiresSplitting {
            update(
                .log(
                    level: "info",
                    message: "音檔超過單段上限，將以最多 \(Int(effectiveSegmentDuration / 60)) 分鐘切成 \(totalSegments) 段；每段完成後會立即建立可取回的救援檢查點。"
                )
            )
        }

        var structuredResults: [Int: CloudTranscriptionResult] = [:]
        for (zeroBasedIndex, segment) in segmentPlan.segments.enumerated() {
            try Task.checkCancellation()
            let segmentIndex = segment.index
            let record = segmentManifest.segments[segmentIndex - 1]
            let audioURL = URL(fileURLWithPath: record.audioPath)
            let transcriptURL = URL(fileURLWithPath: record.outputPath)
            let absoluteStart = Self.cloudSegmentStart(
                sourceSlice: job.sourceSlice,
                plannedStart: segment.startSeconds
            )
            let baseProgress = 8.0
                + (Double(zeroBasedIndex) / Double(totalSegments)) * 80.0
            let maxProgress = 8.0
                + (Double(segmentIndex) / Double(totalSegments)) * 80.0
            let segmentLabel = totalSegments > 1
                ? " 第 \(segmentIndex)/\(totalSegments) 段"
                : ""

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
                        durationSeconds: segment.durationSeconds
                    )
                }

                let preparedMetadata = try await probeService.probe(audioURL)
                guard preparedMetadata.duration <= effectiveSegmentDuration + 1.0 else {
                    throw AudioSegmentationError.segmentOutputTooLong(
                        index: segmentIndex,
                        duration: preparedMetadata.duration,
                        maximum: effectiveSegmentDuration
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
                    .log(
                        level: "info",
                        message: "正在由 \(modelDisplay)\(segmentLabel) 忠實轉錄。"
                    )
                )
                try segmentManifest.mark(
                    segmentIndex: segmentIndex,
                    status: .transcribing
                )
                try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

                let rawResult = try await transcribe(
                    try Data(contentsOf: audioURL),
                    absoluteStart,
                    baseProgress,
                    maxProgress,
                    segmentLabel
                )
                let offsetResult = rawResult.applyingSegmentOffset(
                    absoluteStart,
                    segmentIndex: segmentIndex
                )
                var convertedResult = try await convertCloudResultToTraditional(
                    offsetResult,
                    workingDirectory: segmentsDirectory
                )
                let validationPrompt = descriptor.isDedicatedTranscription
                    ? nil
                    : job.snapshot.prompt
                convertedResult.text = try OutputContractValidator.validate(
                    text: convertedResult.text,
                    path: transcriptURL.path,
                    prompt: validationPrompt
                )
                try AtomicFileWriter.writeText(
                    convertedResult.text,
                    to: transcriptURL
                )
                structuredResults[segmentIndex] = convertedResult

                if let metadataPath = record.metadataPath {
                    let segmentMetadata = CloudTranscriptSegmentMetadata(
                        index: segmentIndex,
                        startSeconds: record.startSeconds,
                        endSeconds: record.endSeconds,
                        result: convertedResult
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [
                        .prettyPrinted,
                        .sortedKeys,
                        .withoutEscapingSlashes
                    ]
                    try AtomicFileWriter.write(
                        try encoder.encode(segmentMetadata),
                        to: URL(fileURLWithPath: metadataPath)
                    )
                }

                try segmentManifest.mark(
                    segmentIndex: segmentIndex,
                    status: .completed,
                    completedEventCount: 1
                )
                try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

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
            try TextFileValidator.readNonEmptyUTF8(
                at: URL(fileURLWithPath: record.outputPath)
            )
        }
        let finalTranscribedText: String
        if let finalizeTranscript {
            finalTranscribedText = await finalizeTranscript(completedSegmentTexts)
        } else {
            finalTranscribedText = completedSegmentTexts.joined(separator: "\n\n")
        }

        try Task.checkCancellation()
        update(.progress(current: 92, total: 100, unit: "percent"))
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

        let metadataOutputURL: URL?
        if writesMetadata {
            let segments = completedSegments.compactMap { record -> CloudTranscriptSegmentMetadata? in
                guard let result = structuredResults[record.segmentIndex] else {
                    return nil
                }
                return CloudTranscriptSegmentMetadata(
                    index: record.segmentIndex,
                    startSeconds: record.startSeconds,
                    endSeconds: record.endSeconds,
                    result: result
                )
            }
            guard segments.count == completedSegments.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let sidecar = CloudTranscriptMetadata(
                provider: job.snapshot.backendType,
                modelID: descriptor.id,
                transport: descriptor.transport,
                mode: job.snapshot.transcriptionOptions.mode,
                requestedLanguageCodes: job.snapshot.resolvedLanguageCodes,
                segments: segments
            )
            metadataOutputURL = try writeUniqueMetadata(
                sidecar,
                alongside: finalOutputURL
            )
        } else {
            metadataOutputURL = nil
        }

        update(.progress(current: 100, total: 100, unit: "percent"))
        update(
            .log(
                level: "info",
                message: "轉錄完成！已儲存至：\(finalOutputURL.lastPathComponent)"
            )
        )
        if let metadataOutputURL {
            update(
                .log(
                    level: "info",
                    message: "詳細說話者／時間資料已儲存至：\(metadataOutputURL.lastPathComponent)"
                )
            )
        }
        update(.stage(.completed))
        return PipelineResult(
            outputURL: finalOutputURL,
            rawOutputURL: nil,
            metadataOutputURL: metadataOutputURL,
            duration: Date().timeIntervalSince(startedAt),
            containsSkippedAudio: false
        )
    }

    private func convertCloudResultToTraditional(
        _ result: CloudTranscriptionResult,
        workingDirectory: URL
    ) async throws -> CloudTranscriptionResult {
        let sourceStrings = [result.text]
            + result.words.map(\.text)
            + result.speakerTurns.map(\.text)
        let converted = try await convertStringsToTraditional(
            sourceStrings,
            workingDirectory: workingDirectory
        )
        guard converted.count == sourceStrings.count,
              let transcript = converted.first else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var cursor = 1
        var copy = result
        copy.text = transcript
        copy.words = result.words.map { word in
            defer { cursor += 1 }
            return TimedWord(
                text: converted[cursor],
                speaker: word.speaker,
                startSeconds: word.startSeconds,
                endSeconds: word.endSeconds,
                segmentIndex: word.segmentIndex
            )
        }
        copy.speakerTurns = result.speakerTurns.map { turn in
            defer { cursor += 1 }
            return SpeakerTurn(
                speaker: turn.speaker,
                text: converted[cursor],
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                segmentIndex: turn.segmentIndex
            )
        }
        return copy
    }

    private func convertStringsToTraditional(
        _ values: [String],
        workingDirectory: URL
    ) async throws -> [String] {
        guard !values.isEmpty else { return [] }
        let identifier = UUID().uuidString
        let source = workingDirectory.appendingPathComponent(
            "cloud-opencc-\(identifier).json"
        )
        let destination = workingDirectory.appendingPathComponent(
            "cloud-opencc-\(identifier)-traditional.json"
        )
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try AtomicFileWriter.write(
            try JSONEncoder().encode(values),
            to: source
        )
        try await openCCService.convert(
            sourceURL: source,
            destinationURL: destination
        )
        return try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: destination)
        )
    }

    private func writeUniqueMetadata(
        _ metadata: CloudTranscriptMetadata,
        alongside transcriptURL: URL
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(metadata)
        let directory = transcriptURL.deletingLastPathComponent()
        let base = transcriptURL.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let name = index == 1
                ? "\(base).json"
                : "\(base)_metadata_\(index).json"
            let candidate = directory.appendingPathComponent(name)
            do {
                try AtomicFileWriter.writeNew(data, to: candidate)
                return candidate
            } catch AtomicFileWriterError.destinationExists {
                index += 1
            }
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
                    failureMessage: sourceRecord.failureMessage
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
            segments: recoveredRecords
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
