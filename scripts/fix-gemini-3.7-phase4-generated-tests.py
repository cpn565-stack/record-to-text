#!/usr/bin/env python3
from pathlib import Path

path = Path("Tests/RecordToTextCoreTests/SilenceAwareSegmentationTests.swift")
text = path.read_text(encoding="utf-8")
old = '''        XCTAssertEqual(plan.segments.first?.startSeconds, 0)
        XCTAssertEqual(plan.segments.last?.endSeconds, 4_000, accuracy: 0.001)
'''
new = '''        XCTAssertEqual(plan.segments.first?.startSeconds, 0)
        let finalSegment = try XCTUnwrap(plan.segments.last)
        XCTAssertEqual(finalSegment.endSeconds, 4_000, accuracy: 0.001)
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one optional final-segment assertion, found {count}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
print("Unwrapped final silence-aware segment for accuracy assertion")
