import Foundation

/// The three common engine/model combinations exposed by the main-window
/// quick selector. Advanced model choices remain available in Settings.
public enum QuickTranscriptionChoice: String, CaseIterable, Identifiable, Sendable {
    case qwen3ASR1_7BBF16
    case vertexGemini37Flash
    case aiStudioGemini37Flash

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3ASR1_7BBF16:
            return "Qwen3-ASR 1.7B BF16"
        case .vertexGemini37Flash:
            return "Vertex AI (Gemini 3.7 Flash)"
        case .aiStudioGemini37Flash:
            return "AI Studio (Gemini 3.7 Flash)"
        }
    }

    public var backendType: ASRBackendType {
        switch self {
        case .qwen3ASR1_7BBF16:
            return .localQwen
        case .vertexGemini37Flash:
            return .vertexAI
        case .aiStudioGemini37Flash:
            return .googleAIStudio
        }
    }

    public func applying(to settings: AppSettings) -> AppSettings {
        var updated = settings
        updated.backendType = backendType
        switch self {
        case .qwen3ASR1_7BBF16:
            updated.selectedModels[CPUArchitecture.current.rawValue] =
                ASRModelDescriptor.appleSiliconBF16.id
        case .vertexGemini37Flash:
            updated.vertexAIModelID = "gemini-3.7-flash"
        case .aiStudioGemini37Flash:
            updated.googleAIStudioModelID = "gemini-3.7-flash"
        }
        return updated
    }

    public func matches(_ settings: AppSettings) -> Bool {
        guard settings.backendType == backendType else {
            return false
        }
        switch self {
        case .qwen3ASR1_7BBF16:
            return settings.selectedModelID == ASRModelDescriptor.appleSiliconBF16.id
        case .vertexGemini37Flash:
            return settings.vertexAIModelID == "gemini-3.7-flash"
        case .aiStudioGemini37Flash:
            return settings.googleAIStudioModelID == "gemini-3.7-flash"
        }
    }
}
