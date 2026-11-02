# 2026-10-28–29 雲端轉錄錯誤調查

## 範圍與限制

檢查本機 journal、recent history、Temp-Recovery manifest／descriptor、已安裝執行檔、程式與系統睡眠紀錄。時間以 UTC+8 表示；保留的這批失敗資料集中在 10/29。初次快照為 13:52:49，另核對至 13:58:23 的新完成／失敗工作。不讀取訪談正文，不重送、上傳、安裝或中斷正在執行的 App。

安裝版本仍為 0.2.1（16），SHA-256 為 `cf2b10c86ba440f3598a84ad14af0339fbd71f6e2e0e897b12cf8a2ce7768457`，與先前驗證相同。工作樹原有修改不代表已安裝到 App。

初次快照有 15 份本輪異常執行的 recovery manifest；其中包含同一錄音的不同執行及續跑歷史，不能當成 15 份不同錄音或目前仍失敗。最近完成清單只保留 10 筆，完整成功較早即可能被裁切，因此本次不能算整批成功率。初次快照另可確認 4 筆完整成功，13:56 再確認 1 筆完整成功。

按事件時間、root、片段、attempt、category 去除沿用歷史與終止摘要重複，初次快照有 18 次異常操作；13:58 新增一次攔截，共 19 次。片段擷取失敗尚未送出雲端請求，不應把 19 全稱為 Google 請求失敗。

| 類型 | 次數 | 可確認的來源／責任 |
| --- | ---: | --- |
| promptFeedback 攔截 | 8 | Google 回傳；`OTHER` 6 次、`SAFETY` 1 次、`PROHIBITED_CONTENT` 1 次 |
| 沒有可用正文 | 5 | Google 空回應；另發現 App AI Studio 缺少空 STOP 重試 |
| `-1005` 連線中斷 | 4 | 同一片段四次；代理／上游連線問題可疑，未證實具體斷線端 |
| 上傳初始化期限到期 | 1 | 電腦合蓋睡眠、網路不可用，喚醒後 App 檢查期限 |
| 來源檔案不存在 | 1 | 本機原始來源路徑失效，尚未發送該片段 |

## Google 攔截

