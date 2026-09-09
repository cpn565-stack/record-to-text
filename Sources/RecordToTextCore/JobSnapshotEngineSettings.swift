import Foundation

public extension TranscriptionJob {
    func canUpdateQueuedEngine(activeJobID: UUID?) -> Bool {
        stage == .queued && id != activeJobID && startedAt == nil
            && resumeFromRecoveryDirectory == nil
    }
}

public extension JobSnapshot {
    var engineDisplayName: String {
        let model = backendType == .localQwen
            ? ASRModelDescriptor.descriptor(id: modelID)?.displayName ?? modelID
            : requestedModelID
        let backend = backendType == .localQwen ? "本機 Qwen"
            : backendType == .googleAIStudio ? "AI Studio" : "Vertex AI"
        return "\(backend) · \(model)"
    }

    func withEngineSettings(_ settings: AppSettings) -> JobSnapshot {
        JobSnapshot(
            modelID: settings.selectedModelID,
            modelRevision: ASRModelDescriptor.revision(forModelID: settings.selectedModelID),
            language: language, glossaryID: glossaryID, glossaryName: glossaryName,
            terms: terms, prompt: prompt, outputLocationMode: outputLocationMode,
            outputDirectory: outputDirectory, keepRawTranscript: keepRawTranscript,
            outputFilenameSuffix: outputFilenameSuffix, rawFilenameSuffix: rawFilenameSuffix,
            backendType: settings.backendType, googleAIStudioAPIKey: nil,
            googleAIStudioModelID: settings.googleAIStudioModelID,
            vertexAIProjectID: settings.vertexAIProjectID, vertexAILocation: settings.vertexAILocation,
            vertexAIModelID: settings.vertexAIModelID, vertexAIGCSBucket: settings.vertexAIGCSBucket,
            vertexAIIncludeSummary: settings.vertexAIIncludeSummary,
            geminiThinkingLevel: settings.geminiThinkingLevel,
            cloudFallbackPolicy: settings.cloudFallbackPolicy,
            silenceAwareCloudSegmentation: settings.silenceAwareCloudSegmentation)
    }
}
