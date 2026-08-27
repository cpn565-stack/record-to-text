# Gemini 3.5 Transcribe 實作報告暨本地 Agent 部署驗證手冊

> 專案：`cpn565-stack/record-to-text`  
> 實作分支：`feature/gemini-3.5-transcribe`  
> 實作基準：`ba3d1297cb480fc592b11046a64f2f9221bd0bd0`  
> 程式功能驗證基準 commit：`dde0ad08b5bfc6c7616e61e4aeceef0724da52c7`  
> 文件整理日期：2026-08-27

本文件的目的不是重新設計功能，而是讓本地 Agent 在取得此分支後，可以直接完成：

1. 部署與建置。
2. 自動化 regression test。
3. Google AI Studio 真實 API smoke test。
4. Google Cloud / gcloud 真實 API smoke test。
5. 長音訊、speaker、timestamp、recovery、cleanup 驗證。
6. 最後輸出一份可判斷是否能 merge / release 的測試報告。

本文件應與以下兩份文件一起使用：

- `docs/GEMINI_3_5_TRANSCRIBE_IMPLEMENTATION.md`：21 章規格與程式實作對照。
- `docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md`：完整人工與真實 API 驗證細節。

---

# 1. Executive Summary

這次修改不是把現有 `gemini-3.7-flash` 的 model ID 換成 `gemini-3.5-transcribe`。

核心決策是：**保留原本一般 Gemini `generateContent` 路徑，同時增加 provider-specific 的專用 Transcribe transport。**

目前產品架構如下：

```text
Cloud transcription
├── Google AI Studio
│   ├── Gemini 3.7 Flash / 一般 Gemini
│   │   └── generateContent
│   └── Gemini 3.5 Transcribe
│       └── Files API + Interactions API v1beta
│
├── Google Cloud / gcloud
│   ├── Gemini 3.7 Flash / 一般 Vertex Gemini
│   │   └── Vertex generateContent
│   └── Gemini 3.5 Transcribe Preview
│       └── Agent Platform audio transcription contract v1beta1
│
└── Local Qwen ASR
    └── 原本本機流程不變
```

因此這次驗證的首要原則是：

- 新模型能成功。
- 舊模型不能退化。
- 新 Transcribe 不能偷偷 fallback 成一般 Gemini。
- Provider-specific endpoint / schema 不能混用。
- 失敗時不能交付看似完整但其實不完整的正式 TXT。

---

# 2. Source Control 狀態

目標分支：

```text
feature/gemini-3.5-transcribe
```

本次功能從：

```text
ba3d1297cb480fc592b11046a64f2f9221bd0bd0
```

開始實作。

程式功能與 API contract 已在：

```text
dde0ad08b5bfc6c7616e61e4aeceef0724da52c7
```

完成完整 macOS CI 驗證。

之後的 commit 只包含清除一次性 scaffolding 與文件，不應改變已驗證的核心程式行為。

本地 Agent 開始前必須執行：

```bash
git fetch origin
git switch feature/gemini-3.5-transcribe
git pull --ff-only origin feature/gemini-3.5-transcribe

git branch --show-current
git log -5 --oneline
```

不要直接在 `main` 或 `feature/google-ai-studio-gemini-cloud` 上進行測試性修改。

如果測試過程需要修 bug，請另外建立：

```text
fix/gemini-3.5-transcribe-local-validation
```

並記錄每一個修正原因，不要把測試修正直接混進目前 feature branch。

---

# 3. 本次修改範圍

已完成的主要功能：

- Google AI Studio `gemini-3.5-transcribe`。
- Google Cloud / gcloud `gemini-3.5-transcribe-preview`。
- Provider-specific model catalog。
- Verbatim / Smart Mode。
- Custom Vocabulary。
- Speaker diarization。
- Word-level timestamps。
- Optional structured JSON sidecar。
- Dynamic segmentation。
- Structured result merge。
- 台灣繁體 OpenCC post-processing。
- Remote upload-once / retry-same-reference。
- Cancellation-safe remote cleanup。
- Segment checkpoint / recovery。
- AppSettings schema migration。
- UI capability gating。
- Vertex summary model 與 transcription model 解耦。

