# record-to-text 0.2 後續全盤優化規格

狀態：Ready for staged implementation
日期：2026-08-30
適用分支：`codex/record-to-text-reliability-v2`
審查基準：`662835b10bfc71f29efba612086cc3201bc0a8d0`
產品版本：`0.2.0 (1)`

## 1. 結論

目前版本可繼續作為開發／受控測試版使用，但仍不適合標示為一般使用者可直接安裝的 Stable release。

工作 1–3 已收尾：

- `MAX_TOKENS`、子段錯誤與最大切段深度均有 `TranscriptionEngine.run` 整合測試。
- 最新基準 CI Run `33289746434` 對 `662835b` 執行 178 項 XCTest，0 failures。
- development DMG、App bundle 驗證與 artifact 上傳均通過。
- 本機與遠端分支 SHA 一致，審查開始時工作樹乾淨。

下一階段不應先擴大功能，而應依序補齊真實環境證據、隱私與清理保護、正式 Runtime／模型信任鏈，再做產品擴充與架構整理。

## 2. 本規格的授權邊界

本文件只定義後續工作，不授權：

- 發送付費 Gemini／Vertex API 請求。
- 使用、移動或刪除私人錄音與逐字稿。
- 刪除現有 Temp-Recovery／模型快取。
- 替換 `/Applications/record-to-text.app`。
- 合併 `main`、建立 GitHub Release、簽署或公證。
- 將驗證用 token 上限、測試接縫或除錯開關暴露成正式產品設定。

上述動作必須另取得明確授權。

## 3. 審查方法與證據邊界

本輪檢查：

- Swift Core、SwiftUI、Python helper、Runtime schema、CI／release scripts。
- 現有 178 項 XCTest、70 項 executable self-test、10 條 mock pipeline 的覆蓋範圍。
- `NEXT_STEPS`、產品決策、Reliability v2 validation、歷史 handoff。
- Google 官方 Gemini 模型／退役文件與 GitHub 官方 Actions 版本資訊。

本輪沒有執行：

- 真實 Gemini／Vertex 轉錄。
- 真實 30／173 分鐘 Qwen soak。
- Intel、Universal 2、Developer ID、notarization。
- High Contrast、Reduce Motion、VoiceOver 與真實 active cloud job 全流程。

因此本規格把內容分為：

- **已確認缺口**：目前程式／文件可直接證明缺少。
- **需實測風險**：程式已有保護，但缺少真實環境證據。
- **研究型優化**：可能有價值，未達成 A/B 門檻前不得取代現行路徑。

## 4. 已確認基線與不應重做的項目

### 4.1 已有的模型重用不可重寫

- Swift 會在相同 `ResolvedRuntime` 下重用 `TranscriptionEngine`：`Sources/RecordToTextApp/AppViewModel.swift:1711`。
- MLX helper 使用 persistent JSONL session：`Sources/RecordToTextCore/ASRBackend.swift:678`。
- Python 在相同 model ID／revision 下重用記憶體模型：`Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py:325`。

較早版本曾出現每段 `Fetching 11 files`。目前程式已具備 cache，不得先重寫載入架構；下一步應量測目前版本是否仍重複抓取／載入，以及 cache hit 對耗時與記憶體的實際影響。

### 4.2 遠端音檔已有 best-effort 清理

- AI Studio Files API 成功／失敗／取消後會嘗試 DELETE：`GoogleAIStudioBackend.swift:395`、`:831`。
- Vertex GCS 成功／失敗／取消後會嘗試 DELETE：`VertexAIGeminiBackend.swift:176`、`:884`。

缺口不是「完全沒清理」，而是 DELETE 失敗後只有 warning，沒有耐久重試紀錄。後續應補 cleanup debt ledger，不應重做上傳流程。

### 4.3 啟動盤點已移出主執行緒

- 模型快取盤點使用 utility-priority detached task：`AppViewModel.swift:663`。
- RecoveryScanner 盤點使用 utility-priority detached task：`AppViewModel.swift:1530`。

不再把舊的「啟動 Task 仍在 MainActor」當成目前缺陷。只在 Instruments 顯示新的主執行緒停頓時才另案處理。

### 4.4 現有模型 ID 目前沒有立即退役警報

