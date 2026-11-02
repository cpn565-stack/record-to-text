# 下一次接續

## 2026-10-30：App 與開發目錄無損精簡

保留全部功能。已安裝 App、dist App 及重新打包的 DMG 均沿用原 Build 17 的全部 11 個檔案，逐檔 SHA-256 一致；以 APFS 透明壓縮將 App 磁碟占用從 135.8 MiB 降至 63.9 MiB，檔案內容仍約 136 MiB。這次沒有重新編譯或納入較新的診斷修補，版本與執行檔雜湊維持下節 Build 17 紀錄。

開發目錄從約 1.4 GiB 降至約 228 MiB。編譯快取、舊 build 10／16 DMG 與三份舊 App 備份合計約 1,067 MiB 移至垃圾桶，可還原；清空垃圾桶後才釋放此部分空間。保留全部原始碼、測試、文件、歷史轉錄／復原證據、目前產物、模型及工作資料。runtime 音訊工具同樣只做無損壓縮，126.4 MiB → 60.9 MiB。

`build-app.sh` 預設在簽章後執行 `compact-app.sh`，可用 `COMPACT_APP=0` 關閉；`clean-development.py` 預設只預覽，`--apply` 才移到垃圾桶。清理拒絕 Git 追蹤內容，保留目前／較新 build 與其他版本；下次編譯會重建快取。

驗證：App 與掛載 DMG 的檔案內容、資源、權限、簽章通過；WAV、MP3、M4A、FLAC、OGG、MP4 → 16 kHz 單聲道 → 24 kbps MP3 及靜音偵測通過；編解碼器、filter、format、protocol 清單不變；四份 Python helper 可解析。正常退出／重開後 19 筆工作身分與狀態保留（12 完成、5 失敗、2 中斷），未自動送出工作。清理腳本的預覽、受追蹤檔案保護及資料保留以暫存 fixture 驗證；未使用私人音訊或真實 Google API。

目前 DMG SHA-256：`2bf38522ae423262b017c32545846526428982f45d5148f69db70341985576bf`。空間、備份位置與驗證紀錄：`dist/footprint-2026-10-30.json`。下節較早的 DMG 雜湊與備份路徑屬歷史紀錄。

## 2026-10-29：AI Studio 空回應復原實作交接

目前分支 `codex/ai-studio-empty-response-recovery` 接續 [AI Studio 空回應復原與雲端診斷規格](ai-studio-empty-response-recovery-spec-2026-10-29.md)，工作樹為 0.2.1（17），變更尚未提交。AI Studio 明確 STOP 但正文空白時，沿用同一模型與已準備音訊，在既有每片段／模型最多 4 次的實際生成額度及原 root deadline 內重試；網路／限流與空 STOP 共用額度。安全攔截與 OTHER 不走空結果重試。增加生成回應的固定代碼診斷、失敗後續跑與費用估算提示；回應未知代碼顯示 UNKNOWN，錯誤與日誌避免顯示服務自由文字，包含部分引用背景的 HTTP 錯誤。未發送真實音訊或 Google API。

2026-10-29 驗證與建置：`SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh` 通過，Swift 592 項、1 項因未提供本機模型與音訊 smoke-test 參數而跳過、0 失敗；Python 134 項、72 項 self-test、10 個 pipeline 情境通過。Swift release 編譯與 `scripts/verify-release.sh` 通過，App 為 ad-hoc 簽章的 Apple Silicon 測試版，DMG 未公證。Build 17：`dist/record-to-text.app`、`dist/record-to-text-0.2.1-build17-development.dmg` 及 `.sha256`；App 執行檔 SHA-256 `e91f70f4bfbaa15a404476d0b0875bda3995d325b975616e2fe44f1732d486e8`，DMG SHA-256 `6c868f3b5e19f7f2d515ae6e548bba8e938c907597613073bd2b70e69e896480`。原 dist Build 16 備份在 `dist/install-backups/before-ai-studio-build17-20261029.noindex/record-to-text.app`；依使用者要求已正常退出舊版並安裝、啟動 `/Applications/record-to-text.app` Build 17；安裝後執行檔雜湊與 dist 一致、簽章驗證通過。原安裝版 Build 16 在 `dist/install-backups/installed-before-build17-20261029.noindex/record-to-text.app`。升級前後 journal 均為 22 筆（10 完成、10 失敗、2 中斷），未自動啟動工作。未執行真實模型 smoke test，也未呼叫真實 Google API。

