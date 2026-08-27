#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def replace_once(content: str, old: str, new: str, label: str) -> str:
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return content.replace(old, new, 1)


implementation = r'''# Gemini 3.7 Cloud Quality Hardening 實作報告

> Repository：`cpn565-stack/record-to-text`  
> 基準 commit：`ba3d1297cb480fc592b11046a64f2f9221bd0bd0`  
> 實作分支：`feature/gemini-3.7-quality-hardening`  
> 實作日期：2026-08-27

## 1. 決策摘要

本輪不導入 Gemini 3.5 Transcribe。以同一份台灣中文多人課程錄音做實測後，Custom Vocabulary 雖能改善部分專有名詞，但仍存在會改變內容意思的辨識錯誤，例如否定詞遺失及核心方法詞彙誤判。因此產品繼續以一般 Gemini 3.7 Flash `generateContent` 路徑為主。

本輪目標不是重新打造 Cloud backend，而是把 `ba3d12` 已可用的 3.7 路徑做成：

- 可知道實際由哪個模型完成。
- 可量測 token、thinking 與 API latency。
- 預設不暗中切換模型。
- 長錄音較不容易在句中硬切。
- Cloud 最終輸出真正保證台灣繁體。
- 失敗後可沿用已完成片段，而不是整份重跑。

## 2. 已完成範圍

### 2.1 Cloud 模型可追溯性

新增：

- `CloudTranscriptionMetadata`
- `CloudUsageMetadata`
- `CloudTranscriptionResult`
- `GeminiResponseMetadataParser`

每個 Cloud segment 可保存：

```text
requestedModelID
effectiveModelID
modelVersion
responseID
retryCount
fallbackReason
thinkingLevel
latencySeconds
promptTokenCount
cachedContentTokenCount
candidatesTokenCount
thoughtsTokenCount
totalTokenCount
serviceTier
```

這些資料會進入 segment manifest、job ledger 與 recent job summary。UI 顯示要求模型與實際模型；若長錄音內有不同實際模型，不再用一個模糊名稱掩蓋。

### 2.2 Thinking Level

新增設定：

```text
low
medium
high
```

預設為 `medium`。設定會在工作加入佇列時寫入 Job Snapshot，避免排隊後修改設定影響已建立的工作。

Gemini 3.7 request 使用：

```json
{
  "generationConfig": {
    "maxOutputTokens": 16384,
    "thinkingConfig": {
      "thinkingLevel": "medium"
    }
  }
}
```

只有支援此欄位的 3.7 路徑才送出 thinking level；fallback 至 3.6 時不假設相同 contract。

### 2.3 Cloud Output Token

AI Studio 與 Vertex 的逐段 transcription output 上限由：

```text
8192
```

提高為：

```text
16384
```

`MAX_TOKENS` 仍維持 fail-closed：不把截斷稿當成成功稿。

### 2.4 Fallback Policy

新增：

```text
CloudFallbackPolicy.disabled
CloudFallbackPolicy.flashOnly
```

預設：

```text
disabled
```

行為：

- 預設只重試原本選定模型。
- 不再因 safety / prohibited content 自動切到 Pro。
- 不再自動形成 `3.7 → 3.6 → 3.1 Pro` 鏈。
- 使用者明確選 `flashOnly` 時，3.7 在 retry budget 用完且仍是 transient failure，才可改用 3.6 Flash。
- fallback 必須寫入 structured metadata 與 UI warning。

### 2.5 Retry / Quota

共用 retry policy 改為：

- 最多 4 次同模型嘗試。
- 指數退避。
- 有界 jitter。
- 支援 `Retry-After`。
- 支援 `google.rpc.RetryInfo.retryDelay`。
- retryable status：408、429、500、502、503、504。
- 解析 daily quota markers；當日配額用完時不做沒有意義的短時間 retry。

取消仍會立即向外傳遞，不會因取消而再送 fallback request。

### 2.6 Cloud 最終 OpenCC

Cloud pipeline 現在是：

```text
ffprobe
→ ffmpeg 壓縮／分段
→ Gemini transcription
→ merge
→ optional Vertex summary
→ OpenCC s2twp
→ final OutputContractValidator
→ atomic TXT
```

因此「台灣繁體」不再只靠 Prompt。AI Studio 與 Vertex 的環境檢查都會要求可執行的 OpenCC。

### 2.7 誠實進度

Google Cloud API 沒有可靠的生成百分比，因此移除每 2 秒自行增加 3% 的假進度。

目前 UI：

- 音訊壓縮：顯示可量測進度。
- 等待 Gemini：顯示 indeterminate spinner。
- 多段工作：顯示目前第 N / M 段。
- 每 30 秒記錄實際等待時間。
- segment 完成後才跳到該段完成 floor。

### 2.8 Silence-aware Cloud Segmentation

20 分鐘仍是硬上限，但切點策略改為：

1. 使用 ffmpeg `silencedetect` 分析來源範圍。
2. 在每個名義 20 分鐘邊界前 30 秒尋找靜音。
3. 靜音至少 0.35 秒。
4. 選最接近上限、但不超過上限的合格靜音 midpoint。
5. 找不到或分析失敗時，安全退回精確 20 分鐘硬切。

不使用 overlap，因此不需以 fuzzy matching 刪除可能重複的真實內容。

### 2.9 Cloud Checkpoint Resume

失敗／取消後，如果 `Temp-Recovery` 已有完成片段，UI 提供：

```text
從已完成片段續跑
```

續跑前驗證：

- recovery directory 必須在 App 管理的 `Temp-Recovery/<UUID>`。
- `recovery.json` 必須是 schema 2+ 的 `cloudCheckpoint`。
- 原始來源路徑一致。
- source slice 一致。
- backend 一致。
- source duration 一致。
- maximum segment duration 一致。
- segment index、count、時間邊界連續。
- reusable segment 必須是 completed / completedWithGaps。
- completed event 必須恰好一次。
- TXT 必須存在、非空，且位於受管 recovery segments directory。

通過後：

- 已完成片段複製到新工作目錄。
- 不重新壓縮。
- 不重新上傳。
- 不重新計費轉錄。
- 未完成片段才重新處理。
- 仍執行完整 manifest gate、merge、OpenCC 與正式輸出驗證。

### 2.10 gcloud 認證回歸測試

新增可控 fake gcloud fixtures，涵蓋：

- executable 不存在。
- access token cache。
- `forceRefresh`。
- `invalidateToken`。
- active project 解析與 trim。
- 空 token。
- `(unset)` project。
- non-zero exit status 與 stderr。

Vertex 既有 401 refresh path 及 request tests繼續保留。

## 3. 主要檔案

### Core

```text
Sources/RecordToTextCore/CloudTranscriptionModels.swift
Sources/RecordToTextCore/GeminiResponseMetadataParser.swift
Sources/RecordToTextCore/GeminiTransportHelper.swift
Sources/RecordToTextCore/GoogleAIStudioBackend.swift
Sources/RecordToTextCore/VertexAIGeminiBackend.swift
Sources/RecordToTextCore/TranscriptionEngine.swift
Sources/RecordToTextCore/SilenceAwareSegmentation.swift
Sources/RecordToTextCore/CloudResumeCheckpoint.swift
Sources/RecordToTextCore/RuntimeEnvironment.swift
Sources/RecordToTextCore/Models.swift
Sources/RecordToTextCore/AudioSegmentation.swift
```

### App

```text
Sources/RecordToTextApp/AppViewModel.swift
Sources/RecordToTextApp/SettingsView.swift
Sources/RecordToTextApp/MainView.swift
```

### Tests

```text
Tests/RecordToTextCoreTests/CloudTranscriptionModelsTests.swift
Tests/RecordToTextCoreTests/GeminiBackendObservabilityTests.swift
Tests/RecordToTextCoreTests/CloudPipelinePresentationTests.swift
Tests/RecordToTextCoreTests/SilenceAwareSegmentationTests.swift
Tests/RecordToTextCoreTests/CloudResumeCheckpointTests.swift
Tests/RecordToTextCoreTests/GCloudAuthServiceTests.swift
```

## 4. 實作 checkpoints

```text
c2720d3  cloud provenance models / migration
ed4813f  backend observability / 16K / thinking / retry / fallback
b536f8f  pipeline provenance / OpenCC / honest progress / UI
9c532eb  silence-aware segmentation
9f72685  cloud checkpoint resume
acb7b9f  expanded gcloud auth tests
```

以上 commit 都位於 `feature/gemini-3.7-quality-hardening`，最終以 branch HEAD 為準。

## 5. 預設產品配置

```text
Default model: Gemini 3.7 Flash
Thinking level: medium
Automatic fallback: disabled
Silence-aware segmentation: enabled
Cloud max output tokens: 16384
Final Taiwan Traditional conversion: OpenCC s2twp
Checkpoint resume: user-initiated only
```

## 6. 保留的安全邊界

- API Key 不進 settings / job ledger / log。
- Bearer token 不落盤。
- Remote audio upload 仍是 upload-once。
- retry / fallback 共用同一個 remote reference。
- remote audio 在 success / error / cancel 後 cleanup。
- incomplete response / missing STOP / empty output fail closed。
- 中途失敗不產生正式 final TXT。
- recovery 不保存 Cloud MP3。
- resume 不信任任意外部 TXT 或任意路徑。

## 7. 尚未由自動測試證明

- 使用者實際 AI Studio Key 的 3.7 live contract。
- 使用者 GCP Project / IAM / quota / GCS 的 live contract。
- 同一批真實台灣中文錄音的 medium vs low 品質與成本差異。
- silence-aware boundary 在真實課程錄音上的漏字改善幅度。
- Cloud checkpoint resume 的實際遠端計費／上傳次數觀察。

這些需依 `GEMINI_3_7_QUALITY_HARDENING_VERIFICATION.md` 在本機執行。
'''
write(
    "docs/GEMINI_3_7_QUALITY_HARDENING_IMPLEMENTATION.md",
    implementation,
)

