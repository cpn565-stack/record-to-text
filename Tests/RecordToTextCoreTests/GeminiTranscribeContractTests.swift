import Foundation
import XCTest
@testable import RecordToTextCore

final class GeminiTranscribeCatalogTests: XCTestCase {
    func testProviderSpecificCatalogsUseDifferentModelsAndTransports() throws {
        let aiStudio = try XCTUnwrap(
            GoogleAIStudioModelCatalog.descriptor(
                id: "gemini-3.5-transcribe"
            )
        )
        XCTAssertEqual(aiStudio.provider, .googleAIStudio)
        XCTAssertEqual(aiStudio.transport, .geminiInteractionsTranscribe)
        XCTAssertEqual(aiStudio.apiVersion, "v1beta")
        XCTAssertEqual(aiStudio.recommendedSegmentDurationSeconds, 1_200)
        XCTAssertTrue(aiStudio.supportsSmartMode)

        let gcloud = try XCTUnwrap(
            GCloudModelCatalog.descriptor(
                id: "gemini-3.5-transcribe-preview"
            )
        )
        XCTAssertEqual(gcloud.provider, .vertexAI)
        XCTAssertEqual(gcloud.transport, .agentPlatformTranscribe)
        XCTAssertEqual(gcloud.apiVersion, "v1beta1")
        XCTAssertEqual(gcloud.requiredLocation, "global")
        XCTAssertEqual(gcloud.maximumAudioDurationSeconds, 900)
        XCTAssertEqual(gcloud.recommendedSegmentDurationSeconds, 840)
        XCTAssertFalse(gcloud.supportsSmartMode)
    }

    func testUnknownCustomModelRemainsGeneralGenerateContent() {
        let aiStudio = CloudModelCatalog.resolvedDescriptor(
            provider: .googleAIStudio,
            modelID: "custom-audio-model"
        )
        XCTAssertEqual(aiStudio.transport, .geminiGenerateContent)
        XCTAssertTrue(aiStudio.supportsSystemInstruction)

        let gcloud = CloudModelCatalog.resolvedDescriptor(
            provider: .vertexAI,
            modelID: "custom-vertex-model"
        )
        XCTAssertEqual(gcloud.transport, .geminiGenerateContent)
        XCTAssertEqual(gcloud.apiVersion, "v1")
    }

    func testVocabularyNormalizationIsStableAndBounded() throws {
        XCTAssertEqual(
            try CloudTranscriptionPolicy.normalizedVocabulary([
                " SPECIFIQUE ",
                "specifique",
                "OGSTM",
                "復盛",
                "復盛 "
            ]),
            ["SPECIFIQUE", "OGSTM", "復盛"]
        )

        let excessive = (0...CloudTranscriptionPolicy.maximumCustomVocabularyCount)
            .map { "term-\($0)" }
        XCTAssertThrowsError(
            try CloudTranscriptionPolicy.normalizedVocabulary(excessive)
        ) { error in
            XCTAssertEqual(
                error as? CloudTranscriptionConfigurationError,
                .vocabularyTooLarge(
                    count: excessive.count,
                    maximum: CloudTranscriptionPolicy.maximumCustomVocabularyCount
                )
            )
        }
    }

    func testSmartModeRejectsStructuredMetadata() throws {
        let descriptor = try XCTUnwrap(
            GoogleAIStudioModelCatalog.descriptor(
                id: "gemini-3.5-transcribe"
            )
        )
        let options = DedicatedTranscriptionOptions(
            mode: .smart,
            diarizationEnabled: true
        )
        XCTAssertThrowsError(
            try CloudTranscriptionPolicy.validate(
                descriptor: descriptor,
                options: options,
                vocabulary: []
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudTranscriptionConfigurationError,
                .smartModeMetadataConflict
            )
        }
        XCTAssertFalse(options.normalizedForUI().diarizationEnabled)
    }
}

