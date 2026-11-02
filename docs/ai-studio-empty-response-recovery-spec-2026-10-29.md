# AI Studio 空回應復原與雲端診斷補強規格

日期：2026-10-29。狀態：規格已進入實作；驗證與打包狀態見 NEXT_STEPS。基準：已安裝的 0.2.1（16），原始碼 `7bd8021` 加上目前工作樹；既有未提交修改需保留。本規格不表示已打包或安裝修正版。

調查依據：[10/28–29 執行錯誤調查](cloud-run-diagnosis-2026-10-29.md)、[10/24 Vertex 調查](vertex-safety-diagnosis-2026-10-24.md)。不在本文件保存訪談原文、背景原文、個人姓名、API Key 或原始回應。

## 1 必要性與交付決策

**建議做，優先序 P1：排入下一個維護版本；無須停用現有 App 或回退錄音背景功能。**

已確認 AI Studio 收到 `finishReason=STOP` 但沒有逐字稿正文時，直接停止；Vertex 同類回應已有有限次重試。這使可能恢復的暫時空結果變成需要使用者手動操作的失敗，對夜間批次轉錄尤其不利。修正可共用既有 retry、quota、deadline 與 checkpoint，不需要重寫轉錄流程。

本批保留資料有 5 次空回應，至少 1 次的 inventory 明確證實為空 STOP；另 4 次只剩概括診斷，不能保證全部符合本規格的重試條件。曾有空回應的錄音稍後手動執行成功，支持存在可恢復案例，但不能據此估算自動重試成功率或保證解決所有失敗。

| 工作 | 必要性 | 本次決策 |
| --- | --- | --- |
| AI Studio 空 STOP 有上限重試 | P1，高 | 本版核心範圍 |
| unary JSON 的 finishReason、prompt blockReason 與明確錯誤摘要 | P1，高 | 與重試一起交付，才能正確驗收與追查 |
| AI Studio SSE／代理相容性 | P2，中 | 另案；已有斷線線索，尚無受控證據指定根因 |
| 合蓋／喚醒原因提示 | P2，中 | 另案；目前已保留工作、續跑成功，不先改期限計時語意 |
| 來源改名／移動提示及保護 | P2，中 | 另案；先避免轉錄中改名，不能按近似名稱自動認領音檔 |
| Vertex 活躍串流被 300 秒期限中止 | P1，獨立問題 | 10/24 已有證據，另設等待策略規格，不與本版共用 timeout 改動綁定 |

本版預期收益是減少可恢復空結果的人工重送、讓錯誤原因可判讀。重試會增加請求與可能的費用；不宣稱提高逐字稿準確率、不承諾解除 Google 內容攔截。

## 2 本版範圍與固定條件

交付三件事：

1. 為 AI Studio 保留「正常結束但正文為空」的獨立錯誤語意，接入現有有上限重試。
2. 在生成回應驗證前保存必要的結構化回應代碼，使 failure history 與複製診斷保留真正原因。
3. 改善空結果耗盡與 `OTHER`／明確安全代碼的顯示，並納入工作樹已有的「完成（含缺口）」診斷修正。

固定原模型、thinking、system instruction、canonical prompt、詞庫、背景、音訊、時間範圍、講者參考與 safetySettings。保持現有輸出格式、OpenCC、分段／MAX_TOKENS 自適應處理、checkpoint 驗證與本機 Qwen 路徑。

本版不新增設定開關，不引入 SSE，不更改代理設定，不調整 HTTP／segment 期限，不增加跨服務自動切換，不改寫提示來重送攔截，不把一般失敗發布成完整成稿，也不擴大為整套費用帳務改造。

## 3 現況與修改位置

