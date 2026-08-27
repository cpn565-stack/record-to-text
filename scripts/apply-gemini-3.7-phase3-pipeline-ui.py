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


def replace_between(
    content: str,
    start_marker: str,
    end_marker: str,
    replacement: str,
    label: str,
) -> str:
    start = content.find(start_marker)
    if start < 0:
        raise RuntimeError(f"{label}: start marker not found")
    end = content.find(end_marker, start)
    if end < 0:
        raise RuntimeError(f"{label}: end marker not found")
    return content[:start] + replacement + content[end:]


# ---------------------------------------------------------------------------
# Pipeline: detailed cloud results, honest progress, OpenCC, provenance.
# ---------------------------------------------------------------------------
engine_path = "Sources/RecordToTextCore/TranscriptionEngine.swift"
engine = read(engine_path)
cloud_region = r'''    private func runGoogleAIStudioPipeline(
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
        ) { audioData, timeOffset, segmentLabel in
            try await self.transcribeGoogleAIStudioWithStatus(
                audioData: audioData,
                job: job,
                modelDisplay: "\(modelDisplay)\(segmentLabel)",
                timeOffset: timeOffset,
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
                customPrompt: job.snapshot.prompt,
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
            transcribe: { audioData, timeOffset, segmentLabel in
                try await self.transcribeVertexWithStatus(
                    audioData: audioData,
                    job: job,
                    modelDisplay: "\(modelDisplay)\(segmentLabel)",
                    timeOffset: timeOffset,
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
                customPrompt: job.snapshot.prompt,
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
            _ segmentLabel: String
        ) async throws -> CloudTranscriptionResult
    ) async throws -> PipelineResult {
        let fileManager = FileManager.default
        let segmentPlan = try AudioSegmentPlanner.makePlan(
            sourceDuration: metadata.duration,
            maximumSegmentDuration: maximumASRSegmentDuration
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
                return AudioSegmentRecord(
                    segmentIndex: segment.index,
                    segmentCount: totalSegments,
                    startSeconds: sourceTimeOffset + segment.startSeconds,
                    endSeconds: sourceTimeOffset + segment.endSeconds,
                    audioPath: audioURL.path,
                    outputPath: transcriptURL.path
                )
            }
        )
        try writeSegmentManifest(segmentManifest, to: segmentManifestURL)

        if segmentPlan.requiresSplitting {
            update(
                .log(
                    level: "info",
                    message: "音檔超過單段上限，將以最多 \(Int(maximumASRSegmentDuration / 60)) 分鐘切成 \(totalSegments) 段；每段完成後會立即建立可取回的救援檢查點。"
                )
            )
        }

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
            let waitingUnit = totalSegments > 1
                ? "waiting|\(segmentIndex)|\(totalSegments)"
                : "waiting"

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
                    segmentLabel
                )
                let validatedText = try OutputContractValidator.validate(
                    text: result.text,
                    path: transcriptURL.path,
                    prompt: job.snapshot.prompt
                )
                try AtomicFileWriter.writeText(validatedText, to: transcriptURL)
                segmentManifest.segments[segmentIndex - 1].cloudMetadata =
                    result.metadata
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

'''
engine = replace_between(
    engine,
    "    private func runGoogleAIStudioPipeline(\n",
    "    private func writeUniqueText(\n",
    cloud_region,
    "cloud pipeline region",
)
write(engine_path, engine)


