# 真實 Gemini 短音檔自適應切段驗證規格

狀態：待實作
日期：2026-08-30
適用分支：`codex/record-to-text-reliability-v2`
程式停點：`9c218344509d51b4c0fecbecec2e91a52725d2ca`
文件停點：`5bdbaf1307112151e32b0f6df94c643e21b414d9`
產品版本：`0.2.0 (1)`

完成本規格書 ≠ 已完成真實 Gemini 驗證。本檔只定義要跑什麼、什麼算通過、什麼禁止。實際打 API 與驗證報告須另一次明確授權。

## 1. 目的

用一次受控、可停、有支出上限的真實 Google 雲端轉錄，證明 Reliability v2 的自適應切段在真 API 上成立：

1. 父段真實回 `MAX_TOKENS`／丟出 `CloudOutputTruncatedError`。
2. App 捨棄父段截斷文字，不把它當正式稿。
3. 在 production 切段政策下把該段切成左右子段。
4. 子段真實 `STOP` 後依序合併，才產生正式 TXT。
5. manifest 連續、無重疊、無缺口；並留下請求次數與費用紀錄。

這不是新產品功能。Production 預設維持：

- 轉錄 `maxOutputTokens = 16384`
- 最小子段 `CloudAdaptiveSegmentPlanner.productionMinimumChildDuration = 240` 秒
- 最大 `splitDepth = 2`

## 2. 非目標

本次規格與後續實跑都不做：

- 重做工作 1–3（XCTest CI、mock 整合測試、文件同步）
- 把 mock／CI 綠燈寫成真實 Gemini 證據
- 5 分鐘音檔的 `STOP` 成功轉錄（那只證明傳輸與一般雲端路徑，不證明切段）
- 子段失敗 fail-closed 的付費重跑（mock 已覆蓋；本規格付費只買成功切段）
- 30／62 分鐘 Gemini、speaker roster、Qwen soak、GUI／High Contrast／Reduce Motion
- PD-015、Runtime installer、Intel、Universal 2、簽署、公證、Stable DMG
- 把驗證用 token 覆寫做成正式設定選項
- 將私人音檔、逐字稿全文、API Key、token、job-ledger 提交進 Git

## 3. 與既有 mock 證據的邊界

已完成、不得重做：

- `fdeaef9`／`a3ac87d`／`9c21834`：`TranscriptionEngine.run` 在 URLProtocol 假回應下，父段截斷 → 子段 `STOP` 合併、子段 HTTP 400 fail-closed、最大深度 fail-closed。
- GitHub Actions Run `33263989282`：178 項 XCTest。
- 測試使用假 API Key、短 fixture、並透過 internal `cloudAdaptiveMinimumChildDuration` 繞過 240 秒限制。

尚未證明：

- 真實 `GoogleAIStudioBackend`／`VertexAIGeminiBackend` 的 `finishReason`
- 真實 Files API／GCS 上傳後，coordinator 仍會丟 `CloudOutputTruncatedError` 並切段
- 真實子段 `STOP` 後的 segment coverage
- 真實費用

`docs/reliability-v2-validation.md` 階段 1 的自動化證據仍然有效；本規格補的是該檔「真實環境待驗」那一列。

## 4. 已知約束

### 4.1 少於約 8 分鐘不能測 production 切段

`CloudAdaptiveSegmentPlanner.splitBoundary` 在 `duration < 240 * 2` 或已達最大深度時回傳 `nil`。此時 `TranscriptionEngine` 不會切段，只會把該段標 failed 並 fail-closed。

因此：

- 驗證音檔必須 **≥ 8 分鐘**（480 秒）。
- 建議 **8–12 分鐘** 中文對談，不要用 5 分鐘，也不要用 30／62 分鐘當第一槍。
- **禁止**為了遷就短檔而把 production 最小子段改短。那測到的不是使用者會碰到的政策。

### 4.2 預設 16384 通常切不到

