#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "Tests/RecordToTextCoreTests/GeminiTranscribeContractTests.swift"
text = path.read_text()
old = '''        XCTAssertEqual(result.words[0].speaker, "speaker-1")
        XCTAssertEqual(result.words[0].startSeconds, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result.speakerTurns.count, 1)
'''
new = '''        XCTAssertEqual(result.words[0].speaker, "speaker-1")
        let firstStart = try XCTUnwrap(result.words[0].startSeconds)
        XCTAssertEqual(firstStart, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result.speakerTurns.count, 1)
'''
if old in text:
    path.write_text(text.replace(old, new, 1))
    print("unwrapped optional interaction timestamp assertion")
elif new in text:
    print("interaction timestamp assertion already unwrapped")
else:
    raise RuntimeError("could not locate interaction timestamp assertion")
