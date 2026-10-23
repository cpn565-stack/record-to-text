# Vertex AI 串流回應修復規格

日期：2026-10-17。狀態：待實作。本次交付限於規格與研究證據；不修改 App 程式、不 build、不安裝。

## 1 目的與實作基準

將 Vertex 音訊轉錄改為接收 Google 的串流回應，降低長時間等待整份逐字稿時的連線中斷風險。對轉錄管線仍回傳一份經完整性驗證的結果，沿用既有純文字繁中逐字稿、講者與時間區間格式。

實作基準為已安裝的 **0.2.1 build 13** 對應工作樹：`/Users/mike/.codex-personal/worktrees/2089/record-to-text`，分支 `codex/fix-local-model-cache-20261013`。其中有 build 11–13 的未提交修改，實作須保留。一般專案目錄的 build 10 不是本規格的程式基準。

成功標準是：正式 Vertex backend 能以串流端點完成受控長音訊；斷線、截斷、封鎖、取消及錯誤回應不會被當作完整逐字稿保存。串流成功不代表已證明辨識準確度，也不保證消除 Google 的容量限制。

## 2 已確認的問題與研究證據

2026-10-17 共做 8 次真實 Vertex 請求，使用自製合成語音。長音訊為 1,200 秒、16 kHz、單聲道、24 kbps MP3，共 3,600,513 bytes；模型使用 `global`、`v1`、`high`。測試中的輸出 token 上限為 32,768，與正式 Flash 的 65,536 不同，正式驗收須涵蓋實際設定。

| 模型與條件 | 觀測結果 |
| --- | --- |
| 3.8 Flash，短音訊，Swift 系統代理 | 3.834 秒，HTTP 200、STOP |
| Gemini 4 Argon，短音訊，Swift 系統代理 | 5.156 秒，HTTP 200、STOP |
| 3.8 Flash，20 分鐘，Swift HTTP/2 系統代理，非串流回應 | 18.182 秒上傳完成；81.108 秒發生 `NSURLErrorDomain -1005`，沒有回應標頭或內容 |
| 3.8 Flash，另一筆非串流請求 | 80.237 秒收到 HTTP 429、`RESOURCE_EXHAUSTED`；該筆雖嘗試停用代理，metrics 仍是 `proxy=true`，不得列為直連對照 |
| 3.8 Flash，相同長音訊，Swift HTTP/2 系統代理，SSE | 51.740 秒收到第一批資料；76.906 秒 HTTP 200、STOP，18,818 字元 |
| Gemini 4 Argon，相同長音訊，Swift HTTP/2 系統代理，SSE | 35.616 秒收到第一批資料；87.403 秒 HTTP 200、STOP，19,302 字元 |
| 3.8 Flash，相同長音訊，Python HTTP/1.1，略過 HTTP 代理 | 71.275 秒 HTTP 200、STOP |
| 3.8 Flash，相同長音訊，Python HTTP/1.1，明確經 localhost 代理 | 57.023 秒 HTTP 200、STOP |

去識別化原始量測及音訊 SHA-256 保存在 [研究證據 JSON](evidence/vertex-streaming-probe-2026-10-17.json)。研究探針與合成素材暫存於 `/tmp/record-vertex-investigation-20261017`；正式驗收不能依賴暫存檔永久存在。

**事實：** 兩個模型均能完成 20 分鐘音訊請求。失敗案例發生在上傳完成約 63 秒後，並非音訊尚未送完。另有一筆 Google 429，須獨立處理。

**推測：** 長時間沒有回應資料的連線路徑可能是斷線因素。現有樣本無法確定責任在代理、HTTP/2、Google 端或其交互作用；HTTP/1.1 代理組等待時間較短，不能據此認定 HTTP/2 是根因。略過 HTTP 代理也不等於排除底層 VPN。