Google 官方在 2026-08-26 的 deprecation 表中，`gemini-3.7-flash`、`gemini-3.6-flash` 與 `gemini-3.1-pro-preview` 都尚未公告 shutdown 日期。這不代表 preview 模型可永久依賴，仍需要模型生命週期保護。

官方參考：

- <https://ai.google.dev/gemini-api/docs/models>
- <https://ai.google.dev/gemini-api/docs/deprecations>

## 5. 優先序總表

| 優先序 | ID | 項目 | 類型 | 使用者影響 |
|---|---|---|---|---|
| P0 | E1 | 真實 Gemini 自適應切段驗證 | 實測 | 確認長音截斷不會漏稿 |
| P0 | E2 | Qwen 30／173 分鐘 soak 與 cache 效能量測 | 實測 | 確認長會議穩定、可續跑且不重載 |
| P0 | E3 | 真實 active cloud／復原／輔助使用驗收 | 實測 | 確認 UI 狀態、取消、續跑真的可用 |
| P1 | R1 | 遠端暫存檔 cleanup debt ledger | 可靠性／隱私 | 避免 Files API／GCS 音檔長期殘留 |
| P1 | R2 | 可安全分享的除錯資訊 | 隱私 | 避免分享本機路徑與敏感 log |
| P1 | R3 | Recovery 容量、日期與保留政策 | 資料治理 | 避免復原資料無限累積或誤刪 |
| P1 | D1 | 正式 Runtime／模型信任鏈 | 發布阻塞 | 讓乾淨 Mac 不靠 Homebrew 也能安全使用 |
| P2 | C1 | 雲端模型能力矩陣與 token 策略 | 成本／完整性 | 降低不必要切段與模型退役風險 |
| P2 | C2 | Gemini 3.5 Transcribe A/B spike | 研究 | 評估專有名詞、講者、時間戳是否更佳 |
| P2 | Q1 | CI Actions 更新、測試隔離與 coverage | 工程品質 | 降低 CI 警告、flaky test 與未覆蓋風險 |
| P3 | M1 | 協調器／ViewModel 模組化 | 維護性 | 降低後續修改互相牽連 |
| P3 | U1 | PD-015 自動檢查更新 | 產品 | 使用者可知道有新版；須晚於簽署流程 |

## 6. P0：先補真實環境證據

### E1：真實 Gemini 自適應切段驗證

直接沿用：

`docs/real-gemini-adaptive-split-spec-2026-08-30.md`

附加要求：

1. 開始前由使用者確認後端、模型、音檔與支出上限。
2. 只跑一條雲端後端，不同時測 AI Studio 與 Vertex。
3. 音檔不得進 Git；報告不得保存全文、金鑰或私人路徑。
4. 驗證用 `maxOutputTokens` 覆寫只能是 internal，不改 production 預設 16384。
5. 必須觀察父段真實 `MAX_TOKENS`、warning、左右子段真實 `STOP`、正式稿無父段 partial、manifest 無重疊／缺口。
6. 同一音檔最多兩個完整 job；未觸發就如實記錄，不換更長音檔硬闖。

驗收：

- 產出 `docs/real-gemini-adaptive-split-verification-YYYY-MM-DD.md`。
- 結論只能是「通過／未觸發／失敗」。
- 成功後仍不得擴大宣稱 30／62 分鐘、speaker、GUI 或 Stable release 已通過。

### E2：Qwen soak 與模型重用量測

目的：確認 current persistent helper／model cache 的真實效果，而不是憑舊 log 推論仍會重載。

測試順序：

1. 5 分鐘 smoke，確認環境與輸出契約。
2. 30 分鐘 BF16，記錄首次模型載入與後續 coordinator segment cache hit。
3. 人工中止後從 chunk checkpoint 續跑，確認不重做已完成 chunk。
4. 原 173 分鐘錄音 soak；若 30 分鐘未通過，不得開始。
5. 模擬 helper timeout／重啟，確認 process tree 終止、session recycle 與 resume。

必記指標：

- 每個 coordinator segment 的開始／完成時間。
- `模型快取命中`／`未命中` 次數。
- `Fetching 11 files` 次數。
- 首次與後續段的 real-time factor。
- 峰值記憶體、App／helper PID、是否發生 swap 或 memory pressure。
- 取消延遲、重啟時間、重用 chunk 數量。
- 最終字數、缺口 marker、來源與輸出時長 coverage。

