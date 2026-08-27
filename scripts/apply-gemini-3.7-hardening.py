#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def replace_once(content: str, old: str, new: str, label: str) -> str:
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return content.replace(old, new, 1)


cloud_models = r'''import Foundation

public enum GeminiThinkingLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low:
            return "低（速度優先）"
        case .medium:
            return "中（模型預設）"
        case .high:
            return "高（品質／延遲較高）"
        }
    }
}

public enum CloudFallbackPolicy: String, Codable, CaseIterable, Sendable {
    case disabled
    case flashOnly

    public var displayName: String {
        switch self {
        case .disabled:
            return "不自動切換模型（推薦）"
        case .flashOnly:
            return "3.7 忙碌時允許改用 3.6 Flash"
        }
    }
}

public struct CloudUsageMetadata: Codable, Equatable, Sendable {
    public let promptTokenCount: Int?
    public let cachedContentTokenCount: Int?
    public let candidatesTokenCount: Int?
    public let thoughtsTokenCount: Int?
    public let totalTokenCount: Int?
    public let serviceTier: String?

    public init(
        promptTokenCount: Int? = nil,
        cachedContentTokenCount: Int? = nil,
        candidatesTokenCount: Int? = nil,
        thoughtsTokenCount: Int? = nil,
        totalTokenCount: Int? = nil,
        serviceTier: String? = nil
    ) {
        self.promptTokenCount = promptTokenCount
        self.cachedContentTokenCount = cachedContentTokenCount
        self.candidatesTokenCount = candidatesTokenCount
        self.thoughtsTokenCount = thoughtsTokenCount
        self.totalTokenCount = totalTokenCount
        self.serviceTier = serviceTier
    }

    public func merged(with other: CloudUsageMetadata) -> CloudUsageMetadata {
        CloudUsageMetadata(
            promptTokenCount: Self.sum(promptTokenCount, other.promptTokenCount),
            cachedContentTokenCount: Self.sum(
                cachedContentTokenCount,
                other.cachedContentTokenCount
            ),
            candidatesTokenCount: Self.sum(
                candidatesTokenCount,
                other.candidatesTokenCount
            ),
            thoughtsTokenCount: Self.sum(
                thoughtsTokenCount,
                other.thoughtsTokenCount
            ),
            totalTokenCount: Self.sum(totalTokenCount, other.totalTokenCount),
            serviceTier: serviceTier == other.serviceTier
                ? serviceTier
                : serviceTier ?? other.serviceTier
        )
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else {
            return nil
        }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}

public struct CloudTranscriptionMetadata: Codable, Equatable, Sendable {
    public let requestedModelID: String
    public let effectiveModelID: String
    public let modelVersion: String?
    public let responseID: String?
    public let retryCount: Int
    public let fallbackReason: String?
    public let thinkingLevel: GeminiThinkingLevel
    public let latencySeconds: Double?
    public let usage: CloudUsageMetadata?

    public init(
        requestedModelID: String,
        effectiveModelID: String,
        modelVersion: String? = nil,
        responseID: String? = nil,
        retryCount: Int = 0,
        fallbackReason: String? = nil,
        thinkingLevel: GeminiThinkingLevel = .medium,
        latencySeconds: Double? = nil,
        usage: CloudUsageMetadata? = nil
    ) {
        self.requestedModelID = requestedModelID
        self.effectiveModelID = effectiveModelID
        self.modelVersion = modelVersion
        self.responseID = responseID
        self.retryCount = max(retryCount, 0)
        self.fallbackReason = fallbackReason
        self.thinkingLevel = thinkingLevel
        self.latencySeconds = latencySeconds
        self.usage = usage
    }

    public var usedFallback: Bool {
        requestedModelID != effectiveModelID || fallbackReason != nil
    }
}

public struct CloudTranscriptionResult: Equatable, Sendable {
    public let text: String
    public let metadata: CloudTranscriptionMetadata

    public init(text: String, metadata: CloudTranscriptionMetadata) {
        self.text = text
        self.metadata = metadata
    }
}

public enum CloudTranscriptionMetadataAggregator {
    public static func uniqueEffectiveModelIDs(
        _ metadata: [CloudTranscriptionMetadata]
    ) -> [String] {
        var seen = Set<String>()
        return metadata.compactMap { item in
            seen.insert(item.effectiveModelID).inserted
                ? item.effectiveModelID
                : nil
        }
    }

    public static func totalUsage(
        _ metadata: [CloudTranscriptionMetadata]
    ) -> CloudUsageMetadata? {
        metadata.compactMap(\.usage).reduce(nil) { partial, usage in
            partial?.merged(with: usage) ?? usage
        }
    }

    public static func totalRetryCount(
        _ metadata: [CloudTranscriptionMetadata]
    ) -> Int {
        metadata.reduce(0) { $0 + $1.retryCount }
    }
}

public extension JobSnapshot {
    var requestedModelID: String {
        switch backendType {
        case .googleAIStudio:
            return googleAIStudioModelID
        case .vertexAI:
            return vertexAIModelID
        case .localQwen:
            return modelID
        }
    }
}

public extension TranscriptionJob {
    var resolvedCloudSegmentMetadata: [CloudTranscriptionMetadata] {
        cloudSegmentMetadata ?? []
    }

    var cloudModelSummary: String? {
        guard snapshot.backendType != .localQwen else {
            return nil
        }
        let metadata = resolvedCloudSegmentMetadata
        guard !metadata.isEmpty else {
            return snapshot.requestedModelID
        }
        let effective = CloudTranscriptionMetadataAggregator
            .uniqueEffectiveModelIDs(metadata)
        if effective == [snapshot.requestedModelID] {
            return snapshot.requestedModelID
        }
        return "要求：\(snapshot.requestedModelID)；實際：\(effective.joined(separator: ", "))"
    }
}

public extension RecentJobSummary {
    var cloudModelSummary: String? {
        guard backendType != .localQwen else {
            return nil
        }
        guard let effectiveModelIDs, !effectiveModelIDs.isEmpty else {
            return modelID
        }
        if effectiveModelIDs == [modelID] {
            return modelID
        }
        return "要求：\(modelID)；實際：\(effectiveModelIDs.joined(separator: ", "))"
    }
}
'''
write("Sources/RecordToTextCore/CloudTranscriptionModels.swift", cloud_models)