# ---------------------------------------------------------------------------
# Runtime: cloud output now requires OpenCC so the UI promise is enforceable.
# ---------------------------------------------------------------------------
runtime_path = "Sources/RecordToTextCore/RuntimeEnvironment.swift"
runtime = read(runtime_path)
runtime = replace_once(
    runtime,
    "        if settings.developerMode {\n            isDeveloperRuntime = true\n            let discovery = developerRuntimeDiscovery ?? discoverDeveloperRuntime(\n                fileManager: fileManager\n            )\n",
    "        let discovery = developerRuntimeDiscovery ?? discoverDeveloperRuntime(\n            fileManager: fileManager\n        )\n\n        if settings.developerMode {\n            isDeveloperRuntime = true\n",
    "runtime discovery reuse",
)
runtime = replace_once(
    runtime,
    "        } else {\n            isDeveloperRuntime = false\n            python = releaseBin.appendingPathComponent(\"python\")\n            opencc = releaseBin.appendingPathComponent(\"opencc\")\n            helper = releaseBin.appendingPathComponent(releaseHelperName)\n            managedComponents.formUnion([.python, .opencc, .helper])\n        }\n",
    "        } else {\n            isDeveloperRuntime = false\n            python = releaseBin.appendingPathComponent(\"python\")\n            helper = releaseBin.appendingPathComponent(releaseHelperName)\n            if settings.backendType == .localQwen {\n                opencc = releaseBin.appendingPathComponent(\"opencc\")\n                managedComponents.formUnion([.python, .opencc, .helper])\n            } else {\n                // Cloud backends use the locally discovered OpenCC only for\n                // deterministic Taiwan-Traditional post-processing.\n                opencc = discovery.openCC\n                managedComponents.formUnion([.python, .helper])\n            }\n        }\n",
    "runtime cloud opencc selection",
)
runtime = replace_once(
    runtime,
    "        if backendType == .vertexAI {\n            let gcloudURL = runtime.gcloud\n                ?? GCloudAuthService(customGCloudPath: customGCloudPath)\n                    .resolveGCloudURL(fileManager: fileManager)\n            pairs.append((.gcloud, gcloudURL))\n        } else if backendType == .localQwen {\n",
    "        if backendType == .vertexAI {\n            pairs.append((.opencc, runtime.opencc))\n            let gcloudURL = runtime.gcloud\n                ?? GCloudAuthService(customGCloudPath: customGCloudPath)\n                    .resolveGCloudURL(fileManager: fileManager)\n            pairs.append((.gcloud, gcloudURL))\n        } else if backendType == .localQwen {\n",
    "vertex inspect opencc",
)
runtime = replace_once(
    runtime,
    "        } else if backendType == .googleAIStudio {\n            // Google AI Studio API 僅需 ffmpeg/ffprobe 進行音訊壓縮與切片\n        }\n",
    "        } else if backendType == .googleAIStudio {\n            // Cloud response is post-processed with OpenCC s2twp before output.\n            pairs.append((.opencc, runtime.opencc))\n        }\n",
    "AI Studio inspect opencc",
)
runtime = replace_once(
    runtime,
    "        case .googleAIStudio:\n            return [.ffmpeg, .ffprobe]\n        case .vertexAI:\n            return [.ffmpeg, .ffprobe, .gcloud]\n",
    "        case .googleAIStudio:\n            return [.ffmpeg, .ffprobe, .opencc]\n        case .vertexAI:\n            return [.ffmpeg, .ffprobe, .opencc, .gcloud]\n",
    "cloud required opencc",
)
write(runtime_path, runtime)


# ---------------------------------------------------------------------------
# App model: snapshot quality controls and persist actual cloud metadata.
# ---------------------------------------------------------------------------
vm_path = "Sources/RecordToTextApp/AppViewModel.swift"
vm = read(vm_path)
vm = replace_once(
    vm,
    "                vertexAIGCSBucket: settings.vertexAIGCSBucket,\n                vertexAIIncludeSummary: settings.vertexAIIncludeSummary\n",
    "                vertexAIGCSBucket: settings.vertexAIGCSBucket,\n                vertexAIIncludeSummary: settings.vertexAIIncludeSummary,\n                geminiThinkingLevel: settings.geminiThinkingLevel,\n                cloudFallbackPolicy: settings.cloudFallbackPolicy,\n                silenceAwareCloudSegmentation:\n                    settings.silenceAwareCloudSegmentation\n",
    "snapshot cloud quality settings",
)
vm = replace_once(
    vm,
    "                jobs[index].rawOutputPath = result.rawOutputURL?.path\n                jobs[index].completedAt = Date()\n                let duration = Self.durationFormatter.string(from: result.duration) ?? \"—\"\n",
    "                jobs[index].rawOutputPath = result.rawOutputURL?.path\n                jobs[index].cloudSegmentMetadata =\n                    result.cloudSegmentMetadata.isEmpty\n                        ? nil\n                        : result.cloudSegmentMetadata\n                jobs[index].completedAt = Date()\n                jobs[index].progressUnit = nil\n                appendCloudResultSummary(result, to: index)\n                let duration = Self.durationFormatter.string(from: result.duration) ?? \"—\"\n",
    "persist cloud metadata",
)
insert_marker = "    private func markCancelled(_ id: UUID, error: Error) {\n"
helper = r'''    private func appendCloudResultSummary(
        _ result: PipelineResult,
        to index: Int
    ) {
        let metadata = result.cloudSegmentMetadata
        guard !metadata.isEmpty else {
            return
        }
        let effectiveModels = CloudTranscriptionMetadataAggregator
            .uniqueEffectiveModelIDs(metadata)
        let retries = CloudTranscriptionMetadataAggregator
            .totalRetryCount(metadata)
        let usage = CloudTranscriptionMetadataAggregator.totalUsage(metadata)
        var parts = ["實際模型：\(effectiveModels.joined(separator: ", "))"]
        if retries > 0 {
            parts.append("總重試 \(retries) 次")
        }
        if let total = usage?.totalTokenCount {
            parts.append("總 token \(total)")
        }
        if let thoughts = usage?.thoughtsTokenCount {
            parts.append("thinking token \(thoughts)")
        }
        jobs[index].logLines.append(parts.joined(separator: "；") + "。")
    }

'''
if insert_marker not in vm:
    raise RuntimeError("AppViewModel result summary insertion marker not found")
