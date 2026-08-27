import Foundation

public enum CPUArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64
    case unknown

    public static var current: CPUArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }
}

public struct ASRModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let revision: String?
    public let displayName: String
    public let architecture: CPUArchitecture
    public let isExperimental: Bool
    public let detail: String?

    public init(
        id: String,
        revision: String? = nil,
        displayName: String,
        architecture: CPUArchitecture,
        isExperimental: Bool,
        detail: String? = nil
    ) {
        self.id = id
        self.revision = revision
        self.displayName = displayName
        self.architecture = architecture
        self.isExperimental = isExperimental
        self.detail = detail
    }

    /// Default Apple Silicon model: smaller download, good quality.
    public static let appleSiliconDefault = ASRModelDescriptor(
        id: "mlx-community/Qwen3-ASR-1.7B-8bit",
        revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
        displayName: "Qwen3-ASR 1.7B 8-bit",
        architecture: .arm64,
        isExperimental: false,
        detail: "預設。體積較小，適合日常會議轉錄。"
    )

    /// Full-precision MLX build of the 1.7B model.
    public static let appleSiliconBF16 = ASRModelDescriptor(
        id: "mlx-community/Qwen3-ASR-1.7B-bf16",
        revision: "e1f6c266914abc5a46e8756e02580f834a6cf8a7",
        displayName: "Qwen3-ASR 1.7B BF16",
        architecture: .arm64,
        isExperimental: false,
        detail: "完整精度。下載與記憶體需求較大。"
    )

    /// Smaller Apple Silicon option for constrained machines.
    public static let appleSilicon0_6B8bit = ASRModelDescriptor(
        id: "mlx-community/Qwen3-ASR-0.6B-8bit",
        revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f",
        displayName: "Qwen3-ASR 0.6B 8-bit",
        architecture: .arm64,
        isExperimental: false,
        detail: "較小較快，長會議品質通常不如 1.7B。"
    )

    public static let intelDefault = ASRModelDescriptor(
        id: "Qwen/Qwen3-ASR-0.6B",
        revision: "5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
        displayName: "Qwen3-ASR 0.6B CPU",
        architecture: .x86_64,
        isExperimental: true,
        detail: "Experimental。尚未通過 Intel 真機驗證。"
    )

    public static var currentDefault: ASRModelDescriptor {
        CPUArchitecture.current == .x86_64 ? .intelDefault : .appleSiliconDefault
    }

    /// Built-in selectable models for the given architecture.
    public static func available(for architecture: CPUArchitecture) -> [ASRModelDescriptor] {
        switch architecture {
        case .arm64, .unknown:
            return [
                .appleSiliconDefault,
                .appleSiliconBF16,
                .appleSilicon0_6B8bit
            ]
        case .x86_64:
            return [.intelDefault]
        }
    }

    public static var currentAvailable: [ASRModelDescriptor] {
        available(for: .current)
    }

    public static func descriptor(id: String) -> ASRModelDescriptor? {
        let all = available(for: .arm64) + available(for: .x86_64)
        return all.first { $0.id == id }
    }

    public static func revision(forModelID modelID: String) -> String? {
        descriptor(id: modelID)?.revision
    }
}

public enum OutputLocationMode: String, Codable, CaseIterable, Sendable {
    case fixedDirectory
    case sameAsSource
    case askEveryTime

    public var displayName: String {
        switch self {
        case .fixedDirectory:
            return "固定資料夾"
        case .sameAsSource:
            return "與來源音檔相同"
        case .askEveryTime:
            return "每次詢問"
        }
    }
}

public enum ASRBackendType: String, Codable, CaseIterable, Sendable {
    case googleAIStudio = "googleAIStudio"
    case vertexAI = "vertexAI"
    case localQwen = "localQwen"

    public var displayName: String {
        switch self {
        case .googleAIStudio:
            return "Google AI Studio (Gemini API Key)"
        case .vertexAI:
            return "Google Cloud Vertex AI (GCP / ADC)"
        case .localQwen:
            return "本機 Qwen ASR（不上雲）"
        }
    }
}

public struct GeminiModelDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let note: String

    public init(id: String, displayName: String, note: String) {
        self.id = id
        self.displayName = displayName
        self.note = note
    }

    public static let presetModels: [GeminiModelDescriptor] = [
        GeminiModelDescriptor(
            id: "gemini-3.7-flash",
            displayName: "Gemini 3.7 Flash",
            note: "極速轉錄、中文語音理解力頂級，適合日常會議與課程（推薦）"
        ),
        GeminiModelDescriptor(
            id: "gemini-3.6-flash",
            displayName: "Gemini 3.6 Flash",
            note: "速度極快且高可用，當 3.7 遇到尖峰負載 (503) 時的絕佳替代選擇"
        ),
        GeminiModelDescriptor(
            id: "gemini-3.1-pro-preview",
            displayName: "Gemini 3.1 Pro",
            note: "高智能推論能力，適合深度專業術語與複雜中英文混講"
        )
    ]
}

public typealias VertexAIModelDescriptor = GeminiModelDescriptor

