#!/usr/bin/env python3
from pathlib import Path

paths = [
    Path("Sources/RecordToTextCore/GoogleAIStudioBackend.swift"),
    Path("Sources/RecordToTextCore/VertexAIGeminiBackend.swift"),
]

for path in paths:
    text = path.read_text(encoding="utf-8")
    bad = r'\"%.1f\"'
    count = text.count(bad)
    if count != 2:
        raise SystemExit(
            f"{path}: expected two escaped Swift format strings, found {count}"
        )
    path.write_text(text.replace(bad, '"%.1f"'), encoding="utf-8")

print("Normalized generated Swift format-string quotes")
