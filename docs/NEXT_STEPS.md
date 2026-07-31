# 下一次接續

目前 checkpoint 是 Phase 0 / Apple Silicon Developer Mode MVP，不是可交付一般使用者的 Stable DMG。

## 已完成：長錄音完整性

PD-013 的 coordinator-level 實作已完成：

1. ffprobe 取得總時長，`AudioSegmentPlanner` 以 **1,200 秒（20 分鐘）** 建立分段計畫；每段 ASR 預設 token 預算 **16384**。
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

## 已完成：啟動復原掃描（唯讀 + 操作 UI）

- `RecoveryScanner` 盤點 system temp `record-to-text/<UUID>` 與 App `Temp-Recovery/<UUID>`。
- 只接受 UUID 目錄；非 UUID 計入 ignored，不掃管線外路徑。
- 分類：可復原（有效 recovery.json + WAV）、孤立暫存、損壞／schema 不符。
- 啟動有發現時顯示 sheet；工具列「復原掃描」可重跑。
- **刪除／批次清除孤立與損壞**：二次確認；`validatedManagedJobDirectory` 拒絕範圍外路徑。
- **可復原**：可「重新加入來源」音檔到佇列（來源仍存在時）；Finder 顯示復原目錄。
- **不自動刪除**；不刪原始錄音或正式 TXT。

## 已完成：ProcessRunner 取消 race 與程序樹

- `cancelRequested`：launch 前取消也能中止，不再只在 `isRunning` 時送訊號。
- 啟動後 `setpgid`；取消時對 **process group** 送 SIGINT → SIGTERM → SIGKILL，涵蓋 helper 子程序。

## 第一優先（下一輪）

- 為 ffprobe、ffmpeg、OpenCC 加入合理 timeout／inactivity watchdog。
- 同時檢查暫存磁碟與實際輸出 volume 的可用空間。
- 最近工作顯示來源／輸出已移動或刪除；決定完成工作日誌的保留策略。

## 規劃中：自動檢查更新（約每週一次）

產品要做 **App 自動檢查更新**，不要做成每次開 App 都打網路。

### 行為目標

- **預設間隔**：約 **7 天** 檢查一次（可設定，例如關閉／每天／每週）。
- **觸發時機**：App 啟動後、且距上次成功檢查已超過間隔；背景安靜檢查，不擋轉錄佇列。
- **有新版本時**：非阻斷提示（通知或設定內 banner），顯示目前版號、新版版號與 Release 說明摘要；使用者決定是否開啟下載頁。
- **無新版本／離線／檢查失敗**：安靜失敗或僅在設定顯示「上次檢查時間」，不要一直跳錯誤。
- **手動**：設定內提供「立即檢查更新」。

### 技術方向（實作時再定稿）

- 來源優先 **GitHub Releases**（例如 `cpn565-stack/record-to-text` 的 latest / 已標記 prerelease 策略要分開：Stable 只看正式 release）。
- 比對 `CFBundleShortVersionString`／`CFBundleVersion` 與遠端 tag 或 manifest。
- 只做 **檢查 + 引導下載**；自動下載安裝可第二階段（需簽署 DMG／公證後再談 Sparkle 或自管 installer）。
- 記錄 `lastUpdateCheckAt` 於 `settings.json`；遵守「不把 token 寫進 repo」；公開 API 即可，不需使用者 HF token。
- 與 Runtime／模型更新分開：App 更新 ≠ 模型重下；模型更新仍走既有 Models 流程。

### 依賴

- 較適合在 **有正式 Release 發佈流程** 後上線；Phase 0 可先做 stub／設定項與週期邏輯，遠端 URL 對準 GitHub Releases。

## 尚待外部驗證

- 可使用 Metal 的真實 Qwen3-ASR：1、30、65、120 分鐘。
- App 管理且簽署的 Runtime／Model installer、Intel 實機、Universal 2。
- Developer ID、notarization、乾淨帳號與正式 DMG。