驗收：

- 30 分鐘與 173 分鐘各有獨立報告。
- 同 model/revision 的後續段不得重新載入整個模型；若仍發生，先定位 session recycle 原因。
- timeout／取消後不得留有運行中的 helper 子程序。
- 續跑不得重送已完成 chunk，正式稿順序完整。

### E3：真實 GUI／復原／輔助使用矩陣

必測狀態：

- 空佇列、等待中、active、取消中、失敗、完成、有 safety gap、可 resume。
- 轉錄設定摺疊／展開。
- 最小 760-point 寬度與一般寬度。
- 淺色、深色、High Contrast、Reduce Motion。
- VoiceOver 讀出模型、工作狀態、真實完成段數與主要動作。
- 多個同 bundle ID 副本存在時，確認實際啟動路徑；不得靠視窗標題加入版本辨識。

真實 active cloud 驗收：

- 目前段預估最多填至該格 90%。
- 完成回應後才跳滿並前進下一段。
- 進度不倒退，不把預測值寫進 ledger。
- 完整 log 僅在「複製除錯資訊」提供，主卡保持兩句白話狀態。

復原驗收：

- 取消、App 重開、checkpoint resume、成功後 cleanup。
- 刪除只作用於 App 管理的 UUID 子目錄。
- 可取回項目不得被批次清除孤立／損壞功能刪除。

## 7. P1：可靠性、隱私與正式發布阻塞

### R1：遠端 cleanup debt ledger

已確認缺口：

- Files API／GCS DELETE 失敗目前只寫 warning：`GoogleAIStudioBackend.swift:842`、`VertexAIGeminiBackend.swift:903`。
- App 重開後已沒有足夠資料自動重試遠端刪除。

資料模型：

- provider：`googleAIStudioFiles`／`vertexGCS`
- remote identifier：Files API file name，或 GCS bucket＋object name
- createdAt、lastAttemptAt、attemptCount、lastError
- job ID 可選；不得保存 API Key、access token、Authorization header、音檔或逐字稿

行為：

1. DELETE 成功或 404：不建立／移除 debt。
2. 網路、401、403、429、5xx：原子保存 debt。
3. 有可用 credential 時在下次啟動後背景重試；沒有 credential 時顯示待清理，不反覆要求登入。
4. 提供手動「重試遠端清理」，顯示項目數、provider、建立時間與最後錯誤。
5. 重試有上限與 backoff；不能阻塞轉錄或 App 結束。

測試：

- DELETE 失敗後 debt 落盤，檔案權限限制為使用者可讀寫。
- App 重建 repository 後可載入 debt。
- 401 刷新 credential 後成功，404 視為已清理。
- 多次相同 remote ID 去重。
- 取消 transcription 不取消 shielded cleanup。
- JSON 不含 credential、原始音訊或 transcript。

### R2：可安全分享的除錯資訊

已確認缺口：

- `JobDebugClipboard.dump` 目前直接包含完整 `job.sourcePath`、失敗 technical details 與全部 log：`MainView.swift:1405`。
- 使用者把內容貼給第三方支援時，可能暴露帳號目錄、客戶／會議檔名、bucket／URL 或未來新增的敏感 log。

要求：

1. 預設動作改為「複製可分享的除錯資訊」。
2. 預設遮蔽完整來源／輸出／recovery 路徑；檔名可由使用者選擇保留或遮蔽。
3. scrub API key 格式、Bearer token、Authorization header、signed URL query、home directory、Prompt／詞庫正文與 transcript 片段。
4. 保留版本、build、backend、requested/effective model、stage、finishReason、HTTP status、token counts、retry count、匿名 segment 狀態。
5. 「複製完整本機除錯資訊」放在次要選單，顯示將包含路徑與完整 log 的確認文字。

測試：

- 用假 home path、`AIza` key、Bearer token、signed URL、Prompt 與逐字稿片段建立 fixture。
- share-safe output 不含任何敏感 fixture；仍保留可診斷欄位。
- full-local output 只有在明確選取時產生。

### R3：Recovery 容量與保留政策

已確認缺口：

