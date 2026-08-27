import Foundation

public enum CloudModelTransport: String, Codable, CaseIterable, Sendable {
    case geminiGenerateContent
    case geminiInteractionsTranscribe
    case agentPlatformTranscribe

    public var displayName: String {
        switch self {
        case .geminiGenerateContent:
            return "Gemini generateContent"
        case .geminiInteractionsTranscribe:
            return "Gemini Interactions Transcribe"
        case .agentPlatformTranscribe:
            return "Gemini Agent Platform Transcribe"
        }
    }
}

public enum DedicatedTranscriptionMode: String, Codable, CaseIterable, Sendable {
    case verbatim
    case smart

    public var displayName: String {
        switch self {
        case .verbatim:
            return "忠實逐字"
        case .smart:
            return "智慧整理"
        }
    }
}

public enum TranscriptionLanguagePreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case taiwanMandarin
    case custom

    public var displayName: String {
        switch self {
        case .automatic:
            return "自動偵測"
        case .taiwanMandarin:
            return "台灣華語優先"
        case .custom:
            return "自訂語言代碼"
        }
    }
}

public struct DedicatedTranscriptionOptions: Codable, Equatable, Sendable {
    public var mode: DedicatedTranscriptionMode
    public var languagePreference: TranscriptionLanguagePreference
    public var customLanguageCodes: [String]
    public var diarizationEnabled: Bool
    public var wordTimestampsEnabled: Bool
    public var writeMetadataJSON: Bool

    public init(
        mode: DedicatedTranscriptionMode = .verbatim,
        languagePreference: TranscriptionLanguagePreference = .automatic,
        customLanguageCodes: [String] = [],
        diarizationEnabled: Bool = false,
        wordTimestampsEnabled: Bool = false,
        writeMetadataJSON: Bool = false
    ) {
        self.mode = mode
        self.languagePreference = languagePreference
        self.customLanguageCodes = customLanguageCodes
        self.diarizationEnabled = diarizationEnabled
        self.wordTimestampsEnabled = wordTimestampsEnabled
        self.writeMetadataJSON = writeMetadataJSON
    }

    public static let `default` = DedicatedTranscriptionOptions()

    public var resolvedLanguageCodes: [String] {
        switch languagePreference {
        case .automatic:
            return []
        case .taiwanMandarin:
            return ["cmn-Hant-TW"]
        case .custom:
            return Self.normalizedCodes(customLanguageCodes)
        }
    }

    public var requestsStructuredMetadata: Bool {
        diarizationEnabled || wordTimestampsEnabled || writeMetadataJSON
    }

    public func normalizedForUI() -> DedicatedTranscriptionOptions {
        var copy = self
        if copy.mode == .smart {
            copy.diarizationEnabled = false
            copy.wordTimestampsEnabled = false
        }
        return copy
    }

    private static func normalizedCodes(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { continue }
            let key = code.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(code)
        }
        return result
    }
}

