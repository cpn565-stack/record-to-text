import Foundation

/// Builds the generation configuration shared by the Gemini cloud transports.
/// Gemini 3.x and Argon accept the string thinking-level setting; unknown/custom model
/// IDs keep the conservative max-output-only configuration.
public enum GeminiGenerationConfig {
    /// Direct, non-streaming REST limits (not SDK/Interactions limits).
    /// Argon rejects >32K without continuation; long recordings use the existing
    /// adaptive audio splitting instead of long decode. Verified 2026-10-15:
    /// https://ai.google.dev/gemini-api/docs/generate-content/long-decode
    public static func transcriptionOutputTokens(modelID: String) -> Int {
        switch modelID {
        case "gemini-4-argon":
            return 32_768
        case "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash":
            return 65_536
        default:
            return 16_384
        }
    }

    public static func requestTimeout(modelID: String) -> TimeInterval {
        modelID == "gemini-4-argon" ? 1_200 : 300
    }

    /// Includes preparation and retries; shared by all adaptive children.
    public static func segmentBudget(modelID: String) -> Duration {
        modelID == "gemini-4-argon" ? .seconds(1_800) : .seconds(900)
    }

    public static func make(
        maxOutputTokens: Int,
        modelID: String,
        thinkingLevel: GeminiThinkingLevel,
        includeThoughts: Bool = false
    ) -> [String: Any] {
        var config: [String: Any] = [
            "maxOutputTokens": maxOutputTokens
        ]
        if modelID.hasPrefix("gemini-3.") || modelID == "gemini-4-argon" {
            var thinkingConfig: [String: Any] = [
                "thinkingLevel": thinkingLevel.rawValue
            ]
            if includeThoughts {
                thinkingConfig["includeThoughts"] = true
            }
            config["thinkingConfig"] = thinkingConfig
        }
        return config
    }
}
