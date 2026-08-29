import Foundation
import XCTest
@testable import RecordToTextCore

private final class MockAdaptiveCloudURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("MockAdaptiveCloudURLProtocol handler is missing")
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

private final class MockAIStudioTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var generateRequests: [URLRequest] = []
    private var generateResponses: [Result<(finishReason: String, text: String), Error>]
    private var filesCreated: [String] = []
    private var filesDeleted: [String] = []

    init(responses: [Result<(finishReason: String, text: String), Error>]) {
        self.generateResponses = responses
    }

    func handle(request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let urlString = url.absoluteString

        if urlString == "https://generativelanguage.googleapis.com/upload/v1beta/files" && request.httpMethod == "POST" {
            let uploadSessionID = UUID().uuidString
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "X-Goog-Upload-URL": "https://upload.example.test/resumable/\(uploadSessionID)"
                ]
            )!
            return (response, Data("{}".utf8))
        }

        if urlString.hasPrefix("https://upload.example.test/resumable/") && request.httpMethod == "POST" {
            let fileID = UUID().uuidString
            lock.withLock { filesCreated.append("files/\(fileID)") }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {
                "file": {
                    "name": "files/\(fileID)",
                    "uri": "https://files.example.test/\(fileID)",
                    "state": "ACTIVE"
                }
            }
            """
            return (response, Data(body.utf8))
        }

        if urlString.contains(":generateContent") && request.httpMethod == "POST" {
            lock.withLock { generateRequests.append(request) }
            let outcome: Result<(finishReason: String, text: String), Error> = lock.withLock {
                guard !generateResponses.isEmpty else {
                    return .failure(GoogleAIStudioError.emptyResponse)
                }
                return generateResponses.removeFirst()
            }
            switch outcome {
            case let .success((finishReason, text)):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let candidate: [String: Any] = [
                    "content": [
                        "parts": [["text": text]],
                        "role": "model"
                    ],
                    "finishReason": finishReason,
                    "finishMessage": "output limit"
                ]
                let payload: [String: Any] = [
                    "candidates": [candidate],
                    "modelVersion": "gemini-3.7-flash",
                    "responseId": "resp-\(UUID().uuidString)"
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (response, data)
            case let .failure(error):
                throw error
            }
        }

        if urlString.hasPrefix("https://generativelanguage.googleapis.com/v1beta/files/") && request.httpMethod == "DELETE" {
            let fileName = String(urlString.dropFirst("https://generativelanguage.googleapis.com/v1beta/".count))
            lock.withLock { filesDeleted.append(fileName) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        throw URLError(.badURL)
    }

    var recordedGenerateRequests: [URLRequest] {
        lock.withLock { generateRequests }
    }

    var createdFiles: [String] {
        lock.withLock { filesCreated }
    }

    var deletedFiles: [String] {
        lock.withLock { filesDeleted }
    }
}

final class CloudAdaptiveSegmentationTests: XCTestCase {
    func testSplitBoundaryPrefersNearestEligibleSilence() throws {
        let boundary = try XCTUnwrap(
            CloudAdaptiveSegmentPlanner.splitBoundary(
                duration: 1_200,
                splitDepth: 0,
                silences: [
                    DetectedSilence(startSeconds: 480, endSeconds: 481),
                    DetectedSilence(startSeconds: 618, endSeconds: 620),
                    DetectedSilence(startSeconds: 900, endSeconds: 901)
                ]
            )
        )
        XCTAssertEqual(boundary, 619, accuracy: 0.001)
    }

    func testSplitBoundaryStopsAtMaximumDepthAndMinimumDuration() {
        XCTAssertNil(
            CloudAdaptiveSegmentPlanner.splitBoundary(
                duration: 1_200,
                splitDepth:
                    CloudAdaptiveSegmentPlanner.productionMaximumSplitDepth
            )
        )
        XCTAssertNil(
            CloudAdaptiveSegmentPlanner.splitBoundary(
                duration:
                    CloudAdaptiveSegmentPlanner.productionMinimumChildDuration
                        * 2 - 1,
                splitDepth: 0
            )
        )
    }

    func testManifestSplitRenumbersContiguousChildren() throws {
        let directory = URL(fileURLWithPath: "/tmp/adaptive")
        let original = AudioSegmentRecord(
            segmentIndex: 1,
            segmentCount: 2,
            startSeconds: 0,
            endSeconds: 1_200,
            audioPath: "/tmp/adaptive/segment-0001.mp3",
            outputPath: "/tmp/adaptive/segment-0001.txt"
        )
        let trailing = AudioSegmentRecord(
            segmentIndex: 2,
            segmentCount: 2,
            startSeconds: 1_200,
            endSeconds: 1_800,
            audioPath: "/tmp/adaptive/segment-0002.mp3",
            outputPath: "/tmp/adaptive/segment-0002.txt"
        )
        let children = try XCTUnwrap(
            TranscriptionEngine.adaptiveCloudChildRecords(
                for: original,
                boundaryOffset: 600,
                segmentsDirectory: directory
            )
        )
        var manifest = AudioSegmentManifest(
            schemaVersion: 3,
            jobID: UUID(),
            sourceDurationSeconds: 1_800,
            maximumSegmentDurationSeconds: 1_200,
            expectedSegmentCount: 2,
            segments: [original, trailing]
        )
        try manifest.replaceSegment(segmentIndex: 1, with: children)

        XCTAssertEqual(manifest.expectedSegmentCount, 3)
        XCTAssertEqual(manifest.segments.map(\.segmentIndex), [1, 2, 3])
        XCTAssertTrue(manifest.segments.allSatisfy { $0.segmentCount == 3 })
        XCTAssertEqual(manifest.segments.map(\.startSeconds), [0, 600, 1_200])
        XCTAssertEqual(manifest.segments.map(\.endSeconds), [600, 1_200, 1_800])
        XCTAssertEqual(manifest.segments[0].splitDepth, 1)
        XCTAssertEqual(manifest.segments[1].splitDepth, 1)
        XCTAssertNotEqual(
            manifest.segments[0].outputPath,
            manifest.segments[1].outputPath
        )
    }

    func testAdaptiveSegmentationSucceedsAfterMaxTokensTruncation() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let outputDirectory = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let candidate = RuntimeEnvironment.candidate(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: true),
            bundledHelperURL: nil
        )
        guard FileManager.default.isExecutableFile(atPath: candidate.ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: candidate.ffprobe.path),
              FileManager.default.isExecutableFile(atPath: candidate.opencc.path)
        else {
            return XCTFail("Required audio tools (ffmpeg/ffprobe/opencc) are not available")
        }

        let sourceURL = root.appendingPathComponent("test_audio.wav")
        try await makeSineAudioFixture(
            durationSeconds: 4.0,
            destinationURL: sourceURL,
            ffmpegURL: candidate.ffmpeg
        )

        let parentTruncatedText = "這段截斷文字不得進入正式稿"
        let leftChildText = "[00:00 - 00:02]\n講者 1：左子段完整稿。"
        let rightChildText = "[00:02 - 00:04]\n講者 1：右子段完整稿。"

        let transport = MockAIStudioTransport(responses: [
            .success((finishReason: "MAX_TOKENS", text: parentTruncatedText)),
            .success((finishReason: "STOP", text: leftChildText)),
            .success((finishReason: "STOP", text: rightChildText))
        ])
        MockAdaptiveCloudURLProtocol.handler = { request in
            try transport.handle(request: request)
        }
        addTeardownBlock {
            MockAdaptiveCloudURLProtocol.handler = nil
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(
                apiKey: "mock-key",
                modelID: "gemini-3.7-flash"
            )
        )

        let engine = TranscriptionEngine(
            runtime: candidate,
            paths: paths,
            googleAIStudioBackend: backend,
            cloudAdaptiveMinimumChildDuration: 1.0
        )

        let snapshot = JobSnapshot(
            modelID: "gemini-3.7-flash",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "忠實轉錄",
            outputLocationMode: .fixedDirectory,
            outputDirectory: outputDirectory.path,
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioAPIKey: "mock-key",
            googleAIStudioModelID: "gemini-3.7-flash"
        )
        let job = TranscriptionJob(
            id: UUID(),
            sourcePath: sourceURL.path,
            snapshot: snapshot
        )

        var observedUpdates: [PipelineUpdate] = []
        let result = try await engine.run(job: job) { update in
            observedUpdates.append(update)
        }

        // 1. Assert cloud requests sequence: Parent -> Left Child -> Right Child
        XCTAssertEqual(transport.recordedGenerateRequests.count, 3)
        XCTAssertEqual(transport.createdFiles.count, 3)
        XCTAssertEqual(transport.deletedFiles.count, 3)

        // 2. Assert warning was emitted for MAX_TOKENS adaptive split
        let splitWarnings = observedUpdates.compactMap { update -> String? in
            if case let .warning(code, message) = update, code == "cloud_segment_split_max_tokens" {
                return message
            }
            return nil
        }
        XCTAssertEqual(splitWarnings.count, 1)
        let warningMsg = try XCTUnwrap(splitWarnings.first)
        XCTAssertTrue(warningMsg.contains("第 1 段達輸出上限"))
        XCTAssertTrue(warningMsg.contains("已捨棄截斷稿並在 2.0 秒處切成兩段重試；目前共 2 段"))

        // 3. Assert result properties
        XCTAssertFalse(result.containsSkippedAudio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))

        // 4. Assert final transcript content
        let finalContent = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(finalContent.contains("左子段完整稿"))
        XCTAssertTrue(finalContent.contains("右子段完整稿"))
        XCTAssertFalse(finalContent.contains(parentTruncatedText), "Parent truncated text must NOT enter final transcript")
        XCTAssertFalse(finalContent.contains("未完成"), "No incomplete draft markers in final transcript")
        XCTAssertFalse(finalContent.contains("跳過"), "No skipped audio markers in final transcript")

        // 5. Assert working directory was cleaned up and temp recovery is clean
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text")
            .appendingPathComponent(job.id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.path))

        let recoveryJobDirectory = paths.tempRecovery.appendingPathComponent(job.id.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryJobDirectory.path))
    }

    func testAdaptiveSegmentationChildFailureFailsClosedWithoutFinalTranscript() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let outputDirectory = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let candidate = RuntimeEnvironment.candidate(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: true),
            bundledHelperURL: nil
        )
        guard FileManager.default.isExecutableFile(atPath: candidate.ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: candidate.ffprobe.path),
              FileManager.default.isExecutableFile(atPath: candidate.opencc.path)
        else {
            return XCTFail("Required audio tools (ffmpeg/ffprobe/opencc) are not available")
        }

        let sourceURL = root.appendingPathComponent("test_fail_audio.wav")
        try await makeSineAudioFixture(
            durationSeconds: 4.0,
            destinationURL: sourceURL,
            ffmpegURL: candidate.ffmpeg
        )

        let parentTruncatedText = "這段截斷文字不得進入正式稿"
        let leftChildText = "[00:00 - 00:02]\n講者 1：左子段完整稿。"
        let childError = GoogleAIStudioError.requestFailed(statusCode: 500, message: "Internal server error")

        let transport = MockAIStudioTransport(responses: [
            .success((finishReason: "MAX_TOKENS", text: parentTruncatedText)),
            .success((finishReason: "STOP", text: leftChildText)),
            .failure(childError)
        ])
        MockAdaptiveCloudURLProtocol.handler = { request in
            try transport.handle(request: request)
        }
        addTeardownBlock {
            MockAdaptiveCloudURLProtocol.handler = nil
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(
                apiKey: "mock-key",
                modelID: "gemini-3.7-flash"
            )
        )

        let engine = TranscriptionEngine(
            runtime: candidate,
            paths: paths,
            googleAIStudioBackend: backend,
            cloudAdaptiveMinimumChildDuration: 1.0
        )

        let snapshot = JobSnapshot(
            modelID: "gemini-3.7-flash",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "忠實轉錄",
            outputLocationMode: .fixedDirectory,
            outputDirectory: outputDirectory.path,
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioAPIKey: "mock-key",
            googleAIStudioModelID: "gemini-3.7-flash"
        )
        let job = TranscriptionJob(
            id: UUID(),
            sourcePath: sourceURL.path,
            snapshot: snapshot
        )

        do {
            _ = try await engine.run(job: job) { _ in }
            XCTFail("Expected run to throw PipelineExecutionError when right child fails")
        } catch let pipelineError as PipelineExecutionError {
            XCTAssertEqual(pipelineError.stage, .transcribing)
            let recoveryDir = try XCTUnwrap(pipelineError.recoveryDirectory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryDir.path))

            // 1. Assert NO formal output was created in outputDirectory
            let outputFiles = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
            XCTAssertTrue(outputFiles.isEmpty, "No output files should exist in outputDirectory upon failure")

            // 2. Assert recovery manifest structure
            let manifestURL = recoveryDir.appendingPathComponent("segment-manifest.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(AudioSegmentManifest.self, from: manifestData)

            XCTAssertEqual(manifest.expectedSegmentCount, 2)
            XCTAssertEqual(manifest.segments.count, 2)
            XCTAssertEqual(manifest.segments[0].segmentIndex, 1)
            XCTAssertEqual(manifest.segments[0].status, .completed)
            XCTAssertEqual(manifest.segments[0].completedEventCount, 1)
            XCTAssertEqual(manifest.segments[0].splitDepth, 1)

            XCTAssertEqual(manifest.segments[1].segmentIndex, 2)
            XCTAssertEqual(manifest.segments[1].status, .failed)
            XCTAssertEqual(manifest.segments[1].completedEventCount, 0)
            XCTAssertEqual(manifest.segments[1].splitDepth, 1)
            XCTAssertTrue(manifest.segments[1].failureMessage?.contains("500") == true)

            // 3. Assert partial transcript in recovery contains completed child and NOT parent truncated text
            let partialTranscriptURL = recoveryDir.appendingPathComponent("partial-transcript.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: partialTranscriptURL.path))
            let partialContent = try String(contentsOf: partialTranscriptURL, encoding: .utf8)
            XCTAssertTrue(partialContent.contains("未完成逐字稿"))
            XCTAssertTrue(partialContent.contains("左子段完整稿"))
            XCTAssertFalse(partialContent.contains(parentTruncatedText), "Parent truncated text must NOT be in recovery transcript")

            // 4. Assert recovery metadata
            let recoveryJSONURL = recoveryDir.appendingPathComponent("recovery.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryJSONURL.path))
            let recoveryData = try Data(contentsOf: recoveryJSONURL)
            let recoveryJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: recoveryData) as? [String: Any])
            XCTAssertEqual(recoveryJSON["failureStage"] as? String, "transcribing")
            XCTAssertEqual(recoveryJSON["backendType"] as? String, "googleAIStudio")
        }
    }

    func testAdaptiveSegmentationExceedingMaxSplitDepthFailsClosed() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        let outputDirectory = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let candidate = RuntimeEnvironment.candidate(
            paths: paths,
            settings: AppSettings.defaultValue(developerMode: true),
            bundledHelperURL: nil
        )
        guard FileManager.default.isExecutableFile(atPath: candidate.ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: candidate.ffprobe.path),
              FileManager.default.isExecutableFile(atPath: candidate.opencc.path)
        else {
            return XCTFail("Required audio tools (ffmpeg/ffprobe/opencc) are not available")
        }

        let sourceURL = root.appendingPathComponent("test_depth_audio.wav")
        try await makeSineAudioFixture(
            durationSeconds: 4.0,
            destinationURL: sourceURL,
            ffmpegURL: candidate.ffmpeg
        )

        // Depth 0: parent (4s) -> MAX_TOKENS -> splits to Depth 1 (2s each)
        // Depth 1: child A (2s) -> MAX_TOKENS -> splits to Depth 2 (1s each)
        // Depth 2: grandchild A1 (1s) -> MAX_TOKENS -> reaches maxDepth 2, cannot split further
        let transport = MockAIStudioTransport(responses: [
            .success((finishReason: "MAX_TOKENS", text: "截斷文字 0")),
            .success((finishReason: "MAX_TOKENS", text: "截斷文字 1")),
            .success((finishReason: "MAX_TOKENS", text: "截斷文字 2"))
        ])
        MockAdaptiveCloudURLProtocol.handler = { request in
            try transport.handle(request: request)
        }
        addTeardownBlock {
            MockAdaptiveCloudURLProtocol.handler = nil
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(
                apiKey: "mock-key",
                modelID: "gemini-3.7-flash"
            )
        )

        let engine = TranscriptionEngine(
            runtime: candidate,
            paths: paths,
            googleAIStudioBackend: backend,
            cloudAdaptiveMinimumChildDuration: 0.5
        )

        let snapshot = JobSnapshot(
            modelID: "gemini-3.7-flash",
            glossaryID: nil,
            glossaryName: nil,
            terms: [],
            prompt: "忠實轉錄",
            outputLocationMode: .fixedDirectory,
            outputDirectory: outputDirectory.path,
            keepRawTranscript: false,
            backendType: .googleAIStudio,
            googleAIStudioAPIKey: "mock-key",
            googleAIStudioModelID: "gemini-3.7-flash"
        )
        let job = TranscriptionJob(
            id: UUID(),
            sourcePath: sourceURL.path,
            snapshot: snapshot
        )

        do {
            _ = try await engine.run(job: job) { _ in }
            XCTFail("Expected run to throw when maximum split depth is exceeded with MAX_TOKENS")
        } catch let pipelineError as PipelineExecutionError {
            XCTAssertEqual(pipelineError.stage, .transcribing)
            XCTAssertTrue(pipelineError.underlying is CloudOutputTruncatedError || pipelineError.underlying is AudioSegmentationError)

            // Assert NO formal output created
            let outputFiles = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
            XCTAssertTrue(outputFiles.isEmpty)

            // Assert recovery data exists
            let recoveryDir = try XCTUnwrap(pipelineError.recoveryDirectory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryDir.path))

            let manifestURL = recoveryDir.appendingPathComponent("segment-manifest.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
            let manifest = try JSONDecoder().decode(
                AudioSegmentManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            // Grandchild A1 (segment 1) failed
            XCTAssertEqual(manifest.segments[0].status, .failed)
            XCTAssertEqual(manifest.segments[0].splitDepth, 2)
        }
    }

    private func makeSineAudioFixture(
        durationSeconds: Double,
        destinationURL: URL,
        ffmpegURL: URL
    ) async throws {
        let runner = ProcessRunner()
        _ = try await runner.run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi",
                "-i", "sine=frequency=440:sample_rate=16000",
                "-t", String(format: "%.3f", durationSeconds),
                "-c:a", "pcm_s16le",
                destinationURL.path
            ]
        )
    }
}
