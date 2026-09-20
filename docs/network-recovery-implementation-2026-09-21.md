# 網路恢復實作與驗證紀錄

日期：2026-09-21。對應 [網路恢復規格](network-recovery-spec-2026-09-19.md) 方案 A／A1–A4。

## 交付範圍與狀態

已實作有上限的網路等待、同片段重送、上傳確認、失敗診斷、佇列暫停與手動續作。方案 B 的持久化雲端生成工作不在範圍；同步生成中斷後仍可能需要重新生成及再次計費。

本紀錄針對分支 `codex/record-to-text-reliability-v2`、基底 `2fe11e9` 之後的網路恢復實作，已保存為 `dde71e7` 並 push。自動驗證完成後，依使用者打包要求將來源升為 **0.2.1 build 7**，該 checkpoint 的 release build 與 App ad-hoc 簽章驗證通過。後續精簡及最新 **308 XCTest／0 failures** 見 [程式體積檢查](code-size-review-2026-09-21.md)；使用者因 App 執行中要求暫不重建／安裝。已安裝 build 6 不包含本次修改。

自動化驗證使用合成音訊、注入式時鐘、mock transport 與隔離資料夾；不使用私人錄音或有效雲端憑證。真實 VPN／網路切換、兩個 backend 的付費呼叫與 native GUI 操作仍未執行。下方「通過」均指自動化覆蓋範圍。

## 實作摘要

- **A1 診斷**：`CloudFailureDiagnostic` 分開 URLSession timeout、App request deadline、root deadline、STOP 空內容、認證及 transient network。片段與 pipeline 包裝保留型別；失敗／取消／期限及零完成片段均可保存 collector、manifest 與 job 摘要。每工作最多保留 100 個事件，累計事件／生成發送數不受截斷影響。
- **A2 恢復**：每 root 共用 900 秒期限與 300 秒網路等待額度，退避 15／45／120 秒加 0–20% jitter，恢復後至少穩定 3 秒。同待處理片段／模型最多四次 App task 發送，包含 401、POSIX、URI／session 重建。adaptive child 有自己的片段 quota，但沿用 root 期限及等待額度。path 僅作提示，不取消健康的進行中請求；一般連線故障最多換一次 session。
- **上傳確認**：Files 使用 client-generated lowercase name，遺失回應先核對 name／sizeBytes／SHA256；GCS 核對 object name／size／MD5。確認已收到便沿用，未知才有限重傳。第四次 body 回應遺失仍能查 metadata，但不得送第五次 body。生成使用的遠端 URI 經 metadata 確认 404／410 後最多重建一次，不重設 quota／root／等待。
- **Files 輪詢**：60 秒有效輪詢時間只扣除已量測的網路等待；正常 poll 間隔與 GET 耗時計入。GET 最多 15 秒且受有效輪詢餘額限制。upload／generation 使用 App-owned `waitsForConnectivity=true` session；bodyless metadata GET 採 `false` 並由共用 loop 等待，以免把無法由公開 delegate 區分的 GET server time 算成連線等待。
- **A3 狀態與佇列**：恢復耗盡進入 `.interrupted`／`networkRecovery.paused`，後續工作保持 queued。父工作與唯一 continuation ID 同筆落盤成功後才放行；重複點擊、落盤失敗、退出時 flush、落盤後尚未啟動就 crash 都不建立重複付費續作。重啟不自動發送。原 snapshot／sourceSlice 保留，完成片段通過 loader 驗證後沿用。
- **UI**：顯示等待／重試／暫停、已完成片段、剩餘等待與下次重試時間；保留取消操作，並提示未知結果與重複費用。零完成為「重新嘗試」，有完成片段為「從已完成片段繼續」。

## 本次接續修正

交班指出最後一筆網路失敗與停止事件可能因 diagnostic 相同而被去重，導致複製診斷看不出 root deadline。此次在 `CloudFailureEvent` 增加 optional `recoveryStopReason`，保留原始 failure；collector 以兩者共同去重，`debugSummary` 同時列出例如 `category=connectionLost` 與 `recoveryStopReason=rootDeadline`。`waitExhausted`、`attemptsExhausted` 亦同。舊事件缺欄位仍可讀，未知停止原因 decode 為 `unknown`。

