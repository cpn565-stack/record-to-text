#!/usr/bin/env python3
from pathlib import Path

path = Path("Tests/RecordToTextCoreTests/CloudReliabilityTests.swift")
text = path.read_text(encoding="utf-8")
old = '''        XCTAssertEqual(
            try await backend.transcribe(audioData: Data("audio".utf8)),
            "忠實逐字稿"
        )
'''
new = '''        let transcript = try await backend.transcribe(
            audioData: Data("audio".utf8)
        )
        XCTAssertEqual(transcript, "忠實逐字稿")
'''
if text.count(old) != 1:
    raise SystemExit(f"expected one async XCTAssertEqual occurrence, found {text.count(old)}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
print("Repaired async XCTest assertion")