vm = vm.replace(insert_marker, helper + insert_marker, 1)
write(vm_path, vm)


# ---------------------------------------------------------------------------
# Settings UI: thinking, fallback, silence-aware segmentation, 16K disclosure.
# ---------------------------------------------------------------------------
settings_path = "Sources/RecordToTextApp/SettingsView.swift"
settings = read(settings_path)
cloud_controls = r'''                if viewModel.settings.backendType != .localQwen {
                    Divider()

                    Picker(
                        "Gemini 3.7 思考強度",
                        selection: setting(\.geminiThinkingLevel)
                    ) {
                        ForEach(GeminiThinkingLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    Text("預設使用 Medium。Low 可用來做速度／品質 A/B；每個工作加入佇列時會鎖定當下設定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(
                        "模型不可用時",
                        selection: setting(\.cloudFallbackPolicy)
                    ) {
                        ForEach(CloudFallbackPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    Text("預設不自動換模型，避免同一份長錄音混用不同模型。允許 fallback 時只會從 3.7 改用 3.6 Flash，不會自動改用 Pro。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "在 20 分鐘上限前優先尋找靜音切點",
                        isOn: setting(\.silenceAwareCloudSegmentation)
                    )
                    Text("目前先保存此工作設定；靜音偵測與切點調整會在本分支下一階段接入。沒有可用靜音時仍採 20 分鐘硬切。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("雲端單段輸出上限") {
                        Text("16,384 tokens")
                            .foregroundStyle(.secondary)
                    }
                    Text("Cloud 最終稿會在本機經 OpenCC s2twp 統一成台灣繁體，因此環境檢查會要求 OpenCC。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

'''
settings = replace_once(
    settings,
    "                if viewModel.settings.backendType == .localQwen {\n                    localQwenModelSettings\n                }\n",
    cloud_controls + "                if viewModel.settings.backendType == .localQwen {\n                    localQwenModelSettings\n                }\n",
    "cloud quality settings UI",
)
settings = settings.replace(
    "Google AI Studio API 僅需 ffmpeg/ffprobe",
    "Google AI Studio API 需要 ffmpeg/ffprobe，並以 OpenCC 統一台灣繁體",
)
write(settings_path, settings)