真實 HTTP 200 回應含 promptFeedback blockReason、modelVersion 及新 response ID。這不是 App 自行產生的安全判斷，也不是根據 HTTP 狀態誤判。Google 將 `OTHER` 定義為原因不明的 prompt 攔截；缺少 safety ratings，不能推定具體觸發內容或斷言錄音違規。[官方 API 定義](https://ai.google.dev/api/generate-content#BlockReason)。

天津 10/21-1、10/21-2、10/22-3 是 `OTHER`；10/22-1 是 `PROHIBITED_CONTENT`。這四份 job snapshot 的錄音背景皆為空字串，足以排除「新增背景文字是所有攔截的必要條件」，但不能排除既有提示／詞庫／音訊對服務判斷的影響，也不能依此宣稱 Google 發生全面服務故障。

石家莊兩個舊缺口續跑仍分別收到 `SAFETY`／`OTHER`，其背景非空並沿用舊 snapshot。長沙另有一次 `OTHER`，只留下 recovery 資料，無法核對其原始背景。天津 10/21-2 於 13:58 手動重送後再次收到 `OTHER`，計入上述第 8 次攔截。

App 只有明確安全代碼會繼續並輸出含缺口成稿；`OTHER` 保留完成片段、將整體列失敗。此狀態差異是既有規則，不是解析回歸；但頂層 `contentBlocked` 訊息未清楚呈現實際 blockReason，仍有改善空間。

## Google 空結果與 App 復原缺口

長沙兩份、南京兩份、天津一份各有一次 HTTP 200、516 bytes 的 `emptyResponse`。天津 10/22-2 的保留 inventory 明確顯示 `missing_candidate_parts`、`finishReason=STOP`、`parts=0`、4,883 thinking tokens，沒有 promptFeedback blockReason。其正文在解析前就不存在，不能說 App 清掉了收到的逐字稿。其他四筆沒有完整 inventory 留存，僅憑相同回應大小不能斷言原始 JSON 每個欄位相同。

已確認 App 處理差異：

- `GeminiResponseParser.swift:14–20`：AI Studio 將空正文 STOP 映射為一般 `.emptyResponse`；Vertex 另用 `.emptyCompletedResponse`。
- `GeminiGenerationRetry.swift:114–134`：只有 Vertex 的 `.emptyCompletedResponse` 進入空結果重試。AI Studio 收到同類結果就停止。
- `CancellableCloudRequest.swift:175,421–424`：只有 SSE accumulator 提供結構化 finishReason；AI Studio unary JSON 的 failure event 可能缺少 STOP，需參考 inventory 日誌。

結論是「服務端回空結果，App AI Studio 復原能力不完整」。補上有限次重試可能減少人工重送，但不能保證 Google 下一次一定產出正文。這些差異在背景功能之前的 `1f8e4c8`／`9081990` 已存在。

既有離線測試 `testMissingCandidateContentAndWhitespaceAreErrors` 與 `testEmptyStopRetriesSameModelAndSucceeds` 重跑通過：前者直接驗證兩個 backend 對最小空 STOP 的不同 mapping，後者驗證 Vertex 同模型重試成功。沒有修改 production code 或新增真實請求。

南京 10/26-1 在稍後手動重送後已三段完整成功，舊 emptyResponse 仍保留在累計 failureHistory，不應把舊錯誤當成這次又失敗。

## 代理連線中斷

南京 10/26-4 第 3 段連續四次 `NSURLErrorDomain -1005`，約 84.21／61.42／61.06／61.12 秒；均為 `unaryJSON`、HTTP/2、`usedProxy=true`、回應 bytes=0，沒有 Google HTTP 錯誤碼或內容攔截回應。當時 02:19–02:30 沒有睡眠事件。前兩段已完成，第三段重試四次後保留工作。

`-1005` 表示載入中的網路連線中斷。[Apple 說明](https://developer.apple.com/library/archive/qa/qa1941/_index.html)。目前系統 HTTP／HTTPS／SOCKS 代理指向 `127.0.0.1:7890`。約 61 秒重複斷線符合代理或上游閒置關閉的可能性，但沒有當時代理的連線日誌，無法指定是哪個節點關閉。兩個先前成功片段也經代理且超過 60 秒才收到回應，不能認定代理對所有請求都有固定 60 秒上限。

AI Studio 在這個版本使用一次回傳的 JSON；等待模型思考時不會持續收到 SSE。這是可改善的傳輸相容性方向，但目前不足以把斷線指定為 App 的 timer 故障或 Google 模型錯誤。這四次都未達 Flash 300 秒生成期限。

## 合蓋睡眠與上傳期限

天津 10/22-4 的系統事件與 App 時間完全對上：

| UTC+8 時間 | 事件 |
| --- | --- |
| 07:52:15 | 開始工作 |
| 07:52:19 | 電池供電時進入 Clamshell Sleep |
| 07:54:16 | DarkWake；App 記錄上傳初始化逾時，經過 114.85 秒 |
| 07:57:35 | 再入 Maintenance Sleep，持續約 3,146 秒 |
| 08:50:01 | DarkWake；App 檢查 root deadline、停止等待 |

該次是 Files API 初始化請求（`rawData`），正常設定期限為 30 秒，並未送出模型生成：`generationRequestCount=0`。程式無法在電腦睡眠時即時完成取消／寫日誌，故看到大於 30 秒才記錄超時。約 3,345 秒 backoff 主要含睡眠，並非 App 在正常運行中忽略 900 秒原始段期限，也不是 Google 推論花近一小時。

App 使用 `ContinuousClock`，會計入睡眠時間，恢復執行後檢查期限。防閒置睡眠 assertion 不能阻止這次明確合蓋；系統紀錄中該 assertion 仍存在。13:50 續跑後，13:56:32 三段各一次成功且完整輸出，支持這次屬執行環境中斷，而非錄音本身永遠無法處理。

## 來源檔案路徑失效

長沙 10/26-F-R02 在第 1 段成功後，第 2 段 ffmpeg 回報 `No such file or directory`，發生在 extract 階段。原 `Changsha-…` 名稱已不存在，同目錄現在有 `CS-…` 名稱的對應錄音，稍後亦有使用新名稱的工作。較符合改名／移動／同步導致舊來源失效；無改名事件或原檔雜湊，不能斷言由誰操作或保證檔案內容完全相同。

此筆與 Google API 無關。可改進 App 對錄音執行期間路徑變動的提示及來源保護；本輪沒有移動、覆寫或重新加入來源。

## 判斷與建議優先序

1. 補齊 AI Studio 空 STOP 的有上限重試，並保留 unary JSON 的 finishReason／blockReason 診斷，避免一般空回應與明確政策攔截混在一起。
2. 針對 AI Studio 長時間等待，評估串流傳輸與代理路徑相容性；需針對現有 proxy 做受控驗證，不推定全部是 Google 問題。
3. 改善合蓋／喚醒後的工作提示與來源路徑失效提示；等待期間保持電腦清醒、來源檔名穩定。
4. 服務端明確攔截需另外處理；重試或加長期限不能保證消除它。

本輪是診斷交付，未實作以上修正。未發現這批有舊的「生成中被 300 秒絕對期限切斷」事件；該既有問題仍待處理，不能套用到本輪所有錯誤。
