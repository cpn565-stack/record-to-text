import Foundation
import XCTest
@testable import RecordToTextCore

final class GeminiThinkingPreferencesTests: XCTestCase {
    func testNeonQuickChoicesDefaultToHighAndSupportAllFourLevelsOnBothBackends() throws {
        let initial = AppSettings(defaultOutputDirectory: "/tmp/output")
        XCTAssertEqual(initial.googleAIStudioModelID, "gemini-4-neon")
        XCTAssertEqual(initial.vertexAIModelID, "gemini-4-neon")
        XCTAssertEqual(initial.geminiThinkingLevel, .high)
        XCTAssertEqual(
            GeminiModelDescriptor.presetModels.map(\.id),
            ["gemini-4-neon", "gemini-4-hydrogen", "gemini-4-carbon", "gemini-4-argon"]
        )
        for choice in [QuickTranscriptionChoice.aiStudioGemini4Neon, .vertexGemini4Neon] {
            let settings = choice.applying(to: initial)
            let restored = try roundTrip(settings)
            XCTAssertTrue(choice.matches(restored))
            XCTAssertEqual(restored.selectedGeminiModelID, "gemini-4-neon")
            XCTAssertEqual(restored.geminiThinkingLevel, .high)
            XCTAssertEqual(restored.defaultOutputDirectory, initial.defaultOutputDirectory)
            XCTAssertEqual(restored.vertexAIIncludeSummary, initial.vertexAIIncludeSummary)
        }
        XCTAssertEqual(GoogleAIStudioBackend.Configuration(modelID: "gemini-4-neon").thinkingLevel, .high)
        XCTAssertEqual(VertexAIGeminiBackend.Configuration(modelID: "gemini-4-neon").thinkingLevel, .high)
        XCTAssertEqual(GoogleAIStudioBackend.Configuration().modelID, "gemini-4-neon")
        XCTAssertEqual(VertexAIGeminiBackend.Configuration().modelID, "gemini-4-neon")
        XCTAssertEqual(
            GeminiGenerationConfig.supportedThinkingLevels(modelID: "gemini-4-neon"),
            [.low, .medium, .high, .xhigh]
        )

        // Legacy global preference (e.g. medium) must not override Neon's default high.
        let legacyJSON = Data(#"{"defaultOutputDirectory":"/tmp/output","googleAIStudioModelID":"gemini-4-carbon","geminiThinkingLevel":"medium"}"#.utf8)
        var migrated = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(migrated.geminiThinkingLevel, .medium)
        migrated = QuickTranscriptionChoice.aiStudioGemini4Neon.applying(to: migrated)
        XCTAssertEqual(migrated.geminiThinkingLevel, .high)

        for level in [GeminiThinkingLevel.low, .medium, .high, .xhigh] {
            migrated.geminiThinkingLevel = level
            let restored = try roundTrip(migrated)
            let switched = QuickTranscriptionChoice.vertexGemini4Neon.applying(to: restored)
            XCTAssertEqual(switched.geminiThinkingLevel, level)
        }
    }

    func testHydrogenQuickChoicesDefaultToXHighOnBothBackends() throws {
        let initial = AppSettings(defaultOutputDirectory: "/tmp/output")
        for choice in [QuickTranscriptionChoice.aiStudioGemini4Hydrogen, .vertexGemini4Hydrogen] {
            let settings = choice.applying(to: initial)
            let restored = try roundTrip(settings)
            XCTAssertTrue(choice.matches(restored))
            XCTAssertEqual(restored.selectedGeminiModelID, "gemini-4-hydrogen")
            XCTAssertEqual(restored.geminiThinkingLevel, .xhigh)
            XCTAssertEqual(restored.defaultOutputDirectory, initial.defaultOutputDirectory)
            XCTAssertEqual(restored.vertexAIIncludeSummary, initial.vertexAIIncludeSummary)
        }
        XCTAssertTrue(GeminiModelDescriptor.presetModels.contains { $0.id == "gemini-4-hydrogen" })
        XCTAssertEqual(GoogleAIStudioBackend.Configuration(modelID: "gemini-4-hydrogen").thinkingLevel, .xhigh)
        XCTAssertEqual(VertexAIGeminiBackend.Configuration(modelID: "gemini-4-hydrogen").thinkingLevel, .xhigh)
    }

    func testLegacyGlobalChoiceRemainsDefaultForOldModelsButNotHydrogen() throws {
        let json = Data(#"{"defaultOutputDirectory":"/tmp/output","googleAIStudioModelID":"gemini-4-carbon","geminiThinkingLevel":"medium"}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: json)
        for model in ["gemini-4-carbon", "gemini-4-argon", "gemini-3.8-flash"] {
            settings.googleAIStudioModelID = model
            XCTAssertEqual(settings.geminiThinkingLevel, .medium)
        }
        settings = QuickTranscriptionChoice.aiStudioGemini4Hydrogen.applying(to: settings)
        XCTAssertEqual(settings.geminiThinkingLevel, .xhigh)
        settings.geminiThinkingLevel = .low
        settings = try roundTrip(settings)
        settings = QuickTranscriptionChoice.vertexGemini4Carbon.applying(to: settings)
        XCTAssertEqual(settings.geminiThinkingLevel, .medium)
        settings = QuickTranscriptionChoice.vertexGemini4Hydrogen.applying(to: settings)
        XCTAssertEqual(settings.geminiThinkingLevel, .low)
    }

    func testEveryHydrogenChoiceSurvivesModelBackendSwitchAndRestart() throws {
        for level in [GeminiThinkingLevel.low, .medium, .high, .xhigh] {
            var settings = QuickTranscriptionChoice.aiStudioGemini4Carbon.applying(
                to: AppSettings(defaultOutputDirectory: "/tmp/output"))
            settings.geminiThinkingLevel = .low
            settings = QuickTranscriptionChoice.vertexGemini4Hydrogen.applying(to: settings)
            XCTAssertEqual(settings.geminiThinkingLevel, .xhigh)
            settings.geminiThinkingLevel = level
            settings = try roundTrip(settings)
            settings = QuickTranscriptionChoice.vertexGemini4Carbon.applying(to: settings)
            XCTAssertEqual(settings.geminiThinkingLevel, .low)
            settings = QuickTranscriptionChoice.aiStudioGemini4Hydrogen.applying(to: settings)
            XCTAssertEqual(settings.geminiThinkingLevel, level)
        }
    }

    func testCapabilitiesNeverSendXHighToCarbonOrThinkingToTranscribe() throws {
        XCTAssertEqual(GeminiGenerationConfig.supportedThinkingLevels(modelID: "gemini-4-hydrogen"),
                       [.low, .medium, .high, .xhigh])
        XCTAssertEqual(GeminiGenerationConfig.supportedThinkingLevels(modelID: "gemini-4-carbon"),
                       [.low, .medium, .high])
        var settings = AppSettings(defaultOutputDirectory: "/tmp/output",
            googleAIStudioModelID: "gemini-4-carbon",
            geminiThinkingLevelsByModel: ["gemini-4-carbon": .xhigh])
        XCTAssertEqual(settings.geminiThinkingLevel, .high)
        settings.geminiThinkingLevel = .xhigh
        XCTAssertEqual(try roundTrip(settings).geminiThinkingLevel, .high)
        let config = GeminiGenerationConfig.make(maxOutputTokens: 32_768,
            modelID: "gemini-4-carbon", thinkingLevel: .xhigh)
        XCTAssertEqual((config["thinkingConfig"] as? [String: String])?["thinkingLevel"], "high")
        for model in ["custom-model"] {
            XCTAssertTrue(GeminiGenerationConfig.supportedThinkingLevels(modelID: model).isEmpty)
            XCTAssertNil(GeminiGenerationConfig.make(maxOutputTokens: 16_384,
                modelID: model, thinkingLevel: .xhigh)["thinkingConfig"])
        }
    }

    func testSnapshotAndResumeKeepCapturedLevelDespiteNewPreferences() throws {
        var settings = QuickTranscriptionChoice.aiStudioGemini4Hydrogen.applying(
            to: AppSettings(defaultOutputDirectory: "/tmp/output"))
        let original = JobSnapshot(modelID: "unused", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp/output", keepRawTranscript: false)
        let snapshot = original.withEngineSettings(settings)
        let restored = try JSONDecoder().decode(JobSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.geminiThinkingLevel, .xhigh)
        settings.geminiThinkingLevel = .low
        XCTAssertEqual(settings.applyingRuntimeConfiguration(from: restored).geminiThinkingLevel, .xhigh)
        XCTAssertEqual(settings.geminiThinkingLevel, .low)
        XCTAssertEqual(snapshot.withEngineSettings(settings).geminiThinkingLevel, .low)

        // Existing checkpoints with an explicit high must not be upgraded to xhigh.
        let oldSnapshot = JobSnapshot(modelID: "unused", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "", outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp/output", keepRawTranscript: false,
            backendType: .vertexAI, vertexAIModelID: "gemini-4-hydrogen", geminiThinkingLevel: .high)
        XCTAssertEqual(settings.applyingRuntimeConfiguration(from: oldSnapshot).geminiThinkingLevel, .high)
    }

    func testHydrogenAndNeonBudgetsAndUsageDoNotInheritUnknownModelOrFlashDefaults() {
        for model in ["gemini-4-neon", "gemini-4-hydrogen"] {
            XCTAssertEqual(GeminiGenerationConfig.transcriptionOutputTokens(modelID: model), 65_536)
            XCTAssertEqual(GeminiGenerationConfig.summaryOutputTokens(modelID: model), 65_536)
            XCTAssertEqual(GeminiGenerationConfig.requestTimeout(modelID: model), 1_200)
            XCTAssertEqual(GeminiGenerationConfig.segmentBudget(modelID: model), .seconds(1_800))
            let usage = CloudUsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 100,
                thoughtsTokenCount: 200, totalTokenCount: 1_300)
            XCTAssertNil(usage.estimatedCostUSD(modelID: model))
            XCTAssertEqual(usage.summaryDisplay(modelID: model), "1.3k tokens (思考 200)")
        }
        XCTAssertEqual(GeminiGenerationConfig.summaryOutputTokens(modelID: "gemini-4-carbon"), 16_384)
        XCTAssertEqual(GeminiGenerationConfig.summaryOutputTokens(modelID: "gemini-3.8-flash"), 16_384)
        XCTAssertEqual(GeminiGenerationConfig.summaryOutputTokens(modelID: "custom-model"), 2_048)
    }

    private func roundTrip(_ settings: AppSettings) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    }
}
