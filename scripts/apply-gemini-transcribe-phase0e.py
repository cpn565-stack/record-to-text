#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "Tests/RecordToTextCoreTests/CloudReliabilityTests.swift"
text = path.read_text()
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
if old in text:
    path.write_text(text.replace(old, new, 1))
    print("updated async XCTest assertion for current Swift toolchain")
elif new in text:
    print("async XCTest assertion already updated")
else:
    raise RuntimeError("could not locate async XCTest assertion")
