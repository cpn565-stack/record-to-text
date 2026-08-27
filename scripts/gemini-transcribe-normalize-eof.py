#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for relative in [
    "docs/GEMINI_3_5_TRANSCRIBE_IMPLEMENTATION.md",
    "docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md",
]:
    path = root / relative
    path.write_text(path.read_text(encoding="utf-8").rstrip() + "\n", encoding="utf-8")
