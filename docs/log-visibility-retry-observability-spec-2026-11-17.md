# 執行日誌展開與雲端重試可視性規格

日期：2026-11-17（Asia/Taipei）  
狀態：已於分支 `codex/log-visibility-retry-observability` 完成程式、測試與 0.2.1（21）本機建置準備  
基準：`main` `62811d6`（已合併 PR #1 `codex/gemini-hydrogen-thinking` `de7e66d`），本機建置版本基準調整為 `0.2.1 (21)`。  
歷史系統規格基準：[product-system-spec-2026-09-11.md](product-system-spec-2026-09-11.md)（停留在 0.2.1 build 6）。

---

## 1. 背景與問題成因

本規格源自 2026-11-17 本機安裝版 `0.2.1 (38)` 執行 Vertex AI `gemini-4-hydrogen`（`thinkingConfig=high`）長錄音工作 `411E31EC-46A6-4160-8461-937913964C3B` 的實測觀察：

1. **畫面只顯示收合兩句摘要，無法直接展開**：在 [MainView.swift](../Sources/RecordToTextApp/MainView.swift) 中，`JobRowView` 的 `logSection` 僅透過 `JobDebugClipboard.statusSummary(from:)` 過濾技術行後顯示最新兩句，旁邊只有「複製除錯資訊」按鈕；使用者必須複製並貼到外部文字編輯器才能看到完整執行日誌。歸檔後的 `RecentJobRow`（使用 `RecentJobSummary`）則僅在右鍵選單提供「複製除錯資訊」，畫面上看不到分段診斷。
2. **傳輸層暫時性失敗與重試沒有寫入日誌**：該筆工作經由系統代理 `127.0.0.1:7890` 執行，第 1 段與第 2 段各自發生 `incompleteStream`（HTTP 200 SSE 串流在收到 `finishReason` 前 EOF 中斷）與 `connectionLost`（`NSURLErrorDomain -1005`），並在 [GeminiTransportHelper.swift](../Sources/RecordToTextCore/GeminiTransportHelper.swift) 內自動退避重試後成功完成。但因為內層重試不會寫入 `logLines`，而 [TranscriptionEngine.swift](../Sources/RecordToTextCore/TranscriptionEngine.swift) 的 `makeCloudStatusTask` 每 30 秒才輸出一次心跳訊息，導致日誌連續數分鐘只顯示「正在接收 Google 回應（已耗時 XXX 秒）」，使用者無法判斷是正常深度思考等待、還是已多次斷線重連，外觀上如同「卡住」。

---

## 2. 既有規劃盤點與本版定位

實作前先對齊專案既有規劃與版本演進，避免與既有保護或設計決策衝突：

### 2.1 與既有總體規劃的落差（build 6 → 目前狀態）

[product-system-spec-2026-09-11.md](product-system-spec-2026-09-11.md) 仍停在 `0.2.1 build 6`，以下能力已陸續進入 `main`（至 build 19 `a1e2b54`）或待併的 PR #1（`de7e66d` / CI #38），不屬於本版待規劃事項：

- **已實作於 `main`**：20 秒固定網路重試與手動「立刻重試」（[functional-review-2026-10-17.md](functional-review-2026-10-17.md)、[network-recovery-spec-2026-09-19.md](network-recovery-spec-2026-09-19.md)）、HTTP 429 服務冷卻與完成後休眠（[cloud-cooldown-manual-resend-sleep-spec-2026-09-21.md](cloud-cooldown-manual-resend-sleep-spec-2026-09-21.md)）、Vertex SSE 串流與 `includeThoughts` 保活（[vertex-streaming-response-spec-2026-10-17.md](vertex-streaming-response-spec-2026-10-17.md)）、雲端錄音背景（[cloud-recording-context-spec-2026-10-23.md](cloud-recording-context-spec-2026-10-23.md)）、AI Studio 空 STOP 有限重試與結構化 `CloudFailureHistory`（[ai-studio-empty-response-recovery-spec-2026-10-29.md](ai-studio-empty-response-recovery-spec-2026-10-29.md)）、以及 `gemini-4-argon`／`gemini-4-carbon`／`gemini-3.5-transcribe` 支援。
- **已實作於 PR #1（OPEN，`codex/gemini-hydrogen-thinking`）**：`gemini-4-hydrogen`（含 `xhigh` 思考強度、65,536 tokens 輸出與摘要上限、1,200 秒單次期限／1,800 秒段預算）與各模型獨立保存思考強度。