verification = r'''# Gemini 3.7 Quality Hardening 本機部署與驗證手冊

> Branch：`feature/gemini-3.7-quality-hardening`  
> Base：`ba3d1297cb480fc592b11046a64f2f9221bd0bd0`

## 1. 本地 Agent 指令

請先完整閱讀：

```text
docs/GEMINI_3_7_QUALITY_HARDENING_IMPLEMENTATION.md
docs/GEMINI_3_7_QUALITY_HARDENING_VERIFICATION.md
HANDOFF.md
```

執行原則：

1. 先驗證，不先改程式。
2. 保存完整 command / log / branch / commit。
3. Automated tests 通過後才執行真實 API。
4. AI Studio 與 Vertex 都先測 3.7 regression。
5. 不能把 API entitlement、quota 或 IAM 錯誤直接判為程式 bug。
6. 不得輸出 API Key、Bearer token、完整 Base64 音訊。
7. 若需要修正，另開 fix branch。

## 2. 取得程式

```bash
git fetch origin
git switch feature/gemini-3.7-quality-hardening
git pull --ff-only origin feature/gemini-3.7-quality-hardening

git branch --show-current
git rev-parse HEAD
git log -10 --oneline
```

確認 branch 不是 3.5 Transcribe 分支。

## 3. 環境

```bash
brew install ffmpeg opencc
which ffmpeg ffprobe opencc
ffmpeg -version | head -1
opencc --version
```

Vertex 另需：

```bash
gcloud --version
gcloud auth login
gcloud auth print-access-token >/dev/null && echo "token OK"
gcloud config get-value project
```

第一次建置建議：

```bash
rm -rf .build dist
```

不要任意刪除：

```text
~/Library/Application Support/record-to-text/
```

## 4. Automated Tests

```bash
REQUIRE_XCTEST=1 scripts/run-checks.sh
swift test
ADHOC_SIGN=0 scripts/build-app.sh
ALLOW_UNSIGNED=1 CHECK_APP_SIZE=0 \
  scripts/verify-release.sh dist/record-to-text.app
```

啟動：

```bash
open dist/record-to-text.app
```

記錄：

```text
macOS
Mac architecture
Xcode / Swift
ffmpeg
OpenCC
gcloud
branch
HEAD
XCTest count
self-test count
```

## 5. 設定預期

Cloud backend 應看到：

```text
Gemini 3.7 思考強度
- Low
- Medium
- High

模型不可用時
- 不自動切換模型（推薦）
- 3.7 忙碌時允許改用 3.6 Flash

在 20 分鐘上限前優先尋找靜音切點
雲端單段輸出上限：16,384 tokens
```

預設：

```text
Thinking: Medium
Fallback: Disabled
Silence-aware segmentation: ON
```

## 6. Google AI Studio Live Test

### 6.1 3.7 Regression

```text
Backend: Google AI Studio
Model: Gemini 3.7 Flash
Thinking: Medium
Fallback: Disabled
Silence-aware: ON
```

使用 1–3 分鐘台灣中文音檔，確認：

- Files API upload。
- `generateContent` 3.7。
- 正常 TXT。
- 完成後 remote file DELETE。
- job log 有實際模型。
- 若 response 提供 modelVersion / responseId / usage，UI 與 ledger 可看到。
- final TXT 經 OpenCC，無簡繁混用。

### 6.2 Medium vs Low A/B

使用同一音檔、同一詞庫、同一切片：

```text
A: Thinking Medium
B: Thinking Low
```

比較：

- 漏句。
- 否定詞。
- 專有名詞。
- 中英混講。
- 幻覺。
- total processing time。
- thoughtsTokenCount。
- totalTokenCount。

不要只比文字長度。

### 6.3 Fallback Disabled

預設情況下，即使 3.7 transient retries 用完：

- 工作失敗。
- 保留已完成 checkpoint。
- 不得出現「實際模型 3.6」。
- 不得自動送 3.1 Pro。

### 6.4 Explicit Flash Fallback

將 policy 改為允許 3.6。只有在可重現 3.7 transient failure 時測：

- 3.7 先耗盡同模型 retry。
- 才送 3.6。
- segment log 與 metadata 清楚顯示 requested 3.7 / effective 3.6。
- final recent job 不得仍只顯示 3.7。

## 7. Vertex Live Test

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com
```

若使用 GCS：

```bash
gcloud services enable storage.googleapis.com
```

App：

```text
Backend: Google Cloud Vertex AI
Model: Gemini 3.7 Flash
Location: project 可用 location
Thinking: Medium
Fallback: Disabled
```

確認：

- 取得 project / token。
- 401 時 force refresh 一次。
- GCS 或 inline 路徑成功。
- GCS object 在 success / error / cancel 後刪除。
- model/version/response/token metadata 可保存。
- final TXT 經 OpenCC。

## 8. Silence-aware Segmentation

準備 31 分鐘以上、接近 20 分鐘處有自然停頓的錄音。

確認 log：

```text
正在分析 20 分鐘上限前的靜音位置
已採用靜音感知切點（秒）：...
```

或：

```text
未找到合適靜音切點，維持精確 20 分鐘硬切
```

驗證：

- 每段都不超過 1,200 秒。
- 切點位於名義邊界前 30 秒內。
- 靜音至少約 0.35 秒。
- 找不到時仍能正常硬切。
- segment manifest 的 start/end 連續無 gap/overlap。
- 比較切點前後完整句子是否少漏字。

## 9. Honest Progress

等待 Gemini 時應看到 spinner 與：

```text
等待 Gemini 回應 · 第 N／M 段（無虛構百分比）
```

不可每 2 秒自行增加百分比。

音訊壓縮及已完成 segment floor 仍可顯示真實／可驗證進度。

## 10. Cloud Checkpoint Resume

### 10.1 建立 checkpoint

使用至少 2 段的長音檔：

1. 等第 1 段完成。
2. 在第 2 段處理中取消，或製造 transient failure。
3. 確認 `Temp-Recovery/<jobID>` 有：
   - `recovery.json`
   - `segment-manifest.json`
   - `partial-transcript.txt`
   - `segments/segment-0001.txt`
4. 確認沒有 MP3。

### 10.2 續跑

按：

```text
從已完成片段續跑
```

確認 log：

```text
已驗證雲端復原檢查點
第 1/N 段沿用已完成檢查點
不重新壓縮、上傳或計費轉錄
```

確認：

- 已完成段不再出現新的 upload / generate request。
- 未完成段正常重跑。
- final merge 包含舊段與新段，順序正確。
- final OpenCC / output gate 照常執行。
- 任意外部目錄、改過 source、不同 backend 或不連續 manifest 會拒絕續跑。

## 11. Quota / Retry

使用 mock tests 或可控錯誤驗證：

```text
408, 429, 500, 502, 503, 504 → transient candidate
400, 401(after Vertex refresh), 403 → fail closed
```

確認：

- exponential backoff。
- bounded jitter。
- `Retry-After` 優先。
- `google.rpc.RetryInfo.retryDelay` 可解析。
- daily quota 不做無效短 retry。
- cancellation 不觸發更多 request。

## 12. Security / Cleanup

搜尋 App 資料：

```bash
ROOT="$HOME/Library/Application Support/record-to-text"
grep -R "AIza" "$ROOT" 2>/dev/null || true
grep -R "Bearer " "$ROOT" 2>/dev/null || true
```

預期：

- settings / ledger / logs 無 API Key。
- 無 Bearer token。
- recovery 無 Cloud MP3。
- request temporary files完成後刪除。
- remote Files API / GCS temporary audio 完成後刪除。

## 13. 最終報告格式

### Environment

```text
Mac / architecture:
macOS:
Xcode / Swift:
ffmpeg:
OpenCC:
gcloud:
Branch:
HEAD:
```

### Automated

| Test | Result | Notes |
|---|---|---|
| run-checks | PASS/FAIL | |
| XCTest | PASS/FAIL | count |
| App build | PASS/FAIL | |
| bundle verify | PASS/FAIL | |

### AI Studio

| Test | Result | Notes |
|---|---|---|
| 3.7 Medium regression | | |
| 3.7 Low A/B | | |
| provenance / usage | | |
| fallback disabled | | |
| explicit 3.6 fallback | | |
| remote cleanup | | |
| OpenCC final output | | |

### Vertex

| Test | Result | Notes |
|---|---|---|
| 3.7 regression | | |
| token / project / 401 refresh | | |
| GCS or inline | | |
| remote cleanup | | |
| summary once | | |
| OpenCC final output | | |

### Long Audio

| Test | Result | Notes |
|---|---|---|
| silence-aware boundary | | |
| no gap / overlap | | |
| honest progress | | |
| cancel checkpoint | | |
| resume skips completed segments | | |
| final merge | | |

### Recommendation

只能選一項：

```text
READY TO MERGE
READY WITH KNOWN LIMITATIONS
NOT READY – FIX REQUIRED
BLOCKED BY PROVIDER / IAM / QUOTA
```
'''
write(
    "docs/GEMINI_3_7_QUALITY_HARDENING_VERIFICATION.md",
    verification,
)