原錄音背景驗收仍有完整背景回吐漏擋，以及重複檔案確認期間切換後端的狀態一致性待處理；Vertex 活躍串流的 300 秒請求期限亦屬獨立待辦。上述問題未隨本版全部修復，實際內容攔截是否發生仍由 Google 決定。背景對辨識品質的 A/B 仍未完成。

## 2026-10-29：AI Studio 空回應復原規格

[AI Studio 空回應復原與雲端診斷補強規格](ai-studio-empty-response-recovery-spec-2026-10-29.md) 已撰寫；後續實作狀態見上節。必要性列 P1，建議下一個維護版完成「明確空 STOP 的有限重試＋unary JSON 原因代碼＋錯誤摘要」。沿用每 segment/model 最多 4 次實際生成及原 root budget；網路、429、空結果共用額度，明確 Google 攔截不重試。規格包含 T01–T15 驗收、資料相容性、費用估算界線及隱私要求。代理 SSE、合蓋提示、來源失效與 Vertex 活躍串流 300 秒期限分開立案。

## 2026-10-29：最近雲端執行錯誤分類

已核對本機 journal／recovery、安裝版及系統睡眠紀錄，見 [10/28–29 調查](cloud-run-diagnosis-2026-10-29.md)。截至 13:58 的保留資料，去除沿用與終止摘要重複後有 19 次異常操作：8 次 Google prompt 攔截、5 次空回應、4 次同片段代理路徑斷線、1 次睡眠期間上傳初始化逾時、1 次來源路徑失效。這不是完整失敗率；歷史成功清單只有 10 筆。

確認 App 既有缺口：AI Studio 空 STOP 被歸為一般 emptyResponse 而直接停止，Vertex 同型結果則有重試；unary JSON 的 finishReason 也未寫入結構化診斷。相關兩項既有離線測試通過，尚未修改程式或安裝版本。多份 Google 攔截工作背景為空，不能歸因為新增背景功能的普遍回歸。長達近一小時的等待已對上合蓋／DarkWake，該工作之後續跑三段完整成功；不是 Google 連續推論近一小時。優先補 AI Studio 空 STOP 復原與診斷，再評估代理／串流相容性。

## 2026-10-24：Vertex SAFETY 攔截調查

兩份 Vertex `gemini-3.8-flash` 錄音均在第 2 段收到 Google `promptFeedback.blockReason=SAFETY`；第 1、3 段及復原檢查點保留。安全設定與 Flash 的 300 秒請求期限均未在 build 16 改變，但兩份工作都有相同的非空背景，尚無真實有／無背景對照可排除提示影響。調查細節與重送界線見 [調查紀錄](vertex-safety-diagnosis-2026-10-24.md)。

已修正複製診斷只寫「完成」而遺失 `hasGaps` 標籤的顯示問題，改為「完成（含缺口）」，涵蓋工作及最近工作。相關 20 項 XCTest 通過，0 跳過、0 失敗；本輪未重建安裝包、重啟 App 或發送 Google API 請求。此修正與測試／文件仍在工作樹。

後續兩份成功案例補充：皆為三段完整 `STOP`，沒有安全缺口。其一第一次請求在 291.79 秒開始回傳正式文字，卻在 300.60 秒被 App 固定期限取消（已收到 133 個 SSE 事件），重送後成功。這確認既有 Flash 300 秒單次期限會中止仍有進度的 Vertex 串流，與 Google `SAFETY` 為不同問題；不是 build 16 才新增的期限。等待策略尚未修改，詳見調查紀錄。成功工作摘要未保存背景，不能推定四份背景皆相同。

