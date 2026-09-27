# Qwen 地端強化：規格入口與實作順序

日期：2026-09-27

狀態：階段 0／1／1.1 已實作，`SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh` 全綠（Swift 506／Python 134）；本機測試 App 已安裝為 0.2.1（build 8）。階段 1 的**程式收尾**完成，但真實模型 A/B 與預設放行仍未執行，功能維持「進階設定可主動開啟、新工作預設關閉」。階段 2／3 仍待實作。交付證據見[階段 1.1 交付說明](qwen-local-01-hardening-delivery-2026-09-27.md)。

適用：Apple Silicon／MLX Qwen；Intel Experimental、Gemini 雲端行為不在本輪範圍。

基準：HEAD `43f0fbd`，加上工作區已完成、尚未提交／安裝的「Qwen TXT 每十分鐘時間區間」修改。

## 1. 依序交付

| 階段 | 規格 | 主要結果 | 前置條件 | 狀態 |
| --- | --- | --- | --- | --- |
| 0 | [音訊身分驗證＋實際切塊起訖紀錄](qwen-local-00-identity-spans-spec-2026-09-27.md) | 安全的 v2 checkpoint、明確時間座標、leaf 狀態 | 現有固定切塊流程 | 已實作，自動化驗收通過 |
| 1 | [靜音感知切點](qwen-local-01-silence-boundaries-spec-2026-09-27.md) | 外層、120 秒內層與 token 重切都使用適合的停頓 | 階段 0 | 已實作；經[審查](qwen-local-01-review-and-hardening-spec-2026-09-27.md)與 [1.1 收尾](qwen-local-01-hardening-delivery-2026-09-27.md)。A/B 未執行，預設關閉 |
| 2 | [段級續跑與前處理跳過](qwen-local-02-segment-resume-spec-2026-09-27.md) | 已完成區間不再轉檔、載入音訊或推論 | 階段 0、1 | 待實作 |
| 3 | [token 缺口保留與定點補稿](qwen-local-03-gap-repair-spec-2026-09-27.md) | 有限重試、保留可用稿、只補未完成區間 | 階段 0～2 | 待實作 |

各階段先通過自己的驗收再開下一階段；不得用第四階段的 UI 掩蓋第一階段尚未成立的來源驗證。四份文件使用同一份 v2 資料契約，不各自新增一套續跑格式。

## 2. 原規格撰寫時的現況與限制（歷史基準）

本節記錄階段 0／1 實作前的狀態，不代表目前工作區；最新驗證結果見上方審查文件。

- `qwen_asr_mlx_runner.py` 現有 checkpoint 的 fingerprint 包含長度與推論設定，但不含音訊內容、語言。模擬測試已重現相同 sample 數的不同內容可沿用舊文字。
- Swift 本機管線使用最長 1,200 秒硬切；Python 再切 120 秒，token 上限後取中點重切。雲端的靜音 planner 並未接到上述本機流程。
- 地端續跑會重做 normalize／逐段抽取；Python 讀取 checkpoint 前仍會載入模型與音訊。
- 不可再切的 token-limit leaf 留下缺口，其他內容繼續；完成後本機 recovery 目錄仍會被清除。
- 工作區十分鐘時間戳已通過 30 個 Python 測試、339 個 XCTest、72 個 executable self-tests、10 個 pipeline 情境。這是前一項變更的驗證，**不代表本規格四階段已通過**。
- 目前沒有可支持「靜音切點是地端與雲端最大品質差距」或「續跑必定加速某個百分比」的比較數據。

現況來源：[本機管線](../Sources/RecordToTextCore/TranscriptionEngine.swift)、[MLX helper](../Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py)、[token 切分](../Sources/RecordToTextApp/Resources/qwen_asr_chunking.py)、[本機 checkpoint](../Sources/RecordToTextCore/LocalChunkCheckpoint.swift)。

## 3. 本輪共同決定

1. 本機音訊、文字與詞庫不送雲端；不加入 LLM 潤飾、講者猜測或逐句強制對齊。
2. 原始錄音與先前正式 TXT 不覆寫。補稿建立新工作、新檔案，保留歷史。
3. TXT 維持約十分鐘一個時間區間，不能因內部 120 秒塊／leaf 增加而變成密集標記。階段 0 維持整十分鐘；階段 1 為避開說話，可在目標前後五秒採實際切點，顯示真實時間，不把附近切點假標成整分。
4. 推論先維持模型、詞庫、token 上限與單工；靜音切點的效果需獨立量測。
5. 局部 token 失敗允許產出「完成（含缺口）」；一般執行錯誤、取消、來源不符、協定／寫檔錯誤不偽裝成完成。
6. 來源 hash、切塊方案、推論設定、文字完整性均通過，才可沿用。檔名、長度、mtime、進度百分比都不是充分證據。
7. 心跳只表示程序仍回報活動；階段 3 的推論預算必須使用獨立單調時鐘，心跳不能延長期限。
8. 新型別名稱為建議實作名稱；資料語意、狀態轉移、相容性與驗收條件是必須遵守的契約。

## 4. 交付與回退

- 每階段附變更摘要、資料格式版本、mock／真實模型分開的測試證據、未驗證項目。測試素材以合成音訊或經允許的本機素材為主，真實訪談與逐字稿不進 Git。
- 必跑 `SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh`；完整 Xcode 環境不可跳過 XCTest。規格撰寫本身只做文件檢查，不需重跑模型。
- 安裝包另走既有 [交付流程](development-delivery.md)；寫完規格或通過 mock 不等於已更新安裝版。
- 回退不得把 v2 結果交給舊 helper 猜讀。v2 採新目錄，不覆蓋 v1；舊版可保留查看已輸出的 TXT，但不能宣稱能續跑 v2。
- 階段 1 關閉靜音設定只影響新工作。已有工作使用自己的方案；不在續跑中途換切點。
- [2026-09-04 雲端缺段由地端補稿規格](local-segment-fill-spec-2026-09-04.md)是另一個功能，不能把它的模糊文字錨點或雲端混稿流程套到本次地端精確區間補稿。

## 5. 最終驗收門檻

| 類別 | 門檻 |
| --- | --- |
| 正確性 | 終端 leaf 對工作範圍形成無重疊、無遺漏的分割；缺口與已確認靜音都顯式記錄 |
| 恢復 | 刪除暫存 WAV、重啟、取消、寫入中斷後，不重複文字、不錯用來源、不丟已提交 leaf |
| 時間 | 非零 source slice、跨小時、遞迴切分、續跑／補稿都只加一次原始錄音偏移 |
| 品質 | 固定素材 A/B 比較切點附近錯漏字；未測不得宣稱提升 |
| 效能 | 報告 hash／靜音掃描／normalize／extract／模型載入／推論各自時間及呼叫數 |
| 產品 | 有缺口可查範圍、重啟後可補稿；全失敗不交付只剩缺口標記的正式稿 |
