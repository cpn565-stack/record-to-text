#!/usr/bin/env python3
"""Apply final Gemini 3.5 Transcribe contract corrections."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8")


def replace_exact(path: str, old: str, new: str, count: int = 1) -> None:
    text = read(path)
    actual = text.count(old)
    if actual != count:
        raise RuntimeError(
            f"{path}: expected {count} occurrence(s), found {actual}: {old[:80]!r}"
        )
    write(path, text.replace(old, new, count))


def insert_once(path: str, marker: str, insertion: str) -> None:
    text = read(path)
    if insertion.strip() in text:
        return
    if marker not in text:
        raise RuntimeError(f"{path}: insertion marker not found: {marker[:80]!r}")
    write(path, text.replace(marker, insertion + marker, 1))


def replace_supported_language_code() -> None:
    # Published Gemini 3.5 Transcribe tables currently list Mandarin as
    # cmn-Hans-CN. The App still converts transcript and metadata text to
    # Taiwan Traditional Chinese through OpenCC.
    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git" in path.parts:
            continue
        if path.suffix.lower() not in {
            ".swift", ".md", ".py", ".yml", ".yaml", ".json", ".txt"
        }:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        updated = text.replace("cmn-Hans-CN", "cmn-Hans-CN")
        updated = updated.replace(
            "Mandarin 中文提示（官方代碼）",
            "Mandarin 中文提示（官方代碼）",
        )
        if updated != text:
            path.write_text(updated, encoding="utf-8")


def patch_models() -> None:
    replace_exact(
        "Sources/RecordToTextCore/Models.swift",
        "        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1\n",
        "        let decodedSchemaVersion = try container.decodeIfPresent(\n"
        "            Int.self,\n"
        "            forKey: .schemaVersion\n"
        "        ) ?? 1\n"
        "        schemaVersion = max(decodedSchemaVersion, 2)\n",
    )


def patch_language_ui() -> None:
    marker = "            Toggle(\n                \"辨識說話者\",\n"
    insertion = (
        "            if options.languagePreference == .taiwanMandarin {\n"
        "                Text(\"Google 目前公開的 Mandarin 支援代碼為 cmn-Hans-CN；App 仍會在輸出階段轉為台灣繁體。台灣口音或中英混講建議優先使用自動偵測。\")\n"
        "                    .font(.caption)\n"
        "                    .foregroundStyle(.secondary)\n"
        "            }\n\n"
    )
    insert_once(
        "Sources/RecordToTextApp/CloudModelSettingsView.swift",
        marker,
        insertion,
    )


def patch_initial_segment_plan() -> None:
    old = """            let segmentPlan = try AudioSegmentPlanner.makePlan(
                sourceDuration: metadata.duration,
                maximumSegmentDuration: maximumASRSegmentDuration
            )
            update(
                .log(
                    level: "info",
                    message: String(
                        format: "分段計畫：來源 %.1f 分鐘，每段最長 %.0f 分鐘（%.0f 秒），共 %d 段。",
                        metadata.duration / 60.0,
                        maximumASRSegmentDuration / 60.0,
                        maximumASRSegmentDuration,
                        segmentPlan.expectedSegmentCount
                    )
                )
            )
"""
    new = """            let planningSegmentDuration: TimeInterval
            if job.snapshot.backendType == .localQwen {
                planningSegmentDuration = maximumASRSegmentDuration
            } else {
                planningSegmentDuration = Self.effectiveCloudSegmentDuration(
                    for: job.snapshot,
                    productMaximum: maximumASRSegmentDuration
                )
            }
            let segmentPlan = try AudioSegmentPlanner.makePlan(
                sourceDuration: metadata.duration,
                maximumSegmentDuration: planningSegmentDuration
            )
            update(
                .log(
                    level: "info",
                    message: String(
                        format: "分段計畫：來源 %.1f 分鐘，每段最長 %.0f 分鐘（%.0f 秒），共 %d 段。",
                        metadata.duration / 60.0,
                        planningSegmentDuration / 60.0,
                        planningSegmentDuration,
                        segmentPlan.expectedSegmentCount
                    )
                )
            )
