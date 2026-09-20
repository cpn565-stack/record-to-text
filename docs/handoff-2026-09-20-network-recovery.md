# 網路恢復實作：2026-09-20 暫停交班

> 此為第一次暫停的歷史紀錄。請優先讀 [2026-09-21 最新交班](handoff-2026-09-21-network-recovery.md)。

## 暫停原因與工作樹

使用者要出門，要求立即在安全位置收尾。停止新增功能，保留目前工作樹；未部署、未安裝 App、未呼叫真實付費 API、未切換使用者網路。

- 分支：`codex/record-to-text-reliability-v2`。
- 已依使用者要求先提交既有文件／驗證工具：`2fe11e9`（`docs: checkpoint product specifications and network recovery plan`），尚未 push。
- 下述程式修改尚未 commit，屬於 A1 進行中，**不是網路恢復方案已完成**。
- 最新實作規格：[network-recovery-spec-2026-09-19.md](network-recovery-spec-2026-09-19.md)。本專案為 record-to-text；其他 interview-copilot 交班檔不是這次需求。

## 已寫入的修改

1. 新增 `CloudFailureDiagnostic.swift`：固定錯誤分類、有限深度 underlying NSError allowlist、固定使用者文案；新增 `CloudRequestDeadlineExceeded`，區分 App 操作期限與 URLSession timeout；新增分段錯誤 wrapper 保留 typed cause。
2. `CloudJobDiagnostics.swift`：片段 failed／cancelled／deadline outcome、失敗摘要、實際 generation task 計數，以及每工作最多 100 筆的事件歷史；累計事件與發送數獨立保留。新狀態 enum 讀取未知字串退回 unknown。
3. `CloudSegmentBudget`、`CancellableCloudRequest`、`GeminiTransportHelper`：記錄實際 task 發送、HTTP 失敗與操作失敗；App wall deadline 改拋獨立型別。網路 transient 判定改用結構化分類。
4. `TranscriptionEngine`：一般失敗、取消、根期限與切分失敗保存 collector；`PipelineExecutionError` 帶 diagnostics；取消零完成片段也保留 metadata，沒有放寬 checkpoint loader 的成功條件。
5. 修正 `preserveCloudRecoveryData` 重建紀錄時漏掉 `diagnostic`、`discardedDiagnostics` 的問題；新增 failureHistory 同步保留。
6. `JobFailure` 新增 optional cloudDiagnostic；`AppViewModel` 保存失敗／取消的 diagnostics，雲端 typed failure 的 technicalDetails 改為受限摘要。
7. Vertex 401 刷新後的 transport resend 移出 authentication catch，避免後續連線錯誤一律變成 authenticationFailed；兩後端紀錄 model 與 generation failure。

## 驗證與已知界線

- 收尾測試：`swift test --disable-sandbox --filter 'CloudSegmentBudgetTests|CloudJobDiagnosticsTests|GeminiBackendObservabilityTests'`。
- 最後修改後重新編譯成功，**15 tests／0 failures**，命令正常結束（exit 0）；日誌 `/tmp/record-network-handoff-tests.log`。本輪測試沒有留在背景執行。
- 較早版本同一批 15 tests／0 failures（`/tmp/record-network-a1-tests.log`）。早期結果不能取代最後修改的結果。
- `git diff --check` 已通過。
- 尚未新增並執行分類／隱私／零完成／401 後斷線的專用故障注入回歸，也未跑全套測試。
- A2 的 300 秒共用等待、15／45／120 秒退避、path monitor、session owner、四次實際發送硬上限、分階段上傳恢復與 Files 有效輪詢時間均未實作。
- A3 的 networkRecovery 狀態、持久化 queue gate、等待 UI、去重手動續作與重啟恢復均未實作；目前仍是既有重試／佇列行為。
- 新事件尚缺 A2 才能提供的 path、網路等待用量、session reset 資訊。不能宣稱已滿足 N01–N18。

## 接續順序

1. 先讀本檔與最新規格，檢查 working diff；**不要 reset／清掉未提交修改**。
2. 完成 A1 專用測試：NSError allowlist／深度與循環、四類 timeout／STOP 區分、100 筆截斷後累計不變、未知 enum／舊 ledger 相容、multi-segment typed cause、首段失敗及取消的 recovery／journal 保存、401 後網路錯誤仍進入網路處理。
3. 特別檢查目前新增的 per-segment defer 寫 manifest、取消後保存順序與錯誤 stage 是否精確；切分例外與晚到 callback 不能把失败重新提交成成功。新增取消零完成 metadata 不得對外宣稱有部分稿。
4. 延伸 `CloudAdaptiveSegmentationTests` 的真實本機合成音訊＋mock transport 測試，檢查復原複製後 diagnostic／discardedDiagnostics／failureHistory 都存在；避免只測 model round-trip。
5. A1 穩定後接 A2、A3，依規格整合 A4。付費實機驗收、打包、安裝與 push 未在本輪執行。

## 主要檔案

- `Sources/RecordToTextCore/CloudFailureDiagnostic.swift`（新增）
- `Sources/RecordToTextCore/CloudJobDiagnostics.swift`
- `Sources/RecordToTextCore/CloudSegmentBudget.swift`
- `Sources/RecordToTextCore/CancellableCloudRequest.swift`
- `Sources/RecordToTextCore/GeminiTransportHelper.swift`
- `Sources/RecordToTextCore/TranscriptionEngine.swift`
- `Sources/RecordToTextCore/AudioSegmentation.swift`、`Models.swift`
- `Sources/RecordToTextCore/VertexAIGeminiBackend.swift`、`GoogleAIStudioBackend.swift`
- `Sources/RecordToTextApp/AppViewModel.swift`
- `Tests/RecordToTextCoreTests/CloudSegmentBudgetTests.swift`（更新 App timeout 型別斷言）
