#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "Sources/RecordToTextCore/TranscriptionEngine.swift"
text = path.read_text()

if "private let googleAIStudioTranscribeBackend" in text:
    print("phase 2 already applied")
    raise SystemExit(0)

old = '''    private let googleAIStudioBackend: GoogleAIStudioBackend
    private let vertexAIBackend: VertexAIGeminiBackend
    private let sleepPrevention: SleepPreventionService
'''
new = '''    private let googleAIStudioBackend: GoogleAIStudioBackend
    private let googleAIStudioTranscribeBackend: GoogleAIStudioTranscribeBackend
    private let vertexAIBackend: VertexAIGeminiBackend
    private let agentPlatformTranscribeBackend: AgentPlatformTranscribeBackend
    private let sleepPrevention: SleepPreventionService
'''
if text.count(old) != 1:
    raise RuntimeError("could not patch TranscriptionEngine backend properties")
text = text.replace(old, new, 1)

old = '''        runner: ProcessRunner = ProcessRunner(),
        googleAIStudioBackend: GoogleAIStudioBackend? = nil,
        vertexAIBackend: VertexAIGeminiBackend? = nil,
        sleepPrevention: SleepPreventionService = SleepPreventionService(),
'''
new = '''        runner: ProcessRunner = ProcessRunner(),
        googleAIStudioBackend: GoogleAIStudioBackend? = nil,
        googleAIStudioTranscribeBackend: GoogleAIStudioTranscribeBackend? = nil,
        vertexAIBackend: VertexAIGeminiBackend? = nil,
        agentPlatformTranscribeBackend: AgentPlatformTranscribeBackend? = nil,
        sleepPrevention: SleepPreventionService = SleepPreventionService(),
'''
if text.count(old) != 1:
    raise RuntimeError("could not patch TranscriptionEngine initializer signature")
text = text.replace(old, new, 1)

old = '''        self.backend = HelperASRBackend(runtime: runtime, paths: paths, runner: runner)
        self.googleAIStudioBackend = googleAIStudioBackend ?? GoogleAIStudioBackend()
        self.vertexAIBackend = vertexAIBackend ?? VertexAIGeminiBackend(authService: GCloudAuthService(runner: runner))
        self.sleepPrevention = sleepPrevention
'''
new = '''        self.backend = HelperASRBackend(runtime: runtime, paths: paths, runner: runner)
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
'''
if text.count(old) != 1:
    raise RuntimeError("could not patch TranscriptionEngine initializer body")
text = text.replace(old, new, 1)

start_marker = "    private func runGoogleAIStudioPipeline(\n"
end_marker = "    private func writeUniqueText(\n"
start = text.find(start_marker)
end = text.find(end_marker, start)
if start < 0 or end < 0:
    raise RuntimeError("could not locate cloud pipeline replacement range")

section = r'''    static func effectiveCloudSegmentDuration(
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

'''

text = text[:start] + section + text[end:]
path.write_text(text)
print("phase 2 applied")