transport = r'''# Gemini Cloud Transport 與 Quality Hardening

狀態：**已實作**  
更新：2026-08-27  
基準：`ba3d1297cb480fc592b11046a64f2f9221bd0bd0`  
目前分支：`feature/gemini-3.7-quality-hardening`

## 已完成的傳輸層

- GenerateContent request 以暫存檔串流 upload，不使用大型 in-memory `httpBody`。
- POSIX 40 / EMSGSIZE 會改用新的 ephemeral session 重試一次。
- AI Studio 預設 Files API，上傳一次後讓 retry / fallback 共用同一 URI。
- Vertex 有 GCS Bucket 時使用 `gs://` reference；未設定且片段不超過 inline limit 時使用 inline request。
- 成功、失敗、取消後都等待 remote cleanup。
- Vertex 401 會 refresh access token 一次。
- API Key 僅 Keychain；token 不落盤。

## 已完成的 Quality Hardening

- Cloud transcription output 上限 16,384 tokens。
- Gemini 3.7 thinking level 可選 low / medium / high，預設 medium。
- fallback 預設關閉；可明確允許 3.7 → 3.6 Flash。
- 不再自動 fallback 到 Pro。
- 每段保存 requested / effective model、modelVersion、responseId、usage、thinking、latency、retry、fallback reason。
- exponential backoff + jitter。
- 解析 Retry-After / RetryInfo。
- 區分 transient rate limit 與 daily quota。
- 20 分鐘上限前優先使用靜音切點。
- Cloud merge 後強制 OpenCC s2twp。
- 等待 Gemini 時顯示 indeterminate progress，不捏造百分比。
- 失敗後可驗證並重用已完成 Cloud checkpoints。

完整設計與驗證：

```text
docs/GEMINI_3_7_QUALITY_HARDENING_IMPLEMENTATION.md
docs/GEMINI_3_7_QUALITY_HARDENING_VERIFICATION.md
```

## 保留的 fail-closed 行為

- `finishReason` 必須為 STOP。
- MAX_TOKENS 不交付截斷稿。
- 空白／invalid JSON／Prompt echo 不交付。
- 任一必需 segment 缺漏，不建立正式 TXT。
- cleanup warning 不覆蓋已成功的正式逐字稿。

## 尚待真實環境驗證

- AI Studio / Vertex live API。
- 使用者 Project IAM / quota。
- medium vs low 的真實品質／成本。
- silence-aware boundary 的人工聽檢。
- resume 時實際 remote request / billing 次數。
'''
write("docs/gemini-cloud-transport-hardening.md", transport)

