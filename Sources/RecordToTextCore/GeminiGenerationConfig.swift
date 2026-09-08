import Foundation

/// Builds the generation configuration shared by the Gemini cloud transports.
/// Gemini 3.x accepts the string thinking-level setting; unknown/custom model
/// IDs keep the conservative max-output-only configuration.
public enum GeminiGenerationConfig {
    /// Published output limits for the supported Flash models. Custom models
    /// retain the conservative limit until their capabilities are known.
    public static func transcriptionOutputTokens(modelID: String) -> Int {
        switch modelID {
        case "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash":
            return 65_536
        default:
            return 16_384
        }
    }

    public static func make(
        maxOutputTokens: Int,
        modelID: String,
        thinkingLevel: GeminiThinkingLevel
    ) -> [String: Any] {
        var config: [String: Any] = [
            "maxOutputTokens": maxOutputTokens
        ]
        if modelID.hasPrefix("gemini-3.") {
            config["thinkingConfig"] = [
                "thinkingLevel": thinkingLevel.rawValue
            ]
        }
        return config
    }
}
