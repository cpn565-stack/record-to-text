# VPN／手機網路短暫中斷恢復修改規格

日期：2026-09-19

狀態（2026-09-21 更新）：方案 A 的 Core／App 實作與故障注入測試已加入 working tree，接續驗證見 [實作與驗證紀錄](network-recovery-implementation-2026-09-21.md)。尚未安裝或部署；native GUI／真實網路及付費驗收另列待辦。下文「目前／現況」調查以 2026-09-19 基準版本為準，不代表修改後程式。

基準：原始碼 `7c337d2`；查驗時 `/Applications/record-to-text.app` 為 0.2.1 build 6。

適用：Vertex AI、Google AI Studio；主要使用情境為中國境內 VPN／手機網路短暫不穩，稍後恢復。

## 1. 結論與本次範圍

可以改善「短暫斷線就整筆失敗」：等待恢復、有限重送未完成片段、保留已完成結果、暫停後續佇列。但不能保證網路永不失敗，也不能讓已斷掉的同步生成請求自動接回原結果。

本次建議先實作方案 A：沿用目前同步轉錄，加入有上限的網路恢復。方案 B「雲端背景工作，之後查回同一結果」另列可行方向，不包含在第一階段交付。

規格制定時的等待秒數與新增狀態為建議值；2026-09-21 實作已採用方案 A 的上限及狀態，具體調整與驗證界線見上述實作紀錄。原調查與接續開發未重送使用者錄音、未中斷使用者網路、未調整 VPN 或 live App 設定。

## 2. 最近錯誤的實際證據

來源：本機 `~/Library/Application Support/record-to-text/Temp-Recovery/<jobID>/recovery.json` 與同目錄 `segment-manifest.json`。下表是最近四份保留的雲端失敗紀錄，不代表全部歷史工作或總失敗率。時間為復原紀錄建立時間，轉為 UTC+8；不是精確的斷線起始時間。

| 復原紀錄時間（UTC+8） | 工作 ID 前八碼 | 後端 | 保留的失敗原因 | 片段狀態 |
| --- | --- | --- | --- | --- |
| 2026-09-19 01:20:15 | `3766E8ED` | Vertex AI | 網路連線中斷 | 第 1／3 段失敗 |
| 2026-09-19 01:15:25 | `8FCB7BE3` | Vertex AI | 網路連線中斷 | 第 1／4 段失敗 |
| 2026-09-17 16:42:15 | `15A31B07` | Vertex AI | STOP 完成回應沒有逐字稿 | 第 1／4 段失敗 |
| 2026-09-17 16:34:50 | `811F1FE9` | Vertex AI | 網路連線中斷 | 第 1／4 段失敗 |

已確認：

- 四筆 manifest 均沒有已完成片段；後續片段仍是 `planned`。因此這四筆不能靠「重用先前完成片段」省掉第一段重做。
- 失敗片段的 `diagnostic` 都未保存；沒有錯誤 domain/code、每次 request 的時間、網路路徑變化或實際嘗試次數。
- `Logs` 目錄為空；查驗時現行 ledger／recent 已不含這四筆的完整工作日誌，仍可由 recovery metadata 確認上述終止原因。
- 另一筆 STOP 空結果是模型／回應內容問題，必須與網路失敗分開，不能全部歸因於 VPN。

合理推測：使用者描述的 VPN／手機網路間歇不穩，與三筆連線中斷訊息相容。

無法確認：哪一段網路斷線、持續多久、是否由 VPN、電信商、中間代理或 Google 端關閉連線造成；是否曾經重試成功後又失敗；失聯請求是否已產生費用。保留的中文訊息與 `NSURLErrorNetworkConnectionLost` 相符，但沒有原始 code，不能把 `-1005` 寫成已查得事實。