兩個雲端 backend 的轉錄路徑目前寫死 `maxOutputTokens: 16_384`。8–12 分鐘中文對談多半會 `STOP`，不會自然截斷。若完全不覆寫、只賭 Google 自己回 `MAX_TOKENS`，本項驗證很可能跑完卻沒切段。那種結果只能寫「未觸發」，不能寫通過。

### 4.3 切段成功會把同一段音訊送三次

成功路徑預期請求順序：父段（截斷）→ 左子段 → 右子段。同一段音訊會被處理約兩倍時長以上（父段全長 + 兩個半長）。費用明顯高於單次轉錄。只准跑本規格第 7 節允許的次數。

## 5. 開工前必須確認

未得到下列確認前，不得送出任何付費 `generateContent`：

1. 後端：只用 App **目前已能跑通的那一條**（Google AI Studio 或 Vertex AI）。禁止雙跑。先前真機長音基線是 Vertex `gemini-3.7-flash`；若使用者現況不同，以現況為準並寫進報告。
2. 模型 ID 與 `thinkingLevel`：沿用現況；費用敏感時可改 Low。必須記錄實際送出值。
3. 本機音檔：≥ 8 分鐘、中文為主、不進 Git。報告只寫時長與類型（例如「約 10 分鐘雙人對談」），不寫私人內容、不提交路徑到遠端文件。
4. 支出上限：使用者給出本次可接受上限。超過即停。
5. 授權範圍：只做本規格；不順便改產品預設、不開長音檔。

## 6. 允許的最小程式縫

為了讓 8–12 分鐘音檔**確定**能觸發 `CloudOutputTruncatedError`，實跑前允許加一條 **internal／驗證專用** 的轉錄 `maxOutputTokens` 覆寫，比照既有 `cloudAdaptiveMinimumChildDuration`：

1. Production convenience initializer 與正式 UI **不得**暴露此覆寫。
2. 未覆寫時必須仍是 `16384`。
3. 接縫維持 `internal` 或同等測試／驗證入口；不要為驗證擴大公開 API。
4. 不得連帶修改 240 秒最小子段或最大 split depth。
5. 此縫只為本規格服務，不得做成 0.2.0 的產品選項。

覆寫目標：**父段截斷、左右子段仍可能 `STOP`。**

- 不要從極低值（例如 5 或 64）起跳，以免子段也立刻截斷；2.5 分鐘子段低於 240 秒，無法再切，會變成 fail-closed。
- 建議從數百～約 1000 token 級開始，依第一次真實 `finishReason` 微調。
- 若覆寫後父段仍 `STOP`：只准對**同一音檔**調低上限再跑一次。
- 若父段截斷但子段也截斷並因此 fail-closed：只准對**同一音檔**調高上限再跑一次。
- 同一音檔最多 **兩個完整 job**（校正一次 + 正式一次）。禁止第三輪，禁止換 30 分鐘檔再賭。

沒有這條縫、又堅持 production 16384，則本規格的切段驗收視為無法保證執行；若實跑未觸發截斷，依第 9 節處理。

## 7. 必跑案例與通過條件

只要求一條主案例。Mock 已覆蓋的 fail-closed 不在本次付費範圍。

### 7.1 設定

- 音檔：本機 ≥ 8 分鐘（建議 8–12 分鐘）。
- 切段政策：production 240 秒、depth 2。
- Token：驗證覆寫（第 6 節），或在使用者明確拒絕覆寫時用 16384 並接受可能未觸發。
- 後端／模型／thinking：第 5 節確認值。

### 7.2 必須觀察到

1. 父段真實 `finishReason` 為 `MAX_TOKENS`（或後端正規化後同等截斷），並丟出 `CloudOutputTruncatedError`。
2. 日誌／warning 出現 `cloud_segment_split_max_tokens`。
3. 父段 partial text 若可取得，正式 TXT **不得**包含該截斷字串。
4. 左右子段真實 `STOP`（或 `GeminiTranscriptFinishReason.allowsUsableText` 為真的完成理由）。
5. 產生正式 TXT；`PipelineResult.containsSkippedAudio == false`。
6. `segment-manifest.json`：最終兩個完成子段，時間連續、無重疊、無缺口，`splitDepth == 1`，index／count 已重編號。
7. 請求順序為父 → 左 → 右；沒有重送已完成子段。
8. 記錄請求次數，以及費用或 token 用量（有多少記多少，沒有帳單數字就記請求次數與音訊時長，不得編造金額）。

