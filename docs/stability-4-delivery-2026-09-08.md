# 第 4 項實作與驗證紀錄：靜音分析快取與切段前置檢查

日期：2026-09-08。分支 `codex/record-to-text-reliability-v2`。
基準 HEAD：`a889969be46f4acf909c64792fcc2406cf7fff35`。第 4 項改動仍在工作區，未 commit／push。

## 做了什麼

- 單次 `TranscriptionEngine.run` 擁有 `JobSilenceAnalysisCache`，不寫磁碟、不跨工作共用。
- MAX_TOKENS 切小前先用空 silences 問 `CloudAdaptiveSegmentPlanner`：達最大深度或短到不能切成兩個合法子段時，不啟動 ffmpeg。
- 關閉 silence-aware 時，初始分段與 adaptive split 都不分析靜音，合法切分仍走中點。
- cache 以來源 identity（標準化路徑、resource identifier、size、mtime、noise=-35dB、minimumSilence=0.35s）加上完整涵蓋區間命中；空結果仍算已掃描。
- `SilenceDetectionService` 回傳相對本次掃描起點的時間；寫入 cache 時轉成來源絕對秒數。`record.startSeconds` 已是絕對時間，不再加一次 `sourceSlice`。
- 一般分析錯誤記一次 warning 並退回中點；`CancellationError` 向上拋出，不建立子段。
- 工作結束時輸出 `silence_scan_count` 等 summary log，不寫入既有持久化 schema。

## 修改檔案

- `Sources/RecordToTextCore/JobSilenceAnalysisCache.swift`（新增）
- `Sources/RecordToTextCore/SilenceAwareSegmentation.swift`
- `Sources/RecordToTextCore/AudioSegmentation.swift`
- `Sources/RecordToTextCore/TranscriptionEngine.swift`
- `Tests/RecordToTextCoreTests/JobSilenceAnalysisCacheTests.swift`（新增）
- `Tests/RecordToTextCoreTests/CloudAdaptiveSilenceCoordinatorTests.swift`（新增）
- `Tests/RecordToTextCoreTests/CloudAdaptiveSegmentationTests.swift`
- `Tests/RecordToTextCoreTests/SilenceAwareSegmentationTests.swift`

沒有改第 3 項雲端總時間預算，也沒有改第 5 項工作紀錄背景寫入。

## 測試

修改前：新增測試對未存在的 cache／coordinator API 無法編譯。

修改後針對性結果：

```
JobSilenceAnalysisCacheTests 12
CloudAdaptiveSilenceCoordinatorTests 7
SilenceAwareSegmentationTests 5
CloudAdaptiveSegmentationTests 11
合計 35 tests / 0 failures
```

其中 ffmpeg fixture `testDetectionServiceReportsTimesRelativeToTrimmedStart` 確認：`startSeconds=2` 時回傳相對時間約 2–4 秒，不是來源絕對 4–6 秒。

`./scripts/run-checks.sh`：通過。

- Python：22 + 3
- Swift self-test：72 passed
- mock pipeline：10 個情境
- XCTest：215 tests / 0 failures
- App bundle：`dist/record-to-text.app`
- `git diff --check`：通過

既有 MAX_TOKENS adaptive 成功、子段失敗 fail-closed、最大深度 fail-closed 仍通過。測試沒有呼叫真實 Google API，也沒有使用使用者錄音。

## 未驗證

- 真實 Google AI Studio／Vertex 長音訊
- 同一份音訊 baseline／新版本各 3 次的靜音分析耗時比較
- 第 3 項 budget 到期與本項取消路徑的交會（第 3 項尚未實作）
- 未安裝到 `/Applications/record-to-text.app`

## 與規格的差異

- 來源 identity 一旦在工作中改變，cache 會永久失效；即使檔案稍後改回原內容也不再命中。這比規格「改變即失效」更嚴，避免中途被換成別的檔再換回來。
- 第一版不做部分範圍拼接，只在完整涵蓋時命中。
- 超過 100,000 個 silence interval 時，當次結果仍可供當前切分使用，但不寫入 cache。
