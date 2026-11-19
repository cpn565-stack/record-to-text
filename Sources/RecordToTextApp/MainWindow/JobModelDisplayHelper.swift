import Foundation
import RecordToTextCore

/// UI-only human-friendly backend, model, and duration formatters.
/// Never mutates Core persistence contracts or `JobDebugClipboard` output.
enum JobModelDisplayHelper {
    static func shortBackendName(_ backend: ASRBackendType) -> String {
        switch backend {
        case .googleAIStudio:
            return "AI Studio"
        case .vertexAI:
            return "Vertex AI"
        case .localQwen:
            return "本機 Qwen"
        }
    }

    static func backendIcon(_ backend: ASRBackendType) -> String {
        switch backend {
        case .localQwen:
            return CPUArchitecture.current == .x86_64 ? "cpu" : "apple.logo"
        case .googleAIStudio, .vertexAI:
            return "cloud.fill"
        }
    }

    private static let legacyCloudDisplayNames: [String: String] = [
        "gemini-3.8-flash": "Gemini 3.8 Flash",
        "gemini-3.7-flash": "Gemini 3.7 Flash",
        "gemini-3.6-flash": "Gemini 3.6 Flash",
        "gemini-3.1-pro-preview": "Gemini 3.1 Pro",
        "gemini-3.5-transcribe": "Gemini 3.5 Transcribe"
    ]

    static func shortModelName(modelID: String, backend: ASRBackendType?) -> String {
        if backend == .localQwen {
            return ASRModelDescriptor.descriptor(id: modelID)?.displayName ?? modelID
        }
        if let preset = GeminiModelDescriptor.presetModels.first(where: { $0.id == modelID }) {
            return preset.displayName
        }
        if let legacy = legacyCloudDisplayNames[modelID] {
            return legacy
        }
        if let local = ASRModelDescriptor.descriptor(id: modelID) {
            return local.displayName
        }
        return modelID
    }

    static func currentModelShortName(_ settings: AppSettings) -> String {
        switch settings.backendType {
        case .googleAIStudio:
            return shortModelName(modelID: settings.googleAIStudioModelID, backend: .googleAIStudio)
        case .vertexAI:
            return shortModelName(modelID: settings.vertexAIModelID, backend: .vertexAI)
        case .localQwen:
            return shortModelName(modelID: settings.selectedModelID, backend: .localQwen)
        }
    }

    static func currentEngineSummary(_ settings: AppSettings) -> String {
        "\(shortBackendName(settings.backendType)) · \(currentModelShortName(settings))"
    }

    static func choiceMenuTitle(_ choice: QuickTranscriptionChoice) -> String {
        switch choice {
        case .qwen3ASR1_7BBF16:
            return "Qwen3-ASR 1.7B BF16"
        case .aiStudioGemini4Neon, .vertexGemini4Neon:
            return "Gemini 4 Neon"
        case .aiStudioGemini4Hydrogen, .vertexGemini4Hydrogen:
            return "Gemini 4 Hydrogen"
        case .aiStudioGemini4Carbon, .vertexGemini4Carbon:
            return "Gemini 4 Carbon"
        case .aiStudioGemini4Argon, .vertexGemini4Argon:
            return "Gemini 4 Argon"
        }
    }

    static func displayModelLabel(for job: TranscriptionJob) -> String {
        let backend = job.snapshot.backendType
        if backend == .localQwen {
            return shortModelName(modelID: job.snapshot.modelID, backend: .localQwen)
        }
        let requested = job.snapshot.requestedModelID
        let effective = CloudTranscriptionMetadataAggregator.uniqueEffectiveModelIDs(
            job.resolvedCloudSegmentMetadata
        )
        return formatCloudModelLabel(
            requestedModelID: requested,
            effectiveModelIDs: effective,
            backend: backend
        )
    }

    static func displayModelLabel(for summary: RecentJobSummary) -> String {
        if summary.backendType == .localQwen {
            return shortModelName(modelID: summary.modelID, backend: .localQwen)
        }
        return formatCloudModelLabel(
            requestedModelID: summary.modelID,
            effectiveModelIDs: summary.effectiveModelIDs ?? [],
            backend: summary.backendType
        )
    }

    static func displayBackendAndModel(for job: TranscriptionJob) -> String {
        "\(shortBackendName(job.snapshot.backendType)) · \(displayModelLabel(for: job))"
    }

    static func displayBackendAndModel(for summary: RecentJobSummary) -> String {
        let model = displayModelLabel(for: summary)
        guard let backend = summary.backendType else {
            return model
        }
        return "\(shortBackendName(backend)) · \(model)"
    }

    static func fallbackTooltip(for job: TranscriptionJob) -> String? {
        guard job.snapshot.backendType != .localQwen else { return nil }
        let effective = CloudTranscriptionMetadataAggregator.uniqueEffectiveModelIDs(
            job.resolvedCloudSegmentMetadata
        )
        guard !effective.isEmpty, effective != [job.snapshot.requestedModelID] else {
            return nil
        }
        return job.cloudModelSummary
    }

    static func fallbackTooltip(for summary: RecentJobSummary) -> String? {
        guard summary.backendType != .localQwen,
              let effective = summary.effectiveModelIDs,
              !effective.isEmpty,
              effective != [summary.modelID]
        else {
            return nil
        }
        return summary.cloudModelSummary
    }

    static func formattedDuration(startedAt: Date?, completedAt: Date?) -> String? {
        guard let startedAt, let completedAt else { return nil }
        let seconds = completedAt.timeIntervalSince(startedAt)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let rounded = Int(seconds.rounded())
        if rounded < 1 {
            return "< 1秒"
        }
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let secs = rounded % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)小時\(minutes)分" : "\(hours)小時"
        }
        if minutes > 0 {
            return secs > 0 ? "\(minutes)分\(secs)秒" : "\(minutes)分"
        }
        return "\(secs)秒"
    }

    static func compactOutputFolderSummary(_ settings: AppSettings) -> String {
        switch settings.outputLocationMode {
        case .fixedDirectory:
            let name = URL(fileURLWithPath: settings.defaultOutputDirectory).lastPathComponent
            return name.isEmpty ? settings.defaultOutputDirectory : name
        case .sameAsSource:
            return "與來源同資料夾"
        case .askEveryTime:
            return "每次詢問"
        }
    }

    private static func formatCloudModelLabel(
        requestedModelID: String,
        effectiveModelIDs: [String],
        backend: ASRBackendType?
    ) -> String {
        let requestedDisplay = shortModelName(modelID: requestedModelID, backend: backend)
        guard !effectiveModelIDs.isEmpty, effectiveModelIDs != [requestedModelID] else {
            return requestedDisplay
        }
        let targets = effectiveModelIDs.map { targetID -> String in
            let full = shortModelName(modelID: targetID, backend: backend)
            if requestedDisplay.hasPrefix("Gemini "), full.hasPrefix("Gemini ") {
                return String(full.dropFirst("Gemini ".count))
            }
            return full
        }.joined(separator: ", ")
        return "\(requestedDisplay) → \(targets)"
    }
}