next_steps = r'''# 下一次接續

更新日期：2026-08-27  
目前基準：`feature/gemini-3.7-quality-hardening`  
原始基準：`ba3d1297cb480fc592b11046a64f2f9221bd0bd0`

## 一句話狀態

Gemini 3.7 Cloud 主路徑已完成 quality hardening：模型可追溯、16K output、thinking level、fallback 預設關閉、retry/配額分類、Cloud OpenCC、誠實進度、靜音感知切片及 checkpoint resume。自動化 build/test 已通過；下一個 gate 是使用者本機的真實 API 與錄音品質驗證。

## 已完成

### Cloud

- AI Studio Files API / Vertex GCS 或 inline。
- upload-once / retry same reference。
- cancellation-safe remote cleanup。
- requested / effective model provenance。
- modelVersion / responseId / usage / latency。
- 16,384 output tokens。
- thinking low / medium / high。
- fallback default disabled；opt-in 3.7 → 3.6 only。
- exponential+jitter retry；Retry-After / RetryInfo。
- rate limit / daily quota 分類。
- 20 分鐘上限前 30 秒找靜音切點。
- merge 後 OpenCC s2twp。
- indeterminate Gemini waiting progress。
- Cloud checkpoint resume，只重跑未完成片段。

### Local Qwen

- 20 分 coordinator segments。
- 120 秒 helper chunks。
- 16,384 max tokens。
- 遞迴半切與明確缺口標記。
- persistent helper / model cache。
- Prompt echo fail-closed。

### App / Reliability

- Keychain credential migration。
- durable job ledger。
- recovery scanner。
- process group cancellation / timeout / inactivity watchdog。
- disk checks、atomic output、BOM/NUL/Prompt echo gate。
- manual TXT merge。
- App bundle build / verify scripts。

## 近期優先順序

### P0 — 真實 API 與品質驗證

1. AI Studio 3.7 Medium regression。
2. AI Studio 3.7 Medium vs Low A/B。
3. Vertex 3.7 live auth / IAM / quota / GCS。
4. 31／65／120 分鐘長錄音 soak。
5. 人工檢查 silence boundary 前後漏字／重複。
6. 實測 checkpoint resume 是否沒有重送已完成段。
7. 檢查 Files API / GCS cleanup。
8. 驗證 modelVersion / token / thinking metadata。

驗證文件：

```text
docs/GEMINI_3_7_QUALITY_HARDENING_VERIFICATION.md
```

### P1 — 依實測結果調整

- 決定 Gemini 3.7 transcription 預設 thinking：Medium 或 Low。
- 依真實錄音調整 silence threshold / search window；沒有證據前不要加入 overlap fuzzy dedup。
- 若 provider response schema 有變化，集中修改 metadata parser。
- 若 resume live test 發現 remote request 重送，先修正再 merge。
- 決定是否保留 UI 中的 explicit 3.6 fallback 選項。

### P2 — 產品功能

- PD-015 GitHub Releases 自動檢查更新。
- 更完整的 quality benchmark / golden audio harness。
- 匯出 anonymized job metrics（不含正文或詞庫）。
- 可選 sidecar diagnostics report。

### P3 — 發佈條件

- App 管理 Runtime installer。
- Model installer / digest 完整信任鏈。
- Developer ID、notarization、Stable DMG。
- 乾淨 Mac / 新帳號首次啟動。
- Intel 真機與 Universal 2。

## 已明確放棄／暫緩

- Gemini 3.5 Transcribe Preview：台灣中文多人課程 A/B 中，加入 glossary 後仍有語意反轉與核心詞誤判；不進本分支。
- 自動 3.7 → 3.6 → Pro fallback chain。
- Cloud 等待期間捏造進度百分比。
- 未驗證即把 Low thinking 設成預設。
- 未驗證即加入 overlap + fuzzy dedup。

## 交接文件

```text
HANDOFF.md
docs/GEMINI_3_7_QUALITY_HARDENING_IMPLEMENTATION.md
docs/GEMINI_3_7_QUALITY_HARDENING_VERIFICATION.md
docs/gemini-cloud-transport-hardening.md
CHANGELOG.md
```
'''
write("docs/NEXT_STEPS.md", next_steps)

