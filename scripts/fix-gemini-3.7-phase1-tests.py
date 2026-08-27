#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one occurrence, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


replace_once(
    Path("Tests/RecordToTextCoreTests/CloudReliabilityTests.swift"),
    '''        XCTAssertEqual(
            try await backend.transcribe(audioData: Data("audio".utf8)),
            "忠實逐字稿"
        )
''',
    '''        let transcript = try await backend.transcribe(
            audioData: Data("audio".utf8)
        )
        XCTAssertEqual(transcript, "忠實逐字稿")
''',
    "async XCTest assertion",
)

replace_once(
    Path("Tests/RecordToTextCoreTests/AppCredentialMigrationTests.swift"),
    '''        XCTAssertEqual(viewModel.alert?.title, "舊版 API Key 尚未遷移")
''',
    '''        XCTAssertEqual(
            viewModel.googleAIStudioCredentialStorageState,
            .memoryOnly
        )
        XCTAssertTrue(
            viewModel.alert?.message.contains("Keychain") == true
        )
''',
    "credential migration alert assertion",
)

vertex = Path("Tests/RecordToTextCoreTests/VertexAIGeminiBackendTests.swift")
text = vertex.read_text(encoding="utf-8")
text = text.replace(
    '''final class VertexAIGeminiBackendTests: XCTestCase {
    private var mockSession: URLSession!

    override func setUp() {
''',
    '''final class VertexAIGeminiBackendTests: XCTestCase {
    private var mockSession: URLSession!
    private var fakeGCloudURL: URL!

    override func setUp() {
''',
    1,
)
text = text.replace(
    '''        mockSession = URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        mockSession = nil
        super.tearDown()
    }
''',
    '''        mockSession = URLSession(configuration: configuration)

        fakeGCloudURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-to-text-fake-gcloud-\\(UUID().uuidString)")
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
''',
    1,
)
count = text.count('GCloudAuthService(customGCloudPath: "/nonexistent/gcloud")')
if count != 3:
    raise SystemExit(f"fake gcloud replacement: expected 3, found {count}")
text = text.replace(
    'GCloudAuthService(customGCloudPath: "/nonexistent/gcloud")',
    'GCloudAuthService(customGCloudPath: fakeGCloudURL.path)',
)
vertex.write_text(text, encoding="utf-8")

print("Repaired XCTest compatibility and isolated gcloud fixtures")
