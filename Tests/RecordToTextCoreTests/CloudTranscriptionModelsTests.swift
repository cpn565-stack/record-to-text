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
        XCTAssertEqual(settings.geminiThinkingLevel, .high)
        XCTAssertEqual(settings.cloudFallbackPolicy, .disabled)
        XCTAssertTrue(settings.silenceAwareCloudSegmentation)

        let snapshotData = Data(
            #"{"modelID":"local/model","language":"Chinese","glossaryID":null,"glossaryName":null,"terms":[],"prompt":"prompt","outputLocationMode":"fixedDirectory","outputDirectory":"/tmp/output","keepRawTranscript":false,"backendType":"googleAIStudio","googleAIStudioModelID":"gemini-3.7-flash"}"#.utf8
        )
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: snapshotData)
        XCTAssertEqual(snapshot.geminiThinkingLevel, .high)
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

    func testCloudUsageCostEstimationAndSummaryDisplay() {
        let usage = CloudUsageMetadata(
            promptTokenCount: 75_000,
            candidatesTokenCount: 4_228,
            thoughtsTokenCount: 1_212,
            totalTokenCount: 79_228
        )
        let cost = usage.estimatedCostUSD(modelID: "gemini-3.8-flash")
        XCTAssertNotNil(cost)
        XCTAssertEqual(String(format: "%.4f", cost!), "0.0721")
        XCTAssertEqual(CloudUsageMetadata.formatCostUSD(cost!), "$0.07")
        XCTAssertEqual(CloudUsageMetadata.formatTokenCount(79_228), "79.2k")
        XCTAssertEqual(CloudUsageMetadata.formatTokenCount(1_212), "1.2k")
        XCTAssertEqual(
            usage.summaryDisplay(modelID: "gemini-3.8-flash"),
            "79.2k tokens (思考 1.2k)，預估 $0.07"
        )
    }

    func testCompletionTimeFormatting() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let nowComponents = DateComponents(year: 2026, month: 9, day: 3, hour: 12, minute: 0)
        let now = calendar.date(from: nowComponents)!

        let todayComponents = DateComponents(year: 2026, month: 9, day: 3, hour: 23, minute: 56)
        let todayDate = calendar.date(from: todayComponents)!
        XCTAssertEqual(
            RecentJobSummary.formatCompletionDate(todayDate, now: now, calendar: calendar),
            "23:56"
        )

        let yesterdayComponents = DateComponents(year: 2026, month: 9, day: 2, hour: 14, minute: 30)
        let yesterdayDate = calendar.date(from: yesterdayComponents)!
        XCTAssertEqual(
            RecentJobSummary.formatCompletionDate(yesterdayDate, now: now, calendar: calendar),
            "9/2"
        )

        let summary = RecentJobSummary(
            id: UUID(),
            sourcePath: "/tmp/test.m4a",
            outputPath: "/tmp/test.txt",
            stage: .completed,
            startedAt: yesterdayDate,
            completedAt: todayDate,
            modelID: "gemini-3.8-flash",
            glossaryName: nil
        )
        XCTAssertEqual(
            summary.statusWithCompletionTime(now: now, calendar: calendar),
            "完成 23:56"
        )

        let yesterdaySummary = RecentJobSummary(
            id: UUID(),
            sourcePath: "/tmp/test.m4a",
            outputPath: "/tmp/test.txt",
            stage: .completed,
            startedAt: yesterdayDate,
            completedAt: yesterdayDate,
            modelID: "gemini-3.8-flash",
            glossaryName: nil
        )
        XCTAssertEqual(
            yesterdaySummary.statusWithCompletionTime(now: now, calendar: calendar),
            "完成 9/2"
        )
    }
}
