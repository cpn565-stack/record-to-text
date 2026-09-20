import XCTest
import CryptoKit
@testable import RecordToTextCore

private final class UploadRecoveryProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CloudUploadRecoveryTests: XCTestCase {
    private let audio = Data("synthetic fixture".utf8)
    private let success = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"完整逐字稿"}]}}]}"#.utf8)
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadRecoveryProtocol.self]
        return URLSession(configuration: config)
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func file(_ name: String, state: String = "ACTIVE") -> [String: Any] {
        ["name": name, "uri": "https://generativelanguage.googleapis.com/v1beta/" + name,
         "state": state, "sizeBytes": String(audio.count),
         "sha256Hash": Data(SHA256.hash(data: audio)).base64EncodedString()]
    }
    private func requestedName(_ request: URLRequest) throws -> String {
        let data: Data
        if let body = request.httpBody { data = body }
        else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var result = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            data = result
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((object["file"] as? [String: Any])?["name"] as? String)
    }

    func testFilesInitUploadAndPollRecoverWithoutInlineAndExclude120SecondOutage() async throws {
        let session = session(), clock = RecoveryClock()
        defer { session.invalidateAndCancel(); UploadRecoveryProtocol.handler = nil }
        var initializes = 0, uploads = 0, polls = 0, generates = 0
        let offlineUntil = RecoveryValue(0.0)
        var name = ""
        UploadRecoveryProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            if path == "/upload/v1beta/files" {
                initializes += 1
                if initializes == 1 { throw URLError(.networkConnectionLost) }
                name = try self.requestedName(request)
                return (200, ["X-Goog-Upload-URL": "https://fixture.invalid/upload"], Data())
            }
            if path == "/upload" {
                uploads += 1
                if uploads == 1 { throw URLError(.networkConnectionLost) }
                return (200, [:], try self.json(["file": self.file(name, state: "PROCESSING")]))
            }
            if path.contains(":generateContent") {
                generates += 1
                XCTAssertEqual(polls, 2)
                XCTAssertEqual(uploads, 2)
                return (200, [:], self.success)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 15)
            if uploads == 1 { return (404, [:], Data()) } // Upload was not accepted.
            polls += 1
            if polls == 1 {
                offlineUntil.value = clock.seconds + 120
                throw URLError(.networkConnectionLost)
            }
            return (200, [:], try self.json(self.file(name)))
        }
        let env = clock.environment { $0 < offlineUntil.value ? .unsatisfied : .satisfied }
        let backend = GoogleAIStudioBackend(networkEnvironment: env, urlSession: session, configuration: .init(apiKey: "fixture"))
        let text = try await backend.transcribe(audioData: audio)
        XCTAssertEqual(text, "完整逐字稿")
        XCTAssertEqual(initializes, 3)
        XCTAssertEqual(generates, 1)
        XCTAssertGreaterThanOrEqual(clock.seconds, 153)
        XCTAssertLessThan(clock.seconds, 160)
    }

    func testLostFilesUploadResponseUsesNamedMetadataWithoutUploadingAgain() async throws {
        let session = session(), clock = RecoveryClock()
        defer { session.invalidateAndCancel(); UploadRecoveryProtocol.handler = nil }
        var name = "", uploads = 0, checks = 0
        UploadRecoveryProtocol.handler = { request in
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            if request.url!.path == "/upload/v1beta/files" {
                name = try self.requestedName(request)
                return (200, ["X-Goog-Upload-URL": "https://fixture.invalid/upload"], Data())
            }
            if request.url!.path == "/upload" { uploads += 1; throw URLError(.networkConnectionLost) }
            if request.url!.path.contains(":generateContent") { return (200, [:], self.success) }
            checks += 1
            XCTAssertEqual(request.url!.path, "/v1beta/" + name)
            return (200, [:], try self.json(self.file(name)))
        }
        let backend = GoogleAIStudioBackend(networkEnvironment: clock.environment(), urlSession: session,
            configuration: .init(apiKey: "fixture"))
        _ = try await backend.transcribe(audioData: audio)
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(checks, 1)
    }

    func testFilesSessionRecreationCannotMultiplyInitializationQuota() async throws {
        let session = session(), clock = RecoveryClock()
        defer { session.invalidateAndCancel(); UploadRecoveryProtocol.handler = nil }
        var initializes = 0, uploads = 0, generates = 0
        UploadRecoveryProtocol.handler = { request in
            if request.url!.path == "/upload/v1beta/files" {
                initializes += 1
                if initializes < 4 { throw URLError(.networkConnectionLost) }
                return (200, ["X-Goog-Upload-URL": "https://fixture.invalid/upload"], Data())
            }
            if request.url!.path == "/upload" { uploads += 1; throw URLError(.networkConnectionLost) }
            if request.url!.path.contains(":generateContent") { generates += 1; return (200, [:], self.success) }
            return (404, [:], Data())
        }
        let backend = GoogleAIStudioBackend(networkEnvironment: clock.environment(), urlSession: session,
            configuration: .init(apiKey: "fixture"))
        do { _ = try await backend.transcribe(audioData: audio); XCTFail("Exceeded initialization quota") }
        catch let error as CloudNetworkRecoveryExhausted {
            XCTAssertEqual(error.recovery.stopReason, .attemptsExhausted)
            XCTAssertEqual(error.recovery.lastFailure?.stage, .upload)
        }
        XCTAssertEqual(initializes, 4)
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(generates, 0)
    }

    func testExpiredFileRebuildPreservesFourSendQuota() async throws {
        for finalSucceeds in [true, false] {
            let session = session(), clock = RecoveryClock()
            defer { session.invalidateAndCancel(); UploadRecoveryProtocol.handler = nil }
            var name = "", uploads = 0, sends = 0
            UploadRecoveryProtocol.handler = { request in
                if request.httpMethod == "DELETE" { return (204, [:], Data()) }
                if request.url!.path == "/upload/v1beta/files" {
                    name = try self.requestedName(request)
                    return (200, ["X-Goog-Upload-URL": "https://fixture.invalid/upload"], Data())
                }
                if request.url!.path == "/upload" {
                    uploads += 1
                    return (200, [:], try self.json(["file": self.file(name)]))
                }
                if request.url!.path.contains(":generateContent") {
                    sends += 1
                    if sends == 3 { return (404, [:], Data()) }
                    if sends == 4 && finalSucceeds { return (200, [:], self.success) }
                    throw URLError(.networkConnectionLost)
                }
                return (404, [:], Data())
            }
            let backend = GoogleAIStudioBackend(networkEnvironment: clock.environment(), urlSession: session,
                configuration: .init(apiKey: "fixture"))
            do {
                let result = try await backend.transcribeDetailed(audioData: audio)
                XCTAssertTrue(finalSucceeds)
                XCTAssertEqual(result.metadata.retryCount, 3)
            } catch let error as CloudNetworkRecoveryExhausted {
                XCTAssertFalse(finalSucceeds)
                XCTAssertEqual(error.recovery.stopReason, .attemptsExhausted)
            }
            XCTAssertEqual(sends, 4)
            XCTAssertEqual(uploads, 2)
        }
    }

    func testGCSUploadRetriesOnlyUploadOrConfirmsLostResponse() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gcloud = root.appendingPathComponent("gcloud")
        try "#!/bin/sh\necho fixture-token\n".write(to: gcloud, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gcloud.path)
        for acceptedAt in [1, 0, 4] {
            let session = session(), clock = RecoveryClock()
            defer { session.invalidateAndCancel(); UploadRecoveryProtocol.handler = nil }
            var uploads = 0, checks = 0, generates = 0
            var name = ""
            UploadRecoveryProtocol.handler = { request in
                if request.httpMethod == "DELETE" { return (204, [:], Data()) }
                if request.url!.path.contains(":generateContent") {
                    generates += 1
                    XCTAssertGreaterThan(checks, 0)
                    return (200, [:], self.success)
                }
                if request.url!.path.hasPrefix("/upload/") {
                    uploads += 1
                    name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "name" }!.value!
                    if uploads == 1 || acceptedAt == 4 { throw URLError(.networkConnectionLost) }
                    return (200, [:], Data("{}".utf8))
                }
                checks += 1
                return acceptedAt > 0 && uploads >= acceptedAt ? (200, [:], try self.json(["name": name, "size": String(self.audio.count),
                    "md5Hash": Data(Insecure.MD5.hash(data: self.audio)).base64EncodedString()])) : (404, [:], Data())
            }
            let backend = VertexAIGeminiBackend(networkEnvironment: clock.environment(),
                authService: GCloudAuthService(customGCloudPath: gcloud.path), urlSession: session,
                configuration: .init(projectID: "fixture", gcsBucket: "fixture-bucket"))
            _ = try await backend.transcribe(audioData: audio)
            XCTAssertEqual(uploads, acceptedAt == 0 ? 2 : acceptedAt)
            XCTAssertEqual(checks, max(1, acceptedAt))
            XCTAssertEqual(generates, 1)
        }
    }
}

final class RecoveryValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
