#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}")
    path.write_text(text.replace(old, new, 1))


models_test = ROOT / "Tests/RecordToTextCoreTests/ModelsDefaultsTests.swift"
replace_once(
    models_test,
    "        XCTAssertEqual(settings.schemaVersion, 1)\n",
    "        XCTAssertEqual(settings.schemaVersion, 2)\n"
)

migration_test = ROOT / "Tests/RecordToTextCoreTests/AppCredentialMigrationTests.swift"
replace_once(
    migration_test,
    '        XCTAssertEqual(viewModel.alert?.title, "舊版 API Key 尚未遷移")\n',
    '        XCTAssertEqual(viewModel.alert?.title, "部分資料未能載入")\n'
)

vertex_test = ROOT / "Tests/RecordToTextCoreTests/VertexAIGeminiBackendTests.swift"
text = vertex_test.read_text()
anchor = '''final class VertexAIGeminiBackendTests: XCTestCase {
    private var mockSession: URLSession!

    override func setUp() {
'''
replacement = '''final class VertexAIGeminiBackendTests: XCTestCase {
    private var mockSession: URLSession!
    private var fakeGCloudDirectory: URL!
    private var fakeGCloudURL: URL!

    override func setUp() {
'''
if anchor not in text:
    raise RuntimeError("Vertex test class anchor not found")
text = text.replace(anchor, replacement, 1)

anchor = '''        mockSession = URLSession(configuration: configuration)
    }

    override func tearDown() {
'''
replacement = '''        mockSession = URLSession(configuration: configuration)

        fakeGCloudDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "record-to-text-fake-gcloud-\\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: fakeGCloudDirectory,
            withIntermediateDirectories: true
        )
        fakeGCloudURL = fakeGCloudDirectory.appendingPathComponent("gcloud")
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf 'mock-access-token\\n'
          exit 0
        fi
        if [ "$1" = "config" ]; then
          printf 'my-test-gcp-project\\n'
          exit 0
        fi
        printf 'unsupported fake gcloud command\\n' >&2
        exit 2
        """
        try! script.write(to: fakeGCloudURL, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGCloudURL.path
        )
    }

    override func tearDown() {
'''
if anchor not in text:
    raise RuntimeError("Vertex test setUp anchor not found")
text = text.replace(anchor, replacement, 1)

anchor = '''        MockURLProtocol.requestHandler = nil
        mockSession = nil
        super.tearDown()
'''
replacement = '''        MockURLProtocol.requestHandler = nil
        mockSession = nil
        if let fakeGCloudDirectory {
            try? FileManager.default.removeItem(at: fakeGCloudDirectory)
        }
        fakeGCloudDirectory = nil
        fakeGCloudURL = nil
        super.tearDown()
'''
if anchor not in text:
    raise RuntimeError("Vertex test tearDown anchor not found")
text = text.replace(anchor, replacement, 1)

count = text.count('GCloudAuthService(customGCloudPath: "/nonexistent/gcloud")')
if count != 3:
    raise RuntimeError(f"expected 3 fake gcloud replacements, found {count}")
text = text.replace(
    'GCloudAuthService(customGCloudPath: "/nonexistent/gcloud")',
    'GCloudAuthService(customGCloudPath: fakeGCloudURL.path)'
)
vertex_test.write_text(text)

print("updated schema, migration, and deterministic fake-gcloud tests")