第三次回報再增加兩份完整成功：一份兩段各一次成功；另一份第 1 段先收到 HTTP 429，冷卻 35.87 秒後同模型重送成功，後兩段也完成。這次是服務端限流／容量或配額相關拒絕，現有冷卻機制正常處理，沒有安全缺口或 300 秒逾時。六份累計 17 段、15 完成／2 安全攔截，20 次生成發送（另含 2 次逾時重送及 1 次 429 重送）。新增紀錄只做唯讀核對與文件更新，未重送或修改等待政策。

第四次回報的第七份錄音：第 2 段第一次為 `STOP` 但正文為空，短暫等待後同模型重試成功；第 3 段另被 `SAFETY` 攔截，缺少最後約 5 分 25 秒，第 1、2 段文字與復原檢查點仍在。空回應／thought／串流累積相關 4 項既有測試通過；原始 SSE 未保存，僅能說目前未發現 parser 回歸證據。七份累計 20 段、17 完成／3 安全攔截，24 次生成發送（2 逾時、1 次 429、1 次空回應的重送）。本輪未修改轉錄程式或安裝版本。

兩個缺口工作手動重送後仍為 `SAFETY`：本次各只發送缺段，先在約 7 秒出現 `-1005`（記錄 `h3`），等待約 20 秒重建 session 後以 `h2` 收到新的 Google 攔截回應。snapshot 與原工作相同，完成片段確實沿用；歷史錯誤／用量統計包含前次資料，不能視為本輪新增費用。沒有 300 秒逾時，不宜再盲目同條件重送。已在本機 `Repair-Exports/blocked-segments-20261024-xcg8i7pz/` 準備約 5 分 25 秒及 19 分 59 秒兩個缺口 WAV，附時間偏移 manifest；來源雜湊未變，尚未辨識／合併／上傳。完整資訊見調查紀錄的「相同設定手動重送後仍攔截」。

AI Studio 對照更新：錄音 B 的三段一次完成，原本 Vertex 反覆被擋的第 2 段在 AI Studio 成功；錄音 G 則前兩段完成、第 3 段回傳 HTTP 200、`promptFeedback.blockReason=OTHER`，缺最後約 5 分 25 秒。`OTHER` 是 Google 未提供具體原因的攔截，App 依既有規則列為失敗、保留兩個完成檢查點，不能冒稱明確安全政策或完整成功。G 兩份 snapshot 的提示、詞庫、背景均不同（77／83 scalars），不是 backend 單變因對照；不能再泛稱 AI Studio 一定能解決或只屬 Vertex 問題。詳見調查紀錄的「AI Studio 對照：一份完整，一份仍失敗」。本輪未上傳、重送或更動失敗規則。

## 2026-10-23：雲端錄音背景 build 16

[雲端轉錄錄音背景規格](cloud-recording-context-spec-2026-10-23.md) 已在分支 `codex/cloud-recording-context` 實作並提交為 `7bd8021`。可留空的雲端背景在加入佇列時寫入 snapshot；分段、重試與續跑沿用原背景，只有「使用目前設定」重建才捕捉新草稿，本機不套用。回吐檢查在 Markdown 清理前比對原始背景包裝；錯誤與診斷會先拿掉背景原文。

`SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh` 於 2026-10-23 22:10 通過：Swift 568 項、1 項預設跳過、0 失敗，含 Python、self-test 與 10 個 pipeline 情境。已以 Apple Silicon release、ad-hoc 簽章安裝 `/Applications/record-to-text.app` 0.2.1（16）。執行檔 SHA-256 `cf2b10c86ba440f3598a84ad14af0339fbd71f6e2e0e897b12cf8a2ce7768457`，與 `dist/record-to-text.app` 一致。測試包為 `dist/record-to-text-0.2.1-build16-development.dmg`，DMG 未用 Developer ID 簽署，不是公證發行版。build 15 備份在 `dist/install-backups/before-recording-context-build16-20261023.noindex/record-to-text.app`。未做規格第 11 節的音訊 A/B，不能把功能可用說成辨識變準。

