import Foundation

public enum GeminiResponseMetadataParser {
    public static func makeMetadata(
        from data: Data,
        requestedModelID: String,
        effectiveModelID: String,
        retryCount: Int,
        fallbackReason: String?,
        thinkingLevel: GeminiThinkingLevel,
        latencySeconds: Double
    ) -> CloudTranscriptionMetadata {
        let json = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any]
        let usageObject = json?["usageMetadata"] as? [String: Any]

        func integer(_ key: String) -> Int? {
            if let number = usageObject?[key] as? NSNumber {
                return number.intValue
            }
            return usageObject?[key] as? Int
        }

        let prompt = integer("promptTokenCount")
        let cached = integer("cachedContentTokenCount")
        let candidates = integer("candidatesTokenCount")
        let thoughts = integer("thoughtsTokenCount")
        let total = integer("totalTokenCount")
        let serviceTier = usageObject?["trafficType"] as? String
            ?? json?["serviceTier"] as? String
        let usage: CloudUsageMetadata?
        if prompt == nil,
           cached == nil,
           candidates == nil,
           thoughts == nil,
           total == nil,
           serviceTier == nil {
            usage = nil
        } else {
            usage = CloudUsageMetadata(
                promptTokenCount: prompt,
                cachedContentTokenCount: cached,
                candidatesTokenCount: candidates,
                thoughtsTokenCount: thoughts,
                totalTokenCount: total,
                serviceTier: serviceTier
            )
        }

        return CloudTranscriptionMetadata(
            requestedModelID: requestedModelID,
            effectiveModelID: effectiveModelID,
            modelVersion: json?["modelVersion"] as? String,
            responseID: json?["responseId"] as? String,
            retryCount: retryCount,
            fallbackReason: fallbackReason,
            thinkingLevel: thinkingLevel,
            latencySeconds: latencySeconds,
            usage: usage
        )
    }
}
