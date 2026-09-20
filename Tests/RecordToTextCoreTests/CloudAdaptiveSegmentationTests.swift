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
            let fileID = UUID().uuidString.lowercased()
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
            var capturedRequest = request
            if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count == 0 { break }
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    data.append(contentsOf: buffer.prefix(count))
                }
                capturedRequest.httpBody = data
            }
            lock.withLock { generateRequests.append(capturedRequest) }
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
                if let studioError = error as? GoogleAIStudioError,
                   case let .requestFailed(statusCode, message) = studioError {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    let payload: [String: Any] = [
                        "error": [
                            "code": statusCode,
                            "message": message,
                            "status": "INVALID_ARGUMENT"
                        ]
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    return (response, data)
                }
                throw error
            }
        }

        if urlString.hasPrefix("https://generativelanguage.googleapis.com/v1beta/files/") && request.httpMethod == "GET" {
            let name = String(urlString.dropFirst("https://generativelanguage.googleapis.com/v1beta/".count))
            let exists = lock.withLock { filesCreated.contains(name) && !filesDeleted.contains(name) }
            return (HTTPURLResponse(url: url, statusCode: exists ? 200 : 404, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: ["name": name, "state": "ACTIVE"]))
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

private final class CloudSilenceDetectorSpy: SilenceDetectionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(start: Double, duration: Double)] = []
    let result: [DetectedSilence]

    init(result: [DetectedSilence] = []) {
        self.result = result
    }

    func detect(
        sourceURL: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> [DetectedSilence] {
        lock.withLock {
            calls.append((startSeconds, durationSeconds))
        }
        return result
    }
}

