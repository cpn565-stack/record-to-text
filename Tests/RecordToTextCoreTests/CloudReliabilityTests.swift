import Foundation
import XCTest
@testable import RecordToTextCore

private final class AIStudioMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var shouldSuspend: ((URLRequest) -> Bool)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if Self.shouldSuspend?(request) == true {
            // Intentionally leave the request open. URLSession will call
            // stopLoading() when the parent transcription task is cancelled.
            return
        }
        guard let handler = Self.handler else {
            XCTFail("AIStudioMockURLProtocol handler is missing")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.withLock { storage += 1 }
    }

    var value: Int {
        lock.withLock { storage }
    }
}

final class GeminiCloudResponseValidationTests: XCTestCase {
    func testAIStudioAcceptsOnlyStopWithNonEmptyText() throws {
        let backend = GoogleAIStudioBackend()
        XCTAssertEqual(
            try backend.parseCandidateText(from: responseData()),
            "忠實逐字稿"
        )

        XCTAssertThrowsError(
            try backend.parseCandidateText(
                from: responseData(finishReason: "MAX_TOKENS")
            )
        ) { error in
            XCTAssertEqual(
                error as? GoogleAIStudioError,
                .incompleteResponse(
                    finishReason: "MAX_TOKENS",
                    message: "output limit"
                )
            )
        }

        XCTAssertThrowsError(
            try backend.parseCandidateText(
                from: responseData(finishReason: "SAFETY")
            )
        ) { error in
            XCTAssertEqual(
                error as? GoogleAIStudioError,
                .prohibitedContent("output limit")
            )
        }
    }

    func testVertexAcceptsOnlyStopWithNonEmptyText() throws {
        let backend = VertexAIGeminiBackend()
        XCTAssertEqual(
            try backend.parseCandidateText(from: responseData()),
            "忠實逐字稿"
        )

        XCTAssertThrowsError(
            try backend.parseCandidateText(
                from: responseData(finishReason: "MAX_TOKENS")
            )
        ) { error in
            XCTAssertEqual(
                error as? VertexAIError,
                .incompleteResponse(
                    finishReason: "MAX_TOKENS",
                    message: "output limit"
                )
            )
        }

        XCTAssertThrowsError(
            try backend.parseCandidateText(
                from: responseData(finishReason: nil)
            )
        ) { error in
            XCTAssertEqual(
                error as? VertexAIError,
                .incompleteResponse(
                    finishReason: "MISSING_FINISH_REASON",
                    message: "output limit"
                )
            )
        }
    }

    func testMissingCandidateContentAndWhitespaceAreErrors() throws {
        let aiStudio = GoogleAIStudioBackend()
        let vertex = VertexAIGeminiBackend()
        let noCandidates = Data("{\"candidates\":[]}".utf8)
        let noContent = Data(
            "{\"candidates\":[{\"finishReason\":\"STOP\"}]}".utf8
        )
        let whitespace = responseData(text: "  \n ")

        for data in [noCandidates, noContent, whitespace] {
            XCTAssertThrowsError(try aiStudio.parseCandidateText(from: data)) {
                XCTAssertEqual($0 as? GoogleAIStudioError, .emptyResponse)
            }
            XCTAssertThrowsError(try vertex.parseCandidateText(from: data)) {
                XCTAssertEqual($0 as? VertexAIError, .emptyResponse)
            }
        }
    }

    func testCloudPromptsDoNotForceTimestampsSpeakersOrDuplicateTerms() {
        let canonicalPrompt = "忠實轉錄。\n盛和塾"
        let aiStudio = GoogleAIStudioBackend()
        let aiStudioSystem = aiStudio.buildSystemInstruction()
        let aiStudioUser = aiStudio.buildUserPrompt(
            terms: ["盛和塾"],
            customPrompt: canonicalPrompt,
            timeOffsetSeconds: 1_200
        )
        XCTAssertTrue(aiStudioSystem.contains("不加時間戳"))
        XCTAssertTrue(aiStudioSystem.contains("不自行辨識、命名或標示講者"))
        XCTAssertEqual(aiStudioUser.components(separatedBy: "盛和塾").count - 1, 1)
        XCTAssertFalse(aiStudioUser.contains("請將輸出中的所有時間碼"))

        let vertex = VertexAIGeminiBackend()
        let vertexSystem = vertex.buildSystemInstruction()
        XCTAssertTrue(vertexSystem.contains("不得輸出摘要"))
        XCTAssertFalse(vertexSystem.contains("[00:00"))
        XCTAssertFalse(
            vertex.buildUserPrompt(
                terms: ["盛和塾"],
                customPrompt: canonicalPrompt,
                timeOffsetSeconds: 1_200
            ).contains("完整逐字稿之後")
        )
    }