此外，先讀取 context 再取得 collector lock，避免 session reset 在 context lock 內記錄 retry 時形成反向取鎖。此次修正不改等待政策或發送次數。

新增兩項診斷測試，另擴充 N06 根期限案例；專用 **17 tests／0 failures**，日誌 `/tmp/record-network-stop-reason-tests.log`。

## N01–N18 自動化驗證對照

測試均位於 `Tests/RecordToTextCoreTests/`。表內使用以下類別簡稱：NR = `CloudNetworkRecoveryTests`；UP = `CloudUploadRecoveryTests`；APP = `AppNetworkRecoveryTests`；AD = `CloudAdaptiveSegmentationTests`；FD = `CloudFailureDiagnosticTests`；VB = `VertexAIGeminiBackendTests`。

| 編號 | 證據 | 驗證結果與界線 |
| --- | --- | --- |
| N01 | NR `testOfflineBeforeSendWaitsForThirtyOr120SecondsAndStability` | 30／120 秒離線後再穩定 3 秒才送出，僅一次生成成功。 |
| N02 | NR `testSatisfiedPathStillRetriesServiceAndOnlyResetsSessionOnce` | path 持續 satisfied，發送時間為 0／15／60／180 秒，服務恢復後成功，session 只換一次。 |
| N03 | NR 四次發送／恢復案例；AD `testNetworkRetryReusesUploadedFile`；APP 真實管線 mock | 未知結果旗標、同模型重試與既有 URI 沿用；UI 已加入可能再次計費文字，尚無 native GUI 點擊驗收。 |
| N04 | NR `testFlappingWaitIsBoundedAndOverlappingWaitCountsOnce`；AD／budget tests | 反覆上下線最多等待 300 秒，重疊等待不重複計時，900 秒 root 餘額為 600 秒；子段沿用 root。 |
| N05 | NR `testFourSendsPauseWithoutFifthOrModelFallback`；VB `test401POSIXAndNetworkShareFourGenerationSends`；UP URI 重建案例 | 四次實際 task 發送上限含 401／POSIX／URI 重建，耗盡暫停，無第五次生成與網路模型 fallback。 |
| N06 | NR `testRootTwentySecondsStopsBefore45SecondRetry`；FD `testRecoveryStopSurvivesDeduplicationWrappingAndDebugCopy` | root 剩 20 秒時即停，保留 connectionLost、rootDeadline、20 秒等待及零 root 餘額；終止事件不被去重，複製摘要可見。 |
| N07 | NR `testCancellationDuringWaitStopsPromptly`；`CloudRequestCancellationTests`；`GeminiCloudResponseValidationTests.testCancelDuringNetworkBackoffDoesNotSendAnotherRequest`；`CloudSegmentBudgetTests.testLateUncooperativeResultCannotPassDeadline` | mock 等待／退避／upload／poll／generation 取消及晚到結果關閉；三個 request 階段各驗證小於 1 秒且僅一次發送。未模擬真實 VPN delegate 行為。 |
| N08 | APP `testRealPipelinePausesFirstJobAndKeepsSecondQueuedThenResumesOnce`、`testFailedContinuationSaveNeverStartsAndRepeatedClicksReuseOneJob` | 第 1 段失敗保存零完成診斷、原快照與 sourceSlice；續作未冒充有完成 checkpoint。 |
| N09 | AD `testThirdSegmentNetworkPauseResumesWithoutReuploadingFirstTwo` | 合成 3 段，前 2 段完成後第 3 段四次失敗；續跑只新增 1 次檔案上傳與 1 次生成，沿用旗標為 true／true／false，前兩段 checkpoint bytes 不變。 |
| N10 | APP `testRealPipelinePausesFirstJobAndKeepsSecondQueuedThenResumesOnce` | 首筆暫停，次筆仍 queued；雙擊只產生一個優先續作，手動續作完成後才處理後續工作。 |
| N11 | APP paused／waiting／unknown restart、`testTerminationWhileContinuationFlushesCannotStartAndRestartReusesItsID` | 持久化再建立 AppViewModel 後 gate 保留、不自動發送；退出與 flush 競爭、父 resolved 而續作 queued 的 crash 窗口沿用同一 ID。屬 model 層重啟驗證。 |
| N12 | UP 全 5 項；`GeminiCloudResponseValidationTests` cleanup cases | Files init／upload／poll、GCS upload 分階段恢復；不轉 inline、不提前生成；上傳遺失回應優先確認，init quota 不被 session 重建放大。 |
| N13 | VB `test401POSIXAndNetworkShareFourGenerationSends` | 401 更新後的連線錯誤保留 network 類別與共用發送 quota。 |
| N14 | FD `testClassificationAndTimeoutSources`；`CloudSegmentBudgetTests`；VB empty STOP cases | request deadline／URLSession timeout／root deadline／STOP 空內容分開；STOP 不當離線，既有有限重試保留。 |
| N15 | NR `testPathBecomingOfflineDoesNotCancelHealthyInflightResponse` | 原請求最後成功，path 變 unsatisfied 不搶先取消，只發送一次。 |
| N16 | FD `testErrorChainPrivacyAndDepth`、`testEventCapPreservesCountersAndTypedCause`；`JobDebugClipboardTests` | 序列化／複製不新增 key、token、URL、IP、SSID、prompt／逐字稿；bounded chain 防循環；120 件保留最後 100 件但總計仍 120。 |
| N17 | FD 舊資料／unknown decode；APP 持久化失敗／重複點擊；`JobRetentionPolicyTests`、`JobPersistenceCoordinatorTests` | 舊格式可讀，limit=0 保留 interrupted／queued，寫入失敗不啟動續作，雙擊與重新嘗試沿用 continuation。 |
| N18 | UP `testFilesInitUploadAndPollRecoverWithoutInlineAndExclude120SecondOutage`；NR `testPollingExcludes120SecondsOfNetworkWait` | PROCESSING 時斷線等待 120 秒，恢復 ACTIVE 後才生成；網路等待不誤耗 60 秒處理額度，餘額不重設，GET 上限 15 秒。 |