### 2.2 仍留待後續的既有規劃項目（本版不混做）

依 [NEXT_STEPS.md](NEXT_STEPS.md)、[functional-review-2026-10-17.md](functional-review-2026-10-17.md) 與 [ai-studio-empty-response-recovery-spec-2026-10-29.md](ai-studio-empty-response-recovery-spec-2026-10-29.md)，其餘未完成規劃維持獨立排程：

| 優先序 | 既有規劃項目 | 目前狀態與不納入本版原因 |
| --- | --- | --- |
| P1 | 雲端「測試目前模型」與失敗分類 | 涉及模型探測請求設計，與本版日誌呈現無直接相依 |
| P1 | Flash 300 秒活躍串流期限／代理長等待相容性 | `usesExtendedBudget` 已給 Argon／Carbon／Hydrogen 1,200 秒，其餘代理相容性需受控連線測試，另案處理 |
| P2 | 可選較短預切上限（5／10／20 分鐘） | 涉及分段、邊界品質與成本 A/B，另案處理 |
| P2 | 按模型／思考 token 修正美元成本估算 | 需核對各模型官方費率表，另案處理 |
| P2 | PD-015 自動檢查更新、真實 Gemini 自適應切段／soak／GUI 驗證 | 既有中長程驗證與功能待辦 |
| P3 | 顯示目前 App 路徑、Runtime／模型 installer、Intel／Universal 2、簽署與公證 | 發佈與安裝鏈條件另立里程碑 |

### 2.3 調和 `PD-009` 與 `0.2.0` UI 日誌決策

- [product-decisions.md](product-decisions.md)（PD-009）原本定義執行過程應「寫入展開式日誌」，並於 PD-014 要求限制持久化日誌行數避免無限增長。
- [handoff-2026-08-29-ui.md](handoff-2026-08-29-ui.md)（0.2.0）為簡化主畫面，將工作卡日誌區改為「最多兩句白話狀態（濾掉 `HTTP `／`JSON `／`thinkingConfig`／`token` 等）」搭配「複製除錯資訊」。
- **本版定位**：維持 0.2.0 預設收合的清爽版面，但在同一工作卡上補回「可手動展開查看完整日誌／診斷」的能力，同時讓雲端傳輸重試事件即時留下安全、可判讀的日誌紀錄。

---

## 3. 本版範圍與非目標

### 3.1 交付範圍

1. **工作卡片展開式日誌（`JobRowView`）**：保留預設兩句白話摘要與「複製除錯資訊」，新增預設收合的展開控制，展開後可直接在 App 內捲動與選取查看完整 `logLines`。
2. **最近工作展開式診斷（`RecentJobRow`）**：當 `RecentJobSummary` 附帶結構化 `cloudDiagnostics` 時，提供預設收合的展開檢視與可直接點擊的診斷檢視／複製入口。
3. **雲端傳輸重試日誌補齊（`GeminiTransportHelper`）**：當 `budgetedUpload`／`budgetedData` 遭遇可重試暫時性錯誤（`incompleteStream`、`NSURLErrorDomain -1005`、`-1001` 等）、POSIX 40 session 重建，或非生成階段（upload／poll）遭遇 429／5xx 重試時，立即透過 `logger` 寫入包含固定錯誤分類／代碼與實際發送次數的狀態訊息。

### 3.2 明確非目標

- **不改變重試與逾時策略**：不增加單模型最大發送次數（仍為含首次最多 4 次）、不修改 20 秒網路重試倒數、429 冷卻、300／1,200 秒單次請求期限或 900／1,800 秒 root budget。
- **不把 `logLines` 塞進 `RecentJobSummary`**：維持 [Models.swift](../Sources/RecordToTextCore/Models.swift) 中 `RecentJobSummary` 不保存 `logLines` 的資料契約與去識別化優勢，避免 `recent-jobs.json` 體積膨脹或帶入歷史檔案路徑／非結構化 log。
- **不輸出敏感資料或原始 SSE／HTTP body**：嚴格遵守 [product-system-spec-2026-09-11.md](product-system-spec-2026-09-11.md) §17.2 與 [network-recovery-spec-2026-09-19.md](network-recovery-spec-2026-09-19.md) 的白名單規範。
- **不改動本機 Qwen helper 輸出協定或 `makeCloudStatusTask` 30 秒週期**。