final class CloudAdaptiveSegmentationTests: XCTestCase {
    func testThirdSegmentNetworkPauseResumesWithoutReuploadingFirstTwo() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        try paths.createDirectories()
        let runtime = RuntimeEnvironment.candidate(paths: paths,
            settings: AppSettings.defaultValue(developerMode: true), bundledHelperURL: nil)
        let source = root.appendingPathComponent("fixture.wav")
        try await makeSineAudioFixture(durationSeconds: 6, destinationURL: source, ffmpegURL: runtime.ffmpeg)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MockAdaptiveCloudURLProtocol.handler = nil }
        let clock = RecoveryClock()
        let backend = GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "mock"))
        let engine = TranscriptionEngine(cloudNetworkEnvironment: clock.environment(), runtime: runtime,
            paths: paths, googleAIStudioBackend: backend, maximumASRSegmentDuration: 2,
            silenceDetectionService: CloudSilenceDetectorSpy())
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "忠實轉錄", outputLocationMode: .fixedDirectory,
            outputDirectory: root.path, keepRawTranscript: false, backendType: .googleAIStudio,
            googleAIStudioAPIKey: "mock", silenceAwareCloudSegmentation: false)
        let initial = MockAIStudioTransport(responses: [
            .success(("STOP", "[00:00 - 00:02]\n講者 1：第一段。")),
            .success(("STOP", "[00:02 - 00:04]\n講者 1：第二段。"))
        ] + Array(repeating: .failure(URLError(.networkConnectionLost)), count: 4))
        MockAdaptiveCloudURLProtocol.handler = { try initial.handle(request: $0) }
        var recovery: URL?
        do {
            _ = try await engine.run(job: .init(sourcePath: source.path, snapshot: snapshot)) { _ in }
            XCTFail("Expected pause")
        } catch let error as PipelineExecutionError {
            recovery = error.recoveryDirectory
            XCTAssertEqual(error.networkRecovery?.completedSegmentCount, 2)
            XCTAssertEqual(error.networkRecovery?.state, .paused)
        }
        let directory = try XCTUnwrap(recovery)
        let manifest = try JSONDecoder().decode(AudioSegmentManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent(RecoveryScanner.segmentManifestFileName)))
        let completed = Array(manifest.segments.prefix(2))
        let original = try completed.map { try Data(contentsOf: URL(fileURLWithPath: $0.outputPath)) }
        XCTAssertEqual(initial.createdFiles.count, 3)
        XCTAssertEqual(initial.recordedGenerateRequests.count, 6)
        let remaining = MockAIStudioTransport(responses: [.success(("STOP", "[00:04 - 00:06]\n講者 1：第三段。"))])
        MockAdaptiveCloudURLProtocol.handler = { try remaining.handle(request: $0) }
        let resumed = TranscriptionJob(sourcePath: source.path, snapshot: snapshot, resumeFromRecoveryDirectory: directory.path)
        let result = try await engine.run(job: resumed, persistCompletion: { _ in false }) { _ in }
        XCTAssertEqual(remaining.createdFiles.count, 1)
        XCTAssertEqual(remaining.recordedGenerateRequests.count, 1)
        let diagnostics = try XCTUnwrap(result.cloudDiagnostics)
        XCTAssertEqual(diagnostics.segments.map(\.reusedFromCheckpoint), [true, true, false])
        XCTAssertEqual(try completed.map { try Data(contentsOf: URL(fileURLWithPath: $0.outputPath)) }, original)
        let text = try String(contentsOf: result.outputURL, encoding: .utf8)
        for content in ["第一段", "第二段", "第三段"] { XCTAssertTrue(text.contains(content)) }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text").appendingPathComponent(resumed.id.uuidString))
    }

    func testSpeakerLabelsSurviveSegmentsMergeAndLegacyCheckpointResume() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        try paths.createDirectories()
        let runtime = RuntimeEnvironment.candidate(paths: paths,
            settings: AppSettings.defaultValue(developerMode: true), bundledHelperURL: nil)
        let source = root.appendingPathComponent("voices.wav")
        try await makeSineAudioFixture(durationSeconds: 4, destinationURL: source, ffmpegURL: runtime.ffmpeg)
        let first = "講者 1：我是負責這個專案的人員。\n王小明：早安。\n陳小明：你好。"
        let second = "講者 1：我叫陳大文。\n小明：我補充一下。"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MockAdaptiveCloudURLProtocol.handler = nil }
        let backend = GoogleAIStudioBackend(networkEnvironment: RecoveryClock().environment(), urlSession: session,
            configuration: .init(apiKey: "mock", modelID: "gemini-3.7-flash"))
        let engine = TranscriptionEngine(runtime: runtime, paths: paths, googleAIStudioBackend: backend,
            maximumASRSegmentDuration: 2, silenceDetectionService: CloudSilenceDetectorSpy())
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            terms: [], prompt: "忠實轉錄", outputLocationMode: .fixedDirectory,
            outputDirectory: root.path, keepRawTranscript: false, backendType: .googleAIStudio,
            googleAIStudioAPIKey: "mock", googleAIStudioModelID: "gemini-3.7-flash",
            silenceAwareCloudSegmentation: false)
        let initial = MockAIStudioTransport(responses: [.success(("STOP", first)),
            .failure(GoogleAIStudioError.requestFailed(statusCode: 400, message: "fixture failure"))])
        MockAdaptiveCloudURLProtocol.handler = { try initial.handle(request: $0) }
        let job = TranscriptionJob(sourcePath: source.path, snapshot: snapshot)
        var recovery: URL?
        do { _ = try await engine.run(job: job) { _ in }; XCTFail("Expected interruption") }
        catch let error as PipelineExecutionError { recovery = error.recoveryDirectory }
        let checkpointDirectory = try XCTUnwrap(recovery)
        let manifestURL = checkpointDirectory.appendingPathComponent(RecoveryScanner.segmentManifestFileName)
        var manifest = try JSONDecoder().decode(AudioSegmentManifest.self, from: Data(contentsOf: manifestURL))
        let savedTranscript = URL(fileURLWithPath: manifest.segments[0].outputPath)
        let originalBytes = try Data(contentsOf: savedTranscript)
        XCTAssertTrue(String(decoding: originalBytes, as: UTF8.self).contains(first))
        manifest.speakerRoster = SpeakerRoster(identities: [SpeakerIdentity(canonicalLabel: "錯誤姓名",
            aliases: ["講者 1", "小明"], firstSeenSegment: 1, confidence: .explicit)])
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let resumedTransport = MockAIStudioTransport(responses: [.success(("STOP", second))])
        MockAdaptiveCloudURLProtocol.handler = { try resumedTransport.handle(request: $0) }
        let resumed = TranscriptionJob(sourcePath: source.path, snapshot: snapshot,
            resumeFromRecoveryDirectory: checkpointDirectory.path)
        // Keep checkpoint during this verification, as if durable completion is delayed.
        let result = try await engine.run(job: resumed, persistCompletion: { _ in false }) { _ in }
        let text = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(text.contains(first), text)
        XCTAssertTrue(text.contains(second))
        XCTAssertFalse(text.contains("錯誤姓名"))
        XCTAssertEqual(resumedTransport.recordedGenerateRequests.count, 1)
        let diagnostics = try XCTUnwrap(result.cloudDiagnostics)
        XCTAssertEqual(diagnostics.segments.count, 2)
        XCTAssertTrue(diagnostics.segments[0].reusedFromCheckpoint)
        XCTAssertFalse(diagnostics.segments[1].reusedFromCheckpoint)
        XCTAssertNotNil(diagnostics.timestampNotice)
        XCTAssertTrue(diagnostics.segments.allSatisfy { $0.timestampReview?.needsReview == true })
        XCTAssertEqual(try Data(contentsOf: savedTranscript), originalBytes)
        let request = try XCTUnwrap(resumedTransport.recordedGenerateRequests.first?.httpBody)
        XCTAssertFalse(String(decoding: request, as: UTF8.self).contains("錯誤姓名"))
        // Timestamp notices must not turn into apparent speaker identities.
        XCTAssertFalse(String(decoding: request, as: UTF8.self).contains("- [時間標記提示"))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("record-to-text").appendingPathComponent(resumed.id.uuidString)
        try? FileManager.default.removeItem(at: work)
    }

    func testNetworkRetryReusesUploadedFile() async throws {
        let transport = MockAIStudioTransport(responses: [
            .failure(URLError(.networkConnectionLost)),
            .success((finishReason: "STOP", text: "完整逐字稿"))
        ])
        MockAdaptiveCloudURLProtocol.handler = { try transport.handle(request: $0) }
        defer { MockAdaptiveCloudURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let backend = GoogleAIStudioBackend(networkEnvironment: RecoveryClock().environment(), urlSession: session,
            configuration: .init(apiKey: "mock", modelID: "gemini-3.8-flash"))
        let collector = CloudDiagnosticCollector()
        let text = try await CloudDiagnosticContext.$current.withValue(collector) {
            try await backend.transcribe(audioData: Data("audio".utf8))
        }
        XCTAssertEqual(text, "完整逐字稿")
        XCTAssertEqual(transport.recordedGenerateRequests.count, 2)
        XCTAssertEqual(transport.createdFiles.count, 1)
        XCTAssertEqual(transport.deletedFiles.count, 1)
        let diagnostic = collector.snapshot(start: 0, end: 4, outcome: .completed, preparation: nil, cloud: nil)
        XCTAssertEqual(diagnostic.retryReasons, [.network, .transportReset])
        XCTAssertTrue(diagnostic.stageTimings.contains { $0.stage == .backoff && $0.seconds > 0 })
        XCTAssertTrue(diagnostic.stageTimings.contains { $0.stage == .generation && $0.seconds > 0 })
    }

    func testBudgetStopsNetworkAndServerRetriesBeforeFallback() async throws {
        for failure in [URLError(.networkConnectionLost) as Error, GoogleAIStudioError.requestFailed(statusCode: 503, message: "busy")] {
            let transport = MockAIStudioTransport(responses: [.failure(failure)])
            MockAdaptiveCloudURLProtocol.handler = { try transport.handle(request: $0) }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
            let session = URLSession(configuration: config)
            let backend = GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "mock", modelID: "gemini-3.8-flash"))
            let budget = CloudSegmentBudget(limit: .milliseconds(400))
            do {
                _ = try await CloudBudgetContext.$current.withValue(budget) {
                    try await backend.transcribe(audioData: Data("audio".utf8))
                }
                XCTFail("Retry exceeded budget")
            } catch let error as CloudSegmentDeadlineExceeded {
                XCTAssertEqual(error.stage, "backoff")
                XCTAssertEqual(transport.recordedGenerateRequests.count, 1)
                XCTAssertEqual(transport.createdFiles.count, 1)
            } catch let error as CloudNetworkRecoveryExhausted {
                XCTAssertEqual(error.recovery.stopReason, .rootDeadline)
                XCTAssertEqual(transport.recordedGenerateRequests.count, 1)
            }
            try await Task.sleep(for: .milliseconds(30))
            session.invalidateAndCancel()
        }
        MockAdaptiveCloudURLProtocol.handler = nil
    }

    func testFilesPollingUsesRootDeadline() async throws {
        let transport = MockAIStudioTransport(responses: [])
        MockAdaptiveCloudURLProtocol.handler = { request in
            let (response, data) = try transport.handle(request: request)
            let body = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "ACTIVE", with: "PROCESSING")
            return (response, Data(body.utf8))
        }
        defer { MockAdaptiveCloudURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let backend = GoogleAIStudioBackend(urlSession: session, configuration: .init(apiKey: "mock"))
        do {
            _ = try await CloudBudgetContext.$current.withValue(CloudSegmentBudget(limit: .milliseconds(100))) {
                try await backend.transcribe(audioData: Data("audio".utf8))
            }
            XCTFail("Polling exceeded root deadline")
        } catch let error as CloudSegmentDeadlineExceeded {
            XCTAssertEqual(error.stage, "poll")
            XCTAssertEqual(transport.recordedGenerateRequests.count, 0)
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    func testPreviouslyBlockedFiveAndSevenMinuteSegmentsCanSplit() {
        XCTAssertEqual(CloudAdaptiveSegmentPlanner.splitBoundary(duration: 300, splitDepth: 2), 150)
        XCTAssertEqual(CloudAdaptiveSegmentPlanner.splitBoundary(duration: 430, splitDepth: 1), 215)
    }

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
        try await assertAdaptiveRecovery(parentTruncatedText: "這段截斷文字不得進入正式稿")
    }

    func testAdaptiveSegmentationRecoversFromEmptyMaxTokens() async throws {
        try await assertAdaptiveRecovery(parentTruncatedText: "")
    }

    func testRightChildDeadlinePreservesLeftAndRejectsLateResponse() async throws {
        try await assertAdaptiveRecovery(parentTruncatedText: "截斷", expireRight: true)
    }

    func testCompletionReceiptPrecedesWorkspaceCleanup() async throws {
        try await assertAdaptiveRecovery(parentTruncatedText: "截斷", completionDurable: false)
    }

    func testTimestampRepairUsesActualChildBoundsWithoutExtraCloudRequests() async throws {
        try await assertAdaptiveRecovery(parentTruncatedText: "截斷", timestampAnomalies: true)
    }

    private func assertAdaptiveRecovery(parentTruncatedText: String, expireRight: Bool = false, completionDurable: Bool = true, timestampAnomalies: Bool = false) async throws {
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

        let leftChildText = timestampAnomalies ? "講者 1：左子段完整稿。" : "[00:00 - 00:02]\n講者 1：左子段完整稿。"
        let rightChildText = timestampAnomalies ? "[00:02 - 05:02]\n講者 1：右子段完整稿。" : "[00:02 - 00:04]\n講者 1：右子段完整稿。"

        let transport = MockAIStudioTransport(responses: [
            .success((finishReason: "MAX_TOKENS", text: parentTruncatedText)),
            .success((finishReason: "STOP", text: leftChildText)),
            .success((finishReason: "STOP", text: rightChildText))
        ])
        MockAdaptiveCloudURLProtocol.handler = { request in
            if expireRight, request.url?.absoluteString.contains(":generateContent") == true,
               transport.recordedGenerateRequests.count == 2 {
                Thread.sleep(forTimeInterval: 1.5)
            }
            return try transport.handle(request: request)
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
        let silenceDetector = CloudSilenceDetectorSpy()

        let engine = TranscriptionEngine(
            runtime: candidate,
            paths: paths,
            googleAIStudioBackend: backend,
            cloudAdaptiveMinimumChildDuration: 1.0,
            silenceDetectionService: silenceDetector,
            cloudSegmentBudgetLimit: expireRight ? .seconds(1) : .seconds(900)
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
        if expireRight {
            do {
                _ = try await engine.run(job: job) { _ in }
                XCTFail("Deadline accepted late right child")
            } catch let error as PipelineExecutionError {
                let deadline = try XCTUnwrap(error.underlying as? CloudSegmentDeadlineExceeded)
                XCTAssertEqual(deadline.stage, "generation")
                let recovery = try XCTUnwrap(error.recoveryDirectory)
                let data = try Data(contentsOf: recovery.appendingPathComponent(RecoveryScanner.segmentManifestFileName))
                let manifest = try JSONDecoder().decode(AudioSegmentManifest.self, from: data)
                XCTAssertEqual(manifest.segments.count, 2)
                XCTAssertEqual(manifest.segments[0].status, .completed)
                XCTAssertEqual(manifest.segments[1].status, .failed)
                XCTAssertEqual(manifest.segments[1].deadlineReason, "generation")
                XCTAssertEqual(manifest.segments[0].diagnostic?.outcome, .completed)
                XCTAssertEqual(manifest.segments[1].diagnostic?.outcome, .deadlineExceeded)
                XCTAssertEqual(manifest.discardedDiagnostics?.count, 1)
                XCTAssertNotNil(manifest.failureHistory)
                XCTAssertEqual(manifest.segments[0].rootSegmentID, manifest.segments[1].rootSegmentID)
                XCTAssertEqual(manifest.segments[0].rootSegmentID, deadline.rootSegmentID)
                XCTAssertTrue(try String(contentsOfFile: manifest.segments[0].outputPath).contains("左子段完整稿"))
                try await Task.sleep(for: .seconds(1.6))
                XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(RecoveryScanner.segmentManifestFileName)), data)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).count, 0)
            }
            return
        }
        let result = try await engine.run(job: job, persistCompletion: { result in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("record-to-text").appendingPathComponent(job.id.uuidString)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
            return completionDurable
        }) { update in
            observedUpdates.append(update)
        }

        // 1. Assert cloud requests sequence: Parent -> Left Child -> Right Child
        XCTAssertEqual(transport.recordedGenerateRequests.count, 3)
        for request in transport.recordedGenerateRequests {
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
            XCTAssertEqual(config["maxOutputTokens"] as? Int, 65_536)
        }
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
        let diagnostics = try XCTUnwrap(result.cloudDiagnostics)
        XCTAssertEqual(diagnostics.segments.map(\.outcome), [.split, .completed, .completed])
        XCTAssertTrue(diagnostics.segments.allSatisfy { ($0.cloudSeconds ?? 0) > 0 })
        XCTAssertTrue(diagnostics.segments.allSatisfy { ($0.preparationSeconds ?? 0) > 0 })
        if timestampAnomalies {
            XCTAssertEqual(diagnostics.segments[1].timestampReview?.disposition, .segmentRangeOnly)
            XCTAssertEqual(diagnostics.segments[2].timestampReview?.disposition, .boundsCorrected)
            XCTAssertNotNil(diagnostics.timestampNotice)
        } else {
            XCTAssertNil(diagnostics.timestampNotice)
        }

        // 4. Assert final transcript content
        let finalContent = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(finalContent.contains("左子段完整稿"))
        XCTAssertTrue(finalContent.contains("右子段完整稿"))
        if timestampAnomalies {
            XCTAssertTrue(finalContent.contains(TranscriptTimestampValidator.reviewNotice))
            XCTAssertTrue(finalContent.contains("[00:02 - 00:04]"))
            XCTAssertFalse(finalContent.contains("05:02"))
            let lastBody = try XCTUnwrap(transport.recordedGenerateRequests.last?.httpBody)
            XCTAssertTrue(String(decoding: lastBody, as: UTF8.self).contains("[00:02 - 00:04]"))
        }
        if !parentTruncatedText.isEmpty {
            XCTAssertFalse(finalContent.contains(parentTruncatedText), "Parent truncated text must NOT enter final transcript")
        }
        XCTAssertFalse(finalContent.contains("未完成"), "No incomplete draft markers in final transcript")
        XCTAssertFalse(finalContent.contains("跳過"), "No skipped audio markers in final transcript")
        XCTAssertEqual(
            silenceDetector.calls.count,
            1,
            "A successful parent scan should be reused by both adaptive children"
        )

        // 5. Assert working directory was cleaned up and temp recovery is clean
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text")
            .appendingPathComponent(job.id.uuidString)
        XCTAssertEqual(FileManager.default.fileExists(atPath: workingDirectory.path), !completionDurable)
        if !completionDurable { try FileManager.default.removeItem(at: workingDirectory) }

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
        let childError = GoogleAIStudioError.requestFailed(statusCode: 400, message: "Invalid argument")

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
            XCTAssertTrue(manifest.segments[1].failureMessage?.contains("400") == true)
            XCTAssertTrue(manifest.segments[1].failureMessage?.contains("Invalid argument") == true)

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

        // Repeated truncation must stop at the production depth limit.
        let transport = MockAIStudioTransport(responses: [
            .success((finishReason: "MAX_TOKENS", text: "截斷文字 0")),
            .success((finishReason: "MAX_TOKENS", text: "截斷文字 1")),
            .success((finishReason: "MAX_TOKENS", text: "截斷文字 2")),
            .success((finishReason: "MAX_TOKENS", text: "截斷文字 3")),
            .success((finishReason: "MAX_TOKENS", text: "截斷文字 4"))
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
            cloudAdaptiveMinimumChildDuration: 0.1
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
            XCTAssertTrue((pipelineError.underlying as? CloudSegmentExecutionError)?.underlying is CloudOutputTruncatedError)

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
            XCTAssertEqual(manifest.segments[0].splitDepth, 4)
            XCTAssertEqual(transport.recordedGenerateRequests.count, 5)
            XCTAssertTrue(manifest.segments[0].failureMessage?.contains("已停止自動重試") == true)
            XCTAssertFalse(manifest.segments[0].failureMessage?.contains("將切小") == true)
        }
    }

    func testDisabledSilenceAwareDoesNotCallDetectorForInitialOrAdaptiveSplit() async throws {
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

        let sourceURL = root.appendingPathComponent("disabled-silence.wav")
        try await makeSineAudioFixture(
            durationSeconds: 4.0,
            destinationURL: sourceURL,
            ffmpegURL: candidate.ffmpeg
        )

        let transport = MockAIStudioTransport(responses: [
            .success((finishReason: "MAX_TOKENS", text: "截斷")),
            .success((finishReason: "STOP", text: "[00:00 - 00:01]\n講者 1：左。")),
            .success((finishReason: "STOP", text: "[00:01 - 00:02]\n講者 1：右。")),
            .success((finishReason: "STOP", text: "[00:02 - 00:04]\n講者 1：第二段。"))
        ])
        MockAdaptiveCloudURLProtocol.handler = { request in
            try transport.handle(request: request)
        }
        addTeardownBlock { MockAdaptiveCloudURLProtocol.handler = nil }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(apiKey: "mock-key", modelID: "gemini-3.7-flash")
        )
        let silenceDetector = CloudSilenceDetectorSpy(
            result: [DetectedSilence(startSeconds: 1, endSeconds: 1.4)]
        )
        let engine = TranscriptionEngine(
            runtime: candidate,
            paths: paths,
            googleAIStudioBackend: backend,
            maximumASRSegmentDuration: 2.0,
            cloudAdaptiveMinimumChildDuration: 1.0,
            silenceDetectionService: silenceDetector
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
            googleAIStudioModelID: "gemini-3.7-flash",
            silenceAwareCloudSegmentation: false
        )
        let job = TranscriptionJob(
            id: UUID(),
            sourcePath: sourceURL.path,
            snapshot: snapshot
        )

        _ = try await engine.run(job: job) { _ in }

        XCTAssertEqual(silenceDetector.calls.count, 0)
        XCTAssertEqual(transport.recordedGenerateRequests.count, 4)
    }

    func testInitialSilenceScanIsReusedByAdaptiveChildren() async throws {
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

        let sourceURL = root.appendingPathComponent("reuse-silence.wav")
        try await makeSineAudioFixture(
            durationSeconds: 4.0,
            destinationURL: sourceURL,
            ffmpegURL: candidate.ffmpeg
        )

        let transport = MockAIStudioTransport(responses: [
            .success((finishReason: "MAX_TOKENS", text: "截斷")),
            .success((finishReason: "STOP", text: "[00:00 - 00:01]\n講者 1：左。")),
            .success((finishReason: "STOP", text: "[00:01 - 00:02]\n講者 1：右。")),
            .success((finishReason: "STOP", text: "[00:02 - 00:04]\n講者 1：第二段。"))
        ])
        MockAdaptiveCloudURLProtocol.handler = { request in
            try transport.handle(request: request)
        }
        addTeardownBlock { MockAdaptiveCloudURLProtocol.handler = nil }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockAdaptiveCloudURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let backend = GoogleAIStudioBackend(
            urlSession: session,
            configuration: .init(apiKey: "mock-key", modelID: "gemini-3.7-flash")
        )
        let silenceDetector = CloudSilenceDetectorSpy()
        let engine = TranscriptionEngine(
            runtime: candidate,
            paths: paths,
            googleAIStudioBackend: backend,
            maximumASRSegmentDuration: 2.0,
            cloudAdaptiveMinimumChildDuration: 1.0,
            silenceDetectionService: silenceDetector
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

        _ = try await engine.run(job: job) { _ in }

        XCTAssertEqual(silenceDetector.calls.count, 1)
        let initialScan = try XCTUnwrap(silenceDetector.calls.first)
        XCTAssertEqual(initialScan.start, 0, accuracy: 0.001)
        XCTAssertEqual(initialScan.duration, 4, accuracy: 0.001)
        XCTAssertEqual(transport.recordedGenerateRequests.count, 4)
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
