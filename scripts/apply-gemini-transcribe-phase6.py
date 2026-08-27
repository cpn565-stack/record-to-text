#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
models = ROOT / "Sources/RecordToTextCore/Models.swift"
self_test = ROOT / "Tools/SelfTest/main.swift"
recovery_test = ROOT / "Tests/RecordToTextCoreTests/CloudReliabilityTests.swift"
readme = ROOT / "README.md"
changelog = ROOT / "CHANGELOG.md"
decisions = ROOT / "docs/product-decisions.md"
next_steps = ROOT / "docs/NEXT_STEPS.md"
implementation_doc = ROOT / "docs/GEMINI_3_5_TRANSCRIBE_IMPLEMENTATION.md"

if implementation_doc.exists() and "PD-016" in decisions.read_text():
    print("phase 6 already applied")
    raise SystemExit(0)


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"{path}: expected one match, found {count}: {old[:140]!r}"
        )
    path.write_text(text.replace(old, new, 1))


# Remove the obsolete shared model catalog. AI Studio and gcloud no longer
# share model IDs or transports.
model_text = models.read_text()
start = model_text.find("public struct GeminiModelDescriptor:")
end_marker = "public typealias VertexAIModelDescriptor = GeminiModelDescriptor\n\n"
end = model_text.find(end_marker, start)
if start < 0 or end < 0:
    raise RuntimeError("could not locate obsolete GeminiModelDescriptor block")
model_text = model_text[:start] + model_text[end + len(end_marker):]
model_text = model_text.replace(
    '            return "Google Cloud Vertex AI (GCP / ADC)"',
    '            return "Google Cloud (gcloud / ADC)"',
    1
)
models.write_text(model_text)

replace_once(
    self_test,
    '''tests.check(
    {
        let presets = GeminiModelDescriptor.presetModels
        return presets.contains(where: { $0.id == "gemini-3.7-flash" })
            && presets.contains(where: { $0.id == "gemini-3.6-flash" })
            && presets.contains(where: { $0.id == "gemini-3.1-pro-preview" })
    }(),
    "GeminiModelDescriptor contains 3.7 Flash, 3.6 Flash and 3.1 Pro presets"
)
''',
    '''tests.check(
    {
        let aiStudio = GoogleAIStudioModelCatalog.models
        let gcloud = GCloudModelCatalog.models
        return aiStudio.contains(where: {
            $0.id == "gemini-3.5-transcribe"
                && $0.transport == .geminiInteractionsTranscribe
        })
            && gcloud.contains(where: {
                $0.id == "gemini-3.5-transcribe-preview"
                    && $0.transport == .agentPlatformTranscribe
                    && $0.requiredLocation == "global"
            })
            && GCloudModelCatalog.summaryModels.allSatisfy(\\.supportsSummary)
    }(),
    "Provider-specific Gemini catalogs separate Interactions, Agent Platform and summary models"
)
'''
)

# Recovery must carry structured metadata while continuing to exclude audio.
replace_once(
    recovery_test,
    '''        let firstText = workingSegments.appendingPathComponent("segment-0001.txt")
        let secondText = workingSegments.appendingPathComponent("segment-0002.txt")
        try Data("sensitive audio".utf8).write(to: firstAudio)
        try Data("sensitive audio".utf8).write(to: secondAudio)
        try Data("第一段已完成".utf8).write(to: firstText)
''',
    '''        let firstText = workingSegments.appendingPathComponent("segment-0001.txt")
        let secondText = workingSegments.appendingPathComponent("segment-0002.txt")
        let firstMetadata = workingSegments.appendingPathComponent(
            "segment-0001.metadata.json"
        )
        try Data("sensitive audio".utf8).write(to: firstAudio)
        try Data("sensitive audio".utf8).write(to: secondAudio)
        try Data("第一段已完成".utf8).write(to: firstText)
        try Data("{\\"speakerScope\\":\\"segmentLocal\\"}".utf8).write(
            to: firstMetadata
        )
'''
)
replace_once(
    recovery_test,
    '''                    audioPath: firstAudio.path,
                    outputPath: firstText.path,
                    status: .completed,
''',
    '''                    audioPath: firstAudio.path,
                    outputPath: firstText.path,
                    metadataPath: firstMetadata.path,
                    status: .completed,
'''
)
replace_once(
    recovery_test,
    '''        XCTAssertTrue(recovered.segments.allSatisfy {
            $0.outputPath.hasPrefix(recovery.path)
        })
        XCTAssertEqual(
''',
    '''        XCTAssertTrue(recovered.segments.allSatisfy {
            $0.outputPath.hasPrefix(recovery.path)
        })
        let recoveredMetadataPath = try XCTUnwrap(
            recovered.segments[0].metadataPath
        )
        XCTAssertTrue(recoveredMetadataPath.hasPrefix(recovery.path))
        XCTAssertFalse(recoveredMetadataPath.contains(working.path))
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: recoveredMetadataPath),
                encoding: .utf8
            ),
            "{\\"speakerScope\\":\\"segmentLocal\\"}"
        )
        XCTAssertNil(recovered.segments[1].metadataPath)
        XCTAssertEqual(
'''
)