    func testVertexMultipleSegmentsRequestExactlyOneWholeTranscriptSummary() async {
        let summaryCalls = LockedCounter()
        let captureLock = NSLock()
        var summarizedInput = ""

        let result = await TranscriptionEngine.finalizeVertexTranscript(
            segmentTexts: ["第一段逐字稿", "第二段逐字稿", "第三段逐字稿"],
            includeSummary: true,
            summarize: { completeTranscript in
                summaryCalls.increment()
                captureLock.withLock {
                    summarizedInput = completeTranscript
                }
                return "摘要：三段的整體重點"
            },
            update: { update in
                if case let .warning(code, message) = update {
                    XCTFail("不應收到警告 \(code)：\(message)")
                }
            }
        )

        XCTAssertEqual(summaryCalls.value, 1)
        XCTAssertEqual(
            captureLock.withLock { summarizedInput },
            "第一段逐字稿\n\n第二段逐字稿\n\n第三段逐字稿"
        )
        XCTAssertEqual(
            result,
            "第一段逐字稿\n\n第二段逐字稿\n\n第三段逐字稿\n\n摘要：三段的整體重點"
        )
    }

    func testVertexSummaryDisabledMakesNoSummaryCall() async {
        let summaryCalls = LockedCounter()

        let result = await TranscriptionEngine.finalizeVertexTranscript(
            segmentTexts: ["第一段", "第二段"],
            includeSummary: false,
            summarize: { _ in
                summaryCalls.increment()
                return "不應被使用"
            },
            update: { _ in }
        )

        XCTAssertEqual(summaryCalls.value, 0)
        XCTAssertEqual(result, "第一段\n\n第二段")
    }

    func testVertexSummaryFailureKeepsTranscriptAndEmitsWarning() async {
        let summaryCalls = LockedCounter()
        let warningCalls = LockedCounter()

        let result = await TranscriptionEngine.finalizeVertexTranscript(
            segmentTexts: ["已完成的逐字稿"],
            includeSummary: true,
            summarize: { _ in
                summaryCalls.increment()
                throw VertexAIError.incompleteResponse(
                    finishReason: "MAX_TOKENS",
                    message: "output limit"
                )
            },
            update: { update in
                guard case let .warning(code, message) = update else {
                    return
                }
                XCTAssertEqual(code, "vertex_summary_failed")
                XCTAssertTrue(message.contains("已保留完整逐字稿"))
                warningCalls.increment()
            }
        )

        XCTAssertEqual(summaryCalls.value, 1)
        XCTAssertEqual(warningCalls.value, 1)
        XCTAssertEqual(result, "已完成的逐字稿")
    }

    func testVertexLocationAndLongManualSliceKeepUserSelectedOffsets() {
        XCTAssertEqual(
            TranscriptionEngine.resolvedVertexLocation("us-central1"),
            "us-central1"
        )
        XCTAssertEqual(
            TranscriptionEngine.resolvedVertexLocation("  asia-east1  "),
            "asia-east1"
        )
        XCTAssertEqual(TranscriptionEngine.resolvedVertexLocation("  "), "global")

        let longManualSlice = TranscriptionSourceSlice(
            startSeconds: 3_600,
            durationSeconds: 2_700,
            partIndex: 2,
            partCount: 3
        )
        XCTAssertEqual(
            TranscriptionEngine.cloudSegmentStart(
                sourceSlice: longManualSlice,
                plannedStart: 1_200
            ),
            4_800
        )
    }

