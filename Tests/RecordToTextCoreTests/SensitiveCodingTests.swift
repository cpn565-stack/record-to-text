import Foundation
import XCTest
@testable import RecordToTextCore

final class SensitiveCodingTests: XCTestCase {
    func testAppSettingsDecodesLegacyAPIKeyButNeverEncodesIt() throws {
        let legacyJSON = Data(
            #"{"defaultOutputDirectory":"/tmp/output","googleAIStudioAPIKey":"legacy-secret","googleAIStudioModelID":"gemini-test"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.googleAIStudioAPIKey, "legacy-secret")

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(object["googleAIStudioAPIKey"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("legacy-secret"))
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: encoded).googleAIStudioAPIKey,
            nil
        )
    }

    func testJobSnapshotDecodesLegacyAPIKeyButLedgerNeverEncodesIt() throws {
        let legacyJSON = Data(
            #"{"modelID":"legacy/model","language":"Chinese","glossaryID":null,"glossaryName":null,"terms":[],"prompt":"prompt","outputLocationMode":"fixedDirectory","outputDirectory":"/tmp/output","keepRawTranscript":false,"backendType":"googleAIStudio","googleAIStudioAPIKey":"ledger-secret","googleAIStudioModelID":"gemini-test"}"#.utf8
        )
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: legacyJSON)
        XCTAssertEqual(snapshot.googleAIStudioAPIKey, "ledger-secret")

        let job = TranscriptionJob(sourcePath: "/tmp/audio.m4a", snapshot: snapshot)
        let encoded = try JSONEncoder().encode(JobLedgerCollection(jobs: [job]))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("ledger-secret"))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
        let encodedSnapshot = try XCTUnwrap(jobs.first?["snapshot"] as? [String: Any])
        XCTAssertNil(encodedSnapshot["googleAIStudioAPIKey"])
    }

    func testCredentialRedactionPreservesOriginalTranscriptionConfiguration() throws {
        let original = JobSnapshot(
            modelID: "local/model",
            modelRevision: "revision",
            language: "Taiwanese Mandarin",
            glossaryID: "glossary-id",
            glossaryName: "詞庫",
            terms: ["專有名詞"],
            prompt: "原始提示",
            outputLocationMode: .sameAsSource,
            outputDirectory: "/tmp/original-output",
            keepRawTranscript: true,
            outputFilenameSuffix: "_原稿",
            rawFilenameSuffix: "_原始",
            backendType: .vertexAI,
            googleAIStudioAPIKey: "transient-secret",
            googleAIStudioModelID: "gemini-ai-studio-original",
            vertexAIProjectID: "original-project",
            vertexAILocation: "asia-east1",
            vertexAIModelID: "gemini-vertex-original",
            vertexAIGCSBucket: "original-bucket",
            vertexAIIncludeSummary: true
        )

        let redacted = original.withGoogleAIStudioAPIKey(nil)
        XCTAssertNil(redacted.googleAIStudioAPIKey)
        XCTAssertEqual(
            redacted.withGoogleAIStudioAPIKey("transient-secret"),
            original
        )

        let encoded = try JSONEncoder().encode(redacted)
        let restored = try JSONDecoder().decode(JobSnapshot.self, from: encoded)
        XCTAssertEqual(restored, redacted)
        XCTAssertEqual(restored.vertexAILocation, "asia-east1")
        XCTAssertEqual(restored.vertexAIGCSBucket, "original-bucket")
        XCTAssertTrue(restored.vertexAIIncludeSummary)

        var currentSettings = AppSettings(defaultOutputDirectory: "/tmp/current")
        currentSettings.backendType = .localQwen
        currentSettings.developerMode = false
        currentSettings.customPythonPath = "/current/python"
        currentSettings.customGCloudPath = "/current/gcloud"
        let runtimeSettings = currentSettings.applyingRuntimeConfiguration(
            from: restored
        )
        XCTAssertEqual(runtimeSettings.backendType, .vertexAI)
        XCTAssertEqual(runtimeSettings.vertexAIModelID, "gemini-vertex-original")
        XCTAssertEqual(runtimeSettings.vertexAILocation, "asia-east1")
        XCTAssertEqual(runtimeSettings.vertexAIGCSBucket, "original-bucket")
        XCTAssertTrue(runtimeSettings.vertexAIIncludeSummary)
        XCTAssertFalse(runtimeSettings.developerMode)
        XCTAssertEqual(runtimeSettings.customPythonPath, "/current/python")
        XCTAssertEqual(runtimeSettings.customGCloudPath, "/current/gcloud")
    }

    func testRuntimeAuthorizationRemainsLiveForAlreadyQueuedJobs() {
        let snapshot = JobSnapshot(
            modelID: "local/model",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "prompt",
            outputLocationMode: .fixedDirectory,
            outputDirectory: "/tmp/output",
            keepRawTranscript: false,
            backendType: .localQwen
        )

        var enabled = AppSettings(defaultOutputDirectory: "/tmp/current")
        enabled.developerMode = true
        enabled.customPythonPath = "/approved/python"
        let enabledRuntime = enabled.applyingRuntimeConfiguration(from: snapshot)
        XCTAssertTrue(enabledRuntime.developerMode)
        XCTAssertEqual(enabledRuntime.customPythonPath, "/approved/python")

        var revoked = enabled
        revoked.developerMode = false
        revoked.customPythonPath = nil
        let revokedRuntime = revoked.applyingRuntimeConfiguration(from: snapshot)
        XCTAssertFalse(revokedRuntime.developerMode)
        XCTAssertNil(revokedRuntime.customPythonPath)
    }
}
