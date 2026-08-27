#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
phase1 = ROOT / "scripts/apply-gemini-transcribe-phase1.py"
text = phase1.read_text()
needle = "    /// Returns a copy suitable for transient execution.\n"
replacement = "    /// Returns a copy suitable for transient execution. The credential remains\n"
count = text.count(needle)
if count == 2:
    phase1.write_text(text.replace(needle, replacement))
    print("matched complete JobSnapshot transient-execution comment")
elif replacement in text:
    print("JobSnapshot transient-execution comment already corrected")
else:
    raise RuntimeError(f"expected two transient-execution anchors, found {count}")
