# 下一次接續

目前 checkpoint 是 Phase 0 / Apple Silicon Developer Mode MVP，不是可交付一般使用者的 Stable DMG。

## 已完成：長錄音完整性

PD-013 的 coordinator-level 實作已完成：

1. ffprobe 取得總時長，`AudioSegmentPlanner` 以 1,800 秒建立分段計畫。
2. Swift coordinator／ffmpeg 產生依序編號的 WAV。
3. 每段使用獨立 ASR 呼叫與 token budget。
4. Segment manifest 要求編號連續、順序正確、非空白 UTF-8 且 completed 恰好一次。
5. 全部片段通過後才以 LF 合併、OpenCC、原子提交正式 TXT。
6. 31／65／120 分鐘規劃 fixture，以及縮時真實 ffmpeg／OpenCC mock E2E 已通過。
7. 中段／尾段失敗、空白、token limit 或未 completed 時，皆不提交部分正式 TXT。

尚待真實 Metal 模型與 31／65／120 分鐘音檔 soak test；完成前不宣稱正式支援任意長度。

## 已完成：Job ledger 保存

- Job ledger 保存上限不再套用到 queued／active／interrupted 工作。
- `recentJobLimit=0` 與超長佇列都會完整保存 durable jobs。
- completed 不進 ledger；failed／cancelled 只保留最新 terminal history。
- 已加入 JSON round-trip、restart retention、terminal 裁切與 log cap 測試。

## 第一優先：啟動復原掃描

- 建立唯讀 scanner，盤點 system temp `record-to-text/<jobID>` 與 `Temp-Recovery`。
- 只接受 UUID job 目錄與本 App 定義的檔名／metadata schema。
- 顯示可復原、孤立、損壞三種狀態；第一步不自動刪除。
- 不追蹤或刪除 App 管理根目錄以外的任何路徑。

## 其次處理

- 修正 ProcessRunner 在 launch 前取消的 race，並評估 helper 子程序樹終止。
- 為 ffprobe、ffmpeg、OpenCC 加入合理 timeout／inactivity watchdog。
- 同時檢查暫存磁碟與實際輸出 volume 的可用空間。
- 最近工作顯示來源／輸出已移動或刪除；決定完成工作日誌的保留策略。

## 尚待外部驗證

- 可使用 Metal 的真實 Qwen3-ASR：1、30、65、120 分鐘。
- App 管理且簽署的 Runtime／Model installer、Intel 實機、Universal 2。
- Developer ID、notarization、乾淨帳號與正式 DMG。