final class GoogleAIStudioInteractionsContractTests: XCTestCase {
    func testRequestUsesInteractionsTranscriptionContractWithoutPromptFields() throws {
        let backend = GoogleAIStudioTranscribeBackend()
        let body = backend.buildInteractionRequestBody(
            modelID: "gemini-3.5-transcribe",
            fileURI: "https://generativelanguage.googleapis.com/v1beta/files/test",
            mimeType: "audio/mp3",
            options: DedicatedTranscriptionOptions(
                mode: .verbatim,
                languagePreference: .taiwanMandarin,
                diarizationEnabled: true,
                wordTimestampsEnabled: true
            ),
            customVocabulary: ["SPECIFIQUE", "OGSTM"]
        )

        XCTAssertEqual(body["model"] as? String, "gemini-3.5-transcribe")
        XCTAssertNil(body["systemInstruction"])
        XCTAssertNil(body["contents"])
        let generation = try XCTUnwrap(
            body["generation_config"] as? [String: Any]
        )
        let transcription = try XCTUnwrap(
            generation["transcription_config"] as? [String: Any]
        )
        XCTAssertEqual(
            transcription["language_codes"] as? [String],
            ["cmn-Hant-TW"]
        )
        XCTAssertEqual(
            transcription["custom_vocabulary"] as? [String],
            ["SPECIFIQUE", "OGSTM"]
        )
        let mode = try XCTUnwrap(
            transcription["mode"] as? [String: Any]
        )
        XCTAssertEqual(mode["type"] as? String, "verbatim")
        XCTAssertEqual(mode["diarization_mode"] as? String, "speaker")
        XCTAssertEqual(
            mode["timestamp_granularities"] as? [String],
            ["word"]
        )
    }

    func testInteractionResponseParsesTextSpeakerAndWordOffsets() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "id": "interaction-123",
                "status": "completed",
                "steps": [
                    [
                        "type": "model_output",
                        "content": [
                            [
                                "text": "今天討論OGSTM。",
                                "annotations": [
                                    [
                                        "type": "word_info",
                                        "text": "今天",
                                        "speaker": "speaker-1",
                                        "start_offset": "0.4s",
                                        "end_offset": "0.9s"
                                    ],
                                    [
                                        "type": "word_info",
                                        "text": "討論",
                                        "speaker": "speaker-1",
                                        "start_offset": "0.9s",
                                        "end_offset": "1.3s"
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        )
        let result = try GoogleAIStudioTranscribeBackend()
            .parseInteractionResponse(data)
        XCTAssertEqual(result.text, "今天討論OGSTM。")
        XCTAssertEqual(result.transport, .geminiInteractionsTranscribe)
        XCTAssertEqual(result.providerResponseID, "interaction-123")
        XCTAssertEqual(result.words.count, 2)
        XCTAssertEqual(result.words[0].speaker, "speaker-1")
        XCTAssertEqual(result.words[0].startSeconds, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result.speakerTurns.count, 1)
        XCTAssertEqual(result.speakerTurns[0].text, "今天討論")
    }

    func testInteractionFailureStatusFailsClosed() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "status": "failed",
                "error": ["message": "model unavailable"]
            ]
        )
        XCTAssertThrowsError(
            try GoogleAIStudioTranscribeBackend()
                .parseInteractionResponse(data)
        ) { error in
            XCTAssertEqual(
                error as? GoogleAIStudioTranscribeError,
                .interactionNotCompleted(
                    status: "failed",
                    message: "model unavailable"
                )
            )
        }
    }
}

final class AgentPlatformTranscribeContractTests: XCTestCase {
    func testEndpointIsGlobalV1Beta1PreviewModel() throws {
        let descriptor = try XCTUnwrap(
            GCloudModelCatalog.descriptor(
                id: "gemini-3.5-transcribe-preview"
            )
        )
        let endpoint = try AgentPlatformTranscribeBackend().endpoint(
            projectID: "test-project",
            descriptor: descriptor
        )
        XCTAssertEqual(
            endpoint.absoluteString,
            "https://aiplatform.googleapis.com/v1beta1/projects/test-project/locations/global/publishers/google/models/gemini-3.5-transcribe-preview:generateContent"
        )
    }

