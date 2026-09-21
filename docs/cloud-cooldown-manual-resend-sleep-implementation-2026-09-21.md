# 雲端冷卻、手動重送與完成後休眠：實作與驗證

日期：2026-09-21。**實作與自動化驗收完成，最終 337 XCTest／0 failures；尚未打包安裝或實機驗收。** 對應[功能規格](cloud-cooldown-manual-resend-sleep-spec-2026-09-21.md)，分支 `codex/record-to-text-reliability-v2`、基底 `a6fde8d`。

## 實作範圍

- **429 冷卻**：AI Studio／Vertex 共用 30／60／120 秒加 0–20% jitter 的等待政策，遵守較晚的 Retry-After／RetryInfo。沿用每片段、每模型四次實際發送與 900 秒根期限；網路等待及服務冷卻分別計量。upload／metadata 有階段上限，poll 保留有效 60 秒期限。日額度、等待超出期限或發送耗盡會保存工作並暫停；fallback 仍須原設定允許，且不能越過 serverNotBefore。
- **手動重送**：所有雲端重送入口共用 `CloudJobContinuation`，保留原設定與切片、執行時才注入憑證。有效完成片段沿用；損壞、遺失且已有完成證據的 checkpoint 明確報錯。父子 ID 在開始前落盤，重按及重啟沿用同一續作；保存失敗、取消或退出不放行請求。
- **歷史與佇列**：已手動授權的續作可通過其他暫停父工作的 gate，普通佇列維持暫停。失敗續作及祖先保留；成功憑據寫回父鏈，歷史上限 0 及重啟後不能從舊父工作再次付費。queued 續作不隨快捷模型變動；移除它時撤銷關聯及授權。
- **完成後休眠**：主畫面加入預設關、僅本次有效的勾選。獨立追蹤本次邏輯工作，全部完整成功、輸出發布完成、writer 確認 journal revision 已落盤及其他工作結束後，才開始 30 秒可取消倒數。新增工作、匯入／合併、互動確認、保存錯誤等立即取消倒數。最後再 flush、檢查 generation token 與資格，在同一 MainActor 區段消耗勾選並要求休眠一次。
- **電源事件**：IOKit 連線會關閉，拒絕碼可見且不循環重試。`QueueCompletionSleep` OSLog 分別記錄要求接受、拒絕、willSleep、didWake，只含固定訊息與 IOKit 錯誤碼。收到外部休眠通知也取消倒數；收到喚醒通知後保持關閉。API 接受、系統即將休眠通知均不宣稱已證明整機完成休眠。

已修正交班中的初始 journal 保存期間取消競爭、daily quota 遺失伺服器等待下限、完成憑據被歷史裁掉、queued child 刪除後晚到 flush 仍啟動，以及缺少來源的舊憑證測試 fixture。續作沿用有界診斷歷史與累計生成次數。

## 自動化驗收對照

所有測試位於 `Tests/RecordToTextCoreTests/`，使用合成音訊、隔離資料夾、mock transport／sleep service 與可注入時鐘。以下為自動化證據，native GUI 與真實電源驗收另列。

類別簡稱：SC = `CloudServiceRecoveryTests`；APP = `AppServiceRecoveryTests`；SLEEP = `QueueCompletionSleepTests`；NET = `AppNetworkRecoveryTests`；AD = `CloudAdaptiveSegmentationTests`。