models = read("Sources/RecordToTextCore/Models.swift")
models = replace_once(
    models,
    "        case vertexAIIncludeSummary\n        case customGCloudPath\n",
    "        case vertexAIIncludeSummary\n        case geminiThinkingLevel\n        case cloudFallbackPolicy\n        case silenceAwareCloudSegmentation\n        case customGCloudPath\n",
    "AppSettings CodingKeys",
)
models = replace_once(
    models,
    "    public var vertexAIGCSBucket: String?\n    public var vertexAIIncludeSummary: Bool\n    public var customGCloudPath: String?\n",
    "    public var vertexAIGCSBucket: String?\n    public var vertexAIIncludeSummary: Bool\n    public var geminiThinkingLevel: GeminiThinkingLevel\n    public var cloudFallbackPolicy: CloudFallbackPolicy\n    public var silenceAwareCloudSegmentation: Bool\n    public var customGCloudPath: String?\n",
    "AppSettings properties",
)
models = replace_once(
    models,
    "        vertexAIGCSBucket: String? = nil,\n        vertexAIIncludeSummary: Bool = false,\n        customGCloudPath: String? = nil\n",
    "        vertexAIGCSBucket: String? = nil,\n        vertexAIIncludeSummary: Bool = false,\n        geminiThinkingLevel: GeminiThinkingLevel = .medium,\n        cloudFallbackPolicy: CloudFallbackPolicy = .disabled,\n        silenceAwareCloudSegmentation: Bool = true,\n        customGCloudPath: String? = nil\n",
    "AppSettings init parameters",
)
models = replace_once(
    models,
    "        self.vertexAIGCSBucket = vertexAIGCSBucket\n        self.vertexAIIncludeSummary = vertexAIIncludeSummary\n        self.customGCloudPath = customGCloudPath\n",
    "        self.vertexAIGCSBucket = vertexAIGCSBucket\n        self.vertexAIIncludeSummary = vertexAIIncludeSummary\n        self.geminiThinkingLevel = geminiThinkingLevel\n        self.cloudFallbackPolicy = cloudFallbackPolicy\n        self.silenceAwareCloudSegmentation = silenceAwareCloudSegmentation\n        self.customGCloudPath = customGCloudPath\n",
    "AppSettings assignments",
)
models = replace_once(
    models,
    "        vertexAIGCSBucket = try container.decodeIfPresent(String.self, forKey: .vertexAIGCSBucket)\n        vertexAIIncludeSummary = try container.decodeIfPresent(Bool.self, forKey: .vertexAIIncludeSummary) ?? false\n        customGCloudPath = try container.decodeIfPresent(String.self, forKey: .customGCloudPath)\n",
    "        vertexAIGCSBucket = try container.decodeIfPresent(String.self, forKey: .vertexAIGCSBucket)\n        vertexAIIncludeSummary = try container.decodeIfPresent(Bool.self, forKey: .vertexAIIncludeSummary) ?? false\n        geminiThinkingLevel = try container.decodeIfPresent(\n            GeminiThinkingLevel.self,\n            forKey: .geminiThinkingLevel\n        ) ?? .medium\n        cloudFallbackPolicy = try container.decodeIfPresent(\n            CloudFallbackPolicy.self,\n            forKey: .cloudFallbackPolicy\n        ) ?? .disabled\n        silenceAwareCloudSegmentation = try container.decodeIfPresent(\n            Bool.self,\n            forKey: .silenceAwareCloudSegmentation\n        ) ?? true\n        customGCloudPath = try container.decodeIfPresent(String.self, forKey: .customGCloudPath)\n",
    "AppSettings decode",
)
models = replace_once(
    models,
    "        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)\n        try container.encode(vertexAIIncludeSummary, forKey: .vertexAIIncludeSummary)\n        try container.encodeIfPresent(customGCloudPath, forKey: .customGCloudPath)\n",
    "        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)\n        try container.encode(vertexAIIncludeSummary, forKey: .vertexAIIncludeSummary)\n        try container.encode(geminiThinkingLevel, forKey: .geminiThinkingLevel)\n        try container.encode(cloudFallbackPolicy, forKey: .cloudFallbackPolicy)\n        try container.encode(\n            silenceAwareCloudSegmentation,\n            forKey: .silenceAwareCloudSegmentation\n        )\n        try container.encodeIfPresent(customGCloudPath, forKey: .customGCloudPath)\n",
    "AppSettings encode",
)

