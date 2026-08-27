# Gemini 3.5 Transcribe 實作對照（21 章規格）

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

`AgentPlatformTranscribeBackend.swift`：gcloud／ADC、`gemini-3.5-transcribe-preview`、`global`、`v1beta1`、GCS／inline、Verbatim／Smart `audioTranscriptionConfig`、structured response、401 refresh、retry 與 cleanup。

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

首版仍保留 3.7 Flash 為預設；3.5 Transcribe 以可選 Preview 上線。兩個 provider 都支援 Verbatim／Smart；預設 Verbatim、Auto language、Custom Vocabulary，speaker／timestamps／JSON 關閉，專用模型跨一般模型 fallback 關閉。

## 驗證入口

完整指令、UI 步驟、邊界測試、遠端 cleanup、資安檢查與 A/B 表格見：

`docs/GEMINI_3_5_TRANSCRIBE_VERIFICATION.md`
