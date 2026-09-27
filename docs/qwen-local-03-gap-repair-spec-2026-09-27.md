# 階段 3：token 缺口保留、有限重試與定點補稿

日期：2026-09-27

狀態：待實作規格；採用下列預設產品策略，不代表已部署。

前置：[資料契約](qwen-local-00-identity-spans-spec-2026-09-27.md)、[靜音切點](qwen-local-01-silence-boundaries-spec-2026-09-27.md)、[段級續跑](qwen-local-02-segment-resume-spec-2026-09-27.md)。

## 1. 產品決定

保留「局部 token-limit 不妨礙其餘內容完成」，不為了與雲端一致而將預設改成整件失敗。附帶三個必要條件：

1. 不可再切的區間是已知缺口，不能把截斷文字當成完成。
2. 正式 TXT、工作狀態、重啟後工作紀錄都能指出缺口，並保留補稿所需證據。
3. 使用者可只重試缺口；正常內容不重新推論、不覆寫原稿，不自動換模型或送雲端。

雲端 token 上限耗盡的 fail-closed 策略維持原樣。一般本機錯誤也不因本功能而全部改成「跳過繼續」。本版不新增 strict／lenient 模式選單。

## 2. 原始轉錄的終止規則

| 事件 | 動作／最終語意 |
| --- | --- |
| 正常文字、未達 token cap | 提交 completed leaf |
| 達 cap 且可合法切分 | 不提交截斷文字，按階段 1 切分並重試 children |
| 達 cap 且不可再切 | 提交 `gap(reason=token_limit)`，保留真實範圍，繼續後續音訊 |
| 空結果且全範圍靜音已驗證 | 提交 verifiedSilence |
| 空結果無證據／純 prompt echo／缺 token 證據 | 停止目前工作、保留已完成葉節點，不能標無缺口完成 |
| MLX／Metal 崩潰、一般 Python 錯誤、來源／協定／存檔錯誤 | 停止並保留 recovery，不當成 token gap |
| 使用者取消 | cancelled；停止新增推論，保留已提交結果 |
| 推論總預算耗盡或真正停滯 | failed／可續跑，不能用心跳一直延長，亦不偽裝成 token gap |

正常流程維持 maximumTokens=16,384、遞迴 child 最短 30 秒、maxDepth=6。最短 30 秒不等於每個末端一定 30 秒：例如 45 秒不能再拆成兩個至少 30 秒的 child，仍可能成為 gap。

### 2.1 有限執行預算

- 每個初始 ASR chunk 建立 900 秒總預算，從開始推論起算，包含其遞迴子段；不含整個模型冷啟動與前置音訊準備。此為初始工程值，需以 BF16／8-bit 實測校準。
- 同一初始 chunk 的 children 共用 deadline；收到 token／heartbeat／log 不重設。模型冷啟動另設 900 秒絕對上限，含必要模型解析／載入，不能依賴目前會被心跳重設的 inactivity timeout；本次不自動重試載入。ffmpeg 沿用既有有界程序 timeout。
- 使用單調時鐘；跨程序只保存 elapsed／原因，不序列化 Instant 充當可跨重啟的 deadline。
- Swift 獨立監督 active chunk；helper 透過結構化事件回報 initialChunkID、leafID、實際進度。Python heartbeat thread 不能作唯一 watchdog。
- 到期先封閉提交 gate，終止 active helper，使用既有 process-group 升級終止。晚到結果不可提交；不在未確認舊程序退出前啟動新 helper。
- 目標是在期限後五秒內停止本機子程序並呈現狀態；以可注入 clock／卡死 helper 測試驗證，不靠等待原生呼叫自行返回。
- 手動續跑是新一次有界執行；沿用完成結果與 split tree，不暗中消除歷史失敗紀錄。

## 3. 缺口資料與正式稿

gap 必須含 `nodeID/rootID`、絕對 start/end sample、reason、觸發 token 數、token cap、splitDepth、attempt summary。不得只保存「約缺少 30 秒」文字或 `containsSkippedAudio=true`。

例：

```text
[00:20:00 - 00:30:00]

這裡保留已完成的訪談內容。

【未完成：00:23:30 - 00:24:00｜Qwen 達輸出上限，待補稿】

這裡接續缺口之後已完成的內容。
```

