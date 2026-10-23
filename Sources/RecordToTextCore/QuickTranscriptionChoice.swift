import Foundation

/// Common engine/model combinations exposed by the main-window
/// quick selector. Advanced model choices remain available in Settings.
public enum QuickTranscriptionChoice: String, CaseIterable, Identifiable, Sendable {
    case qwen3ASR1_7BBF16
    case aiStudioGemini4Argon
    case vertexGemini4Argon
    case vertexGemini38Flash
    case aiStudioGemini38Flash
    case vertexGemini37Flash
    case aiStudioGemini37Flash

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3ASR1_7BBF16:
            return "Qwen3-ASR 1.7B BF16"
        case .aiStudioGemini4Argon:
            return "AI Studio (Gemini 4 Argon)"
        case .vertexGemini4Argon:
            return "Vertex AI (Gemini 4 Argon)"
        case .vertexGemini38Flash:
            return "Vertex AI (Gemini 3.8 Flash)"
        case .aiStudioGemini38Flash:
            return "AI Studio (Gemini 3.8 Flash)"
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
        case .vertexGemini4Argon, .vertexGemini38Flash, .vertexGemini37Flash:
            return .vertexAI
        case .aiStudioGemini4Argon, .aiStudioGemini38Flash, .aiStudioGemini37Flash:
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
        case .aiStudioGemini4Argon:
            updated.googleAIStudioModelID = "gemini-4-argon"
        case .vertexGemini4Argon:
            updated.vertexAIModelID = "gemini-4-argon"
        case .vertexGemini38Flash:
            updated.vertexAIModelID = "gemini-3.8-flash"
        case .aiStudioGemini38Flash:
            updated.googleAIStudioModelID = "gemini-3.8-flash"
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
        case .aiStudioGemini4Argon:
            return settings.googleAIStudioModelID == "gemini-4-argon"
        case .vertexGemini4Argon:
            return settings.vertexAIModelID == "gemini-4-argon"
        case .vertexGemini38Flash:
            return settings.vertexAIModelID == "gemini-3.8-flash"
        case .aiStudioGemini38Flash:
            return settings.googleAIStudioModelID == "gemini-3.8-flash"
        case .vertexGemini37Flash:
            return settings.vertexAIModelID == "gemini-3.7-flash"
        case .aiStudioGemini37Flash:
            return settings.googleAIStudioModelID == "gemini-3.7-flash"
        }
    }
}