public struct CloudModelDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let note: String
    public let provider: ASRBackendType
    public let transport: CloudModelTransport
    public let isPreview: Bool
    public let maximumAudioDurationSeconds: TimeInterval
    public let recommendedSegmentDurationSeconds: TimeInterval
    public let supportsCustomVocabulary: Bool
    public let supportsLanguageHints: Bool
    public let supportsSmartMode: Bool
    public let supportsDiarization: Bool
    public let supportsWordTimestamps: Bool
    public let supportsSystemInstruction: Bool
    public let supportsSummary: Bool
    public let requiredLocation: String?
    public let apiVersion: String

    public init(
        id: String,
        displayName: String,
        note: String,
        provider: ASRBackendType,
        transport: CloudModelTransport,
        isPreview: Bool,
        maximumAudioDurationSeconds: TimeInterval,
        recommendedSegmentDurationSeconds: TimeInterval,
        supportsCustomVocabulary: Bool,
        supportsLanguageHints: Bool,
        supportsSmartMode: Bool,
        supportsDiarization: Bool,
        supportsWordTimestamps: Bool,
        supportsSystemInstruction: Bool,
        supportsSummary: Bool,
        requiredLocation: String?,
        apiVersion: String
    ) {
        self.id = id
        self.displayName = displayName
        self.note = note
        self.provider = provider
        self.transport = transport
        self.isPreview = isPreview
        self.maximumAudioDurationSeconds = maximumAudioDurationSeconds
        self.recommendedSegmentDurationSeconds = recommendedSegmentDurationSeconds
        self.supportsCustomVocabulary = supportsCustomVocabulary
        self.supportsLanguageHints = supportsLanguageHints
        self.supportsSmartMode = supportsSmartMode
        self.supportsDiarization = supportsDiarization
        self.supportsWordTimestamps = supportsWordTimestamps
        self.supportsSystemInstruction = supportsSystemInstruction
        self.supportsSummary = supportsSummary
        self.requiredLocation = requiredLocation
        self.apiVersion = apiVersion
    }

    public var isDedicatedTranscription: Bool {
        transport != .geminiGenerateContent
    }

    public func effectiveLocation(requestedLocation: String) -> String {
        if let requiredLocation {
            return requiredLocation
        }
        let trimmed = requestedLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "global" : trimmed
    }

    public func effectiveMaximumAudioDuration(
        options: DedicatedTranscriptionOptions
    ) -> TimeInterval {
        if transport == .geminiInteractionsTranscribe,
           options.diarizationEnabled || options.wordTimestampsEnabled {
            return min(maximumAudioDurationSeconds, 1_800)
        }
        return maximumAudioDurationSeconds
    }
}

public enum GoogleAIStudioModelCatalog {
    public static let models: [CloudModelDescriptor] = [
        CloudModelDescriptor(
            id: "gemini-3.5-transcribe",
            displayName: "Gemini 3.5 Transcribe",
            note: "專用語音轉文字模型（Preview）；支援詞彙提示、說話者與逐字時間戳。",
            provider: .googleAIStudio,
            transport: .geminiInteractionsTranscribe,
            isPreview: true,
            maximumAudioDurationSeconds: 3_600,
            recommendedSegmentDurationSeconds: 1_200,
            supportsCustomVocabulary: true,
            supportsLanguageHints: true,
            supportsSmartMode: true,
            supportsDiarization: true,
            supportsWordTimestamps: true,
            supportsSystemInstruction: false,
            supportsSummary: false,
            requiredLocation: nil,
            apiVersion: "v1beta"
        ),
        CloudModelDescriptor.generalAIStudio(
            id: "gemini-3.7-flash",
            displayName: "Gemini 3.7 Flash",
            note: "一般 Gemini 音訊理解路徑；保留完整 Prompt 與現有 fallback。"
        ),
        CloudModelDescriptor.generalAIStudio(
            id: "gemini-3.6-flash",
            displayName: "Gemini 3.6 Flash",
            note: "一般 Gemini 備援模型，速度快且高可用。"
        ),
        CloudModelDescriptor.generalAIStudio(
            id: "gemini-3.1-pro-preview",
            displayName: "Gemini 3.1 Pro",
            note: "一般 Gemini 高推論模型，適合複雜術語與中英文混講。",
            isPreview: true
        )
    ]

    public static func descriptor(id: String) -> CloudModelDescriptor? {
        models.first { $0.id == id }
    }
}

