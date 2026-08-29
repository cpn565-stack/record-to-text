# Changelog

所有值得注意的變更會記錄在此。版本採 Semantic Versioning。

## [Unreleased]

### Added

- 新增完整 `TranscriptionEngine` 雲端自適應切段整合測試：父段 `MAX_TOKENS` 後切成子段重試，只有所有子段 `STOP` 才交付正式稿；子段失敗或達最大切段深度時維持 fail-closed 並保留 recovery。

### Fixed

- 修正 adaptive segmentation XCTest 的 optional 編譯錯誤，恢復完整 Xcode CI；`9c21834` 對應的 GitHub Actions 已執行 178 項 XCTest，0 failures。

### Planned

- 自動檢查更新（PD-015）：預設約每 7 天檢查 GitHub Releases；有新版再提示；可手動檢查；細節見 `docs/NEXT_STEPS.md`。

## [0.2.0] - 2026-08-29

### Added

- 主畫面把轉錄設定收成摺疊列；進行中工作只留左邊藍線，不再整張洗色。
- 雲端目前段用前段耗時中位數往前填進度，最多到該格 90%；已完成段才實心填滿。
- 執行日誌改為白話狀態加「複製除錯資訊」，完整 HTTP／token 紀錄不再直接攤在卡片上。
- 佇列有工作時縮小拖放區；「開始轉文字」移到進件區下方。
- 啟動後的模型快取與復原掃描改在背景盤點，復原畫面顯示掃描狀態與完成時間。
- 單一版本來源、版本 contract 檢查、repo hygiene gate 與未簽署測試 DMG／SHA-256 交付流程。
- Gemini 雲端傳輸強固化（雙層架構）：
  - 傳輸層改造：全面以工作暫存檔串流上傳 (`upload(for:fromFile:)`) 替代 in-memory `httpBody`，遞迴檢測並攔截 POSIX 40 (`EMSGSIZE`) 與 `_kCFStreamErrorCodeKey: 40`，自動以 Ephemeral TCP Session 重試 1 次。
  - 音訊上傳分離：Google AI Studio 預設啟用官方 Files API 串流傳輸音訊，Vertex AI 支援 GCS Bucket 參照（`gs://...`），大幅降低推論 API 的 Payload 體積與斷線風險。
- Google AI Studio 模式把 FFmpeg 9.0 / FFprobe（arm64 static，含 libmp3lame）打進 App `Contents/Helpers`，預設不再依賴 Homebrew 或 Developer Mode。
- Runtime 設定可選 Apple Silicon 模型：`Qwen3-ASR 1.7B 8-bit`、`1.7B BF16`、`0.6B 8-bit`（含鎖定 revision）。
- 模型選擇旁提供「下載模型／匯入本機模型」：優先從 `~/.cache/huggingface` 匯入，否則下載到 App Models 目錄。
- 預設輸出檔名後綴改為 `_逐字稿`（例如 `原檔名_逐字稿.txt`）。
- 啟動時掃描 system temp 與 Temp-Recovery，分類可復原／孤立／損壞；可確認後刪除或批次清孤立／損壞；可復原可重新加入來源音檔。
- ProcessRunner：修復 launch 前取消 race；取消時終止 process group（helper 子程序）。
- 建立 `record-to-text` SwiftPM 專案與原生 SwiftUI App。
- Apple Silicon MLX-Audio JSONL helper 與 Intel Experimental helper。
- 專有名詞、Prompt、詞庫、設定、佇列、輸出命名與原子寫入。
- ffprobe、ffmpeg、OpenCC 與 ASR coordinator。
- Core XCTest、executable self-test、mock helper 與管線整合測試。
- Runtime／模型完整性資料模型與 Release scripts。
- Helper liveness warning、慢速取消整合測試與失敗復原資料刪除 UI。
- Coordinator-level 30 分鐘預切、segment manifest、逐段獨立 ASR 與全段完整性 gate。
- 31／65／120 分鐘 planner fixture，以及中段／尾段失敗、空白、token limit、未 completed 的 fail-closed 管線測試。
- Durable Job retention policy 與 limit 0、長佇列、terminal history、日誌裁切及 JSON round-trip 測試。
- 外部程序 timeout／inactivity watchdog：ffprobe、ffmpeg、OpenCC 與 ASR helper 卡住時會自動停止並保留可診斷錯誤。
- 轉錄前檢查暫存 volume 與輸出 volume 的可用空間，包含安全餘裕。
- 輸出契約 final validation：拒收 BOM、NUL 控制字元與 Prompt echo，並在逐段、合併及繁體轉換後驗證。
- 最近工作標示來源或輸出檔案已移動／刪除；相同 runtime 的佇列工作重用 engine 與長駐 helper。
- 錄音加入佇列後，可在「開始轉文字」旁將單一錄音切成前後兩個時間範圍工作：前半先處理，後半排隊；兩段各自輸出有順序的 TXT。
- 可從前端選取多份 TXT，依分段編號排序後合併成新檔；拒絕空白／不合法輸出且不覆寫既有檔案。
- 視窗標題維持純 `record-to-text`；行銷版本與 build 改由設定頁及「複製除錯資訊」提供。

