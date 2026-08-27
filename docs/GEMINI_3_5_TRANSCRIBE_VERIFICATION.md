# Gemini 3.5 Transcribe 本機與真實 API 驗證手冊

本文件適用於分支：

```text
feature/gemini-3.5-transcribe
```

目標是驗證以下四條路徑都能正確運作，且彼此不互相污染：

1. Google AI Studio `gemini-3.5-transcribe`（Interactions API）
2. Google AI Studio 一般 Gemini（既有 `generateContent`）
3. gcloud `gemini-3.5-transcribe-preview`（Agent Platform audio transcription contract）
4. gcloud 一般 Vertex Gemini（既有 `generateContent`）

> Gemini 3.5 Transcribe 目前屬於 Preview／新 API 能力。單元測試能驗證 request、response、切片與清理邏輯，但最終是否已對你的 API Key／GCP Project 開放，必須用真實憑證做 smoke test。

---

## 1. 取得分支

已經有本機 clone：

```bash
git fetch origin
git switch feature/gemini-3.5-transcribe
git pull --ff-only origin feature/gemini-3.5-transcribe
```

第一次 clone：

```bash
git clone https://github.com/cpn565-stack/record-to-text.git
cd record-to-text
git switch feature/gemini-3.5-transcribe
```

確認目前分支與 commit：

```bash
git branch --show-current
git log -1 --oneline
```

預期分支：

```text
feature/gemini-3.5-transcribe
```

---

## 2. 本機必要環境

### 2.1 macOS 與工具

建議：

- Apple Silicon Mac
- macOS 14 或更新
- 完整 Xcode，或至少可使用 SwiftPM 的 Swift toolchain
- Homebrew

安裝與確認：

```bash
brew install ffmpeg opencc
which ffmpeg ffprobe opencc
ffmpeg -version | head -1
opencc --version
```

雲端管線仍會在送出前使用 ffmpeg 壓成 16 kHz、單聲道、24 kbps MP3；回傳後會使用 OpenCC 轉成台灣繁體。

### 2.2 清除舊建置產物（建議第一次做）

```bash
rm -rf .build dist
```

不要刪除：

```text
~/Library/Application Support/record-to-text/
```

除非你確定要重設 App 的設定、工作紀錄與詞庫。

---

## 3. 編譯與自動測試

### 3.1 完整專案檢查

```bash
REQUIRE_XCTEST=1 scripts/run-checks.sh
```

預期全部通過：

- RecordToTextCore 編譯
- RecordToTextApp 編譯
- executable self-tests
- pipeline self-tests
- XCTest
- Gemini Transcribe request／response contract tests
- 舊版 settings／job ledger migration tests

### 3.2 單獨執行 XCTest

```bash
swift test
```

只跑本次新增的 contract tests：

```bash
swift test --filter GeminiTranscribe
swift test --filter GoogleAIStudioInteractionsContractTests
swift test --filter AgentPlatformTranscribeContractTests
swift test --filter DedicatedCloudSegmentPolicyTests
```

### 3.3 建立開發版 App

```bash
scripts/build-app.sh
open dist/record-to-text.app
```

若 macOS 阻擋未簽署開發版，可在 Finder 對 App 按右鍵後選「打開」，或依你原本的開發簽署流程處理。

---

## 4. 先準備測試音檔

至少準備以下素材：

| 編號 | 素材 | 用途 |
|---|---|---|
| A | 1–3 分鐘、單人台灣中文 | 基本 smoke test |
| B | 2–5 分鐘、中英文混講 | code-switching |
| C | 2–5 分鐘、含 SPECIFIQUE／OGSTM／客戶名 | Custom Vocabulary |
| D | 2–5 分鐘、兩人以上 | speaker diarization |
| E | 約 13 分鐘 | gcloud 單段邊界內 |
| F | 15–16 分鐘 | gcloud 必須切成兩段 |
| G | 31 分鐘以上 | 長音訊切片、合併、checkpoint |

建議保留一份人工校對稿，方便比較：

- 漏字／漏句
- 幻覺內容
- 專有名詞正確率
- 中英文切換
- speaker label
- timestamp 誤差
- 片段交界是否重複或缺漏

