# 網路恢復：2026-09-21 安全暫停交班

**歷史暫停交班。使用者已於 2026-09-21 要求接續；診斷停止原因已修正，最新實作與驗證狀態見 [實作與驗證紀錄](network-recovery-implementation-2026-09-21.md)。下方保留暫停當時的狀態。**

## 保存狀態

- 專案：`/Users/mike/Projects/AI工作區域/record-to-text`。
- 分支：`codex/record-to-text-reliability-v2`；HEAD `2fe11e9`（最初要求的規格 checkpoint commit）。
- 本輪所有程式、測試與交班保留在 working tree，尚未 commit／push／安裝／部署；版本仍 0.2.1 build 6。
- 暫停前 `git diff --check` 通過；程序檢查沒有仍執行中的本專案 XCTest、Swift test、run-checks 或 executable self-test。
- 最新來源可編譯；最後相關回歸 **17 tests／0 failures**。不能宣稱最終全套驗收完成。
- 需求仍為 [2026-09-19 網路恢復規格](network-recovery-spec-2026-09-19.md) 的 A1–A4／方案 A；方案 B 持久化雲端 job 不在範圍。

## 本輪完成

1. 修復 `AppNetworkRecoveryTests` 的 xctest 通知 crash：測試先 `setNotificationPreference(false)`；正式 App 通知不變。真實 engine＋合成音訊＋mock transport 已通過四次失敗暫停、後續 queued、零完成診斷保存、双擊續作去重及優先執行。
2. `CloudNetworkRecoveryContext.requestSucceeded()` 清除目前失敗原因與停止原因，保留歷史事件／累計等待；恢復成功後的純 root deadline 不再沿用舊離線原因。
3. `CloudModelAttempts` 為單次 pending segment 持有模型及上傳階段 quota，`CloudRequestAttempts` 在具體 task resume 前計數。URI 重建、Files session 重建、401、POSIX 不會重設發送上限。adaptive child 另有 segment quota，仍共用 root deadline／wait。
4. Files 指定 client-generated lowercase resource name；上傳回應遺失後先 `files.get` 核對 name、sizeBytes、SHA256。GCS 核對 object name、size、MD5。確認成功便沿用；未知才有限重傳／重建 session；最後第四次上傳回應遺失仍可做 metadata 確認，不發第五次 body。
5. generation 回應 400／403／404／410 且已使用遠端檔案時，metadata 確認 404／410 才重建，最多一次，沿用 quota、root 與 wait。查詢／重建失敗也會走已知資源 cleanup。
6. bodyless metadata GET 使用 App-owned `waitsForConnectivity=false` session，失敗交給共用 recovery loop 計時；upload／generation 保持 `waitsForConnectivity=true`。這是對規格 session 建議的具體細化：公開 delegate 沒有 GET 連線恢復回呼，不能把正常 GET server time 當網路等待。GET 仍有 15 秒／有效輪詢餘額上限。
7. `CancellableCloudRequest` 的 delegate 安裝／finish 改用同一鎖；body 首次進度停止 connectivity wait 並解除等待 UI，晚到 waiting callback 不會重新開始。實際 upload／poll／generation 取消均有專用小於一秒 mock 測試。
8. `CloudHTTPFailure` 保留上傳／poll HTTP status 與 stage，避免字串包裝後丟失原因。`CloudRetryReason` 補 unknown decode。診斷序列化／debug copy 測試擴大為 URL、key、token、SSID、IP、prompt／逐字稿不洩露，保留事件上限與未截斷計數。
9. engine 外層 root timer 若在網路恢復期間獲勝，仍轉 network paused；前兩段完成、第三段四次連線失敗後續跑，驗證前兩段不重傳、只再上傳／生成第三段，checkpoint bytes 不變。
10. App 重啟時 unknown recovery state 正規化為可操作 paused；父工作 resolved、但已落盤 continuation 尚 queued 的 crash 窗口亦恢復父 gate。`isTerminating` 阻止續作 flush callback 在退出時重啟付費請求，重啟沿用同一 continuation ID。
11. 等待 UI 顯示「前次請求結果未知、重送可能重複費用」。
12. executable SelfTest 的 inline 25 MiB 上限案例明確 `useFilesAPI=false`。舊案例依賴預設 Files 失敗後 fallback，可能以假 key 發出初始化请求；新的容量測試完全不必連外。