- 正常時間標題仍約每十分鐘一次；缺口標記只在真正缺漏位置出現，不為每個 120 秒 chunk 加標題。
- 相鄰同原因 gap 可合併顯示，但底層 node IDs 與各自 attempt 保留；缺口總時長以區間聯集計算，不能重複累加父子。
- 有可用正常文字＋gap：正式稿可發布，狀態「完成（含缺口）」，顯示缺口數／總時長。
- 整份只有 gap／verifiedSilence、沒有任何可用辨識文字：不發布充滿標記的正式稿；failed，保留診斷與可重試範圍。
- 只有已驗證靜音不代表需要造出文字；單獨顯示「未辨識到可輸出的文字」，不捏造逐字稿。

## 4. 保留、發布與工作紀錄

### 4.1 先持久化，才承諾可補稿

1. 所有 leaf／gap 與 plan 存入 v2 recovery。
2. 準備 publication intent，必須包含 `recoveryDirectory`、輸出完整性與必要的重建參照。
3. 原子發布新 TXT。
4. 工作 ledger durable 保存完成狀態、可恢復引用與缺口摘要。
5. 才可清除非必要 WAV／snapshot；含 gap 的 manifest／leaf text／publication 對照不能隨成功清理刪掉。

任一步失敗保留已有證據；重啟按 [OutputPublicationStore](../Sources/RecordToTextCore/OutputPublicationStore.swift) 的意圖記錄恢復，不重複發布或把恢復目錄當 orphan 刪除。

### 4.2 不受最近紀錄數限制

- 有待補 gap 且 recovery 有效的本機工作必須納入 `hasPendingGapRecovery`／durable ledger 規則；`recentJobLimit=0` 也不能使它消失。
- 建議新增可選 `LocalRecoveryState`：request kind（resume／repair）、checkpoint version／directory、parentJobID、childJobID、continuation pending／resolved。缺口列表以 manifest 為權威，摘要只供顯示。
- parent/child 保存及祖先保留需同時支援本機鏈，不能只走現有 `cloudContinuationID`。不得讓本機新欄位觸發雲端 resend 分支。
- 同時有 active child、仍被 parent／child 鏈引用的 recovery 或未完成 publication intent 時，清理不得移除被引用資料。
- 使用者明確捨棄恢復資料可解除 durable 保留，保留原 TXT／原始音檔，UI 說明之後不能只補缺口。取消補稿本身不等於捨棄恢復資料。
- 暫不自動按天數刪除 gap checkpoint；大型 WAV 可回收，文字／範圍證據不能跟著刪。

## 5. 補稿入口與安全門檻

工作卡提供「補上 Qwen 缺口」。來源可讀、v2 完整驗證通過、至少一個 token gap、模型 runtime 就緒且同一 recovery 無 active child 才能開始。

與一般「從中斷處續跑」區分：一般續跑不重試已記錄 gap；補稿只處理選定父稿的 gap。待處理／failed 範圍先走階段 2，避免把未完成整件工作誤算為缺口補稿。

本版一次處理全部可補 gap，不新增逐個勾選 UI。來源被換、checkpoint 舊版／損壞、缺少原稿對照時顯示具體原因，可取回既有稿或另建新工作；不得用模糊文字錨點猜補入位置。

## 6. 補稿管線與預算

1. 背景驗證 source identity、模型／prompt 契約、v2 tree、原稿 publication digest。
2. 建立獨立 child 工作與 recovery 副本，保存 parent/child 關係並 flush ledger；重複點擊不建立第二個 child。
3. 沿用全部 completed／verifiedSilence leaf；只將目標 gap 轉成 child 工作內的 repair pending。parent 保持不變。
4. 使用階段 2 的最小音訊準備；不重跑已完成音訊。一般工作快照的模型、詞庫、語言與 maximumTokens 固定，不因目前設定頁改變而變更。
5. 套用獨立、已入 snapshot 的 `local-gap-repair-v1`：對至少 30 秒的 gap，先在合法停頓／中點切成兩個至少 15 秒的 child，避免原封不動重跑同一個確定性失敗；更短 gap 最多先做一次直接辨識。
6. 補稿遞迴最深兩層（相對該 gap），child 下限 15 秒、每 gap 最多七次 generate。原始整段流程仍用 30 秒下限，不偷改全局設定。
7. 每 gap 最多 300 秒，整次補稿最多 1,800 秒；所有 children 共用相應剩餘預算。數值為初始預設，實測後可版本化調整；本次執行中不放大預算。
8. 再度不可分 token cap：留下更小或原範圍 gap，繼續其他 gap。一般崩潰／取消／deadline 到期依 §2 停止，不自動開新模型或無限重送。
9. 合併驗證通過後發布新檔；全部修復則 complete，仍有 gap 則 completedWithGaps。到期／取消已提交的補稿 leaf 下次可沿用。

相同模型在同一錄音上仍可能失敗；補稿不是成功保證。UI 顯示本次新增成功範圍與剩餘範圍，不用「重試」暗示必定能補上。