---

## 4. 現況缺口與修改位置

| 模組 | 現況 | 本版預期責任 |
| --- | --- | --- |
| [MainView.swift](../Sources/RecordToTextApp/MainView.swift) | `JobRowView.logSection` 只有 2 句摘要與「複製除錯資訊」；`RecentJobRow` 只在右鍵選單提供複製除錯資訊；`JobDebugClipboard.isDebugLine` 未濾除 `budget` 技術行 | 新增工作卡預設收合之日誌展開區、最近工作診斷展開區；以父層穩定狀態保存展開集合；補入 `budget created`／`budget root=` 至 `isDebugLine` |
| [GeminiTransportHelper.swift](../Sources/RecordToTextCore/GeminiTransportHelper.swift) | `budgetedUpload`、`budgetedData` 與 `send` 不接受 `logger`；內層重試與 POSIX 40 重設完全不寫入執行日誌 | 接收可選 `logger`；在確定重試／重建 session 時輸出安全去識別的簡明重試原因與發送次數，不與 `GeminiGenerationRetry` 重複洗版 |
| [VertexAIGeminiBackend.swift](../Sources/RecordToTextCore/VertexAIGeminiBackend.swift) | `sendWithPOSIXRetry`、`uploadToGCS`、`gcsMetadata` 未將 `logger` 傳給 `GeminiTransportHelper` | 傳遞經 `CloudRecordingContext.redactedDiagnostic` 包裝的 `logger` 給 generation 與 upload/metadata transport 呼叫 |
| [GoogleAIStudioBackend.swift](../Sources/RecordToTextCore/GoogleAIStudioBackend.swift) | `sendWithPOSIXRetry`、`uploadToFilesAPI`、`startFilesUpload`、`remoteFileMetadata`、`finishFilesUpload` 未將 `logger` 傳給 `GeminiTransportHelper` | 傳遞經 `CloudRecordingContext.redactedDiagnostic` 包裝的 `logger` 給 generation、Files init/upload/poll transport 呼叫 |
| [CloudFailureDiagnostic.swift](../Sources/RecordToTextCore/CloudFailureDiagnostic.swift) | 已提供固定分類 `Category`、`userMessage` 與白名單 `errorChain`（`NSURLErrorDomain`、`NSPOSIXErrorDomain`、`NSCocoaErrorDomain`、`kCFErrorDomainCFNetwork`） | 供 `GeminiTransportHelper` 共用分類與安全錯誤碼格式，禁止另行讀取 `NSError.localizedDescription` 或 `userInfo` |
| [AppViewModel.swift](../Sources/RecordToTextApp/AppViewModel.swift) | `appendLog` 保留最新 400 行，`.log` 走預設 `.coalescible` 或持久化節流 | 維持現有 400 行記憶體上限與 `JobRetentionPolicy` ledger 100 行裁切；不因新增重試日誌增加 `.critical` 同步磁碟寫入 |

---

## 5. 介面可視性規格（UI）

### 5.1 工作卡片（`JobRowView`）

1. **預設收合，不破壞 0.2.0 版面**：
   - 當 `!job.logLines.isEmpty` 時，卡片維持顯示最多兩句白話摘要（`JobDebugClipboard.statusSummary(from: job.logLines)`）。
   - 控制列（原「複製除錯資訊」旁）新增切換按鈕：收合時顯示「展開日誌（\(job.logLines.count)）」、展開時顯示「收合日誌」，搭配圖示指示展開方向（如 `chevron.down`／`chevron.up`）。
   - 若僅有 `job.cloudDiagnostics != nil` 而 `job.logLines.isEmpty`，仍維持提供展開檢視分段診斷摘要與「複製除錯資訊」。
