# Security and privacy

## Privacy boundary

- **本機 Qwen**：音訊、Prompt、詞庫與逐字稿不離開使用者電腦；網路只用於 Runtime／模型下載與主動更新。
- **Google AI Studio／Vertex AI**：壓縮或分段音訊、Prompt 與詞彙會送往 Google 以執行轉錄。使用者在切換後端時必須視為隱私邊界變更。
- 來源的完整本機路徑不得加入雲端 Prompt／HTTP payload。
- 診斷資訊預設不得包含音訊、逐字稿正文或完整詞庫。

## Credential boundary

- Google AI Studio API Key 必須放在 macOS Keychain 或等效的系統憑證儲存，不得寫入 `settings.json`、`job-ledger.json`、Prompt 或 log。
- 舊版 JSON 中的 API Key 只能用於單次遷移；成功移入憑證儲存後，必須重寫去除明文的 JSON。
- Vertex AI 使用 `gcloud` 取得短效 access token；token 不得持久化或出現在 log。

## Process boundary

- 外部程序一律使用 executable URL 與 arguments，不經 shell 字串拼接。
- Prompt 寫入權限為 0600 的 request JSON，不放在 argv。
- Helper stdout 專供 JSONL；第三方輸出與技術日誌走 stderr。
- Helper 子程序只接收必要環境變數白名單，不繼承 GitHub、雲端或資料庫憑證。
- Helper 必須同時符合 exit code 0、唯一 completed event、預期路徑，以及非空白 UTF-8 輸出，才視為成功。
- 使用者正式輸出採 `RENAME_EXCL` 原子提交；競態下改用下一個檔名，不覆寫既有檔案。
- 工作暫存與復原目錄權限為 0700；request JSON 為 0600。成功後清除工作暫存；失敗時只能把復原所需的最小資料移到 App 管理的 `Temp-Recovery`。
- 雲端工作取消時，若已有完成片段，會在清除工作暫存前只保留可人工取回的部分 TXT、manifest 與最小 metadata，不保留分段 MP3。若無完成片段，復原掃描不得顯示有部分稿。
- 雲端部分 TXT 只供取回與人工整理，不能當成自動斷點續跑狀態；重新加入原始錄音會從頭轉錄。

## Runtime trust

目前 Developer Mode 只供使用者明確選擇的本機開發環境。未開啟 Developer Mode 時，本機 Qwen Runtime 必須 fail-closed；不得只因檔案存在就視為可信。正式 Runtime 必須：

- 由 App 內建 trust anchor 驗證 signed manifest。
- 鎖定 HTTPS host、架構、版本、SHA-256、檔案清單與 Team Identifier。
- 驗證所有 Mach-O、dylib 與 Python native extension 的 code signature。
- 下載至 staging，驗證後才原子切換，更新失敗時保留上一版。
- 不以移除 quarantine 或關閉 Gatekeeper 規避驗證。

## Reporting

請不要在公開 issue 附上音訊、逐字稿、詞庫、完整路徑、憑證或 token。先提供不含內容的版本、架構、錯誤碼與最小重現步驟。