# ---------------------------------------------------------------------------
# Main UI: honest indeterminate cloud stage and visible provenance.
# ---------------------------------------------------------------------------
main_path = "Sources/RecordToTextApp/MainView.swift"
main = read(main_path)
main = replace_once(
    main,
    "            progressSection\n            failureSection\n            logSection\n",
    "            progressSection\n            cloudMetadataSection\n            failureSection\n            logSection\n",
    "job row cloud metadata section",
)
progress_old = '''    @ViewBuilder
    private var progressSection: some View {
        if let current = job.progressCurrent,
           let total = job.progressTotal,
           total > 0 {
            ProgressView(value: min(current, total), total: total) {
                Text(progressLabel(current: current, total: total, unit: job.progressUnit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .animation(.easeInOut(duration: 0.2), value: current)
        } else if job.id == viewModel.activeJobID {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(job.stage.displayName)
        }
    }

'''
progress_new = '''    @ViewBuilder
    private var progressSection: some View {
        if job.progressUnit?.hasPrefix("waiting") == true,
           job.id == viewModel.activeJobID {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text(waitingProgressLabel(job.progressUnit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(waitingProgressLabel(job.progressUnit))
        } else if let current = job.progressCurrent,
                  let total = job.progressTotal,
                  total > 0 {
            ProgressView(value: min(current, total), total: total) {
                Text(progressLabel(current: current, total: total, unit: job.progressUnit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .animation(.easeInOut(duration: 0.2), value: current)
        } else if job.id == viewModel.activeJobID {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(job.stage.displayName)
        }
    }

    private func waitingProgressLabel(_ unit: String?) -> String {
        let parts = (unit ?? "").split(separator: "|")
        if parts.count == 3 {
            return "等待 Gemini 回應 · 第 \(parts[1])／\(parts[2]) 段（無虛構百分比）"
        }
        return "等待 Gemini 回應（無虛構百分比）"
    }

    @ViewBuilder
    private var cloudMetadataSection: some View {
        if job.snapshot.backendType != .localQwen {
            let metadata = job.resolvedCloudSegmentMetadata
            VStack(alignment: .leading, spacing: 3) {
                Text(job.cloudModelSummary ?? job.snapshot.requestedModelID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !metadata.isEmpty {
                    let usage = CloudTranscriptionMetadataAggregator
                        .totalUsage(metadata)
                    let retries = CloudTranscriptionMetadataAggregator
                        .totalRetryCount(metadata)
                    HStack(spacing: 8) {
                        if let total = usage?.totalTokenCount {
                            Text("總 token \(total)")
                        }
                        if let thoughts = usage?.thoughtsTokenCount {
                            Text("thinking \(thoughts)")
                        }
                        if retries > 0 {
                            Text("重試 \(retries)")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

'''
main = replace_once(main, progress_old, progress_new, "honest progress UI")
main = replace_once(
    main,
    "                    if let glossaryName = summary.glossaryName {\n                        Text(\"・\\(glossaryName)\")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                    }\n",
    "                    if let glossaryName = summary.glossaryName {\n                        Text(\"・\\(glossaryName)\")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                    }\n                    if let cloudModel = summary.cloudModelSummary {\n                        Text(\"・\\(cloudModel)\")\n                            .font(.caption.monospaced())\n                            .foregroundStyle(.secondary)\n                            .lineLimit(1)\n                    }\n",
    "recent model provenance UI",
)
write(main_path, main)


