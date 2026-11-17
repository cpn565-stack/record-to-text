import Foundation

/// Builds the generation configuration shared by the Gemini cloud transports.
/// Keeps the picker, saved preferences and both REST transports on the same
/// model capabilities. Unknown models keep a max-output-only configuration.
public enum GeminiGenerationConfig {
    public static func supportedThinkingLevels(modelID: String) -> [GeminiThinkingLevel] {
        if modelID == "gemini-4-hydrogen" { return [.low, .medium, .high, .xhigh] }
        if modelID == "gemini-3.5-transcribe" { return [] }
        if modelID.hasPrefix("gemini-3.") || modelID == "gemini-4-argon" || modelID == "gemini-4-carbon" {
            return [.low, .medium, .high]
        }
        return []
    }

    public static func defaultThinkingLevel(modelID: String) -> GeminiThinkingLevel {
        modelID == "gemini-4-hydrogen" ? .xhigh : .high
    }

    /// Protect direct callers and old/custom settings as well as model switching.
    public static func resolvedThinkingLevel(
        _ level: GeminiThinkingLevel, modelID: String
    ) -> GeminiThinkingLevel {
        level == .xhigh && modelID != "gemini-4-hydrogen" ? .high : level
    }

    /// Direct, non-streaming REST limits (not SDK/Interactions limits).
    /// Argon rejects >32K without continuation; long recordings use the existing
    /// adaptive audio splitting instead of long decode. Hydrogen supports 64K
    /// in one foreground request, including thinking tokens. Verified 2026-11-13:
    /// https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/4-hydrogen
    public static func transcriptionOutputTokens(modelID: String) -> Int {
        switch modelID {
        case "gemini-4-argon", "gemini-4-carbon":
            return 32_768
        case "gemini-4-hydrogen", "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash":
            return 65_536
        default:
            return 16_384
        }
    }

    public static func requestTimeout(modelID: String) -> TimeInterval {
        usesExtendedBudget(modelID: modelID) ? 1_200 : 300
    }

    /// Hydrogen's optional summary also needs room for thinking before text.
    public static func summaryOutputTokens(modelID: String) -> Int {
        modelID == "gemini-4-hydrogen" ? 65_536 : 2_048
    }

    /// Includes preparation and retries; shared by all adaptive children.
    public static func segmentBudget(modelID: String) -> Duration {
        usesExtendedBudget(modelID: modelID) ? .seconds(1_800) : .seconds(900)
    }

    private static func usesExtendedBudget(modelID: String) -> Bool {
        ["gemini-4-argon", "gemini-4-carbon", "gemini-4-hydrogen"].contains(modelID)
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