handoff = r'''# record-to-text 交班單

- 交班日期：2026-08-27
- Repository：`cpn565-stack/record-to-text`
- 分支：`feature/gemini-3.7-quality-hardening`
- 原始基準：`ba3d1297cb480fc592b11046a64f2f9221bd0bd0`
- 狀態：Cloud quality hardening 已完成自動化驗證；真實 API / 錄音品質待本機驗證

## 一句話狀態

Gemini 3.7 Flash 保留為主要 Cloud ASR。現在每段可追蹤實際模型與 token，預設不自動 fallback，長音使用靜音感知 20 分鐘切片，完成後強制 OpenCC；失敗後可只續跑未完成片段。

## 預設配置

```text
Model: Gemini 3.7 Flash
Thinking: Medium
Fallback: Disabled
Silence-aware segmentation: ON
Cloud max output: 16,384 tokens
Final conversion: OpenCC s2twp
Resume: explicit user action
```

## 已完成 checkpoints

```text
c2720d3  Cloud provenance data model / migration
ed4813f  Backend observability / retry / fallback / 16K / thinking
b536f8f  Pipeline provenance / OpenCC / honest progress / UI
9c532eb  Silence-aware segmentation
9f72685  Cloud checkpoint resume
acb7b9f  gcloud auth regression tests
```

最終以 branch HEAD 為準。

## 核心安全邊界

- API Key 只存 Keychain。
- Bearer token 不落盤。
- Cloud audio upload-once。
- retry / fallback 共用同一 remote reference。
- remote cleanup 在 success / failure / cancel 都執行。
- incomplete / MAX_TOKENS / empty / Prompt echo fail closed。
- 部分完成不產生 final TXT。
- recovery 不保留 Cloud MP3。
- resume 只信任受管目錄與完整驗證過的 manifest / TXT。

## 接手順序

1. 讀：
   - `docs/GEMINI_3_7_QUALITY_HARDENING_IMPLEMENTATION.md`
   - `docs/GEMINI_3_7_QUALITY_HARDENING_VERIFICATION.md`
2. 拉 branch HEAD。
3. 跑完整 automated tests / App build / bundle verify。
4. 先測 AI Studio 3.7 Medium regression。
5. 再做 Medium vs Low A/B。
6. 測 Vertex auth / GCS / cleanup。
7. 測 31+ 分鐘 silence boundary。
8. 測 cancel/failure checkpoint resume。
9. 依驗證文件輸出 READY / NOT READY 報告。

## 不要做

- 不要重新加入 Gemini 3.5 Transcribe。
- 不要把 Cloud output token 改回 8,192。
- 不要恢復自動 Pro fallback。
- 不要把等待 spinner 改回假百分比。
- 不要讓 resume 信任任意路徑或外部 TXT。
- 不要在沒有真實 A/B 前把 Low 設為預設。

## 仍未完成

- 真實使用者 credential 的 live smoke test。
- 真實錄音 Medium vs Low 品質結論。
- Stable Runtime / Developer ID / notarization / release。
- Intel 真機。
- 自動檢查更新。
'''
write("HANDOFF.md", handoff)