---

# 5. Google AI Studio 驗證

## 5.1 準備 API Key

在 Google AI Studio 建立 Gemini API Key。

不要把 Key 寫進 repo、設定 JSON 或 shell script。App 內請使用：

```text
設定 → Runtime → Google AI Studio → Google AI Studio API Key
```

貼上後按：

```text
儲存到 Keychain
```

再按：

```text
測試 API Key 連線
```

注意：這個按鈕主要驗證 Key 是否有效；是否已取得 `gemini-3.5-transcribe` Preview 權限，仍以實際轉錄結果為準。

---

## 5.2 一般 Gemini 回歸測試

先選：

```text
後端：Google AI Studio
模型：Gemini 3.7 Flash
```

使用音檔 A 執行一次。

驗證：

- 可完成轉錄
- 輸出 TXT 是台灣繁體
- 原有 Prompt／詞庫行為仍存在
- 不會產生 JSON sidecar
- log 顯示 `Gemini generateContent`
- 既有 3.7 → 3.6 → 3.1 Pro 的 server fallback 邏輯未被專用模型改掉

這一項先通過，再測專用 Transcribe；否則較難判斷是環境問題還是新 API 問題。

---

## 5.3 Gemini 3.5 Transcribe 基本測試

選：

```text
後端：Google AI Studio
模型：Gemini 3.5 Transcribe・Preview
轉錄模式：忠實逐字
語言提示：自動偵測
辨識說話者：關閉
逐字時間戳：關閉
詳細 JSON：關閉
```

加入音檔 A，按「開始轉文字」。

預期 log 至少能看出：

```text
Gemini Interactions Transcribe
API v1beta
使用 Files API 上傳
模型 gemini-3.5-transcribe
```

驗證輸出：

- 只有正式 TXT
- 沒有 Markdown 前言或摘要
- 沒有虛構時間戳或講者名稱
- 中文已經過 OpenCC 轉成台灣繁體
- 完成後 Files API 暫存音訊會執行 DELETE

---

## 5.4 Custom Vocabulary 測試

建立或選擇含以下詞彙的詞庫：

```text
SPECIFIQUE
OGSTM
復盛
典華
```

使用音檔 C。

驗證：

- Job log 顯示專用 Transcribe transport
- 詞彙以 `custom_vocabulary` 傳送，而不是重複塞進一般 Prompt
- 輸出不應因詞庫而憑空出現音檔中沒說過的詞
- 同一詞的大小寫／前後空白重複會被穩定去重

詞彙數量政策：

- 0–100：正常
- 101–1,000：允許，但 Job log 顯示品質提醒
- 超過 1,000：加入工作前阻止

---

## 5.5 台灣華語提示測試

改為：

```text
語言提示：台灣華語優先
```

App 會解析為：

```text
cmn-Hant-TW
```

使用音檔 B 驗證：

- 中文仍正常
- 英文品牌／術語未被強制翻譯
- code-switching 沒有明顯劣化

若自動偵測反而較好，日常使用可維持「自動偵測」。

---

## 5.6 Smart Mode 測試

選：

```text
轉錄模式：智慧整理
```

UI 應自動關閉並停用：

```text
辨識說話者
輸出逐字時間戳
```

使用同一份音檔 A，比較忠實逐字與智慧整理：

- Smart 可移除部分贅詞、重複與 false start
- 可有輕度段落與格式整理
- 不適合作為法律、研究或逐字引述版本
- App 不應再用一般 Gemini 的 Markdown stripping 破壞 Smart 輸出

---

## 5.7 Speaker／Word Timestamp／JSON 測試

選：

```text
轉錄模式：忠實逐字
辨識說話者：開啟
輸出逐字時間戳：開啟
輸出詳細 JSON：開啟
```

使用音檔 D。

預期產生：

```text
原檔名_逐字稿.txt
原檔名_逐字稿.json
```

檢查 JSON：

```bash
python3 -m json.tool "/path/to/原檔名_逐字稿.json" | less
```

至少確認：

```text
schemaVersion = 1
provider = googleAIStudio
modelID = gemini-3.5-transcribe
transport = geminiInteractionsTranscribe
speakerScope = segmentLocal
segments[].words[]
segments[].speakerTurns[]
```

