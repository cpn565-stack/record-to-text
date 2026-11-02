# Vertex 安全攔截調查

日期：2026-10-24。範圍：七份使用者回報的長錄音工作、已安裝 build 16、build 15／16 原始碼差異及離線回歸測試。本紀錄依回報順序以 A–G 代稱錄音，不保存私人檔名、路徑、背景原文或逐字稿。

## 結論與判斷界線

前兩份錄音 A／B 的主要缺口都是 Vertex 回傳 `promptFeedback.blockReason=SAFETY`，並非 App 自行判定錄音有問題。後四份 C–F 的所有片段皆完成，持久化完整性為 `complete`，正式輸出沒有安全缺口標記。第七份 G 的第 2 段空回應重試成功，第 3 段另遭 `SAFETY` 攔截，最終有缺口。七份實際要求及回報的模型均為 `gemini-3.8-flash`；不能拿先前 AI Studio／Gemini 4 Argon 的成功案例直接當成同條件對照。

沒有發現 build 16 收緊安全設定、錯誤轉換破壞 `SAFETY` 分類或串流解析的回歸證據。但兩份工作都使用同一份 83 Unicode scalars 的非空錄音背景，因此尚不能排除背景和音訊／講者參考的組合影響 Google 判斷。未進行相同音訊的有／無背景真實對照，不宣稱已排除此因素。

Google 未附 `safetyRatings` 分類；現有資料不足以確認觸發類別、哪句錄音造成攔截，或是否為服務誤判。`SAFETY` 也不能直接改稱某種不可調整的特定政策類型。

C 的新診斷另確認一個 App 等待策略問題：Flash SSE 已在產出正式文字，仍被既有的 300 秒單次請求期限取消，之後自動重送成功。這不是 Google 安全攔截，也不能把這筆 `network` 重試分類解讀為網路斷線。期限在 build 15 已存在，沒有證據是 build 16 新增背景造成的程式回歸。

## 已核對事實

| 項目 | 錄音 A | 錄音 B |
| --- | --- | --- |
| 音訊長度 | 3144.58 秒 | 2741.68 秒 |
| 第 2 段缺口，採 manifest 精確秒數 | 1199.7796045–2395.524604 | 1196.118031–2394.8025105 |
| Google 回應 | HTTP 200，`promptFeedback.blockReason=SAFETY` | HTTP 200，`promptFeedback.blockReason=SAFETY` |
| 被擋請求耗時 | 約 18.82 秒 | 約 219.41 秒 |
| 第 1、3 段 | 完成，保留文字檔仍存在 | 完成，保留文字檔仍存在 |
| 持久化完整性 | `hasGaps`，正式 TXT 有一個安全缺口標記 | `hasGaps`，正式 TXT 有一個安全缺口標記 |

兩份 recovery manifest 皆為 `completed / blockedBySafety / completed`，已完成片段各有一次完成事件。原始錄音與正式輸出未修改。

後續成功案例的對照如下：

| 項目 | 錄音 C | 錄音 D |
| --- | --- | --- |
| 音訊長度 | 2648.02 秒 | 2896.30 秒 |
| 完成片段 | 3／3，皆有最終 `STOP` | 3／3，皆有最終 `STOP` |
| 初次第 1 段 | 300.60 秒到達 App 請求期限，重送 | 159.20 秒完成 |
| 重送第 1 段 | 252.28 秒完成 | 無重送 |
| 第 2／3 段 | 106.48／115.21 秒完成 | 126.94／96.76 秒完成 |
| 安全攔截 | 無 | 無 |
| 最終完整性 | `complete`，正式輸出存在 | `complete`，正式輸出存在 |

前四份共 12 個音訊片段，10 個完成、2 個安全攔截；共 14 次生成發送，包含 A／C 各一次逾時重送。C／D 的第 2 段成功，與「App 固定在第 2 段出錯」不符。這是本批次的結果，不是模型整體失敗率。

A／B 的 snapshot 可核對相同背景、詞庫、canonical prompt、`thinking=high`、backend 及模型。C／D 完整成功後只在目前 journal／recent history 保有摘要，未保有 snapshot，不能從這些紀錄確認其背景是否與 A／B 相同；待使用者確認，不因同批或模型相同就推定相同。

第三次回報的錄音 E／F 也已核對本機 recent history 與正式輸出：

