#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
phase0f = ROOT / "scripts/apply-gemini-transcribe-phase0f.py"
text = phase0f.read_text()
marker = "phase 0f already applied"
if marker in text:
    print("phase 0f idempotency guard already installed")
    raise SystemExit(0)

needle = '''ROOT = Path(__file__).resolve().parents[1]


def replace_once'''
replacement = '''ROOT = Path(__file__).resolve().parents[1]

models_test_state = (ROOT / "Tests/RecordToTextCoreTests/ModelsDefaultsTests.swift").read_text()
migration_test_state = (ROOT / "Tests/RecordToTextCoreTests/AppCredentialMigrationTests.swift").read_text()
vertex_test_state = (ROOT / "Tests/RecordToTextCoreTests/VertexAIGeminiBackendTests.swift").read_text()
if (
    "XCTAssertEqual(settings.schemaVersion, 2)" in models_test_state
    and 'XCTAssertEqual(viewModel.alert?.title, "部分資料未能載入")' in migration_test_state
    and "private var fakeGCloudDirectory" in vertex_test_state
):
    print("phase 0f already applied")
    raise SystemExit(0)


def replace_once'''
if needle not in text:
    raise RuntimeError("could not install phase 0f idempotency guard")
phase0f.write_text(text.replace(needle, replacement, 1))
print("installed phase 0f idempotency guard")