# README: make provider/transport and privacy boundaries accurate.
replace_once(
    readme,
    '`record-to-text` 是原生 macOS App：把 M4A / MP3 / WAV / AAC / FLAC 拖進去，先整理專有名詞，再選擇 Google AI Studio、Vertex AI 或本機 Qwen3-ASR 轉錄，輸出 UTF-8 繁體 TXT。',
    '`record-to-text` 是原生 macOS App：把 M4A / MP3 / WAV / AAC / FLAC 拖進去，先整理專有名詞，再選擇 Google AI Studio、Google Cloud（gcloud / ADC）或本機 Qwen3-ASR 轉錄，輸出 UTF-8 台灣繁體 TXT。'
)
replace_once(
    readme,
    '> **隱私邊界取決於你選的後端。** Google AI Studio 與 Vertex AI 會上傳經壓縮／分段的音訊、Prompt 與詞彙給 Google；只有「本機 Qwen」模式不會上傳音訊或轉錄內容。',
    '> **隱私邊界取決於你選的後端。** 一般 Gemini 路徑會上傳壓縮／分段音訊、Prompt 與詞彙；Gemini 3.5 Transcribe 專用路徑只上傳音訊、語言提示、Custom Vocabulary 與轉錄選項，不傳送自由文字 Prompt。只有「本機 Qwen」模式不會上傳音訊或轉錄內容。'
)
replace_once(
    readme,
    '''- **Google AI Studio**：在設定中儲存 Gemini API Key。音訊工具由 App 或本機環境提供。
- **Vertex AI**：需可用的 `gcloud` 登入狀態、GCP 專案與有權限的 Vertex AI 區域。
- **本機 Qwen**：目前需開啟 Developer Mode，並準備 Python／MLX-Audio、OpenCC 與 helper。App 管理的完整 Runtime installer 尚未完成。

下列環境需求主要適用於「本機 Qwen」。
''',
    '''- **Google AI Studio**：在設定中儲存 Gemini API Key；一般 Gemini 走 `generateContent`，`gemini-3.5-transcribe` 走 Interactions API。
- **Google Cloud**：需可用的 `gcloud`／ADC、GCP 專案；一般 Gemini 走 Vertex `generateContent`，`gemini-3.5-transcribe-preview` 走 Agent Platform 專用契約並固定使用 `global`。
- **本機 Qwen**：目前需開啟 Developer Mode，並準備 Python／MLX-Audio、OpenCC 與 helper。App 管理的完整 Runtime installer 尚未完成。

### Gemini 3.5 Transcribe 路徑

| Provider | 模型 | Transport | 產品安全切片 | 主要能力 |
| --- | --- | --- | ---: | --- |
| Google AI Studio | `gemini-3.5-transcribe` | Gemini Interactions `v1beta` | 20 分鐘 | Verbatim／Smart、Custom Vocabulary、speaker、word timestamp |
| Google Cloud | `gemini-3.5-transcribe-preview` | Agent Platform `v1beta1` | 14 分鐘 | Custom Vocabulary、speaker、word timestamp、`global` only |

專用 Transcribe 預設不會在失敗時偷偷改走一般 Gemini；429／500／502／503 只在同一模型內退避重試。說話者標籤只保證同一分段內一致，長音檔 JSON 會明確標成 `segmentLocal`。

完整的本機、真實 API、清理、取消與 A/B 驗證步驟見 [Gemini 3.5 Transcribe 驗證手冊](docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md)。

下列環境需求主要適用於「本機 Qwen」。
'''
)
replace_once(
    readme,
    '- 雲端管線：`ffprobe → ffmpeg 壓縮／分段 → Gemini API → 原子寫入 TXT`。',
    '- 雲端管線：`ffprobe → 模型能力決定 14／20 分鐘切片 → ffmpeg 壓縮 → provider-specific Gemini transport → OpenCC → 原子寫入 TXT`；可選擇另存 speaker／word timestamp JSON。'
)
replace_once(
    readme,
    '- 超過 **20 分鐘**：coordinator 切成編號片段、逐段獨立 ASR（預設 token 預算 16384）；全部通過 manifest gate 後才交付正式逐字稿。',
    '- 雲端切片由工作 Snapshot 固定：一般 Gemini 與 AI Studio Transcribe 最多 **20 分鐘**；gcloud Transcribe Preview 使用 **14 分鐘**安全切片。任一路徑都要全部通過 manifest gate 才交付正式逐字稿。'
)
replace_once(
    readme,
    '- 雲端分段工作失敗或取消時，若已有完成片段，`Temp-Recovery` 會只保留部分 TXT、manifest 與最小 metadata（不保留 MP3），供人工取回。這不是自動斷點續跑；重新加入原始錄音會從頭轉錄。若還沒有任何完成片段，就不會誤稱有部分稿可取回。',
    '- 雲端分段工作失敗或取消時，若已有完成片段，`Temp-Recovery` 會保留部分 TXT、manifest、最小 recovery metadata，以及已完成片段的 optional structured metadata JSON；不保留 MP3。這不是自動斷點續跑；重新加入原始錄音會從頭轉錄。'
)
replace_once(
    readme,
    '- [下一次接續](docs/NEXT_STEPS.md)\n- [交班單](HANDOFF.md)',
    '- [下一次接續](docs/NEXT_STEPS.md)\n- [Gemini 3.5 Transcribe 實作對照](docs/GEMINI_3_5_TRANSCRIBE_IMPLEMENTATION.md)\n- [Gemini 3.5 Transcribe 驗證手冊](docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md)\n- [交班單](HANDOFF.md)'
)