所有文字欄位都應是台灣繁體。

重要限制：

```text
segment-0001:speaker-1
segment-0002:speaker-1
```

不代表跨片段一定是同一個人。第一版只保證片段內 speaker label，不做跨段聲紋比對。

---

## 5.8 AI Studio 長音訊測試

使用音檔 G（31 分鐘以上）。

預期：

- 仍採產品安全政策，每段最多 20 分鐘
- 31 分鐘應切成 2 段
- 每段完成後立即建立 checkpoint
- 全部片段完成後才交付正式 TXT
- 片段交界不能重複一整句，也不能漏掉明顯內容
- JSON timestamp 應加上片段起點，第二段不是從 0 秒重新開始

---

# 6. gcloud / Google Cloud 驗證

## 6.1 登入與 Project

確認 gcloud：

```bash
which gcloud
gcloud version
```

登入：

```bash
gcloud auth login
gcloud auth application-default login
```

設定專案：

```bash
export GOOGLE_CLOUD_PROJECT="你的-project-id"
gcloud config set project "$GOOGLE_CLOUD_PROJECT"
gcloud config get-value project
gcloud auth print-access-token >/dev/null && echo "access token OK"
```

啟用常用 API：

```bash
gcloud services enable aiplatform.googleapis.com
```

若使用 GCS：

```bash
gcloud services enable storage.googleapis.com
```

你的帳號／執行身分至少要有對應的模型呼叫權限；使用 GCS 時，還需要該 bucket 的 object create／delete 權限。

> 已能使用一般 Vertex Gemini，不代表一定已取得 Gemini 3.5 Transcribe Preview／Agent Platform entitlement。若收到 403 或特定 404，先確認 Preview 開放狀態、Project entitlement、IAM 與 API enablement，不要重新產生 AI Studio API Key。

---

## 6.2 GCS Bucket（建議但非強制）

建立測試 bucket，例如：

```bash
export RTT_BUCKET="你的唯一-bucket-name"
gcloud storage buckets create "gs://$RTT_BUCKET" \
  --project="$GOOGLE_CLOUD_PROJECT" \
  --location=ASIA
```

App 設定填 bucket 名稱，不要加 `gs://`：

```text
你的唯一-bucket-name
```

未設定 bucket 時，單段壓縮音訊在 20 MB 內可走 inline Base64；設定 bucket 通常更適合穩定測試上傳、重試與清理。

---

## 6.3 一般 Vertex Gemini 回歸測試

先選：

```text
後端：Google Cloud Vertex AI
模型：Gemini 3.7 Flash
Location：原本可用的區域或 global
```

使用音檔 A。

驗證：

- 一般 Vertex generateContent 可成功
- 仍保留 Prompt
- 仍保留既有 retry／fallback
- 仍可在全文合併後摘要一次
- 專用 Transcribe 的 global／14 分鐘政策沒有誤套到一般模型

---

## 6.4 gcloud Gemini 3.5 Transcribe Preview 基本測試

選：

```text
後端：Google Cloud Vertex AI
模型：Gemini 3.5 Transcribe Preview
轉錄模式：忠實逐字
語言提示：自動偵測
```

選此模型後，UI 應顯示：

```text
Effective Location：global
單段安全切片：14 分鐘
```

Location 欄位會停用，但原本保存的區域值不會被覆寫；切回一般 Vertex 模型時會恢復使用。

使用音檔 A。

預期 log：

```text
Gemini Agent Platform Transcribe
API v1beta1
gemini-3.5-transcribe-preview
location global
```

驗證：

- 不送 `systemInstruction`
- 不送一般 Prompt
- 使用 `generationConfig.audioTranscriptionConfig`
- JSON key 是 `languageCodes`／`customVocabulary`／`wordTimestamp`／`diarization`
- 正式輸出為台灣繁體 TXT

---

## 6.5 14／15 分鐘切片邊界

依序測試：

| 音檔 | 預期段數 |
|---:|---:|
| 13 分鐘 | 1 |
| 14 分鐘 | 1 |
| 15–16 分鐘 | 2 |
| 20 分鐘 | 2 |
| 31 分鐘 | 3 |

