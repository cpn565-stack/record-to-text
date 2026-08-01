# Changelog

所有值得注意的變更會記錄在此。版本採 Semantic Versioning。

## [Unreleased]

### Added

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

### Fixed

- 長駐 ASR helper 的 stdin 改送 compact 單行 JSON（JSONL），避免 pretty-printed JSON 造成 helper `JSONDecodeError` 與早期 `asr_failed`。
- MLX helper 輸出尾端若回吐 system prompt 開頭，以 `remove_prompt_echo()` 清除，避免污染正式逐字稿。

### Changed

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

### Planned

- 自動檢查更新（PD-015）：預設約每 7 天檢查 GitHub Releases；有新版再提示；可手動檢查；細節見 `docs/NEXT_STEPS.md`。

### Known limitations

- 已在本機 Apple Silicon + 真實 Qwen3-ASR（MLX）路徑驗證長音訊流程；仍非正式公證／可分發 Stable 版。
- 極密語或異常音訊可能使最短約 30 秒葉節仍達 token 上限：會以明確缺口標記處理，不保證該區間文字完整。
- 每個 coordinator 分段仍可能重複確認／載入模型（日誌可見 `Fetching 11 files`）；模型生命週期優化待辦。
- 正式 Runtime、Universal 2、Developer ID、公證與 DMG 尚需外部條件。
- 尚無 App 自動檢查更新。