# Changelog additions under the existing Unreleased/Added section.
replace_once(
    changelog,
    '''### Added

''',
    '''### Added

- Google AI Studio 新增 `gemini-3.5-transcribe`：使用 Gemini Interactions `v1beta`、Files API upload-once、Custom Vocabulary、Verbatim／Smart、speaker diarization、word timestamps 與 optional JSON sidecar。
- Google Cloud 新增 `gemini-3.5-transcribe-preview`：使用 gcloud／ADC、Agent Platform `v1beta1`、`global`、GCS／inline 音訊、14 分鐘安全切片與 structured `audioTranscription` parser。
- AI Studio 與 Google Cloud 改用 provider-specific model catalogs；自訂未知 Model ID 仍明確走既有一般 `generateContent`，不靠字串猜測 transport。
- 雲端工作 Snapshot 固定 transport、語言提示、去重後 Custom Vocabulary、模型時長、切片政策、metadata 選項與獨立摘要模型；舊 settings／ledger 可向後解碼。
- 專用轉錄的 transcript、speaker turns 與 word text 會一致轉成台灣繁體；可輸出帶絕對時間與 segment-local speaker label 的 JSON sidecar。
- 新增完整 API contract、切片、offset、speaker scope、設定 migration 與 recovery metadata 測試，以及 `docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md`。

'''
)
replace_once(
    changelog,
    '''### Known limitations

''',
    '''### Known limitations

- Gemini 3.5 Transcribe 兩條路徑已通過 mock／contract／pipeline／App build 測試，但 CI 不持有使用者的 AI Studio Key、GCP Project entitlement 或 GCS 權限；真實 Preview 可用性與 response contract 仍須依驗證手冊在目標專案 smoke test。
- 長音檔 speaker label 目前是 `segmentLocal`；不同分段的 `speaker-1` 不宣稱是同一人。

'''
)