    func testRequestUsesCamelCaseAudioTranscriptionConfig() throws {
        let body = AgentPlatformTranscribeBackend().buildRequestBody(
            inputPart: [
                "fileData": [
                    "mimeType": "audio/mp3",
                    "fileUri": "gs://bucket/audio.mp3"
                ]
            ],
            options: DedicatedTranscriptionOptions(
                languagePreference: .taiwanMandarin,
                diarizationEnabled: true,
                wordTimestampsEnabled: true
            ),
            customVocabulary: ["SPECIFIQUE"]
        )
        XCTAssertNil(body["systemInstruction"])
        let generation = try XCTUnwrap(
            body["generationConfig"] as? [String: Any]
        )
        let transcription = try XCTUnwrap(
            generation["audioTranscriptionConfig"] as? [String: Any]
        )
        XCTAssertEqual(
            transcription["languageCodes"] as? [String],
            ["cmn-Hant-TW"]
        )
        XCTAssertEqual(
            transcription["customVocabulary"] as? [String],
            ["SPECIFIQUE"]
        )
        XCTAssertEqual(transcription["wordTimestamp"] as? Bool, true)
        XCTAssertEqual(transcription["diarization"] as? Bool, true)
        XCTAssertNil(generation["audio_transcription_config"])
    }

    func testResponsePrefersStructuredAudioTranscription() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "responseId": "response-456",
                "candidates": [
                    [
                        "finishReason": "STOP",
                        "content": [
                            "parts": [
                                [
                                    "text": "fallback text",
                                    "audioTranscription": [
                                        "text": "專用逐字稿",
                                        "languageCode": "cmn-Hant-TW",
                                        "speakerLabel": "speaker-2",
                                        "words": [
                                            [
                                                "word": "專用",
                                                "startOffset": "1.0s",
                                                "endOffset": "1.4s"
                                            ],
                                            [
                                                "word": "逐字稿",
                                                "startOffset": "1.4s",
                                                "endOffset": "2.0s"
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        )
        let result = try AgentPlatformTranscribeBackend().parseResponse(data)
        XCTAssertEqual(result.text, "專用逐字稿")
        XCTAssertEqual(result.transport, .agentPlatformTranscribe)
        XCTAssertEqual(result.detectedLanguageCodes, ["cmn-Hant-TW"])
        XCTAssertEqual(result.words.count, 2)
        XCTAssertEqual(result.words[0].speaker, "speaker-2")
        XCTAssertEqual(result.providerResponseID, "response-456")
    }
}

final class DedicatedCloudSegmentPolicyTests: XCTestCase {
    func testGCloudPreviewUsesFourteenMinuteSegments() {
        let snapshot = JobSnapshot(
            modelID: "local-placeholder",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "",
            outputLocationMode: .sameAsSource,
            outputDirectory: "",
            keepRawTranscript: false,
            backendType: .vertexAI,
            vertexAIModelID: "gemini-3.5-transcribe-preview",
            cloudTransport: .agentPlatformTranscribe,
            modelMaximumDurationSeconds: 900,
            modelRecommendedSegmentDurationSeconds: 840
        )
        XCTAssertEqual(
            TranscriptionEngine.effectiveCloudSegmentDuration(
                for: snapshot,
                productMaximum: 1_200
            ),
            840
        )
    }

    func testGeneralGeminiKeepsTwentyMinuteSegments() {
        let snapshot = JobSnapshot(
            modelID: "local-placeholder",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "",
            outputLocationMode: .sameAsSource,
            outputDirectory: "",
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioModelID: "gemini-3.7-flash",
            cloudTransport: .geminiGenerateContent,
            modelRecommendedSegmentDurationSeconds: 1_200
        )
        XCTAssertEqual(
            TranscriptionEngine.effectiveCloudSegmentDuration(
                for: snapshot,
                productMaximum: 1_200
            ),
            1_200
        )
    }

    func testStructuredOffsetsBecomeAbsoluteAndSpeakerLabelsStaySegmentLocal() {
        let result = CloudTranscriptionResult(
            text: "逐字稿",
            modelID: "gemini-3.5-transcribe",
            transport: .geminiInteractionsTranscribe,
            speakerTurns: [
                SpeakerTurn(
                    speaker: "speaker-1",
                    text: "逐字稿",
                    startSeconds: 1,
                    endSeconds: 2
                )
            ],
            words: [
                TimedWord(
                    text: "逐字稿",
                    speaker: "speaker-1",
                    startSeconds: 1,
                    endSeconds: 2
                )
            ]
        ).applyingSegmentOffset(840, segmentIndex: 2)

        XCTAssertEqual(result.words[0].startSeconds, 841)
        XCTAssertEqual(result.words[0].endSeconds, 842)
        XCTAssertEqual(result.words[0].speaker, "segment-0002:speaker-1")
        XCTAssertEqual(result.speakerTurns[0].speaker, "segment-0002:speaker-1")
    }
}