models = replace_once(
    models,
    "        case vertexAIGCSBucket\n        case vertexAIIncludeSummary\n        // Legacy runtime-selection keys are intentionally ignored.",
    "        case vertexAIGCSBucket\n        case vertexAIIncludeSummary\n        case geminiThinkingLevel\n        case cloudFallbackPolicy\n        case silenceAwareCloudSegmentation\n        // Legacy runtime-selection keys are intentionally ignored.",
    "JobSnapshot CodingKeys",
)
models = replace_once(
    models,
    "    public let vertexAIGCSBucket: String?\n    public let vertexAIIncludeSummary: Bool\n\n    public init(\n",
    "    public let vertexAIGCSBucket: String?\n    public let vertexAIIncludeSummary: Bool\n    public let geminiThinkingLevel: GeminiThinkingLevel\n    public let cloudFallbackPolicy: CloudFallbackPolicy\n    public let silenceAwareCloudSegmentation: Bool\n\n    public init(\n",
    "JobSnapshot properties",
)
models = replace_once(
    models,
    "        vertexAIGCSBucket: String? = nil,\n        vertexAIIncludeSummary: Bool = false\n    ) {\n",
    "        vertexAIGCSBucket: String? = nil,\n        vertexAIIncludeSummary: Bool = false,\n        geminiThinkingLevel: GeminiThinkingLevel = .medium,\n        cloudFallbackPolicy: CloudFallbackPolicy = .disabled,\n        silenceAwareCloudSegmentation: Bool = true\n    ) {\n",
    "JobSnapshot init parameters",
)
models = replace_once(
    models,
    "        self.vertexAIGCSBucket = vertexAIGCSBucket\n        self.vertexAIIncludeSummary = vertexAIIncludeSummary\n    }\n\n    public init(from decoder: Decoder) throws {\n",
    "        self.vertexAIGCSBucket = vertexAIGCSBucket\n        self.vertexAIIncludeSummary = vertexAIIncludeSummary\n        self.geminiThinkingLevel = geminiThinkingLevel\n        self.cloudFallbackPolicy = cloudFallbackPolicy\n        self.silenceAwareCloudSegmentation = silenceAwareCloudSegmentation\n    }\n\n    public init(from decoder: Decoder) throws {\n",
    "JobSnapshot assignments",
)
models = replace_once(
    models,
    "        vertexAIGCSBucket = try container.decodeIfPresent(String.self, forKey: .vertexAIGCSBucket)\n        vertexAIIncludeSummary = try container.decodeIfPresent(Bool.self, forKey: .vertexAIIncludeSummary) ?? false\n    }\n\n    public func encode(to encoder: Encoder) throws {\n",
    "        vertexAIGCSBucket = try container.decodeIfPresent(String.self, forKey: .vertexAIGCSBucket)\n        vertexAIIncludeSummary = try container.decodeIfPresent(Bool.self, forKey: .vertexAIIncludeSummary) ?? false\n        geminiThinkingLevel = try container.decodeIfPresent(\n            GeminiThinkingLevel.self,\n            forKey: .geminiThinkingLevel\n        ) ?? .medium\n        cloudFallbackPolicy = try container.decodeIfPresent(\n            CloudFallbackPolicy.self,\n            forKey: .cloudFallbackPolicy\n        ) ?? .disabled\n        silenceAwareCloudSegmentation = try container.decodeIfPresent(\n            Bool.self,\n            forKey: .silenceAwareCloudSegmentation\n        ) ?? true\n    }\n\n    public func encode(to encoder: Encoder) throws {\n",
    "JobSnapshot decode",
)
models = replace_once(
    models,
    "        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)\n        try container.encode(vertexAIIncludeSummary, forKey: .vertexAIIncludeSummary)\n    }\n\n    /// Returns a copy suitable for transient execution.",
    "        try container.encodeIfPresent(vertexAIGCSBucket, forKey: .vertexAIGCSBucket)\n        try container.encode(vertexAIIncludeSummary, forKey: .vertexAIIncludeSummary)\n        try container.encode(geminiThinkingLevel, forKey: .geminiThinkingLevel)\n        try container.encode(cloudFallbackPolicy, forKey: .cloudFallbackPolicy)\n        try container.encode(\n            silenceAwareCloudSegmentation,\n            forKey: .silenceAwareCloudSegmentation\n        )\n    }\n\n    /// Returns a copy suitable for transient execution.",
    "JobSnapshot encode",
)
models = replace_once(
    models,
    "            vertexAIGCSBucket: vertexAIGCSBucket,\n            vertexAIIncludeSummary: vertexAIIncludeSummary\n        )\n",
    "            vertexAIGCSBucket: vertexAIGCSBucket,\n            vertexAIIncludeSummary: vertexAIIncludeSummary,\n            geminiThinkingLevel: geminiThinkingLevel,\n            cloudFallbackPolicy: cloudFallbackPolicy,\n            silenceAwareCloudSegmentation: silenceAwareCloudSegmentation\n        )\n",
    "JobSnapshot credential copy",
)
models = replace_once(
    models,
    "        resolved.vertexAIGCSBucket = snapshot.vertexAIGCSBucket\n        resolved.vertexAIIncludeSummary = snapshot.vertexAIIncludeSummary\n        return resolved\n",
    "        resolved.vertexAIGCSBucket = snapshot.vertexAIGCSBucket\n        resolved.vertexAIIncludeSummary = snapshot.vertexAIIncludeSummary\n        resolved.geminiThinkingLevel = snapshot.geminiThinkingLevel\n        resolved.cloudFallbackPolicy = snapshot.cloudFallbackPolicy\n        resolved.silenceAwareCloudSegmentation =\n            snapshot.silenceAwareCloudSegmentation\n        return resolved\n",
    "runtime configuration",
)