2026-10-24 重新執行 `SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh` 通過：Python 134 項、Swift 568 項（1 項本機模型 smoke test 因未提供素材而跳過）、self-test 72 項、10 個 pipeline 情境，0 失敗；`git diff --check` 亦通過。本輪跳過 App bundle 建置，沒有重裝或新增測試包。追加的請求攔截斷言確認兩個雲端 backend 的 429 重試及 AI Studio 網路重試沿用相同背景。仍未呼叫真實 Google API 或執行錄音 A/B。

## 2026-10-17：build 14–15 Vertex 串流回應實作與 thinking 期間保活修正

已依 [Vertex AI 串流回應修復規格](vertex-streaming-response-spec-2026-10-17.md) 完成實作（build 14），並針對真實 20 分鐘訪談錄音在 `gemini-4-argon`／`gemini-3.8-flash`（`thinkingLevel=high`）深度思考階段可能長達 80–130 秒、導致本機代理（如 `127.0.0.1:7890`）因約 60 秒無回應位元組而主動斷線（`NSURLErrorDomain -1005`）的問題，在 build 15 為 Vertex SSE 請求啟用 `thinkingConfig.includeThoughts = true`。

實測確認啟用 `includeThoughts = true` 後，Vertex `:streamGenerateContent?alt=sse` 會在請求上傳完成後約 2–5 秒即回傳 HTTP 200 並每 3–4 秒持續送出 `thought: true` SSE 事件，使連線在整個思考階段保持活躍，不再觸發代理 60 秒閒置斷線；`GeminiStreamingResponseAccumulator` 仍嚴格過濾所有 `thought: true` 與 `thoughtSignature`，不進入逐字稿、日誌或持久化，且 `firstResponseByteSeconds` 與 `firstTextDeltaSeconds` 分別精準記錄首個回應位元組與首個實際逐字稿文字片段時間。S01–S16 全部 16 項測試、59 項相關單元測試及 72 項 self-test 均通過，已打包並安裝 `/Applications/record-to-text.app` 0.2.1（15）。

## 2026-10-17：build 13 重試操作與功能檢視

網路失敗後固定等 20 秒，加入「立刻重試」及逐秒倒數；手動跳過等待不增加工作、不重複發送、不重設發送次數或期限，取消仍優先。日誌區分網路／服務等待與模型回應。AI Studio／Vertex 的自訂模型選單也已修正：可由預設切入，輸入完成後套用一次，空白草稿不改動設定或排隊工作。

完整檢查 Swift 527 項（1 項預設跳過、0 失敗）、Python 134 項、self-test 72 項、pipeline 10 個情境通過；模型選單修改後相關 54 項測試及隔離 AppKit 實際操作通過。已安裝並開啟 `/Applications/record-to-text.app` 0.2.1（13），保留設定及 14 筆工作狀態，沒有自動開始排隊工作；build 12 已封存。未新增真實 Google API 轉錄驗證。

後續優先序：測試所選模型的可用性 → 可選較短音訊分段 → 按實際模型／思考 token 修正成本估算 → 顯示目前 App 路徑。這些建議尚未實作，詳見[功能檢視與驗證紀錄](functional-review-2026-10-17.md)。

## 2026-10-15：build 12 Gemini 4 Argon

使用者指定只新增模型，沿用既有逐字稿格式。設定與主視窗加入 Argon，送出實際思考強度，直接非串流 REST 採 32,768 輸出上限；單次推論 20 分鐘／原始音訊段共用 30 分鐘期限。保留現有分段、截斷處理與清理，不加入 JSON 或摘要。詳見 [Argon 支援紀錄](gemini-4-argon-support-2026-10-15.md)。

