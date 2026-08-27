#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
phase1 = ROOT / "scripts/apply-gemini-transcribe-phase1.py"
text = phase1.read_text()
old = '''    replace_once(models, "        schemaVersion: Int = 1,\\n", "        schemaVersion: Int = 2,\\n")
'''
new = '''    replace_once(
        models,
        """    public init(
        schemaVersion: Int = 1,
        defaultOutputDirectory: String,
""",
        """    public init(
        schemaVersion: Int = 2,
        defaultOutputDirectory: String,
"""
    )
'''
if old in text:
    phase1.write_text(text.replace(old, new, 1))
    print("narrowed AppSettings schema migration anchor")
elif "schemaVersion: Int = 2" in text:
    print("phase 1 schema migration anchor already corrected")
else:
    raise RuntimeError("could not find phase 1 schema migration anchor")
