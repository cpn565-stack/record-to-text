# 網路恢復：2026-09-20 第二次安全暫停交班

> 歷史交班，已於 2026-09-21 接續實作並再次安全暫停。請優先讀 [最新交班](handoff-2026-09-21-network-recovery.md)，本頁待辦與測試狀態不再代表目前版本。

## 工作樹與範圍

- 專案：`/Users/mike/Projects/AI工作區域/record-to-text`。
- 分支：`codex/record-to-text-reliability-v2`，HEAD 仍為 `2fe11e9`，比 origin 多一個 commit。
- `2fe11e9` 是實作前的文件／驗證工具 checkpoint。**本輪程式、測試與交班均未 commit／push**，保留全部 working diff，不要 reset。
- 需求：[network-recovery-spec-2026-09-19.md](network-recovery-spec-2026-09-19.md)，方案 A，A1–A4；不是 Interview Copilot。
- 尚未完成規格或交付，未安裝 App、未部署、未提高版本、未呼叫付費 API、未操作真實網路切換。

## 這次續作已寫入

1. 延續 A1：新增 `CloudFailureDiagnosticTests`，測分類、App／URLSession／root timeout、NSError allowlist、八層深度與循環、100 事件截斷後累計、未知 enum、舊 segment decode、分段 wrapper。
2. 新增 `CloudNetworkRecoveryPolicy.swift`：可注入 monotonic clock／sleep／path／session factory；root 共用 300 秒等待、15／45／120 秒＋jitter、3 秒穩定、wait interval 聯集、最多一次 session reset。`NWPathMonitor` 只提供提示。新增 waiting／retrying／paused／resolved model、stop reason、generation attempts 與 Files effective polling budget。
3. `GeminiTransportHelper` 集中 network／POSIX 重試；generation 的四次計數涵蓋 401 後重送；upload／poll 有各自 transient loop。一般 HTTP/model 重試仍由 backend 控制，四次發送額度共用。預設改為 App-owned ephemeral URLSession 並啟用 waitsForConnectivity。
4. `CancellableCloudRequest` 加入 task delegate，追蹤 connectivity wait、取消與額度；不因 path 變化取消健康中的 request。
5. 兩 backend：transcribeDetailed 建立共用 context；原 POSIX wrapper 縮成共用 transport 呼叫；實際 metadata retryCount 包含內層發送。Files 僅明確 HTTP 404/405/501 不支援時 inline fallback；網路／malformed file 不再默默 fallback。輪詢 60 秒排除已量測網路等待。
6. Engine 以 root 字典共用 network context，經 PipelineUpdate 通知 UI，manifest/recovery 保留 networkRecovery；失敗 wrapper 讓 App 取得 paused 狀態。
7. App：network gate 從 persisted interrupted+networkRecovery 推導；drain/schedule 均檢查；首段失敗也留原快照。續作 ID 與父狀態同一 journal snapshot，flush 成功才解 gate，重複點擊去重並優先插到第一個 queued 位置。取消 paused 不自行啟動後續工作。重啟 waiting 轉 paused，queued 保留 queued。等待／結果未知／手動續作 UI 已接入。
8. 增加 App 的可注入 engineFactory 供整合測試。新增 `CloudNetworkRecoveryTests`、`AppNetworkRecoveryTests`；Vertex 新增 401→POSIX→連線失敗共用四次上限測試。
9. 最近兩個小修：刪除 paused 工作不讓 pending manualDrain 自動啟動後續佇列；Retry-After 不再被 60 秒 cap 截短。這兩項尚無專用回歸。

## 驗證：請分清版本與範圍

- `/tmp/record-network-new-tests.log`：**11 tests／0 failures**（CloudNetworkRecoveryTests 7＋CloudFailureDiagnosticTests 4）。驗證 offline 30/120 秒、path satisfied 但服務失聯、四次停止、300 秒 flapping、20 秒 root 限制、等待取消、有效 polling 時間。
- `/tmp/record-network-integration.log`：**42 tests／0 failures**。組合為 AppNetworkRecoveryTests 當時 4、CloudAdaptiveSegmentationTests 17、GeminiCloudResponseValidationTests 20、Vertex `test401POSIXAndNetworkShareFourGenerationSends` 1。包含 paused/waiting 重啟、recent limit=0、續作儲存失敗與重複點擊、取消 gate、既有續跑與 late callback。
- 上述 42 項之後新增 `testRealPipelinePausesFirstJobAndKeepsSecondQueuedThenResumesOnce`。最新程式**編譯成功**，但這項測試在第一次成功續作觸發 App 完成通知時 crash，**不是通過**。
- crash log：`/tmp/record-network-pipeline.log`。`UNUserNotificationCenter.current()` 在 xctest executable 無 App bundle 時拋 `NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`，signal 6。測試已結束，沒有留在背景。最後一個 unified exec session 73033 可收取 exit 狀態，但 process 已不在。
- `git diff --check` 在第二次收尾時通過。尚未跑最後版本的全套 XCTest／Python／executable pipeline checks，也未做 GUI 驗收。
- 編譯警告：`CloudNetworkRecoveryTests` 的 session factory closure 直接更改 captured `resets`，需改成鎖保護計數器以符合 Swift 6；另有原先 source Resources 下 `__pycache__` 未處理警告，未擅自清理。

