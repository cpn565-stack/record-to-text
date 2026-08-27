import Foundation
import RecordToTextCore

struct ResolvedCloudJobConfiguration: Sendable {
    let descriptor: CloudModelDescriptor
    let options: DedicatedTranscriptionOptions
    let resolvedLanguageCodes: [String]
    let resolvedCustomVocabulary: [String]
    let maximumAudioDurationSeconds: Double
    let recommendedSegmentDurationSeconds: Double

    var usesLargeVocabulary: Bool {
        resolvedCustomVocabulary.count
            > CloudTranscriptionPolicy.recommendedCustomVocabularyCount
    }
}

extension AppViewModel {
    var selectedCloudModelDescriptor: CloudModelDescriptor? {
        switch settings.backendType {
        case .googleAIStudio:
            return CloudModelCatalog.resolvedDescriptor(
                provider: .googleAIStudio,
                modelID: settings.googleAIStudioModelID
            )
        case .vertexAI:
            return CloudModelCatalog.resolvedDescriptor(
                provider: .vertexAI,
                modelID: settings.vertexAIModelID
            )
        case .localQwen:
            return nil
        }
    }

    var selectedCloudTranscriptionOptions: DedicatedTranscriptionOptions {
        switch settings.backendType {
        case .googleAIStudio:
            return settings.googleAIStudioTranscriptionOptions
                .normalizedForUI()
        case .vertexAI:
            return settings.vertexAITranscriptionOptions
                .normalizedForUI()
        case .localQwen:
            return .default
        }
    }

    var selectedCloudModelIsDedicatedTranscribe: Bool {
        selectedCloudModelDescriptor?.isDedicatedTranscription == true
    }

    var selectedCloudPromptBehaviorDescription: String? {
        guard let descriptor = selectedCloudModelDescriptor,
              descriptor.isDedicatedTranscription else {
            return nil
        }
        return "此模型使用專用語音轉文字契約。詞庫會作為 Custom Vocabulary 傳送；一般自由文字 Prompt 不會送給模型。"
    }

    func resolveCloudJobConfiguration(
        terms: [String]
    ) throws -> ResolvedCloudJobConfiguration? {
        guard let descriptor = selectedCloudModelDescriptor else {
            return nil
        }
        let options = selectedCloudTranscriptionOptions
        let vocabulary: [String]
        if descriptor.isDedicatedTranscription {
            vocabulary = try CloudTranscriptionPolicy.normalizedVocabulary(
                terms
            )
            try CloudTranscriptionPolicy.validate(
                descriptor: descriptor,
                options: options,
                vocabulary: vocabulary
            )
        } else {
            vocabulary = []
        }
        return ResolvedCloudJobConfiguration(
            descriptor: descriptor,
            options: options,
            resolvedLanguageCodes: options.resolvedLanguageCodes,
            resolvedCustomVocabulary: vocabulary,
            maximumAudioDurationSeconds:
                descriptor.effectiveMaximumAudioDuration(options: options),
            recommendedSegmentDurationSeconds:
                descriptor.recommendedSegmentDurationSeconds
        )
    }
}