# README targeted synchronization.
readme = read("README.md")
readme = replace_once(
    readme,
    "- **Google AI Studio**：在設定中儲存 Gemini API Key。音訊工具由 App 或本機環境提供。\n- **Vertex AI**：需可用的 `gcloud` 登入狀態、GCP 專案與有權限的 Vertex AI 區域。\n",
    "- **Google AI Studio**：在設定中儲存 Gemini API Key；需要 ffmpeg／ffprobe 與 OpenCC。\n- **Vertex AI**：需 ffmpeg／ffprobe、OpenCC、可用的 `gcloud` 登入狀態、GCP 專案與有權限的 Vertex AI 區域。\n",
    "README cloud requirements",
)
readme = replace_once(
    readme,
    "在 App 內：**環境檢查**（右上角盾牌 icon）只會檢查當前後端所需元件。雲端模式需 ffmpeg／ffprobe 及對應憑證；本機 Qwen 才需 Python、OpenCC 與 helper。\n",
    "在 App 內：**環境檢查**（右上角盾牌 icon）只會檢查當前後端所需元件。雲端模式需 ffmpeg／ffprobe、OpenCC 及對應憑證；本機 Qwen 另需 Python 與 helper。\n",
    "README environment summary",
)
readme = replace_once(
    readme,
    "- 雲端管線：`ffprobe → ffmpeg 壓縮／分段 → Gemini API → 原子寫入 TXT`。\n- 超過 **20 分鐘**：coordinator 切成編號片段、逐段獨立 ASR（預設 token 預算 16384）；全部通過 manifest gate 後才交付正式逐字稿。\n- 雲端分段工作失敗或取消時，若已有完成片段，`Temp-Recovery` 會只保留部分 TXT、manifest 與最小 metadata（不保留 MP3），供人工取回。這不是自動斷點續跑；重新加入原始錄音會從頭轉錄。若還沒有任何完成片段，就不會誤稱有部分稿可取回。\n",
    "- 雲端管線：`ffprobe → ffmpeg 壓縮／分段 → Gemini API → merge → OpenCC s2twp → 原子寫入 TXT`。\n- Cloud 每段保存 requested／effective model、model version、response ID、token usage、thinking、latency、retry 與 fallback reason。\n- Cloud transcription 單段 output 上限為 **16,384 tokens**；Gemini 3.7 thinking 可選 Low／Medium／High，預設 Medium。\n- 自動模型 fallback 預設關閉；明確開啟時只允許 3.7 → 3.6 Flash，不自動切到 Pro。\n- 超過 **20 分鐘**：coordinator 優先在上限前 30 秒的自然靜音切段；找不到時才精確硬切。全部通過 manifest gate 後才交付正式逐字稿。\n- 雲端分段工作失敗或取消時，若已有完成片段，`Temp-Recovery` 只保留部分 TXT、manifest 與最小 metadata（不保留 MP3）。使用者可從已完成片段續跑，通過驗證的片段不再壓縮、上傳或計費轉錄。\n- 等待 Gemini 時使用不確定進度與實際耗時，不捏造 server-side 百分比。\n",
    "README cloud feature block",
)
readme = readme.replace(
    "- 20 項 executable self-test。",
    "- executable self-tests。",
)
readme = replace_once(
    readme,
    "- [下一次接續](docs/NEXT_STEPS.md)\n- [交班單](HANDOFF.md)\n",
    "- [Gemini 3.7 Quality Hardening 實作](docs/GEMINI_3_7_QUALITY_HARDENING_IMPLEMENTATION.md)\n- [Gemini 3.7 本機驗證](docs/GEMINI_3_7_QUALITY_HARDENING_VERIFICATION.md)\n- [下一次接續](docs/NEXT_STEPS.md)\n- [交班單](HANDOFF.md)\n",
    "README docs links",
)
write("README.md", readme)