public enum GCloudModelCatalog {
    public static let models: [CloudModelDescriptor] = [
        CloudModelDescriptor(
            id: "gemini-3.5-transcribe-preview",
            displayName: "Gemini 3.5 Transcribe Preview",
            note: "gcloud / Agent Platform 專用轉錄模型；支援忠實逐字／智慧整理，固定使用 global，單段以 14 分鐘安全切片。",
            provider: .vertexAI,
            transport: .agentPlatformTranscribe,
            isPreview: true,
            maximumAudioDurationSeconds: 900,
            recommendedSegmentDurationSeconds: 840,
            supportsCustomVocabulary: true,
            supportsLanguageHints: true,
            supportsSmartMode: true,
            supportsDiarization: true,
            supportsWordTimestamps: true,
            supportsSystemInstruction: false,
            supportsSummary: false,
            requiredLocation: "global",
            apiVersion: "v1beta1"
        ),
        CloudModelDescriptor.generalVertex(
            id: "gemini-3.7-flash",
            displayName: "Gemini 3.7 Flash",
            note: "一般 Vertex Gemini 音訊理解路徑；保留完整 Prompt 與現有 fallback。"
        ),
        CloudModelDescriptor.generalVertex(
            id: "gemini-3.6-flash",
            displayName: "Gemini 3.6 Flash",
            note: "一般 Vertex Gemini 備援模型。"
        ),
        CloudModelDescriptor.generalVertex(
            id: "gemini-3.1-pro-preview",
            displayName: "Gemini 3.1 Pro",
            note: "一般 Vertex Gemini 高推論模型，可作為摘要模型。",
            isPreview: true
        )
    ]

    public static func descriptor(id: String) -> CloudModelDescriptor? {
        models.first { $0.id == id }
    }

    public static var summaryModels: [CloudModelDescriptor] {
        models.filter(\.supportsSummary)
    }
}

public enum CloudModelCatalog {
    public static func models(for provider: ASRBackendType) -> [CloudModelDescriptor] {
        switch provider {
        case .googleAIStudio:
            return GoogleAIStudioModelCatalog.models
        case .vertexAI:
            return GCloudModelCatalog.models
        case .localQwen:
            return []
        }
    }

    public static func descriptor(
        provider: ASRBackendType,
        modelID: String
    ) -> CloudModelDescriptor? {
        models(for: provider).first { $0.id == modelID }
    }

    public static func resolvedDescriptor(
        provider: ASRBackendType,
        modelID: String
    ) -> CloudModelDescriptor {
        if let known = descriptor(provider: provider, modelID: modelID) {
            return known
        }
        switch provider {
        case .googleAIStudio:
            return .generalAIStudio(
                id: modelID,
                displayName: modelID,
                note: "自訂模型 ID；預設以一般 Gemini generateContent 契約呼叫。"
            )
        case .vertexAI:
            return .generalVertex(
                id: modelID,
                displayName: modelID,
                note: "自訂模型 ID；預設以一般 Vertex generateContent 契約呼叫。"
            )
        case .localQwen:
            return CloudModelDescriptor(
                id: modelID,
                displayName: modelID,
                note: "本機模型",
                provider: .localQwen,
                transport: .geminiGenerateContent,
                isPreview: false,
                maximumAudioDurationSeconds: 1_200,
                recommendedSegmentDurationSeconds: 1_200,
                supportsCustomVocabulary: false,
                supportsLanguageHints: false,
                supportsSmartMode: false,
                supportsDiarization: false,
                supportsWordTimestamps: false,
                supportsSystemInstruction: false,
                supportsSummary: false,
                requiredLocation: nil,
                apiVersion: "local"
            )
        }
    }
}

private extension CloudModelDescriptor {
    static func generalAIStudio(
        id: String,
        displayName: String,
        note: String,
        isPreview: Bool = false
    ) -> CloudModelDescriptor {
        CloudModelDescriptor(
            id: id,
            displayName: displayName,
            note: note,
            provider: .googleAIStudio,
            transport: .geminiGenerateContent,
            isPreview: isPreview,
            maximumAudioDurationSeconds: 1_200,
            recommendedSegmentDurationSeconds: 1_200,
            supportsCustomVocabulary: false,
            supportsLanguageHints: false,
            supportsSmartMode: false,
            supportsDiarization: false,
            supportsWordTimestamps: false,
            supportsSystemInstruction: true,
            supportsSummary: true,
            requiredLocation: nil,
            apiVersion: "v1beta"
        )
    }

