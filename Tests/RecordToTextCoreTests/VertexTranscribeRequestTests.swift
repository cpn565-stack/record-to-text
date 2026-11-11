import Foundation
import XCTest
@testable import RecordToTextCore

final class VertexTranscribeRequestTests: XCTestCase {
    func testRequestUsesOnlyAudioAndCompatibleTranscriptionOptions() throws {
        let audio = ["fileData": ["fileUri": "gs://test/audio.mp3", "mimeType": "audio/mp3"]]
        for terms in [[], ["專有名詞", "Google"]] {
            let body = try VertexTranscribeRequest.body(inputPart: audio, terms: terms)
            XCTAssertNil(body["systemInstruction"])
            XCTAssertNil(body["safetySettings"])
            let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 1)
            XCTAssertNotNil(parts.first?["fileData"])
            let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
            XCTAssertNil(config["thinkingConfig"])
            let transcription = try XCTUnwrap(config["audioTranscriptionConfig"] as? [String: Any])
            XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
            if terms.isEmpty {
                XCTAssertEqual(transcription["diarization"] as? Bool, true)
                XCTAssertNil(transcription["customVocabulary"])
            } else {
                XCTAssertEqual(transcription["customVocabulary"] as? [String], terms)
                XCTAssertNil(transcription["diarization"])
            }
        }
        XCTAssertThrowsError(try VertexTranscribeRequest.body(
            inputPart: audio, terms: (0...1_000).map { "詞\($0)" })) {
            XCTAssertEqual($0 as? VertexAIError, .vocabularyTooLarge(count: 1_001))
        }
    }

    func testSpeakerTextIsPreservedAndScopedToSegment() throws {
        let data = try response(parts: [
            ["audioTranscription": ["text": "第一句", "speakerLabel": "spk_1"]],
            ["audioTranscription": ["text": "第二句", "speakerLabel": "spk_2"]]
        ])
        let transcript = try VertexTranscribeRequest.transcript(from: data, segmentStartSeconds: 900)
        XCTAssertTrue(transcript.contains("[片段 15:00・spk_1]\n第一句"))
        XCTAssertTrue(transcript.contains("[片段 15:00・spk_2]\n第二句"))
    }

    func testRepeatedPlainAndWordsOnlyPartsAreBothPreserved() throws {
        let plain = try response(parts: [["text": "全部逐字稿"],
            ["audioTranscription": ["words": [["word": "全部逐字稿"]]]]])
        var warning = false
        let text = try VertexTranscribeRequest.transcript(from: plain, segmentStartSeconds: 0) { level, _ in
            if level == "warning" { warning = true }
        }
        XCTAssertEqual(text, "全部逐字稿全部逐字稿")
        XCTAssertTrue(warning)
        let words = try response(parts: [["audioTranscription": ["words": [
            ["word": "你好"], ["word": "世界"], ["word": "Hello"], ["word": "world"]
        ]]]])
        XCTAssertEqual(try VertexTranscribeRequest.transcript(from: words, segmentStartSeconds: 0), "你好世界Hello world")
    }

    func testMixedPlainAndAudioPartsPreserveOriginalOrder() throws {
        let data = try response(parts: [
            ["text": "第一句"],
            ["audioTranscription": ["text": "第二句", "speakerLabel": "spk_1"]],
            ["text": "第三句"]
        ])
        let result = try VertexTranscribeRequest.transcript(from: data, segmentStartSeconds: 0)
        let first = try XCTUnwrap(result.range(of: "第一句"))
        let second = try XCTUnwrap(result.range(of: "第二句"))
        let third = try XCTUnwrap(result.range(of: "第三句"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertLessThan(second.lowerBound, third.lowerBound)
        let mixedWords = try response(parts: [
            ["text": "第一句"],
            ["audioTranscription": ["words": [["word": "第二句"]]]]
        ])
        XCTAssertEqual(try VertexTranscribeRequest.transcript(from: mixedWords, segmentStartSeconds: 0), "第一句第二句")
    }

    func testPartTextWithAudioMetadataIsNotLostOrDuplicated() throws {
        let data = try response(parts: [
            ["text": "第一句", "audioTranscription": ["speakerLabel": "spk_1"]],
            ["text": "第二句", "audioTranscription": ["speakerLabel": "spk_2", "text": "第二句"]],
            ["audioTranscription": ["speakerLabel": "spk_1", "text": "第三句"]]
        ])
        let result = try VertexTranscribeRequest.transcript(from: data, segmentStartSeconds: 0)
        XCTAssertTrue(result.contains("[片段 00:00・spk_1]\n第一句"))
        XCTAssertTrue(result.contains("[片段 00:00・spk_2]\n第二句"))
        XCTAssertTrue(result.contains("[片段 00:00・spk_1]\n第三句"))
        for text in ["第一句", "第二句", "第三句"] {
            XCTAssertEqual(result.components(separatedBy: text).count, 2)
        }
    }

    func testEmptyTruncatedAndBlockedResponsesNeverBecomeSuccess() throws {
        let empty = try response(parts: [["audioTranscription": ["text": ""]]])
        XCTAssertThrowsError(try VertexTranscribeRequest.transcript(from: empty, segmentStartSeconds: 0)) {
            XCTAssertEqual($0 as? VertexAIError, .emptyCompletedResponse)
        }
        let partial = try response(parts: [["audioTranscription": ["text": "部分"]]], finish: "MAX_TOKENS")
        XCTAssertThrowsError(try VertexTranscribeRequest.transcript(from: partial, segmentStartSeconds: 0)) {
            XCTAssertTrue($0 is CloudOutputTruncatedError)
        }
        let blocked = try response(parts: [["audioTranscription": ["text": "部分"]]], finish: "SAFETY")
        XCTAssertThrowsError(try VertexTranscribeRequest.transcript(from: blocked, segmentStartSeconds: 0)) {
            guard case .prohibitedContent = $0 as? VertexAIError else { return XCTFail("expected safety block") }
        }
        let missingReason = try JSONSerialization.data(withJSONObject: ["candidates": [[
            "content": ["parts": [["audioTranscription": ["text": "內容"]]]]
        ]]])
        XCTAssertThrowsError(try VertexTranscribeRequest.transcript(from: missingReason, segmentStartSeconds: 0)) {
            guard case .incompleteResponse = $0 as? VertexAIError else { return XCTFail("expected missing finish reason") }
        }
    }

    private func response(parts: [[String: Any]], finish: String = "STOP") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["candidates": [[
            "content": ["parts": parts], "finishReason": finish
        ]]])
    }
}
