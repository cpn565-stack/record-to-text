# 排隊工作模型選擇修正

問題：加入錄音時保存的 JobSnapshot 不會隨上方選單更新，造成畫面顯示 AI Studio，
已排隊的工作卻仍以 Qwen 執行。

新行為：主畫面快速選單與 Runtime 設定頁的引擎設定更新時，同步更新尚未開始、
沒有 recovery checkpoint 的 queued 工作，並保存 ledger。保留工作 ID、詞庫、
Prompt、來源時間範圍及輸出設定，不將 API Key 寫入工作 snapshot。
正在執行、有 startedAt 或從 checkpoint 續跑的工作不會被切換。

主畫面標示選單適用新錄音與未開始工作；每張工作卡顯示 snapshot 的後端與模型。
執行期間另顯示正在執行的模型，避免與下一筆的選擇混淆。

回歸測試涵蓋 AppViewModel 加檔後 Qwen → AI Studio 快速切換、設定頁切換 Vertex、
ledger 保存及執行中／checkpoint 排除條件。

## Vertex STOP 空內容修正

兩筆使用者日誌皆顯示 Vertex HTTP 200、finishReason=STOP，但缺少 candidate parts，
只有 thinking token，無可交付逐字稿。這能確認回應形狀，不能確認 Google 端原因。
新增獨立 emptyCompletedResponse 分類；僅 STOP 的缺少 parts、空白或 thought-only
內容走既有同模型重試迴圈，含首次最多 4 次，沿用已準備音訊、原片段預算、取消機制。
重試耗盡會明確記錄停止原因，不因空回應切換模型；其他空結果、安全封鎖、
不完整 finishReason 和 MAX_TOKENS 保持既有處理。

## 驗證與交付

- 修改前新增兩個後端回歸測試，重現首次空結果即失敗、只有一次請求。
- 修改後完整 `./scripts/run-checks.sh` 通過：248 項 XCTest 零失敗、Python、
  72 項 executable self-tests、10 種 pipeline mock 情境、App build/package。
  完整 log：`/tmp/record-engine-vertex-full.log`。
- 原 0.5 秒 backoff 測試先預載 mock 認證，再建立相同 0.5 秒預算；
  避免程序啟動速度干擾重試邊界，未更動正式逾時設定。另測 STOP 重試受同一預算限制。
- 確認無既有 App 程序後備份、安裝至 `/Applications/record-to-text.app`。
  首次合併複製偵測到舊資源導致簽章驗證失敗，已改為乾淨目錄整包替換並重新驗證。
  installed/dist 執行檔 SHA256 相同：
  `dd1cb3e1a4f14effc63a361a10b164d43d5b1717eb90dd7a0bf61de0dcf4c395`。
- 舊版備份：`~/Library/Application Support/record-to-text/App-Backups/20260909-151150/record-to-text.app`。
- 已啟動新版並檢視 AX 與截圖：選單範圍、工作卡後端／模型、檢查點標示完整顯示。
  原有工作及救援資料保留，未觸發雲端重跑。
- New Recording 29 的 manifest 前兩段 completed、第三段 failed，工作卡提供續跑；
  New Recording 26 第一段 failed、第二段 planned，尚無已完成逐字稿。
- 尚未用原音檔實際呼叫 Google 驗證；不能保證供應端重試一定成功。

