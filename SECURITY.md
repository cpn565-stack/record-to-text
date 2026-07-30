# Security and privacy

## Privacy boundary

- 音訊、逐字稿、詞庫、檔名與本機路徑預設不離開使用者電腦。
- 網路只用於 Runtime／模型下載與使用者主動檢查更新。
- 診斷資訊預設不得包含音訊、逐字稿正文或完整詞庫。

## Process boundary

- 外部程序一律使用 executable URL 與 arguments，不經 shell 字串拼接。
- Prompt 寫入權限為 0600 的 request JSON，不放在 argv。
- Helper stdout 專供 JSONL；第三方輸出與技術日誌走 stderr。
- Helper 子程序只接收必要環境變數白名單，不繼承 GitHub、雲端或資料庫憑證。
- Helper 必須同時符合 exit code 0、唯一 completed event、預期路徑，以及非空白 UTF-8 輸出，才視為成功。
- 使用者正式輸出採 `RENAME_EXCL` 原子提交；競態下改用下一個檔名，不覆寫既有檔案。
- 工作暫存與復原目錄權限為 0700；request JSON 為 0600，成功與取消會清除工作暫存。

## Runtime trust

目前 Developer Mode 只供本機驗證。正式 Runtime 必須：

- 由 App 內建 trust anchor 驗證 signed manifest。
- 鎖定 HTTPS host、架構、版本、SHA-256、檔案清單與 Team Identifier。
- 驗證所有 Mach-O、dylib 與 Python native extension 的 code signature。
- 下載至 staging，驗證後才原子切換，更新失敗時保留上一版。
- 不以移除 quarantine 或關閉 Gatekeeper 規避驗證。

## Reporting

請不要在公開 issue 附上音訊、逐字稿、詞庫、完整路徑、憑證或 token。先提供不含內容的版本、架構、錯誤碼與最小重現步驟。
