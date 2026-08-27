#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
phase1 = ROOT / "scripts/apply-gemini-transcribe-phase1.py"
text = phase1.read_text()
old = '''        \'\'\'        // Legacy runtime-selection keys are intentionally ignored.
\'\'\',
'''
new = '''        \'\'\'        // Legacy runtime-selection keys are intentionally ignored. Runtime
\'\'\',
'''
old_output = '''        // Legacy runtime-selection keys are intentionally ignored.
\'\'\'
'''
new_output = '''        // Legacy runtime-selection keys are intentionally ignored. Runtime
\'\'\'
'''
changed = False
if old in text:
    text = text.replace(old, new, 1)
    changed = True
if old_output in text:
    text = text.replace(old_output, new_output, 1)
    changed = True
if changed:
    phase1.write_text(text)
    print("matched full JobSnapshot legacy-comment line")
elif "ignored. Runtime" in text:
    print("full JobSnapshot legacy-comment line already matched")
else:
    raise RuntimeError("could not update JobSnapshot legacy-comment line")