models = replace_once(
    models,
    "    public var failure: JobFailure?\n    public var logLines: [String]\n\n    public init(\n",
    "    public var failure: JobFailure?\n    public var logLines: [String]\n    public var cloudSegmentMetadata: [CloudTranscriptionMetadata]?\n    public var resumeFromRecoveryDirectory: String?\n\n    public init(\n",
    "TranscriptionJob properties",
)
models = replace_once(
    models,
    "        sourceSlice: TranscriptionSourceSlice? = nil,\n        stage: TranscriptionStage = .queued,\n        createdAt: Date = Date()\n    ) {\n",
    "        sourceSlice: TranscriptionSourceSlice? = nil,\n        stage: TranscriptionStage = .queued,\n        createdAt: Date = Date(),\n        cloudSegmentMetadata: [CloudTranscriptionMetadata]? = nil,\n        resumeFromRecoveryDirectory: String? = nil\n    ) {\n",
    "TranscriptionJob init parameters",
)
models = replace_once(
    models,
    "        self.failure = nil\n        self.logLines = []\n    }\n",
    "        self.failure = nil\n        self.logLines = []\n        self.cloudSegmentMetadata = cloudSegmentMetadata\n        self.resumeFromRecoveryDirectory = resumeFromRecoveryDirectory\n    }\n",
    "TranscriptionJob assignments",
)

