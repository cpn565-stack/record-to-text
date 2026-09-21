# 429 冷卻、手動重送與完成後休眠：完成紀錄與歷史交班

日期：2026-09-21，Asia/Shanghai。

**最新狀態：使用者已明確要求實作完成；功能與自動化驗收皆完成。最終完整 checks exit 0，337 XCTest／0 failures。沒有打包、安裝、關閉或重啟正在使用的 App，也沒有執行真實付費 API 或休眠。**

## 最終接續成果（優先於所有下方歷史）

- 補跑最新工作樹完整 checks：先為 335／0，確認前次唯一舊 fixture 失敗已修正。
- 最後補上規格要求的電源事件紀錄：要求接受／拒絕、willSleep／didWake 分開記錄；外部休眠會取消倒數。私有 notification center 與 fake sleep 測試通過，不觸發真電源動作。
- 通知修改後 App service＋sleep 專用 17／0，最終全套 **337／0**，Python 25、自測 72、pipeline 10 組全部通過。
- 最終 log：`/tmp/record-service-final-verification.log`，XCTest 於 2026-09-21 14:55:26（Asia/Shanghai）結束；`git diff --check` 通過。
- C01–C07、R01–R05、S01–S07 的自動化證據已整理至[實作與驗證紀錄](cloud-cooldown-manual-resend-sleep-implementation-2026-09-21.md)。S08 native GUI／實機 sleep-wake 仍待版本交付時人工驗收，不能把 mock 成功當成實機結果。
- 來源仍為 0.2.1 build 7、實作基底 `a6fde8d`；已安裝 build 6 及舊 dist bundle 都不包含這次最後修改。後續交付時才處理打包安裝。

以下保留暫停時的原始交班與 log；其中「維持暫停」「尚未編譯」「待跑全套」均已被此節及正式驗證紀錄取代，不需重做。

---

## 最新移交核對（優先於下方歷史紀錄）

HEAD 實際為 `a6fde8d`，服務冷卻／手動重送／休眠修改仍未 commit。先前網路恢復已提交並完成後續重構，不要再以舊 `2fe11e9` 暫停交班判斷現況。本次接手僅核對與更新文件，沒有新增程式修改或重跑測試。

### 斷網暫停之後已接續完成

- `AppServiceRecoveryTests` fixture 針對非 generation 路由回 404，明確走 Files unsupported fallback；writer 延遲／失敗 hook 改在啟動與憑證載入完成後才開啟，並補保存任務收尾。
- `runJob` 在初始 journal flush 後，再檢查取消要求，避免 `activeExecutionTask` 尚未建立時按取消仍繼續請求。
- transport 保存 429 的 server delay，daily quota 舊錯誤型別也不再遺失 Retry-After／RetryInfo；service pause 保留已有的 server lower bound。
- 診斷歷史繼承已編譯驗證。新 checkpoint 測試涵蓋前 3 段完成、第 4 段 429 暫停後，只轉錄第 4、5 段，前 3 份檔案 bytes 不變，累計 generation count 保留。
- `CloudJobContinuation` 拒絕來源消失、損壞的已完成 checkpoint，或已有完成證據但 manifest 缺失的情況，避免靜默從頭付費。
- optional `continuationCompleted` 在完整成功後保存到父鏈；history limit=0 裁掉成功 child 後仍顯示已完成、不能再次重送。失敗 child 與祖先保留供後續恢復。
- queued continuation 不隨快捷模型設定改變，即使沒有 checkpoint 也保持原快照；舊 forward link 在重啟時補 parent link。
- 刪除 queued child 撤銷父關聯及本次授權；晚到 flush 必須再次核對 child 仍 queued、父子關係仍成立才可啟動。
- 舊憑證遷移測試補上實際 source fixture，維持重送前來源檢查及原有斷言。

### 已從現存 log 核實的結果

| log | 結果 |
| --- | --- |
| `/tmp/record-service-app-regression.log` | App service 5＋Core service 9，共 14／0 |
| `/tmp/record-service-checkpoint-tests.log` | network／service 多片段續作與 checkpoint，共 7／0 |
| `/tmp/record-service-last-edges.log` | service／sleep／checkpoint／retention，共 37／0 |
| `/tmp/record-service-final-app-edges.log` | 最後憑證 fixture、快照保護、App network／service，共 **15／0** |
| `/tmp/record-service-final-checks.log` | 較早完整 XCTest **334 tests／1 failure**；舊憑證 fixture 缺來源檔。已修正並通過上述最後 15 項，但未再跑最終完整 checks |