- `RecoveryScanItem` 有分類與檔名，但沒有目錄大小、最後修改時間或年齡：`RecoveryScanner.swift:19`。
- UI 只能看到項目數，無法判斷磁碟占用：`RecoveryScanView.swift:154`。

要求：

1. 掃描時計算每個 managed UUID directory 的 logical bytes、modifiedAt；大目錄應可取消，不阻塞 MainActor。
2. summary 顯示總容量、可取回容量、孤立／損壞容量與最舊日期。
3. 支援依容量／日期排序。
4. 可提供 opt-in 自動清理，但只允許清理超過設定天數的 orphaned／damaged。
5. recoverable 永不自動刪除；任何 symlink／root 外路徑維持拒絕。
6. 刪除前顯示項目數與總容量，刪除後重新掃描核對釋放量。

驗收：

- 測試巢狀檔案、空目錄、讀取錯誤、symlink、取消與 root boundary。
- 批次清理不碰原始錄音、正式輸出或 recoverable。
- 1000 個小檔案與一個大型檔案時 UI 仍可操作。

### D1：正式 Runtime／模型信任鏈

已確認發布阻塞：

- `runtime/arm64/requirements.lock.txt` 只有兩個核心 pin，不是完整 hash lock。
- `runtime/arm64/model-lock.json` 的 `files` 為空。
- `ModelCache.isUsableSnapshot` 只確認 `config.json` 與任一權重檔存在：`ModelCache.swift:87`。
- `RuntimeManifestValidator` 只驗 schema、URL、Team ID 字串與 SHA 格式；目前沒有 manifest signature 驗證或 installer：`FileIntegrity.swift:71`。

交付物：

1. 乾淨 arm64 builder 產生完整 wheelhouse／dependency closure，記錄 Python 精確 patch 版與每個 wheel SHA-256。
2. 產生 Runtime archive、signed manifest、預期解壓檔案清單與 nested code signature／Team ID。
3. App 內建 manifest 驗證 public key 與允許的 Team ID，不信任 manifest 自我聲明。
4. staging 下載後驗 archive hash、manifest signature、解壓檔案 hash、Mach-O／dylib／Python extension 簽章。
5. 驗證後才原子切換 `current`，失敗保留上一版並可 rollback。
6. 每個模型 revision 產生非空 `ModelManifest.files`，驗 size、SHA-256、license；驗證完成才顯示「可用」。
7. 模型完整後斷網啟動，確認 `HF_HUB_OFFLINE`／`TRANSFORMERS_OFFLINE` 下不抓網路。
8. 乾淨 macOS 14 帳號不裝 Homebrew、不建 `~/mlx-audio-env` 也能完成 1 分鐘 smoke。

驗收：

- 篡改 archive、manifest、單一 wheel、模型權重、Team ID、download host 均 fail closed。
- interrupted install 不破壞上一版。
- Gatekeeper、codesign、notarization、stapling、clean-account smoke 全通過。
- 未完成前 README 與 UI 維持 Developer Mode／非 Stable 說明。

## 8. P2：雲端能力、CI 與產品優化

### C1：雲端模型能力矩陣與 model-aware token 策略

現況：

- App 靜態列出 3.7 Flash、3.6 Flash、3.1 Pro Preview：`Models.swift:159`。
- AI Studio 與 Vertex 轉錄目前固定 `maxOutputTokens = 16384`。
- Google 官方顯示 3.7 Flash 的最大輸出為 65,536 tokens；提高 production 上限是否能減少 dense audio 切段，尚未 A/B 驗證。

要求：

1. 建立 `CloudModelCapabilities`：backend availability、stable／preview、max output、thinking support、transcription features、lastVerifiedAt、sunset／replacement。
2. App 啟動不應依賴網路抓 catalog；使用版控 allowlist，另由 scheduled CI／人工更新檢查退役資訊。
3. preview 模型顯示明確標籤；未知或已 shutdown 模型 fail closed 並建議可用替代，不默默換模型。
4. requested model、effective model、fallback reason 必須繼續進 metadata／debug info。
5. 對 3.7 Flash 做 16384、32768、65536 A/B：同一 dense 20 分鐘 fixture，比較 `finishReason`、完整性、延遲、輸出 token、重試與人工品質。
6. A/B 沒有明確改善前，production 預設維持 16384。

