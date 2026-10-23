# Gemini 4 Argon 支援（build 12）

使用者要求只新增 Argon 模型支援，沿用既有逐字稿格式。版本為 0.2.1（12）。

## 行為

- 設定的 Gemini 模型選單及主視窗快速切換選單加入 `gemini-4-argon`；AI Studio 與 Vertex AI 共用模型能力設定。使用者原本選用的模型及思考強度不自動變更。
- 沿用純文字繁中逐字稿、講者輪替、時間區間、詞庫、20 分鐘音訊分段、Files API 清理與檢查點流程。沒有新增 JSON、摘要或每句時間戳記。
- Argon 會送出實際選定的 `thinkingConfig.thinkingLevel`（low／medium／high）。不新增 temperature、topP、topK 或顯式快取。
- 本 App 使用直接的非串流 REST `generateContent`，Argon 設定 32,768 tokens；Flash 仍為 65,536，未知模型仍為 16,384。設定頁顯示實際上限。達到 `MAX_TOKENS` 時仍丟棄截斷稿、細分音訊重試；沒有加入 long decode。非完成回應不當成完整逐字稿。
- Argon 單次推論最多等待 20 分鐘；每個原始音訊段含準備、重試及細分子段共用 30 分鐘上限。其他模型維持單次 5 分鐘、原始段 15 分鐘；取消與外部注入的更短期限仍有效。
- 保留實際 token 用量。Argon 不套用既有 Flash 的費率估算，費用以 Google 帳單為準；需要可使用該模型的付費 API 權限。既有 Flash fallback 規則不會替換 Argon。

## 官方依據（2026-10-15 核對）

- [模型規格：音訊輸入、思考強度](https://ai.google.dev/gemini-api/docs/models/gemini-4-argon)
- [GenerateContent 遷移指南：REST 欄位、等待時間與計費](https://ai.google.dev/gemini-api/docs/generate-content/latest-model)
- [Long decode：直接非串流 REST 的 32K 上限](https://ai.google.dev/gemini-api/docs/generate-content/long-decode)
- [Google Cloud Argon 指南](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-4-argon?hl=en)

模型總覽、SDK 與 Interactions 的輸出上限不能直接當作本 App 非串流 REST 的單次上限。

## 驗證範圍

使用模擬 HTTP 傳輸驗證 Argon endpoint、三種思考強度、輸出上限、提示詞與既有格式、Files API 清理、截斷及權限錯誤、時間上限和實際 pipeline 的細分合併。未使用私人錄音呼叫 Google，亦未驗證使用者帳號的 Argon 權限或真實模型辨識品質。

`SKIP_APP_BUNDLE=1 scripts/run-checks.sh` 通過：Swift 522 項測試、0 失敗、1 項真實本機模型測試依預設跳過；Python 134 項、executable self-test 72 項及 10 個 pipeline 情境通過。之後補上主畫面快速選項，追加驗證 12 項全部通過，涵蓋設定持久化、Argon 請求及細分流程。

## 本機交付

已以 Apple Silicon release 建置、ad-hoc 簽章，安裝至 `/Applications/record-to-text.app` 並開啟 0.2.1（12）；不是已公證的正式發行版。安裝時 App 已關閉且無執行中工作。安裝後確認簽章、執行檔與建置產物一致、程序正常、11 筆既有工作狀態及設定檔未變。build 11 的完整備份保留在 App 資料目錄 `AppBackups/build11-before-argon-20261015.zip`，壓縮檔完整性已驗證。