    static func generalVertex(
        id: String,
        displayName: String,
        note: String,
        isPreview: Bool = false
    ) -> CloudModelDescriptor {
        CloudModelDescriptor(
            id: id,
            displayName: displayName,
            note: note,
            provider: .vertexAI,
            transport: .geminiGenerateContent,
            isPreview: isPreview,
            maximumAudioDurationSeconds: 1_200,
            recommendedSegmentDurationSeconds: 1_200,
            supportsCustomVocabulary: false,
            supportsLanguageHints: false,
            supportsSmartMode: false,
            supportsDiarization: false,
            supportsWordTimestamps: false,
            supportsSystemInstruction: true,
            supportsSummary: true,
            requiredLocation: nil,
            apiVersion: "v1"
        )
    }
}

public enum CloudTranscriptionConfigurationError: LocalizedError, Equatable {
    case smartModeUnsupported(provider: ASRBackendType)
    case smartModeMetadataConflict
    case diarizationUnsupported(modelID: String)
    case wordTimestampsUnsupported(modelID: String)
    case vocabularyTooLarge(count: Int, maximum: Int)
    case customLanguageCodesRequired

    public var errorDescription: String? {
        switch self {
        case let .smartModeUnsupported(provider):
            return "\(provider.displayName) 的目前專用轉錄契約不支援智慧整理模式。"
        case .smartModeMetadataConflict:
            return "智慧整理模式不能同時啟用說話者辨識或逐字時間戳。請改用忠實逐字模式。"
        case let .diarizationUnsupported(modelID):
            return "模型 \(modelID) 不支援說話者辨識。"
        case let .wordTimestampsUnsupported(modelID):
            return "模型 \(modelID) 不支援逐字時間戳。"
        case let .vocabularyTooLarge(count, maximum):
            return "專有名詞共 \(count) 個，超過專用轉錄模型上限 \(maximum) 個。請精簡詞庫後再加入工作。"
        case .customLanguageCodesRequired:
            return "已選擇自訂語言代碼，但尚未輸入任何有效的 BCP-47 語言代碼。"
        }
    }
}

public enum CloudTranscriptionPolicy {
    public static let maximumCustomVocabularyCount = 1_000
    public static let recommendedCustomVocabularyCount = 100

    public static func normalizedVocabulary(_ values: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let normalized = raw
                .precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
        }
        guard result.count <= maximumCustomVocabularyCount else {
            throw CloudTranscriptionConfigurationError.vocabularyTooLarge(
                count: result.count,
                maximum: maximumCustomVocabularyCount
            )
        }
        return result
    }

    public static func validate(
        descriptor: CloudModelDescriptor,
        options: DedicatedTranscriptionOptions,
        vocabulary: [String]
    ) throws {
        _ = try normalizedVocabulary(vocabulary)
        guard descriptor.isDedicatedTranscription else { return }

        if options.languagePreference == .custom,
           options.resolvedLanguageCodes.isEmpty {
            throw CloudTranscriptionConfigurationError.customLanguageCodesRequired
        }
        if options.mode == .smart {
            guard descriptor.supportsSmartMode else {
                throw CloudTranscriptionConfigurationError.smartModeUnsupported(
                    provider: descriptor.provider
                )
            }
            if options.diarizationEnabled || options.wordTimestampsEnabled {
                throw CloudTranscriptionConfigurationError.smartModeMetadataConflict
            }
        }
        if options.diarizationEnabled, !descriptor.supportsDiarization {
            throw CloudTranscriptionConfigurationError.diarizationUnsupported(
                modelID: descriptor.id
            )
        }
        if options.wordTimestampsEnabled, !descriptor.supportsWordTimestamps {
            throw CloudTranscriptionConfigurationError.wordTimestampsUnsupported(
                modelID: descriptor.id
            )
        }
    }
}