App 採 14 分鐘，而不是硬貼官方 15 分鐘上限，目的是保留編碼延遲與容器 padding 的安全餘裕。

檢查 log 與 recovery manifest：

```text
maximumSegmentDurationSeconds = 840
```

---

## 6.6 gcloud Speaker／Timestamp／JSON

使用音檔 D，開啟：

```text
辨識說話者
輸出逐字時間戳
輸出詳細 JSON
```

驗證項目與 AI Studio 相同，但 JSON 應顯示：

```text
provider = vertexAI
modelID = gemini-3.5-transcribe-preview
transport = agentPlatformTranscribe
```

若 Provider 回傳 `audioTranscription.text`，App 會優先使用；只有缺少 structured transcription 時才退回 `part.text`。

---

## 6.7 專用 Transcribe + 全文摘要

開啟：

```text
附加內容摘要
摘要模型：Gemini 3.7 Flash
```

使用長音檔。

驗證：

1. 每段音訊只由 `gemini-3.5-transcribe-preview` 轉錄。
2. 所有片段合併後，才呼叫一次摘要模型。
3. 摘要模型是一般 Gemini，不是 Transcribe Preview。
4. 摘要失敗時，完整逐字稿仍保留，僅顯示 warning。
5. 正式 TXT 最後才附加摘要。

---

# 7. Retry、取消與清理驗證

## 7.1 取消

使用長音檔，至少等第一段完成後取消。

預期：

- 當前 HTTP／上傳工作收到取消
- 已完成片段保存在 `Temp-Recovery`
- 正式輸出 TXT 不會被建立
- recovery 不保留 MP3
- 若啟用 JSON，已完成片段的 `.metadata.json` 也會被保留
- App log 顯示可取回未完成稿

Recovery 位置：

```text
~/Library/Application Support/record-to-text/Temp-Recovery/
```

## 7.2 模擬權限／模型不可用

可暫時使用沒有 Preview entitlement 的 Project，或把 Project ID 改成無權限專案。

預期：

- 400／403／404 不做無限 retry
- 不偷偷 fallback 成一般 Gemini
- 不產生看似完整的正式 TXT
- UI 顯示實際 HTTP 與 entitlement／permission 訊息
- 已完成片段仍可 recovery

## 7.3 Server retry

429／500／502／503 會在同一模型內重試，且：

- AI Studio Files API 音訊只上傳一次
- gcloud GCS object 只上傳一次
- 每次 retry 共用同一遠端 URI
- 專用模型預設不跨到一般 Gemini

---

# 8. 遠端暫存清理檢查

## 8.1 AI Studio Files API

建議在測試前後列出 Files API 檔案數量。請用環境變數，不要把 Key 直接寫進命令歷史：

```bash
export GEMINI_API_KEY="你的-key"
curl -sS \
  -H "x-goog-api-key: $GEMINI_API_KEY" \
  "https://generativelanguage.googleapis.com/v1beta/files" \
  | python3 -m json.tool
```

完成、失敗與取消後，不應留下本次由 `record-to-text-UUID` 建立的音訊。

## 8.2 GCS

```bash
gcloud storage ls "gs://$RTT_BUCKET/**" 2>/dev/null \
  | grep 'record-to-text-' || true
```

完成、失敗與取消後，不應留下本次 UUID object。

如果 log 顯示 DELETE 失敗，先確認 bucket delete 權限；App 不會把 cleanup failure 假裝成成功，會留下 warning。

---

# 9. 資安與落盤檢查

確認 API Key 不在 JSON：

```bash
ROOT="$HOME/Library/Application Support/record-to-text"
grep -R 'AIza' "$ROOT" --include='*.json' --include='*.log' || true
grep -R 'Bearer ' "$ROOT" --include='*.json' --include='*.log' || true
```

預期沒有輸出。

確認新的 settings／job ledger 不編碼 API Key：

```bash
grep -R 'googleAIStudioAPIKey' "$ROOT" --include='*.json' || true
```

