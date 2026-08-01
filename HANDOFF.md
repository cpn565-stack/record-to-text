# record-to-text 交班單

- 交班日期：2026-08-02（取代 2026-07-30 舊版敘述）
- Repository：https://github.com/cpn565-stack/record-to-text
- 分支：`main`
- 實作基準：`38de33b`（長音訊 hardening + UX checkpoint）

## 一句話狀態

**Phase 0 / Apple Silicon Developer Mode MVP** 已在 main：20 分外切、120 秒內切、16384 tokens、token 半切與缺口標記、長駐 helper JSONL、Prompt echo 清除、復原掃描、手動開始與 `_逐字稿` 等。本機真實 Metal 已驗證；**不是** 可交付一般使用者的 Stable／公證 DMG。

待辦總表以 **`docs/NEXT_STEPS.md`** 為準（已合併「已完成」與「待修改」）。

## 已確認完成（摘要）

- 原生 SwiftUI macOS App、SwiftPM、詞庫／Prompt／佇列／原子 TXT。
- `ffprobe → ffmpeg → ASR helper → OpenCC → 原子寫入`。
- 長音訊 coordinator（20 分）+ helper 120s + 遞迴半切 + 缺口標記。
- 長駐 helper compact JSONL、job 內 model cache、Prompt 尾端 echo 清除。
- Job ledger（PD-014）、RecoveryScanner、ProcessRunner process group 取消。
- UX：模型選擇（含 BF16）、手動開始、刪除完成工作、About、進度列。
- `scripts/run-checks.sh`（Python + self-test + pipeline）；完整 XCTest 需完整 Xcode。

## 驗證狀態

- 本機 `run-checks`：通過（CLTs 環境 XCTest SKIP）。
- 真實 Metal／Qwen3-ASR：短檔、約 26 分整檔、長會分段等（見 `docs/real-metal-verification-2026-08-01.md`、`docs/handoff-sol-2026-08-02.md`）。
- 正式 Runtime／公證／乾淨帳號 DMG：**未完成**。

## 後續優先（與 NEXT_STEPS 對齊）

1. ffprobe／ffmpeg／OpenCC timeout 與 inactivity watchdog  
2. 暫存與輸出 volume 磁碟空間檢查  
3. 最近工作來源／輸出遺失標示與日誌保留策略  
4. 降低每段模型重複 Fetching／載入  
5. PD-015 自動檢查更新（約每週）  
6. App 管理 Runtime／Model installer、Intel、Universal 2、Developer ID、公證、Stable DMG  

細節、P1–P3 分級與 PD-015 行為規格 → **`docs/NEXT_STEPS.md`**。

## 相關文件

| 文件 | 用途 |
|------|------|
| `docs/NEXT_STEPS.md` | **待辦與已完成總表**（接續用這份） |
| `docs/product-decisions.md` | PD-001～015 |
| `docs/long-audio-token-limit-hardening.md` | Token／chunk 策略 |
| `docs/real-metal-verification-2026-08-01.md` | 2026-08-01 Metal 實測 |
| `docs/handoff-sol-2026-08-02.md` | Codex 工程交接（JSONL／Prompt echo） |
| `CHANGELOG.md` | Unreleased 變更摘要 |
| `README.md` | 環境需求與使用方式 |