models = replace_once(
    models,
    "    public let modelID: String\n    public let glossaryName: String?\n\n    public init(\n",
    "    public let modelID: String\n    public let glossaryName: String?\n    public let backendType: ASRBackendType?\n    public let effectiveModelIDs: [String]?\n    public let cloudUsage: CloudUsageMetadata?\n    public let cloudRetryCount: Int?\n    public let cloudFallbackUsed: Bool?\n\n    public init(\n",
    "RecentJobSummary properties",
)
models = replace_once(
    models,
    "        completedAt: Date?,\n        modelID: String,\n        glossaryName: String?\n    ) {\n",
    "        completedAt: Date?,\n        modelID: String,\n        glossaryName: String?,\n        backendType: ASRBackendType? = nil,\n        effectiveModelIDs: [String]? = nil,\n        cloudUsage: CloudUsageMetadata? = nil,\n        cloudRetryCount: Int? = nil,\n        cloudFallbackUsed: Bool? = nil\n    ) {\n",
    "RecentJobSummary init parameters",
)
models = replace_once(
    models,
    "        self.modelID = modelID\n        self.glossaryName = glossaryName\n    }\n\n    public init(job: TranscriptionJob) {\n        self.init(\n",
    "        self.modelID = modelID\n        self.glossaryName = glossaryName\n        self.backendType = backendType\n        self.effectiveModelIDs = effectiveModelIDs\n        self.cloudUsage = cloudUsage\n        self.cloudRetryCount = cloudRetryCount\n        self.cloudFallbackUsed = cloudFallbackUsed\n    }\n\n    public init(job: TranscriptionJob) {\n        let cloudMetadata = job.resolvedCloudSegmentMetadata\n        self.init(\n",
    "RecentJobSummary assignments",
)
models = replace_once(
    models,
    "            modelID: job.snapshot.modelID,\n            glossaryName: job.snapshot.glossaryName\n        )\n",
    "            modelID: job.snapshot.requestedModelID,\n            glossaryName: job.snapshot.glossaryName,\n            backendType: job.snapshot.backendType,\n            effectiveModelIDs: cloudMetadata.isEmpty\n                ? nil\n                : CloudTranscriptionMetadataAggregator\n                    .uniqueEffectiveModelIDs(cloudMetadata),\n            cloudUsage: CloudTranscriptionMetadataAggregator\n                .totalUsage(cloudMetadata),\n            cloudRetryCount: cloudMetadata.isEmpty\n                ? nil\n                : CloudTranscriptionMetadataAggregator\n                    .totalRetryCount(cloudMetadata),\n            cloudFallbackUsed: cloudMetadata.isEmpty\n                ? nil\n                : cloudMetadata.contains(where: \.usedFallback)\n        )\n",
    "RecentJobSummary from job",
)