| ID | 證據與結果 |
| --- | --- |
| C01 | SC `testBothBackendsCoolDownThirtyAndSixtySecondsThenSucceed`：兩後端發送時間為 0／30／90 秒，只有三次生成。 |
| C02 | SC 四次 429 案例：0／30／90／210 秒，第四次後 paused、無第五次；APP 完整管線確認下一筆仍 queued。 |
| C03 | SC `testMixedFailuresKeepOneQuotaAndSeparateWaitAccounting`：3 network＋429 在第四次停；2 network＋429＋成功共四次，網路及服務等待各自累計。 |
| C04 | SC Retry-After／RetryInfo、too-long 案例：秒數、三種 HTTP-date、較晚下限、無效值及超出根期限皆驗證；保留 serverNotBefore。 |
| C05 | SC upload／poll 案例確認四次上限與 60 秒 poll 期限；既有 `CloudUploadRecoveryTests`、network polling 及 AD Files root deadline 回歸正常 PROCESSING／metadata 路徑。 |
| C06 | SC 冷卻取消小於一秒；root timer snapshot 保留進行中等待及獨立終止診斷。APP 驗證 serverNotBefore 等待期間取消不發送；NET 驗證退出與續作 flush 競爭。 |
| C07 | SC daily quota 不等待、不 fallback，fallback 遵守同一根期限與伺服器下限；`VertexAIGeminiBackendTests`、`CloudReliabilityTests`、`GeminiBackendObservabilityTests` 回歸 401／POSIX 共用 quota、403 分類、5xx、STOP 與 opt-in fallback。 |
| R01 | APP build 6 failed／新 service pause、NET 零完成續作；`AppCredentialMigrationTests` 證明零 checkpoint 續作也不能被快捷模型變更。 |
| R02 | AD `testFourthSegmentServicePauseManuallyResumesWithoutReuploadingFirstThree`：五段中前三段完成、第四段四次 429；續作僅上傳及生成第四、第五段，前三份 checkpoint bytes 不變，累計生成數與診斷繼承。 |
| R03 | APP／NET 驗證雙擊、多入口、保存失敗、已落盤尚未開始的重啟窗口及退出競爭，保持唯一 ID；初始保存後再次檢查取消，尚未建立 execution task 時取消也不漏送。 |
| R04 | `CloudResumeCheckpointTests` 驗證來源遺失、空白 checkpoint、有完成證據但 manifest 遺失時拒絕；`CloudUploadRecoveryTests` 既有 URI 重建不增加生成上限；續作保留結果未知提示。 |
| R05 | APP unknown service state、serverNotBefore 重啟與 history=0 完成憑據；NET 舊 ledger／unknown network state；`JobRetentionPolicyTests` 回歸持久化與裁剪。 |
| S01 | SLEEP 預設關，空佇列及舊成功歷史不倒數；arming 沒有持久化欄位，新 instance 預設關閉。 |
| S02 | SLEEP 本機／AI Studio／Vertex 邏輯混合工作全部成功與零歷史裁剪後只呼叫 fake sleep 一次；APP 合成音訊完整管線證明服務恢復、續作、佇列落盤後才倒數。 |
| S03 | SLEEP failure／interrupted／hasGaps／unknown 皆不倒數；APP writer 延遲、匯入及互動確認案例，另審查 active／queued／model download／環境／憑證／consent gates。 |
| S04 | SLEEP 新工作、忙碌狀態變動重新完整倒數，取消勾選／工作／刪除消耗 arming；APP 匯入、duplicate／prompt 提示立即取消倒數。 |
| S05 | SLEEP 續作取代失敗父工作、忽略舊歷史；APP history=0 保留失敗 child、成功父鏈憑據，重啟後不能重送已完成工作。 |
| S06 | APP 直接提交完成結果、刻意阻塞 writer 且無 active queue task，確認尚未 durable 就不能倒數；SLEEP 保存失敗及最後 flush 中加新工作不能送休眠；既有輸出發布／完成憑據 pipeline 回歸。 |
| S07 | SLEEP 系統拒絕顯示並記錄錯誤碼、不重試；私有 NotificationCenter 模擬 willSleep／didWake，分別記錄、不重送，外部休眠取消待送倒數。App 結束流程會解除勾選。 |
| S08 | **尚未執行 native GUI／實機電源驗收**。App target 編譯及協調器測試已通過；mock 通知不代表真實睡眠／喚醒驗證。 |

## 完整檢查

```sh
SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh
git diff --check
```

最後完整腳本以 exit 0 結束，日誌 `/tmp/record-service-final-verification.log`。XCTest 於 2026-09-21 14:55:26（Asia/Shanghai）結束；此結果包含最後新增的系統通知實作與測試。

| 檢查 | 結果 |
| --- | --- |
| version contract／repository hygiene | 通過 |
| Python chunking／runner | 22＋3 tests，全部通過 |
| Swift build | Core、App、self-test、mock-helper、pipeline-self-test 全部通過 |
| executable self-test | 72 項，全部通過 |
| pipeline scenarios | 10 組，全部通過 |
| XCTest | **337 tests，0 failures** |
| `git diff --check` | 通過 |
| App bundle | 依既有使用者限制，以 `SKIP_APP_BUNDLE=1` 跳過 |

補系統通知前完整 335／0（`/tmp/record-service-completion-checks.log`），通知修改後專用 17／0（`/tmp/record-service-sleep-events-tests.log`）亦已通過；最終判定以上述 337 項全套為準。較早 334／1 的舊 fixture 失敗已修正並包含於最終回歸。

SwiftPM 仍提示既有 ignored `Resources/__pycache__` 為未宣告 resource，未造成編譯或測試失敗；本次未改動使用者本機快取。

## 交付界線

來源維持 0.2.1 build 7。本次只編譯開發 targets，未打包、安裝、關閉或重啟使用者正在使用的 App，也未發送真實付費 API 或休眠要求。已安裝 build 6 與先前 dist 的 build 7 都不包含本次最後來源修改，不可當成本功能的交付版本。

後續版本交付時再驗證 native GUI checkbox、冷卻與重送狀態、倒數取消及視窗尺寸；在可中斷使用的時段，才安排一次 IOKit 真休眠／喚醒，分別核對要求紀錄、系統通知及 OS 電源事件。本功能不建立排程或 LaunchAgent。

此頁優先於[歷次安全暫停交班](handoff-2026-09-21-service-recovery-sleep.md)的中途待辦。