最新接手核對 `git diff --check` 通過；程序檢查沒有本專案 Swift test／XCTest／run-checks／self-test 還在執行。原本正在使用的 App 沒有被關閉或改動。

### 下次第一步

1. 以目前工作樹及此節為準，不要重做上方已通過的功能。先跑 `SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh`，確認最後 15 項通過之後的整份來源狀態沒有回歸。
2. 對照服務冷卻／手動重送／休眠規格，整理最終驗收矩陣；若完整 checks 失敗，先釐清 fixture 與產品行為，不能只改斷言求通過。
3. 完成差異審查、更新規格狀態及驗收文件，再依有效授權處理 commit／push。本次移交沒有替另一位 agent 完成提交推送。
4. 持續遵守不打包、不安裝、不關閉或重啟正在使用的 App；不執行真休眠、私人音訊或付費 API 驗收。

---

以下為較早交班；「App 測試尚未編譯」等敘述已被上方實測結果取代。

## 最新接續進度（網路斷線前再次暫停）

此節優先於下方第一次用量暫停的歷史紀錄。HEAD 仍為 `a6fde8d`，所有新增修改／測試都留在 working tree，尚未 commit／push、打包、安裝或重啟 App；沒有真實付費 API 或休眠要求。

### 已修改

- App 休眠資格改比較 writer 回報的 `durablePersistenceRevision` 與目前修訂；flush 返回亦更新狀態。模型下載、憑證載入／保存、duplicate／prompt 等狀態加即時 refresh。
- 手動續作新增本次 process 的 `authorizedContinuations`，允許已保存且手動選定的續作通過其他 paused 父工作 gate，普通 queued 仍停住。MainView 顯示保存中／排隊／重送中／已完成並停用重複按鈕；保存失敗或重啟待確認時仍可再按，沿用同一 ID。
- `JobRetentionPolicy.continuationAncestorIDs` 保留待處理續作祖先，涵蓋舊 forward network link；刪除歷史也保護這些祖先。
- service snapshot 即時計入進行中的等待；finishWait 在建立期限錯誤前結算，外層 timer 也能讀到實際等待。fallback 遵守原 serverNotBefore；Retry-After 增加兩種舊 HTTP-date 格式。
- `CloudJobContinuation` 取 network／service completed count 的最大值；有完成證據而 manifest／recovery 缺失或沒有完成片段時報错，不靜默從頭轉錄。
- **最後一次通過測試之後**，再加續作診斷歷史：child 沿用原 cloudDiagnostics，checkpoint loader 帶 failureHistory，engine 新 collector 繼承有界事件與累計次數。**這幾項尚未重新編譯或測試。**

### 本次測試證據

| log | 已完成結果 |
| --- | --- |
| `/tmp/record-service-initial-regression.log` | `AppNetworkRecoveryTests`＋`CloudNetworkRecoveryTests`：18 tests／0 failures |
| `/tmp/record-service-new-tests.log` | 新 `CloudServiceRecoveryTests` 9＋`QueueCompletionSleepTests` 9：18 tests／0 failures |

新測試驗證兩 backend 的 429 30／60／120 秒、四次上限、混合 network／429、Retry-After、upload／poll deadline、daily quota、fallback server lower bound、冷卻取消及 root 診斷；休眠全部用 fake service，含 default-off、成功憑據跨裁剪、續作替換、倒數競爭、保存失敗、系統拒絕與 wake。初次取消測試曾因 observer 重複 fulfill expectation crash，已改只 fulfill 一次，上表為修正後通過結果。

**剛新增 `Tests/RecordToTextCoreTests/AppServiceRecoveryTests.swift`，尚未編譯／執行。** 包含完整 pipeline 429 暫停→手動去重→全部成功 fake sleep、多 paused 父 gate、build 6 failed parent 的已落盤 queued crash window、延遲 journal／匯入與 consent hook、serverNotBefore 與取消。下次先編譯這些測試，修正 fixture 或實作問題後再擴充驗收。