完整檢查通過（Swift 522 項、1 項預設跳過、0 失敗；Python 134 項、72 項 self-test、10 個 pipeline 情境），快速選單追加驗證 12 項通過。已安裝並開啟 `/Applications/record-to-text.app` build 12，保留原設定、工作與 build 11 備份；未做真實 Google API 辨識或帳號權限驗證。

## 2026-10-13：build 11 本機模型驗證修正

修正 checkpoint 的模型驗證漏用 `Models/hub`，以及 Hugging Face snapshot 符號連結被跳過的問題；未解析的連結拒絕產生 manifest，取消驗證仍視為取消。原「找不到 snapshot」訊息只停用跨次續跑，與工作取消分開判讀。模型已在本機，不需重新下載。

驗證：相關111個 Swift 測試通過；真實模型的12秒音訊，經隔離的完整本機 pipeline、兩個6秒段及文字輸出離線測試通過。未重跑完整長錄音。版本0.2.1（11），詳見[本機模型驗證修正](local-model-cache-fix-2026-10-13.md)。

已依使用者要求，在原轉錄完成後更新 `/Applications/record-to-text.app` 並重開 build 11；既有工作與完成紀錄保留，build 10 已封存備份。

## 2026-10-08：build 10 主視窗拖放

錄音檔現在可拖到主視窗內容區的標題、工作佇列與四周空白，不必對準錄音框；文字輸入框依使用者要求保留原生編輯與拖拉行為。拖入時顯示視窗邊框與放開提示，錄音框文案更新為「將錄音拖入視窗」。沿用原有檔案格式檢查、重複檔案確認與手動開始流程。

驗證：完整檢查通過 Swift 514 tests、Python 134 tests、executable self-test 與 10 個 pipeline 情境。使用隔離 AppViewModel／憑證存放器的 AppKit 實際拖放，確認標題、工作佇列、左右及底部空白可加入檔案，加入後不會自動開始；文字輸入框保留檔案路徑與純文字的原生拖放處理。

版本為 0.2.1／build 10，Apple Silicon release 組態、ad-hoc 簽章；安裝包為 `dist/record-to-text-0.2.1-build10-development.dmg` 及對應 `.sha256`，沿用既有本機測試包交付方式。

## 2026-09-27：build 9 退出儲存修正

已修正 Keychain 載入阻擋一般工作紀錄儲存，以及取消退出後無法再啟動佇列的問題；取消退出也不會使之前等待儲存的雲端重送自動復活。保留舊憑證遷移與損壞 journal 的防覆寫保護，退出錯誤改為顯示實際原因。驗證紀錄見[修正與發佈界線](quit-persistence-fix-2026-09-27.md)。

完整驗證通過 Swift 514／Python 134 tests。本機 App 已更新為 0.2.1／build 9，已產出 `dist/record-to-text-0.2.1-build9-development.dmg` 與核對碼；build 8 保留於 `.noindex` 備份資料夾，使用者 journal 未更動。本機缺少 Developer ID Application 憑證，這是未公證測試包，不宣稱完成 Stable 發佈。Qwen 階段 2／3 與真實模型 A/B 仍未完成。

## 2026-09-27：Qwen 地端新規格

最新本機強化規劃見 [四階段規格入口](qwen-local-roadmap-spec-2026-09-27.md)。依序為「音訊身分驗證＋實際切塊起訖紀錄」→「靜音感知切點」→「段級續跑」→「token 缺口保留與補稿」。

**功能進度：階段 0／1／1.1 已實作。以下是 build 8 的驗證與安裝紀錄；後續 build 9 退出修正見上一節。**
`SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh` 全綠：Swift 506 tests／0 failures／0 skipped，Python 134 tests。階段 1 審查列出的 F1–F5 已修正，另修掉兩個審查未列出的 P1（非零切片的 `identity.json` 自己讀不回來、`checkpointCommitted` 被當成 `invalid_jsonl` 而使任何走真實 backend 的 v2 執行中止）。證據見[階段 1.1 交付說明](qwen-local-01-hardening-delivery-2026-09-27.md)。