public struct AppSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case defaultOutputDirectory
        case outputLocationMode
        case lastInputDirectory
        case lastOutputDirectory
        case lastSelectedGlossaryID
        case lastTemporaryTerms
        case selectedModels
        case autoStartAfterSelection
        case revealInFinderWhenCompleted
        case openTextWhenCompleted
        case showNotificationWhenCompleted
        case keepRawTranscript
        case outputFilenameSuffix
        case rawFilenameSuffix
        case recentJobLimit
        case developerMode
        case customPythonPath
        case customHelperPath
        case hasCompletedOnboarding
        case backendType
        // Decode-only migration key. `encode(to:)` deliberately omits it.
        case googleAIStudioAPIKey
        case googleAIStudioModelID
        case googleAIStudioTranscriptionOptions
        case vertexAIProjectID
        case vertexAILocation
        case vertexAIModelID
        case vertexAITranscriptionOptions
        case vertexAIGCSBucket
        case vertexAIIncludeSummary
        case vertexAISummaryModelID
        case allowDedicatedTranscribeFallbackToGeneralGemini
        case customGCloudPath
    }

    public var schemaVersion: Int
    public var defaultOutputDirectory: String
    public var outputLocationMode: OutputLocationMode
    public var lastInputDirectory: String?
    public var lastOutputDirectory: String?
    public var lastSelectedGlossaryID: String?
    public var lastTemporaryTerms: String
    public var selectedModels: [String: String]
    public var autoStartAfterSelection: Bool
    public var revealInFinderWhenCompleted: Bool
    public var openTextWhenCompleted: Bool
    public var showNotificationWhenCompleted: Bool
    public var keepRawTranscript: Bool
    /// Optional so older settings.json without this key still decodes.
    public var outputFilenameSuffix: String?
    /// Optional so older settings.json without this key still decodes.
    public var rawFilenameSuffix: String?
    public var recentJobLimit: Int
    public var developerMode: Bool
    public var customPythonPath: String?
    public var customHelperPath: String?
    public var hasCompletedOnboarding: Bool

    // MARK: - Cloud Gemini Settings (Google AI Studio & Vertex AI)
    public var backendType: ASRBackendType
    /// In-memory credential value. Old JSON can still decode this field for
    /// Keychain migration, but new JSON never encodes it.
    public var googleAIStudioAPIKey: String?
    public var googleAIStudioModelID: String
    public var googleAIStudioTranscriptionOptions: DedicatedTranscriptionOptions
    public var vertexAIProjectID: String?
    public var vertexAILocation: String
    public var vertexAIModelID: String
    public var vertexAITranscriptionOptions: DedicatedTranscriptionOptions
    public var vertexAIGCSBucket: String?
    public var vertexAIIncludeSummary: Bool
    public var vertexAISummaryModelID: String
    public var allowDedicatedTranscribeFallbackToGeneralGemini: Bool
    public var customGCloudPath: String?

    public init(
        schemaVersion: Int = 2,
        defaultOutputDirectory: String,
        outputLocationMode: OutputLocationMode = .fixedDirectory,
        lastInputDirectory: String? = nil,
        lastOutputDirectory: String? = nil,
        lastSelectedGlossaryID: String? = nil,
        lastTemporaryTerms: String = "",
        selectedModels: [String: String] = [
            CPUArchitecture.arm64.rawValue: ASRModelDescriptor.appleSiliconDefault.id,
            CPUArchitecture.x86_64.rawValue: ASRModelDescriptor.intelDefault.id
        ],
        autoStartAfterSelection: Bool = false,
        revealInFinderWhenCompleted: Bool = true,
        openTextWhenCompleted: Bool = false,
        showNotificationWhenCompleted: Bool = true,
        keepRawTranscript: Bool = false,
        outputFilenameSuffix: String? = OutputNameBuilder.defaultFinalSuffix,
        rawFilenameSuffix: String? = OutputNameBuilder.defaultRawSuffix,
        recentJobLimit: Int = 10,
        developerMode: Bool = false,
        customPythonPath: String? = nil,
        customHelperPath: String? = nil,
        hasCompletedOnboarding: Bool = false,
        backendType: ASRBackendType = .googleAIStudio,
        googleAIStudioAPIKey: String? = nil,
        googleAIStudioModelID: String = "gemini-3.7-flash",
        googleAIStudioTranscriptionOptions: DedicatedTranscriptionOptions = .default,
        vertexAIProjectID: String? = nil,
        vertexAILocation: String = "global",
        vertexAIModelID: String = "gemini-3.7-flash",
        vertexAITranscriptionOptions: DedicatedTranscriptionOptions = .default,
        vertexAIGCSBucket: String? = nil,
        vertexAIIncludeSummary: Bool = false,
        vertexAISummaryModelID: String = "gemini-3.7-flash",
        allowDedicatedTranscribeFallbackToGeneralGemini: Bool = false,
        customGCloudPath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.defaultOutputDirectory = defaultOutputDirectory
        self.outputLocationMode = outputLocationMode
        self.lastInputDirectory = lastInputDirectory
        self.lastOutputDirectory = lastOutputDirectory
        self.lastSelectedGlossaryID = lastSelectedGlossaryID
        self.lastTemporaryTerms = lastTemporaryTerms
        self.selectedModels = selectedModels
        self.autoStartAfterSelection = autoStartAfterSelection
        self.revealInFinderWhenCompleted = revealInFinderWhenCompleted
        self.openTextWhenCompleted = openTextWhenCompleted
        self.showNotificationWhenCompleted = showNotificationWhenCompleted
        self.keepRawTranscript = keepRawTranscript
        self.outputFilenameSuffix = outputFilenameSuffix
        self.rawFilenameSuffix = rawFilenameSuffix
        self.recentJobLimit = recentJobLimit
        self.developerMode = developerMode
        self.customPythonPath = customPythonPath
        self.customHelperPath = customHelperPath
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.backendType = backendType
        self.googleAIStudioAPIKey = googleAIStudioAPIKey
        self.googleAIStudioModelID = googleAIStudioModelID
        self.googleAIStudioTranscriptionOptions = googleAIStudioTranscriptionOptions
        self.vertexAIProjectID = vertexAIProjectID
        self.vertexAILocation = vertexAILocation
        self.vertexAIModelID = vertexAIModelID
        self.vertexAITranscriptionOptions = vertexAITranscriptionOptions
        self.vertexAIGCSBucket = vertexAIGCSBucket
        self.vertexAIIncludeSummary = vertexAIIncludeSummary
        self.vertexAISummaryModelID = vertexAISummaryModelID
        self.allowDedicatedTranscribeFallbackToGeneralGemini =
            allowDedicatedTranscribeFallbackToGeneralGemini
        self.customGCloudPath = customGCloudPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        defaultOutputDirectory = try container.decode(String.self, forKey: .defaultOutputDirectory)
        outputLocationMode = try container.decodeIfPresent(OutputLocationMode.self, forKey: .outputLocationMode) ?? .fixedDirectory
        lastInputDirectory = try container.decodeIfPresent(String.self, forKey: .lastInputDirectory)
        lastOutputDirectory = try container.decodeIfPresent(String.self, forKey: .lastOutputDirectory)
        lastSelectedGlossaryID = try container.decodeIfPresent(String.self, forKey: .lastSelectedGlossaryID)
        lastTemporaryTerms = try container.decodeIfPresent(String.self, forKey: .lastTemporaryTerms) ?? ""
        selectedModels = try container.decodeIfPresent([String: String].self, forKey: .selectedModels) ?? [
            CPUArchitecture.arm64.rawValue: ASRModelDescriptor.appleSiliconDefault.id,
            CPUArchitecture.x86_64.rawValue: ASRModelDescriptor.intelDefault.id
        ]
        autoStartAfterSelection = try container.decodeIfPresent(Bool.self, forKey: .autoStartAfterSelection) ?? false
        revealInFinderWhenCompleted = try container.decodeIfPresent(Bool.self, forKey: .revealInFinderWhenCompleted) ?? true
        openTextWhenCompleted = try container.decodeIfPresent(Bool.self, forKey: .openTextWhenCompleted) ?? false
        showNotificationWhenCompleted = try container.decodeIfPresent(Bool.self, forKey: .showNotificationWhenCompleted) ?? true
        keepRawTranscript = try container.decodeIfPresent(Bool.self, forKey: .keepRawTranscript) ?? false
        outputFilenameSuffix = try container.decodeIfPresent(String.self, forKey: .outputFilenameSuffix)
        rawFilenameSuffix = try container.decodeIfPresent(String.self, forKey: .rawFilenameSuffix)
        recentJobLimit = try container.decodeIfPresent(Int.self, forKey: .recentJobLimit) ?? 10
        developerMode = try container.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        customPythonPath = try container.decodeIfPresent(String.self, forKey: .customPythonPath)
        customHelperPath = try container.decodeIfPresent(String.self, forKey: .customHelperPath)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false

        backendType = try container.decodeIfPresent(ASRBackendType.self, forKey: .backendType) ?? .googleAIStudio
        googleAIStudioAPIKey = try container.decodeIfPresent(String.self, forKey: .googleAIStudioAPIKey)
        googleAIStudioModelID = try container.decodeIfPresent(String.self, forKey: .googleAIStudioModelID) ?? "gemini-3.7-flash"
        googleAIStudioTranscriptionOptions = try container.decodeIfPresent(
            DedicatedTranscriptionOptions.self,
            forKey: .googleAIStudioTranscriptionOptions
        ) ?? .default
        vertexAIProjectID = try container.decodeIfPresent(String.self, forKey: .vertexAIProjectID)
        vertexAILocation = try container.decodeIfPresent(String.self, forKey: .vertexAILocation) ?? "global"
        vertexAIModelID = try container.decodeIfPresent(String.self, forKey: .vertexAIModelID) ?? "gemini-3.7-flash"
        vertexAITranscriptionOptions = try container.decodeIfPresent(
            DedicatedTranscriptionOptions.self,
            forKey: .vertexAITranscriptionOptions
        ) ?? .default
        vertexAIGCSBucket = try container.decodeIfPresent(String.self, forKey: .vertexAIGCSBucket)
        vertexAIIncludeSummary = try container.decodeIfPresent(Bool.self, forKey: .vertexAIIncludeSummary) ?? false
        vertexAISummaryModelID = try container.decodeIfPresent(
            String.self,
            forKey: .vertexAISummaryModelID
        ) ?? "gemini-3.7-flash"
        allowDedicatedTranscribeFallbackToGeneralGemini = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowDedicatedTranscribeFallbackToGeneralGemini
        ) ?? false
        customGCloudPath = try container.decodeIfPresent(String.self, forKey: .customGCloudPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(defaultOutputDirectory, forKey: .defaultOutputDirectory)
        try container.encode(outputLocationMode, forKey: .outputLocationMode)
        try container.encodeIfPresent(lastInputDirectory, forKey: .lastInputDirectory)
        try container.encodeIfPresent(lastOutputDirectory, forKey: .lastOutputDirectory)
        try container.encodeIfPresent(lastSelectedGlossaryID, forKey: .lastSelectedGlossaryID)
        try container.encode(lastTemporaryTerms, forKey: .lastTemporaryTerms)
        try container.encode(selectedModels, forKey: .selectedModels)
        try container.encode(autoStartAfterSelection, forKey: .autoStartAfterSelection)
        try container.encode(revealInFinderWhenCompleted, forKey: .revealInFinderWhenCompleted)
        try container.encode(openTextWhenCompleted, forKey: .openTextWhenCompleted)
        try container.encode(showNotificationWhenCompleted, forKey: .showNotificationWhenCompleted)
        try container.encode(keepRawTranscript, forKey: .keepRawTranscript)
        try container.encodeIfPresent(outputFilenameSuffix, forKey: .outputFilenameSuffix)
        try container.encodeIfPresent(rawFilenameSuffix, forKey: .rawFilenameSuffix)
        try container.encode(recentJobLimit, forKey: .recentJobLimit)
        try container.encode(developerMode, forKey: .developerMode)
        try container.encodeIfPresent(customPythonPath, forKey: .customPythonPath)
        try container.encodeIfPresent(customHelperPath, forKey: .customHelperPath)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encode(backendType, forKey: .backendType)
        // googleAIStudioAPIKey is intentionally stored only in Keychain.
        try container.encode(googleAIStudioModelID, forKey: .googleAIStudioModelID)
        try container.encode(
            googleAIStudioTranscriptionOptions,
            forKey: .googleAIStudioTranscriptionOptions
        )
        try container.encodeIfPresent(vertexAIProjectID, forKey: .vertexAIProjectID)
        try container.encode(vertexAILocation, forKey: .vertexAILocation)
        try container.encode(vertexAIModelID, forKey: .vertexAIModelID)
        try container.encode(
            vertexAITranscriptionOptions,
            forKey: .vertexAITranscriptionOptions
        )
        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)
        try container.encode(vertexAIIncludeSummary, forKey: .vertexAIIncludeSummary)
        try container.encode(vertexAISummaryModelID, forKey: .vertexAISummaryModelID)
        try container.encode(
            allowDedicatedTranscribeFallbackToGeneralGemini,
            forKey: .allowDedicatedTranscribeFallbackToGeneralGemini
        )
        try container.encodeIfPresent(customGCloudPath, forKey: .customGCloudPath)
    }

    public var resolvedOutputFilenameSuffix: String {
        OutputNameBuilder.sanitizedSuffix(
            outputFilenameSuffix,
            fallback: OutputNameBuilder.defaultFinalSuffix
        )
    }

    public var resolvedRawFilenameSuffix: String {
        OutputNameBuilder.sanitizedSuffix(
            rawFilenameSuffix,
            fallback: OutputNameBuilder.defaultRawSuffix
        )
    }

    public static func defaultValue(
        fileManager: FileManager = .default,
        developerMode: Bool = false
    ) -> AppSettings {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let output = documents
            .appendingPathComponent("record-to-text", isDirectory: true)
            .appendingPathComponent("轉出的文字", isDirectory: true)

        return AppSettings(
            defaultOutputDirectory: output.path,
            developerMode: developerMode
        )
    }

    public var selectedModelID: String {
        selectedModels[CPUArchitecture.current.rawValue]
            ?? ASRModelDescriptor.currentDefault.id
    }
}

