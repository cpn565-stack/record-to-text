import Foundation
import XCTest
@testable import RecordToTextCore

/// All cloud endpoints are intercepted. The audio is a locally generated sine
/// wave; this test never uploads user recordings or contacts Google.
private final class TranscribeRecoveryURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status,
                httpVersion: nil, headerFields: headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class TranscribeRecoveryTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var interactionCount = 0
    private var created: [String] = []
    private var deleted: [String] = []

    var sends: Int { lock.withLock { interactionCount } }
    var createdFiles: [String] { lock.withLock { created } }
    var deletedFiles: [String] { lock.withLock { deleted } }

    func handle(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let url = try XCTUnwrap(request.url)
        let method = request.httpMethod ?? "GET"
        let path = url.path
        if path == "/upload/v1beta/files", method == "POST" {
            return (200, ["X-Goog-Upload-URL": "https://upload.example.test/\(UUID().uuidString)"], Data("{}".utf8))
        }
        if url.host == "upload.example.test", method == "POST" {
            let name = "files/\(UUID().uuidString.lowercased())"
            lock.withLock { created.append(name) }
            let object: [String: Any] = ["file": ["name": name,
                "uri": "https://files.example.test/\(name)", "state": "ACTIVE"]]
            return (200, [:], try JSONSerialization.data(withJSONObject: object))
        }
        if path.hasPrefix("/v1beta/files/"), method == "GET" {
            return (200, [:], Data(#"{"state":"ACTIVE"}"#.utf8))
        }
        if path.hasPrefix("/v1beta/files/"), method == "DELETE" {
            lock.withLock { deleted.append(String(path.dropFirst("/v1beta/".count))) }
            return (204, [:], Data())
        }
        if path == "/v1beta/interactions", method == "POST" {
            let number = lock.withLock { interactionCount += 1; return interactionCount }
            if number == 2 {
                // A permanent error means no automatic retry; the preserved
                // checkpoint must be used by an explicit continuation.
                return (400, [:], Data(#"{"error":{"message":"synthetic permanent failure"}}"#.utf8))
            }
            guard number == 1 || number == 3 else { throw URLError(.badServerResponse) }
            let text = number == 1 ? "第一段合成測試內容。" : "第二段合成測試內容。"
            let payload: [String: Any] = ["status": "completed", "steps": [[
                "type": "model_output", "content": [["type": "text", "text": text]]
            ]]]
            return (200, [:], try JSONSerialization.data(withJSONObject: payload))
        }
        throw URLError(.badURL)
    }
}

final class TranscribePipelineRecoveryTests: XCTestCase {
    func testLongTranscribeResumesOnlyUnfinishedFourteenMinuteSegment() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root.appendingPathComponent("Support"))
        try paths.createDirectories()
        let runtime = RuntimeEnvironment.candidate(paths: paths,
            settings: AppSettings.defaultValue(developerMode: true), bundledHelperURL: nil)
        for executable in [runtime.ffmpeg, runtime.ffprobe, runtime.opencc] {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw XCTSkip("Required local audio tools are unavailable")
            }
        }
        let source = root.appendingPathComponent("synthetic.wav")
        _ = try await ProcessRunner().run(executableURL: runtime.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=16000", "-t", "842", "-c:a", "pcm_s16le", source.path
        ])
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [TranscribeRecoveryURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let transport = TranscribeRecoveryTransport()
        TranscribeRecoveryURLProtocol.handler = { try transport.handle($0) }
        defer { session.invalidateAndCancel(); TranscribeRecoveryURLProtocol.handler = nil }
        let backend = GoogleAIStudioBackend(urlSession: session,
            configuration: .init(apiKey: "synthetic-key", modelID: "gemini-3.5-transcribe"))
        let engine = TranscriptionEngine(runtime: runtime, paths: paths, googleAIStudioBackend: backend)
        let snapshot = JobSnapshot(modelID: "fixture", glossaryID: nil, glossaryName: nil,
            // Transcribe never receives this prompt. The first response matches
            // it exactly and must not be incorrectly rejected as prompt echo.
            terms: [], prompt: "第一段合成測試內容。", outputLocationMode: .fixedDirectory,
            outputDirectory: root.path, keepRawTranscript: false, backendType: .googleAIStudio,
            googleAIStudioAPIKey: "synthetic-key", googleAIStudioModelID: "gemini-3.5-transcribe",
            silenceAwareCloudSegmentation: false)
        var failed = TranscriptionJob(sourcePath: source.path, snapshot: snapshot)
        var recovery: URL?
        do {
            _ = try await engine.run(job: failed) { _ in }
            XCTFail("A failed second segment must not publish a full transcript")
        } catch let error as PipelineExecutionError {
            let segment = try XCTUnwrap(error.underlying as? CloudSegmentExecutionError)
            XCTAssertEqual(segment.segmentIndex, 2)
            failed.stage = .failed
            failed.failure = .init(stage: .transcribing, userMessage: "synthetic failure",
                technicalDetails: "synthetic failure", recoverable: true,
                recoveryDirectory: error.recoveryDirectory?.path)
            recovery = error.recoveryDirectory
        }
        XCTAssertEqual(transport.sends, 2)
        let directory = try XCTUnwrap(recovery)
        let manifestURL = directory.appendingPathComponent(RecoveryScanner.segmentManifestFileName)
        let manifest = try JSONDecoder().decode(AudioSegmentManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.maximumSegmentDurationSeconds, 840, accuracy: 0.01)
        XCTAssertEqual(manifest.segments.count, 2)
        XCTAssertEqual(manifest.segments.map(\.status), [.completed, .failed])
        XCTAssertEqual(manifest.segments[0].startSeconds, 0, accuracy: 0.01)
        XCTAssertEqual(manifest.segments[0].endSeconds, 840, accuracy: 0.01)
        XCTAssertEqual(manifest.segments[1].startSeconds, 840, accuracy: 0.01)
        XCTAssertEqual(manifest.segments[1].endSeconds, 842, accuracy: 0.1)
        let completed = URL(fileURLWithPath: manifest.segments[0].outputPath)
        let originalFirstSegment = try Data(contentsOf: completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.segments[1].outputPath))

        var resumed = try CloudJobContinuation.make(from: failed, paths: paths)
        XCTAssertEqual(resumed.resumeFromRecoveryDirectory, directory.path)
        resumed.snapshot = resumed.snapshot.withGoogleAIStudioAPIKey("synthetic-key")
        let result = try await engine.run(job: resumed, persistCompletion: { _ in false }) { _ in }
        defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text").appendingPathComponent(resumed.id.uuidString)) }
        XCTAssertEqual(transport.sends, 3, "Only the failed segment should be sent again")
        XCTAssertEqual(transport.createdFiles.count, 3)
        XCTAssertEqual(Set(transport.createdFiles), Set(transport.deletedFiles))
        XCTAssertEqual(try Data(contentsOf: completed), originalFirstSegment)
        let diagnostics = try XCTUnwrap(result.cloudDiagnostics)
        XCTAssertEqual(diagnostics.segments.map(\.reusedFromCheckpoint), [true, false])
        XCTAssertFalse(result.containsSkippedAudio)
        let finalText = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertEqual(finalText.components(separatedBy: "第一段合成測試內容").count, 2)
        XCTAssertEqual(finalText.components(separatedBy: "第二段合成測試內容").count, 2)
    }
}