# CHANGELOG additions.
changelog = read("CHANGELOG.md")
changelog = replace_once(
    changelog,
    "### Added\n\n",
    "### Added\n\n- Gemini 3.7 Cloud quality hardening：每段記錄 requested／effective model、modelVersion、responseId、usage、thinking、latency、retry 與 fallback reason。\n- Gemini 3.7 thinking level（Low／Medium／High，預設 Medium）與 Cloud fallback policy（預設關閉；可選 3.7 → 3.6 Flash）。\n- Cloud transcription output 上限提高至 16,384 tokens；合併後強制 OpenCC `s2twp` 與 final output validation。\n- Cloud retry 改為 exponential backoff + jitter，支援 `Retry-After`／`RetryInfo`，並區分 rate limit 與 daily quota。\n- 20 分鐘上限前的 silence-aware segmentation；沒有合格靜音時安全退回硬切。\n- Cloud checkpoint resume：驗證受管 recovery 後，只重跑未完成片段。\n- Cloud waiting UI 改為 indeterminate progress 與真實耗時，不再捏造 API 百分比。\n- 擴充 gcloud token cache、force refresh、invalidate、project、empty output 與 exit status 測試。\n\n",
    "CHANGELOG quality additions",
)
write("CHANGELOG.md", changelog)

