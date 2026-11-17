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
        XCTAssertFalse(settings.localSilenceAwareSegmentation)

        let snapshotData = Data(
            #"{"modelID":"local/model","language":"Chinese","glossaryID":null,"glossaryName":null,"terms":[],"prompt":"prompt","outputLocationMode":"fixedDirectory","outputDirectory":"/tmp/output","keepRawTranscript":false,"backendType":"googleAIStudio","googleAIStudioModelID":"gemini-3.7-flash"}"#.utf8
        )
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: snapshotData)
        XCTAssertEqual(snapshot.geminiThinkingLevel, .high)
        XCTAssertEqual(snapshot.cloudFallbackPolicy, .disabled)
        XCTAssertTrue(snapshot.silenceAwareCloudSegmentation)
        XCTAssertFalse(snapshot.localSilenceAwareSegmentation)
        XCTAssertEqual(snapshot.requestedModelID, "gemini-3.7-flash")
    }

    /// Phase 1.1 H5: silence-aware local cut points have not passed the real
    /// model A/B, so they stay opt-in. A fresh install and a freshly built
    /// snapshot are off; a value the user explicitly saved survives a round trip
    /// and is what the engine reads, and turning it off again is honoured too.
    func testLocalSilenceSegmentationStaysOptInUntilTheABReleaseGatePasses() throws {
        XCTAssertFalse(AppSettings(defaultOutputDirectory: "/tmp/output").localSilenceAwareSegmentation)
        XCTAssertFalse(JobSnapshot(
            modelID: "local/model", glossaryID: nil, glossaryName: nil, terms: [],
            prompt: "prompt", outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp/output", keepRawTranscript: false,
            backendType: .localQwen
        ).localSilenceAwareSegmentation)

        for enabled in [true, false] {
            var settings = AppSettings(defaultOutputDirectory: "/tmp/output")
            settings.localSilenceAwareSegmentation = enabled
            let decodedSettings = try JSONDecoder().decode(
                AppSettings.self, from: JSONEncoder().encode(settings)
            )
            XCTAssertEqual(decodedSettings.localSilenceAwareSegmentation, enabled)

            let snapshot = JobSnapshot(
                modelID: "local/model", glossaryID: nil, glossaryName: nil, terms: [],
                prompt: "prompt", outputLocationMode: .fixedDirectory,
                outputDirectory: "/tmp/output", keepRawTranscript: false,
                backendType: .localQwen,
                localSilenceAwareSegmentation: enabled
            )
            let decodedSnapshot = try JSONDecoder().decode(
                JobSnapshot.self, from: JSONEncoder().encode(snapshot)
            )
            XCTAssertEqual(decodedSnapshot.localSilenceAwareSegmentation, enabled)
            // A queued job is re-synced from live settings before it starts, so
            // the switch has to survive that path unchanged in both directions.
            XCTAssertEqual(
                decodedSnapshot.withEngineSettings(settings).localSilenceAwareSegmentation,
                enabled
            )
        }
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
        XCTAssertEqual(cost!, 0.07665, accuracy: 1e-9)
        XCTAssertEqual(CloudUsageMetadata.formatCostUSD(cost!), "$0.08")
        XCTAssertEqual(CloudUsageMetadata.formatTokenCount(79_228), "79.2k")
        XCTAssertEqual(CloudUsageMetadata.formatTokenCount(1_212), "1.2k")
        XCTAssertEqual(
            usage.summaryDisplay(modelID: "gemini-3.8-flash"),
            "79.2k tokens (思考 1.2k)，預估 $0.08"
        )
    }

    func testMultiSegmentFallbackTotalsCostPerEffectiveModelRate() {
        let seg1 = CloudTranscriptionMetadata(
            requestedModelID: "gemini-3.8-flash",
            effectiveModelID: "gemini-3.8-flash",
            usage: CloudUsageMetadata(
                promptTokenCount: 100_000,
                candidatesTokenCount: 10_000,
                thoughtsTokenCount: 0,
                totalTokenCount: 110_000
            )
        )
        let seg2 = CloudTranscriptionMetadata(
            requestedModelID: "gemini-3.8-flash",
            effectiveModelID: "gemini-3.6-flash",
            retryCount: 3,
            fallbackReason: "HTTP 503",
            usage: CloudUsageMetadata(
                promptTokenCount: 100_000,
                candidatesTokenCount: 10_000,
                thoughtsTokenCount: 0,
                totalTokenCount: 110_000
            )
        )
        // seg1 (3.8): 0.1 * $0.75 + 0.01 * $3.75 = $0.075 + $0.0375 = $0.1125
        // seg2 (3.6): 0.1 * $0.70 + 0.01 * $0.40 = $0.070 + $0.0040 = $0.0740
        // sum = $0.1865 (vs $0.2250 if erroneously billed all at 3.8 rate)
        let totalCost = CloudTranscriptionMetadataAggregator.totalEstimatedCostUSD([seg1, seg2])
        XCTAssertNotNil(totalCost)
        XCTAssertEqual(String(format: "%.4f", totalCost!), "0.1865")

        let snapshot = JobSnapshot(
            modelID: "unused",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "",
            outputLocationMode: .sameAsSource,
            outputDirectory: "",
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioModelID: "gemini-3.8-flash"
        )
        let job = TranscriptionJob(
            sourcePath: "/tmp/fallback.m4a",
            snapshot: snapshot,
            stage: .completed,
            cloudSegmentMetadata: [seg1, seg2]
        )
        XCTAssertEqual(job.cloudTokenSummary, "220.0k tokens，預估 $0.19")
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
