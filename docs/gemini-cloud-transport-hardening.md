# Gemini 雲端傳輸修正規格（兩層）

狀態：規格已寫，**尚未實作**  
日期：2026-08-21  
適用範圍：`VertexAIGeminiBackend`、`GoogleAIStudioBackend`，以及它們的單元測試  
觸發事件：2026-08-21 `Nangang Software Park.m4a`（約 31.5 分鐘）兩次 Vertex AI 轉錄皆在送出後約 2 秒失敗

## 1. 背景與問題

### 1.1 已確認的失敗

工作紀錄（`job-ledger.json`）兩筆皆為：

- 後端：`vertexAI`，模型 `gemini-3.7-flash`，location `global`
- 切段：來源約 31.5 分鐘，coordinator 每段最長 20 分鐘，共 2 段
- 壓縮：16 kHz 單聲道 MP3（約 24 kbps）後，整段以 JSON `inlineData`（base64）一次 `URLSession.data(for:)` POST
- 底層錯誤：`NSPOSIXErrorDomain Code=40 "Message too long"`（`_kCFStreamErrorDomainKey=1`、`_kCFStreamErrorCodeKey=40`）
- 對端：Google IPv6 `:443`（`2404:6800:…`）
- 使用者看到：`無法完成作業。訊息太長`

這不是 Gemini JSON 回傳「音檔太長／上下文爆掉」。請求在本機送出階段就失敗，Google 尚未開始轉逐字稿。

POSIX 40（`EMSGSIZE`）出現在 IPv6 + 大包 POST 時，與 HTTP/3／QUIC（UDP）路徑相容：macOS URLSession 把過大的 in-memory `httpBody` 往這條通道送時，socket 直接拒絕。HTTP/2 over TCP 通常能串流同一大小的 body，因此「以前更長的檔可以」不能用來否定今天這條雲端路徑。

### 1.2 為什麼「以前更長也能過」不能當反證

- 本專案先前約兩個半小時的成功路徑，是本機 Qwen／MLX，不是這次的 Vertex inline POST。
- 雲端路徑不論來源多長，每包仍是約 20 分鐘。31 分鐘與 3 小時的**單次 POST 大小同級**。
- 因此問題是傳送通道，不是「今天這檔比較長」。

### 1.3 現行程式問題點

`VertexAIGeminiBackend.executeGenerateContent` 與 `GoogleAIStudioBackend.executeGenerateContent` 皆為：

1. 將 MP3 做 base64，塞進單一 JSON。
2. `JSONSerialization.data` 得到數 MB～十數 MB 的 `Data`。
3. 放到 `URLRequest.httpBody`。
4. `urlSession.data(for:)`（預設 `.shared`，可能沿用 HTTP/3 Alt-Svc）。

`maximumInlineAudioBytes = 20 MB` 只擋原始 MP3 位元組，不擋 base64 膨脹後的 JSON，也不處理 POSIX 40。

`VertexAIGeminiBackend.Configuration` 已有 `gcsBucket`，但現行轉錄路徑未使用。

## 2. 目標

1. 雲端轉錄不再依賴「整包 JSON 放 `httpBody` + `data(for:)`」這條已知會在 IPv6／HTTP/3 炸掉的路徑。
2. POSIX 40 不得再顯示成「訊息太長」；使用者要能看出是傳輸通道問題。
3. 分兩層實作，可分開合併、分開驗收。第一層先恢復可用；第二層改成 Google 建議的檔案參照，讓 generateContent 請求體變小。
4. Vertex AI 與 Google AI Studio 兩條後端都要修，行為一致。
5. **不改回本機 Qwen 作為這次的修復手段。**

## 3. 非目標

- 不把 coordinator 20 分鐘上限改短當成主修（5～8 分鐘切段最多當手動緩解，不進本規格必做項）。
- 不重啟本機 MLX／Qwen 預設路徑。
- 不使用未公開的 `NSURLSessionHTTP3Enabled` 等私有 API 關閉 HTTP/3。
- 不在本規格處理 503／429 模型 fallback、安全政策誤判（既有邏輯保留）。
- 不在本規格新增大段 UX 改版或設定頁大改；第二層若需要 GCS bucket，只加必要設定與錯誤提示。
- 不在規格階段實作程式。