`TestSupport.swift` 新增有界 eventually 與可取消的 `RecoveryTestGate`。所有本輪已啟動 Swift test session 都已返回；暫停程序檢查未發現 Swift build/test/XCTest/run-checks/self-test。`git diff --check` 無輸出通過；程序篩選的無匹配 exit 1 不是差異檢查失敗。

### 下次優先順序

1. 先跑 `swift test --disable-sandbox --filter 'AppServiceRecoveryTests|CloudServiceRecoveryTests|QueueCompletionSleepTests|AppNetworkRecoveryTests|CloudResumeCheckpointTests|JobRetentionPolicyTests'`，確認最後新增歷史繼承程式與 App 測試可編譯、修到通過。
2. 檢查 App 測試是否確實涵蓋 writer 已 submit 但尚未 durable 的窗口；不能只靠 active queue task 阻擋來通過。失敗 writer 的測試收尾亦需避免背景保存 task 存活至 fixture 刪除後。
3. 補多完成片段 service 暫停／手動續作的實際 checkpoint bytes 與發送數驗證；審查日額度錯誤是否保留 server Retry-After、清理錯誤與 pause 原因、不相關 HTTP／STOP 回歸。
4. 檢查 service／network 混合歷史與 terminal snapshot、手動保存失敗重按、退出／重啟；native GUI 與真休眠仍不執行。
5. 再跑 `SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh`、差異檢查、更新正式驗收紀錄。不要拿上面小範圍通過替代最後檔案狀態完整回歸。

---

以下為第一次用量暫停時的交班，已完成的部分以上方更新為準。

## 1. 保存狀態與操作限制

- 專案：`/Users/mike/Projects/AI工作區域/record-to-text`。
- 分支：`codex/record-to-text-reliability-v2`；HEAD `a6fde8d`。
- 先前網路恢復 `dde71e7` 與共用 Gemini 解析／重試 `a6fde8d` 已 commit／push。本輪新功能所有修改仍在 working tree，**尚未 commit／push**，不要還原或覆蓋。
- 來源版本仍 0.2.1 build 7；已安裝 App 最後核對為 build 6。使用者要求「App 正在 run，先不要重建」仍有效；本轮只編譯開發 target，沒有重新打包、安裝、關閉或重啟使用者 App。
- 使用者說 DMG 暫時不用做。既有 `dist` 的 build 7 App／DMG 是較早精簡前快照，不含本輪功能，不可當最新成果交付。
- 本輪沒有發送付費轉錄或重送私人音訊，也沒有實際呼叫新增的休眠 API。
- 所有本輪工具啟動的 Swift build session 均已结束。最後 `git diff --check` 通過；沒有在背景繼續跑本輪測試或建置。
- Engram-only，禁止自動回退 legacy vault／Codex native memory。僅存整理後技術資訊，不存私人音訊、逐字稿、來源名稱／路徑、憑證或原始 prompt。
- 本次 runtime session：`01a0bfcb-d8ca-7a11-910b-2ef684e36cb5`。新 session 必須採新 runtime 提供的 ID，不要自行沿用作新身份。

## 2. 需求與採用策略

依據：[功能規格](cloud-cooldown-manual-resend-sleep-spec-2026-09-21.md)。使用者在規劃後已指示「直接開始實作」，最新指示則為暫停。

1. HTTP 429 冷卻延長為 30／60／120 秒，加 0–20% 正向 jitter；尊重 `Retry-After`／`RetryInfo` 較晚期限。保留每待處理片段／模型最多四次實際發送及 900 秒 root deadline。網路等待 300 秒與服務冷卻分開計算。
2. 統一手動再送入口，有有效檢查點便只重送未完成片段，沿用原快照；journal 先保存唯一 continuation，再發送。雙擊、重啟與退出不得產生重複付費請求。
3. 完成後休眠預設關，使用者本次勾選才開啟，不保留至下次啟動；本次工作全部成功且輸出／journal 已保存才進入 30 秒可取消倒數。

「失敗或暫停是否仍休眠」的選項未收到答覆；規劃已明示採全部成功才休眠，使用者隨後要求實作。此為採用的保守假設，不是使用者逐項指定。失敗、缺口、暫停不觸發 App 主動休眠，歷史舊失敗不應永久阻止新批次。

