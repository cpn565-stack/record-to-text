#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
models = ROOT / "Sources/RecordToTextCore/CloudTranscriptionModels.swift"
backend = ROOT / "Sources/RecordToTextCore/AgentPlatformTranscribeBackend.swift"
tests = ROOT / "Tests/RecordToTextCoreTests/GeminiTranscribeContractTests.swift"
readme = ROOT / "README.md"
changelog = ROOT / "CHANGELOG.md"
verification = ROOT / "docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md"
implementation = ROOT / "docs/GEMINI_3_5_TRANSCRIBE_IMPLEMENTATION.md"

if 'transcriptionConfig["mode"]' in backend.read_text():
    print("phase 7 already applied")
    raise SystemExit(0)


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"{path}: expected one match, found {count}: {old[:140]!r}"
        )
    path.write_text(text.replace(old, new, 1))


model_text = models.read_text()
model_start = model_text.index('            id: "gemini-3.5-transcribe-preview",')
model_end = model_text.index('        CloudModelDescriptor.generalVertex(', model_start)
model_block = model_text[model_start:model_end]
if "supportsSmartMode: false" not in model_block:
    raise RuntimeError("gcloud Transcribe descriptor Smart-mode flag not found")
model_block = model_block.replace(
    "supportsSmartMode: false",
    "supportsSmartMode: true",
    1
)
model_block = model_block.replace(
    'note: "gcloud / Agent Platform 專用轉錄模型；固定使用 global，單段以 14 分鐘安全切片。"',
    'note: "gcloud / Agent Platform 專用轉錄模型；支援忠實逐字／智慧整理，固定使用 global，單段以 14 分鐘安全切片。"',
    1
)
models.write_text(model_text[:model_start] + model_block + model_text[model_end:])

replace_once(
    backend,
    '''        if !customVocabulary.isEmpty {
            transcriptionConfig["customVocabulary"] = customVocabulary
        }
        transcriptionConfig["wordTimestamp"] = options.wordTimestampsEnabled
''',
    '''        if !customVocabulary.isEmpty {
            transcriptionConfig["customVocabulary"] = customVocabulary
        }
        transcriptionConfig["mode"] = options.mode == .smart
            ? "SMART"
            : "VERBATIM"
        transcriptionConfig["wordTimestamp"] = options.wordTimestampsEnabled
'''
)

replace_once(
    tests,
    '''        XCTAssertFalse(gcloud.supportsSmartMode)
''',
    '''        XCTAssertTrue(gcloud.supportsSmartMode)
'''
)
replace_once(
    tests,
    '''        XCTAssertEqual(transcription["wordTimestamp"] as? Bool, true)
        XCTAssertEqual(transcription["diarization"] as? Bool, true)
        XCTAssertNil(generation["audio_transcription_config"])
    }

    func testResponsePrefersStructuredAudioTranscription() throws {
''',
    '''        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
        XCTAssertEqual(transcription["wordTimestamp"] as? Bool, true)
        XCTAssertEqual(transcription["diarization"] as? Bool, true)
        XCTAssertNil(generation["audio_transcription_config"])
    }

    func testSmartRequestUsesUppercaseEnumAndDisablesStructuredOptions() throws {
        let options = DedicatedTranscriptionOptions(
            mode: .smart,
            languagePreference: .automatic,
            diarizationEnabled: true,
            wordTimestampsEnabled: true
        ).normalizedForUI()
        XCTAssertFalse(options.diarizationEnabled)
        XCTAssertFalse(options.wordTimestampsEnabled)

        let body = AgentPlatformTranscribeBackend().buildRequestBody(
            inputPart: [
                "inlineData": [
                    "mimeType": "audio/mp3",
                    "data": "YXVkaW8="
                ]
            ],
            options: options,
            customVocabulary: []
        )
        let generation = try XCTUnwrap(
            body["generationConfig"] as? [String: Any]
        )
        let transcription = try XCTUnwrap(
            generation["audioTranscriptionConfig"] as? [String: Any]
        )
        XCTAssertEqual(transcription["mode"] as? String, "SMART")
        XCTAssertEqual(transcription["wordTimestamp"] as? Bool, false)
        XCTAssertEqual(transcription["diarization"] as? Bool, false)
    }

    func testResponsePrefersStructuredAudioTranscription() throws {
'''
)