## 4. 分層與順序

| 層 | 名稱 | 何時做 | 成功標準 |
|---|---|---|---|
| 第一層 | 串流上傳 + POSIX 40 重試 | 先做 | 同一支 31.5 分鐘檔、Vertex `gemini-3.7-flash`、20 分鐘切段，第 1 段能送出並取得 HTTP 回應（200 或可解析的 API 錯誤，而不是 POSIX 40） |
| 第二層 | 檔案上傳後以 URI 呼叫 generateContent | 第一層合併並通過實測後 | generateContent 請求體不再含 base64 音訊；上傳與推論分開；POSIX 40 在推論請求上不再可重現 |

第一層失敗不得略過直接做第二層的「只改切段秒數」。若第一層實測仍 POSIX 40，第二層提前開工，但第一層的錯誤文案與測試仍要做完。

---

## 5. 第一層行為規格

### 5.1 送出方式

`executeGenerateContent`（兩條後端）必須：

1. 仍可在記憶體組 JSON（或先寫 UTF-8 JSON 檔）。
2. **禁止**把完整請求 JSON 設為 `URLRequest.httpBody` 後呼叫 `data(for:)`。
3. 改為把請求 JSON 寫入工作目錄暫存檔，使用 `urlSession.upload(for:fromFile:)`（或等價的 `httpBodyStream` + 串流 upload task）。
4. 暫存檔權限收緊（建議 `0o600`），函式結束（成功、失敗、取消）都要刪。
5. `timeoutInterval` 維持至少 300 秒；取消工作必須能取消進行中的 upload。

### 5.2 POSIX 40 判定

符合任一即視為傳輸通道失敗，得進入 5.3：

- `NSError.domain == NSPOSIXErrorDomain && code == 40`
- `userInfo["_kCFStreamErrorCodeKey"]` 為 `40`（含 `NSNumber`）

不得把 Gemini HTTP 4xx／5xx JSON 誤判成 POSIX 40。

### 5.3 自動重試一次

第一次 upload 發生 POSIX 40 時：

1. 寫入工作日誌（info）：說明是本機傳輸通道失敗，將改用新的連線重試，不是音檔超時長。
2. 建立**新的** `URLSessionConfiguration.ephemeral` session（不要重用 `.shared`，以丟掉可能快取的 HTTP/3 Alt-Svc）。
3. `URLRequest.assumesHTTP3Capable = false`（公開 API，能避免「一開始就假設 HTTP/3」；不宣稱能完全關閉 HTTP/3）。
4. 用同一個 JSON 檔再 `upload` **恰好一次**。
5. 第二次仍 POSIX 40：拋出本規格 5.4 的明確錯誤，不要再無限重試。
6. 第二次若是 HTTP 401／503 等，走既有 token 刷新或 503 fallback，不得當成 POSIX 40。

401 token 刷新（Vertex 既有行為）在串流上傳路徑上必須仍然有效：刷新後用同一檔再 upload。

### 5.4 錯誤文案

新增錯誤（名稱可在實作時調整，語意固定）：

- Vertex：`VertexAIError.transportMessageTooLarge`
- AI Studio：`GoogleAIStudioError.transportMessageTooLarge`

使用者可見文字必須接近：

> 連到 Google 的傳輸通道失敗（本機無法送出這包資料）。這不是音檔超過 Gemini 時長上限。請重試；若持續發生，需要改為先上傳音檔再轉錄。

禁止再把 POSIX 40 的 `localizedDescription`（「無法完成作業。訊息太長」）直接寫進 job 失敗列。

`audioPayloadTooLarge`（超過 20 MB 原始音訊）維持現狀，與傳輸通道錯誤分開。

### 5.5 日誌

至少記錄：