未宣稱完成：

- 跨切片 speaker identity matching。
- Preview 模型對所有 Google Cloud Project 都可用。
- Preview API 永久不變。
- 3.5 Transcribe 已適合取代 3.7 Flash 成為產品預設值。

---

# 4. 主要新增與修改檔案

## Core

```text
Sources/RecordToTextCore/CloudTranscriptionModels.swift
Sources/RecordToTextCore/GoogleAIStudioTranscribeBackend.swift
Sources/RecordToTextCore/AgentPlatformTranscribeBackend.swift
Sources/RecordToTextCore/Models.swift
Sources/RecordToTextCore/TranscriptionEngine.swift
Sources/RecordToTextCore/AudioSegmentation.swift
```

用途：

- `CloudTranscriptionModels.swift`
  - model transport abstraction
  - provider-specific model descriptor
  - transcription capabilities
  - language / mode / metadata models
  - normalized Custom Vocabulary

- `GoogleAIStudioTranscribeBackend.swift`
  - Files API upload-once
  - Interactions API `v1beta`
  - Transcribe request / response parsing
  - Verbatim / Smart
  - speaker / timestamps
  - retry / cleanup

- `AgentPlatformTranscribeBackend.swift`
  - gcloud access token
  - `gemini-3.5-transcribe-preview`
  - `global`
  - `v1beta1`
  - GCS / inline audio
  - `audioTranscriptionConfig`
  - structured response parser
  - 401 token refresh
  - retry / cleanup

- `TranscriptionEngine.swift`
  - model transport routing
  - model-aware segment policy
  - segment checkpoint
  - structured metadata merge
  - OpenCC conversion
  - final artifact production

## App / UI

```text
Sources/RecordToTextApp/CloudJobConfiguration.swift
Sources/RecordToTextApp/CloudModelSettingsView.swift
Sources/RecordToTextApp/AppViewModel.swift
Sources/RecordToTextApp/SettingsView.swift
```

用途：

- provider-specific model picker
- Preview model capability controls
- Smart Mode conflict gating
- language hint
- speaker / timestamp / JSON options
- Vertex summary model selection
- Job Snapshot resolution

## Tests

```text
Tests/RecordToTextCoreTests/GeminiTranscribeContractTests.swift
Tests/RecordToTextCoreTests/CloudReliabilityTests.swift
Tests/RecordToTextCoreTests/ModelsDefaultsTests.swift
Tests/RecordToTextCoreTests/VertexAIGeminiBackendTests.swift
```

---

# 5. Model / Transport Architecture

不要用 `modelID.contains("transcribe")` 之類的弱判斷來取代目前 descriptor / transport routing。

目前責任切分：

```text
ASRBackendType
= credential/provider selection

CloudModelDescriptor
= model capability + API contract metadata

CloudModelTransport
= actual request protocol
```

同樣叫 Gemini，但以下兩條路徑不是同一 API：

```text
Gemini 3.7 Flash
→ generateContent

Gemini 3.5 Transcribe
→ dedicated transcription transport
```

測試時如果看到 `gemini-3.5-transcribe` 被送到 `:generateContent`，直接判定 FAIL。

---

# 6. Google AI Studio 實作契約

模型：

```text
gemini-3.5-transcribe
```

API：

```text
POST https://generativelanguage.googleapis.com/v1beta/interactions
```

音訊策略：

```text
Files API upload
→ 得到 URI
→ Interactions input 引用 URI
→ retry 共用同一 URI
→ success / error / cancel 後 cleanup
```

專用 Transcribe 不使用一般 Gemini 的：

```text
systemInstruction
contents + audio part generateContent contract
generationConfig.temperature
general prompt echo sanitizer
```

轉錄設定透過：

```text
transcription_config
```

支援：

```text
language_codes
custom_vocabulary
verbatim / smart
speaker diarization
word timestamp
```

Smart Mode 不得與 speaker diarization / word timestamps 同時生效。

---

# 7. Google Cloud / gcloud 實作契約