| 模組 | 現況／預期責任 |
| --- | --- |
| `GeminiResponseParser.swift` | 先讀 finishReason 再讀 parts；AI Studio 的 emptyTranscript 一律回一般 emptyResponse。改為保留可重試的空 STOP 語意。 |
| `GoogleAIStudioBackend.swift` | 新增 typed error；沿用已準備音訊與既有生成重試入口。 |
| `GeminiGenerationRetry.swift` | AI Studio 接受與 Vertex 相同的空 STOP 重試條件；額度、退避與取消共用。清除僅寫 Vertex 的共用耗盡文案。 |
| `CloudRecordingContext.swift` | 新錯誤經背景遮蔽後仍保持型別／可重試語意；不能改成一般文字錯誤。 |
| `CloudJobDiagnostics.swift` | 回應代碼寫入該次 attempt、failure event 與除錯輸出；保持舊紀錄可讀。 |
| `CloudFailureDiagnostic.swift` | 保留可用的固定原因代碼與正確摘要，不以任意 provider message 取代安全文案。 |
| `CancellableCloudRequest.swift` | 現在只由 SSE accumulator 設 finishReason。若使用此層承接欄位，需避免把上傳／輪詢 JSON 當生成回應；優先在共用生成 parser 擷取。 |
| `MainView.swift`、工作／最近工作診斷輸出 | 一致呈現缺口與原因，沿用既有互動。 |

開始實作前比對並保留目前髒工作樹，不將其他測試／文件修改自動併入本功能提交。版本號在實作與打包階段依當時實際基準遞增，本文件不預先佔用 build 編號。

## 4 可重試的精確條件

以解析後的協定欄位判斷，禁止從錯誤文字、bytes 大小、thinking tokens 或 `category=emptyResponse` 單獨推論。

必須同時符合：HTTP 200、JSON 可解析、沒有 promptFeedback 攔截、依既有候選選擇規則取得候選、其 finishReason 正規化後為 `STOP`，且現有正文擷取／清理得到空字串，沒有其他輸出驗證錯誤。

| 回應形態 | 處理 |
| --- | --- |
| STOP，但 content／parts 缺少，或 parts 為空 | typed emptyCompletedResponse，允許有限重試 |
| STOP，text 為空／只有空白，或只有 thought parts | 同上；不把 thought 當逐字稿 |
| STOP，有可用正文 | 一次成功，不重試 |
| 沒有 candidates／候選為空 | 保留一般 emptyResponse；不因本版新增重試 |
| 缺少、空白或未知 finishReason | 沿用不完整／未知回應錯誤；不推定 STOP |
| promptFeedback 任意有效 blockReason，包括 OTHER | 立即交回既有攔截規則；不走空結果重試 |
| candidate 的 SAFETY／PROHIBITED_CONTENT／RECITATION 等非 STOP 終止 | 保留原分類，不當作空 STOP |
| MAX_TOKENS | 走既有截斷／細分流程，不當作空 STOP |
| JSON 損壞、正文回吐提示、OutputContract 驗證失敗 | 保留實際錯誤，不以空結果掩蓋或重試 |
| 429、5xx、網路中斷 | 各走既有政策，與空 STOP 共用實際生成額度 |

建議新增 `GoogleAIStudioError.emptyCompletedResponse`，與 Vertex 型別保持對稱；一般 `.emptyResponse` 保留，避免將所有缺結果的情況擴大重試。`CloudFailureDiagnostic.category` 可繼續使用既有 `emptyResponse`，由 `finishReason=STOP` 區分，不必新增持久化 category。

## 5 發送額度、退避與音訊生命週期

### 5.1 共用額度

每個待處理片段／模型的既有 quota **最多 4 次實際生成發送，含首次請求**。同一片段的網路、429／5xx、空 STOP、遠端檔案失效後重建都使用同一 quota。禁止再包一個「空結果重試 4 次」迴圈，造成 4×4 或重設額度。若既有 MAX_TOKENS 流程產生自適應子段，每個子段沿用既有規則取得自己的模型 quota，但全部共用原始段 root budget；不能誤改成整個細分樹只能送 4 次，也不能替子段另開 root 計時。

範例：第 1 次連線中斷 → 第 2 次空 STOP → 第 3 次 429 → 第 4 次成功，合計只能發送 4 次；若第 4 次仍空 STOP，停止，不能發送第 5 次。

退避沿用 `GeminiTransportHelper.RetryPolicy` 的既有指數退避／jitter，不新增固定長等待。429 保留服務冷卻與 Retry-After 政策，網路等待仍由網路復原控制，不因新增空結果重試改變。顯示 N／4 時使用實際 quota／sendSequence，不能使用可能在內層網路重送後落後的外層迴圈編號。

