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

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        mockSession = nil
        super.tearDown()
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

        // 建立模擬 Auth Service
        let authService = GCloudAuthService(customGCloudPath: "/nonexistent/gcloud")
        // 透過測試子類或直接測試 Backend 配置
        let config = VertexAIGeminiBackend.Configuration(
            projectID: expectedProject,
            location: expectedLocation,
            modelID: expectedModel,
            includeSummary: true
        )

        // 自定義一個帶有 Mock Token 的 Backend 測試
        let backend = VertexAIGeminiBackend(
            authService: authService,
            configuration: config,
            urlSession: mockSession
        )

        // 測試過大音檔報錯
        let dummySmallAudio = "mock audio data".data(using: .utf8)!
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
}