public struct GlossaryPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var terms: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        terms: [String],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.terms = terms
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GlossaryCollection: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var commonTerms: [String]
    public var glossaries: [GlossaryPreset]

    public init(
        schemaVersion: Int = 1,
        commonTerms: [String] = [],
        glossaries: [GlossaryPreset] = []
    ) {
        self.schemaVersion = schemaVersion
        self.commonTerms = commonTerms
        self.glossaries = glossaries
    }
}

public enum TranscriptionStage: String, Codable, CaseIterable, Sendable {
    case queued
    case validating
    case preparingRuntime
    case downloadingModel
    case convertingAudio
    case loadingModel
    case transcribing
    case convertingTraditionalChinese
    case writingOutput
    case completed
    case failed
    case cancelled
    case interrupted

    public var displayName: String {
        switch self {
        case .queued:
            return "等待中"
        case .validating:
            return "驗證音檔"
        case .preparingRuntime:
            return "準備執行環境"
        case .downloadingModel:
            return "下載模型"
        case .convertingAudio:
            return "轉換音訊"
        case .loadingModel:
            return "載入模型"
        case .transcribing:
            return "轉錄中"
        case .convertingTraditionalChinese:
            return "轉換台灣繁體"
        case .writingOutput:
            return "寫入文字檔"
        case .completed:
            return "完成"
        case .failed:
            return "失敗"
        case .cancelled:
            return "已取消"
        case .interrupted:
            return "上次工作被中斷"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        default:
            return false
        }
    }
}

