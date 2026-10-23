import Foundation
import XCTest
@testable import RecordToTextCore

final class GeminiBackendObservabilityTests: XCTestCase {
    func testQuickArgonSelectionPersistsWithoutChangingTranscriptPreferences() throws {
        var original = AppSettings(defaultOutputDirectory: "/tmp/output")
        original.geminiThinkingLevel = .medium
        original.keepRawTranscript = true
        for choice in [QuickTranscriptionChoice.aiStudioGemini4Argon, .vertexGemini4Argon] {
            let selected = choice.applying(to: original)
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(selected))
            XCTAssertTrue(choice.matches(restored))
            XCTAssertEqual(restored.geminiThinkingLevel, .medium)
            XCTAssertEqual(restored.keepRawTranscript, original.keepRawTranscript)
            XCTAssertEqual(restored.outputLocationMode, original.outputLocationMode)
            XCTAssertEqual(restored.defaultOutputDirectory, original.defaultOutputDirectory)
            XCTAssertEqual(restored.vertexAIIncludeSummary, original.vertexAIIncludeSummary)
            XCTAssertFalse(QuickTranscriptionChoice.qwen3ASR1_7BBF16.matches(restored))
        }
    }

    func testNetworkRetryClassificationDoesNotRetryPermanentErrorsOrCancellation() {
        for code in [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet,
                     .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            XCTAssertTrue(GeminiTransportHelper.isTransientNetworkFailure(URLError(code)))
        }
        for code in [URLError.cancelled, .badURL, .secureConnectionFailed, .userAuthenticationRequired] {
            XCTAssertFalse(GeminiTransportHelper.isTransientNetworkFailure(URLError(code)))
        }
        XCTAssertFalse(GeminiTransportHelper.isTransientNetworkFailure(NSError(domain: "other", code: -1001)))
        XCTAssertTrue(GeminiTransportHelper.isNetworkCancellation(URLError(.cancelled)))
    }

    func testTranscriptionOutputBudgetKeepsUnknownModelsConservative() {
        for model in ["gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash"] {
            XCTAssertEqual(GeminiGenerationConfig.transcriptionOutputTokens(modelID: model), 65_536)
        }
        XCTAssertEqual(GeminiGenerationConfig.transcriptionOutputTokens(modelID: "custom-model"), 16_384)
        XCTAssertEqual(GeminiGenerationConfig.transcriptionOutputTokens(modelID: "gemini-4-argon"), 32_768)
    }

    func testArgonSupportKeepsOtherModelTimeoutsAndUnknownCapabilities() {
        for model in ["gemini-3.8-flash", "custom-model"] {
            XCTAssertEqual(GeminiGenerationConfig.requestTimeout(modelID: model), 300)
            XCTAssertEqual(GeminiGenerationConfig.segmentBudget(modelID: model), .seconds(900))
        }
        XCTAssertEqual(GeminiGenerationConfig.segmentBudget(modelID: "gemini-4-argon"), .seconds(1_800))
        XCTAssertNil(GeminiGenerationConfig.make(maxOutputTokens: 16_384,
            modelID: "custom-model", thinkingLevel: .high)["thinkingConfig"])
        let usage = CloudUsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 100,
            thoughtsTokenCount: 200, totalTokenCount: 1_300)
        XCTAssertNil(usage.estimatedCostUSD(modelID: "gemini-4-argon"))
        XCTAssertEqual(usage.summaryDisplay(modelID: "gemini-4-argon"), "1.3k tokens (思考 200)")
    }

    func testMetadataParserCapturesModelVersionResponseAndUsage() throws {
        let data = Data(
            #"{"modelVersion":"gemini-3.7-flash-202608","responseId":"resp-123","usageMetadata":{"promptTokenCount":120,"cachedContentTokenCount":20,"candidatesTokenCount":50,"thoughtsTokenCount":12,"totalTokenCount":182,"trafficType":"ON_DEMAND"}}"#.utf8
        )
        let metadata = GeminiResponseMetadataParser.makeMetadata(
            from: data,
            requestedModelID: "gemini-3.7-flash",
            effectiveModelID: "gemini-3.6-flash",
            retryCount: 4,
            fallbackReason: "HTTP 503",
            thinkingLevel: .low,
            latencySeconds: 3.5
        )

        XCTAssertEqual(metadata.modelVersion, "gemini-3.7-flash-202608")
        XCTAssertEqual(metadata.responseID, "resp-123")
        XCTAssertEqual(metadata.retryCount, 4)
        XCTAssertEqual(metadata.thinkingLevel, .low)
        XCTAssertEqual(metadata.usage?.thoughtsTokenCount, 12)
        XCTAssertEqual(metadata.usage?.totalTokenCount, 182)
        XCTAssertTrue(metadata.usedFallback)
    }

    func testRetryPolicyUsesExponentialBackoffJitterAndRetryInfo() {
        XCTAssertEqual(
            GeminiTransportHelper.RetryPolicy.backoffSeconds(
                forAttempt: 1,
                jitterFraction: 0
            ),
            1
        )
        XCTAssertEqual(
            GeminiTransportHelper.RetryPolicy.backoffSeconds(
                forAttempt: 3,
                jitterFraction: 0
            ),
            4
        )
        XCTAssertEqual(
            GeminiTransportHelper.RetryPolicy.backoffSeconds(
                forAttempt: 2,
                retryAfterSeconds: 9,
                jitterFraction: 0
            ),
            9
        )
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(
                GeminiTransportHelper.RetryPolicy
                    .isRetryableStatusCode(status)
            )
        }
        XCTAssertFalse(
            GeminiTransportHelper.RetryPolicy.isRetryableStatusCode(403)
        )
    }

    func testRetryInfoAndDailyQuotaClassification() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test"))
        let response = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )!
        let retryData = Data(
            #"{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"7.5s"}]}}"#.utf8
        )
        XCTAssertEqual(
            GeminiTransportHelper.retryAfterSeconds(
                response: response,
                data: retryData
            ),
            7.5
        )
        XCTAssertTrue(
            GeminiTransportHelper.isDailyQuotaExceeded(
                data: Data(#"{"quotaId":"GenerateRequestsPerDay"}"#.utf8),
                message: "quota exhausted"
            )
        )
        XCTAssertFalse(
            GeminiTransportHelper.isDailyQuotaExceeded(
                data: Data(),
                message: "rate limit exceeded per minute"
            )
        )
    }

    func testFallbackDefaultsOffAndMayBeExplicitlyEnabled() {
        XCTAssertEqual(
            GoogleAIStudioBackend.Configuration.default.fallbackPolicy,
            .disabled
        )
        XCTAssertEqual(
            VertexAIGeminiBackend.Configuration.default.fallbackPolicy,
            .disabled
        )
        XCTAssertEqual(
            GoogleAIStudioBackend.Configuration(
                fallbackPolicy: .flashOnly
            ).fallbackPolicy,
            .flashOnly
        )
    }
}