# ---------------------------------------------------------------------------
# Runtime tests: explicitly provide cloud OpenCC fixtures and new expectations.
# ---------------------------------------------------------------------------
test_path = "Tests/RecordToTextCoreTests/RuntimeEnvironmentTests.swift"
tests = read(test_path)
tests = replace_once(
    tests,
    "        let bundled = try makeBundledAudioTools(in: root)\n\n        let runtime = try RuntimeEnvironment.resolve(\n",
    "        let bundled = try makeBundledAudioTools(in: root)\n        let cloudDiscovery = try makeCloudDiscovery(in: root)\n\n        let runtime = try RuntimeEnvironment.resolve(\n",
    "first cloud discovery",
)
tests = replace_once(
    tests,
    "            bundledFFprobeURL: bundled.ffprobe,\n            includeSystemAudioTools: false\n        )\n",
    "            bundledFFprobeURL: bundled.ffprobe,\n            includeSystemAudioTools: false,\n            developerRuntimeDiscovery: cloudDiscovery\n        )\n",
    "first cloud resolve discovery",
)
# Second cloud candidate test.
tests = replace_once(
    tests,
    "        let bundled = try makeBundledAudioTools(in: root)\n\n        let runtime = RuntimeEnvironment.candidate(\n",
    "        let bundled = try makeBundledAudioTools(in: root)\n        let cloudDiscovery = try makeCloudDiscovery(in: root)\n\n        let runtime = RuntimeEnvironment.candidate(\n",
    "second cloud discovery",
)
tests = replace_once(
    tests,
    "            bundledFFprobeURL: bundled.ffprobe,\n            includeSystemAudioTools: false\n        )\n\n        XCTAssertEqual(runtime.ffmpeg.path, bundled.ffmpeg.path)\n",
    "            bundledFFprobeURL: bundled.ffprobe,\n            includeSystemAudioTools: false,\n            developerRuntimeDiscovery: cloudDiscovery\n        )\n\n        XCTAssertEqual(runtime.ffmpeg.path, bundled.ffmpeg.path)\n",
    "second cloud candidate discovery",
)
# Missing components expectation now includes OpenCC.
tests = replace_once(
    tests,
    "                [.ffmpeg, .ffprobe]\n",
    "                [.ffmpeg, .ffprobe, .opencc]\n",
    "cloud missing components expectation",
)
# Inspection fixture creates executable OpenCC and expects it.
tests = replace_once(
    tests,
    "        let runtime = ResolvedRuntime(\n            python: root.appendingPathComponent(\"python\"),\n            ffmpeg: bundled.ffmpeg,\n            ffprobe: bundled.ffprobe,\n            opencc: root.appendingPathComponent(\"opencc\"),\n",
    "        let openCC = root.appendingPathComponent(\"opencc\")\n        try makeExecutable(at: openCC)\n        let runtime = ResolvedRuntime(\n            python: root.appendingPathComponent(\"python\"),\n            ffmpeg: bundled.ffmpeg,\n            ffprobe: bundled.ffprobe,\n            opencc: openCC,\n",
    "cloud inspection opencc executable",
)
tests = replace_once(
    tests,
    "        XCTAssertEqual(report.components.map(\\.component), [.ffmpeg, .ffprobe])\n",
    "        XCTAssertEqual(\n            report.components.map(\\.component),\n            [.ffmpeg, .ffprobe, .opencc]\n        )\n",
    "cloud inspection components",
)
# Managed cloud tests should assert OpenCC is also verified.
tests = replace_once(
    tests,
    "                XCTAssertTrue(resolved.managedComponents.contains(.ffprobe))\n",
    "                XCTAssertTrue(resolved.managedComponents.contains(.ffprobe))\n                // Cloud OpenCC is developer-discovered, not a managed component.\n",
    "cloud verifier comment",
)
# Helper for deterministic cloud discovery.
helper_marker = "    private func makeBundledAudioTools(in root: URL) throws -> (ffmpeg: URL, ffprobe: URL) {\n"
cloud_helper = '''    private func makeCloudDiscovery(
        in root: URL
    ) throws -> DeveloperRuntimeDiscovery {
        let openCC = root.appendingPathComponent("cloud-tools/opencc")
        try makeExecutable(at: openCC)
        return DeveloperRuntimeDiscovery(
            python: root.appendingPathComponent("unused-python"),
            openCC: openCC,
            pythonWasDetected: false,
            openCCWasDetected: true
        )
    }

'''
if helper_marker not in tests:
    raise RuntimeError("runtime test helper marker missing")
tests = tests.replace(helper_marker, cloud_helper + helper_marker, 1)
write(test_path, tests)


# Pipeline metadata utility tests.
pipeline_tests = r'''import Foundation
import XCTest
@testable import RecordToTextCore

final class CloudPipelinePresentationTests: XCTestCase {
    func testJobCloudSummaryDistinguishesRequestedAndEffectiveModels() {
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
        let job = TranscriptionJob(
            sourcePath: "/tmp/audio.m4a",
            snapshot: snapshot,
            cloudSegmentMetadata: [
                CloudTranscriptionMetadata(
                    requestedModelID: "gemini-3.7-flash",
                    effectiveModelID: "gemini-3.7-flash"
                ),
                CloudTranscriptionMetadata(
                    requestedModelID: "gemini-3.7-flash",
                    effectiveModelID: "gemini-3.6-flash",
                    fallbackReason: "HTTP 503"
                )
            ]
        )

        XCTAssertEqual(
            job.cloudModelSummary,
            "要求：gemini-3.7-flash；實際：gemini-3.7-flash, gemini-3.6-flash"
        )
    }

    func testCloudSnapshotCapturesQualityControls() throws {
        let snapshot = JobSnapshot(
            modelID: "local-placeholder",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "prompt",
            outputLocationMode: .sameAsSource,
            outputDirectory: "",
            keepRawTranscript: false,
            backendType: .vertexAI,
            vertexAIModelID: "gemini-3.7-flash",
            geminiThinkingLevel: .low,
            cloudFallbackPolicy: .flashOnly,
            silenceAwareCloudSegmentation: false
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(JobSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.geminiThinkingLevel, .low)
        XCTAssertEqual(decoded.cloudFallbackPolicy, .flashOnly)
        XCTAssertFalse(decoded.silenceAwareCloudSegmentation)
    }
}
'''
write(
    "Tests/RecordToTextCoreTests/CloudPipelinePresentationTests.swift",
    pipeline_tests,
)

print("Applied Gemini 3.7 pipeline, OpenCC, honest progress, and UI phase")
