import Foundation
import XCTest
@testable import RecordToTextCore

final class GCloudAuthServiceTests: XCTestCase {
    func testMissingGCloudExecutableThrows() async {
        let auth = GCloudAuthService(
            customGCloudPath: "/invalid/path/to/nonexistent_gcloud"
        )
        XCTAssertNil(auth.resolveGCloudURL())

        do {
            _ = try await auth.getAccessToken()
            XCTFail("Should throw gcloudNotFound")
        } catch let error as GCloudAuthError {
            XCTAssertEqual(error, .gcloudNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await auth.getDefaultProjectID()
            XCTFail("Should throw gcloudNotFound")
        } catch let error as GCloudAuthError {
            XCTAssertEqual(error, .gcloudNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTokenIsCachedAndForceRefreshRunsGCloudAgain() async throws {
        let fixture = try makeScript(
            body: """
            counter="$1"
            shift
            if [ "$1" = "auth" ] && [ "$2" = "print-access-token" ]; then
              value=0
              if [ -f "$counter" ]; then value=$(cat "$counter"); fi
              value=$((value + 1))
              echo "$value" > "$counter"
              echo "token-$value"
              exit 0
            fi
            exit 9
            """,
            wrapperArguments: { counter in [counter.path] }
        )
        let auth = GCloudAuthService(customGCloudPath: fixture.executable.path)

        let firstToken = try await auth.getAccessToken()
        let cachedToken = try await auth.getAccessToken()
        XCTAssertEqual(firstToken, "token-1")
        XCTAssertEqual(cachedToken, "token-1")
        XCTAssertEqual(
            try String(contentsOf: fixture.counter, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "1"
        )

        let refreshedToken = try await auth.getAccessToken(
            forceRefresh: true
        )
        XCTAssertEqual(refreshedToken, "token-2")
        XCTAssertEqual(
            try String(contentsOf: fixture.counter, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "2"
        )
    }

    func testInvalidateTokenForcesNextFetch() async throws {
        let fixture = try makeScript(
            body: """
            counter="$1"
            shift
            if [ "$1" = "auth" ] && [ "$2" = "print-access-token" ]; then
              value=0
              if [ -f "$counter" ]; then value=$(cat "$counter"); fi
              value=$((value + 1))
              echo "$value" > "$counter"
              echo "token-$value"
              exit 0
            fi
            exit 9
            """,
            wrapperArguments: { counter in [counter.path] }
        )
        let auth = GCloudAuthService(customGCloudPath: fixture.executable.path)
        let initialToken = try await auth.getAccessToken()
        XCTAssertEqual(initialToken, "token-1")
        auth.invalidateToken()
        let tokenAfterInvalidation = try await auth.getAccessToken()
        XCTAssertEqual(tokenAfterInvalidation, "token-2")
    }

    func testProjectIDIsTrimmedAndParsed() async throws {
        let fixture = try makeScript(
            body: """
            if [ "$1" = "config" ] && [ "$2" = "get-value" ] && [ "$3" = "project" ]; then
              printf '  project-from-config  \\n'
              exit 0
            fi
            exit 9
            """
        )
        let auth = GCloudAuthService(customGCloudPath: fixture.executable.path)
        let projectID = try await auth.getDefaultProjectID()
        XCTAssertEqual(projectID, "project-from-config")
    }

    func testUnsetProjectAndEmptyTokenProduceSpecificErrors() async throws {
        let emptyToken = try makeScript(
            body: """
            if [ "$1" = "auth" ] && [ "$2" = "print-access-token" ]; then
              printf '\\n'
              exit 0
            fi
            exit 9
            """
        )
        let emptyAuth = GCloudAuthService(
            customGCloudPath: emptyToken.executable.path
        )
        do {
            _ = try await emptyAuth.getAccessToken()
            XCTFail("Expected tokenEmpty")
        } catch let error as GCloudAuthError {
            XCTAssertEqual(error, .tokenEmpty)
        }

        let unsetProject = try makeScript(
            body: """
            if [ "$1" = "config" ] && [ "$2" = "get-value" ] && [ "$3" = "project" ]; then
              echo '(unset)'
              exit 0
            fi
            exit 9
            """
        )
        let projectAuth = GCloudAuthService(
            customGCloudPath: unsetProject.executable.path
        )
        do {
            _ = try await projectAuth.getDefaultProjectID()
            XCTFail("Expected projectNotFound")
        } catch let error as GCloudAuthError {
            XCTAssertEqual(error, .projectNotFound)
        }
    }

    func testNonZeroExitPreservesStatusAndMessage() async throws {
        let fixture = try makeScript(
            body: """
            echo 'login expired' >&2
            exit 17
            """
        )
        let auth = GCloudAuthService(customGCloudPath: fixture.executable.path)
        do {
            _ = try await auth.getAccessToken()
            XCTFail("Expected command failure")
        } catch let error as GCloudAuthError {
            guard case let .commandFailed(status, message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 17)
            XCTAssertTrue(message.contains("login expired"))
        }
    }

    private struct ScriptFixture {
        let root: URL
        let executable: URL
        let counter: URL
    }

    private func makeScript(
        body: String,
        wrapperArguments: ((URL) -> [String])? = nil
    ) throws -> ScriptFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "record-to-text-gcloud-test-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let implementation = root.appendingPathComponent("implementation.sh")
        try "#!/bin/sh\n\(body)\n".write(
            to: implementation,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: implementation.path
        )

        let counter = root.appendingPathComponent("counter.txt")
        let executable = root.appendingPathComponent("gcloud")
        let prefix = (wrapperArguments?(counter) ?? [])
            .map(shellQuote)
            .joined(separator: " ")
        let invocation = prefix.isEmpty
            ? "exec \(shellQuote(implementation.path)) \"$@\""
            : "exec \(shellQuote(implementation.path)) \(prefix) \"$@\""
        try "#!/bin/sh\n\(invocation)\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return ScriptFixture(
            root: root,
            executable: executable,
            counter: counter
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