- 壓縮後 MP3 位元組、JSON 請求檔位元組、模型 ID、location／host。
- 第一次 upload 是否 POSIX 40。
- 是否已做 ephemeral 重試、重試結果（HTTP 狀態或再次 POSIX 40）。

不得把 Access Token、API Key 寫進 log。

### 5.6 第一層刻意不做

- 不呼叫 Files API／GCS。
- 不改切段秒數。
- 不改 prompt、safetySettings、generationConfig（含 `maxOutputTokens`）。

---

## 6. 第二層行為規格

### 6.1 原則

音訊位元組與 generateContent JSON 分開：

1. 先把壓縮後的 MP3 **以檔案上傳**。
2. 等檔案進入可用狀態（`ACTIVE` 或文件規定的等價狀態）。
3. `generateContent` 的 `parts` 使用 `fileData`（`fileUri` + `mimeType`），**不得**再帶該段音訊的 `inlineData.data`。
4. 轉錄結束或失敗，盡力刪除遠端暫存檔；刪除失敗只記 warning，不把整次工作改判失敗（逐字稿若已成功仍算成功）。

### 6.2 Google AI Studio

使用官方 Files API：

1. 上傳：`POST https://generativelanguage.googleapis.com/upload/v1beta/files`（resumable／multipart 以現行 Google 文件為準），標頭沿用 `x-goog-api-key`。
2. 輪詢或讀取檔案 metadata，直到狀態可用，超時建議 60 秒，間隔 1～2 秒。
3. `generateContent` 的 part：

```json
{
  "fileData": {
    "mimeType": "audio/mpeg",
    "fileUri": "<files API 回傳的 uri>"
  }
}
```

4. 刪除：`DELETE https://generativelanguage.googleapis.com/v1beta/{fileName}`。

上傳本身也必須用檔案串流（`upload(for:fromFile:)`），不得把整份 MP3 再包進超大 JSON `httpBody`。

### 6.3 Vertex AI

優先順序：

1. **若 `gcsBucket` 有值**：把 MP3 上傳到該 bucket（物件名建議含 job id、segment index、不可猜測的隨機後綴），`generateContent` 使用：

```json
{
  "fileData": {
    "mimeType": "audio/mpeg",
    "fileUri": "gs://<bucket>/<object>"
  }
}
```

   結束後刪除該 object。

2. **若 `gcsBucket` 為空**：使用 Vertex 對應的 file upload（實作時以當時 Vertex Gemini 文件為準；endpoint 須帶 project、location、OAuth bearer）。不得悄悄改走 AI Studio API Key 來混用兩套驗證。

3. 若當時 Vertex 沒有「免 bucket 的 file upload」、且使用者沒設 bucket：第二層對 Vertex 必須**明確失敗**，提示到設定填 GCS bucket，或改用 Google AI Studio 後端。禁止默默退回第一層 inline JSON 而不記 log。

設定頁：Vertex 區顯示 GCS bucket 欄位（Config 已有 `gcsBucket` 的話接上即可）。空白表示未設定。不在本規格做 bucket 自動建立。

### 6.4 generateContent 其餘欄位

`systemInstruction`、user prompt、safetySettings、generationConfig、401 刷新、503／安全政策 fallback **保持與現況相同**，只替換音訊 part 的攜帶方式。

### 6.5 錯誤與超時

- 上傳 HTTP 非 2xx：`requestFailed`，帶 status 與伺服器訊息。
- 檔案遲遲未變可用：明確超時錯誤（不要 POSIX 40 文案）。
- generateContent 仍可能 POSIX 40（理論上請求已很小）：沿用第一層判定與文案；此情況應在實測報告標成異常，優先查是否誤把音訊又 inline 進去。
- 取消：停止輪詢與 upload，並嘗試刪遠端檔。

### 6.6 第二層與第一層的關係

第二層落地後，雲端轉錄的主路徑應為「上傳檔案 + URI」。第一層的串流 upload **仍保留**給：

- 檔案 API 不可用時的緊急路徑（須打 log）；或
- 僅用於「上傳音檔」那個小協定，而不是再把 base64 音訊塞進 generateContent。