public struct TimedWord: Codable, Equatable, Sendable {
    public var text: String
    public var speaker: String?
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var segmentIndex: Int

    public init(
        text: String,
        speaker: String? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        segmentIndex: Int = 0
    ) {
        self.text = text
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.segmentIndex = segmentIndex
    }
}

public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var speaker: String
    public var text: String
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var segmentIndex: Int

    public init(
        speaker: String,
        text: String,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        segmentIndex: Int = 0
    ) {
        self.speaker = speaker
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.segmentIndex = segmentIndex
    }
}

public struct CloudTranscriptionResult: Equatable, Sendable {
    public var text: String
    public var modelID: String
    public var transport: CloudModelTransport
    public var detectedLanguageCodes: [String]
    public var speakerTurns: [SpeakerTurn]
    public var words: [TimedWord]
    public var providerResponseID: String?

    public init(
        text: String,
        modelID: String,
        transport: CloudModelTransport,
        detectedLanguageCodes: [String] = [],
        speakerTurns: [SpeakerTurn] = [],
        words: [TimedWord] = [],
        providerResponseID: String? = nil
    ) {
        self.text = text
        self.modelID = modelID
        self.transport = transport
        self.detectedLanguageCodes = detectedLanguageCodes
        self.speakerTurns = speakerTurns
        self.words = words
        self.providerResponseID = providerResponseID
    }

    public func applyingSegmentOffset(
        _ offsetSeconds: Double,
        segmentIndex: Int
    ) -> CloudTranscriptionResult {
        func scopedSpeaker(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return String(format: "segment-%04d:%@", segmentIndex, value)
        }

        var copy = self
        copy.words = words.map { word in
            TimedWord(
                text: word.text,
                speaker: scopedSpeaker(word.speaker),
                startSeconds: word.startSeconds.map { $0 + offsetSeconds },
                endSeconds: word.endSeconds.map { $0 + offsetSeconds },
                segmentIndex: segmentIndex
            )
        }
        copy.speakerTurns = speakerTurns.map { turn in
            SpeakerTurn(
                speaker: scopedSpeaker(turn.speaker) ?? turn.speaker,
                text: turn.text,
                startSeconds: turn.startSeconds.map { $0 + offsetSeconds },
                endSeconds: turn.endSeconds.map { $0 + offsetSeconds },
                segmentIndex: segmentIndex
            )
        }
        return copy
    }
}

public struct CloudTranscriptSegmentMetadata: Codable, Equatable, Sendable {
    public let index: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let detectedLanguageCodes: [String]
    public let speakerTurns: [SpeakerTurn]
    public let words: [TimedWord]

    public init(
        index: Int,
        startSeconds: Double,
        endSeconds: Double,
        result: CloudTranscriptionResult
    ) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = result.text
        self.detectedLanguageCodes = result.detectedLanguageCodes
        self.speakerTurns = result.speakerTurns
        self.words = result.words
    }
}

public struct CloudTranscriptMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let provider: ASRBackendType
    public let modelID: String
    public let transport: CloudModelTransport
    public let mode: DedicatedTranscriptionMode
    public let requestedLanguageCodes: [String]
    public let speakerScope: String
    public let segments: [CloudTranscriptSegmentMetadata]

    public init(
        schemaVersion: Int = 1,
        provider: ASRBackendType,
        modelID: String,
        transport: CloudModelTransport,
        mode: DedicatedTranscriptionMode,
        requestedLanguageCodes: [String],
        speakerScope: String = "segmentLocal",
        segments: [CloudTranscriptSegmentMetadata]
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.modelID = modelID
        self.transport = transport
        self.mode = mode
        self.requestedLanguageCodes = requestedLanguageCodes
        self.speakerScope = speakerScope
        self.segments = segments
    }
}

public enum GoogleDurationParser {
    public static func seconds(from value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        guard var text = value as? String else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("s") {
            text.removeLast()
        }
        guard let parsed = Double(text), parsed.isFinite else { return nil }
        return parsed
    }
}
