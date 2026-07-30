# record-to-text v1.0 需求追蹤

本文件是 2026-07-30《Qwen 會議轉錄器 App 產品需求與技術規格書 v1.0》的實作追蹤摘要，不取代原始規格。已確認的規格修正以 [product-decisions.md](product-decisions.md) 為準。

## 產品定位

把本機會議錄音轉為可交給後續 ChatAI／LLM 使用的台灣繁體原始逐字稿。App 不摘要、不改寫、不重新斷句、不刪語助詞、不做說話者辨識或時間戳。

## P0 使用者旅程

1. 開啟 App，保留上次詞庫與本次補充。
2. 準備共用詞彙、專案詞庫與本次詞彙。
3. 拖入或選擇 M4A、MP3、WAV、AAC、FLAC。
4. Enqueue 時凍結模型、語言、Prompt、詞庫、輸出與保留原始稿設定。
5. 依序完成 ffprobe、ffmpeg、Qwen3-ASR、OpenCC、原子 TXT。
6. 成功清 temp；失敗保留 normalized WAV；原始音檔不修改、不移動、不刪除。

## P0 追蹤

| 範圍 | 實作狀態 | 證據／限制 |
| --- | --- | --- |
| 五種格式與特殊路徑 | Implemented | ffprobe／ffmpeg service；mock E2E 已通過 M4A 特殊路徑，其餘格式待 fixture matrix |
| 詞彙解析與 Snapshot | Implemented | Core tests / self-test |
| Prompt 確實傳入 | Implemented, real inference pending | MLX helper 對 `system_prompt` 反射；mock capability；真實 Metal 實測待辦 |
| 多檔單工佇列 | Implemented, build verified | SwiftPM debug／release build 通過；互動仍待完整 App 驗收 |
| 取消、liveness 與錯誤 | Implemented | SIGINT → SIGTERM → SIGKILL；30 秒無活動警告；mock failure／slow cancellation 通過 |
| OpenCC 台灣繁體 | Implemented | mock E2E 使用真實 `s2twp` 通過 |
| UTF-8 / LF / 無 BOM | Implemented | self-test 通過 |
| 原子輸出與不覆蓋 | Implemented | `renamex_np(RENAME_EXCL)`；self-test / XCTest |
| 設定／詞庫／最近工作 | Implemented | JSON repository 與 App wiring；durable ledger 不受 recentJobLimit 裁切，含 limit 0／長佇列 round-trip 測試；互動仍待驗收 |
| Runtime／模型下載管理 | Partial | schema 與安全決策已完成；正式 artifact、下載 UI、簽章未完成 |
| Apple Silicon 真實工作 | Pending | 需可用 Metal 的 App 執行環境與測試音檔 |
| 超過 30 分鐘長錄音 | Implemented, real soak pending | Coordinator-level 30 分鐘預切、逐段獨立 ASR、manifest gate、LF 順序合併與 fail-closed mock E2E 已完成；真實 Metal 31／65／120 分鐘仍待驗證 |
| Intel | Blocked / Experimental | 無 Intel 真機，且現行 PyTorch x86_64 發佈鏈中斷 |
| Universal 2 | Pending | 需完整 Xcode 與兩種實機 |
| 簽署／公證／DMG | Scripts ready, credentials pending | 需 Developer ID 與 notarytool profile |
| 乾淨帳號 | Pending | 需正式 Runtime artifact |
| 自動檢查更新 | Planned | 約每週一次；啟動後若逾間隔則安靜檢查 GitHub Releases；有新版再提示；可手動檢查；見 [NEXT_STEPS.md](NEXT_STEPS.md) |

## 規劃中（非 P0 阻塞，但要做）

### 自動檢查更新

- **間隔**：預設約每 **7 天** 一次（設定可調或關閉）。
- **行為**：檢查遠端是否有新 App 版本；有則提示下載／Release 頁，不強制中斷使用。
- **不做（第一階段）**：未簽署前不強制自動替換本機 `.app`；不與模型下載混成同一個「更新」按鈕語意。
- **證據完成條件**：settings 記錄上次檢查時間；mock／fixture 可測「有更新／無更新／離線」；正式發佈通道就緒後對真實 Release 驗一次。

## 第一版明確不做

- LLM 摘要、改寫、斷句與會議記錄。
- diarization、時間戳、字幕與 forced alignment。
- 錄音、剪輯、降噪。
- 雲端 API 轉錄。
- Mac App Store、手機、Windows。
- 多工作平行 ASR。

## 驗收層級

- **Core verified**：可在目前 Command Line Tools 執行。
- **App build verified**：SwiftUI source 已接線，SwiftPM debug／release 與 `.app` 封裝通過；互動仍需人工驗證。
- **Developer Mode verified**：可依賴本機 Homebrew／Python，只能供開發。
- **Release verified**：必須在乾淨帳號、簽署 Runtime、Developer ID App、notarized DMG 下通過。

只有最後一級才可標記 v1.0 Stable。
