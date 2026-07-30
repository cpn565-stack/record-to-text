# 下一次接續

目前 checkpoint 是 Phase 0 / Apple Silicon Developer Mode MVP，不是可交付一般使用者的 Stable DMG。

## 第一優先：長錄音完整性

依 2026-07-30 的實際觀察，直接處理長錄音可能只輸出前段。下一次先實作 PD-013：

1. ffprobe 取得總時長。
2. 超過 30 分鐘時，由 Swift coordinator／ffmpeg 產生每段最長 30 分鐘的編號 WAV。
3. 每段使用獨立 ASR 呼叫、token budget、完成事件與非空白 UTF-8 驗證。
4. 全部片段數量與順序完整後才合併、OpenCC、原子提交正式 TXT。
5. 以 31、65、120 分鐘 fixture 驗證；尾端放置唯一驗證句。
6. 任一片段失敗、空白、達 token limit 或未 completed 時，不得提交部分正式 TXT。

現有 helper 內部 chunk 不算完成此需求。

## 其次處理

- Job ledger 的保存上限不得套用到 active／queued 工作；`recentJobLimit=0` 仍須保存未完成工作。
- 啟動時掃描並整理 system temp 與 `Temp-Recovery`，避免 crash 後產生孤兒音訊或 request。
- 修正 ProcessRunner 在 launch 前取消的 race，並評估 helper 子程序樹終止。
- 為 ffprobe、ffmpeg、OpenCC 加入合理 timeout／inactivity watchdog。
- 同時檢查暫存磁碟與實際輸出 volume 的可用空間。
- 最近工作顯示來源／輸出已移動或刪除；決定完成工作日誌的保留策略。

## 尚待外部驗證

- 完整 Xcode 執行 45 個 XCTest。
- 可使用 Metal 的真實 Qwen3-ASR：1、30、65、120 分鐘。
- App 管理且簽署的 Runtime／Model installer、Intel 實機、Universal 2。
- Developer ID、notarization、乾淨帳號與正式 DMG。