# Record the architectural decision before the Phase 0 gate section.
pd016 = '''### PD-016：Gemini 3.5 Transcribe 的 Provider／Transport 分離

**決策**

- `ASRBackendType` 只代表 credential／provider 邊界：Google AI Studio API Key、Google Cloud gcloud／ADC、本機 Qwen。
- Model descriptor 決定 transport：一般 Gemini `generateContent`、AI Studio Interactions Transcribe、Google Cloud Agent Platform Transcribe。
- AI Studio 與 Google Cloud 使用獨立 model catalog；相同產品名稱不能假設 Model ID、API version、location、request／response schema 相同。
- `gemini-3.5-transcribe` 使用 Gemini Interactions `v1beta`；`gemini-3.5-transcribe-preview` 使用 Agent Platform `v1beta1` 且 effective location 固定為 `global`。
- 專用 Transcribe 失敗時預設不跨到一般 Gemini。429／500／502／503 只在同一模型內重試，避免語意、speaker／timestamp、成本與 A/B 數據被隱性改變。
- gcloud Preview 以 14 分鐘切片保留官方 15 分鐘上限的容器／編碼餘裕；一般 Gemini 與 AI Studio 專用模型維持 20 分鐘產品切片。
- Job Snapshot 固定 transport、options、resolved vocabulary、語言提示與切片參數，避免佇列等待期間的設定變更改寫既有工作的執行語意。
- transcript、word text 與 speaker turn 一起經 OpenCC 轉成台灣繁體；speaker identity 只保證 segment-local，不宣稱跨切片一致。
- Vertex 全文摘要與轉錄模型解耦；專用 Transcribe 完成合併後，最多再由指定的一般 Gemini 摘要一次，摘要失敗不得丟失逐字稿。

**證據邊界**

- Swift Core、SwiftUI App、mock pipeline、request／response contract、settings／ledger migration、recovery 與 XCTest 已自動化驗證。
- CI 不保存真實 API Key／ADC／Preview entitlement；目標 Project 的 live endpoint、quota、IAM、GCS cleanup 與實際音訊品質仍依 `docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md` 驗證。

'''
replace_once(
    decisions,
    '''## 4. Phase 0 決策閘門
''',
    pd016 + '''## 4. Phase 0 決策閘門
'''
)

# NEXT_STEPS becomes explicit that code is complete but live provider evidence remains.
replace_once(
    next_steps,
    '更新日期：2026-08-02  ',
    '更新日期：2026-08-27  '
)
new_checkpoint = '''## 已完成（feature/gemini-3.5-transcribe）

- Google AI Studio `gemini-3.5-transcribe` Interactions API transport。
- Google Cloud `gemini-3.5-transcribe-preview` Agent Platform transport（`global`／14 分鐘切片）。
- Provider-specific model catalogs、Job Snapshot migration、Custom Vocabulary、語言提示、Smart／speaker／timestamp compatibility validation。
- Structured speaker／word metadata、絕對時間 offset、segment-local speaker scope、台灣繁體轉換、optional JSON sidecar 與 recovery metadata。
- 轉錄／摘要模型分離；專用模型不做隱性 general-model fallback。
- 完整 mock／contract／pipeline／SwiftUI App build／XCTest 自動驗證。
- 本機與真實 API 驗證步驟：`docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md`。

**仍需外部證據**

- 使用實際 AI Studio Key 確認 Preview entitlement 與 Interactions response。
- 使用目標 GCP Project 確認 Agent Platform Preview、`v1beta1` endpoint、IAM／quota 與 GCS cleanup。
- 同一批真實會議與 3.7 Flash／Local Qwen 做 A/B 品質、速度與成本比較。

'''
replace_once(
    next_steps,
    '''## 待修改／尚未做（優先序）
''',
    new_checkpoint + '''## 待修改／尚未做（優先序）
'''
)

