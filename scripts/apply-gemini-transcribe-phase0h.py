#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
phase6 = ROOT / "scripts/apply-gemini-transcribe-phase6.py"
text = phase6.read_text()
old = "    '更新日期：2026-08-27  '\n"
new = "    '更新日期：2026-08-27'\n"
if old in text:
    phase6.write_text(text.replace(old, new, 1))
    print("removed trailing whitespace from NEXT_STEPS migration")
elif new in text:
    print("NEXT_STEPS migration already has no trailing whitespace")
else:
    raise RuntimeError("could not locate NEXT_STEPS replacement value")