模型：

```text
gemini-3.5-transcribe-preview
```

有效 Location：

```text
global
```

API contract：

```text
v1beta1
```

驗證重點：

```text
generationConfig.audioTranscriptionConfig
```

欄位使用 Google Cloud contract：

```text
languageCodes
customVocabulary
wordTimestamp
diarization
mode
```

Smart Mode mode 值應符合目前 Cloud contract。

認證由 App 透過：

```bash
gcloud auth print-access-token
```

取得 Bearer token。

401：

```text
invalidate cached token
→ force refresh once
→ retry once
```

403 / entitlement / schema error 不得無限重試。

---

# 8. Model Catalog 與 UI 行為

AI Studio 與 Vertex 不再共用完全相同的 model list。

原因：

```text
gemini-3.5-transcribe
```

與：

```text
gemini-3.5-transcribe-preview
```

是不同 provider contract。

因此驗證：

- AI Studio picker 不應顯示 Cloud-only preview model ID。
- Vertex picker 不應把 AI Studio `gemini-3.5-transcribe` 當作 Vertex generateContent 模型。
- custom unknown model ID 應繼續視為一般 Gemini generateContent，而不是自動猜成 Transcribe。

---

# 9. Job Snapshot / Migration

`AppSettings` 已升級 cloud schema，新增 Transcribe 設定欄位。

Job 加入 queue 時，以下內容應被 snapshot：

- backend / provider
- model ID
- resolved transport
- transcription mode
- language hint
- speaker enabled
- timestamp enabled
- structured JSON enabled
- Custom Vocabulary snapshot
- maximum segment duration
- summary model

但 API Key / access token 不應被 snapshot 到 ledger。

舊設定與舊 job ledger 必須仍可 decode。

驗證時不要只測全新設定；至少保留一份舊版本 `settings.json` / ledger 做 migration regression。

---

# 10. Dynamic Segmentation

目前政策：

```text
一般 Gemini                    1200 秒 / 20 分鐘
AI Studio Gemini Transcribe    1200 秒 / 20 分鐘
gcloud Transcribe Preview       840 秒 / 14 分鐘
```

gcloud 採 14 分鐘而不是貼滿 15 分鐘上限，是刻意保留 encoder / container 安全 margin。

必測：

```text
13 min  → gcloud 1 segment
14 min  → gcloud 1 segment
15–16 min → gcloud 2 segments
20 min  → gcloud 2 segments
31 min  → gcloud 3 segments
```

AI Studio：

```text
31 min → 2 segments
```

切片 policy 必須從 Job Snapshot 一路一致到：

```text
planner
manifest
progress
checkpoint
recovery
final merge
```

---

# 11. Structured Result / Timestamp / Speaker

專用 Transcribe 回傳後會正規化成：

```text
CloudTranscriptionResult
TimedWord
SpeakerTurn
```

切片內 timestamp 必須轉成整個 source recording 的 absolute offset。

例如：

```text
segment 2 starts at 840 sec
provider word timestamp = 5.2 sec
final timestamp = 845.2 sec
```

Speaker identity 第一版只保證 segment-local：

```text
segment-0001:speaker-1
segment-0002:speaker-1
```

不代表同一真人。

如果 Agent 在測試報告中把跨段 speaker label 當成全域 identity，屬於錯誤判讀。

---

# 12. 台灣繁體後處理

所有專用 Transcribe 結果都應經 OpenCC：

```text
s2twp
```

必須同步處理：

- final transcript text
- word annotation text
- speaker turn text

不能只轉 final TXT，否則 JSON metadata 會出現簡繁不一致。

Smart Mode 的段落格式不能被一般 Gemini 的 Markdown stripping / prompt-echo sanitizer 誤傷。

---

# 13. Custom Vocabulary

現有 glossary / terms 會正規化成 dedicated ASR 的 Custom Vocabulary。

政策：

```text
0–100      正常使用
101–1000   允許，但顯示品質提醒
>1000      在 job 建立前阻止
```

必須：