驗收：

- catalog fixture 覆蓋 stable、preview、deprecated、shutdown、unknown。
- model migration 不改寫已入佇列 JobSnapshot。
- 退役檢查故障不阻擋離線 Qwen。
- token A/B 報告分開記錄品質與成本，不只比較是否 `STOP`。

官方參考：

- <https://ai.google.dev/gemini-api/docs/models/gemini-3.7-flash>
- <https://ai.google.dev/gemini-api/docs/deprecations>

### C2：Gemini 3.5 Transcribe A/B spike

Google 已提供專用 `gemini-3.5-transcribe`，支援 custom vocabulary、speaker diarization 與 word-level timestamps；diarization／timestamps 模式每個 request 最長 30 分鐘，三位以上 speaker attribution 仍是 experimental。

本項只做研究，不直接加入預設模型選單。

比較資料集：

- 5 分鐘雙人中文。
- 20 分鐘密集會議。
- 30 分鐘多人／相似姓名。
- 中英 code-switch、專有名詞、背景噪音各一條。

比較 3.7 Flash 現行路徑與 3.5 Transcribe verbatim：

- 文字完整性與人工漏句／重複計數。
- 專有名詞正確率；custom vocabulary 有／無的 A/B。
- speaker consistency、時間戳單調性與 segment coverage。
- 台灣繁體經 OpenCC 後品質。
- 延遲、請求數、費用、上傳／遠端清理行為。
- 失敗／取消／重試／復原支援差異。

通過門檻：

- 不得比 3.7 Flash 增加缺段或資料遺失風險。
- 專有名詞或 speaker 至少一項有可重現改善，且另一項不顯著退化。
- 能映射為現有正式 TXT 契約；annotations 缺失時 fail closed 或明確降級。
- 通過後另寫 backend integration 規格，再決定是否成為實驗選項。

官方參考：

- <https://ai.google.dev/gemini-api/docs/transcribe>
- <https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe>

### Q1：CI Actions、測試隔離與 coverage

已確認缺口／噪音：

- CI 使用 `actions/checkout@v4`、`actions/upload-artifact@v4`，目前 runner 會警告 Node.js 20 metadata 被強制用 Node 24。
- 多個 XCTest mock 使用 static URLProtocol handler；部分測試還使用全域 `URLProtocol.registerClass`，限制平行測試安全性。
- CI 沒有 Swift coverage baseline。
- `brew install ffmpeg opencc` 使用 runner 當下版本，log 沒有固定記錄工具版本。

要求：

1. 在獨立 CI commit 升級 GitHub-hosted runner 可用的 Node 24 官方 action major；目前官方 checkout／upload-artifact 已提供 Node 24 版本。
2. 不關閉 Homebrew tap trust 檢查；只移除專案可控制的警告。
3. CI 開頭輸出 Swift、macOS、architecture、ffmpeg、ffprobe、OpenCC 版本。
4. 將 URLProtocol handler 改為每個 test session 隔離的 registry／actor，避免跨測試污染；清除全域 registerClass。
5. 新增重複／平行測試 job，至少連跑 cloud transport／adaptive suites 20 次，確認無 flake。
6. 建立 `swift test --enable-code-coverage` baseline，先上傳報告；有穩定 baseline 後才對 critical modules 設門檻。
7. Critical modules 至少包含 cloud finishReason、segment manifest、recovery path validation、credential redaction、process termination。

驗收：

- CI 不再顯示 Node 20／punycode deprecation warning。
- 178 項以上 XCTest、Python tests、self-tests、pipeline、DMG、bundle verification 全綠。
- 20 次 repeat／parallel 無 handler collision、掛起或順序依賴。
- coverage 報告可下載；門檻不以排除核心檔案的方式灌高。

官方參考：

- <https://github.com/actions/checkout>
- <https://github.com/actions/upload-artifact>

## 9. P3：維護性與更新體驗

### M1：大型協調器模組化

現況行數只是風險訊號，不是功能缺陷：

- `AppViewModel.swift` 約 2549 行。
- `TranscriptionEngine.swift` 約 2478 行。
- `MainView.swift` 約 1506 行。
- Google／Vertex backends 各約 1000 行。

只有在 P0／P1 證據與保護完成後才開始。拆分順序：