public struct JobSnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case modelID
        case modelRevision
        case language
        case glossaryID
        case glossaryName
        case terms
        case prompt
        case outputLocationMode
        case outputDirectory
        case keepRawTranscript
        case outputFilenameSuffix
        case rawFilenameSuffix
        case backendType
        // Decode-only migration key. `encode(to:)` deliberately omits it.
        case googleAIStudioAPIKey
        case googleAIStudioModelID
        case vertexAIProjectID
        case vertexAILocation
        case vertexAIModelID
        case vertexAIGCSBucket
        case vertexAIIncludeSummary
        case cloudTransport
        case transcriptionOptions
        case resolvedLanguageCodes
        case resolvedCustomVocabulary
        case modelMaximumDurationSeconds
        case modelRecommendedSegmentDurationSeconds
        case vertexAISummaryModelID
        case allowDedicatedTranscribeFallbackToGeneralGemini
        // Legacy runtime-selection keys are intentionally ignored. Runtime
        // paths and the Developer Runtime consent are live authorization, not
        // immutable transcription semantics.
        case developerMode
        case customPythonPath
        case customHelperPath
        case customGCloudPath
        case runtimeSettingsCaptured
    }

    public let modelID: String
    public let modelRevision: String?
    public let language: String
    public let glossaryID: String?
    public let glossaryName: String?
    public let terms: [String]
    public let prompt: String
    public let outputLocationMode: OutputLocationMode
    public let outputDirectory: String
    public let keepRawTranscript: Bool
    public let outputFilenameSuffix: String
    public let rawFilenameSuffix: String
    public let backendType: ASRBackendType
    /// Transient execution credential. This is decoded from legacy ledgers for
    /// migration only and is never encoded into a new ledger.
    public let googleAIStudioAPIKey: String?
    public let googleAIStudioModelID: String
    public let vertexAIProjectID: String?
    public let vertexAILocation: String
    public let vertexAIModelID: String
    public let vertexAIGCSBucket: String?
    public let vertexAIIncludeSummary: Bool
    public let cloudTransport: CloudModelTransport
    public let transcriptionOptions: DedicatedTranscriptionOptions
    public let resolvedLanguageCodes: [String]
    public let resolvedCustomVocabulary: [String]
    public let modelMaximumDurationSeconds: Double?
    public let modelRecommendedSegmentDurationSeconds: Double?
    public let vertexAISummaryModelID: String
    public let allowDedicatedTranscribeFallbackToGeneralGemini: Bool

    public init(
        modelID: String,
        modelRevision: String? = nil,
        language: String = "Chinese",
        glossaryID: String?,
        glossaryName: String?,
        terms: [String],
        prompt: String,
        outputLocationMode: OutputLocationMode,
        outputDirectory: String,
        keepRawTranscript: Bool,
        outputFilenameSuffix: String = OutputNameBuilder.defaultFinalSuffix,
        rawFilenameSuffix: String = OutputNameBuilder.defaultRawSuffix,
        backendType: ASRBackendType = .googleAIStudio,
        googleAIStudioAPIKey: String? = nil,
        googleAIStudioModelID: String = "gemini-3.7-flash",
        vertexAIProjectID: String? = nil,
        vertexAILocation: String = "global",
        vertexAIModelID: String = "gemini-3.7-flash",
        vertexAIGCSBucket: String? = nil,
        vertexAIIncludeSummary: Bool = false,
        cloudTransport: CloudModelTransport = .geminiGenerateContent,
        transcriptionOptions: DedicatedTranscriptionOptions = .default,
        resolvedLanguageCodes: [String] = [],
        resolvedCustomVocabulary: [String] = [],
        modelMaximumDurationSeconds: Double? = nil,
        modelRecommendedSegmentDurationSeconds: Double? = nil,
        vertexAISummaryModelID: String = "gemini-3.7-flash",
        allowDedicatedTranscribeFallbackToGeneralGemini: Bool = false
    ) {
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.language = language
        self.glossaryID = glossaryID
        self.glossaryName = glossaryName
        self.terms = terms
        self.prompt = prompt
        self.outputLocationMode = outputLocationMode
        self.outputDirectory = outputDirectory
        self.keepRawTranscript = keepRawTranscript
        self.outputFilenameSuffix = OutputNameBuilder.sanitizedSuffix(
            outputFilenameSuffix,
            fallback: OutputNameBuilder.defaultFinalSuffix
        )
        self.rawFilenameSuffix = OutputNameBuilder.sanitizedSuffix(
            rawFilenameSuffix,
            fallback: OutputNameBuilder.defaultRawSuffix
        )
        self.backendType = backendType
        self.googleAIStudioAPIKey = googleAIStudioAPIKey
        self.googleAIStudioModelID = googleAIStudioModelID
        self.vertexAIProjectID = vertexAIProjectID
        self.vertexAILocation = vertexAILocation
        self.vertexAIModelID = vertexAIModelID
        self.vertexAIGCSBucket = vertexAIGCSBucket
        self.vertexAIIncludeSummary = vertexAIIncludeSummary
        self.cloudTransport = cloudTransport
        self.transcriptionOptions = transcriptionOptions
        self.resolvedLanguageCodes = resolvedLanguageCodes
        self.resolvedCustomVocabulary = resolvedCustomVocabulary
        self.modelMaximumDurationSeconds = modelMaximumDurationSeconds
        self.modelRecommendedSegmentDurationSeconds =
            modelRecommendedSegmentDurationSeconds
        self.vertexAISummaryModelID = vertexAISummaryModelID
        self.allowDedicatedTranscribeFallbackToGeneralGemini =
            allowDedicatedTranscribeFallbackToGeneralGemini
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        modelRevision = try container.decodeIfPresent(String.self, forKey: .modelRevision)
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "Chinese"
        glossaryID = try container.decodeIfPresent(String.self, forKey: .glossaryID)
        glossaryName = try container.decodeIfPresent(String.self, forKey: .glossaryName)
        terms = try container.decode([String].self, forKey: .terms)
        prompt = try container.decode(String.self, forKey: .prompt)
        outputLocationMode = try container.decode(
            OutputLocationMode.self,
            forKey: .outputLocationMode
        )
        outputDirectory = try container.decode(String.self, forKey: .outputDirectory)
        keepRawTranscript = try container.decode(Bool.self, forKey: .keepRawTranscript)
        outputFilenameSuffix = OutputNameBuilder.sanitizedSuffix(
            try container.decodeIfPresent(String.self, forKey: .outputFilenameSuffix),
            fallback: OutputNameBuilder.defaultFinalSuffix
        )
        rawFilenameSuffix = OutputNameBuilder.sanitizedSuffix(
            try container.decodeIfPresent(String.self, forKey: .rawFilenameSuffix),
            fallback: OutputNameBuilder.defaultRawSuffix
        )
        backendType = try container.decodeIfPresent(ASRBackendType.self, forKey: .backendType) ?? .googleAIStudio
        googleAIStudioAPIKey = try container.decodeIfPresent(String.self, forKey: .googleAIStudioAPIKey)
        googleAIStudioModelID = try container.decodeIfPresent(String.self, forKey: .googleAIStudioModelID) ?? "gemini-3.7-flash"
        vertexAIProjectID = try container.decodeIfPresent(String.self, forKey: .vertexAIProjectID)
        vertexAILocation = try container.decodeIfPresent(String.self, forKey: .vertexAILocation) ?? "global"
        vertexAIModelID = try container.decodeIfPresent(String.self, forKey: .vertexAIModelID) ?? "gemini-3.7-flash"
        vertexAIGCSBucket = try container.decodeIfPresent(String.self, forKey: .vertexAIGCSBucket)
        vertexAIIncludeSummary = try container.decodeIfPresent(Bool.self, forKey: .vertexAIIncludeSummary) ?? false
        let selectedCloudModelID = backendType == .googleAIStudio
            ? googleAIStudioModelID
            : vertexAIModelID
        cloudTransport = try container.decodeIfPresent(
            CloudModelTransport.self,
            forKey: .cloudTransport
        ) ?? CloudModelCatalog.resolvedDescriptor(
            provider: backendType,
            modelID: selectedCloudModelID
        ).transport
        transcriptionOptions = try container.decodeIfPresent(
            DedicatedTranscriptionOptions.self,
            forKey: .transcriptionOptions
        ) ?? .default
        resolvedLanguageCodes = try container.decodeIfPresent(
            [String].self,
            forKey: .resolvedLanguageCodes
        ) ?? transcriptionOptions.resolvedLanguageCodes
        resolvedCustomVocabulary = try container.decodeIfPresent(
            [String].self,
            forKey: .resolvedCustomVocabulary
        ) ?? []
        modelMaximumDurationSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .modelMaximumDurationSeconds
        )
        modelRecommendedSegmentDurationSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .modelRecommendedSegmentDurationSeconds
        )
        vertexAISummaryModelID = try container.decodeIfPresent(
            String.self,
            forKey: .vertexAISummaryModelID
        ) ?? "gemini-3.7-flash"
        allowDedicatedTranscribeFallbackToGeneralGemini = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowDedicatedTranscribeFallbackToGeneralGemini
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(modelRevision, forKey: .modelRevision)
        try container.encode(language, forKey: .language)
        try container.encodeIfPresent(glossaryID, forKey: .glossaryID)
        try container.encodeIfPresent(glossaryName, forKey: .glossaryName)
        try container.encode(terms, forKey: .terms)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(outputLocationMode, forKey: .outputLocationMode)
        try container.encode(outputDirectory, forKey: .outputDirectory)
        try container.encode(keepRawTranscript, forKey: .keepRawTranscript)
        try container.encode(outputFilenameSuffix, forKey: .outputFilenameSuffix)
        try container.encode(rawFilenameSuffix, forKey: .rawFilenameSuffix)
        try container.encode(backendType, forKey: .backendType)
        // googleAIStudioAPIKey is intentionally stored only in Keychain.
        try container.encode(googleAIStudioModelID, forKey: .googleAIStudioModelID)
        try container.encodeIfPresent(vertexAIProjectID, forKey: .vertexAIProjectID)
        try container.encode(vertexAILocation, forKey: .vertexAILocation)
        try container.encode(vertexAIModelID, forKey: .vertexAIModelID)
        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)
        try container.encode(vertexAIIncludeSummary, forKey: .vertexAIIncludeSummary)
        try container.encode(cloudTransport, forKey: .cloudTransport)
        try container.encode(transcriptionOptions, forKey: .transcriptionOptions)
        try container.encode(resolvedLanguageCodes, forKey: .resolvedLanguageCodes)
        try container.encode(
            resolvedCustomVocabulary,
            forKey: .resolvedCustomVocabulary
        )
        try container.encodeIfPresent(
            modelMaximumDurationSeconds,
            forKey: .modelMaximumDurationSeconds
        )
        try container.encodeIfPresent(
            modelRecommendedSegmentDurationSeconds,
            forKey: .modelRecommendedSegmentDurationSeconds
        )
        try container.encode(vertexAISummaryModelID, forKey: .vertexAISummaryModelID)
        try container.encode(
            allowDedicatedTranscribeFallbackToGeneralGemini,
            forKey: .allowDedicatedTranscribeFallbackToGeneralGemini
        )
    }

    /// Returns a copy suitable for transient execution. The credential remains
    /// excluded from Codable output even while present in memory.
    public func withGoogleAIStudioAPIKey(_ apiKey: String?) -> JobSnapshot {
        JobSnapshot(
            modelID: modelID,
            modelRevision: modelRevision,
            language: language,
            glossaryID: glossaryID,
            glossaryName: glossaryName,
            terms: terms,
            prompt: prompt,
            outputLocationMode: outputLocationMode,
            outputDirectory: outputDirectory,
            keepRawTranscript: keepRawTranscript,
            outputFilenameSuffix: outputFilenameSuffix,
            rawFilenameSuffix: rawFilenameSuffix,
            backendType: backendType,
            googleAIStudioAPIKey: apiKey,
            googleAIStudioModelID: googleAIStudioModelID,
            vertexAIProjectID: vertexAIProjectID,
            vertexAILocation: vertexAILocation,
            vertexAIModelID: vertexAIModelID,
            vertexAIGCSBucket: vertexAIGCSBucket,
            vertexAIIncludeSummary: vertexAIIncludeSummary,
            cloudTransport: cloudTransport,
            transcriptionOptions: transcriptionOptions,
            resolvedLanguageCodes: resolvedLanguageCodes,
            resolvedCustomVocabulary: resolvedCustomVocabulary,
            modelMaximumDurationSeconds: modelMaximumDurationSeconds,
            modelRecommendedSegmentDurationSeconds:
                modelRecommendedSegmentDurationSeconds,
            vertexAISummaryModelID: vertexAISummaryModelID,
            allowDedicatedTranscribeFallbackToGeneralGemini:
                allowDedicatedTranscribeFallbackToGeneralGemini
        )
    }
}