2. **技術行過濾更新（`JobDebugClipboard.isDebugLine`）**：
   - 在現有 `markers` 基礎上補入 `"budget created"` 與 `"budget root="`，使預算建立與每次 attempt 的英文除錯紀錄只在展開日誌與「複製除錯資訊」中顯示，不佔用收合態的兩句白話位置。
   - 新增的「暫時性斷線與重試」繁中訊息 **不得** 加入 `isDebugLine` 過濾清單，確保在收合態下使用者也能立刻看到正在從哪個錯誤重試（例如 `incompleteStream` 或 `NSURLErrorDomain:-1005`），不會只看到計時數字跳動。
3. **展開區內容與捲動行為**：
   - 展開區以背景微區隔（如圓角內襯底色），使用等寬字體（`font(.caption.monospaced())`）、`textSelection(.enabled)`，依時間順序從舊到新逐行呈現完整 `job.logLines`（不套用 `isDebugLine` 過濾，亦不截短每行文字）。
   - 外層包覆固定最大高度的垂直 `ScrollView`（建議 `maxHeight: 220`），避免 100～400 行日誌把整條佇列畫面撐爆。
   - 若工作有 `job.cloudDiagnostics`，可在展開區底部（或附帶摺疊標頭）一併顯示 `diagnostics.debugSummary`（或顯示總請求數／重試原因統計），讓使用者不必複製就能看到各段耗時與失敗事件。
   - **穩定展開狀態與無障礙**：展開狀態由父層 `MainView` 以 `@State private var expandedLogJobIDs: Set<UUID> = []` 持有並傳入綁定（`Binding`），不得依賴會隨 `LazyVStack` 重置的 row 區域狀態；執行中每隔 30 秒新增心跳日誌時，已展開的卡片不得自動收合，且不得強制跳離使用者正在向上回看的位置（若提供「跳至最新」按鈕為佳，預設不強拉捲動位置）。
   - 760pt 最小視窗寬度、淺色／深色模式、High Contrast 與 Reduce Motion 下不可截斷操作按鈕或產生過度動畫。

### 5.2 最近工作（`RecentJobRow`）

1. **資料來源界線**：
   - `RecentJobSummary` 延續現行設計，只包含結構化 `cloudDiagnostics`（無 `logLines`）。
2. **UI 呈現**：
   - 當 `summary.cloudDiagnostics != nil` 時，於 `RecentJobRow` 提供預設收合的「查看診斷」按鈕（由父層 `MainView` 以 `expandedRecentDiagnosticsIDs: Set<UUID>` 管理），展開後以可選取等寬字體顯示 `summary.cloudDiagnostics?.debugSummary`，並於該區內或操作列提供「複製除錯資訊」（同時保留右鍵 `.contextMenu` 的既有項目）。
   - 舊版未保存 `cloudDiagnostics` 的最近工作不顯示展開按鈕，維持原本簡潔單列。

---

## 6. 雲端傳輸與重試日誌規格（Core）

### 6.1 傳輸層重試事件日誌化

在 `GeminiTransportHelper.send(...)` 新增 `logger: ((_ level: String, _ message: String) -> Void)? = nil`（並透傳於 `budgetedUpload` 與 `budgetedData`）：

| 發生情境 | 寫入條件 | 寫入層級與訊息格式要求 |
| --- | --- | --- |
| `generation` 暫時性失敗並將重試 | `transient == true` 且 `attempt < 4 && sends < 4`（在進入 `context.retry(...)` 之前立即寫入） | `level: "info"`（或 `"warning"`）；格式包含：階段（生成）、分類中文說明（取 `classified.userMessage`）、固定代碼（如 `incompleteStream`、`HTTP 408` 或白名單首個 `errorChain` 如 `NSURLErrorDomain:-1005`）、是否重建連線（若發生 `transportReset` 或將重建會標註「準備重設連線」）、等待約幾秒（`Int(ceil(context.policy.retryDelaySeconds))`）與實際發送進度（`已發送 \(sends)／4 次`） |
| `upload`／`poll` 暫時性失敗並將重試 | `!generation && transient == true && attempt < 4 && sends < 4` | 同上格式，階段改標「上傳音訊」或「查詢雲端檔案狀態」；若該次是 `confirmUpload` 前的錯誤亦標示待確認或重試 |
| POSIX 40（`EMSGSIZE`）重建連線 | `posix == true && attempt < 4 && sends < 4 && !context.sessionWasReset` | `level: "warning"`；明確寫出 `本機傳輸通道無法送出這包資料（NSPOSIXErrorDomain:40），已重設連線並重新嘗試（第 \(sends)／4 次）。` |
| 非生成（`!generation`）HTTP 429 服務冷卻 | `!generation && http.statusCode == 429 && attempt < 4` | `level: "info"`；寫出階段（上傳音訊／查詢狀態）、`HTTP 429` 與 `已發送 \(quota?.count ?? attempt)／4 次，依服務冷卻政策等待重試。` |
| 非生成（`!generation`）可重試 HTTP 狀態碼（408/5xx） | `!generation && RetryPolicy.isRetryableStatusCode(http.statusCode) && attempt < 4` | `level: "info"`；寫出階段、`HTTP \(http.statusCode)`、退避約幾秒與 `第 \(attempt)／4 次嘗試` |