"""
    replace_exact(
        "Sources/RecordToTextCore/TranscriptionEngine.swift",
        old,
        new,
    )


def patch_contract_tests() -> None:
    path = "Tests/RecordToTextCoreTests/GeminiTranscribeContractTests.swift"
    marker = "\n}\n\nfinal class GoogleAIStudioInteractionsContractTests"
    insertion = (
        "\n\n    func testMandarinPresetUsesPublishedSupportedCode() {\n"
        "        let automatic = DedicatedTranscriptionOptions(\n"
        "            languagePreference: .automatic\n"
        "        )\n"
        "        XCTAssertTrue(automatic.resolvedLanguageCodes.isEmpty)\n\n"
        "        let mandarin = DedicatedTranscriptionOptions(\n"
        "            languagePreference: .taiwanMandarin\n"
        "        )\n"
        "        XCTAssertEqual(mandarin.resolvedLanguageCodes, [\"cmn-Hans-CN\"])\n"
        "    }\n"
    )
    text = read(path)
    if "testMandarinPresetUsesPublishedSupportedCode" not in text:
        if marker not in text:
            raise RuntimeError(f"{path}: catalog test class marker not found")
        text = text.replace(
            marker,
            insertion + "\n}\n\nfinal class GoogleAIStudioInteractionsContractTests",
            1,
        )
        write(path, text)


def patch_settings_migration_test() -> None:
    marker = (
        "    func testDefaultValueUsesNeutralProductDirectoryAndRequestedDeveloperMode() {\n"
    )
    insertion = (
        "    func testLegacySettingsDecodeUpgradesCloudSchemaAndDefaults() throws {\n"
        "        let json = \"{\\\"schemaVersion\\\":1,\\\"defaultOutputDirectory\\\":\\\"/tmp/output\\\"}\"\n"
        "        let settings = try JSONDecoder().decode(\n"
        "            AppSettings.self,\n"
        "            from: Data(json.utf8)\n"
        "        )\n\n"
        "        XCTAssertEqual(settings.schemaVersion, 2)\n"
        "        XCTAssertEqual(settings.googleAIStudioTranscriptionOptions, .default)\n"
        "        XCTAssertEqual(settings.vertexAITranscriptionOptions, .default)\n"
        "        XCTAssertEqual(settings.vertexAISummaryModelID, \"gemini-3.7-flash\")\n"
        "        XCTAssertFalse(settings.allowDedicatedTranscribeFallbackToGeneralGemini)\n"
        "    }\n\n"
    )
    insert_once(
        "Tests/RecordToTextCoreTests/ModelsDefaultsTests.swift",
        marker,
        insertion,
    )


def patch_docs() -> None:
    note = (
        "\n\n## 語言提示限制（2026-08-27）\n\n"
        "Google 目前公開的 Gemini 3.5 Transcribe 支援語言表只列出 Mandarin `cmn-Hans-CN`，沒有列出 `cmn-Hans-CN` 或 `zh-TW`。因此 App 的 Mandarin 中文提示會送出 `cmn-Hans-CN`；主逐字稿、speaker turn 與 word metadata 仍會在本機經 OpenCC 轉成台灣繁體。台灣口音或中英混講建議先使用「自動偵測」，再以相同音檔比較 Mandarin 提示的結果。\n"
    )
    for path in [
        "docs/GEMINI_3_5_TRANSCRIBE_IMPLEMENTATION.md",
        "docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md",
    ]:
        text = read(path)
        if "## 語言提示限制（2026-08-27）" not in text:
            write(path, text.rstrip() + note + "\n")

    insert_once(
        "CHANGELOG.md",
        "### Fixed\n\n",
        "- Gemini 3.5 Transcribe 的 Mandarin 預設語言提示改用官方已列出的 `cmn-Hans-CN`；輸出仍由 App 在本機轉為台灣繁體，並修正 gcloud 14 分鐘工作在初始日誌中誤顯示 20 分鐘的問題。\n",
    )


if __name__ == "__main__":
    replace_supported_language_code()
    patch_models()
    patch_language_ui()
    patch_initial_segment_plan()
    patch_contract_tests()
    patch_settings_migration_test()
    patch_docs()
    print("Gemini Transcribe finalization patch applied.")