| 項目 | 錄音 E | 錄音 F |
| --- | --- | --- |
| 音訊長度 | 2072.34 秒 | 2487.10 秒 |
| 完成片段 | 2／2，皆 `STOP` | 3／3，皆 `STOP` |
| 生成發送 | 2 次 | 4 次 |
| 失敗事件 | 無 | 第 1 段第一次為 HTTP 429 |
| 處理 | 112.15／145.82 秒，各一次成功 | 429 後冷卻 35.87 秒，重送成功 |
| 最終完整性 | `complete`，無安全缺口標記 | `complete`，無安全缺口標記 |

F 第 1 段第一次請求在 164.89 秒收到 HTTP 429，沒有 SSE 事件；重送在 97.36 秒以 `STOP` 結束。該段約 299.34 秒雲端耗時包含兩次請求、冷卻與驗證，並非單次請求碰到 300 秒期限。重試模型保持不變，後續兩段各一次成功。

HTTP 429 代表服務容量／限流或配額相關拒絕；官方說明 pay-as-you-go 也可能因共享容量暫時不足而回傳此碼，並建議退避重試。[Google 429 說明](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/deploy/error-code-429)。F 在短暫冷卻後成功，較符合暫時性限流或容量問題；缺少完整錯誤訊息與專案配額資料，不能指定是哪一種配額或確認特定容量瓶頸，也不據此判斷餘額不足。App 本次冷卻與重試機制成功處理此錯誤。

前六份累計：4 份完整、2 份有安全缺口；17 個音訊片段中 15 個完成、2 個安全攔截；20 次生成發送包含 2 次逾時重送與 1 次 429 重送。應分別處理 Google 安全攔截、App 既有 300 秒期限與 Google 429，不能統稱同一種新版 App 錯誤。C–F 的成功摘要未保存背景，尚不能證實六份背景一致。本次新增比較只讀取診斷與檢查輸出缺口標記，沒有修改音訊或發送 Google API 請求。

第四次回報的錄音 G 長 2711.32 秒，本機紀錄為 `hasGaps`，正式輸出有一個安全缺口標記。manifest 與保留文字檔確認第 1、2 段完成，第 3 段為 `blockedBySafety`：

| 片段 | 結果 | 診斷 |
| --- | --- | --- |
| 第 1 段 | 完成 | 一次請求，88.35 秒，`STOP` |
| 第 2 段第一次 | 沒有可用正文 | 163.09 秒，HTTP 200、`STOP`；41,757 bytes／19 個 SSE 事件，但沒有 `firstTextDeltaSeconds` |
| 第 2 段重送 | 完成 | 等待約 1.53 秒後同模型重送，105.95 秒，`STOP` |
| 第 3 段 | 安全攔截 | 36.58 秒，`promptFeedback.blockReason=SAFETY`；缺口為 2386.559969–2711.32 秒，約 5 分 25 秒 |

G 第 2 段第一次的正規化回應顯示 `parts=1[text,textChars=0]`、`thoughtsTokenCount=4816`，沒有安全攔截或 `MAX_TOKENS`。SSE bytes 包含事件封裝、thought 及 metadata，不能以收到約 41 KB 就推定有正式逐字稿。現有紀錄較符合思考後未產出可用正文的空 `STOP` 回應，重試機制已恢復該片段；原始 SSE 未保留，不能只靠事後測試宣稱已完全排除所有未覆蓋的回應格式問題。

針對空 `STOP`、thought／正文分流、後續空事件不清掉已累積文字、多候選及省略 index 的既有 4 項離線測試重跑通過，0 跳過、0 失敗。沒有發現一般串流累積會清掉正文的回歸證據，沒有修改 parser 或發送 Google API 請求。G 的兩次第 2 段請求各在 300 秒內結束，故這次空回應與前述硬性期限不同。

G 的「Google safety-blocked segments: 3」中的 `3` 是被攔截的片段編號，不是三段全部被擋。可使用既有「重送未完成片段」驗證並沿用第 1、2 段，只重送第 3 段，仍沿用原 snapshot 的背景與模型。

七份累計：4 份完整、3 份有安全缺口；20 個音訊片段中 17 個完成、3 個安全攔截；24 次生成發送包含 2 次逾時重送、1 次 429 重送及 1 次空回應重送。新增的 `STOP` 空回應屬於第四種診斷情況，不能併入安全攔截或網路斷線。

