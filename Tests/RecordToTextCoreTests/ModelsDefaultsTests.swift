import Foundation
import XCTest
@testable import RecordToTextCore

final class ModelsDefaultsTests: XCTestCase {
    func testAppleSiliconModelDefaultIsStableMLXModel() {
        let model = ASRModelDescriptor.appleSiliconDefault

        XCTAssertEqual(model.id, "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(model.displayName, "Qwen3-ASR 1.7B 8-bit")
        XCTAssertEqual(model.architecture, .arm64)
        XCTAssertFalse(model.isExperimental)
    }

    func testIntelModelDefaultIsExperimentalCPUModel() {
        let model = ASRModelDescriptor.intelDefault

        XCTAssertEqual(model.id, "Qwen/Qwen3-ASR-0.6B")
        XCTAssertEqual(model.displayName, "Qwen3-ASR 0.6B CPU")
        XCTAssertEqual(model.architecture, .x86_64)
        XCTAssertTrue(model.isExperimental)
    }

    func testCurrentModelDefaultMatchesCompiledArchitecture() {
        switch CPUArchitecture.current {
        case .arm64:
            XCTAssertEqual(
                ASRModelDescriptor.currentDefault,
                ASRModelDescriptor.appleSiliconDefault
            )
        case .x86_64:
            XCTAssertEqual(
                ASRModelDescriptor.currentDefault,
                ASRModelDescriptor.intelDefault
            )
        case .unknown:
            XCTAssertEqual(
                ASRModelDescriptor.currentDefault,
                ASRModelDescriptor.appleSiliconDefault
            )
        }
    }

    func testAppSettingsInitializerUsesProductDefaults() {
        let settings = AppSettings(defaultOutputDirectory: "/tmp/output")

        XCTAssertEqual(settings.schemaVersion, 1)
        XCTAssertEqual(settings.defaultOutputDirectory, "/tmp/output")
        XCTAssertEqual(settings.outputLocationMode, .fixedDirectory)
        XCTAssertNil(settings.lastInputDirectory)
        XCTAssertNil(settings.lastOutputDirectory)
        XCTAssertNil(settings.lastSelectedGlossaryID)
        XCTAssertEqual(settings.lastTemporaryTerms, "")
        XCTAssertEqual(
            settings.selectedModels[CPUArchitecture.arm64.rawValue],
            ASRModelDescriptor.appleSiliconDefault.id
        )
        XCTAssertEqual(
            settings.selectedModels[CPUArchitecture.x86_64.rawValue],
            ASRModelDescriptor.intelDefault.id
        )
        XCTAssertTrue(settings.autoStartAfterSelection)
        XCTAssertTrue(settings.revealInFinderWhenCompleted)
        XCTAssertFalse(settings.openTextWhenCompleted)
        XCTAssertTrue(settings.showNotificationWhenCompleted)
        XCTAssertFalse(settings.keepRawTranscript)
        XCTAssertEqual(settings.recentJobLimit, 10)
        XCTAssertFalse(settings.developerMode)
        XCTAssertNil(settings.customPythonPath)
        XCTAssertNil(settings.customHelperPath)
        XCTAssertFalse(settings.hasCompletedOnboarding)
    }

    func testDefaultValueUsesNeutralProductDirectoryAndRequestedDeveloperMode() {
        let settings = AppSettings.defaultValue(developerMode: true)

        XCTAssertTrue(
            settings.defaultOutputDirectory.hasSuffix(
                "/record-to-text/轉出的文字"
            )
        )
        XCTAssertTrue(settings.developerMode)
        XCTAssertEqual(settings.selectedModelID, ASRModelDescriptor.currentDefault.id)
    }

    func testSelectedModelIDUsesArchitectureSpecificOverride() {
        var settings = AppSettings(defaultOutputDirectory: "/tmp/output")
        settings.selectedModels[CPUArchitecture.current.rawValue] = "custom/model"

        XCTAssertEqual(settings.selectedModelID, "custom/model")
    }

    func testOutputLocationModesHaveTraditionalChineseDisplayNames() {
        XCTAssertEqual(OutputLocationMode.fixedDirectory.displayName, "固定資料夾")
        XCTAssertEqual(OutputLocationMode.sameAsSource.displayName, "與來源音檔相同")
        XCTAssertEqual(OutputLocationMode.askEveryTime.displayName, "每次詢問")
    }

    func testOnlyTerminalStagesAreMarkedTerminal() {
        let terminal: Set<TranscriptionStage> = [
            .completed,
            .failed,
            .cancelled,
            .interrupted
        ]

        for stage in TranscriptionStage.allCases {
            XCTAssertEqual(
                stage.isTerminal,
                terminal.contains(stage),
                "\(stage) 的 terminal 判斷不正確"
            )
        }
    }

    func testAudioMetadataEstimatedPCMBytesIncludesSafetyMargin() {
        let metadata = AudioMetadata(
            duration: 60,
            codecName: "aac",
            sampleRate: 48_000,
            channels: 2
        )

        XCTAssertEqual(
            metadata.estimatedPCMBytes,
            Int64(60 * 16_000 * 2) + 16 * 1_024 * 1_024
        )
    }
}