### 6.2 去重複與不誤報契約

1. **不與 `GeminiGenerationRetry` 重複**：`generation` 階段的 HTTP `429`、`5xx` 與 `emptyCompletedResponse` 係由 `GeminiTransportHelper.send` 回傳給後端並拋出型別化錯誤，由 `GeminiGenerationRetry.attempts(...)` 記錄退避並寫入日誌（現行已實作）；`GeminiTransportHelper` 對這三類情況 **不得** 再重複寫入重試日誌。
2. **不寫入虛假重試訊息**：若 `attempt >= 4`、`sends >= 4`、第二度 POSIX 40（`context.sessionWasReset == true`）、`Task.isCancelled` / `isNetworkCancellation`、`CloudSegmentDeadlineExceeded` 或 `CloudNetworkRecoveryExhausted` 發生，代表本次不再自動重試，`GeminiTransportHelper` 不得輸出「約 X 秒後重試」，直接交由上層記錄最終失敗。
3. **文字前綴與分段位置可辨識**：
   - 在 `VertexAIGeminiBackend`／`GoogleAIStudioBackend` 的 `transcribeDetailed` 呼叫 `sendWithPOSIXRetry`、上傳或輪詢時，可透過既有經 `CloudRecordingContext.redactedDiagnostic` 包裝的 `logger` 傳入；若分段資訊已在前一行「正在由 `<model>` 第 X/Y 段 忠實轉錄…」呈現，傳輸層日誌不需重新依賴 UI 字串，只要清楚標示「雲端生成請求」「上傳音訊」或「查詢檔案狀態」與 `已發送 N／4 次` 即可，亦不引入額外 `@TaskLocal` 狀態耦合。

### 6.3 隱私與持久化安全邊界

1. **嚴格白名單**：`GeminiTransportHelper` 建構錯誤摘要時，**只能**讀取 `CloudFailureDiagnostic.classify(error, stage: diagnosticStage)` 所產生的：
   - `classified.userMessage`
   - `classified.category.rawValue`（對 `.incompleteStream`、`.requestDeadlineExceeded` 等無 `errorChain` 者尤其有用）
   - `classified.httpStatus`
   - `classified.errorChain`（該欄位已限制僅允許 `NSURLErrorDomain`、`NSPOSIXErrorDomain`、`NSCocoaErrorDomain`、`kCFErrorDomainCFNetwork` 的 `domain:code`）
   **禁止**讀取並寫入 `error.localizedDescription`、`NSError.userInfo`（含 `NSErrorFailingURLKey` 等）、`request.url`、Authorization / `x-goog-api-key` headers、project ID、GCS bucket／object name、SSE payload、逐字稿或 Prompt。
2. **背景遮蔽兜底**：傳入 `GeminiTransportHelper` 的 `logger` 仍須沿用 `VertexAIGeminiBackend`／`GoogleAIStudioBackend` 現有的 `CloudRecordingContext.redactedDiagnostic` 包裝。
3. **行數裁切與持久化節流**：
   - 新增日誌沿用 `PipelineUpdate.log` 進入 `AppViewModel.appendLog`，受記憶體上限 **400 行**及 `JobRetentionPolicy.ledgerJobs` 磁碟上限 **100 行**約束。
   - 不得將 `.log` 更新改為 `.critical` 立即磁碟 flush（保留現有 `.stage`／`.networkRecovery`／`.serviceRecovery`／終止階段之持久化節奏），維持 `persistJobs` 效能。