### 7.3 不算通過

- 5 分鐘檔 `STOP`、沒切段。
- 父段 `MAX_TOKENS` 但因不足 8 分鐘而 fail-closed。
- 子段也截斷、無法再切、沒有正式 TXT。
- 只跑通 mock 或 CI。
- 正式稿混入父段截斷文字。

## 8. 證據怎麼寫

實跑後另寫報告，建議路徑：

`docs/real-gemini-adaptive-split-verification-YYYY-MM-DD.md`

報告必須有：

- 分支與 `git rev-parse HEAD`
- 後端、模型、location（若 Vertex）、thinkingLevel、實際 `maxOutputTokens`
- 音檔時長（秒）與是否達 480 秒切段門檻；不寫私人內容
- 各次請求的 `finishReason`
- 是否出現 `cloud_segment_split_max_tokens`
- 是否產生正式 TXT
- manifest 段數、各段 `start`／`end`／`splitDepth`／status
- 完整 job 次數（1 或 2）與請求次數
- 費用或用量；沒有帳單就寫「金額未取得」
- 結論：通過／未觸發／失敗

不得提交：

- 音檔、逐字稿全文、API Key、access token、含個人口語的 log dump

工作目錄與 Application Support 產物留在本機。Git 只收報告與必要的規格／NEXT_STEPS 更新。

## 9. 未觸發或中途失敗

據實停止，不要改規格來遷就單次結果。

| 情況 | 結論 |
|---|---|
| 父段 `STOP`，兩次 job 都未截斷 | **未觸發，驗證未完成**。記錄後端、模型、token 上限、finishReason。 |
| `SAFETY`／`OTHER`／429／認證失敗 | **失敗，驗證未完成**。記錄 HTTP／finishReason。不得改跑長檔硬闖。 |
| 父段截斷但子段截斷且無法再切 | **失敗**。記錄 split depth 與各段 finishReason。不得把 fail-closed 寫成切段成功。 |
| POSIX／傳輸錯誤 | **失敗**。這不是本規格要修的傳輸層；若重現 `docs/gemini-cloud-transport-hardening.md` 的問題，另外開單，不在本案例裡改切段秒數。 |

未完成時，`docs/reliability-v2-validation.md` 仍維持「真實環境待驗」。不得把部分成功寫成階段 1 已真實驗收。

## 10. 建議實作順序（實跑階段，非本檔寫作階段）

1. 使用者確認第 5 節。
2. 若需要第 6 節覆寫：最小 internal 接縫，不改 production 預設。本機檢查不因此失敗。
3. 同一 8–12 分鐘音檔最多兩個完整 job。
4. 寫第 8 節報告。
5. 通過後才更新 `docs/reliability-v2-validation.md`、`docs/NEXT_STEPS.md`、必要時 closeout；通過前只保持「待驗」。

本規格書本身不授權：合併主分支、打 Release、替換 `/Applications`、或開始付費呼叫。

## 11. 完成定義

### 11.1 規格書階段（本檔）

- [x] 本檔存在且狀態為待實作
- [x] 實跑尚未開始，未發送付費 API 請求

### 11.2 驗證階段（須另一次授權）

- [ ] 開工前完成第 5 節確認
- [ ] 音檔 ≥ 8 分鐘，切段政策為 production 240 秒／depth 2
- [ ] 觀察到真實父段 `MAX_TOKENS` 與 `cloud_segment_split_max_tokens`
- [ ] 左右子段真實 `STOP`，正式 TXT 不含父段截斷文字
- [ ] manifest 連續、無重疊、無缺口、`splitDepth == 1`
- [ ] 同一音檔不超過兩個完整 job
- [ ] 驗證報告已寫，且未把私人音檔／金鑰／全文提交進 Git
- [ ] 未把本次結果擴大解釋成 30／62 分鐘、speaker、GUI 或正式發佈已通過
