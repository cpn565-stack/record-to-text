import Foundation

/// Only protocol values may be persisted; even an ASCII identifier can contain private text.
enum GeminiDiagnosticCode {
    static let safety: Set<String> = ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "IMAGE_SAFETY", "SPII", "MODEL_ARMOR"]
    static let known: Set<String> = safety.union([
        "STOP", "MAX_TOKENS", "RECITATION", "OTHER", "CONTINUATION",
        "BLOCK_REASON_UNSPECIFIED", "FINISH_REASON_UNSPECIFIED", "MISSING_FINISH_REASON",
        "LANGUAGE", "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS",
        "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER", "NO_IMAGE", "IMAGE_RECITATION",
        "MISSING_THOUGHT_SIGNATURE", "MALFORMED_RESPONSE", "ESCALATION", "PUP_LIMITED_DISABLED",
        "JAILBREAK", "UNKNOWN"
    ])

    static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        return known.contains(normalized) ? normalized : "UNKNOWN"
    }
}