### 5.2 Deadline 與取消

繼續使用原 root budget。Flash 現為 900 秒；Argon 現為 1800 秒；單次生成期限分別沿用 300／1200 秒。重試不重置計時、不延長 root、不使用新的獨立 budget。

安排退避前、等待結束後與建立下一次 request 前都必須遵守取消／額度／剩餘預算；若剩餘時間不足退避，立即走原 deadline 規則，不能先發請求再補查。取消／到期之後晚到的回應不得發布成功或觸發下一次發送。

空 STOP 本身不觸發模型 fallback。既有已啟用的 server／rate-limit fallback 條件維持，不能因新增錯誤型別把它擴大到攔截、空 STOP 或解析失敗。

### 5.3 重用與清理

在 `runTranscriptionAttempts` 內重試，使用同一份 preparedAudio：Files API 沿用同一 file URI，inline 沿用同一音訊 bytes；不重新擷取、壓縮或上傳。原有確認遠端檔案不存在才重建的流程保留，重建不能重設生成 quota。

遠端檔案及暫存 request 仍依原生命週期清理；不能在第 1 次空結果後先刪掉遠端檔案，導致下一次生成引用失效，也不能在最終耗盡時漏掉清理。

## 6 診斷資料與歷史相容性

### 6.1 欄位與取值

| 欄位 | 契約 |
| --- | --- |
| `finishReason: String?` | 沿用既有欄位，補齊 unary JSON 的實際候選終止碼；沒有就 nil，不填入推測值。 |
| `promptBlockReason: String?` | 新增可選欄位，專指 promptFeedback.blockReason，與 candidate finishReason 分開。 |
| `category` | 保留現有分類；OTHER 仍是 contentBlocked，但不是明確安全政策碼。 |
| `httpStatus`、`sendSequence`、`responseMode`、`receivedByteCount` | 沿用傳輸觀測；HTTP 200 與 contentBlocked／emptyResponse 可同時成立。 |
| `generationRequestCount`、`retryCount` | 以實際發送計數為準；不以外層迴圈數取代，模型內 4 次發送成功時 retryCount 為 3。 |

在已解析生成 JSON、尚未拋出驗證錯誤之前，擷取代碼並更新該次 generation attempt。失敗事件被記錄時必須已帶上這些欄位。優先共用 parser 的解析結果，不為補診斷在每個 callback 重複解析大份 JSON。

attempt／failure event 都需保存 `promptBlockReason`，頂層 failure 摘要需能取得同一個經過正規化的原因，可採在 `CloudFailureDiagnostic` 加可選欄位或等價 typed plumbing。不得為了顯示而重新讀舊 logLines 猜原因。

紀錄要對應原來的 model、stage、sendSequence；上傳、輪詢、遠端刪除與晚到的 transport callback 不能覆蓋上一個 generation 的代碼，也不能把前一次 STOP 帶入下一次 OTHER。必要時以既有 attempt 身分或明確索引更新，不能僅假設「最後一個事件永遠是這次生成」。

只保存已知協定代碼；未識別的代碼記固定 `UNKNOWN`，一般缺欄仍為 nil。不可原樣保存任意長字串、finishMessage、blockReasonMessage、正文、thought、提示、背景、音訊 URI 或 headers。清理只影響診斷表示，不得改變 parser 對未知代碼的失敗判定。使用既有合法代碼集合或共用定義，避免每層各有一份不一致清單。

### 6.2 相容與累計語意

新增欄位為 optional，舊 journal／recent jobs／manifest 沒有欄位或欄位為 null 時正常解碼為 nil；不替舊工作捏造 STOP 或 OTHER。既有 schema version 可維持，但必須驗證舊版可忽略新欄位，不破壞降版後讀取及原本未知 enum 的處理。

新欄位通過持久化再載入、checkpoint 續跑與複製除錯資訊後保留。既有事件上限與資料大小界線不變，不存完整 response 來彌補診斷。

同次失敗經 transport、retry、engine 傳遞只計一次；terminal recovery 摘要沿用既有規則，不能被當成另一次生成。已完成片段重用不增加發送數。沿用歷史的事件保持原時間，不改標為本次發生，也不清空過去失敗來假裝此次從未出錯。

