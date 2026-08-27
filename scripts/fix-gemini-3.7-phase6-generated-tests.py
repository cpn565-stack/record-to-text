#!/usr/bin/env python3
from pathlib import Path

path = Path("Tests/RecordToTextCoreTests/GCloudAuthServiceTests.swift")
text = path.read_text(encoding="utf-8")

replacements = [
    (
        '''        XCTAssertEqual(try await auth.getAccessToken(), "token-1")
        XCTAssertEqual(try await auth.getAccessToken(), "token-1")
''',
        '''        let firstToken = try await auth.getAccessToken()
        let cachedToken = try await auth.getAccessToken()
        XCTAssertEqual(firstToken, "token-1")
        XCTAssertEqual(cachedToken, "token-1")
''',
        "cached token assertions",
    ),
    (
        '''        XCTAssertEqual(
            try await auth.getAccessToken(forceRefresh: true),
            "token-2"
        )
''',
        '''        let refreshedToken = try await auth.getAccessToken(
            forceRefresh: true
        )
        XCTAssertEqual(refreshedToken, "token-2")
''',
        "force refresh assertion",
    ),
    (
        '''        XCTAssertEqual(try await auth.getAccessToken(), "token-1")
        auth.invalidateToken()
        XCTAssertEqual(try await auth.getAccessToken(), "token-2")
''',
        '''        let initialToken = try await auth.getAccessToken()
        XCTAssertEqual(initialToken, "token-1")
        auth.invalidateToken()
        let tokenAfterInvalidation = try await auth.getAccessToken()
        XCTAssertEqual(tokenAfterInvalidation, "token-2")
''',
        "invalidate token assertions",
    ),
    (
        '''        XCTAssertEqual(
            try await auth.getDefaultProjectID(),
            "project-from-config"
        )
''',
        '''        let projectID = try await auth.getDefaultProjectID()
        XCTAssertEqual(projectID, "project-from-config")
''',
        "project assertion",
    ),
]

for old, new, label in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 occurrence, found {count}")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
print("Converted gcloud async XCTest assertions to local results")