public extension AppSettings {
    /// Applies immutable transcription choices captured by a queued job while
    /// retaining current authorization and executable paths. In particular,
    /// Developer Runtime consent must be revocable and environment repairs
    /// must take effect for work that is already queued.
    func applyingRuntimeConfiguration(from snapshot: JobSnapshot) -> AppSettings {
        var resolved = self
        resolved.backendType = snapshot.backendType
        resolved.selectedModels[CPUArchitecture.current.rawValue] = snapshot.modelID
        resolved.googleAIStudioModelID = snapshot.googleAIStudioModelID
        resolved.vertexAIProjectID = snapshot.vertexAIProjectID
        resolved.vertexAILocation = snapshot.vertexAILocation
        resolved.vertexAIModelID = snapshot.vertexAIModelID
        resolved.vertexAIGCSBucket = snapshot.vertexAIGCSBucket
        resolved.vertexAIIncludeSummary = snapshot.vertexAIIncludeSummary
        resolved.vertexAISummaryModelID = snapshot.vertexAISummaryModelID
        resolved.allowDedicatedTranscribeFallbackToGeneralGemini =
            snapshot.allowDedicatedTranscribeFallbackToGeneralGemini
        if snapshot.backendType == .googleAIStudio {
            resolved.googleAIStudioTranscriptionOptions =
                snapshot.transcriptionOptions
        } else if snapshot.backendType == .vertexAI {
            resolved.vertexAITranscriptionOptions = snapshot.transcriptionOptions
        }
        return resolved
    }
}