- trim
- stable dedupe
- preserve first occurrence
- 不把完整 vocabulary 寫進 log

專用 Transcribe 不應再把同一批 terms 重複塞進一般 Prompt。

---

# 14. Retry / Fallback

專用 Transcribe：

```text
429 / 500 / 502 / 503
→ same model retry
→ same uploaded URI/object
```

不可因 transient failure 自動改成：

```text
Gemini 3.7 Flash
Gemini 3.1 Pro
```

原因是 dedicated transcription 與 general multimodal generation 的 output semantics 不完全相同。

一般 Gemini 原本既有 fallback 行為要維持不變。

這兩個政策必須共存。

---

# 15. Remote Cleanup / Security

AI Studio：

```text
Files API temporary file
```

Google Cloud：

```text
GCS temporary object
```

都必須在：

```text
success
error
cancel
```

之後執行 cleanup。

Cleanup 應 shield from parent cancellation。

Log 不得包含：

- API Key
- Bearer token
- Base64 audio
- full Custom Vocabulary
- full transcript

AI Studio Key 仍應只存於 Keychain。

Job Snapshot / settings / recovery JSON 不應出現可用 API Key。

---

# 16. Recovery / Checkpoint

每完成一個 segment 就應持久化：

```text
segment TXT
manifest progress
partial transcript checkpoint
optional segment metadata JSON
```

如果下一段失敗或使用者取消：

- 不建立正式 final TXT。
- 已完成片段可進 Temp-Recovery。
- recovery 不保存 MP3。
- structured metadata 開啟時，已完成 metadata 可一起 recovery。

任何中段失敗仍交付正式 final TXT，判定為嚴重 FAIL。

---

# 17. Vertex Summary 解耦

Vertex `附加內容摘要` 不再假設 transcription model 本身可做 summary。

流程：

```text
Transcribe each segment
→ merge full transcript
→ call summary-capable general Gemini exactly once
→ append summary
```

摘要模型由：

```text
vertexAISummaryModelID
```

獨立設定。

摘要失敗：

```text
保留完整 transcript
+ warning
```

不能把 transcript job 整體標成失敗。

---

# 18. 已完成自動驗證

程式功能驗證基準 `dde0ad0` 已在 Apple Silicon macOS runner 執行完整檢查。

當時結果：

```text
RecordToTextCore build       PASS
RecordToTextApp build        PASS
Executable self-tests        54 passed, 0 failed
Pipeline self-test           PASS
XCTest                       152 tests, 0 failures
App bundle build             PASS
Unsigned bundle verification PASS
```

其中包含新增測試：

```text
AgentPlatformTranscribeContractTests
GoogleAIStudioInteractionsContractTests
GeminiTranscribeCatalogTests
DedicatedCloudSegmentPolicyTests
```

注意：這些 contract tests 不等於真實 Preview entitlement 測試。

本地 Agent 必須重新跑一次目前 HEAD 的完整 suite。

---

# 19. 本地部署步驟

## 19.1 取得程式

```bash
git fetch origin
git switch feature/gemini-3.5-transcribe
git pull --ff-only origin feature/gemini-3.5-transcribe
```

## 19.2 環境

```bash
brew install ffmpeg opencc
which ffmpeg ffprobe opencc
ffmpeg -version | head -1
opencc --version
```

建議第一次：

```bash
rm -rf .build dist
```

不要任意刪除：

```text
~/Library/Application Support/record-to-text/
```

## 19.3 完整 automated checks

```bash
REQUIRE_XCTEST=1 scripts/run-checks.sh
```

另跑：

```bash
swift test
```

若失敗，Agent 必須先保存完整 log，再做任何修改。

## 19.4 Build App

```bash
ADHOC_SIGN=0 scripts/build-app.sh
```

驗證：

```bash
ALLOW_UNSIGNED=1 CHECK_APP_SIZE=0 \
  scripts/verify-release.sh dist/record-to-text.app
```

啟動：

```bash
open dist/record-to-text.app
```

---

# 20. 真實 API Smoke Test 計畫

至少準備以下音檔：