## 完整檢查

```sh
SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh
git diff --check
```

本次完整日誌：`/tmp/record-network-complete-checks.log`。以下為停止原因修正與既有 adaptive fixture 修正後，同一份最終程式的執行結果；不是較早快照的 296 或 305 tests 結果。

| 檢查 | 結果 |
| --- | --- |
| version contract／repository hygiene | 通過 |
| Python chunking／runner | 22＋3 tests，全部通過 |
| Swift build | Core、App、self-test、mock-helper、pipeline-self-test 全部通過 |
| executable self-test | 72 項，全部通過 |
| pipeline scenarios | 10 組，全部通過 |
| XCTest | **307 tests，0 failures**；包含原失敗 `testAdaptiveSegmentationChildFailureFailsClosedWithoutFinalTranscript` |
| `git diff --check` | 通過 |

`run-checks.sh` 以退出碼 0 結束，輸出「全部驗證通過」。沙箱的 SwiftPM 使用者快取不可寫提示未阻止檢查；腳本採用專案內的 module cache。先前獨立 `swift test` 因預設 module cache 權限失敗，使用既有 Swift 測試權限重跑後通過；兩者均非測試 assertion 失敗。

編譯有既有 ignored `Sources/RecordToTextApp/Resources/__pycache__/qwen_asr_chunking.cpython-314.pyc` 的 unhandled resource 提示。未刪除使用者本機快取；repository hygiene 不包含該 ignored 檔案。build 7 bundle 驗證確認打包時已排除此快取，包含三支 Python helper、ffmpeg／ffprobe，arm64 App 約 134 MiB。設定與復原資料已備份並核對，模型與 runtime 維持原位。

## 待人工／實機驗收與交付

1. 在可用的 Vertex／AI Studio 測試設定，以可公開短音訊測生成前離線、生成中切網路、120 秒後恢復、等候取消。需分別記錄 backend、實際發送數、恢復停止原因；不可把 mock 的時間或結果當成真實服務證據。
2. native GUI 確認等待文案、暫停操作、雙擊續作、取消、退出／重開；檢查小視窗可操作與診斷複製内容。
3. 程式精簡及自動驗證已完成。使用者最新要求 App 執行中先不要重建，故暫不重建／安裝；DMG 暫不交付。目前 installed build 6 不包含本次修改，精簡前的 build 7 bundle 亦不能作為最後原始碼的交付版本。

先前暫停原因與中間快照見 [2026-09-21 交班](handoff-2026-09-21-network-recovery.md)。本頁為接續後的驗證紀錄，優先於舊交班的待辦狀態。