## 相同設定手動重送後仍攔截

使用者後續重送 B／G。已從本機 ledger 核對 parent／child 關係，兩個 child 的整份 snapshot 都與原工作相同，包含 83 scalars 背景、模型及 thinking。完成片段的診斷標示 `reusedFromCheckpoint=true`，保留文字檔仍存在，沒有重新發送這些完成片段。

| 項目 | G 重送 | B 重送 |
| --- | --- | --- |
| 實際重做片段 | 第 3 段 | 第 2 段 |
| 沿用片段 | 第 1、2 段 | 第 1、3 段 |
| 本次第 1 次發送 | 6.67 秒，`NSURLErrorDomain -1005`，0 回應 bytes，協定紀錄 `h3` | 7.03 秒，`NSURLErrorDomain -1005`，0 回應 bytes，協定紀錄 `h3` |
| 本次等待 | 20.98 秒，重建 session | 20.02 秒，重建 session |
| 本次第 2 次發送 | 17.99 秒，HTTP 200、`promptFeedback.blockReason=SAFETY`，`h2` | 42.11 秒，HTTP 200、`promptFeedback.blockReason=SAFETY`，`h2` |
| 最終完整性 | `hasGaps`，第 3 段仍缺 | `hasGaps`，第 2 段仍缺 |

新的時間與 response ID 證明這次確實重新發送後，再次收到 Google 攔截，不是只顯示前次快取的錯誤。此輪都沒有達到 300 秒期限；調整該期限不會直接解決這兩個重現的 `SAFETY`。

