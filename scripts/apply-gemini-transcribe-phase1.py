#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old[:120]!r}")
    path.write_text(text.replace(old, new, 1))


def main() -> None:
    models = ROOT / "Sources/RecordToTextCore/Models.swift"
    segmentation = ROOT / "Sources/RecordToTextCore/AudioSegmentation.swift"

    marker = "case googleAIStudioTranscriptionOptions"
    if marker in models.read_text():
        print("phase 1 already applied")
        return

    replace_once(
        models,
        '''        case googleAIStudioModelID
        case vertexAIProjectID
        case vertexAILocation
        case vertexAIModelID
        case vertexAIGCSBucket
        case vertexAIIncludeSummary
        case customGCloudPath
''',
        '''        case googleAIStudioModelID
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
'''
    )

    replace_once(
        models,
        '''    public var googleAIStudioAPIKey: String?
    public var googleAIStudioModelID: String
    public var vertexAIProjectID: String?
    public var vertexAILocation: String
    public var vertexAIModelID: String
    public var vertexAIGCSBucket: String?
    public var vertexAIIncludeSummary: Bool
    public var customGCloudPath: String?
''',
        '''    public var googleAIStudioAPIKey: String?
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
'''
    )

    replace_once(
        models,
        """    public init(
        schemaVersion: Int = 1,
        defaultOutputDirectory: String,
""",
        """    public init(
        schemaVersion: Int = 2,
        defaultOutputDirectory: String,
"""
    )

    replace_once(
        models,
        '''        googleAIStudioAPIKey: String? = nil,
        googleAIStudioModelID: String = "gemini-3.7-flash",
        vertexAIProjectID: String? = nil,
        vertexAILocation: String = "global",
        vertexAIModelID: String = "gemini-3.7-flash",
        vertexAIGCSBucket: String? = nil,
        vertexAIIncludeSummary: Bool = false,
        customGCloudPath: String? = nil
''',
        '''        googleAIStudioAPIKey: String? = nil,
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
'''
    )

    replace_once(
        models,
        '''        self.googleAIStudioAPIKey = googleAIStudioAPIKey
        self.googleAIStudioModelID = googleAIStudioModelID
        self.vertexAIProjectID = vertexAIProjectID
        self.vertexAILocation = vertexAILocation
        self.vertexAIModelID = vertexAIModelID
        self.vertexAIGCSBucket = vertexAIGCSBucket
        self.vertexAIIncludeSummary = vertexAIIncludeSummary
        self.customGCloudPath = customGCloudPath
''',
        '''        self.googleAIStudioAPIKey = googleAIStudioAPIKey
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
'''
    )

    replace_once(
        models,
        '''        googleAIStudioAPIKey = try container.decodeIfPresent(String.self, forKey: .googleAIStudioAPIKey)
        googleAIStudioModelID = try container.decodeIfPresent(String.self, forKey: .googleAIStudioModelID) ?? "gemini-3.7-flash"
        vertexAIProjectID = try container.decodeIfPresent(String.self, forKey: .vertexAIProjectID)
        vertexAILocation = try container.decodeIfPresent(String.self, forKey: .vertexAILocation) ?? "global"
        vertexAIModelID = try container.decodeIfPresent(String.self, forKey: .vertexAIModelID) ?? "gemini-3.7-flash"
        vertexAIGCSBucket = try container.decodeIfPresent(String.self, forKey: .vertexAIGCSBucket)
        vertexAIIncludeSummary = try container.decodeIfPresent(Bool.self, forKey: .vertexAIIncludeSummary) ?? false
        customGCloudPath = try container.decodeIfPresent(String.self, forKey: .customGCloudPath)
''',
        '''        googleAIStudioAPIKey = try container.decodeIfPresent(String.self, forKey: .googleAIStudioAPIKey)
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
'''
    )

    replace_once(
        models,
        '''        try container.encode(googleAIStudioModelID, forKey: .googleAIStudioModelID)
        try container.encodeIfPresent(vertexAIProjectID, forKey: .vertexAIProjectID)
        try container.encode(vertexAILocation, forKey: .vertexAILocation)
        try container.encode(vertexAIModelID, forKey: .vertexAIModelID)
        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)
        try container.encode(vertexAIIncludeSummary, forKey: .vertexAIIncludeSummary)
        try container.encodeIfPresent(customGCloudPath, forKey: .customGCloudPath)
''',
        '''        try container.encode(googleAIStudioModelID, forKey: .googleAIStudioModelID)
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
'''
    )

    replace_once(
        models,
        '''        // Legacy runtime-selection keys are intentionally ignored. Runtime
''',
        '''        case cloudTransport
        case transcriptionOptions
        case resolvedLanguageCodes
        case resolvedCustomVocabulary
        case modelMaximumDurationSeconds
        case modelRecommendedSegmentDurationSeconds
        case vertexAISummaryModelID
        case allowDedicatedTranscribeFallbackToGeneralGemini
        // Legacy runtime-selection keys are intentionally ignored. Runtime
'''
    )

    replace_once(
        models,
        '''    public let vertexAIModelID: String
    public let vertexAIGCSBucket: String?
    public let vertexAIIncludeSummary: Bool

    public init(
''',
        '''    public let vertexAIModelID: String
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
'''
    )

    replace_once(
        models,
        '''        vertexAIModelID: String = "gemini-3.7-flash",
        vertexAIGCSBucket: String? = nil,
        vertexAIIncludeSummary: Bool = false
    ) {
''',
        '''        vertexAIModelID: String = "gemini-3.7-flash",
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
'''
    )

    replace_once(
        models,
        '''        self.vertexAIModelID = vertexAIModelID
        self.vertexAIGCSBucket = vertexAIGCSBucket
        self.vertexAIIncludeSummary = vertexAIIncludeSummary
    }

    public init(from decoder: Decoder) throws {
''',
        '''        self.vertexAIModelID = vertexAIModelID
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
'''
    )

    replace_once(
        models,
        '''        vertexAIModelID = try container.decodeIfPresent(String.self, forKey: .vertexAIModelID) ?? "gemini-3.7-flash"
        vertexAIGCSBucket = try container.decodeIfPresent(String.self, forKey: .vertexAIGCSBucket)
        vertexAIIncludeSummary = try container.decodeIfPresent(Bool.self, forKey: .vertexAIIncludeSummary) ?? false
    }

    public func encode(to encoder: Encoder) throws {
''',
        '''        vertexAIModelID = try container.decodeIfPresent(String.self, forKey: .vertexAIModelID) ?? "gemini-3.7-flash"
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
'''
    )

    replace_once(
        models,
        '''        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)
        try container.encode(vertexAIIncludeSummary, forKey: .vertexAIIncludeSummary)
    }

    /// Returns a copy suitable for transient execution. The credential remains
''',
        '''        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)
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
'''
    )

    replace_once(
        models,
        '''            vertexAIModelID: vertexAIModelID,
            vertexAIGCSBucket: vertexAIGCSBucket,
            vertexAIIncludeSummary: vertexAIIncludeSummary
        )
''',
        '''            vertexAIModelID: vertexAIModelID,
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
'''
    )

    replace_once(
        models,
        '''        resolved.vertexAIModelID = snapshot.vertexAIModelID
        resolved.vertexAIGCSBucket = snapshot.vertexAIGCSBucket
        resolved.vertexAIIncludeSummary = snapshot.vertexAIIncludeSummary
        return resolved
''',
        '''        resolved.vertexAIModelID = snapshot.vertexAIModelID
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
'''
    )

    replace_once(
        models,
        '''public struct PipelineResult: Equatable, Sendable {
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
''',
        '''public struct PipelineResult: Equatable, Sendable {
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
'''
    )

    replace_once(
        segmentation,
        '''    public let audioPath: String
    public let outputPath: String
    public var status: AudioSegmentStatus
''',
        '''    public let audioPath: String
    public let outputPath: String
    public let metadataPath: String?
    public var status: AudioSegmentStatus
'''
    )
    replace_once(
        segmentation,
        '''        audioPath: String,
        outputPath: String,
        status: AudioSegmentStatus = .planned,
''',
        '''        audioPath: String,
        outputPath: String,
        metadataPath: String? = nil,
        status: AudioSegmentStatus = .planned,
'''
    )
    replace_once(
        segmentation,
        '''        self.audioPath = audioPath
        self.outputPath = outputPath
        self.status = status
''',
        '''        self.audioPath = audioPath
        self.outputPath = outputPath
        self.metadataPath = metadataPath
        self.status = status
'''
    )

    print("phase 1 applied")


if __name__ == "__main__":
    main()