獨立審查後已補上持久化整數的跨語言驗證：Swift 拒絕整數欄位中的浮點／指數表示，Python 拒絕 Int64 溢位；新增一個 XCTest，讓兩邊 production loader 讀取同一批 113 份檔案並比對判定與錯誤碼。詳見交付說明 §1.4。

本機安裝使用 release 設定建置 arm64 App；dist 與 `/Applications/record-to-text.app` 的執行檔 SHA-256 一致，封裝內容、體積與 ad-hoc 簽章已驗證。原 build 7 保留於 `dist/install-backups/before-qwen-phase1-build8-20260927/`。本機 Python runtime 可載入 `mlx_audio`，但尚未執行真實模型 A/B。安裝紀錄見交付說明 §6。

**下一步有兩條彼此獨立的路：**

1. **階段 2（段級續跑與前處理跳過）**：規格已備，可直接重用階段 1.1 的
   `VerifiedLocalSilence.validate` 與「續跑絕不重算已凍結邊界」前提。
2. **階段 1 的真實模型 A/B 與預設放行**：本機 `mlx_audio` 已可載入；仍需已授權素材與
   人工核對每個被移動切點前後 ±5 秒。在此之前功能維持「進階設定可主動開啟、
   新工作預設關閉」，**不可**改成預設開啟，也不可宣稱切點品質已改善。

以下保留 2026-08-30 的歷史接續清單與當時驗證紀錄，不代表新四階段已完成。

更新日期：2026-08-30
基準 commit：`9c21834`（`codex/record-to-text-reliability-v2`）
目前 checkpoint：**0.2.0 / Reliability v2 自動化收尾完成** — 仍不是可交付一般使用者的 Stable DMG。

全盤優化與後續優先序見 [`post-0.2-optimization-spec-2026-08-30.md`](post-0.2-optimization-spec-2026-08-30.md)。

---

## 已完成（目前 reliability-v2 分支具備）

### 長錄音與 token 防護

- PD-013：coordinator 以 **1,200 秒（20 分鐘）** 預切；每段 ASR **`maximumTokens=16384`**。
- Helper 內部預設 **120 秒** chunk；滿 token 遞迴對半切，最短約 **30 秒**。
- 不可再切的 leaf 達上限：明確**缺口標記**，不把截斷文字當成功；一般錯誤仍 fail-closed。
- 失敗時保留 `partial-transcript.txt` 救援草稿；正式 TXT 仍須全段通過 gate。
- Segment manifest、31／65／120 分鐘 planner fixture、mock 管線 fail-closed 測試通過。
- 本機真實 Metal／Qwen3-ASR：短檔、約 26 分整檔、長會手動切兩段等路徑已跑通（見 `docs/real-metal-verification-2026-08-01.md`、`docs/handoff-sol-2026-08-02.md`）。

### 長駐 helper 與輸出品質

- 長駐 session 使用 **compact 單行 JSON（JSONL）**，修正 pretty JSON 造成的早期 `JSONDecodeError`。
- 同一 job 內重用 Python／MLX helper 與 model cache。
- 輸出尾端 **Prompt echo** 以 `remove_prompt_echo()` 清除。
- Chunk 規劃抽成 `qwen_asr_chunking.py` + 單元測試。

### Job ledger、復原、取消

- PD-014：durable work 不受 `recentJobLimit` 裁切；completed 不進 ledger。
- `RecoveryScanner`：啟動／手動掃描；刪孤立／損壞；可復原可重新加入來源（不自動刪、不刪原文／正式 TXT）。
- `ProcessRunner`：launch 前取消 race；`setpgid` + process group 終止。

### 產品 UX（Phase 0）