| ID | 音檔 | 用途 |
|---|---|---|
| A | 1–3 分鐘台灣中文單人 | basic smoke |
| B | 2–5 分鐘中英文 code-switching | language detection |
| C | 含 SPECIFIQUE / OGSTM / 客戶名 | Custom Vocabulary |
| D | 兩人以上 | speaker / timestamp |
| E | 約 13 分鐘 | gcloud boundary |
| F | 15–16 分鐘 | gcloud forced split |
| G | 31 分鐘以上 | segmentation / recovery / merge |

最好有人工校對稿。

## 20.1 AI Studio Regression First

先測：

```text
Provider: Google AI Studio
Model: Gemini 3.7 Flash
```

必須先 PASS，再測新模型。

確認：

- general generateContent 正常
- 原 Prompt 正常
- 台灣繁體輸出正常
- 原 fallback 行為正常

## 20.2 AI Studio Gemini 3.5 Transcribe

設定：

```text
Provider: Google AI Studio
Model: Gemini 3.5 Transcribe Preview
Mode: Verbatim
Language: Auto
Speaker: OFF
Word timestamps: OFF
JSON: OFF
```

必驗：

- Interactions API，而非 generateContent
- Files API upload
- transcript 正常
- 台灣繁體
- remote file cleanup

再測：

```text
Custom Vocabulary
Smart Mode
Speaker ON
Word timestamps ON
JSON ON
31+ minute recording
```

