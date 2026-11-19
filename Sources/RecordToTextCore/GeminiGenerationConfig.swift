import Foundation

/// Builds the generation configuration shared by the Gemini cloud transports.
/// Keeps the picker, saved preferences and both REST transports on the same
/// model capabilities. Unknown models keep a max-output-only configuration.
public enum GeminiGenerationConfig {
    public static func supportedThinkingLevels(modelID: String) -> [GeminiThinkingLevel] {
        if supportsXHigh(modelID: modelID) { return [.low, .medium, .high, .xhigh] }
        if modelID.hasPrefix("gemini-3.") || modelID == "gemini-4-argon" || modelID == "gemini-4-carbon" {
            return [.low, .medium, .high]
        }
        return []
    }

    public static func defaultThinkingLevel(modelID: String) -> GeminiThinkingLevel {
        modelID == "gemini-4-hydrogen" ? .xhigh : .high
    }

    /// Models introduced after per-model thinking preferences always start from
    /// their own model default rather than inheriting the legacy global value.
    public static func usesModelDefaultThinkingLevel(modelID: String) -> Bool {
        supportsXHigh(modelID: modelID)
    }

    /// Protect direct callers and old/custom settings as well as model switching.
    public static func resolvedThinkingLevel(
        _ level: GeminiThinkingLevel, modelID: String
    ) -> GeminiThinkingLevel {
        level == .xhigh && !supportsXHigh(modelID: modelID) ? .high : level
    }

    /// Direct, non-streaming REST limits (not SDK/Interactions limits).
    /// Argon rejects >32K without continuation; long recordings use the existing
    /// adaptive audio splitting instead of long decode. Neon and Hydrogen support
    /// 64K in one foreground request, including thinking tokens. Verified:
    /// https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/4-hydrogen
    public static func transcriptionOutputTokens(modelID: String) -> Int {
        switch modelID {
        case "gemini-4-argon", "gemini-4-carbon":
            return 32_768
        case "gemini-4-neon", "gemini-4-hydrogen", "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash":
            return 65_536
        default:
            return 16_384
        }
    }

    public static func requestTimeout(modelID: String) -> TimeInterval {
        usesExtendedBudget(modelID: modelID) ? 1_200 : 300
    }

    /// Thinking-capable models need room for reasoning tokens before emitting
    /// the summary text; Neon and Hydrogen support up to 64K in one request.
    public static func summaryOutputTokens(modelID: String) -> Int {
        if supportsXHigh(modelID: modelID) {
            return 65_536
        }
        if !supportedThinkingLevels(modelID: modelID).isEmpty {
            return 16_384
        }
        return 2_048
    }

    /// Includes preparation and retries; shared by all adaptive children.
    public static func segmentBudget(modelID: String) -> Duration {
        usesExtendedBudget(modelID: modelID) ? .seconds(1_800) : .seconds(900)
    }

    private static func supportsXHigh(modelID: String) -> Bool {
        modelID == "gemini-4-neon" || modelID == "gemini-4-hydrogen"
    }

    private static func usesExtendedBudget(modelID: String) -> Bool {
        ["gemini-4-argon", "gemini-4-carbon", "gemini-4-hydrogen", "gemini-4-neon"].contains(modelID)
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
        if !supportedThinkingLevels(modelID: modelID).isEmpty {
            var thinkingConfig: [String: Any] = [
                "thinkingLevel": resolvedThinkingLevel(thinkingLevel, modelID: modelID).rawValue
            ]
            if includeThoughts {
                thinkingConfig["includeThoughts"] = true
            }
            config["thinkingConfig"] = thinkingConfig
        }
        return config
    }
}
