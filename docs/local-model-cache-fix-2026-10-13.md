# 本機模型驗證修正（build 11）

2026-10-13。本次修正本機 Qwen 模型已下載，卻仍顯示找不到 snapshot、無法建立 local-checkpoint-v2 的問題。

## 原因與修正

- `TranscriptionEngine.prepareLocalCheckpointV2` 原本把 `ApplicationPaths.models` 直接交給模型 manifest；實際下載、模型檢查及 Python helper 都使用其下的 `hub`。改為共用 `ModelCache.hubRoot(modelsDirectory:)`。
- Hugging Face snapshot 主要由指向 `blobs` 的符號連結組成；原本的 `attributesOfItem` 讀到連結類型後，將模型權重跳過。改為解析連結，再讀實際檔案的大小與內容 hash；保留連結屬性的紀錄。未能解析的連結會拒絕 manifest，避免只驗到 metadata。
- 取消模型 hash 驗證時，保留 `CancellationError`，不誤記為模型無法驗證。
- 整合測試 fixture 改用真實的 `Models/hub` 目錄，新增符號連結、同大小權重變動及損壞連結的回歸測試。

原警告只停用可驗證的跨次續跑，不會直接取消工作。調查時 App 路徑與 build 10 相符；既有模型權重的 SHA-256 與本機 blob 名稱一致，不需要重新下載。工作取消和該警告分開判讀，不推定所有取消都是轉錄引擎失敗。

## 驗證

- 修改前，真實快取目錄整合測試、符號連結內容驗證、損壞連結拒絕等3個回歸測試均重現失敗。
- 修改後，模型快取、manifest、checkpoint v2、pipeline與整合相關111個測試通過。
- 以既有模型與一段12秒本機音訊，完全離線跑原 helper 成功，約4.6秒。
- 修正後另以隔離 `ApplicationPaths` 跑真實 `TranscriptionEngine`，強制切成兩個6秒段；模型驗證、checkpoint、推論、合併及文字輸出通過，約7.9秒。未重跑整份長錄音。
- `LocalLiveModelSmokeTests` 預設跳過；提供 `R2T_SMOKE_MODELS`、`R2T_SMOKE_AUDIO`、`R2T_SMOKE_PYTHON` 才會讀既有模型與短音訊執行。測試強制 `offline: true`，工作紀錄和輸出置於隔離暫存目錄。

版本：0.2.1（11）。沿用 Apple Silicon release 組態與 ad-hoc 簽章，不代表已公證的正式版本。使用者模型、設定及工作佇列不由修正程式改寫。

## 本機安裝

使用者確認原轉錄完成並要求重開後，已更新 `/Applications/record-to-text.app` 並啟動 build 11。安裝前後的13筆既有工作狀態一致，退出至安裝完成期間設定檔未變；最近完成的轉錄仍保留在歷史紀錄。已驗證安裝後執行檔與 release 產物一致、簽章有效且新程序正常執行。build 10 備份保留於 App 資料目錄的 `AppBackups/build10-before-model-cache-fix-20261013.zip`，壓縮檔完整性已驗證。