## 7 使用者可見行為

不新增操作按鈕；現有自動重試、手動續跑、取消及完成標記繼續使用。

| 情況 | 文案與結果要求 |
| --- | --- |
| 正在重試空 STOP | 「Google 本次沒有產生逐字稿，稍後重試（已發送 N／4 次）。」保留該段進度，不回到整份工作的起點。 |
| 四次發送用盡、最後仍空 STOP | 「本片段已達 4 次發送上限，最後一次仍未取得逐字稿，已保留完成片段。」不能寫成四次都空白，也不能寫成網路斷線。 |
| 在發送上限前先到期限 | 顯示期限到期；不能誤稱已發送 4 次。 |
| OTHER | 「Google 未產生本片段逐字稿，未提供具體原因（OTHER）。」列為失敗，保留復原。 |
| 明確安全代碼 | 說明服務拒絕，沿用安全缺口處理；不推測錄音違規細項。 |
| 完成但含安全缺口 | 工作與最近工作複製診斷均顯示「完成（含缺口）」。 |
| 重試後成功 | 正常輸出，保留本次發送次數與先前錯誤事件；不得將舊失敗繼續當成最終工作失敗。 |

技術細節提供 `mode=unaryJSON`、`finishReason=STOP` 或 `promptBlockReason=OTHER`，同樣出現在該工作與最近工作的除錯資訊。面向一般使用者的主訊息不要求看 JSON 欄位才能理解。

## 8 費用與完整性界線

新增重試可能產生更多處理用量。成功片段 metadata 目前未涵蓋所有失敗／空結果的用量，不能用成功請求的 token 推斷整輪帳單，也不能將空結果標為免費。

本版維持既有成功結果 metadata 格式；若發生重試，在除錯／用量說明附上「費用為估算，失敗或重試請求可能未完整列入」。不新增未經驗證的價格，不把未知用量記為 0，也不把沿用 checkpoint 的 token 全部稱為本次新增費用。完整按 attempt 記帳另案。

空結果耗盡後，保留已完成片段與 recovery。該段維持 failed，後續尚未執行片段不得標為完成；不把空字串寫成成功 checkpoint，不加入假文字補洞，不覆寫原始錄音或現有正式成稿。手動續跑依既有規則驗證並只重做未完成部分。

## 9 驗收測試

優先使用 mock transport、fake clock 與既有 integration fixtures；不得讓普通測試讀取使用者實際設定、錄音、API Key 或發送真實 Google API。必須驗證完整呼叫路徑的請求數與結果，不只測 enum 對映。

| 編號 | 情境 | 必須觀測到的結果 |
| --- | --- | --- |
| T01 | AI Studio HTTP 200 STOP 缺 content／缺 parts／空 parts | 每個子案例第一次回空、第二次有正文；同模型兩次生成，成功；第一筆 failure 有 STOP。 |
| T02 | STOP 空字串、空白、僅 thought | 符合空結果重試；thought 不進入成稿或診斷。 |
| T03 | Files API 空 STOP 後成功 | 只準備／上傳一次，同一 file URI；重試前未刪檔，最終依既有流程清理。另驗證 inline bytes 相同。 |
| T04 | 四次空 STOP | 恰好 4 次生成，沒有第 5 次；無自動 fallback；最後 failed，完成片段可復原。 |
| T05 | 網路失敗 → 空 STOP → 429 → 成功 | 恰好 4 次實際生成，共用 quota，metadata retryCount=3；429 冷卻仍有效。最後改成空 STOP 時不發第 5 次。 |
| T06 | 額度剩 1 次、檔案失效重建、不同模型 quota | 空 STOP 不重設額度；遠端檔案重建保持既有上限；空 STOP 本身不切模型。 |
| T07 | 退避前／退避中／下一次發送前取消或 root 到期 | 結束後沒有新發送、沒有晚到成功；Flash／Argon 的既有預算分別驗證。 |
| T08 | OTHER、SAFETY、PROHIBITED_CONTENT、未知 blockReason | 不執行空結果重試、不 fallback；OTHER 仍一般失敗，明確安全碼仍為缺口，診斷保存正確已知碼或 UNKNOWN。 |
| T09 | 無候選、缺 finishReason、未知 finishReason、壞 JSON、回吐驗證失敗 | 沿用原分類，不新增空結果重試；缺欄不偽填 STOP。 |
| T10 | MAX_TOKENS 與 Vertex 現有空 STOP | 截斷細分與 Vertex 現有重試均無回歸；本機 Qwen 不受影響。 |
| T11 | 非空／空背景、背景恰為 STOP／OTHER、詞庫、時間偏移及講者參考 | 每次生成的語意 payload 一致；不重複附背景、不讀 UI 草稿、不在錯誤或歷史洩漏原文；背景遮蔽不改變協定代碼或 typed error。 |
| T12 | unary JSON 的 STOP／OTHER，加上 upload／poll／cleanup 與晚到 callback | 代碼記在正確 generation attempt；不跨次污染、不被清理事件覆蓋；failureHistory 與複製診斷一致。 |
| T13 | 舊／新 journal、recent history、manifest 與續跑 | 舊缺欄可讀；新欄往返保留；完成 checkpoint 不重送、不重計本次發送；舊事件時間保留。 |
| T14 | 耗盡、deadline、取消、重試成功、完成含缺口 | 最終狀態與文案正確；實際發送數正確；混合錯誤不得寫成四次都空白。 |
| T15 | provider 欄位含背景、長字串、換行或疑似 credential | 只輸出固定安全代碼或 UNKNOWN；不保存原訊息、不改變 retry／safety 分類。 |

