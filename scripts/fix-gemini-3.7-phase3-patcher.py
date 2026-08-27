#!/usr/bin/env python3
from pathlib import Path

path = Path("scripts/apply-gemini-3.7-phase3-pipeline-ui.py")
text = path.read_text(encoding="utf-8")

old_progress = "progress_new = '''    @ViewBuilder\n"
new_progress = "progress_new = r'''    @ViewBuilder\n"
if text.count(old_progress) != 1:
    raise SystemExit(
        f"progress string marker: expected 1, found {text.count(old_progress)}"
    )
text = text.replace(old_progress, new_progress, 1)

old_block = '''tests = replace_once(
    tests,
    "            bundledFFprobeURL: bundled.ffprobe,\\n            includeSystemAudioTools: false\\n        )\\n",
    "            bundledFFprobeURL: bundled.ffprobe,\\n            includeSystemAudioTools: false,\\n            developerRuntimeDiscovery: cloudDiscovery\\n        )\\n",
    "first cloud resolve discovery",
)
'''
new_block = '''first_resolve_old = (
    "            bundledFFprobeURL: bundled.ffprobe,\\n"
    "            includeSystemAudioTools: false\\n"
    "        )\\n"
)
first_resolve_new = (
    "            bundledFFprobeURL: bundled.ffprobe,\\n"
    "            includeSystemAudioTools: false,\\n"
    "            developerRuntimeDiscovery: cloudDiscovery\\n"
    "        )\\n"
)
if first_resolve_old not in tests:
    raise RuntimeError("first cloud resolve discovery marker missing")
tests = tests.replace(first_resolve_old, first_resolve_new, 1)
'''
if text.count(old_block) != 1:
    raise SystemExit(
        f"first resolve replacement block: expected 1, found {text.count(old_block)}"
    )
text = text.replace(old_block, new_block, 1)

path.write_text(text, encoding="utf-8")
print("Scoped phase 3 patcher replacements")