## 3. 已寫入但尚未完成驗證的程式

### Core

- 新增 `Sources/RecordToTextCore/CloudServiceRecovery.swift`：服務冷卻／重試／暫停狀態、停止原因、獨立等待累計、伺服器 not-before、可注入時鐘與 sleeper。作為既有 root recovery context 的 peer，共用期限而不占用網路等待額度。
- `GeminiGenerationRetry.swift` 接入 generation 429；`GeminiTransportHelper.swift` 接入非 generation 的 429，保留原階段 quota／有效輪詢期限。解析數字秒數、RFC 1123 日期及 RetryInfo，健康 PROCESSING 輪詢沿用原間隔。
- `CloudNetworkRecoveryPolicy.swift` 持有 service context；`TranscriptionEngine.swift` 接 observer、manifest 保存與外層 root timer；`Models.swift`／`AudioSegmentation.swift` 新增 optional 狀態及續作欄位，以維持舊資料相容。
- `CloudFailureDiagnostic.swift`／`CloudJobDiagnostics.swift` 保存 HTTP 429、服務停止原因與等待秒數；去重納入服務停止原因。
- 新增 `CloudJobContinuation.swift` 集中快照、檢查點及來源驗證。有已完成片段卻找不到有效檢查點時報錯，避免靜默從頭付費重做；帶入尚未到期的 serverNotBefore。
- `JobRetentionPolicy.swift` 保護 continuationPending 的工作。

### App

- `AppViewModel.swift` 新增共用 `resendCloudJob`；原網路续跑、檢查點續跑、雲端一般重試接到共用入口。新增 generic continuation ID／parent／pending，沿用舊 network continuation 欄位相容舊資料。
- 建立 continuation 後先保存／flush，再解除父 gate、排入優先位置；處理啟動時 pending／已落盤 queued crash window，退出時保留 gate。實際新輪開始前等待原 serverNotBefore；等候可取消。
- 新增 `Sources/RecordToTextApp/QueueCompletionSleepCoordinator.swift`：本次選取工作群組、獨立完成記錄、倒數與取消、wake 後關閉、可注入 fake sleep／等待服務。
- 同檔 native `SystemSleepService` 使用 IOPMFindPowerManagement／IOPMSleepSystem；目前只編譯過，未真實執行。
- `AppViewModel` 接 jobs／持久化／匯入／取消等狀態與最終 flush；`MainView.swift` 加休眠勾選、倒數、服務冷卻及手動再送 UI。
- 未將本次休眠功能做成 launch agent 或排程。

以上是實作進度，**不是已通過測試的完成清單**。

## 4. 已發現的待修與待審查點

優先處理前兩項，再擴充測試。暫停前沒有繼續修這些問題。

1. **休眠倒數開始前的持久化判定不完整。** 目前 `persistenceSubmission` 結束只代表已 submit，`JobPersistenceCoordinator` 仍可能正在寫入。最終 prepare callback 會 flush 並重新判定，防止提前真正休眠；但倒數本身可能在 durable revision 達成前開始。應將 writer 的 durable revision／完成狀態接入資格判定與 refresh，不能只看 submit task 為 nil。注意初始化及 actor／鎖順序。
2. **非 job 狀態變更缺少即時重評估。** `sleepIsBlocked` 讀取模型下載、憑證、prompt／duplicate 等狀態，但部分屬性沒有變動 hook；倒數中改變時，coordinator 的 cached blocked 可能未即時更新。最終 callback 會再讀一次，但 UI 倒數應當下取消，條件恢復後再評估。
3. **手動按鈕的 pending／active UI 尚未補齐。** 底層已有 ID 去重，按鈕仍可能顯示可按；應在唯一 continuation queued／running 時顯示對應狀態並停用，測試雙擊只有一份工作與一次送出。
4. **多個暫停父工作的 queue gate 需審查。** 現在全域 `queuePausedForRecovery` 可能讓已手動選定的 continuation 被另一個舊 paused 父工作阻住。驗證只有獲手動允許的續作能優先通過 gate，普通 queued 不可偷跑；同時保留 crash／退出保障。
5. **續作資料與 checkpoint 邊界需測試。** 檢查舊 network／service 診斷歷史保留，以及 completed count 的 `network ?? service` 優先序（network 為 0 而 service 大於 0 的情況）。來源缺失、manifest 不完整、checkpoint 缺失不得静默全量重做。
6. **冷卻末端 snapshot 可能漏掉最後等待。** `rateLimited` 的 defer 才更新 waitedSeconds；若 sleep 因 root deadline 拋錯，先建立的 exhausted error snapshot 是否漏計需檢查。明確日額度、混合網路／429、poll 階段期限與 fallback 跨模型的 serverNotBefore 也未驗證。
7. **成功／失敗原因轉換需審查。** transport 成功後 resolve 與後續 response parse、network transient、外層 root deadline 的先後不能留下舊服务原因或消掉最後停止事件；cleanup 錯誤也不得覆蓋主因。
8. **Retry-After 日期格式目前只覆蓋 RFC 1123。** 規格與測試需確認是否還要支援 HTTP-date 舊格式；各異常數值／日期不能造成零延遲迴圈。
9. **休眠工作群組與生命周期未驗證。** 歷史裁剪、刪除／取消、重送父子替換、新工作到達、匯入中、模型下載、writer 失敗、wake 及 coordinator/task 清理都需測試。不能以 `isTerminal` 或單純 queue drain 判定成功。

