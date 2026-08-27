import Foundation

/// Builds the generation configuration shared by the Gemini cloud transports.
/// Gemini 3.x accepts the string thinking-level setting; unknown/custom model
/// IDs keep the conservative max-output-only configuration.
public enum GeminiGenerationConfig {
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