    func testFilesAPICleanupCompletesBeforeIncompleteResponseReturns() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStudioMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let deleteCount = LockedCounter()

        AIStudioMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response: HTTPURLResponse
            let data: Data
            switch url.absoluteString {
            case "https://generativelanguage.googleapis.com/upload/v1beta/files":
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "X-Goog-Upload-URL": "https://upload.example.test/resumable"
                    ]
                )!
                data = Data("{}".utf8)
            case "https://upload.example.test/resumable":
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data(
                    "{\"file\":{\"uri\":\"https://files.example.test/audio\",\"name\":\"files/test-audio\",\"state\":\"ACTIVE\"}}".utf8
                )
            case "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.7-flash:generateContent":
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = self.responseData(finishReason: "MAX_TOKENS")
            case "https://generativelanguage.googleapis.com/v1beta/files/test-audio":
                deleteCount.increment()
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            default:
                throw URLError(.badURL)
            }
            return (response, data)
        }
        defer {
            AIStudioMockURLProtocol.handler = nil
            AIStudioMockURLProtocol.shouldSuspend = nil
        }

        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(
                apiKey: "test-key",
                modelID: "gemini-3.7-flash",
                useFilesAPI: true
            )
        )
        do {
            _ = try await backend.transcribe(audioData: Data("audio".utf8))
            XCTFail("Expected an incomplete response error")
        } catch let error as GoogleAIStudioError {
            guard case .incompleteResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(deleteCount.value, 1)
    }

    func testFilesAPICleanupRunsWhenFinalizeResponseHasNameButNoURI() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStudioMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let deleteCount = LockedCounter()

        AIStudioMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response: HTTPURLResponse
            let data: Data
            switch url.absoluteString {
            case "https://generativelanguage.googleapis.com/upload/v1beta/files":
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "X-Goog-Upload-URL": "https://upload.example.test/missing-uri"
                    ]
                )!
                data = Data("{}".utf8)
            case "https://upload.example.test/missing-uri":
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data(
                    "{\"file\":{\"name\":\"files/missing-uri\",\"state\":\"ACTIVE\"}}".utf8
                )
            case "https://generativelanguage.googleapis.com/v1beta/files/missing-uri":
                deleteCount.increment()
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            case "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent":
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = self.responseData()
            default:
                throw URLError(.badURL)
            }
            return (response, data)
        }
        defer {
            AIStudioMockURLProtocol.handler = nil
            AIStudioMockURLProtocol.shouldSuspend = nil
        }

        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(
                apiKey: "test-key",
                modelID: "gemini-test",
                useFilesAPI: true
            )
        )
        let transcript = try await backend.transcribe(
            audioData: Data("audio".utf8)
        )
        XCTAssertEqual(transcript, "忠實逐字稿")
        XCTAssertEqual(deleteCount.value, 1)
    }

    func testOnlyRetryableServerFailuresMayTriggerEmergencyFallback() {
        XCTAssertTrue(
            GoogleAIStudioBackend.isRetryableServerFailure(
                .requestFailed(statusCode: 429, message: "busy")
            )
        )
        XCTAssertTrue(
            GoogleAIStudioBackend.isRetryableServerFailure(
                .requestFailed(statusCode: 500, message: "busy")
            )
        )
        XCTAssertTrue(
            GoogleAIStudioBackend.isRetryableServerFailure(
                .requestFailed(statusCode: 503, message: "busy")
            )
        )
        XCTAssertFalse(
            GoogleAIStudioBackend.isRetryableServerFailure(
                .requestFailed(statusCode: 400, message: "bad request")
            )
        )
        XCTAssertFalse(
            GoogleAIStudioBackend.isRetryableServerFailure(
                .incompleteResponse(finishReason: "MAX_TOKENS", message: nil)
            )
        )
    }

    func testFilesAPICleanupIsShieldedFromParentCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStudioMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let generateStarted = LockedCounter()
        let deleteCount = LockedCounter()

        AIStudioMockURLProtocol.shouldSuspend = { request in
            guard request.url?.path.contains(":generateContent") == true else {
                return false
            }
            generateStarted.increment()
            return true
        }
        AIStudioMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response: HTTPURLResponse
            let data: Data
            switch url.absoluteString {
            case "https://generativelanguage.googleapis.com/upload/v1beta/files":
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "X-Goog-Upload-URL": "https://upload.example.test/cancel"
                    ]
                )!
                data = Data("{}".utf8)
            case "https://upload.example.test/cancel":
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data(
                    "{\"file\":{\"uri\":\"https://files.example.test/cancel\",\"name\":\"files/cancel-audio\",\"state\":\"ACTIVE\"}}".utf8
                )
            case "https://generativelanguage.googleapis.com/v1beta/files/cancel-audio":
                deleteCount.increment()
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            default:
                throw URLError(.badURL)
            }
            return (response, data)
        }
        defer {
            AIStudioMockURLProtocol.handler = nil
            AIStudioMockURLProtocol.shouldSuspend = nil
        }

        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(
                apiKey: "test-key",
                modelID: "gemini-3.7-flash",
                useFilesAPI: true
            )
        )
        let transcription = Task {
            try await backend.transcribe(audioData: Data("audio".utf8))
        }

        for _ in 0..<100 where generateStarted.value == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(generateStarted.value, 1)
        transcription.cancel()
        do {
            _ = try await transcription.value
            XCTFail("Expected the suspended generation request to be cancelled")
        } catch {
            // The concrete Foundation error can be CancellationError or
            // URLError.cancelled. Cleanup behavior is the contract under test.
        }

        // deleteRemoteFileShielded awaits its detached DELETE before the
        // cancelled transcription returns, so this assertion needs no polling.
        XCTAssertEqual(deleteCount.value, 1)
    }

    private func responseData(
        finishReason: String? = "STOP",
        text: String = "忠實逐字稿"
    ) -> Data {
        var candidate: [String: Any] = [
            "content": ["parts": [["text": text]]],
            "finishMessage": "output limit"
        ]
        if let finishReason {
            candidate["finishReason"] = finishReason
        }
        return try! JSONSerialization.data(
            withJSONObject: ["candidates": [candidate]]
        )
    }
}

