import Foundation
import XCTest
@testable import RecordToTextCore

private final class StudioInteractionProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GoogleAIStudioTranscribeTests: XCTestCase {
    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    func testFileRequestPreservesVocabularyWithoutIncompatibleOptions() throws {
        let body = try GoogleAIStudioBackend.transcribeInteractionBody(audioPart: ["fileData": [
            "fileUri": "https://example.invalid/files/abc", "mimeType": "audio/mp3"
        ]], terms: ["專有名詞"])
        XCTAssertEqual(body["model"] as? String, "models/gemini-3.5-transcribe")
        XCTAssertEqual(body["store"] as? Bool, false)
        let input = try XCTUnwrap((body["input"] as? [[String: Any]])?.first)
        XCTAssertEqual(input["type"] as? String, "audio")
        XCTAssertEqual(input["uri"] as? String, "https://example.invalid/files/abc")
        XCTAssertEqual(input["mime_type"] as? String, "audio/mp3")
        XCTAssertEqual(Set(input.keys), ["type", "uri", "mime_type"])
        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        let config = try XCTUnwrap(generation["transcription_config"] as? [String: Any])
        XCTAssertEqual(config["custom_vocabulary"] as? [String], ["專有名詞"])
        // Match the official Developer API vocabulary-only REST example. Its
        // omitted mode defaults to verbatim and does not enable diarization.
        XCTAssertEqual(Set(config.keys), ["custom_vocabulary"])
        XCTAssertNil(body["system_instruction"])
        XCTAssertNil(generation["thinking_config"])
    }

    func testFileRequestRejectsMissingAudioFormatOrURI() throws {
        for file in [["fileUri": "https://example.invalid/files/abc"],
                     ["mimeType": "audio/mp3"],
                     ["fileUri": "", "mimeType": "audio/mp3"],
                     ["fileUri": "https://example.invalid/files/abc", "mimeType": ""]] {
            XCTAssertThrowsError(try GoogleAIStudioBackend.transcribeInteractionBody(
                audioPart: ["fileData": file], terms: [])) { error in
                XCTAssertEqual(error as? GoogleAIStudioError, .invalidAudioReference)
            }
        }
    }

    func testInlineRequestEnablesSpeakerWhenNoVocabulary() throws {
        let body = try GoogleAIStudioBackend.transcribeInteractionBody(audioPart: ["inlineData": [
            "data": "YWJj", "mimeType": "audio/mp3"
        ]], terms: [])
        let input = try XCTUnwrap((body["input"] as? [[String: Any]])?.first)
        XCTAssertEqual(input["type"] as? String, "audio")
        XCTAssertEqual(input["data"] as? String, "YWJj")
        XCTAssertEqual(input["mime_type"] as? String, "audio/mp3")
        let config = try XCTUnwrap((body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any])
        let mode = try XCTUnwrap(config["mode"] as? [String: Any])
        XCTAssertEqual(mode["diarization_mode"] as? String, "speaker")
        XCTAssertNil(config["custom_vocabulary"])
    }

    func testSpeakerAnnotationsPreserveOriginalPunctuationAndMultibyteText() throws {
        let response: [String: Any] = ["status": "completed", "steps": [["type": "model_output", "content": [[
            "type": "text", "text": "你好，世界！",
            "annotations": [
                ["type": "word_info", "text": "你好", "speaker": "spk_1", "start_index": 0, "end_index": 6],
                ["type": "word_info", "text": "世界", "speaker": "spk_2", "start_index": 9, "end_index": 15]
            ]
        ]]]]]
        XCTAssertEqual(try GoogleAIStudioBackend.transcribeInteractionText(from: data(response)),
                       "[片段 00:00:00・講者 1]：你好，\n\n[片段 00:00:00・講者 2]：世界！")
    }

    func testSpeakerAnnotationsWithoutOffsetsAreSafelyAligned() throws {
        func response(_ annotations: [[String: Any]]) throws -> Data {
            try data(["status": "completed", "steps": [["type": "model_output", "content": [[
                "type": "text", "text": "你好，世界！", "annotations": annotations
            ]]]]])
        }
        let matched = [
            ["type": "word_info", "text": "你好", "speaker": "spk_1"],
            ["type": "word_info", "text": "世界", "speaker": "spk_2"]
        ]
        XCTAssertEqual(try GoogleAIStudioBackend.transcribeInteractionText(from: response(matched), timeOffsetSeconds: 840),
                       "[片段 00:14:00・講者 1]：你好，\n\n[片段 00:14:00・講者 2]：世界！")
        let mismatched = [["type": "word_info", "text": "世界", "speaker": "spk_2"]]
        XCTAssertEqual(try GoogleAIStudioBackend.transcribeInteractionText(from: response(mismatched)), "你好，世界！")
    }

