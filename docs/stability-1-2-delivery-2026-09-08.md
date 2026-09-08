# 第 1、2 項實作與驗證紀錄

日期：2026-09-08。分支 codex/record-to-text-reliability-v2。
HEAD 88f9f69904f6991924f43d15638a754a50ea4ca2；本次與先前 MAX_TOKENS 改動仍在工作區，未 commit/push。

## 1. 啟動不被憑證讀取阻塞

- AppViewModel.init 不再同步呼叫 Keychain。
- 單一專用 DispatchQueue 執行啟動讀取及必要的舊資料轉移；MainActor 僅接收結果。
- 載入期間其他設定／主視窗仍可操作；AI Studio 工作留在 queued，完成載入才排程。
- 載入期間禁止與 startup read 衝突的憑證儲存／清除／重設；只更新目前設定的 API Key 欄位，不用舊 snapshot 蓋掉使用者修改。
- 失敗保留舊資料與可讀錯誤；沿用原本轉移與重試規則。
- 此項只移除啟動的 Keychain 阻塞；其餘 JSON 寫入與明確按儲存時的 Keychain 操作不是本次效能重構範圍。

## 2. 暫時性網路錯誤有限重試

- AI Studio 與 Vertex generation 請求可重試 timedOut、networkConnectionLost、notConnectedToInternet、cannotConnectToHost、cannotFindHost、dnsLookupFailed。
- 每模型最多 4 次；與既有 HTTP 重試共用次數，不另外增加一輪。
- 重用 prepared audio；AI Studio Files API 成功上傳後，不因 generation 重試而重複上傳。
- 網路錯誤耗盡直接交回原錯誤，不觸發模型 fallback。
- URL cancellation／Task cancellation 立即停止，backoff 可取消；非暫時性錯誤不自動重試。
- 此變更針對 generation，不是所有 upload／poll／gcloud 操作的通用重試框架。
- 連線中斷後無法保證 Google 沒處理上一個請求，因此不能承諾 exactly-once 或重試不重複計費。

## 證據

- 修改前針對性測試：2 tests / 2 failures，分別重現初始化阻塞與短暫斷線直接失敗。
- 第一組修改後：49 tests / 0 failures。
- scripts/run-checks.sh：完整通過，包含 192 XCTest、Python tests、Swift executable self-tests、10 mock pipeline scenarios、App bundle。
- 最後新增 queued 等待測試及主視窗載入說明後：AppCredentialMigrationTests 13 tests / 0 failures，App 重新打包成功。
- slow store 測試確認初始化不等待 400ms 模擬阻塞；其他設定可在載入中修改，完成後仍保留。
- retry exhausted 測試 4 次停止；backoff 取消測試只有 1 次 generation；Files API 測試 1 次 upload／2 次 generation／1 次 delete。
- Vertex 以 fake gcloud 和 URLProtocol 模擬逾時後成功。
- git diff --check 通過。
- 新增網路錯誤測試未呼叫真實 Google API；真實斷網／喚醒／長音訊壓力測試未執行。

## 安裝

- 已更新 /Applications/record-to-text.app，與 dist executable SHA256 一致：
  1e21c58d95d091c7b6cfd8c5bd654df48a2ae201f4a5e53d54eb6b16c9f71298
- codesign --verify --deep --strict 通過。
- 舊版備份：~/Library/Application Support/record-to-text/AppBackups/20260908-211437/record-to-text.app.zip
- 安裝前確認 App 無執行中程序。
- 安裝後 CUA 可讀取復原掃描視窗、關閉它、取得主視窗並展開轉錄設定，確認目前版本正常回應操作。
- 沒有自動重送使用者錄音。
- 第 3～5 項詳見 stability-performance-3-5-spec-2026-09-08.md，尚未實作。