---

## 7. 分支策略與交付界線

1. **分支現況**：PR #1（`codex/gemini-hydrogen-thinking`）已合併進 `main`（`62811d6`），本規格已自最新 `main` 建立分支 `codex/log-visibility-retry-observability` 完成實作與自動化驗證。
2. **Schema 與設定相容**：不更改 `AppSettings` 欄位、不改變 `schemaVersion`；舊 `job-journal.json`、`job-ledger.json`、`recent-jobs.json` 完全相容載入。
3. **版本號**：`Config/version.env` 設為 `0.2.1`／`DEFAULT_BUILD_NUMBER=21`（CI 若走 `github.run_number` 則由 workflow 注入實際 build 編號）。

---

## 8. 驗收測試矩陣

自動化測試優先使用 mock `URLProtocol`、fake `CloudNetworkEnvironment` clock/sleeper 與記憶體狀態；不得讀取使用者設定、私人錄音、憑證或發送真實付費 Google API。

| 編號 | 測試情境 | 必須觀測到的結果 |
| --- | --- | --- |
| T01 | Vertex／AI Studio generation 收到 HTTP 200 SSE 但未見 `finishReason` 就 EOF（`CloudIncompleteStreamError`），第 2 次成功 | `logger` 在第 1 次失敗當下立即收到 1 則包含 `incompleteStream`、等待約秒數與 `1／4` 的日誌；第 2 次成功；合計僅 2 次生成請求，無重複日誌 |
| T02 | generation 遭遇 `NSURLErrorDomain -1005`（`connectionLost`），觸發 `transportReset` 後重試成功 | `logger` 收到包含 `NSURLErrorDomain:-1005`、重設連線說明與實際發送次數的日誌；不洩漏失敗 URL 或 `userInfo` 自由文字 |
| T03 | 送出請求遭遇 POSIX 40（`EMSGSIZE`）並重建 Ephemeral Session 重試成功；以及連續兩次 POSIX 40 失敗 | 第一次觸發寫入 `NSPOSIXErrorDomain:40` 重設重試日誌；第二次不再重試且不寫入「即將重試」日誌 |
| T04 | Upload／Poll（`!generation`）遭遇 HTTP 429 或 503 重試；對照 generation 遭遇 HTTP 429／503／`emptyCompletedResponse` | Upload／Poll 寫入各自階段、HTTP 狀態與次數日誌；generation 的 429／503／空 STOP 仍只由 `GeminiGenerationRetry` 寫入 1 則日誌，不重複洗版 |
| T05 | 第 4 次仍失敗、執行中取消（`CancellationError`）、或 root budget 到期 | 不輸出「約 X 秒後重試」之誤導日誌；保持原有失敗分類、額度上限與取消語意 |
| T06 | 底層錯誤 `NSError.userInfo` 夾帶敏感 URL、API key 字串、Bearer token 或錄音背景全文 | 產生的日誌僅含白名單固定代碼與中文分類，完全不含敏感字串與任意 `userInfo` |
| T07 | `JobDebugClipboardTests`：`statusSummary(from:)` 與 `isDebugLine` | `budget created ...` 與 `budget root=...` 不進入收合態兩句摘要；新增的重試日誌可進入白話摘要；`JobDebugClipboard.dump` 仍輸出完整無裁切日誌 |
| T08 | SwiftUI 狀態與元件行為（工作卡 & 最近工作） | 工作卡預設收合；切換展開可呈現完整 `logLines`；後續模擬新增 `logLines` 時父層 `expandedLogJobIDs` 保持展開不被重置；`RecentJobRow` 僅在有 `cloudDiagnostics` 時提供展開檢視 `debugSummary` |
| T09 | 400 行記憶體裁切與 `JobRetentionPolicy.ledgerJobs` 100 行裁切 | 長執行多次重試日誌不會造成結構化 `cloudDiagnostics`、進度或恢復狀態異常 |
| T10 | 完整專案自動化門檻與人工目視檢查邊界 | `SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh` 與 `git diff --check` 全數通過；另列出人工 GUI 目視檢查（760pt 寬度、深色模式、多段長日誌捲動與滑鼠拖選複製、Reduce Motion），且不把自動測試冒充人工目視 |