## 20.3 gcloud Login / Project

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud auth print-access-token >/dev/null && echo OK
gcloud services enable aiplatform.googleapis.com
```

如果使用 GCS：

```bash
gcloud services enable storage.googleapis.com
```

## 20.4 Vertex Regression First

先測：

```text
Provider: Google Cloud Vertex AI
Model: Gemini 3.7 Flash
```

確認原本 Vertex generateContent 正常。

## 20.5 gcloud Gemini 3.5 Transcribe Preview

設定：

```text
Provider: Google Cloud Vertex AI
Model: Gemini 3.5 Transcribe Preview
Mode: Verbatim
Language: Auto
```

UI 應顯示：

```text
Effective Location: global
Segment safety limit: 14 min
```

必驗：

- preview model ID 正確
- v1beta1 contract
- `audioTranscriptionConfig`
- 不送 general systemInstruction / prompt
- 13 min = 1 segment
- 15–16 min = 2 segments
- 31 min = 3 segments
- GCS / inline 路徑至少一條成功
- remote GCS cleanup

## 20.6 Summary

開：

```text
附加內容摘要 = ON
摘要模型 = Gemini 3.7 Flash
```

確認：

- 每段只用 Transcribe model
- merge 後只做一次 summary call
- summary failure 不損失 transcript

---

# 21. Acceptance Criteria / Agent 最終任務

本地 Agent 不應只回覆「build successful」。

完成後必須輸出一份測試報告，格式如下。

## A. Environment

```text
Mac model / architecture:
macOS:
Xcode / Swift:
ffmpeg:
OpenCC:
gcloud:
Branch:
HEAD commit:
```

## B. Automated Tests

```text
scripts/run-checks.sh: PASS / FAIL
swift test: PASS / FAIL
XCTest count:
Failures:
build-app.sh: PASS / FAIL
verify-release.sh: PASS / FAIL
```

若 FAIL，附：

```text
exact command
first meaningful error
relevant log excerpt
suspected root cause
whether code was modified
```

## C. AI Studio Live Tests

| Test | Result | Evidence / Notes |
|---|---|---|
| Gemini 3.7 regression | PASS/FAIL | |
| 3.5 basic Verbatim | PASS/FAIL | |
| Custom Vocabulary | PASS/FAIL | |
| Smart Mode | PASS/FAIL | |
| Speaker diarization | PASS/FAIL | |
| Word timestamps | PASS/FAIL | |
| JSON sidecar | PASS/FAIL | |
| 31+ min segmentation | PASS/FAIL | |
| Files API cleanup | PASS/FAIL | |

## D. Google Cloud Live Tests

| Test | Result | Evidence / Notes |
|---|---|---|
| Vertex 3.7 regression | PASS/FAIL | |
| Transcribe Preview entitlement | PASS/FAIL | |
| Basic Verbatim | PASS/FAIL | |
| Smart Mode | PASS/FAIL | |
| 13 min boundary | PASS/FAIL | |
| 15–16 min split | PASS/FAIL | |
| 31 min split | PASS/FAIL | |
| GCS or inline transport | PASS/FAIL | |
| Remote cleanup | PASS/FAIL | |
| Full transcript + one summary | PASS/FAIL | |

## E. Reliability

| Test | Result |
|---|---|
| cancel after first completed segment | PASS/FAIL |
| recovery contains completed text only | PASS/FAIL |
| no recovery MP3 | PASS/FAIL |
| mid-segment failure does not create final TXT | PASS/FAIL |
| retry does not re-upload | PASS/FAIL |
| API key absent from JSON/log | PASS/FAIL |
| Bearer token absent from JSON/log | PASS/FAIL |

## F. Quality Comparison

至少使用同一份音訊比較：

```text
Gemini 3.7 Flash
AI Studio Gemini 3.5 Transcribe
Google Cloud Gemini 3.5 Transcribe Preview（若 entitlement 可用）
Local Qwen ASR
```

記錄：

- 漏句
- 幻覺
- 專有名詞
- 中英混講
- speaker attribution
- timestamp
- segment boundary
- total processing time

## G. Final Recommendation

最後只能從以下選一項：

```text
READY TO MERGE
READY WITH KNOWN LIMITATIONS
NOT READY – FIX REQUIRED
BLOCKED BY PROVIDER ENTITLEMENT
```

並列出理由。

---

# 給本地 Agent 的執行指令

如果你是接手此 repo 的本地 Agent，請依以下原則執行：

1. **先讀本文件、`GEMINI_3_5_TRANSCRIBE_IMPLEMENTATION.md` 與 `GEMINI_3_5_TRANSCRIBE_VERIFICATION.md`。**
2. 不要重新設計架構，也不要先改程式。
3. 先確認 branch / HEAD，再跑完整 automated tests。
4. Automated tests 失敗時，先保存證據並定位 root cause，再決定是否需要建立 fix branch。
5. Automated tests PASS 後，才進行真實 API smoke tests。
6. AI Studio 與 Google Cloud 都必須先跑舊 3.7 regression，再跑 3.5 Transcribe。
7. 不要把 403 / 404 Preview entitlement 問題錯判成程式碼一定有 bug。
8. 不要把 `gemini-3.5-transcribe` 送到 `generateContent`。
9. 不要因新模型失敗而自行加入跨模型 fallback。
10. 不要輸出或保存 API Key、Bearer token、完整 Base64 audio。
11. 測試時若發現 provider contract 已與 2026-08-27 公開規格不同，先記錄實際 HTTP response 與官方文件，再提出最小修正。
12. 測完後必須依第 21 章格式交付完整 PASS/FAIL 報告，而不是只有摘要。

---

# 已知風險

1. Gemini 3.5 Transcribe / Preview 是新 API，provider schema 可能再變更。
2. Google Cloud Project 是否有 Preview entitlement 是 live gate。
3. Mandarin 公開語言代碼目前不是 `zh-TW`；台灣中文建議優先 Auto language，再由 OpenCC 輸出台灣繁體。
4. Speaker identity 僅 segment-local。
5. 真正能否取代 Gemini 3.7 Flash，必須做多場真實會議 A/B，而不是只看一份短錄音。

---

# 建議產品決策（測試前不要更改）

目前建議維持：

```text
Default cloud model: Gemini 3.7 Flash
Gemini 3.5 Transcribe: selectable Preview
Default transcription mode: Verbatim
Language: Auto
Custom Vocabulary: enabled when glossary exists
Speaker: OFF
Word timestamps: OFF
JSON: OFF
Cross-model fallback for dedicated Transcribe: OFF
```

只有在本地真實 API 驗證與多場 A/B 都通過後，再討論是否把 3.5 Transcribe 提升為預設模型。