final class CloudCheckpointRecoveryTests: XCTestCase {
    func testCancellationCheckpointRequiresActualRecoverableText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "record-to-text-cancel-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let transcript = root.appendingPathComponent("segment-0001.txt")
        let manifestURL = root.appendingPathComponent("segment-manifest.json")
        let jobID = UUID()
        let manifest = AudioSegmentManifest(
            jobID: jobID,
            sourceDurationSeconds: 1_200,
            maximumSegmentDurationSeconds: 1_200,
            expectedSegmentCount: 1,
            segments: [
                AudioSegmentRecord(
                    segmentIndex: 1,
                    segmentCount: 1,
                    startSeconds: 0,
                    endSeconds: 1_200,
                    audioPath: "",
                    outputPath: transcript.path,
                    status: .transcribing
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        XCTAssertFalse(
            TranscriptionEngine.cloudCheckpointContainsRecoverableText(
                manifestURL: manifestURL
            )
        )
        try Data("   \n".utf8).write(to: transcript)
        XCTAssertFalse(
            TranscriptionEngine.cloudCheckpointContainsRecoverableText(
                manifestURL: manifestURL
            )
        )
        try Data("已完成的部分稿".utf8).write(to: transcript)
        XCTAssertTrue(
            TranscriptionEngine.cloudCheckpointContainsRecoverableText(
                manifestURL: manifestURL
            )
        )
    }

    func testRecoveredManifestUsesRecoveryPathsAndDoesNotRetainAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "record-to-text-cloud-recovery-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("working", isDirectory: true)
        let workingSegments = working.appendingPathComponent("segments", isDirectory: true)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingSegments,
            withIntermediateDirectories: true
        )

        let firstAudio = workingSegments.appendingPathComponent("segment-0001.mp3")
        let secondAudio = workingSegments.appendingPathComponent("segment-0002.mp3")
        let firstText = workingSegments.appendingPathComponent("segment-0001.txt")
        let secondText = workingSegments.appendingPathComponent("segment-0002.txt")
        let firstMetadata = workingSegments.appendingPathComponent(
            "segment-0001.metadata.json"
        )
        try Data("sensitive audio".utf8).write(to: firstAudio)
        try Data("sensitive audio".utf8).write(to: secondAudio)
        try Data("第一段已完成".utf8).write(to: firstText)
        try Data("{\"speakerScope\":\"segmentLocal\"}".utf8).write(
            to: firstMetadata
        )

        let jobID = UUID()
        let manifest = AudioSegmentManifest(
            jobID: jobID,
            sourceDurationSeconds: 2_400,
            maximumSegmentDurationSeconds: 1_200,
            expectedSegmentCount: 2,
            segments: [
                AudioSegmentRecord(
                    segmentIndex: 1,
                    segmentCount: 2,
                    startSeconds: 0,
                    endSeconds: 1_200,
                    audioPath: firstAudio.path,
                    outputPath: firstText.path,
                    metadataPath: firstMetadata.path,
                    status: .completed,
                    completedEventCount: 1
                ),
                AudioSegmentRecord(
                    segmentIndex: 2,
                    segmentCount: 2,
                    startSeconds: 1_200,
                    endSeconds: 2_400,
                    audioPath: secondAudio.path,
                    outputPath: secondText.path,
                    status: .failed,
                    failureMessage: "MAX_TOKENS"
                )
            ]
        )
        let manifestURL = working.appendingPathComponent("segment-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)

        let snapshot = JobSnapshot(
            modelID: "local-placeholder",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "忠實轉錄",
            outputLocationMode: .sameAsSource,
            outputDirectory: "",
            keepRawTranscript: false,
            backendType: .googleAIStudio
        )
        let job = TranscriptionJob(
            id: jobID,
            sourcePath: "/recordings/source.m4a",
            snapshot: snapshot
        )
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let runtime = ResolvedRuntime(
            python: executable,
            ffmpeg: executable,
            ffprobe: executable,
            opencc: executable,
            helper: executable,
            isDeveloperRuntime: true
        )
        let engine = TranscriptionEngine(
            runtime: runtime,
            paths: ApplicationPaths(root: root)
        )

        _ = try engine.preserveCloudRecoveryData(
            job: job,
            stage: .transcribing,
            error: GoogleAIStudioError.incompleteResponse(
                finishReason: "MAX_TOKENS",
                message: nil
            ),
            segmentManifestURL: manifestURL,
            recoveryDirectory: recovery
        )

        let recoveredManifestURL = recovery.appendingPathComponent(
            "segment-manifest.json"
        )
        let recoveredData = try Data(contentsOf: recoveredManifestURL)
        let recovered = try JSONDecoder().decode(
            AudioSegmentManifest.self,
            from: recoveredData
        )
        XCTAssertFalse(String(decoding: recoveredData, as: UTF8.self).contains(working.path))
        XCTAssertTrue(recovered.segments.allSatisfy { $0.audioPath.isEmpty })
        XCTAssertTrue(recovered.segments.allSatisfy {
            $0.outputPath.hasPrefix(recovery.path)
        })
        let recoveredMetadataPath = try XCTUnwrap(
            recovered.segments[0].metadataPath
        )
        XCTAssertTrue(recoveredMetadataPath.hasPrefix(recovery.path))
        XCTAssertFalse(recoveredMetadataPath.contains(working.path))
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: recoveredMetadataPath),
                encoding: .utf8
            ),
            "{\"speakerScope\":\"segmentLocal\"}"
        )
        XCTAssertNil(recovered.segments[1].metadataPath)
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: recovered.segments[0].outputPath),
                encoding: .utf8
            ),
            "第一段已完成"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: recovery
                    .appendingPathComponent("segments/segment-0001.mp3")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recovery.appendingPathComponent("partial-transcript.txt").path
            )
        )

        let metadataData = try Data(
            contentsOf: recovery.appendingPathComponent("recovery.json")
        )
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        XCTAssertEqual(metadata["schemaVersion"] as? Int, 2)
        XCTAssertEqual(metadata["recoveryKind"] as? String, "cloudCheckpoint")
        XCTAssertEqual(metadata["backendType"] as? String, "googleAIStudio")
    }
}