正常新檔不應包含可用 Key。若是非常舊的 migration 檔，先確認 Keychain 遷移完成，再由 App 正常保存一次設定。

App log 只能記錄：

- provider
- model ID
- transport
- API version
- location
- segment index／count
- byte count
- HTTP status
- retry 次數
- Custom Vocabulary 數量

不應記錄：

- API Key
- Bearer token
- Base64 音訊
- 完整詞庫內容
- 完整逐字稿內容

---

# 10. A/B 品質驗證

對同一批錄音各跑一次：

```text
Google AI Studio Gemini 3.7 Flash
Google AI Studio Gemini 3.5 Transcribe
Google Cloud Gemini 3.5 Transcribe Preview
Local Qwen3-ASR
```

建議記錄：

| 指標 | 說明 |
|---|---|
| 漏句率 | 整句沒出現 |
| 幻覺率 | 音檔沒有但模型寫出 |
| 專有名詞 recall | 詞庫中的詞是否正確 |
| 中文 CER | 字元錯誤率 |
| 英文拼寫 | 品牌／人名／縮寫 |
| 片段交界 | 重複、截斷、漏字 |
| Speaker attribution | 同段內講者分配 |
| Timestamp 誤差 | 與音檔實際時間差 |
| 總耗時 | 含上傳、重試、轉換 |
| 失敗率 | 429／5xx／權限／parse |
| Cleanup | 遠端暫存是否刪除 |

在完成多場真實會議 A/B 前，不建議把 3.5 Transcribe 改成所有使用者的預設模型。

---

# 11. 常見問題判讀

## HTTP 400

優先檢查：

- Preview schema 是否變更
- model ID 是否仍有效
- Smart 與 speaker／timestamp 是否衝突
- language code 是否有效
- 音檔格式與時長

## HTTP 401

AI Studio：檢查 Key。

gcloud：App 會先 invalidate token 並強制 refresh 一次；仍失敗時重新執行：

```bash
gcloud auth login
gcloud auth print-access-token >/dev/null
```

## HTTP 403

通常是 IAM、API enablement、quota 或 Preview entitlement，不等於 Key 格式錯誤。

## HTTP 404

可能是：

- model 尚未對 Project 開放
- Preview model ID 改名
- API version／endpoint 變更
- Project entitlement 不足

## HTTP 429／500／502／503

App 會同模型退避重試。專用模型不會預設偷偷改成一般 Gemini。

## JSON 有 speaker，但跨段對不上

屬於已知限制。`speakerScope` 明確標示為：

```text
segmentLocal
```

第一版不宣稱跨切片 speaker identity 一致。

---

# 12. 最終驗收清單

## 編譯／測試

- [ ] `REQUIRE_XCTEST=1 scripts/run-checks.sh` 全通過
- [ ] `swift test` 全通過
- [ ] App 可建立並開啟

## AI Studio

- [ ] 3.7 Flash 回歸正常
- [ ] 3.5 Transcribe 基本轉錄成功
- [ ] Custom Vocabulary 有作用但不憑空加詞
- [ ] Smart Mode 正確停用 speaker／timestamp
- [ ] speaker／word timestamp JSON 可解析
- [ ] 31 分鐘長音訊正確分段合併
- [ ] Files API 暫存音訊被刪除

## gcloud

- [ ] 一般 Vertex Gemini 回歸正常
- [ ] Transcribe Preview 使用 global／v1beta1
- [ ] 13 分鐘 1 段
- [ ] 15–16 分鐘 2 段
- [ ] 31 分鐘 3 段
- [ ] GCS 或 inline 路徑成功
- [ ] 摘要只在全文合併後呼叫一次一般 Gemini
- [ ] GCS 暫存物件被刪除

## 可靠度／安全

- [ ] 取消後只保存完成片段與 optional metadata，不保存 MP3
- [ ] 任一中段失敗不交付部分正式 TXT
- [ ] retry 不重複上傳
- [ ] API Key／Bearer token 不落盤、不進 log
- [ ] 舊 settings／job ledger 仍可讀取
- [ ] Local Qwen 不受影響

全部完成後，再決定是否將 Gemini 3.5 Transcribe 提升為預設模型或合併回主要雲端分支。