1. 從 `TranscriptionEngine` 抽出 cloud segment coordinator、local pipeline、recovery writer；先保持原 public entry point。
2. 從 `AppViewModel` 抽出 queue runner、model manager、recovery controller、credential coordinator。
3. 從 `MainView` 抽出 intake、job row、progress、debug export 元件。
4. Google／Vertex 只抽取真正相同且已有測試的 request／response／retry primitive；provider-specific auth、upload、cleanup 留在各 backend。

驗收：

- 每一步獨立 commit，不能一次搬動全部檔案。
- public API、JobSnapshot schema、ledger schema、輸出命名與 UI 行為不變。
- 178 項以上 XCTest、10 pipeline、真實 5 分鐘 smoke 均通過。
- `git diff` 可追蹤純搬移與行為修改；若同一 commit 同時大搬移與改功能，拒絕合併。

### U1：PD-015 自動檢查更新

依賴：

- 已有正式、簽署、公證、可下載的 Stable release。
- 版本與 channel 定義完成。
- 更新提示 URL 指向可信任 GitHub Release／正式下載頁。

第一階段只做：

- 約每 7 天安靜檢查，可關閉／每天／每週。
- 設定頁「立即檢查」與上次成功／失敗時間。
- Stable 不提示 prerelease。
- 有新版時非阻斷提示，讓使用者自行開啟下載頁。
- 離線／GitHub failure 安靜失敗，不影響轉錄。

第一階段不做：

- 強制更新。
- 自動覆蓋 `.app`。
- 把 App 更新與模型／Runtime 更新混成同一流程。

驗收：

- fixture 覆蓋有新版、無新版、prerelease、離線、malformed response、rate limit。
- 啟動檢查不在 MainActor 做網路 I/O。
- 同一天不重複通知；使用者忽略後不持續彈窗。

## 10. 執行順序與停止條件

固定順序：

1. E1 真實 Gemini 受控驗證。
2. E2 Qwen 30 分鐘，通過後才跑 173 分鐘。
3. E3 GUI／復原／輔助使用。
4. R1 遠端 cleanup debt、R2 debug redaction、R3 recovery 容量。
5. D1 正式 Runtime／模型信任鏈。
6. C1 model-aware token A/B、C2 Transcribe spike。
7. Q1 CI／測試品質。
8. M1 模組化。
9. Stable release 就緒後才做 U1 自動更新。

停止條件：

- 真實 API 達支出上限、未取得授權或連續兩次未觸發：停止並報告，不擴大音檔。
- 30 分鐘 Qwen 未通過：不得跑 173 分鐘。
- 新路徑出現缺段、重複、來源被修改或 recovery 無法取回：停止功能擴充，先修 correctness。
- CI／mock 通過但真實 runtime 失敗：結論維持未驗證，不得改文案宣稱可用。
- 正式 Runtime trust chain 未完成：不得建立 Stable release 或啟用自動覆蓋更新。

## 11. Commit 與驗證規則

每一項工作必須：

1. 開工前記錄 branch、HEAD、remote SHA、`git status`。
2. 保留使用者資料與 unrelated changes。
3. 一個風險主題一個 commit；禁止混合真實驗證、架構重構與文件清理。
4. 跑 `git diff --check`、`scripts/run-checks.sh`。
5. push 後確認正確 HEAD 的 GitHub Actions 全綠。
6. 真實 API／MLX／GUI／簽署另附實證，不能用 CI 代替。
7. 文件分開列出：已確認、合理推測、未驗證、外部 blocked。

## 12. 本規格完成定義

- [x] 目前 branch／remote／CI 基準已確認。
- [x] 已完成程式、測試、Runtime、UI、CI／release 與文件全盤盤點。
- [x] 已排除已完成的 persistent helper、model cache、background inventory 與 best-effort remote cleanup，不重列成待實作。
- [x] 每一項建議都有優先序、證據、範圍、驗收或停止條件。
- [x] 沒有把 mock／CI 擴大成真實 Gemini、MLX、GUI 或 Stable release 證據。
- [x] 本規格沒有授權付費 API、刪除資料、安裝 App 或建立 Release。

本文件完成只代表下一階段 roadmap 可執行，不代表其中任一優化已實作。
