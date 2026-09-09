# 第 3、5 項開發交付（2026-09-09）

狀態：程式實作與本機自動檢查完成；未安裝正式 App、未 commit／push。真實 Google API、使用者錄音與 GUI 操作尚未驗收。

分支：codex/record-to-text-reliability-v2。
HEAD：a889969be46f4acf909c64792fcc2406cf7fff35；變更全在工作區，包含保留的 Grok 第 4 項。

## 本次接續完成

- 根片段 900 秒預算沿 adaptive 子段、retry、fallback 傳遞；request 另有真正的單次 wall-clock 上限，不能只靠 URLRequest 的 inactivity timeout。單次 timeout 可有限重試，root 到期立即停止。
- CancellableCloudRequest 明確持有 URLSessionTask，取消及晚到 callback 經一次性 completion gate；ProcessRunner 沿既有 process handle 取消。
- 補 Vertex auth／GCS upload／503、AI Studio polling／retry、晚到 generation、5 秒本機 process 取消與單次請求時限測試。
- 背景 persistence 使用 serial writer、單一 journal、revision、合併更新及有限重試。MainActor 發送前也只保留最新 pending，避免大量 Task 各持有舊 snapshot。
- OutputPublicationStore 在正式 TXT 發布前保存位置、完成資訊與 SHA-256。啟動只核對已存在的非終止工作；缺檔／hash 不符不標成完成，已刪工作不因殘留 receipt 復活。
- completed journal durable 後回收 receipt／工作暫存；保存失敗時保留復原依據。開始轉錄前先保存工作 ID，避免付費工作沒有可恢復的既有身分。
- 原子發布前後、journal 前後、cleanup 前後以獨立測試程序 `_exit(73)` 驗證。另有 AppViewModel 啟動找回正式稿與刪除不復活測試。
- 憑證 async 保存加入重入防護；退出重試重新保存最新 snapshot，避免只 flush 過時 revision；重複退出請求不建立多份終止 Task。

## 驗證

最終命令：`./scripts/run-checks.sh`，exit 0，結尾「全部驗證通過」。

完整 log：`docs/validation/stability-3-5-final-checks-2026-09-09.txt`。

- XCTest 241 tests／0 failures。
- Swift self-test 72 passed；mock pipeline 10 情境；Python 檢查通過。
- 最終 dist/record-to-text.app 已重新 build；未複製至 /Applications。
- git diff --check 通過。
- 環境：Xcode 26.6（17F113），macOS arm64，App 0.2.1（1）。

實際 AppViewModel.persistJobs 主執行緒測試：10／100／1000 筆工作，各 400 行輸入 log，每輪 100 次提交、各三輪；1000 筆 p95 約 2.7～2.9ms，低於 16ms。背景 writer 沿既有政策裁切保存 log 至 100 行。一次針對性測試的 process 累計峰值 RSS 約 262MB（包含 XCTest、fixture 與 AppViewModel，不是正式 App 常態記憶體用量）。最新完整 log 也記錄各輪數值。

## 範圍與限制

- 這次完成的是 source 與自動化本機驗證，沒有宣稱真實 Google 長音訊、GUI 退出選項人工驗收或正式部署完成。
- 崩潰測試證明程序中止復原，不是斷電或損壞檔案系統保證。
- 同步 manifest commit 仍依賴本機檔案系統完成；未測不可中斷的 kernel／磁碟長時間停滯，5 秒停止目標的實測是外部程序與非合作 async 回應情境。
- 遠端取消只代表本機停止等待並取消傳輸，不保證 Google 遠端運算或計費同步停止。
- 未重做第 4 項真實錄音 baseline／新版各三次比較。
- 既有 Resources/__pycache__ unhandled-file warning 仍存在，未為消除 warning 刪使用者檔案。

前一份 `stability-3-5-pause-handoff-2026-09-08.md` 是歷史 checkpoint；其中 publication crash 缺口、顯式 URLSessionTask、主執行緒 p95、formatter 並行、Vertex budget、憑證重入等項目已在本次接续處理。