官方核對：Files 自訂 name 與 SHA256 metadata 見 [Gemini Files API](https://ai.google.dev/api/files?hl=en)；GCS 查詢與雜湊欄位見 [objects.get](https://docs.cloud.google.com/storage/docs/json_api/v1/objects/get) 及 [Object resource](https://docs.cloud.google.com/storage/docs/json_api/v1/objects)。2026-09-21 已查閱。

## 驗證證據與先後順序

| 紀錄 | 結果與範圍 |
| --- | --- |
| `/tmp/record-network-app-resume.log` | App 5／0；已修通知 crash，含端到端恢復 |
| `/tmp/record-network-upload.log` | 初版上傳恢復 4／0；Files init/upload/poll、120 秒離線、遺失回應確認、URI 重建與 GCS |
| `/tmp/record-network-full-swift.log` | 較早快照全套 **296／0**，不是最終檔案狀態 |
| `/tmp/record-network-cancel.log` | 12／0；取消三階段、inflight path 變 offline 仍成功、delegate 計時、恢復後 root 原因 |
| `/tmp/record-network-checkpoint.log` | 第三段失敗、重用前兩段專用 1／0 |
| `/tmp/record-network-quotas.log` | 共用 quota 版本相關 17／0 |
| `/tmp/record-network-final-edges.log` | App／上傳 11／0，含 Files 初始化 quota 不被 session 重建放大 |
| `/tmp/record-network-final-checks.log` | Python **22＋3／0**、Core／App／三 executable build、self-test **72／0**、10 組 pipeline scenarios 通過；XCTest **305 tests／2 assertions failed**，同一個既有 fixture 案例，詳下 |
| `/tmp/record-network-final-regression.log` | 最後 **17／0**：App 7、diagnostic 4、upload 5、原失敗 adaptive case 1；包含退出／落盤窗口、第四次 upload metadata 確認、最新 privacy／unknown enum |

最後完整 checks 的兩個 assertion 是 `testAdaptiveSegmentationChildFailureFailsClosedWithoutFinalTranscript` 預期保留 HTTP 400／Invalid argument。原因是舊 `MockAIStudioTransport` 的 File ID 用 uppercase UUID、未實作 metadata GET，新增過期檢查後先撞上不合官方 File.name 格式的 fixture。已將 fixture ID 改 lowercase、補 GET 查已建立檔案，**原 assertion 保留且專用回歸已通過**。尚未在此修正後再跑整份 checks。

編譯仍有既有 `Sources/RecordToTextApp/Resources/__pycache__/qwen_asr_chunking.cpython-314.pyc` 的 unhandled resource 提示；未擅自清除。原 captured `resets` Sendable 警告已改鎖保護值。

## 下一次接續順序

1. 先讀本交班與 `git diff`，不要重做已完成內容。上一份交班中的通知 crash、URI 重建、lost upload、GET 計時及 continuation crash 窗口已處理。
2. 尚有一個**已發現、未修改**的診斷收尾：`CloudFailureDiagnostic.classify(CloudNetworkRecoveryExhausted)` 現在直接回傳 lastFailure；若 stopReason 是 rootDeadline，manifest／job 的 networkRecovery 有 root 原因，但 `CloudJobDiagnostics.debugSummary` 只列事件，可能看不到最後為何停止。考慮 terminal root event 使用 segmentDeadlineExceeded／timeoutSource.segmentDeadline，同时保留 recovery.lastFailure；或給 `CloudFailureEvent` 加 optional recoveryStopReason。collector 目前相同 diagnostic 去重，需要連 stopReason 一起考慮，避免最後停止事件被消掉。**截至暫停尚未寫任何這項修改。**
3. 做以上必要診斷調整後補專用測試，再執行：

   ```sh
   SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh
   git diff --check
   ```

   上次最後 17 項指令為：

   ```sh
   swift test --disable-sandbox --filter 'CloudAdaptiveSegmentationTests.testAdaptiveSegmentationChildFailureFailsClosedWithoutFinalTranscript|CloudFailureDiagnosticTests|CloudUploadRecoveryTests|AppNetworkRecoveryTests'
   ```

4. 對照 N01–N18 補最後驗收文件，更新規格開頭仍為「尚未修改 App」的歷史狀態，連到實作／驗證紀錄。尚未建立最終 implementation report、尚未做 native GUI 操作驗收／bundle 交付。
5. 目前沒有使用私人音訊或有效憑證做付費轉錄；真實 VPN／網路切換與兩 backend 的付費驗收尚未做，不能把 mock 結果描述為實機網路驗收。未安裝新 App。

## 主要檔案

- Core：新增 `CloudFailureDiagnostic.swift`、`CloudNetworkRecoveryPolicy.swift`；修改 `GeminiTransportHelper`、`CancellableCloudRequest`、`CloudJobDiagnostics`、`CloudSegmentBudget`、兩 backend、`TranscriptionEngine`、`Models`、`AudioSegmentation`。
- App：`AppViewModel.swift`、`MainView.swift`。
- 新測試：`AppNetworkRecoveryTests.swift`、`CloudFailureDiagnosticTests.swift`、`CloudNetworkRecoveryTests.swift`、`CloudRequestCancellationTests.swift`、`CloudUploadRecoveryTests.swift`。
- 既有測試：cloud adaptive/reliability/budget/Vertex 與 `Tools/SelfTest/main.swift`。
- Engram：project `record-to-text`；本輪 runtime session `01a0bc67-1498-79b1-b691-f17881a57654`。仍只用 Engram，禁止自動回退 legacy vault/native memory。