models = replace_once(
    models,
    "    public let containsSkippedAudio: Bool\n\n    public init(\n        outputURL: URL,\n        rawOutputURL: URL?,\n        duration: TimeInterval,\n        containsSkippedAudio: Bool = false\n    ) {\n",
    "    public let containsSkippedAudio: Bool\n    public let cloudSegmentMetadata: [CloudTranscriptionMetadata]\n\n    public init(\n        outputURL: URL,\n        rawOutputURL: URL?,\n        duration: TimeInterval,\n        containsSkippedAudio: Bool = false,\n        cloudSegmentMetadata: [CloudTranscriptionMetadata] = []\n    ) {\n",
    "PipelineResult properties",
)
models = replace_once(
    models,
    "        self.duration = duration\n        self.containsSkippedAudio = containsSkippedAudio\n    }\n",
    "        self.duration = duration\n        self.containsSkippedAudio = containsSkippedAudio\n        self.cloudSegmentMetadata = cloudSegmentMetadata\n    }\n",
    "PipelineResult assignments",
)
write("Sources/RecordToTextCore/Models.swift", models)

audio = read("Sources/RecordToTextCore/AudioSegmentation.swift")
audio = replace_once(
    audio,
    "    public var completedEventCount: Int\n    public var failureMessage: String?\n\n    public init(\n",
    "    public var completedEventCount: Int\n    public var failureMessage: String?\n    public var cloudMetadata: CloudTranscriptionMetadata?\n    public var reusedFromCheckpoint: Bool?\n\n    public init(\n",
    "AudioSegmentRecord properties",
)
audio = replace_once(
    audio,
    "        status: AudioSegmentStatus = .planned,\n        completedEventCount: Int = 0,\n        failureMessage: String? = nil\n    ) {\n",
    "        status: AudioSegmentStatus = .planned,\n        completedEventCount: Int = 0,\n        failureMessage: String? = nil,\n        cloudMetadata: CloudTranscriptionMetadata? = nil,\n        reusedFromCheckpoint: Bool? = nil\n    ) {\n",
    "AudioSegmentRecord init parameters",
)
audio = replace_once(
    audio,
    "        self.completedEventCount = completedEventCount\n        self.failureMessage = failureMessage\n    }\n",
    "        self.completedEventCount = completedEventCount\n        self.failureMessage = failureMessage\n        self.cloudMetadata = cloudMetadata\n        self.reusedFromCheckpoint = reusedFromCheckpoint\n    }\n",
    "AudioSegmentRecord assignments",
)
write("Sources/RecordToTextCore/AudioSegmentation.swift", audio)

tests = r'''import XCTest
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
'''
write("Tests/RecordToTextCoreTests/CloudTranscriptionModelsTests.swift", tests)

print("Applied Gemini 3.7 hardening phase 1A")