正式產品路徑不得再對 generateContent 發送含完整音訊 base64 的 JSON。

---

## 7. 實作設計（仍不在本文件階段寫程式）

建議抽共用 helper（名稱可改）：

- `isPOSIXMessageTooLarge(Error) -> Bool`
- `writeJSONRequestFile(...) -> URL`
- `uploadJSONFile(session:request:fileURL:) async throws -> (Data, URLResponse)`
- `makeEphemeralRetrySession() -> URLSession`

兩條 backend 共用判定與重試，避免 Vertex／AI Studio 行為分叉。

單元測試目前用 `MockURLProtocol` 讀 `URLRequest`。改 `upload(fromFile:)` 後，測試必須改為能從 `httpBody` **或** body stream／協定紀錄取得 POST body，不可再假設 `request.httpBody != nil`。

工作目錄：沿用該 job 既有 working directory（已有 `compressed.mp3`、`segment_N.mp3`），JSON／upload 暫存放同一處，job 結束納入既有清理。

---

## 8. 測試規格

### 8.1 單元測試（不打真實 Google）

1. 成功：mock 200，回應可解析逐字稿；assert 請求為 POST、Authorization／API key 正確、URL 仍為既有 generateContent endpoint（第一層）。
2. POSIX 40 一次後 200：第一次 protocol 丟 code 40，第二次 200；assert 有重試、最終成功。
3. POSIX 40 兩次：拋出 `transportMessageTooLarge`，使用者文案不含「訊息太長」四字作為唯一說明，且含「傳輸通道」。
4. HTTP 503：不走 POSIX 重試邏輯；AI Studio 既有 3.6／3.1 fallback 仍在。
5. 超過 20 MB 原始音訊：仍 `audioPayloadTooLarge`，不先送出。
6. 第二層：generateContent 的 JSON **沒有** `inlineData.data`；有 `fileData.fileUri`。上傳失敗時不呼叫 generateContent。
7. 第二層成功後會發刪除（mock DELETE 或 GCS delete）；刪除 404 不導致轉錄失敗。

### 8.2 實機驗收（第一層）

前置：與失敗當日相同——Vertex、`gemini-3.7-flash`、`global`、本機 IPv6 可用。

1. 使用 `/Users/mike/Downloads/Nangang Software Park.m4a`（約 31.5 分鐘）。
2. 第 1／2 段必須通過「送出」：job log 不得在 2 秒內以 POSIX 40 失敗。
3. 若 Google 回 200：該段有非空逐字稿。
4. 若 Google 回業務錯誤（配額、模型名）：錯誤必須是 `requestFailed(HTTP …)`，不是「訊息太長」。
5. 記錄：MP3 大小、JSON 大小、是否觸發 ephemeral 重試、HTTP 狀態。

### 8.3 實機驗收（第二層）

1. 同一音檔、同一後端設定。
2. log 可見上傳檔案、檔案變可用、generateContent、嘗試刪除。
3. 用代理或 debug log 確認 generateContent body 無音訊 base64。
4. Vertex 未設 bucket 且無替代 upload 時，失敗訊息指出缺 bucket，不得 silently inline。

## 9. 驗收與回滾

- 第一層合入條件：8.1 相關測試通過 + 8.2 實機至少一次「不是 POSIX 40」。
- 第二層合入條件：8.1 第二層測試通過 + 8.3。
- 回滾：還原兩支 backend 的送出函式即可；切段與 prompt 不應被本規格改動，回滾面應很小。

## 10. 參考

- 失敗技術細節：Application Support `record-to-text/job-ledger.json`（2026-08-21 兩筆 `Code=40`）
- 現行 inline 送出：`Sources/RecordToTextCore/VertexAIGeminiBackend.swift`、`GoogleAIStudioBackend.swift`
- Google 音訊說明：inline 總請求建議 20 MB 以上改走 Files API；音訊時長上限遠大於 20 分鐘（本事件未觸及該上限）
- 切段政策：`AudioSegmentPlanner` 20 分鐘（PD-011／PD-013），本規格不修改