官方定義 `-1005` 為請求進行中的連線遺失；Google 429 可能涉及可用容量或流量限制，不能一律解讀為日額度耗盡。[Apple 錯誤說明](https://developer.apple.com/library/archive/qa/qa1941/_index.html)、[Google 429 說明](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/deploy/error-code-429)。

## 3 修改範圍

第一版只變更 Vertex **音訊轉錄的回應傳輸與解析**，包含 inline 音訊與既有 GCS 引用兩條路徑。Vertex 選配文字摘要維持原路徑，透過明確的回應模式參數區分；Google AI Studio 與本機 Qwen 的請求方式不變。

保留目前的模型選擇、thinking level、提示詞、安全設定、20 分鐘預切、MAX_TOKENS 自適應細分、檢查點與正式 TXT 發布條件。Argon 輸出上限仍為 32,768；已知 Flash 仍為 65,536；未知模型仍用既有保守上限。本次不因串流支援較高上限而擴張輸出預算。

不加入 long decode、continuation token 自動續接、串流文字即時編輯器、跨次續接半段文字、自動建立 GCS bucket、切換代理、強制 HTTP/1.1 或新的模型 fallback。不要在串流失敗後偷偷改回非串流再發送一次。

## 4 請求與傳輸設計

### 4.1 Vertex 音訊轉錄端點

使用 `POST /v1/projects/{project}/locations/{location}/publishers/google/models/{model}:streamGenerateContent?alt=sse`。沿用現有 global／區域 host、OAuth bearer、JSON body 與 request file 上傳方式，並要求 `Accept: text/event-stream`。音訊仍以既有 inlineData 或 fileData 傳送。

Google 的串流 API 接受多模態輸入，成功回應是一連串 `GenerateContentResponse`。本規格採研究已驗證的 SSE 格式，不加入另一種串流 JSON array 的自動猜測解析。[官方串流 API](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/projects.locations.publishers.models/streamGenerateContent)。

### 4.2 明確傳遞請求階段

目前 `GeminiTransportHelper.budgetedUpload` 與 `CancellableCloudRequest.run` 使用 `contains("generateContent")` 判斷 generation。`streamGenerateContent` 的 `G` 是大寫，直接換端點會漏判，影響上限、診斷及發送計數。

改為由呼叫端傳入明確的 `CloudDiagnosticStage` 與回應模式，例如 `.generation`／`.geminiSSE`。傳輸、逾時計算、attempt claim、診斷紀錄都使用同一個階段值。一般 upload、poll 與非串流 generation 必須維持正確分類。測試中的路由判斷也要依各後端實際端點更新，不能讓 mock 靜默避開 generation 分支。

### 4.3 內部串流聚合與外部完整結果

沿用既有單次請求擁有者與取消生命週期，新增接收資料片段的 delegate 分支；每個 HTTP attempt 擁有獨立 parser、buffer 與聚合結果。重試時全部重建，不能沿用失敗 attempt 的半段文字。

資料流程為：HTTP 狀態判斷 → SSE framing → JSON event → candidate 聚合 → 正常傳輸完成 → 既有完整性 parser → `CloudTranscriptionResult`。上層 engine 不需要理解 SSE，也不能在第一個文字片段或 HTTP 200 出現時把該段標成完成。

SSE 分支須在收到 bytes 時處理資料，避免將整條原始事件串流無限制保留到 completion。若以 session 或 task delegate 實作，必須用真實 URLSession fixture 驗證資料 callback、注入的 URLProtocol、取消與 metrics 都會觸發；不能只靠直接呼叫 parser 的單元測試。

每次取消、正常完成或錯誤只能完成 continuation 一次；晚到 callback 不得再次保存或恢復已取消工作。保持既有 session ownership 與 reset 政策，不為每個 SSE event 建立 session，也不取消同 session 的其他請求。

## 5 SSE 與回應聚合契約

### 5.1 事件邊界與資源限制

- 依 bytes 保留未完成片段，正確處理跨 callback 的 UTF-8 中文、CRLF、LF、CR 與起始 BOM；不能對每個任意 Data 塊直接做有損字串轉換。
- 空行才結束事件；同一事件內多個 `data:` 欄位以換行接合。支援冒號後沒有空格或只有一個可移除空格；忽略註解行及無關 SSE 欄位。
- `id`、`retry` 不啟動 EventSource 式自動重連，不送 `Last-Event-ID` 續接模型輸出；重送仍由 App 的有限重試政策管理。
- EOF 時尚未以空行結束的資料不能被當成完整事件。若有殘留非空事件，即使前面已見 STOP，也判為回應不完整；單純結尾空白或完整註解可忽略。
- 空的 data 事件可忽略；若遇到 `[DONE]`，只視為傳輸標記，不能取代 Google candidate 的 STOP。非空且非 JSON 的資料須報協定錯誤。
- 第一版採明確產品保護上限：單一未完成事件 4 MiB、整個 HTTP 回應累計 32 MiB、可發布文字 4 MiB，均以 bytes 計。超限立刻終止本次 task，回報資源上限錯誤，不重試、不輸出半稿。測試可注入較小上限。這些是 App 限制，不是 Google 官方配額。

事件邊界依 [WHATWG SSE 規則](https://html.spec.whatwg.org/multipage/server-sent-events.html)；JSON 大小限制與不完整事件拒收屬本 App 的完整性要求。

### 5.2 Candidate 與文字

只聚合第一個候選答案，即 candidate index 0；單一候選且省略 index 時視為 0。其他 candidate 不得混入，完全沒有選定候選則依既有空回應／封鎖規則處理。

依收到順序附加選定候選的文字 delta；不得對每塊單獨 trim、清空白、去重或做 Markdown 清理。`thought: true` 的 parts 與 thought signature 不進逐字稿、日誌或持久化。最終合併後才呼叫既有 `GeminiResponseParser` 做文字清理與 finish reason 驗證。

中途缺少 content、只有 usage 或 thought 的事件均可能合法；不能逐事件套用現有「必須有完整逐字稿」判斷。遇到明確 prompt block 或候選封鎖，即使前面已有文字，也不得發布先前內容。

### 5.3 完成與失敗條件

| 回應條件 | 行為 |
| --- | --- |
| HTTP 成功、SSE 完整、選定候選 STOP、有可用文字、task 正常結束 | 聚合後交既有 parser，通過才標示片段完成 |
| 已收到 STOP，但 task 隨後報連線錯誤、取消或逾時 | 本 attempt 失敗，不發布文字 |
| STOP 後還有 usage／metadata | 繼續收取至正常結束；保留最終用量 |
| STOP 後出現新的非空文字、互相矛盾的終止原因或錯誤事件 | 拒收為不一致／失敗回應；不能忽略尾端異常 |
| 正常 EOF，但沒有 STOP 或其他明確終止原因 | 視為不完整串流，走同模型有限網路恢復；不能當作空內容成功 |
| STOP，但聚合後沒有可用文字 | 沿用 Vertex 的有限空完成回應重試 |
| MAX_TOKENS | 轉為既有 `CloudOutputTruncatedError`，交 engine 自適應細分；本段截斷文字不作完成稿 |
| SAFETY／RECITATION／PROHIBITED_CONTENT 等封鎖 | 沿用既有拒收與使用者錯誤，不以換模型或重送繞過 |
| CONTINUATION、OTHER、未知終止原因 | 明確失敗；本版不追加 long decode 請求 |
| 畸形 JSON、無效 UTF-8、非預期內容型別、資源上限超出 | 協定／解析錯誤，不當作暫時網路問題無差別重試 |

HTTP 200 本身不是成功條件。串流中的空 finish reason 表示尚未終止；最終仍維持本專案僅允許 STOP 發布的政策。[官方回應與 FinishReason 定義](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/GenerateContentResponse)。

### 5.4 Metadata 與 token

`modelVersion`、`responseId`、服務類型取有效事件中的最新已提供值，不因後續事件缺欄位而清掉。保留選定候選的 finish reason、finish message 及 parser 必要的安全資訊，不能在轉換成既有回應格式時遺漏。

用量使用最後提供的請求累計值；同一個欄位後續未提供時保留前值。**不得把每個 event 的 prompt、candidate、thought 或 total token 相加。** 缺少用量仍可完成合法逐字稿，但該欄位保持未知，不能填 0 或依字數猜測。失敗 attempt 若沒有完整用量，不顯示為零費用，也不與成功 attempt 的輸出混合。

本版不改費率估算；Argon 繼續只記錄實際 token，不套用 Flash 費率。

## 6 錯誤恢復與時限

### 6.1 HTTP 與串流內錯誤

非 2xx 回應先走原 HTTP error JSON 處理，不因端點是 SSE 就要求錯誤本文也必須是 SSE。保留 HTTP status、Retry-After 與 Google error details，401 更新憑證、403／404／400 與 429 的既有語義不變。

若 HTTP 200 的 SSE 事件含 Google `error`，也要當作失敗。將已知 `error.status` 與有效 HTTP error code 正規化到既有錯誤模型；`RESOURCE_EXHAUSTED` 進服務冷卻，`UNAVAILABLE` 等已知暫時服務失敗進既有服務重試。未知或畸形 error 回報協定錯誤，不猜成 429。RetryInfo 與 HTTP Retry-After 取合法且較晚的等待下限。

收到 `-1005` 等暫時網路錯誤，或無終止原因的 EOF，捨棄本 attempt 的文字，標記生成結果未知，沿用網路恢復及同模型重試。解析錯誤、封鎖、取消不自動換模型。僅保留使用者原本允許、且符合既有條件的 Flash 服務錯誤 fallback。

### 6.2 次數與等待

一筆 HTTP generation POST 才算一次發送；event 數量不增加計數。每片段／模型的四次實際發送額度，由原 quota 控制；401、POSIX reset、斷線、空 STOP 與服務重試共用，不能因新增串流層重設。

沿用 build 13 網路重試等待 20 秒與「立刻重試」規則。串流正在接收時不能再次發送；使用者連按也不能建立第二筆 task。429 沿用 30／60／120 秒及 jitter 的服務冷卻，遵守較晚的伺服器下限；一般 `Resource exhausted` 不當作已確認日額度耗盡。

### 6.3 時限與取消

| 模型 | 單次生成最長時間 | 原始音訊段共用期限 |
| --- | --- | --- |
| Gemini 4 Argon | 1,200 秒 | 1,800 秒 |
| 既有 Flash 與其他模型 | 300 秒 | 900 秒 |

單次生成包括傳送請求、等待第一批資料與接收回應；原始段共用期限包含準備、等待、重試及自適應子段。以外部注入的較短期限為準。

接收 event、註解或 heartbeat 不得重設絕對期限，也不得把 HTTP 200／第一個 chunk 當作 generation 完成。不要新增任意 60 秒靜默斷線計時器；串流首個 event 仍可能等待，沿用既有單次與根期限。

取消須停止實際 URLSessionTask，釋放串流 buffer，停止等待並清理 request file。既有已完成片段不受影響；GCS 物件沿用成功、失敗及取消後的清理責任。清理錯誤不覆蓋原始取消／轉錄錯誤。

## 7 檢查點與使用者狀態

未完成的串流文字僅存在當次記憶體，不寫成完成片段、正式 TXT 或可續接的 checkpoint。重啟／續跑只沿用已完成且驗證有效的片段；目前失敗片段從其音訊重新發送，不能宣稱接續 Google 上次生成或只重新下載結果。

本版不顯示即時逐字稿。維持既有片段進度與取消操作；收到資料後可在節流日誌顯示「正在接收 Google 回應」，不依 event 數或 bytes 推算百分比。全部片段完成、正式稿與 journal 落盤後，才沿用原本完成通知及睡眠倒數。

## 8 診斷與隱私

每次 attempt 記錄模型、stage、回應模式、實際發送序號、HTTP status、錯誤分類與 finish reason；增加上傳完成、第一批回應 bytes、第一個文字 delta、結束時間及接收 bytes／事件數。上傳完成時間代表本機 transport 觀測，不宣稱 Google 已完整處理音訊。

可取得時記錄 URLSession metrics 的實際協定與是否代理；無法取得就保持未知。generation 總時間維持包含網路傳輸，不與新增子時間重複加總。診斷欄位如持久化須採 optional/default 解碼，保持舊工作紀錄可讀。

不記錄 OAuth token、完整 request URL、project ID、GCS URI、原始 SSE、逐字稿、音訊 Base64 或 thought 內容。使用原有去識別化錯誤紀錄方式，限制事件數與字串大小；不得為除錯開啟全量 CFNetwork body 日誌。

## 9 預計修改位置

| 位置 | 責任 |
| --- | --- |
| `VertexAIGeminiBackend.swift` | 音訊端點切 SSE、回應模式與 stage 注入、錯誤及最終聚合整合；摘要維持原模式 |
| `GeminiTransportHelper.swift` | 明確 stage、串流路徑接入原 budget／quota／重試；HTTP 與串流錯誤一致分類 |
| `CancellableCloudRequest.swift` | 逐塊接收、單一完成者、取消、delegate／session 生命週期 |
| 新增 `GeminiSSEParser.swift` 與 `GeminiStreamingResponseAccumulator.swift` | 事件 framing、限制、candidate delta／metadata／終止狀態聚合；名稱可按實作調整 |
| `GeminiResponseParser.swift`、`GeminiResponseMetadataParser.swift` | 重用既有完整性／清理／metadata 語義；必要時加入內部結構入口，避免重複安全判斷 |
| `CloudJobDiagnostics.swift` 與必要的 failure 分類 | 可選的串流量測欄位、不完整串流診斷、舊資料相容 |
| `Tests/RecordToTextCoreTests` | 新增串流測試，更新 Vertex 路由 fixture，保留 AI Studio 非串流案例 |

不在 parser 或 delegate 新增獨立重試迴圈。transport 暫時網路重試仍由 helper 管理；服務與模型重試仍由 `GeminiGenerationRetry` 管理。

## 10 自動化驗收

| 編號 | 情境 | 必須成立 |
| --- | --- | --- |
| S01 | 同一 SSE 分別逐 byte、任意切塊、全部一次送入 | UTF-8 中文與空白完整，聚合結果一致；LF／CRLF／CR、BOM、多 data 行及註解正確 |
| S02 | 文字＋thought＋metadata-only＋最終 STOP | 只輸出公開文字；以最終累計 usage 記一次；STOP-only 尾事件與其後 usage 不丟失 |
| S03 | 兩個 candidate、重複文字 delta、缺 index | 不串接其他候選、不擅自去重；單候選缺 index 可處理 |
| S04 | 半段後 -1005，或正常 EOF 沒有終止原因 | 同模型有限重試；前次文字丟棄；重試成功稿只出現一次；耗盡後保留已完成片段 |
| S05 | STOP 後斷線、未結束 SSE event、畸形 JSON／UTF-8、錯誤或矛盾尾事件 | 不發布已收文字；依 transport／protocol 類型處理，無無限重試 |
| S06 | MAX_TOKENS、CONTINUATION、SAFETY、OTHER、未知原因 | MAX_TOKENS 僅進既有細分；其餘按契約拒收；沒有隱性續接或換模型 |
| S07 | 空 STOP；只有 heartbeat／thought | 空 STOP 最多用原額度重試；heartbeat 不完成、不延長期限；達根期限會停 |
| S08 | HTTP 401→刷新→斷線→重試；POSIX reset 混合失敗 | 所有實際 POST 共用四次上限，401 後網路錯誤不誤報憑證失敗 |
| S09 | HTTP 429 JSON 與 HTTP 200 SSE error RESOURCE_EXHAUSTED | 兩者進同一冷卻，保留 Retry-After／RetryInfo；日額度只在明確訊號時成立 |
| S10 | 未開始、等首包、收流中、冷卻中取消；取消與完成競爭 | task 確實停止、continuation 一次、晚到資料不落盤，無額外發送 |
| S11 | 單事件、總回應、文字超限 | 立即終止，buffer 有界，不發布、不無限重試 |
| S12 | 串流 endpoint、非串流摘要、GCS upload、AI Studio generation | stage 各自正確，Argon 仍用 1,200 秒生成上限；event 不灌大 request count |
| S13 | GCS 上傳後生成重試、取消與 URI 遺失 | 有效物件可重用，沿用既有重建與清理規則；inline 仍以 request file 上傳 |
| S14 | 第一段成功、第二段串流失敗，再重啟續跑 | 第一段不重送，第二段無半稿拼接；未全完成不發布完整稿、不觸發完成睡眠 |
| S15 | 舊 journal／recent history／checkpoint 缺新欄位 | 可讀且可續作；既有工作設定不被當前 UI 選項取代 |
| S16 | 真實本機 HTTP server 以數次延遲送出 SSE，持續超過 60 秒 | 正式 transport 在 EOF 前確實收到 callbacks，沒有自設 60 秒截斷；取消與截止可終止連線 |

S01–S15 以可控制時鐘及 HTTP fixture 驗證；S16 使用本機 loopback server，不呼叫付費 API。另回歸 Vertex、cloud adaptive、network／service recovery、upload、App persistence／publication 既有測試。mock 要能分次 `didLoad`、在半段故障、延遲完成，不能只把所有 SSE 一次塞回成功回應。

## 11 真實驗收與後續 build 門檻

實作後以正式 `VertexAIGeminiBackend` 與實際 engine 跑驗收，不能用研究探針成功代替正式管線驗證。驗收使用公開或合成語音及隔離的輸出／工作資料目錄。

1. 兩模型各跑短音訊一次，確認 endpoint、high thinking、實際輸出上限、stage、用量及清理。
2. 兩模型各跑 20 分鐘合成語音兩次，順序執行、記錄全部 attempt。第一輪預設最多 6 筆初始請求、合計最多 8 次實際 generation 發送；遇 429 按冷卻政策處理，若仍無法完成就如實記錄並停止本輪，不用大量重送換成功樣本。自動 retry 也計入上限。
3. 至少一個成功長請求應跨過 60 秒，確認回應資料在正式完成之前到達。若當天全部較快，這項真實長等待驗證列為未涵蓋，不能用延長本機播放時間冒充；S16 仍須通過。
4. 檢查合成錄音的開頭、結尾及已知 section 標記，確認非空、沒有明顯末段遺失、重送拼接或 thought 外洩。這是完整性抽查，不報 WER／準確率。
5. 兩模型需各有至少兩次 20 分鐘正式管線成功紀錄，且失敗行為符合 S04–S14，才可標示長音訊驗收完成。未達標時交付狀態必須保留未完成原因。

後續實作交付須通過 `SKIP_APP_BUNDLE=1 scripts/run-checks.sh`；完整 XCTest 不可因缺 Xcode 被當作已通過。完成後才按該次任務授權執行 release build、版本遞增與產物驗證。Apple Silicon 開發包沿用 `CONFIGURATION=release UNIVERSAL=0 ADHOC_SIGN=1 scripts/build-app.sh`；ad-hoc 包不宣稱已公證。

本次使用者已將工作限縮為規格書，以上實作、付費驗收及 build 都是後續工作，不在這次文件交付中執行。

## 12 完成定義與接續順序

接續順序為明確 stage → SSE framing／聚合 → transport 取消與錯誤整合 → 正式 backend 與 checkpoint 回歸 → 受控長音訊驗收 → 依當次授權 build。

完成定義：S01–S16 與既有回歸通過；兩個模型的正式長音訊驗收達標；診斷能辨認網路、容量、封鎖與解析錯誤；無半稿發布、無額度重設、無憑證或逐字稿外洩。交付紀錄須清楚區分「程式已實作」「真實驗收通過」「已 build」「已安裝」。

相關基準：[build 13 功能檢視](functional-review-2026-10-17.md)、[Argon 支援](gemini-4-argon-support-2026-10-15.md)、[網路恢復規格](network-recovery-spec-2026-09-19.md)、[服務冷卻規格](cloud-cooldown-manual-resend-sleep-spec-2026-09-21.md)。