更新現有 `testMissingCandidateContentAndWhitespaceAreErrors`，把「無候選」與「空 STOP」分開期望；保留 Vertex 測試，新增 AI Studio 的端到端重試案例。不得只把原先斷言改成通過而省略重試、上限與復原驗證。

完整檢查依專案現行流程執行 `SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh`，記錄通過數、跳過原因與 `git diff --check` 結果。若實作中沒有新增風險，通過後不無故重複完整測試。

真實音訊驗證為補充證據，需有已授權且範圍明確的執行素材；不能以修正規格為由自動重送使用者全部失敗工作。沒有自然遇到空 STOP 不算功能失敗，也不能拿一筆成功取代 T01–T15 的決定性驗收。

## 10 實作順序與交付門檻

1. 加入 typed empty STOP 與 AI Studio shared retry，先通過條件、混合 quota、取消及截止測試。
2. 補齊回應代碼到 attempt／failure／持久化／UI 的完整鏈，通過相容性、歸屬與隱私測試。
3. 更新使用者文案、費用估算說明及既有完成含缺口診斷；通過完整檢查。
4. 依實際實作範圍更新版本及交付紀錄。打包、安裝與真實驗證的結果分開記載，保留可回復版本與既有工作資料。

完成定義：T01–T15 契約皆有相應證據；兩 backend 既有正常成功路徑、復原及本機路徑無回歸；只有符合條件的 AI Studio 空 STOP 新增重試；相同模型每個 quota 不超過 4 次；原始失敗原因可從工作與最近工作診斷直接辨識。

安裝時須先確認使用者 App 的實際工作狀態，不能為升級直接終止轉錄。重新啟動或讀取新診斷資料不能自行啟動歷史失敗工作的付費重送。若決定性測試顯示發送上限、取消、checkpoint 或隱私破壞，先修正，不以提高 timeout／重試次數掩蓋問題。

## 11 後續另案的進入條件

- **代理／SSE**：先建立可重現的長等待斷線測試，再評估 AI Studio SSE；需重新驗證 thought 過濾、未完整串流、取消、deadline 與資料上限。不能假設 SSE 一定能解決所有代理斷線。
- **睡眠**：可新增系統 sleep／wake 事件關聯與明確提示。只有當 App 在清醒且可執行時仍違反 deadline，才將其列為 timer 缺陷；合蓋案例不直接改為無限延長預算。
- **來源失效**：先提供明確「來源檔案已移動或不可用」提示，再評估 bookmark／來源快照；重新定位須驗證音訊身分，不能用檔名相似或時間長度相同作為唯一依據。
- **Google 攔截**：保留可判讀代碼與缺口，獨立評估輸入／服務差異。本版不將內容政策拒絕轉成網路重試，也不保證消除 OTHER。
