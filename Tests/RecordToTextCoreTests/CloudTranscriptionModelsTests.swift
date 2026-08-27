import XCTest
@testable import RecordToTextCore

final class CloudTranscriptionModelsTests: XCTestCase {
    func testUsageAggregationAndEffectiveModelOrder() {
        let first = CloudTranscriptionMetadata(
            requestedModelID: "gemini-3.7-flash",
            effectiveModelID: "gemini-3.7-flash",
            retryCount: 1,
            usage: CloudUsageMetadata(
                promptTokenCount: 100,
                candidatesTokenCount: 40,
                thoughtsTokenCount: 10,
                totalTokenCount: 150
            )
        )
        let second = CloudTranscriptionMetadata(
            requestedModelID: "gemini-3.7-flash",
            effectiveModelID: "gemini-3.6-flash",
            retryCount: 2,
            fallbackReason: "HTTP 503",
            usage: CloudUsageMetadata(
                promptTokenCount: 80,
                candidatesTokenCount: 30,
                thoughtsTokenCount: 5,
                totalTokenCount: 115
            )
        )

        XCTAssertEqual(
            CloudTranscriptionMetadataAggregator.uniqueEffectiveModelIDs([
                first, second, first
            ]),
            ["gemini-3.7-flash", "gemini-3.6-flash"]
        )
        XCTAssertEqual(
            CloudTranscriptionMetadataAggregator.totalRetryCount([first, second]),
            3
        )
        XCTAssertEqual(
            CloudTranscriptionMetadataAggregator.totalUsage([first, second]),
            CloudUsageMetadata(
                promptTokenCount: 180,
                candidatesTokenCount: 70,
                thoughtsTokenCount: 15,
                totalTokenCount: 265
            )
        )
        XCTAssertTrue(second.usedFallback)
    }

    func testLegacySettingsAndSnapshotDefaultToSafeCloudPolicies() throws {
        let settingsData = Data(
            #"{"defaultOutputDirectory":"/tmp/output"}"#.utf8
        )
        let settings = try JSONDecoder().decode(AppSettings.self, from: settingsData)
        XCTAssertEqual(settings.geminiThinkingLevel, .medium)
        XCTAssertEqual(settings.cloudFallbackPolicy, .disabled)
        XCTAssertTrue(settings.silenceAwareCloudSegmentation)

        let snapshotData = Data(
            #"{"modelID":"local/model","language":"Chinese","glossaryID":null,"glossaryName":null,"terms":[],"prompt":"prompt","outputLocationMode":"fixedDirectory","outputDirectory":"/tmp/output","keepRawTranscript":false,"backendType":"googleAIStudio","googleAIStudioModelID":"gemini-3.7-flash"}"#.utf8
        )
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: snapshotData)
        XCTAssertEqual(snapshot.geminiThinkingLevel, .medium)
        XCTAssertEqual(snapshot.cloudFallbackPolicy, .disabled)
        XCTAssertTrue(snapshot.silenceAwareCloudSegmentation)
        XCTAssertEqual(snapshot.requestedModelID, "gemini-3.7-flash")
    }

    func testRecentSummaryUsesCloudRequestedAndEffectiveModels() {
        let snapshot = JobSnapshot(
            modelID: "local-placeholder",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "prompt",
            outputLocationMode: .sameAsSource,
            outputDirectory: "",
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioModelID: "gemini-3.7-flash"
        )
        var job = TranscriptionJob(
            sourcePath: "/tmp/audio.m4a",
            snapshot: snapshot,
            stage: .completed,
            cloudSegmentMetadata: [
                CloudTranscriptionMetadata(
                    requestedModelID: "gemini-3.7-flash",
                    effectiveModelID: "gemini-3.6-flash",
                    retryCount: 2,
                    fallbackReason: "HTTP 503"
                )
            ]
        )
        job.outputPath = "/tmp/audio_逐字稿.txt"
        let summary = RecentJobSummary(job: job)

        XCTAssertEqual(summary.modelID, "gemini-3.7-flash")
        XCTAssertEqual(summary.effectiveModelIDs, ["gemini-3.6-flash"])
        XCTAssertEqual(summary.cloudRetryCount, 2)
        XCTAssertEqual(summary.cloudFallbackUsed, true)
    }
}