# Product decision summary + appended accepted decisions.
pd = read("docs/product-decisions.md")
pd = replace_once(
    pd,
    "| PD-015 | App 自動檢查更新：預設約每 7 天一次，安靜檢查、有新版再提示 | Accepted（待實作） |\n",
    "| PD-015 | App 自動檢查更新：預設約每 7 天一次，安靜檢查、有新版再提示 | Accepted（待實作） |\n| PD-016 | Cloud 每段必須保存 requested／effective model 與可用的 usage metadata | Accepted |\n| PD-017 | Cloud 自動 fallback 預設關閉；只允許使用者明確開啟 3.7 → 3.6 Flash | Accepted |\n| PD-018 | Cloud 最終輸出必須經 OpenCC s2twp；Prompt 不能單獨作為繁體保證 | Accepted |\n| PD-019 | 20 分鐘仍為硬上限，切點優先使用上限前的合格靜音 | Accepted |\n| PD-020 | Cloud checkpoint 續跑只信任受管目錄、相容 manifest 與非空完成 TXT | Accepted |\n| PD-021 | Gemini 3.5 Transcribe Preview 不進主線；台灣中文 A/B 未達語意忠實度門檻 | Accepted |\n",
    "product decision summary",
)
pd += r'''

## 4. 2026-08-27 Cloud Quality 決策

### PD-016：Cloud 模型可追溯

每個 Cloud segment 必須記錄 requested / effective model。Provider 有回傳時，同時保存 modelVersion、responseId、usage、thinking、latency 與 retry。最近工作不得用本機 Qwen model ID 代替 Cloud model metadata。

### PD-017：Fallback 預設關閉

Cloud 預設只重試原模型。使用者可明確允許 3.7 → 3.6 Flash；不得自動切到 Pro。實際 fallback 必須可見且可持久化。

### PD-018：台灣繁體是輸出 gate

AI Studio 與 Vertex 的最終合併稿都要在本機經 OpenCC `s2twp`，再通過 final output validator。Prompt 仍要求台灣繁體，但只作第一層指示。

### PD-019：Silence-aware 20 分鐘上限

20 分鐘是硬上限，不縮短為大量小段。切點優先選上限前 30 秒內、至少 0.35 秒靜音的 midpoint；偵測失敗或沒有合格點時回到硬切。未有證據前不加入 overlap fuzzy dedup。

### PD-020：Cloud checkpoint resume

續跑必須由使用者觸發。只重用受管 `Temp-Recovery/<UUID>/segments` 中、manifest 標為完成、completed event 恰好一次且非空的 TXT。來源、slice、backend、duration 與所有 segment boundaries 必須相容。

### PD-021：放棄 Gemini 3.5 Transcribe Preview

同一台灣中文多人課程錄音的實測中，加入 glossary 後雖改善部分專有名詞，仍出現否定詞遺失、核心詞語意改變與一般中文不穩。產品不以功能數量取代語意忠實度，因此本分支不含 3.5 Transcribe transport。
'''
write("docs/product-decisions.md", pd)

print("Updated Gemini 3.7 hardening docs and repository handoff")