- 模型選擇含 BF16；下載／匯入本機模型。
- 預設輸出後綴 `_逐字稿`；手動「開始轉文字」（無自動開始）。
- 連續進度列、刪除已完成工作、About（版本／build／分段與 token 政策）。
- 圓形 App 圖示；README 環境需求說明。

### 驗證門檻（自動化）

- `scripts/run-checks.sh`：Python tests、executable self-tests、pipeline self-tests。
- 完整 XCTest 需本機／CI 完整 Xcode（CLTs 環境會 SKIP）。

---

## 已完成（2026-08-02）

| # | 項目 | 實作結果 |
|---|------|------|
| 1 | **Timeout／inactivity watchdog** | ProcessRunner 支援絕對 timeout 與 inactivity timeout；ffprobe、ffmpeg、OpenCC、ASR helper 已接入。 |
| 2 | **磁碟空間檢查** | 轉錄前同時檢查暫存 volume 與實際輸出 volume，並保留安全餘裕。 |
| 3 | **最近工作檔案狀態** | 最近工作會標示來源／輸出檔案已移動或刪除；既有 ledger、terminal history 與日誌裁切策略維持不變。 |
| 4 | **模型載入生命週期** | 同一 App 佇列重用 engine／長駐 helper；相同 model revision 命中 Python cache 時跳過重載，並新增技術日誌可辨識 cache hit。 |
| 6 | **輸出契約再驗證** | 新增 final output contract，檢查 BOM、NUL、Prompt echo，並在 segment、merge、OpenCC 後再次驗證。 |
| 7 | **手動 TXT 合併** | 可選取多份 TXT，依分段編號排序合併成新檔；原始檔案不覆寫，後續 LLM 可直接使用。 |
| 15 | **前端等分切片佇列** | 錄音加入佇列後，可在「開始轉文字」旁將單一來源切成前後兩個時間範圍工作；第一段先處理，第二段留在佇列，各自產生有順序的 TXT。 |

## 已完成（2026-08-28，Reliability v2 Phase 4–6）

| 階段 | 結果 |
|---|---|
| **4 啟動效能與復原 UX（P1）** | 模型快取與 RecoveryScanner 改在 utility-priority 背景任務執行；加入取消／generation gate，避免舊結果覆蓋新選擇；復原畫面顯示掃描中與完成時間。 |
| **5 CI、版本、安裝與交付（P1）** | `Config/version.env` 成為單一版本來源；CI 避免重複 App bundle 建置，強制 150 MiB 體積門檻，產生未簽署測試 DMG 與 SHA-256 artifact。 |
| **6 架構整理、repo 清理、體積（P2）** | 啟動盤點邏輯抽成 `StartupInventory`；移除一次性 Gemini patcher；SwiftPM 改為明確打包 3 支 helper，防止 `__pycache__` 進入 App；加入 repo hygiene 與建置體積 gate。 |

## 已完成（2026-08-29，Reliability v2 自動化收尾）

| 項目 | 結果 |
|---|---|
| **工作 1：恢復完整 XCTest CI** | `1d6870c` 修正 optional XCTest 編譯；GitHub Actions Run `33251816818` 通過 175 項 XCTest。 |
| **工作 2：MAX_TOKENS 自適應切段整合測試** | `fdeaef9`、`a3ac87d`、`9c21834` 直接以 `TranscriptionEngine.run` 驗證父段截斷後子段成功、非重試錯誤與最大深度 fail-closed。 |
| **目前完整 CI** | 工作 2：`9c21834`／Run `33263989282`；docs-only 收尾：`30153df`／Run `33264569435`。兩者均通過 178 項 XCTest、development DMG、App bundle 驗證與 artifact 上傳。 |

以上是自動化、決定性證據；沒有呼叫真實 Google API，也沒有取代真實長音或 GUI 驗收。

## 驗證待辦（程式已實作，不等於尚未做）

