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

public struct AppSettings: Codable, Equatable, Sendable {
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

    public init(
        schemaVersion: Int = 1,
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
        hasCompletedOnboarding: Bool = false
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
        rawFilenameSuffix: String = OutputNameBuilder.defaultRawSuffix
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
    public let snapshot: JobSnapshot
    public var stage: TranscriptionStage
    public var progressCurrent: Double?
    public var progressTotal: Double?
    public var progressUnit: String?
    public var outputPath: String?
    public var rawOutputPath: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var failure: JobFailure?
    public var logLines: [String]

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        snapshot: JobSnapshot,
        stage: TranscriptionStage = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.snapshot = snapshot
        self.stage = stage
        self.progressCurrent = nil
        self.progressTotal = nil
        self.progressUnit = nil
        self.outputPath = nil
        self.rawOutputPath = nil
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
        sourceURL.lastPathComponent
    }
}

public struct RecentJobSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourcePath: String
    public let outputPath: String?
    public let stage: TranscriptionStage
    public let startedAt: Date?
    public let completedAt: Date?
    public let modelID: String
    public let glossaryName: String?

    public init(
        id: UUID,
        sourcePath: String,
        outputPath: String?,
        stage: TranscriptionStage,
        startedAt: Date?,
        completedAt: Date?,
        modelID: String,
        glossaryName: String?
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.outputPath = outputPath
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
            outputPath: job.outputPath,
            stage: job.stage,
            startedAt: job.startedAt,
            completedAt: job.completedAt,
            modelID: job.snapshot.modelID,
            glossaryName: job.snapshot.glossaryName
        )
    }

    public var displayName: String {
        URL(fileURLWithPath: sourcePath).lastPathComponent
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
    public let duration: TimeInterval
    public let containsSkippedAudio: Bool

    public init(
        outputURL: URL,
        rawOutputURL: URL?,
        duration: TimeInterval,
        containsSkippedAudio: Bool = false
    ) {
        self.outputURL = outputURL
        self.rawOutputURL = rawOutputURL
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