    func testIncompleteAndEmptyOutputAreNeverAcceptedAsFinished() throws {
        let incomplete: [String: Any] = ["status": "incomplete", "steps": [["type": "model_output", "content": [["type": "text", "text": "partial"]]]]]
        XCTAssertThrowsError(try GoogleAIStudioBackend.transcribeInteractionText(from: data(incomplete))) { error in
            guard case GoogleAIStudioError.incompleteResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try GoogleAIStudioBackend.transcribeInteractionText(from: data(["status": "completed", "steps": []]))) { error in
            XCTAssertEqual(error as? GoogleAIStudioError, .emptyResponse)
        }
        for status in ["failed", "cancelled", "requires_action", "in_progress"] {
            XCTAssertThrowsError(try GoogleAIStudioBackend.transcribeInteractionText(from: data(["status": status])))
        }
    }

    func testVocabularyLimitDoesNotSilentlyDiscardTerms() throws {
        let terms = (0..<1001).map { "term\($0)" }
        XCTAssertThrowsError(try GoogleAIStudioBackend.transcribeInteractionBody(audioPart: ["inlineData": [
            "data": "YQ==", "mimeType": "audio/mp3"
        ]], terms: terms)) { error in
            XCTAssertEqual(error as? GoogleAIStudioError, .tooManyVocabularyTerms(1001))
        }
    }

    func testMultipleOutputPartsAreAllPreservedInOrder() throws {
        let response: [String: Any] = ["status": "completed", "steps": [
            ["type": "model_output", "content": [["type": "text", "text": "甲"], ["type": "text", "text": "乙"]]],
            ["type": "model_output", "content": [["type": "text", "text": "丙"]]]
        ]]
        XCTAssertEqual(try GoogleAIStudioBackend.transcribeInteractionText(from: data(response)), "甲乙丙")
    }

    func testBackendSendsInteractionWithoutPromptAndReturnsUsage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StudioInteractionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StudioInteractionProtocol.handler = nil }
        var calls = 0
        StudioInteractionProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/v1beta/interactions")
            let body = try contextRequestBody(request)
            XCTAssertEqual(body["store"] as? Bool, false)
            let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
            let transcription = try XCTUnwrap(generation["transcription_config"] as? [String: Any])
            XCTAssertEqual(Set(transcription.keys), ["custom_vocabulary"])
            XCTAssertEqual(transcription["custom_vocabulary"] as? [String], ["術語"])
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            XCTAssertFalse(encoded.contains("PRIVATE_CONTEXT"))
            XCTAssertFalse(encoded.contains("PRIVATE_PROMPT"))
            return (200, try self.data(["status": "completed", "id": "test-response", "model": "gemini-3.5-transcribe",
                "usage": ["total_input_tokens": 22, "total_output_tokens": 8, "total_tokens": 30],
                "steps": [["type": "model_output", "content": [["type": "text", "text": "測試結果。"]]]]]))
        }
        let backend = GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "test-key",
            modelID: "gemini-3.5-transcribe", useFilesAPI: false))
        let result = try await backend.transcribeDetailed(audioData: Data("fixture".utf8), terms: ["術語"],
            customPrompt: "PRIVATE_PROMPT", recordingContext: "PRIVATE_CONTEXT")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.text, "測試結果。")
        XCTAssertEqual(result.metadata.usage?.promptTokenCount, 22)
        XCTAssertEqual(result.metadata.usage?.candidatesTokenCount, 8)
        XCTAssertEqual(result.metadata.responseID, "test-response")
    }

    func testEmptyCompletedInteractionDoesNotRetryAsEmptyStop() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StudioInteractionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StudioInteractionProtocol.handler = nil }
        var calls = 0
        StudioInteractionProtocol.handler = { _ in
            calls += 1
            return (200, try self.data(["status": "completed", "steps": []]))
        }
        let backend = GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "test-key",
            modelID: "gemini-3.5-transcribe", useFilesAPI: false))
        do {
            _ = try await backend.transcribeDetailed(audioData: Data("fixture".utf8))
            XCTFail("An empty interaction must not be accepted")
        } catch {
            XCTAssertEqual(error as? GoogleAIStudioError, .emptyResponse)
        }
        XCTAssertEqual(calls, 1)
    }
}