Apple 說明 `networkConnectionLost` 表示請求進行中承載 HTTP 的連線斷開；這本身不能定位哪個網路環節出問題。[Apple QA1941](https://developer.apple.com/library/archive/qa/qa1941/_index.html)

## 3. 現在上傳後斷線，能否繼續

目前是一段接一段處理，預設每段最長 20 分鐘，可能依靜音或輸出長度再調整。不是把整份錄音全部送完後，就交給可離線查詢的雲端工作。

```text
準備片段 → 送出 generateContent → 等同一次請求回傳文字
                                      ↓
                            驗證並保存片段 → 下一段

連線確實斷掉 → 原請求結果未知 → 目前只能有限重送該段
```

| 情況 | 目前能否繼續 | 修改後可達成的行為 |
| --- | --- | --- |
| 短暫沒流量，但原連線未失效 | 可能仍能等到回應，受期限限制 | 不因網路狀態提示就主動取消健康請求 |
| 上傳途中斷線 | 不能假定 Google 收完整段 | 等待後重做失敗的上傳／請求 |
| 已送完，Google 處理中連線斷掉 | Google 可能仍處理，也可能停止；App 無法憑工作編號查回 | 等待後重送未完成片段；可能重複計費 |
| 文字已驗證並保存為完成片段 | 可以從有效 checkpoint 重用 | 不重送已完成片段 |
| 需離線數十分鐘、關閉 App 後取回同一次雲端生成 | 現行流程不支援 | 需方案 B 的持久化雲端工作 |

目前 Vertex 有 GCS 上傳與 inline 音訊兩種準備路徑，AI Studio 有 Files API；即使音訊已成為遠端檔案，也不等於「生成結果可查回」。`responseID` 是回應的識別資料，現有 App 沒有以它取回遺失結果的 API。[Vertex GenerateContentResponse](https://cloud.google.com/vertex-ai/generative-ai/docs/reference/rest/v1/GenerateContentResponse)

## 4. 現有能力與缺口

| 項目 | 現況與影響 | 原始碼定位（基準版本） |
| --- | --- | --- |
| 生成重試 | 已有最多 4 個外層 attempt；退避約 1–1.5、2–3、4–6 秒，對需較久恢復的 VPN 不夠友善；以上僅是退避，不含請求耗時 | `GeminiTransportHelper.swift:197`、`VertexAIGeminiBackend.swift:427` |
| 錯誤分類 | timeout、連線遺失、離線、DNS、host 失敗共用「網路暫時中斷」重試文案 | `GeminiTransportHelper.swift:25`、`VertexAIGeminiBackend.swift:521` |
| 自訂逾時 | App 的單次操作計時器也拋 `URLError.timedOut`，無法僅由 -1001 分辨網路／伺服器慢或 App 主動截止 | `CloudSegmentBudget.swift:99`、`:114` |
| 總期限 | 同一根片段與自動切分後子段共用 900 秒，單次生成操作最多 300 秒 | `CloudSegmentBudget.swift:35`、`GeminiTransportHelper.swift:7` |
| 連線等待 | 沒有 `waitsForConnectivity`、路徑監測或 task metrics；一般網路錯誤不會建立新 session | `CancellableCloudRequest.swift`、`GeminiTransportHelper.swift` |
| 上傳階段 | AI Studio 上傳／輪詢網路錯誤會走 inline fallback；Vertex GCS 上傳在 generation retry 之外 | `GoogleAIStudioBackend.swift:350`、`VertexAIGeminiBackend.swift:360` |
| 憑證後重送 | Vertex 401 刷新後若重送遇到網路錯誤，會包成 authenticationFailed | `VertexAIGeminiBackend.swift:750` |
| 失敗診斷 | 一般失敗／deadline 分支未保存 collector；多段包裝只保留 localizedDescription | `TranscriptionEngine.swift:1909`、`:1953` |
| 佇列 | 一般工作失敗後繼續下一筆，可能整批遇到相同網路問題 | `AppViewModel.swift:1751`、`:1839` |
| 零完成片段 | loader 不接受沒有可重用片段的 checkpoint；需保留原工作快照，提供重新嘗試 | `CloudResumeCheckpoint.swift:275` |

## 5. 方案 A：有限等待與自動恢復（本次建議實作）

### 5.1 恢復策略與上限

新增共用 `CloudNetworkRecoveryPolicy`／context，注入時鐘、等待器、路徑提示與 session factory，供兩後端一致使用及測試。

| 政策 | 建議預設 |
| --- | --- |
| 同一根片段累計網路等待額度 | 最多 300 秒，且不得超過根片段剩餘時間 |
| 根片段總期限 | 沿用 900 秒，包含前處理、上傳、生成、退避、等連線及切分 |
| 單次生成操作期限 | 沿用最多 300 秒，與根片段剩餘時間取小值 |
| 一般 transient 錯誤的重送間隔 | 15、45、120 秒，加 0–20% 正向 jitter；每次均檢查剩餘額度 |
| 同一待處理片段／同一模型的生成發送 | 最多 4 次；這是上限，不保證期限內一定能做滿 |
| 因一般連線故障建立新 session | 最多一次，用於下一個既有 attempt，不額外多送一次 |

等待額度以 monotonic clock 計算。退避、已知離線等待、URLSession 的建立連線等待都計入累計 300 秒，同一時間區間只算一次；實際傳輸／等生成不計入這 300 秒，但仍計入操作與根片段期限。

離線反覆發生、上傳重來、重新建立 session 或自動切分，不得重設根片段期限及其累計網路等待額度。HTTP／模型既有重試仍受相同根期限限制；純網路錯誤不得自動切換模型。

生成計數以 App 建立並啟動的 `generateContent` task 為準；401 後重送、POSIX 40 重送也須共用此發送額度，不能形成「外層 4 次 × 內層多次」。SDK／系統內部傳輸行為另記為不可完全控制。這比目前「4 個外層 attempt」更嚴格，需同步調整相關測試與顯示計數。

上傳初始化、音訊上傳、metadata GET 各自有最多 4 次 transient 嘗試，成功後才推進下一階段，全部共用根期限／等待額度，不可形成重跑整條管線的巢狀重試。metadata 正常處理中的輪詢不算失敗重試。

### 5.2 等待與恢復判定

1. 在送出前已有明確離線提示時，先進入「等待網路」；不快速連發四次請求。已執行中的正常請求不因 path 提示改變就取消。
2. 收到 transient 錯誤時保存結構化事件，依政策等待；path 恢復後維持至少 3 秒穩定，再於退避最低時間已滿時重試。path 事件不得繞過退避下限或增加次數。
3. `NWPathMonitor` 只作提示。VPN 壞掉時底層 Wi-Fi／手機介面仍可能顯示 `satisfied`；即使沒有 path 變化，也要按 15／45／120 秒排程重試實際原服務請求。
4. 不另外發付費模型呼叫作健康檢查；「網路介面可用」不等於「Google 可達」。只有實際 request 結果能證明該次服務連通。
5. 使用 App 自有 URLSession，upload／generation 設定 `waitsForConnectivity = true`，透過 delegate 提示建立連線等待；等待與操作均須可取消並受上述計時控制。2026-09-21 實作細化：bodyless metadata GET 採 `false`，網路失敗由共用恢復 loop 計時；公開 delegate 沒有適合 GET 的連線恢復回呼，不能把正常 GET 伺服器處理耗時當作網路等待。GET 的 15 秒及有效輪詢餘額上限不變。
6. 已斷掉的 request 不會因 `waitsForConnectivity` 接回原結果；這個屬性只處理建立連線時的等待。[Apple waitsForConnectivity](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/waitsforconnectivity)
7. 一般 connectionLost／連線建立失敗後，下次 attempt 可使用一次新 session；不因純慢回應就不停重建。不可使用私有 API 關閉 HTTP/3，也不可宣稱 `assumesHTTP3Capable = false` 保證使用 TCP。
8. 次數用完、300 秒等待額度用完或 900 秒根期限到達，立即停止自動恢復。先到者生效，網路反覆變動不能無限延長。

### 5.3 錯誤分類

新增可序列化 `CloudFailureDiagnostic`，由底層產生，穿過分段及 `PipelineExecutionError` 包裝時保留，UI 使用固定文案，不能靠比對中文訊息做控制流程。

| 類別 | 處理 |
| --- | --- |
| `connectionLost`／`offline` | 等待與有限重送；未完成段保留待處理 |
| `dnsFailure`／`hostUnreachable` | 可有限重送；文案「無法連到 Google」，不可斷言整台電腦離線 |
| `urlSessionTimeout` | 記錄為請求逾時，可有限重送；不可直接歸因 VPN |
| `requestDeadlineExceeded` | App 單次操作主動截止；與原生 URLSession timeout 分開，仍受共用重試額度 |
| `segmentDeadlineExceeded` | 根期限到達，停止；保留最後已知原因及完成片段 |
| HTTP 401／403、TLS／憑證錯誤 | 保留既有認證處理；不能全部當作可恢復離線 |
| HTTP 429／5xx | 保留服務端重試政策及 Retry-After；不能顯示成已確認離線 |
| STOP 空內容 | 保留獨立分類及已有有限重試；不觸發網路離線提示 |
| 使用者取消 | 立即停止等待、poll、request 和後續重送；不可被重分類為網路失敗 |

錯誤 domain/code 及有限深度 underlying error chain 採 allowlist；循環或過深時停止。`gcloud` 的失敗若無可機器判定的網路原因，標記 `authUnavailable/unknown`，不依任意 stderr 字串假造 -1005。

Vertex 401 更新憑證後的 request 若是 transient network error，保留其網路分類；確定是憑證失效才回報 authenticationFailed。單純網路失敗不降模型。

### 5.4 上傳與生成分開恢復

- Vertex inline：沒有獨立上傳完成票據；重送 `generateContent` 仍會帶該段音訊。不能顯示「只重新下載結果」。
- Vertex GCS：上傳失敗僅恢復上傳階段；已確認成功的物件可在同一次工作有效期內重用，避免重複上傳。物件存在不代表生成已完成。
- AI Studio：Files 初始化、音訊上傳、ACTIVE 輪詢納入 transient 恢復。網路錯誤優先等待，不立刻改用更大的 inline 請求；明確不支援 Files API 才走既有適用的 fallback。
- AI Studio 目前另有 60 秒 Files 處理輪詢期限（`GoogleAIStudioBackend.swift:799`）。修改為累計有效輪詢時間：排除 5.1 已量測的網路等待區間，正常輪詢間隔與實際 GET 耗時仍計入；GET 沿用最多 15 秒並受有效輪詢餘額限制。不能因中途等網路 120 秒就立即判定處理逾時，也不能每次恢復重設 60 秒；整段仍受 300 秒累計網路等待與 900 秒根期限限制。
- 上傳成功回應若遺失，優先使用官方支援的 session／metadata 查詢確認；未知時可有限重啟上傳，但不能宣稱不會留下重複遠端資源。只清理本工作已確認擁有的遠端物件；清理失敗不改判已完成文字稿。
- 已取得有效音訊 URI 時，生成重試沿用準備結果；遠端檔案已過期則重建，次數／期限不得重設。
- 每次生成只允許一個有效的本機完成提交；被取消或超時後晚到的 callback 不得另行寫稿、跳到下一段或覆蓋成功結果。取消本機請求不代表 Google 已停止計算或計費。

### 5.5 工作狀態、佇列與重啟

建議新增 optional `networkRecovery` 欄位，包含狀態（waiting／retrying／paused）、停止原因、已用額度、目前片段與已完成片段數。等待中沿用原 pipeline stage，以附加狀態顯示，避免讓段落進度倒退或重設。

```text
處理中 → 暫時連線錯誤 → 等待網路 → 重試未完成段 → 保存結果／下一段
                               ↓ 超過次數或期限
                         已暫停，等待稍後重試
```

- 因網路恢復耗盡而停止者，使用既有 `.interrupted` 加 `networkRecovery.state = paused`，呈現「網路恢復逾限，已暫停」。不把它記成完成，亦不可只留易被裁掉的普通 failed summary。
- 根期限到達若前因是網路等待，可進上述暫停；純模型慢／服務端期限與網路原因仍須分開標示。
- 在將控制權交回佇列前，原子持久化暫停工作及 `queuePausedForNetwork` 所需資訊。`scheduleQueueIfNeeded` 與 `drainQueue` 都要檢查 gate。
- 第一版保留單工順序：暫停後整個當前 drain 停止，後續 queued 工作保持原狀，含混合佇列也不自動跳過。使用者仍可明確改用本機工作，不偷偷切換原工作的後端。
- 自動等待期間不需操作；到達上限後不因 path 上線自動再建立新 job。提供明確「重新嘗試」／「從已完成片段繼續」，使用者點擊才開始新的有限恢復週期。
- 有完成片段：沿用 `CloudResumeCheckpointLoader` 驗證成功片段及原工作快照後續跑，已完成片段不再上傳。
- 零完成片段：保留原 sourceSlice／模型／prompt／terms／輸出設定快照，提供「重新嘗試」。不可偽稱已有部分稿或放寬 loader 為成功；也不可默默改套目前全域設定。
- 重啟後 paused 狀態與 queue gate 必須保留；不能被啟動時的一般 interrupted 改寫流程清掉。等待中被關閉則轉為待手動恢復，不自動重新發付費請求。
- 手動恢復只建立一次續作，優先於原本被擋住的後續工作；重複點擊不能建立多個相同續作。保存成功才解除 gate 並啟動。明確取消 paused 工作可解除其 gate，但不自行啟動後續付費工作。

`JobRetentionPolicy` 的 `.interrupted` 原本即屬跨重啟保留；新增欄位須向後相容，舊 ledger／manifest 可讀。新 diagnostics 狀態不可讓整筆舊資料 decode 失敗。降版需先備份資料或遷移，不能假定舊 binary 接受新的 enum 值。

### 5.6 使用者文字

| 場景 | 建議文字 |
| --- | --- |
| 等待恢復 | 「連到 Google 的連線暫時不穩，正在等待恢復。已完成 2／5 段。」 |
| 即將重試 | 「將重新嘗試第 3／5 段；已完成的片段不會重做。」 |
| 沒有完成段且暫停 | 「連線仍未恢復，工作已保留。恢復網路後可重新嘗試；目前尚未完成任何片段。」 |
| 有完成段且暫停 | 「連線恢復等待已達上限，已暫停。已保存 2／5 段，可稍後繼續。」 |
| 結果未知 | 詳細資訊：「前次請求可能已被 Google 處理；重送未完成片段可能再次計費。」 |

等待 UI 顯示實際剩餘等待額度／下一次重試時間，不假裝有雲端百分比；「Google 正在處理」的既有定時提示在等待／暫停時不得覆蓋真實狀態。取消按鈕始終可用。

### 5.7 必留診斷與隱私

在成功、失敗、取消及期限到達時都保存受限摘要；不依賴只在成功時才回傳的 `PipelineResult`。

必要欄位：schema version、App build、backend／模型、job／root／segment ID、事件 UTC 時間、operation stage、App 發送 attempt 編號、固定錯誤分類、allowlist domain/code、HTTP status、App 或 URLSession 逾時來源、path 狀態（含 unknown）、累計網路等待、根期限剩餘時間、是否換過 session、完成片段數、結果是否未知。事件列表每工作最多 100 筆；累計計數獨立保留，不能因截斷失真。

優先沿用 journal／job model、`CloudJobDiagnostics`、manifest/recovery 的受限欄位。`CloudSegmentDiagnostic.Outcome` 補上失敗／取消／期限等語意；一般 failed catch、deadline catch 在離開前保存 collector。失敗位於第一段、沒有文字檢查點也必須保存診斷。

可選 task metrics：DNS／connect／TLS／request／response 耗時、是否重用連線、HTTP 協定及傳輸 byte count；資料缺失時顯示 unknown。這些能縮小問題範圍，不能當成遠端收到／計費的證明。

禁止新增保存 API key、token、完整 URL/query、IP、SSID、VPN 帳號／名稱、音訊、逐字稿、prompt、詞庫或任意 raw NSError.userInfo／gcloud stderr。診斷複製功能也遵守同一 allowlist；本規格的日誌只為連線排錯。

## 6. 方案 B：上傳後可離線，之後取回同一結果（後續選項）

若需求是「上傳及提交成功後，Mac 可以斷線甚至關 App，Google 照跑，回來拿原結果」，需使用可查詢的持久化雲端工作。

Google 提供 Gemini Batch API，以及 Vertex 的 batch prediction 工作建立／查詢路徑。Batch 與目前同步呼叫是不同工作模式；Gemini Batch 文件以 24 小時為目標周轉時間，不保證像目前幾分鐘內回覆。Vertex 需另核對選定模型、region、音訊輸入與儲存配置，不能把 AI Studio 的能力直接當成 Vertex 已驗證。[Gemini Batch](https://ai.google.dev/gemini-api/docs/batch-api)；[Vertex batch 工作範例](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/samples/generativeaionvertexai-batch-predict-gemini-createjob-gcs)

此方案至少需要：

1. 上傳完成、提交工作、拿到遠端 job name 後立即持久化；之後只查詢同一工作與下載結果，斷線不重新生成。
2. 處理「提交成功但 job name 回應遺失」的未知狀態，依官方可查詢資料對帳；不能盲目重建。Batch 建立並非天然冪等，仍可能提交兩份工作。
3. 保存遠端音訊與結果的生命週期、跨重啟恢復、取消語意、權限與清理，下載成功且本機發布完成才刪工作資源。
4. 保留分段、時間標記、片段驗證與原子發布；現有逐段講者連續性依賴前段結果，不能直接把全部段落併發提交而宣稱效果相同。
5. 用測試確認「拿到並保存 job name → 斷網／關 App → 恢復 → 取回同一工作」，且沒有新增生成工作。

本次優先採 A，以較小修改改善短暫失聯；B 適合能接受非即時完成的需求。單純換成 streaming、延長 timeout、增加 GCS／Files 上傳，都不足以實現 B。

## 7. 修改檔案與交付順序

| 批次 | 主要檔案 | 交付內容 |
| --- | --- | --- |
| A1：分類與診斷 | 新增 `CloudFailureDiagnostic.swift`；`CloudJobDiagnostics.swift`、`CloudSegmentBudget.swift`、`TranscriptionEngine.swift`、`Models.swift` | 失敗可定位 stage/code/timeout 來源，零完成片段亦可保存 |
| A2：共用恢復 | 新增 `CloudNetworkRecoveryPolicy.swift`／網路提示與 session owner；`GeminiTransportHelper.swift`、`CancellableCloudRequest.swift`、兩支 backend | 有上限等待、發送計數、同模型重試、上傳／401 後重送分類 |
| A3：持久化與 UI | `AppViewModel.swift`、`MainView.swift`、`JobPersistenceCoordinator.swift`、`JobRetentionPolicy.swift`、復原相關 model/tests | 等待／暫停、佇列 gate、0／多片段續作與重啟恢復 |
| A4：驗收 | 既有 cloud/recovery/persistence/cancellation 測試及新增故障注入測試 | 下節全部通過後才做實機付費驗收及版本交付 |

A1–A3 必須整合驗收，不能只把 retry 次數調大就宣稱完成。第一版不改預設 20 分鐘段長、不改模型品質／prompt、不加入自動本機 fallback。較短段落可降低重送成本，但目前沒有證據證明「20 分鐘」是這次斷線的原因。

## 8. 驗收規格

自動測試使用注入式時鐘、路徑提示與 mock transport，不等待真實 5／15 分鐘，不上傳私人音訊。

| 編號 | 故障情境 | 必須成立 |
| --- | --- | --- |
| N01 | 發送前離線，30 秒／120 秒後恢復 | 等待後自動完成，不快速耗完 4 次；離線等待不產生生成請求 |
| N02 | VPN 故障、path 一直 satisfied，原請求 -1005；120 秒後服務恢復 | 仍按排程重試，恢復後成功；不依賴 path 跳變 |
| N03 | 已送出後連線斷開，之後成功 | 只重試未完成段；顯示前次結果未知；不保證零重複費用 |
| N04 | 網路反覆上下線 | 累計等待最多 300 秒，不重設 900 秒根期限、不突破發送額度 |
| N05 | 四次實際 App 生成發送均失敗 | 進入暫停，不自動建立第五次／新 job；含401或POSIX內層組合亦符合 |
| N06 | root 剩 20 秒，下一次需等45秒 | 到根期限即停，不等待完整45秒；原因與network分類保留 |
| N07 | 等連線、退避、upload、poll、generation 各階段取消 | mock下1秒內結束，無下一次請求；晚到 callback 不發布文字 |
| N08 | 第1段失敗，0完成 | 保存原快照與診斷，顯示「重新嘗試」，不宣稱可重用完成片段 |
| N09 | 第3段失敗，前2段完成 | 恢復後前2段不再壓縮／上傳／生成；僅重做未完成段 |
| N10 | 一批多工作遇網路耗盡 | 目前工作暫停，後續仍queued；不連續失敗、不自動換模型 |
| N11 | paused／waiting 時退出再啟動 | 狀態與診斷可讀、gate不丟失；不自動發送；手動恢復只能建立一份續作 |
| N12 | Files init／upload／poll、GCS upload transient failure | 恢復所在階段；不因網路錯誤直接inline fallback；生成不提前開始 |
| N13 | Vertex 401後重送連線失敗 | 回到網路恢復政策，非「憑證錯誤」；額度不重設 |
| N14 | App操作計時器、URLSession timeout、根期限、STOP空內容 | 四者診斷與文案可區分，STOP不標為離線 |
| N15 | path unsatisfied但原請求最後成功 | 不因path提示先取消有效請求，只提交一次結果 |
| N16 | 日誌／診斷序列化及複製 | key、token、raw URL、IP、SSID、逐字稿、prompt均未新增洩露；截斷不改累計數字 |
| N17 | 舊資料、最近工作limit=0、原子寫入失敗、重複恢復點擊 | 舊資料可讀；paused工作不被裁掉；未持久化不得開始續作；無重複輸出 |
| N18 | Files 已進入 PROCESSING，有效輪詢尚有餘額，斷線等待120秒後恢復為ACTIVE | 不因等待時間誤判60秒處理逾時，不轉inline；有效輪詢額度與根期限不重設 |

實機驗收另使用可公開的短音訊，在已確認可用的 Vertex／AI Studio 測試設定各跑一組：生成前離線、生成中切換網路、120 秒後恢復、等候中取消。真實網路切換及付費呼叫不屬本次調查已執行項目。記錄僅保留診斷摘要與請求數，不錄製私人逐字稿。

2026-09-19 調查時已執行的基線驗證：16 個既有 mock 測試全部通過，涵蓋原有四次重試、斷線後成功、重試中取消與單段期限。新增功能的 N01–N18 對照及 2026-09-21 完整檢查結果見 [實作與驗證紀錄](network-recovery-implementation-2026-09-21.md)，勿將下方舊基線結果當成最新驗收。

可重現基線檢查指令（2026-09-19 執行結果：16 tests、0 failures）：

```sh
swift test --filter 'GeminiBackendObservabilityTests|CloudSegmentBudgetTests|GeminiCloudResponseValidationTests.testNetworkRetry|GeminiCloudResponseValidationTests.testCancelDuringNetworkBackoff|GeminiCloudResponseValidationTests.testAIStudioRetriesTransientNetworkFailure|VertexAIGeminiBackendTests.testTransientNetworkTimeout'
```

## 9. 完成定義

在故障注入下，短暫離線／VPN路徑失效後能自動繼續未完成段；超過恢復預算會保存工作並暫停佇列；已完成片段不重送；取消與期限仍有效；重啟後可辨認狀態及失敗原因。UI 必須誠實區分「重送未完成段」與「取回同一次雲端結果」。

這份規格以目前原始碼為準；歷史 [Gemini 傳輸修正規格](gemini-cloud-transport-hardening.md) 的「尚未實作」描述不可當成現況。產品現況另見 [產品暨系統規格](product-system-spec-2026-09-11.md)。