replace_once(
    readme,
    '| Google Cloud | `gemini-3.5-transcribe-preview` | Agent Platform `v1beta1` | 14 分鐘 | Custom Vocabulary、speaker、word timestamp、`global` only |',
    '| Google Cloud | `gemini-3.5-transcribe-preview` | Agent Platform `v1beta1` | 14 分鐘 | Verbatim／Smart、Custom Vocabulary、speaker、word timestamp、`global` only |'
)

replace_once(
    changelog,
    '- Google Cloud 新增 `gemini-3.5-transcribe-preview`：使用 gcloud／ADC、Agent Platform `v1beta1`、`global`、GCS／inline 音訊、14 分鐘安全切片與 structured `audioTranscription` parser。',
    '- Google Cloud 新增 `gemini-3.5-transcribe-preview`：使用 gcloud／ADC、Agent Platform `v1beta1`、`global`、GCS／inline 音訊、Verbatim／Smart、14 分鐘安全切片與 structured `audioTranscription` parser。'
)

replace_once(
    verification,
    '''## 6.5 14／15 分鐘切片邊界
''',
    '''## 6.5 gcloud Smart Mode 測試

Google Cloud 官方契約同樣提供 `VERBATIM` 與 `SMART`。選：

```text
轉錄模式：智慧整理
```

App 送出的 `audioTranscriptionConfig.mode` 應為：

```text
SMART
```

UI 會自動關閉並停用 speaker diarization 與 word timestamp，因為 Smart 模式與這兩項 structured metadata 不相容。使用同一份音檔比較 Verbatim／Smart，確認 Smart 會移除部分贅詞、重複與 false start，但不適合作為嚴格逐字引述版本。

## 6.6 14／15 分鐘切片邊界
'''
)
replace_once(
    verification,
    '''## 6.6 gcloud Speaker／Timestamp／JSON
''',
    '''## 6.7 gcloud Speaker／Timestamp／JSON
'''
)
replace_once(
    verification,
    '''## 6.7 專用 Transcribe + 全文摘要
''',
    '''## 6.8 專用 Transcribe + 全文摘要
'''
)
replace_once(
    verification,
    '''- [ ] Transcribe Preview 使用 global／v1beta1
- [ ] 13 分鐘 1 段
''',
    '''- [ ] Transcribe Preview 使用 global／v1beta1
- [ ] gcloud Verbatim／Smart 都能執行，Smart 會停用 speaker／timestamp
- [ ] 13 分鐘 1 段
'''
)

replace_once(
    implementation,
    '`AgentPlatformTranscribeBackend.swift`：gcloud／ADC、`gemini-3.5-transcribe-preview`、`global`、`v1beta1`、GCS／inline、`audioTranscriptionConfig`、structured response、401 refresh、retry 與 cleanup。',
    '`AgentPlatformTranscribeBackend.swift`：gcloud／ADC、`gemini-3.5-transcribe-preview`、`global`、`v1beta1`、GCS／inline、Verbatim／Smart `audioTranscriptionConfig`、structured response、401 refresh、retry 與 cleanup。'
)
replace_once(
    implementation,
    '首版仍保留 3.7 Flash 為預設；3.5 Transcribe 以可選 Preview 上線。預設 Verbatim、Auto language、Custom Vocabulary；speaker／timestamps／JSON 關閉；專用模型跨一般模型 fallback 關閉。',
    '首版仍保留 3.7 Flash 為預設；3.5 Transcribe 以可選 Preview 上線。兩個 provider 都支援 Verbatim／Smart；預設 Verbatim、Auto language、Custom Vocabulary，speaker／timestamps／JSON 關閉，專用模型跨一般模型 fallback 關閉。'
)

print("phase 7 applied")
