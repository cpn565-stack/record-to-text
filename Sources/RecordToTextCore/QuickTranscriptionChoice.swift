import Foundation

/// Common engine/model combinations exposed by the main-window
/// quick selector. Advanced model choices remain available in Settings.
public enum QuickTranscriptionChoice: String, CaseIterable, Identifiable, Sendable {
    case qwen3ASR1_7BBF16
    case aiStudioGemini4Neon
    case vertexGemini4Neon
    case aiStudioGemini4Hydrogen
    case vertexGemini4Hydrogen
    case aiStudioGemini4Carbon
    case vertexGemini4Carbon
    case aiStudioGemini4Argon
    case vertexGemini4Argon

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3ASR1_7BBF16:
            return "Qwen3-ASR 1.7B BF16"
        case .aiStudioGemini4Neon:
            return "AI Studio (Gemini 4 Neon)"
        case .vertexGemini4Neon:
            return "Vertex AI (Gemini 4 Neon)"
        case .aiStudioGemini4Hydrogen:
            return "AI Studio (Gemini 4 Hydrogen)"
        case .vertexGemini4Hydrogen:
            return "Vertex AI (Gemini 4 Hydrogen)"
        case .aiStudioGemini4Carbon:
            return "AI Studio (Gemini 4 Carbon)"
        case .vertexGemini4Carbon:
            return "Vertex AI (Gemini 4 Carbon)"
        case .aiStudioGemini4Argon:
            return "AI Studio (Gemini 4 Argon)"
        case .vertexGemini4Argon:
            return "Vertex AI (Gemini 4 Argon)"
        }
    }

    public var backendType: ASRBackendType {
        switch self {
        case .qwen3ASR1_7BBF16:
            return .localQwen
        case .vertexGemini4Neon, .vertexGemini4Hydrogen, .vertexGemini4Carbon, .vertexGemini4Argon:
            return .vertexAI
        case .aiStudioGemini4Neon, .aiStudioGemini4Hydrogen, .aiStudioGemini4Carbon, .aiStudioGemini4Argon:
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
        case .aiStudioGemini4Neon:
            updated.googleAIStudioModelID = "gemini-4-neon"
        case .vertexGemini4Neon:
            updated.vertexAIModelID = "gemini-4-neon"
        case .aiStudioGemini4Hydrogen:
            updated.googleAIStudioModelID = "gemini-4-hydrogen"
        case .vertexGemini4Hydrogen:
            updated.vertexAIModelID = "gemini-4-hydrogen"
        case .aiStudioGemini4Carbon:
            updated.googleAIStudioModelID = "gemini-4-carbon"
        case .vertexGemini4Carbon:
            updated.vertexAIModelID = "gemini-4-carbon"
        case .aiStudioGemini4Argon:
            updated.googleAIStudioModelID = "gemini-4-argon"
        case .vertexGemini4Argon:
            updated.vertexAIModelID = "gemini-4-argon"
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
        case .aiStudioGemini4Neon:
            return settings.googleAIStudioModelID == "gemini-4-neon"
        case .vertexGemini4Neon:
            return settings.vertexAIModelID == "gemini-4-neon"
        case .aiStudioGemini4Hydrogen:
            return settings.googleAIStudioModelID == "gemini-4-hydrogen"
        case .vertexGemini4Hydrogen:
            return settings.vertexAIModelID == "gemini-4-hydrogen"
        case .aiStudioGemini4Carbon:
            return settings.googleAIStudioModelID == "gemini-4-carbon"
        case .vertexGemini4Carbon:
            return settings.vertexAIModelID == "gemini-4-carbon"
        case .aiStudioGemini4Argon:
            return settings.googleAIStudioModelID == "gemini-4-argon"
        case .vertexGemini4Argon:
            return settings.vertexAIModelID == "gemini-4-argon"
        }
    }
}