## 下次第一步

1. 先修**測試設定**：在 `testRealPipelinePausesFirstJobAndKeepsSecondQueuedThenResumesOnce` 建立 AppViewModel 並 `waitForCredentialLoading()` 後、`startQueuedJobs()` 前，呼叫 `model.setNotificationPreference(false)`；也檢查是否需關閉完成自動開稿／複製設定。不要為測試繞過正式 pipeline 邏輯。
2. 重跑該項。它使用本機合成 2 秒 sine＋mock transport，應驗證第一筆四次失敗→interrupted+gate，第二筆仍 queued，首段 recovery 有 diagnostics 卻沒有 partial transcript／可重用 checkpoint；雙擊續作只建一筆，原快照保留，續作優先，總共六次 generation（四失敗＋續作及第二筆各成功一次）。
3. 修正並驗證下節待完成點，再跑相應測試及完整既有檢查。所有測試只用 mock／合成音訊。

## 尚未完成／必須 review 的地方

- **不能宣稱 N01–N18 全數驗收。** N12/N18 還需 Files init/upload/poll 以及 GCS upload 的逐階段實際 mock 注入，不只測 standalone polling budget；N07 各操作取消／delegate wait 及 N15 in-flight path 改變也需專用測試。
- URLSession task delegate 目前在 didSendBodyData／didFinishCollecting／completion 停止等待計時；GET 沒 request body，可能把等待後的正常 GET 回應時間算入 network wait。須核對官方可觀測訊號、以 task metrics 校正並測試，滿足「實際傳輸／等生成不計入 300 秒」；不要假裝已有精確測量。
- context 的 lastFailure 在成功後尚未清除；成功恢復後若之後純模型／服務端 root deadline，可能沿用舊網路原因進 paused。應分開歷史診斷與目前停止原因，確保規格的原因區分。
- 遠端 Files/GCS URI 過期的有限重建尚未實作；upload 成功回應遺失的官方 session／metadata 對帳亦尚待做。目前主要是同 request 有限重送，不可宣稱避免重複遠端資源。
- generation quota 目前每次 executeWithRetries 建立；若新增 URI 重建，必須在同片段／模型沿用 quota，不可重設。可考慮 per-transcribe TaskLocal model→quota ledger，adaptive 新片段則另立 quota，root wait/deadline 仍共用。
- 審查 engine 的 per-segment defer 再寫 manifest、catch/type 封裝、取消零完成保存，以及 paused waiting journal 更新順序。原子写入失敗不可釋放 gate；不要讓晚到 callback 發布稿件。
- App resume flush 失敗保留同一 queued continuation 供重試；需補成功落 journal 後、尚未啟動即 crash 的恢復測試。unknown network enum 現在保守 gate，但手動恢復只接受 paused，需確認 UI/遷移行為。
- 單次操作 timeout 在分類上已分開，但是否應將純 App requestDeadline 視為網路暫停，需對照規格；不可一概聲稱離線。
- A1 失敗診斷、私密資料 allowlist、必要事件欄位與 debug copy 最後仍需做全面稽核。

## 重要檔案與記憶

- 新增：`Sources/RecordToTextCore/CloudFailureDiagnostic.swift`、`CloudNetworkRecoveryPolicy.swift`。
- 修改：Core 的 `CloudJobDiagnostics`、`CloudSegmentBudget`、`CancellableCloudRequest`、`GeminiTransportHelper`、兩 backend、`TranscriptionEngine`、`Models`、`AudioSegmentation`。
- UI／佇列：`Sources/RecordToTextApp/AppViewModel.swift`、`MainView.swift`。
- 測試：新增三份 `CloudFailureDiagnosticTests.swift`、`CloudNetworkRecoveryTests.swift`、`AppNetworkRecoveryTests.swift`；修改 cloud adaptive/reliability/budget/Vertex 既有測試。
- 本輪沒有修改系統網路、安裝 App 或真實使用者資料。程序檢查只看見既有另一專案 interview-copilot 的舊 helper PID 30257／61322；不屬本輪，未停止。
- Engram 架構記憶 topic `architecture/cloud-network-recovery`，並保存本次暫停摘要。