public struct TranscriptionSourceSlice: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let durationSeconds: Double
    public let partIndex: Int
    public let partCount: Int

    public init(
        startSeconds: Double,
        durationSeconds: Double,
        partIndex: Int,
        partCount: Int
    ) {
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.partIndex = partIndex
        self.partCount = partCount
    }

    public var endSeconds: Double {
        startSeconds + durationSeconds
    }

    public var displayName: String {
        "第 \(partIndex)／\(partCount) 段"
    }

    public static func splitInHalf(
        durationSeconds: Double
    ) -> [TranscriptionSourceSlice] {
        let midpoint = durationSeconds / 2
        return [
            TranscriptionSourceSlice(
                startSeconds: 0,
                durationSeconds: midpoint,
                partIndex: 1,
                partCount: 2
            ),
            TranscriptionSourceSlice(
                startSeconds: midpoint,
                durationSeconds: durationSeconds - midpoint,
                partIndex: 2,
                partCount: 2
            )
        ]
    }

    public func validate(sourceDuration: Double) throws {
        guard
            sourceDuration.isFinite,
            sourceDuration > 0,
            startSeconds.isFinite,
            durationSeconds.isFinite,
            startSeconds >= 0,
            durationSeconds > 0,
            partCount >= 2,
            partIndex >= 1,
            partIndex <= partCount,
            endSeconds <= sourceDuration + 0.5
        else {
            throw TranscriptionSourceSliceError.invalid(
                startSeconds: startSeconds,
                durationSeconds: durationSeconds,
                sourceDuration: sourceDuration
            )
        }
    }
}

