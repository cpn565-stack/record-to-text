import Foundation
import XCTest
@testable import RecordToTextCore

final class CloudPipelinePresentationTests: XCTestCase {
    func testJobCloudSummaryDistinguishesRequestedAndEffectiveModels() {
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
        let job = TranscriptionJob(
            sourcePath: "/tmp/audio.m4a",
            snapshot: snapshot,
            cloudSegmentMetadata: [
                CloudTranscriptionMetadata(
                    requestedModelID: "gemini-3.7-flash",
                    effectiveModelID: "gemini-3.7-flash"
                ),
                CloudTranscriptionMetadata(
                    requestedModelID: "gemini-3.7-flash",
                    effectiveModelID: "gemini-3.6-flash",
                    fallbackReason: "HTTP 503"
                )
            ]
        )

        XCTAssertEqual(
            job.cloudModelSummary,
            "要求：gemini-3.7-flash；實際：gemini-3.7-flash, gemini-3.6-flash"
        )
    }

    func testCloudSnapshotCapturesQualityControls() throws {
        let snapshot = JobSnapshot(
            modelID: "local-placeholder",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "prompt",
            outputLocationMode: .sameAsSource,
            outputDirectory: "",
            keepRawTranscript: false,
            backendType: .vertexAI,
            vertexAIModelID: "gemini-3.7-flash",
            geminiThinkingLevel: .low,
            cloudFallbackPolicy: .flashOnly,
            silenceAwareCloudSegmentation: false
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(JobSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.geminiThinkingLevel, .low)
        XCTAssertEqual(decoded.cloudFallbackPolicy, .flashOnly)
        XCTAssertFalse(decoded.silenceAwareCloudSegmentation)
    }
}