| 項目 | 尚缺證據 |
|---|---|
| **真實 Gemini 自適應切段** | 以受控 **≥ 8 分鐘**（建議 8–12 分鐘）音檔驗證真實 AI Studio／Vertex `MAX_TOKENS`、子段 `STOP`、segment coverage 與成本。5 分鐘檔不夠測 production 240 秒最小子段。規格見 [`real-gemini-adaptive-split-spec-2026-08-30.md`](real-gemini-adaptive-split-spec-2026-08-30.md)（待實作）。 |
| **Speaker roster** | 30 分鐘多人錄音、相似姓名、中途加入第三位講者，確認 heuristic 不會錯併。 |
| **Qwen soak／復原** | 30 分鐘與原 173 分鐘 BF16；timeout restart、手動 chunk resume、成功後 recovery cleanup。 |
| **GUI／輔助使用** | 真實 active cloud job 的 90% 進度、High Contrast、Reduce Motion、recovery scan／resume／取消。 |
| **效能量測** | engine／helper reuse 的耗時、記憶體與 `Fetching 11 files` 前後比較。 |

## 待修改／尚未做（優先序）

### P2 — 產品規劃已定、程式未做

| # | 項目 | 說明 |
|---|------|------|
| 5 | **PD-015 自動檢查更新** | 預設約每 7 天查 GitHub Releases；有新版再提示；設定內手動檢查；只檢查＋引導下載。細節見下方。 |

### P3 — 外部／發佈條件（Blocked 或需資源）

| # | 項目 | 說明 |
|---|------|------|
| 8 | **App 管理 Runtime installer** | 免 Homebrew／自架 Python；簽章信任鏈、digest；乾淨 Mac 一鍵可用。 |
| 9 | **模型 installer 與 digest 驗證** | 正式 installer；固定 revision＋digest（PD-010 完整落地）。 |
| 10 | **Intel 實機** | PD-005：Experimental／Blocked；x86_64 Runtime + 真機轉錄前不得宣稱支援。 |
| 11 | **Universal 2** | arm64 + x86_64 正式建置與驗收。 |
| 12 | **Developer ID、公證、Stable DMG** | 簽署、notarization、乾淨帳號首次啟動、正式發佈流程。 |
| 14 | **品牌／商標** | PD-012：公開名稱不以 Qwen 暗示官方關係；發佈前品牌檢視。 |

---

## 規劃細節：自動檢查更新（PD-015）

- **間隔**：約 7 天（可關／每天／每週）。
- **時機**：啟動後且超過間隔；背景安靜、不擋佇列。
- **有新版**：非阻斷提示；顯示版號與 Release 摘要；使用者決定是否開下載頁。
- **失敗／離線**：安靜失敗或只在設定顯示上次檢查時間。
- **手動**：「立即檢查更新」。
- **來源**：GitHub Releases；Stable 與 prerelease 策略分開。
- **範圍**：App 更新 ≠ 模型重下；模型仍走 Models 流程。
- **依賴**：較適合有正式 Release 流程後上線；Phase 0 可先 stub／週期邏輯。

---

## 明確不做或暫緩

- **Intel 當一等公民**：完成前保持 Blocked／Experimental 標示。
- **把 Developer Mode 偷偷當正式 Runtime**：未就緒須 fail-closed 提示。
- **未確認就 reset／重寫** 大量已驗證的 ASR 正確性路徑。

---

## 建議下一輪開工順序

1. 受控真實 Gemini `MAX_TOKENS` 與 segment coverage 回歸（規格：`docs/real-gemini-adaptive-split-spec-2026-08-30.md`，待實作；尚未授權付費呼叫）
2. 30 分鐘多人 speaker roster 與 30／173 分鐘 Qwen soak
3. 真實 active cloud job、High Contrast、Reduce Motion 與 recovery cleanup GUI 驗收
4. PD-015 自動檢查更新
5. Runtime installer／簽署／公證（P3，與產品發佈時程綁定）