public enum TranscriptionSourceSliceError: LocalizedError, Equatable {
    case invalid(startSeconds: Double, durationSeconds: Double, sourceDuration: Double)

    public var errorDescription: String? {
        switch self {
        case let .invalid(startSeconds, durationSeconds, sourceDuration):
            return String(
                format: "來源切片無效：起點 %.3f 秒、長度 %.3f 秒，音檔長度 %.3f 秒。",
                startSeconds,
                durationSeconds,
                sourceDuration
            )
        }
    }
}

public struct JobFailure: Codable, Equatable, Sendable {
    public let stage: TranscriptionStage
    public let userMessage: String
    public let technicalDetails: String
    public let recoverable: Bool
    public let recoveryDirectory: String?
    public let partialTranscriptPath: String?

    public init(
        stage: TranscriptionStage,
        userMessage: String,
        technicalDetails: String,
        recoverable: Bool,
        recoveryDirectory: String? = nil,
        partialTranscriptPath: String? = nil
    ) {
        self.stage = stage
        self.userMessage = userMessage
        self.technicalDetails = technicalDetails
        self.recoverable = recoverable
        self.recoveryDirectory = recoveryDirectory
        self.partialTranscriptPath = partialTranscriptPath
    }
}

public struct TranscriptionJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourcePath: String
    public var snapshot: JobSnapshot
    public let sourceSlice: TranscriptionSourceSlice?
    public var stage: TranscriptionStage
    public var progressCurrent: Double?
    public var progressTotal: Double?
    public var progressUnit: String?
    public var outputPath: String?
    public var rawOutputPath: String?
    public var metadataOutputPath: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var failure: JobFailure?
    public var logLines: [String]

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        snapshot: JobSnapshot,
        sourceSlice: TranscriptionSourceSlice? = nil,
        stage: TranscriptionStage = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.snapshot = snapshot
        self.sourceSlice = sourceSlice
        self.stage = stage
        self.progressCurrent = nil
        self.progressTotal = nil
        self.progressUnit = nil
        self.outputPath = nil
        self.rawOutputPath = nil
        self.metadataOutputPath = nil
        self.createdAt = createdAt
        self.startedAt = nil
        self.completedAt = nil
        self.failure = nil
        self.logLines = []
    }

    public var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    public var displayName: String {
        guard let sourceSlice else {
            return sourceURL.lastPathComponent
        }
        return "\(sourceURL.lastPathComponent) · \(sourceSlice.displayName)"
    }
}

