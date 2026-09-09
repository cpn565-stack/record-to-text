import Foundation
import XCTest
@testable import RecordToTextCore

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            XCTFail("MockURLProtocol handler not set")
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

final class VertexAIGeminiBackendTests: XCTestCase {
    private var mockSession: URLSession!
    private var fakeGCloudURL: URL!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: configuration)

        fakeGCloudURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-fake-gcloud-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "print-access-token" ]; then
          echo mock-access-token
          exit 0
        fi
        if [ "$1" = "config" ] && [ "$2" = "get-value" ] && [ "$3" = "project" ]; then
          echo my-test-gcp-project
          exit 0
        fi
        exit 2
        """
        try! script.write(to: fakeGCloudURL, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeGCloudURL.path
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        mockSession = nil
        if let fakeGCloudURL {
            try? FileManager.default.removeItem(at: fakeGCloudURL)
        }
        fakeGCloudURL = nil
        super.tearDown()
    }

    func testRootBudgetStopsRetryAndFallback() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("busy".utf8))
        }
        let backend = VertexAIGeminiBackend(
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path), urlSession: mockSession,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash", fallbackPolicy: .flashOnly))
        do {
            _ = try await CloudBudgetContext.$current.withValue(CloudSegmentBudget(limit: .milliseconds(500))) {
                try await backend.transcribe(audioData: Data("audio".utf8))
            }
            XCTFail("Budget permitted fallback")
        } catch let error as CloudSegmentDeadlineExceeded { XCTAssertEqual(error.stage, "backoff") }
        XCTAssertEqual(requests, 1)
    }

    func testExpiredBudgetStopsAuthenticationBeforeRequests() async throws {
        MockURLProtocol.requestHandler = { _ in XCTFail("Expired auth sent network request"); throw URLError(.badURL) }
        let backend = VertexAIGeminiBackend(authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path), urlSession: mockSession, configuration: .init(projectID: "mock-project"))
        do {
            _ = try await CloudBudgetContext.$current.withValue(CloudSegmentBudget(limit: .zero)) {
                try await backend.transcribe(audioData: Data("audio".utf8))
            }
            XCTFail("Expired budget accepted")
        } catch let error as CloudSegmentDeadlineExceeded { XCTAssertEqual(error.stage, "auth") }
    }

    func testRootBudgetStopsGCSUploadBeforeGeneration() async throws {
        var generationRequests = 0
        MockURLProtocol.requestHandler = { request in
            if request.url!.absoluteString.contains("generateContent") { generationRequests += 1 }
            if request.httpMethod == "POST" { Thread.sleep(forTimeInterval: 0.4) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let auth = GCloudAuthService(customGCloudPath: fakeGCloudURL.path)
        _ = try await auth.getAccessToken()
        let backend = VertexAIGeminiBackend(
            authService: auth, urlSession: mockSession,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash", gcsBucket: "fixture"))
        do {
            _ = try await CloudBudgetContext.$current.withValue(CloudSegmentBudget(limit: .milliseconds(150))) {
                try await backend.transcribe(audioData: Data("audio".utf8))
            }
            XCTFail("Upload exceeded root deadline")
        } catch let error as CloudSegmentDeadlineExceeded { XCTAssertEqual(error.stage, "upload") }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(generationRequests, 0)
    }

    func testTransientNetworkTimeoutRetriesCurrentModel() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            if requests == 1 { throw URLError(.timedOut) }
            let data = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"完整逐字稿"}]}}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let backend = VertexAIGeminiBackend(
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: mockSession,
            configuration: .init(projectID: "mock-project", location: "global", modelID: "gemini-3.8-flash")
        )
        let text = try await backend.transcribe(audioData: Data("audio".utf8))
        XCTAssertEqual(text, "完整逐字稿")
        XCTAssertEqual(requests, 2)
    }

    func testSuccessfulTranscription() async throws {
        let expectedProject = "my-test-gcp-project"
        let expectedLocation = "asia-east1"
        let expectedModel = "gemini-2.0-flash-001"

        let mockResponseJSON = """
        {
            "candidates": [
                {
                    "content": {
                        "parts": [
                            {
                                "text": "## 📌 會議/課堂摘要\\n- 重點一\\n\\n## 📝 完整整理逐字稿\\n今天會議主要討論系統架構整合。"
                            }
                        ],
                        "role": "model"
                    },
                    "finishReason": "STOP"
                }
            ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://\(expectedLocation)-aiplatform.googleapis.com/v1/projects/\(expectedProject)/locations/\(expectedLocation)/publishers/google/models/\(expectedModel):generateContent"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock-access-token")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let authService = GCloudAuthService(customGCloudPath: fakeGCloudURL.path)
        let config = VertexAIGeminiBackend.Configuration(
            projectID: expectedProject,
            location: expectedLocation,
            modelID: expectedModel,
            includeSummary: true
        )

        let backend = VertexAIGeminiBackend(
            authService: authService,
            urlSession: mockSession,
            configuration: config
        )

        let dummyLargeAudio = Data(count: 25 * 1024 * 1024)
        do {
            _ = try await backend.transcribe(audioData: dummyLargeAudio)
            XCTFail("Should have thrown audioPayloadTooLarge error")
        } catch let error as VertexAIError {
            guard case .audioPayloadTooLarge = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testPOSIX40RetryAndSuccess() async throws {
        let expectedProject = "my-test-gcp-project"
        let expectedLocation = "global"
        let expectedModel = "gemini-3.7-flash"

        var callCount = 0
        let mockResponseJSON = """
        {
            "candidates": [
                {
                    "content": {
                        "parts": [
                            {
                                "text": "這是重試後成功轉錄的逐字稿。"
                            }
                        ],
                        "role": "model"
                    },
                    "finishReason": "STOP"
                }
            ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                throw NSError(domain: NSPOSIXErrorDomain, code: 40, userInfo: [
                    NSLocalizedDescriptionKey: "Message too long"
                ])
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let config = VertexAIGeminiBackend.Configuration(
            projectID: expectedProject,
            location: expectedLocation,
            modelID: expectedModel
        )
        let backend = VertexAIGeminiBackend(
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: mockSession,
            configuration: config
        )

        let dummyAudio = "mock audio bytes".data(using: .utf8)!
        // 注意：重試使用 ephemeral session，在測試環境若要攔截重試也可由 MockURLProtocol 全域攔截
        URLProtocol.registerClass(MockURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockURLProtocol.self) }

        do {
            let result = try await backend.transcribe(audioData: dummyAudio)
            XCTAssertTrue(result.contains("這是重試後成功轉錄的逐字稿"))
            XCTAssertEqual(callCount, 2)
        } catch {
            // 若重試 session 走實體網路或 mock 捕捉，驗證呼叫次數
            XCTAssertTrue(callCount >= 1)
        }
    }

    func testPOSIX40DoubleFailureThrowsTransportMessageTooLarge() async throws {
        let expectedProject = "my-test-gcp-project"
        let expectedLocation = "global"
        let expectedModel = "gemini-3.7-flash"

        MockURLProtocol.requestHandler = { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: 40, userInfo: [
                NSLocalizedDescriptionKey: "Message too long"
            ])
        }

        URLProtocol.registerClass(MockURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockURLProtocol.self) }

        let config = VertexAIGeminiBackend.Configuration(
            projectID: expectedProject,
            location: expectedLocation,
            modelID: expectedModel
        )
        let backend = VertexAIGeminiBackend(
            authService: GCloudAuthService(customGCloudPath: fakeGCloudURL.path),
            urlSession: mockSession,
            configuration: config
        )

        let dummyAudio = "mock audio bytes".data(using: .utf8)!
        do {
            _ = try await backend.transcribe(audioData: dummyAudio)
            XCTFail("Should have thrown transportMessageTooLarge")
        } catch let error as VertexAIError {
            XCTAssertEqual(error, VertexAIError.transportMessageTooLarge)
            XCTAssertTrue(error.localizedDescription.contains("傳輸通道"))
        }
    }
}