implementation_doc.write_text('''# Gemini 3.5 Transcribe 實作對照（21 章規格）

基準：`ba3d1297cb480fc592b11046a64f2f9221bd0bd0`  
實作分支：`feature/gemini-3.5-transcribe`

本文件將原修改規格書的 21 個章節對照到實際程式與驗證狀態。

## 1. 結論與核心決策

已完成。保留一般 Gemini，新增 provider-specific 專用 Transcribe transport；不以 Model ID 直接套用錯誤 endpoint，也不預設跨模型 fallback。

## 2. `ba3d12` 現況盤點

已以 `ba3d12` 為 branch base，保留 upload-once、same-reference retries、cancellation-safe cleanup、cloud checkpoint、settings flush 與 process cleanup。

## 3. 修改目標

已完成 AI Studio、Google Cloud 與本機 Qwen 的共存；專用模型可在 UI 選擇，舊一般 Gemini 行為保留。

## 4. 目標架構

- `ASRBackendType`：credential／provider。
- `CloudModelTransport`：API contract。
- `CloudModelDescriptor`：能力、API version、location 與時長。
- AI Studio／Google Cloud 各自 model catalog。

主要檔案：`CloudTranscriptionModels.swift`。

## 5. 設定與 Job Snapshot

`AppSettings` schema 2；Job Snapshot 固定 transport、options、語言、Custom Vocabulary、模型限制、切片與摘要模型。舊 JSON 使用 `decodeIfPresent` 向後相容。

## 6. Google AI Studio

`GoogleAIStudioTranscribeBackend.swift`：Files API upload-once、Interactions `v1beta`、Verbatim／Smart、語言、Custom Vocabulary、speaker／word annotation parser、retry 與 cleanup。

## 7. gcloud / Agent Platform

`AgentPlatformTranscribeBackend.swift`：gcloud／ADC、`gemini-3.5-transcribe-preview`、`global`、`v1beta1`、GCS／inline、`audioTranscriptionConfig`、structured response、401 refresh、retry 與 cleanup。

## 8. 摘要解耦

`vertexAISummaryModelID` 只允許一般 summary-capable model；所有段落合併後最多呼叫一次。摘要失敗僅 warning，逐字稿保留。

## 9. 動態切片

- 一般 Gemini：1,200 秒。
- AI Studio Transcribe：1,200 秒。
- gcloud Preview：840 秒。

切片參數固定在 Job Snapshot，manifest／progress／recovery 共用同一政策。

## 10. 結構化結果

`CloudTranscriptionResult`、`TimedWord`、`SpeakerTurn`、segment/final metadata；timestamp 加上來源片段起點，speaker label 改成 `segment-N:speaker-X`。

## 11. 台灣繁體與後處理

transcript、word text、speaker turn 一起以 OpenCC `s2twp` 轉換。專用模型不套用一般 Prompt echo 檢查；Smart Mode 的格式不被一般 Gemini sanitizer 破壞。

## 12. UI / UX

`CloudModelSettingsView.swift`：provider-specific picker、Preview、mode、language、speaker、timestamp、JSON、global、切片與 Prompt 限制。gcloud summary model 另選。

## 13. Retry、Fallback、錯誤

429／500／502／503 同模型退避；gcloud 401 refresh 一次；4xx schema／permission／entitlement fail closed。專用模型預設不跨一般 Gemini。

## 14. Recovery / Checkpoint

每段完成即寫 TXT、manifest、partial transcript；啟用 metadata 時另寫 segment JSON。取消／失敗 recovery 搬移已完成 TXT／JSON，不保留 MP3。

## 15. 安全、隱私、日誌

AI Studio Key 僅 Keychain；Bearer token 不落盤；log 不記 Key、token、Base64、全文詞庫或 transcript。遠端檔案在 success／error／cancel 後 shielded cleanup。

## 16. 檔案修改清單

規格中的 Models、兩個 backend、TranscriptionEngine、SettingsView、AppViewModel、recovery、tests 與 docs 均已落地；另新增 provider-specific UI／job resolver。

## 17. 測試

`GeminiTranscribeContractTests.swift` 與既有 cloud reliability tests 涵蓋 catalog、request schema、response、切片、offset、speaker scope、migration、cleanup 與 recovery。完整 CI 同時跑 App build 與既有 pipeline。

## 18. 開發階段

實作依序完成：model architecture → AI Studio → gcloud → pipeline/metadata → UI/Snapshot → tests/docs。Commit 保持可追溯，未直接修改原雲端分支。

## 19. 驗收標準

自動化部分已完成；真實 API、Preview entitlement、IAM／quota、GCS 與 A/B 品質需依驗證手冊執行。

## 20. 風險與實測事項

Preview API 可能調整；gcloud `v1beta1` 與 Project entitlement 是最重要 live contract gate。跨片段 speaker identity 仍明確標示為 segment-local。

## 21. 建議產品配置

首版仍保留 3.7 Flash 為預設；3.5 Transcribe 以可選 Preview 上線。預設 Verbatim、Auto language、Custom Vocabulary；speaker／timestamps／JSON 關閉；專用模型跨一般模型 fallback 關閉。

## 驗證入口

完整指令、UI 步驟、邊界測試、遠端 cleanup、資安檢查與 A/B 表格見：

`docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md`
''')

print("phase 6 applied")