public struct RecentJobSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourcePath: String
    public let sourceSlice: TranscriptionSourceSlice?
    public let outputPath: String?
    public let metadataOutputPath: String?
    public let stage: TranscriptionStage
    public let startedAt: Date?
    public let completedAt: Date?
    public let modelID: String
    public let glossaryName: String?

    public init(
        id: UUID,
        sourcePath: String,
        sourceSlice: TranscriptionSourceSlice? = nil,
        outputPath: String?,
        metadataOutputPath: String? = nil,
        stage: TranscriptionStage,
        startedAt: Date?,
        completedAt: Date?,
        modelID: String,
        glossaryName: String?
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.sourceSlice = sourceSlice
        self.outputPath = outputPath
        self.metadataOutputPath = metadataOutputPath
        self.stage = stage
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.modelID = modelID
        self.glossaryName = glossaryName
    }

    public init(job: TranscriptionJob) {
        self.init(
            id: job.id,
            sourcePath: job.sourcePath,
            sourceSlice: job.sourceSlice,
            outputPath: job.outputPath,
            metadataOutputPath: job.metadataOutputPath,
            stage: job.stage,
            startedAt: job.startedAt,
            completedAt: job.completedAt,
            modelID: job.snapshot.modelID,
            glossaryName: job.snapshot.glossaryName
        )
    }

    public var displayName: String {
        let name = URL(fileURLWithPath: sourcePath).lastPathComponent
        guard let sourceSlice else {
            return name
        }
        return "\(name) · \(sourceSlice.displayName)"
    }

    public func fileStatus(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> RecentJobFileStatus {
        let sourceExists = fileExists(sourcePath)
        let outputRequired = stage == .completed
        let outputExists = outputPath.map(fileExists) ?? false

        switch (sourceExists, outputRequired, outputExists) {
        case (false, true, false):
            return .sourceAndOutputMissing
        case (false, _, _):
            return .sourceMissing
        case (true, true, false):
            return .outputMissing
        default:
            return .available
        }
    }
}

public enum RecentJobFileStatus: String, Codable, Equatable, Sendable {
    case available
    case sourceMissing
    case outputMissing
    case sourceAndOutputMissing

    public var displayName: String? {
        switch self {
        case .available:
            return nil
        case .sourceMissing:
            return "來源音檔已移動或刪除"
        case .outputMissing:
            return "輸出文字檔已移動或刪除"
        case .sourceAndOutputMissing:
            return "來源與輸出檔都找不到"
        }
    }
}

public struct RecentJobCollection: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var jobs: [RecentJobSummary]

    public init(schemaVersion: Int = 1, jobs: [RecentJobSummary] = []) {
        self.schemaVersion = schemaVersion
        self.jobs = jobs
    }
}

public struct JobLedgerCollection: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var jobs: [TranscriptionJob]

    public init(schemaVersion: Int = 1, jobs: [TranscriptionJob] = []) {
        self.schemaVersion = schemaVersion
        self.jobs = jobs
    }
}

public struct RuntimeManifest: Codable, Equatable, Sendable {
    public struct Components: Codable, Equatable, Sendable {
        public let python: String
        public let mlxAudio: String?
        public let transformers: String?
        public let ffmpeg: String
        public let openCC: String

        public init(
            python: String,
            mlxAudio: String? = nil,
            transformers: String? = nil,
            ffmpeg: String,
            openCC: String
        ) {
            self.python = python
            self.mlxAudio = mlxAudio
            self.transformers = transformers
            self.ffmpeg = ffmpeg
            self.openCC = openCC
        }
    }

    public let schemaVersion: Int
    public let runtimeVersion: String
    public let architecture: CPUArchitecture
    public let minimumOS: String
    public let downloadURL: URL
    public let sha256: String
    public let downloadSize: Int64
    public let teamIdentifier: String
    public let components: Components

    public init(
        schemaVersion: Int = 1,
        runtimeVersion: String,
        architecture: CPUArchitecture,
        minimumOS: String,
        downloadURL: URL,
        sha256: String,
        downloadSize: Int64,
        teamIdentifier: String,
        components: Components
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeVersion = runtimeVersion
        self.architecture = architecture
        self.minimumOS = minimumOS
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.downloadSize = downloadSize
        self.teamIdentifier = teamIdentifier
        self.components = components
    }
}

public struct AudioMetadata: Codable, Equatable, Sendable {
    public let duration: Double
    public let codecName: String
    public let sampleRate: Int
    public let channels: Int

    public init(duration: Double, codecName: String, sampleRate: Int, channels: Int) {
        self.duration = duration
        self.codecName = codecName
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var estimatedPCMBytes: Int64 {
        Int64(max(duration, 0) * 16_000 * 2) + 16 * 1_024 * 1_024
    }
}

public struct PipelineResult: Equatable, Sendable {
    public let outputURL: URL
    public let rawOutputURL: URL?
    public let metadataOutputURL: URL?
    public let duration: TimeInterval
    public let containsSkippedAudio: Bool

    public init(
        outputURL: URL,
        rawOutputURL: URL?,
        metadataOutputURL: URL? = nil,
        duration: TimeInterval,
        containsSkippedAudio: Bool = false
    ) {
        self.outputURL = outputURL
        self.rawOutputURL = rawOutputURL
        self.metadataOutputURL = metadataOutputURL
        self.duration = duration
        self.containsSkippedAudio = containsSkippedAudio
    }
}

public enum PipelineUpdate: Sendable {
    case stage(TranscriptionStage)
    case progress(current: Double, total: Double, unit: String)
    case log(level: String, message: String)
    case warning(code: String, message: String)
}