## 5. 驗證證據與限制

| 項目 | 結果 |
| --- | --- |
| 本輪初次 Core target build | 曾因不同 error 類型的巢狀三元運算失敗，已改明確 if/else |
| 最後 `swift build --disable-sandbox --target RecordToTextApp` | **通過**；包含上述新檔，log `/tmp/record-service-app-build.log` |
| 本輪 XCTest／self-test／完整 checks | **尚未新增或執行**，不能宣稱回歸通過 |
| 暫停前 `git diff --check` | 通過 |
| GUI、真正休眠、真實網路或付費 API | 未驗收 |

較早 `a6fde8d` 精簡版本完整 checks 曾通過 XCTest 308、Python 22＋3、self-test 72、10 組 pipeline scenario；證據在 `/tmp/record-network-refactor-checks.log`。**這是新功能之前的快照，不能替代本輪測試。**

既有 `Resources/__pycache__/qwen_asr_chunking.cpython-314.pyc` unhandled resource 提示未清除。

## 6. 下次接續順序

1. 讀本交班、功能規格與 `git diff`，不要重做已提交的網路恢復／Gemini 精簡，不要安裝現有 dist 快照。
2. 先修第 4 節休眠 durability、狀態 hook 與手動續作 gate／按鈕；保留新檔集中責任，避免把判斷繼續堆進 `AppViewModel`。
3. 按規格 C01–C07／R01–R05／S01–S08 加真正有價值的 mock／fake clock 測試。冷卻涵蓋 30／60／120、server lower bound、四次上限、混合網路原因、日額度、root／poll deadline、取消；手動涵蓋 checkpoint 重用、舊資料、雙擊、crash／退出；休眠必須使用 fake service，涵蓋 default-off、只觸發一次、保存失敗、全成功資格及倒數競爭。
4. 先跑相關測試，修完再執行完整檢查（不建立 App bundle）：

   ```sh
   SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh
   git diff --check
   ```

5. 更新實作／驗收紀錄，明確分開 mock 與實機驗收。依既有授權完成 commit／push 前，先確認本輪測試與 diff；安裝／重啟限制仍有效，DMG 不做。

## 7. 先前排程及錯誤診斷背景

- 一次性凌晨排程確實在 2026-09-21 03:00 執行並讓電腦休眠；當時判斷是沒有 queued／active，因此包含失敗工作，不代表全部轉錄成功。
- 查核後發現原 plist 的 Hour／Minute 會每日重複，已 bootout 並移出 LaunchAgents 至 App Support 的 `.completed-20260921.plist`，已確認原服務未載入。**不要重啟此舊排程。**
- 使用者提供的 build 6 紀錄，一筆首段四次 429，另一筆前三段完成、第四段三次網路失敗後一次 429；最後摘要只顯示末次錯誤。後者前三段檢查點經唯讀核對可重用；本輪未替使用者再送。
- 四次發送上限涵蓋各種可重試原因；900 秒是最長期限，不保證一定用滿。429 不能僅由訊息判定特定帳號配額或 VPN，較長冷卻也不保證服務容量恢復。
