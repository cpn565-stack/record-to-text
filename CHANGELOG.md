# Changelog

所有值得注意的變更會記錄在此。版本採 Semantic Versioning。

## [Unreleased]

### Added

- Runtime 設定可選 Apple Silicon 模型：`Qwen3-ASR 1.7B 8-bit`、`1.7B BF16`、`0.6B 8-bit`（含鎖定 revision）。
- 模型選擇旁提供「下載模型／匯入本機模型」：優先從 `~/.cache/huggingface` 匯入，否則下載到 App Models 目錄。
- 預設輸出檔名後綴改為 `_逐字稿`（例如 `原檔名_逐字稿.txt`）。
- 啟動時唯讀掃描 system temp 與 Temp-Recovery，分類可復原／孤立／損壞；不自動刪除。
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

### Changed

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

- 尚未在可使用 Metal 的 App 執行環境完成真實 Qwen3-ASR 驗證。
- 正式 Runtime、Universal 2、Developer ID、公證與 DMG 尚需外部條件。
- Coordinator 分段邏輯已完成，但真實 Metal 模型搭配 31／65／120 分鐘音檔的 soak test 尚未執行。
- 尚無 App 自動檢查更新。