### Fixed

- 長駐 ASR helper 的 stdin 改送 compact 單行 JSON（JSONL），避免 pretty-printed JSON 造成 helper `JSONDecodeError` 與早期 `asr_failed`。
- MLX helper 輸出尾端若回吐 system prompt 開頭，以 `remove_prompt_echo()` 清除，避免污染正式逐字稿。
- 修正 MLX／Intel helper 在輸出開頭回吐完整詞庫清單或 Prompt 的問題；最終輸出契約也會拒收前置／尾端 Prompt echo。
- 修正中文詞庫以空格輸入時被當成單一詞，導致模型回吐整句詞庫仍被誤判為成功逐字稿；現在會拆分中文詞並在舊 Snapshot 上再次擋下相同污染。
- 模型只回吐詞庫而沒有實際轉錄內容時，helper 現在會回報明確的 `prompt_echo_only` 失敗，不再先寫出空白或誤導性的完成結果。
- MLX helper 任一內部 chunk 只回吐 Prompt 時改為整段 fail-closed；一般 chunk 例外也會保存已完成內容的 partial 草稿，不再讓部分結果被誤判為完整成功或直接遺失。

### Changed

- 雲端轉錄等待時改用會移動的橫向 progress bar，同時顯示目前分段與已完成段數；移除內部進度推理語句。
- CI 改為只打包一次 App，並上傳可追溯 commit 的測試 artifact；App 體積上限改為自動門檻。
- SwiftPM 資源從整個 `Resources` 目錄改為明確的 Python helper 清單，不再將本機 `__pycache__` 打包。
- 長音檔 coordinator 預切由 30 分鐘改為 **20 分鐘**；ASR 預設 `maximumTokens` 由 8192 提高到 **16384**（helper 上限）；helper 內部 generate 窗口由 1200 秒改為 **120 秒**，避免單段 20 分鐘密語仍撞 token 上限。
- MLX helper 的一般錯誤仍維持 fail-closed；不可再切的 token-limit leaf 則改以明確缺口標記處理，不保留可能截斷的文字。
- MLX helper 的最小約 30 秒片段若仍達 token 上限，會插入明確缺口標記、跳過該片段並繼續後續音訊；App 日誌會提示輸出含缺口。
- 轉錄失敗時仍保留已完成段落／chunk 的 `partial-transcript.txt` 救援草稿；正式逐字稿完整性 gate 不變，App 失敗卡片可直接打開未完成稿。
- 同一 job 內優先重用長駐 Python／MLX helper 與 model cache，減少每個 coordinator 分段整模重載。
- 最低系統由原始規格的 macOS 13 修正為 macOS 14。
- 正式產品名稱改為 `record-to-text`。
- Intel 支援由既定功能修正為 Blocked / Experimental，需實機 Spike。
- `settings.json` 成為產品設定唯一 source of truth。
- 使用 exclusive atomic rename 避免競態覆寫；拒收空白或非 UTF-8 逐字稿。
- Helper 改用最小環境變數白名單，不繼承終端機或 CI 的無關憑證。
- `recentJobLimit` 只裁切最近摘要與 terminal history，不再刪除 queued／active／interrupted ledger 工作。

### Removed

- 已完成使命的 Gemini 3.7 一次性 apply／fix patcher 與對應 workflow。

### Known limitations

- 已在本機 Apple Silicon + 真實 Qwen3-ASR（MLX）路徑驗證長音訊流程；仍非正式公證／可分發 Stable 版。
- 極密語或異常音訊可能使最短約 30 秒葉節仍達 token 上限：會以明確缺口標記處理，不保證該區間文字完整。
- 模型 cache reuse 已加入；實際耗時、記憶體與 Fetching 11 files 改善仍需在真實 Metal 長音檔上做前後測量。
- 正式 Runtime、Universal 2、Developer ID、公證與 DMG 尚需外部條件。
- 尚無 App 自動檢查更新。
