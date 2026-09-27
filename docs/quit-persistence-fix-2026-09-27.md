# 0.2.1 build 9：退出儲存修正

日期：2026-09-27。此版本包含 Qwen 階段 0／1／1.1 與退出流程修正；不代表階段 2／3 已完成。

## 問題與修正

- 已用隔離測試重現：Keychain 啟動讀取尚未完成時，`persistJobs()` 一律延後寫入，退出緊接著 flush，立即拋出一般檔案寫入錯誤。這不一定是對話框所說的「超過 5 秒」。
- 不含待遷移舊憑證的工作紀錄，現在不必等待無關的 Keychain 讀取。轉錄啟動仍維持原有憑證載入檢查，沒有放寬雲端執行授權。
- 含舊憑證的 ledger 仍須先成功備份至 Keychain 才能改寫。退出會在共用的 5 秒期限內等待載入；逾時仍保留原檔，之後可重試。
- 取消退出會清除 ViewModel 的退出狀態，允許使用者手動再啟動工作，但不會自動重啟或發送雲端請求。
- 每次退出會使之前尚在等待儲存的雲端重送請求失效；即使之後取消退出，舊請求也不能自行恢復執行。續作保留在佇列，仍須使用者重新確認重送。
- 退出視窗與主畫面保留實際原因，區分舊紀錄讀取失敗、憑證遷移、磁碟寫入失敗及等待逾時；不再對儲存錯誤顯示雲端「本片段」訊息。
- 無法解讀的 journal 仍禁止覆寫；未移除資料保護，也未刪除使用者的紀錄或輸出。

原始截圖當下的完整錯誤未被舊版本記錄，因此不能斷言它一定來自上述 Keychain 情境。現存 journal 經唯讀檢查可解碼；新錯誤訊息可在再次發生時辨識其他原因。

## 驗證

`SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 ./scripts/run-checks.sh` 通過：

- Swift：514 tests，0 failures；包含新增的 8 個退出儲存與重送競態回歸案例。
- Python：134 tests；executable self-test 與 10 個 pipeline 情境通過。
- 新增前的兩個 Keychain 回歸案例會失敗，修正後通過。
- AppKit 隔離程序實際呼叫 `NSApplication.terminate`：憑證已載入及模擬仍在載入兩種情境均正常退出，沒有觸發儲存警告；未讀寫使用者的工作資料。
- 未執行真實模型或付費 API。Qwen 靜音感知維持進階選項、預設關閉；真實模型 A/B 仍待驗證。

## 發佈界線

`Config/version.env` 設為 0.2.1／build 9。本輪準備 Apple Silicon 的 release 組態測試包，使用 ad-hoc 簽章，不是 Developer ID 簽章或 Apple 公證。

產物 `dist/record-to-text-0.2.1-build9-development.dmg` 與對應 `.sha256` 已建立；App 版本、arm64 架構、資源、體積限制、ad-hoc 簽章及 DMG 核對碼驗證通過。

本機 `/Applications/record-to-text.app` 已更新為 build 9，與 dist 執行檔 SHA-256 一致。build 8 保留於 `dist/install-backups/before-quit-fix-build9-20260927.noindex/record-to-text.app`，避免備份 App 再被 Spotlight 索引。更新時 App 未執行，更新前後 journal 與 previous journal 的 SHA-256 不變；未啟動正式 App 或更動使用者工作資料。

本機未找到 Developer ID Application 憑證，因此不建立正式 Stable Release、不假裝通過 Gatekeeper／公證。正式公開交付仍須依 README 完成 Developer ID 簽署、公證與發佈檢查；公開前也應用新版本完成一次實際操作與正常退出驗收。