## 7. 合併與輸出不變性

- 用 node ID＋絕對 sample range 替換 gap，不用整段文字搜尋或 fuzzy matching；replacement leaf 的聯集必須精確等於原 gap，不能伸進旁邊 completed leaf。
- 既有 completed leaf 的原始辨識文字及順序逐 bytes 保持不變；新補文字獨立經既有 OpenCC profile 轉換。
- 為保證既有繁體內容也不被轉換版本改動，發布時保存帶 leaf ID、raw／converted text digest 的 `publication.fragments` 對照。補稿重用已發布 converted fragments，只轉換新 leaf，再以原 displayGroups 渲染。
- root state 仍由 helper 單一 writer 擁有；publication 對照由 Swift 存於獨立 `publication.json`，含自身 schemaVersion=1、formatter／OpenCC profile 與文件 digest，不在 root state 增加競爭 writer。RecoveryScanner 納入此檔。
- 既有 v2 若無 publication 對照，只能在使用原 profile 重建後與原 TXT 全內容一致時補建；無法證明一致則不提供精確補稿，保留原稿與草稿，不猜片段位置。
- 時間標題與缺口顯示可因修復重建；既有正常文字不能被模型重新摘要、校正或潤飾。
- 輸出使用原目錄、原檔 stem 加 `_補稿`，撞名依既有遞增命名；raw 稿選配也使用新名稱，永不覆寫 parent。
- 本次沒有修好任何 gap：不再產出內容相同的正式 TXT；child 記失敗與原因，保留 attempt／recovery，parent 原稿仍可用。
- 全部成功且新稿、child 與 parent resolved 狀態 durable 後，才可依引用計數清除恢復資料。新稿還有 gap 時，下一次從最新 child 繼續，不回到最初 parent 重算。

## 8. UI、日誌與診斷

範例：「完成（含缺口）：2 處，合計 45 秒」「本次補上 1／2 處，剩餘 15 秒」「未能補上缺口，原稿已保留」。先顯示可用成果與實際狀態，技術碼放工作紀錄。

日誌記 parent／child、gapID、start/end、token cap、嘗試數、切分原因、耗時、截止原因與重用 leaf 數；不記逐字稿全文／prompt，也不宣稱本機失敗源自雲端安全攔截。

## 9. 驗收矩陣

| 情境 | 結果 |
| --- | --- |
| 30 秒 token leaf 到頂 | 原工作留下精確 gap，後段仍執行，狀態含缺口 |
| 45 秒 leaf 到頂 | 不假寫成 30 秒；範圍與總時長正確 |
| 全部 leaf 為 gap／靜音 | 不發布標記空稿 |
| 心跳正常但推論不前進 | 獨立預算終止；不能永久等待 |
| 補稿切成 15＋15 秒，一成一敗 | 成功半段保留，另一半維持 gap；原 parent 不變 |
| 補稿 0 成功／部分成功／全部成功 | 不新增重複稿／新含缺口稿／新完整稿 |
| 取消後重啟、recent limit=0 | parent／child、gap、已補 leaf 都仍可找到 |
| 重複點擊／durable save 失敗 | 至多一個可執行 child；未保存不能開始推論 |
| 發布成功但 ledger 寫失敗 | intent 可恢復新稿；不清 checkpoint、不重複生成 |
| 文字檔被外部修改／publication 對照遺失 | 不靜默覆寫或拼接；具體說明不相容 |
| source／模型／prompt 改變 | 拒絕混用；不把新設定補稿說成同一契約 |
| 清除 WAV／捨棄恢復／正常完成清理 | 分別不丟文字證據／明確解除可補狀態／確認引用與持久化後清除 |

在真實短音、30 分鐘與長音 fixture 分開測量；token-limit 可用受控小 cap 驗證控制流程，但不能拿小 cap 的失敗率宣稱 production 模型品質。原稿／補稿內容只保留於受控本機證據目錄。

主要調整：[AppViewModel](../Sources/RecordToTextApp/AppViewModel.swift)、[MainView](../Sources/RecordToTextApp/MainView.swift)、[Models](../Sources/RecordToTextCore/Models.swift)、[JobRetentionPolicy](../Sources/RecordToTextCore/JobRetentionPolicy.swift)、[OutputPublicationStore](../Sources/RecordToTextCore/OutputPublicationStore.swift)、[RecoveryScanner](../Sources/RecordToTextCore/RecoveryScanner.swift)、[ASRBackend](../Sources/RecordToTextCore/ASRBackend.swift)、MLX runner／chunking 與前三階段資料模型。