`-1005` 代表進行中的載入連線中斷。[Apple 說明](https://developer.apple.com/documentation/foundation/urlerror/code/networkconnectionlost)。兩個失敗都記錄在 HTTP/3，session 重建後的回應則為 HTTP/2；這是可供後續網路調查的共同特徵，只有兩筆紀錄仍不足以確認 HTTP/3、作業系統、網路設備或 Google 哪一方是根因。重試已恢復到可接收服務回應，最終缺口由其後的安全攔截造成。

重送診斷的歷史計數是累計值：G 的 4 筆失敗事件包含原本 2 筆與本次 2 筆，6 次發送包含原本 4 次與本次 2 次；B 的 3 筆失敗事件包含原本 1 筆與本次 2 筆，5 次發送包含原本 3 次與本次 2 次。G 列出的舊第 2 段空回應沒有在本輪重新發生。用量／重試標頭取自成功片段 metadata，仍含沿用片段，因此 `85005／64492 tokens` 與費用不是本輪新增用量；本輪失敗請求未取得完整 usage，不能由此判斷實際帳單。

兩個相同片段在相同設定下再次被擋，繼續同條件重送並不是有效的原因隔離方式。已在本機準備兩份僅含缺口的單聲道 16 kHz PCM WAV，可供本機 Qwen 或使用者選定的其他服務單獨補轉：

- G：原錄音 2386.559969–2711.32 秒，輸出 5,196,160 samples，約 324.76 秒。
- B：原錄音 1196.118031–2394.8025105 秒，輸出 19,178,952 samples，約 1198.6845 秒。

位置為 `~/Library/Application Support/record-to-text/Repair-Exports/blocked-segments-20261024-xcg8i7pz/`，附本機 `repair-manifest.json` 與補轉說明。兩個來源檔案在匯出前後 SHA-256 相同，音檔 sample 數與目標範圍差異不超過一個 sample；未覆寫原始錄音、TXT 或檢查點。新 WAV 的時間從零起算，合併回原稿時需依 manifest 加回原錄音時間偏移。本輪只做本機擷取，尚未執行辨識、合併或上傳。

安裝中的 `/Applications/record-to-text.app` 為 0.2.1（16），執行檔 SHA-256 與 `dist/record-to-text.app` 相同：`cf2b10c86ba440f3598a84ad14af0339fbd71f6e2e0e897b12cf8a2ce7768457`。

比較 build 15（`9081990`）與 build 16（`7bd8021`）：

- Vertex 請求的五個既有 `safetySettings` 仍為 `BLOCK_NONE`，本次背景功能沒有調高門檻。
- `GeminiPromptFeedbackParser`、SSE accumulator 及 Flash 的單次請求 300 秒／原始段 900 秒預算未變。
- `GeminiResponseParser` 在檢查背景回吐之前，就依 Google 的 `promptFeedback` 產生 typed error；新增背景檢查不會自行製造 `SAFETY`。
- 背景的錯誤遮蔽保留協定用的 `SAFETY` 值，既有回歸測試涵蓋此分類。

官方將 `promptFeedback` 定義為輸入的內容過濾回饋；`SAFETY` 是安全原因攔截。HTTP 200 代表 HTTP 請求有回應，不能單憑它認定產出了可用逐字稿。[GenerateContentResponse](https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/GenerateContentResponse)。

`BLOCK_NONE` 是可設定內容過濾器的選項，不能據此保證服務永不回傳攔截。官方文件亦區分可設定與不可設定的過濾；本次沒有足夠分類資料判定屬於哪一細項。[安全與內容過濾說明](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/capabilities/configure-safety-filters)。

## AI Studio 對照：一份完整，一份仍失敗

錄音 B 改由 AI Studio Files API／unary JSON、同名 `gemini-3.8-flash` 與 high thinking 處理後，三段皆一次完成，沒有失敗或重試，總耗時 5 分 40 秒。原本 Vertex 反覆攔截的第 2 段在 AI Studio 用 126.63 秒成功；兩邊該段起訖與 MP3 bytes 相同。這證明該時間範圍並非在所有 Google 請求中都無法轉錄，但單次成功不足以指定 Vertex 的某個安全設定、傳輸或模型部署為根因。第 1 段的 `segmentRangeOnly` 是段內時間待核對、保留全文並改標實際音訊範圍，與安全缺口不同。

錄音 G 隨後由 AI Studio 處理，前兩段一次成功，第 3 段仍失敗：

| 片段 | AI Studio 結果 | 生成耗時 |
| --- | --- | --- |
| 第 1 段 | 完成，44,973 tokens／9,668 thinking tokens | 92.61 秒 |
| 第 2 段 | 完成，45,609 tokens／9,535 thinking tokens | 100.75 秒 |
| 第 3 段 | HTTP 200，`promptFeedback.blockReason=OTHER`，沒有可用逐字稿 | 165.72 秒 |

本機 manifest 為 `completed`／`completed`／`failed`，前兩段的文字檔存在，工作保留可復原失敗；尚缺 2386.559969–2711.32 秒，約 5 分 25 秒。這次不是 300 秒逾時、429 或正文為空的 `STOP`，而是服務端明確回傳 prompt block。Google Gemini API 將 `OTHER` 定義為未知原因的 prompt 攔截；沒有 safety ratings 或更具體訊息，不能自行改稱明確安全政策攔截或推定觸發內容。[Gemini API BlockReason](https://ai.google.dev/api/generate-content?hl=en)。

App 只有明確安全政策代碼才會將該段列為 `blockedBySafety`、繼續並發布含缺口的成稿；`OTHER` 走一般失敗，保留完成片段與復原資料。因此這份顯示「失敗」，先前 Vertex `SAFETY` 工作則顯示完成但有缺口，符合既有分類規則。頂層 `category=contentBlocked`／「Google 未允許處理本片段」較概括，具體原因仍須查看日誌的 `blockReason=OTHER`。既有 `testPromptFeedbackOtherIsNotFakeHTTP400AndCapturesDiagnostics` 與 `testPipelineContinuesOnlyForExplicitGoogleSafetyBlocks` 涵蓋此區別。

另已唯讀比較 G 的兩份本機 snapshot：AI Studio 與 Vertex 的 `prompt`、`terms`、`cloudRecordingContext` 都不同，背景分別為 77 與 83 scalars；thinking 同為 high。因此這不是只替換 backend 的受控對照，不能由結果隔離背景、詞庫、提示或服務差異。最新證據修正了「主要只在 Vertex」的推測：B 在 AI Studio 成功，G 同一缺段在兩個服務都曾被擋，但代碼與輸入設定不同，仍無法歸因於新版 App、特定背景或音訊中的某句內容。

此輪只核對本機狀態、程式與既有離線測試；上述兩項測試重跑通過，0 跳過、0 失敗，`git diff --check` 通過。沒有新發送轉錄請求，也沒有更動 `OTHER` 的失敗規則。先前準備的 G 缺段 WAV 可供後續補轉，不需重新處理前兩段。

## 獨立的 300 秒逾時

錄音 A 的第 1 段第一次請求，在 Flash 既有的 300 秒單次請求期限內未收到回應位元組；診斷為 `requestDeadlineExceeded`、`bytes=0`、`sseEvents=0`，結果未知。App 等待約 20 秒後重送成功，第 1 段最終沒有缺口。它與第 2 段的 Google 安全攔截是兩件事，不是 900 秒整段預算用盡。

`path=satisfied` 只能表示系統網路路徑可用，無法分辨當時 Google 處理延遲、代理或中間網路的狀態。沒有從這筆診斷推定特定網路設備故障。

錄音 C 的第 1 段則有明確的串流進度證據：

- 第 134.37 秒收到第一個回應位元組。
- 第 291.79 秒收到第一個實際逐字稿文字 delta，與 thought 事件分開計數。
- 第 300.60 秒 App 的單次請求期限觸發取消，已收到 63,394 bytes、133 個 SSE 事件。
- 等待約 20.10 秒後，第二次請求以同一模型在 252.28 秒、`STOP` 結束。

這說明 C 在取消前約 9 秒仍有正式文字開始輸出；取消由 App 的絕對操作期限造成，無需假設當時已斷網。第 1 段顯示的 API 約 573 秒，是兩次生成加上等待的整體耗時，不是一次請求連續跑了 573 秒。

相關程式為 `GeminiGenerationConfig.requestTimeout`（Flash 300 秒）、`GeminiTransportHelper.budgetedData`（將該值作為 `maximumDuration`），以及 `CloudSegmentBudget.withDeadline`（獨立計時器到期即取消，SSE 活動不會刷新它）。此期限在 900 秒原始段總預算之前生效。

若要修正等待策略，應針對 Vertex SSE 分別設計單次生成期限、無資料期限與 900 秒原始段總預算，讓持續進行的串流不會僅因舊的 300 秒期限而必然被取消；同時保留取消及四次發送上限。不能直接把共用 `requestTimeout` 改大，連帶改變 AI Studio、unary JSON、上傳與輪詢。此輪僅完成診斷，尚未變更等待政策或安裝版本。

## App 診斷文字修正與驗證

工作狀態與介面已有 `hasGaps`，但「複製除錯資訊」只輸出底層 stage 的「完成」。已修正 `MainView.swift` 的工作與最近工作診斷輸出，改用既有完整性標籤，缺口工作現在會寫「狀態：完成（含缺口）」。失敗工作仍顯示「失敗」。此修正僅在原始碼中，本輪未重新打包、安裝或重啟使用者 App。

`swift test --disable-sandbox --scratch-path .build --filter 'JobDebugClipboardTests|OutputCompletenessTests|PromptFeedback|Safety|RawContextEcho|S06_FinishReasons|S02_TextThoughtMetadataOnly|S07_EmptyStop'` 通過 20 項測試，0 跳過、0 失敗。涵蓋安全分類、背景遮蔽、原始回吐、SSE safety／thought 事件及完整性診斷；沒有呼叫 Google API。此小幅診斷文字修正未重跑完整套件；前次完整套件的 568 項結果見 `NEXT_STEPS.md`。

## 後續操作

既有「重送未完成片段」會保留原背景與模型，驗證並沿用第 1、3 段，只重送第 2 段；同樣設定仍有再次被擋的可能。它不會讀取目前輸入框的新背景。

要診斷背景影響，應另取被擋的同一時間範圍，在相同 Vertex 模型、詞庫、thinking、音訊與提示條件下，交錯比較原背景和空背景。需要多於一次結果才能區分偶發差異。如果要比較服務，則固定同一模型再對照 AI Studio。直接用「使用目前設定」重建工作會從頭處理，不能當成僅重做第 2 段的操作。本輪未建立新轉錄工作、上傳錄音或執行付費對照。

目前畫面顯示的總 token 恰為兩個成功片段的加總，未納入被擋請求回報的輸入 token，逾時請求的實際使用量也未知。因此既有費用是成功結果的估算，不能當成本次所有嘗試的帳單總額；沒有據此判斷被擋請求必然收費或免費。
