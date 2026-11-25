# record-to-text 優化改善建議書

- **檢視日期**：2026-11-25
- **檢視基準**：`main` 分支 `bb15eed`（版本 `0.2.1`，`DEFAULT_BUILD_NUMBER=22`）
- **對應技術規格書**：[`OPTIMIZATION_SPEC_20261125.md`](OPTIMIZATION_SPEC_20261125.md)

---

## 1. 專案定位與現況盤點

### 1.1 技術棧與核心架構
`record-to-text` 是針對 macOS 14+（Apple Silicon 為主）打造的原生會議錄音轉台灣繁體逐字稿桌面應用，採零外部 SwiftPM 套件依賴的分層架構：

- **前端應用層（`Sources/RecordToTextApp/`）**：
  - 入口為 `RecordToTextApp.swift:88-160`，由單一 `@MainActor` 狀態協調器 `AppViewModel.swift:39-3586` 管理單工佇列、設定持久化、Keychain 憑證遷移（`GoogleAIStudioCredentialStore.swift`）與完成後系統休眠（`QueueCompletionSleepCoordinator.swift`）。
  - 介面已完成 Phase 1–4 翻新（`DesignSystem/`、`MainWindow/`、`Sheets/`），具備漸進式設定膠囊、可展開執行日誌／分段診斷面板與原生 Quick Look 預覽。
- **核心管線層（`Sources/RecordToTextCore/`）**：
  - `TranscriptionEngine.swift:106-3544` 統籌三種轉錄後端：**Google AI Studio**（`GoogleAIStudioBackend.swift`）、**Google Cloud Vertex AI**（`VertexAIGeminiBackend.swift` + `GCloudAuthService.swift`）與**本機 Qwen3-ASR**（`ASRBackend.swift`）。
  - 具備 20 分鐘靜音感知預切、`MAX_TOKENS` 自適應遞迴拆段、SSE 串流與 `includeThoughts` 保活、20 秒網路恢復與 HTTP 429 冷卻、獨占原子輸出（`AtomicFileWriter.swift` `RENAME_EXCL`）及崩潰對帳（`JobPersistenceCoordinator.swift`、`OutputPublicationStore.swift`）。
- **本機推論輔助與工具鏈（`Sources/RecordToTextApp/Resources/*.py`、`scripts/*`、`Tools/*`）**：
  - 內建 `qwen_asr_mlx_runner.py`（長駐 JSONL `--server`）、`qwen_asr_local_checkpoint.py`（v2 音訊座標與斷點驗證）、`qwen_asr_chunking.py` 與 Experimental `qwen_asr_transformers_runner.py`；隨附 `ffmpeg`／`ffprobe` 打包驗證與三層自動化測試（Python 單元測試、CLI SelfTest／PipelineSelfTest、XCTest）。

### 1.2 已核對之既有文件與交班脈絡
本次審計已先行核對 `README.md`、`HANDOFF.md`、`SECURITY.md`、`CHANGELOG.md`、`docs/NEXT_STEPS.md`、`docs/product-decisions.md`、`docs/functional-review-2026-10-17.md`、`docs/code-size-review-2026-09-21.md`、`docs/log-visibility-retry-observability-spec-2026-11-17.md`、`docs/ui-redesign-spec-2026-11-17.md` 與工作樹未追蹤之 `docs/windows-edition-spec-2026-11-25.md`，確認以下項目**已結案或屬刻意設計，不重複提報**：
- Gemini 4 Neon / Hydrogen / Carbon / Argon 預設與思考強度記憶、舊版 Gemini 3.x 設定自動遷移（build 20–22 已完成）。
- AI Studio / Vertex SSE 串流、零拷貝檔案上傳、POSIX 40 session 重設與傳輸重試日誌白名單（build 14–21 已完成）。
- 已完成工作列預設收合日誌列、改由右上角 `⋯` 選單展開診斷（`docs/ui-redesign-spec-2026-11-17.md:369-375` 刻意設計）。
- 正式受管理 Runtime installer、Intel 實機支援、Developer ID 公證與自動更新（`PD-005`、`PD-006`、`PD-015` 已列為外部條件／獨立發佈里程碑）。

在此基礎上，以下聚焦於現行程式碼中**具明確行號證據、影響隱私邊界、發佈正確性、轉錄可靠性與日常體驗**的 11 項具體改善點。

---

## 2. 優化改善項目總覽表

| 編號 | 優先級 | 類別 | 問題摘要 | 證據位置（`檔案:行號`） | 預估規模 |
| :--- | :---: | :--- | :--- | :--- | :---: |
| **OPT-01** | **P0** | 隱私邊界／狀態一致性 | 重複檔案確認期間切換轉錄引擎，`pendingDuplicateIntake` 未同步更新，導致確認加入的檔案誤用舊雲端後端執行 | `Sources/RecordToTextApp/AppViewModel.swift:75-82, 652-663, 1600-1618` | S |
| **OPT-02** | **P0** | 資安／日誌去識別化 | AI Studio Files API 回應之 `fileName` 未驗證格式即組裝帶金鑰之 URL；雲端清理與 GCS 上傳將原始 `localizedDescription` 及 Bucket／檔名寫入日誌 | `Sources/RecordToTextCore/GoogleAIStudioBackend.swift:850-854, 879, 953-983`；`Sources/RecordToTextCore/VertexAIGeminiBackend.swift:487, 1045-1105` | S |
| **OPT-03** | **P0** | 簽署／打包交付鏈 | `sign-app.sh` 漏簽 `Contents/Helpers/ffmpeg` 與 `ffprobe`；`build-release.sh` Universal 模式混入純 `arm64` 輔助執行檔且 `verify-release.sh` 未檢查；開發 DMG 關閉 ad-hoc 簽章 | `scripts/sign-app.sh:23-31`；`scripts/build-release.sh:16-18`；`scripts/package-development.sh:21-23`；`scripts/verify-release.sh:55-68, 97-103` | S |
| **OPT-04** | **P1** | 管線可靠性／磁碟防護 | 雲端轉錄管線（AI Studio / Vertex AI）於磁碟空間檢查前提前 `return`，完全未驗證暫存區與輸出目錄可用空間 | `Sources/RecordToTextCore/TranscriptionEngine.swift:456-484, 505-511`；`Sources/RecordToTextCore/AudioServices.swift:124-168` | S |
| **OPT-05** | **P1** | 輸出契約／防回吐 | 雲端「錄音背景」回吐檢查僅比對完整 5 行外框，模型若省略前導說明而回吐 `【錄音背景開始】…【錄音背景結束】` 或 JSON 信封會漏擋 | `Sources/RecordToTextCore/CloudRecordingContext.swift:37-49`；`Sources/RecordToTextCore/OutputContractValidator.swift:31-46` | S |
| **OPT-06** | **P1** | 連線驗證／資源管理 | 設定頁「測試連線」未檢測所選模型可用性、Vertex 僅測本機 `gcloud` 未測雲端權限，且 AI Studio 離線測試因 `waitsForConnectivity` 最長卡住 20 分鐘並洩漏臨時 `URLSession` | `Sources/RecordToTextApp/Sheets/SettingsView.swift:1016-1101`；`Sources/RecordToTextCore/GoogleAIStudioBackend.swift:126, 162-199`；`Sources/RecordToTextCore/GeminiTransportHelper.swift:384-395` | M |
| **OPT-07** | **P1** | 本機模型快取／子程序 | `HelperASRBackend` 漏傳 `HF_TOKEN`；覆寫 `HF_HOME` 使 `huggingface-cli login` 憑證失效；MLX `--server` 未清除離線旗標；手動下載模型無 inactivity timeout | `Sources/RecordToTextCore/ASRBackend.swift:1010-1057`；`Sources/RecordToTextApp/AppViewModel.swift:3066-3085, 3141-3181`；`Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py:474-482` | S |
| **OPT-08** | **P1** | Vertex 認證／環境隔離 | `GCloudAuthService` 未傳入環境變數白名單與 Homebrew `PATH`，且 `cachedProjectID` 永久快取不會隨外部 `gcloud config` 更新 | `Sources/RecordToTextCore/GCloudAuthService.swift:41-42, 122-127, 164-199`；`Sources/RecordToTextCore/ProcessRunner.swift:216-218` | S |
| **OPT-09** | **P2** | 成本估算與顯示一致性 | 自訂或帶版號之未知雲端模型落入 `else` 分支誤套用舊 Flash 費率估價；完成日誌與 `RecentJobSummary` 未沿用分段精確估價 | `Sources/RecordToTextCore/CloudTranscriptionModels.swift:247-248, 266-272, 277-306`；`Sources/RecordToTextApp/AppViewModel.swift:2719-2720` | S |
| **OPT-10** | **P2** | 記憶體生命週期 | 長駐 Qwen MLX Helper 於佇列閒置或切換至雲端後端後仍常駐佔用數 GB 統一記憶體；同 session 切換模型時新舊權重同時駐留 | `Sources/RecordToTextApp/AppViewModel.swift:137-138, 2488-2496`；`Sources/RecordToTextCore/ASRBackend.swift:667, 817-838`；`Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py:517-565` | S |
| **OPT-11** | **P2** | UI 狀態／文件與視窗契約 | 工具列選取預設本機 Qwen `1.7B 8-bit` 時誤顯示「目前自訂／進階選擇」雙重勾選；`README.md` 漏列雲端模式 `opencc` 必要依賴；主視窗使用 `WindowGroup` 允許多開共用單例 Sheet 狀態 | `Sources/RecordToTextApp/MainWindow/ToolbarModelMenu.swift:24-34, 48-60`；`Sources/RecordToTextCore/QuickTranscriptionChoice.swift:5-15`；`README.md:22-27, 106`；`Sources/RecordToTextApp/RecordToTextApp.swift:95-103` | S |

---

## 3. 逐項深度診斷與建議

### OPT-01（P0）：重複檔案確認對話框期間切換轉錄引擎，會以過期引擎快照將檔案誤送舊雲端後端
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextApp/AppViewModel.swift:75-82` 定義 `IntakeContext`，以不可變屬性 `let settings: AppSettings` 保存加入當下的完整設定。
  - `Sources/RecordToTextApp/AppViewModel.swift:1600-1618`：`addFiles(_:allowingDuplicates:)` 先將非重複檔案加入 `jobs`，再把重複檔案連同當下的 `intake` 存入 `pendingDuplicateIntake` 與 `pendingDuplicateURLs`，彈出 `isDuplicateConfirmationPresented`。
  - `Sources/RecordToTextApp/AppViewModel.swift:631-639, 652-663`：當使用者變更 `backendType`、雲端／本機模型或思考強度時，`synchronizeQueuedEngineSettings()` 只遍歷更新 `jobs` 陣列中的待轉工作，完全沒有更新 `pendingDuplicateIntake`。該缺口亦曾於 `docs/NEXT_STEPS.md:21` 註記待處理。
- **【風險與影響】**：
  - macOS 的 `Settings`（`⌘,`）為獨立視窗。若使用者在重複檔案確認對話框開啟期間，將引擎由雲端（AI Studio / Vertex AI）切換為「本機 Qwen（不上雲）」，主視窗標題與已排隊工作皆顯示「本機 Qwen」，但按下「仍然加入」後產生的重複檔案工作卻仍綁定舊雲端後端，直接違反 `SECURITY.md:5-6` 的隱私邊界承諾。
- **【具體改善方向】**：
  - 將 `IntakeContext.settings` 改為可同步更新之欄位（或在 `confirmDuplicateFiles()` 執行時以 `intake.settings` 的輸出位置搭配現行 `self.settings` 的引擎設定呼叫 `JobSnapshot.withEngineSettings(settings)`），並在 `synchronizeQueuedEngineSettings()` 中同步更新 `pendingDuplicateIntake`。

### OPT-02（P0）：AI Studio Files API 回傳檔名未做格式驗證，且雲端清理與 GCS 上傳洩漏原始錯誤及儲存貯體名稱至日誌
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextCore/GoogleAIStudioBackend.swift:817` 在 `remoteFileMetadata` 有檢查 `name.range(of: #"^files/[a-z0-9-]{1,40}$"#)`；但 `finishFilesUpload`（`850-854, 879`）與 `deleteRemoteFile`（`963`）從回應 JSON 讀取 `fileObj["name"]` 後未做任何驗證，直接字串插值構造 `https://generativelanguage.googleapis.com/v1beta/\(fileName)` 並附上 `x-goog-api-key` Header。
  - `Sources/RecordToTextCore/GoogleAIStudioBackend.swift:953-955, 981-983` 與 `Sources/RecordToTextCore/VertexAIGeminiBackend.swift:487, 1045-1105`：`VertexAIGeminiBackend.swift:487` 直接把 GCS `bucket` 名稱寫入 `logger`；兩處遠端暫存檔刪除失敗皆直接回傳 `error.localizedDescription` 並連同 `fileName`／`objectName` 寫入 `logger`；且 `VertexAIGeminiBackend.swift:1045-1059` 在 `waitForCleanup == false` 的背景 `Task.detached` 中仍呼叫 `logger`。
- **【風險與影響】**：
  - 違反 `SECURITY.md:7-8` 與 `docs/log-visibility-retry-observability-spec-2026-11-17.md:132-137` 的白名單規範：未驗證之 `fileName` 若遭中間代理竄改為相對路徑或查詢字串，會將 API Key 發往非預期端點；而 `NSError.localizedDescription` 常夾帶完整請求 URL 或底層代理資訊，會被持久化至 `job-journal.json` 與複製除錯資訊中。
- **【具體改善方向】**：
  - 於 `GoogleAIStudioBackend` 抽取 `validateRemoteFileName(_:)` 統一驗證 `^files/[a-z0-9-]{1,40}$`，不符即拋出 `fileUploadFailed` 並拒絕發送帶金鑰之 `GET`/`DELETE`。
  - 移除 `VertexAIGeminiBackend.swift:487` 的 `bucket` 明文，並將兩端刪除失敗訊息改由 `CloudFailureDiagnostic.classify(error, stage: .cleanup)` 格式化為白名單代碼（不含 `fileName`、`objectName` 與 `localizedDescription`）；移除 `waitForCleanup == false` 分支的跨生命週期 `logger` 呼叫。

### OPT-03（P0）：`scripts/sign-app.sh` 漏簽內嵌輔助執行檔，且 Universal 建置與開發打包存在架構／簽章缺口
- **【事實與程式碼證據】**：
  - `scripts/build-release.sh:16-18` 與 `scripts/package-development.sh:21-23` 皆設定 `ADHOC_SIGN=0` 呼叫 `scripts/build-app.sh`（跳過 `build-app.sh:80-84` 的內外層簽章）。
  - `scripts/sign-app.sh:23-31` 僅對外層 `${APP_PATH}` 執行一次 `codesign --force --timestamp --options runtime --entitlements ...`，**完全沒有先簽署 `${APP_PATH}/Contents/Helpers/ffmpeg` 與 `ffprobe`**。
  - `scripts/build-release.sh:16` 指定 `UNIVERSAL=1`，但 `scripts/build-app.sh:76-77` 固定複製 `runtime/macos-arm64/bin/` 的純 `arm64`（且含 GPL 編碼器，`scripts/fetch-bundled-ffmpeg.sh:4-6`）二進位檔；`scripts/verify-release.sh:55-68, 97-103` 只對主執行檔跑 `lipo -archs`，對 `Contents/Helpers/*` 僅檢查 `-x` 可執行權限。
  - `scripts/package-development.sh:22` 在 `build-app.sh:48-53` 改寫 `Contents/Info.plist` 後維持 `ADHOC_SIGN=0`，使 bundle 內主程式僅剩編譯期單檔 linker signature。
- **【風險與影響】**：
  - 依 `README.md:285-290` 執行正式簽署與公證時，會因 `Contents/Helpers/ffmpeg` 未具 Developer ID 簽章、Hardened Runtime 與安全時間戳而被 `codesign --verify --deep --strict` 或 Apple `notarytool` 拒絕；`REQUIRE_UNIVERSAL=1` 亦會誤放行缺 `x86_64` helper 的 App。此外，未重簽 ad-hoc 的開發版 `.app` 在下載解壓後可能因 Info.plist 變更導致簽章不一致遭系統攔截【待環境確認：視目標 macOS 14/15/26 之 `amfid` 對移除隔離屬性後之 linker-signed bundle 驗證行為而定】。
- **【具體改善方向】**：
  - `scripts/sign-app.sh` 改為由內而外依序簽署 `Contents/Helpers/ffmpeg`、`Contents/Helpers/ffprobe`（帶 `--timestamp --options runtime`，不帶 App 主程式 entitlements），再簽署外層 `.app`。
  - `scripts/verify-release.sh` 在 `REQUIRE_UNIVERSAL=1` 時對 `Contents/Helpers/ffmpeg` 與 `ffprobe` 一併執行 `lipo -archs` 驗證；`scripts/package-development.sh` 改為 `ADHOC_SIGN=1` 確保開發測試包具備完整一致的 ad-hoc bundle 簽章。

### OPT-04（P1）：雲端轉錄管線提前返回，完全跳過暫存區與輸出資料夾的磁碟空間預檢
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextCore/TranscriptionEngine.swift:456-484`：`googleAIStudio` 與 `vertexAI` 分支在完成 `outputDirectory` 建立後立即呼叫 `runGoogleAIStudioPipeline`／`runVertexAIPipeline` 並 `return result`。
  - `Sources/RecordToTextCore/TranscriptionEngine.swift:505-511`：`probeService.validateDiskSpace(...)` 位於第 505 行，僅有本機 Qwen 路徑會執行。
- **【風險與影響】**：
  - 與 `README.md:112`、`CHANGELOG.md:74` 所述不符。當使用者磁碟或外接輸出碟剩餘空間極低時，長會議雲端工作不會在啟動前 fail-fast，而是在耗費 Gemini API token 與等待時間後，於擷取分段 MP3、寫入暫存請求檔（Inline fallback 單段可達 ~27 MB）、OpenCC 轉換或最終原子寫檔時才拋出 I/O 失敗。
- **【具體改善方向】**：
  - 於 `AudioProbeService` 擴充支援自訂暫存估算位元組（雲端按 16kHz 24kbps MP3 約 `3,000 bytes/sec * 2 + 32 MiB` JSON/分段緩衝 + `minimumTemporaryReserve`，而非本機 16-bit PCM 倍數），並在 `TranscriptionEngine.run` 進入雲端分支前統一執行暫存區與輸出區空間檢查。

### OPT-05（P1）：雲端「錄音背景」回吐檢查僅比對完整 5 行外框，漏擋標籤區塊或 JSON 信封回吐
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextCore/CloudRecordingContext.swift:37-49`：`referenceBlock(_:)` 由 2 行轉錄規則說明與 `【錄音背景開始】\n{"recording_context":...}\n【錄音背景結束】` 組成。
  - `Sources/RecordToTextCore/OutputContractValidator.swift:36-45`：僅取整段 5 行 `recordingContextBlock` 去空白後檢查 `normalized.hasPrefix(block) || normalized.hasSuffix(block)`。此問題對應 `docs/NEXT_STEPS.md:21` 註記之「完整背景回吐漏擋」。
- **【風險與影響】**：
  - 若模型在逐字稿開頭或末尾只回吐 `【錄音背景開始】...【錄音背景結束】` 或 `{"recording_context":"..."}`（省略前兩行系統說明），現有前置／後置比對即告失效，使背景信封污染正式輸出。
- **【具體改善方向】**：
  - 在 `OutputContractValidator.validate` 中，從 `recordingContextBlock` 額外提取 `【錄音背景開始】...【錄音背景結束】` 區段與內層 `{"recording_context":...}` JSON 字串作為候選信封；凡逐字稿去時間標題與空白後以此類信封為開頭／結尾、或全文仍殘留 `【錄音背景開始】`／`【錄音背景結束】` 邊界標記時，一律以 `OutputContractValidationError.promptEcho` 攔截（不影響講者自然說出背景詞句的正常對話）。

### OPT-06（P1）：設定頁「測試連線」未驗證所選模型、離線時最長卡住 20 分鐘且未釋放臨時 `URLSession`
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextApp/Sheets/SettingsView.swift:1036-1038`：每次點擊「測試連線」皆建立 `GoogleAIStudioBackend()`，其預設 `urlSession` 由 `GeminiTransportHelper.makeEphemeralRetrySession()` 建立（`GeminiTransportHelper.swift:387-394`：`waitsForConnectivity = true`、`timeoutIntervalForResource = 1_200`），且測試結束未呼叫 `finishTasksAndInvalidate()`。
  - `Sources/RecordToTextCore/GoogleAIStudioBackend.swift:162-199`：`validateAPIKey` 僅請求 `GET /v1beta/models?pageSize=1`，不檢查 `settings.googleAIStudioModelID`。
  - `Sources/RecordToTextApp/Sheets/SettingsView.swift:1060-1101`：`testVertexAIAuthentication()` 僅呼叫本機 `gcloud` 讀取預設專案與 Access Token，未向 Vertex AI 發出任何 API 驗證請求。
- **【風險與影響】**：
  - 離線點擊 AI Studio「測試連線」時，`waitsForConnectivity = true` 會忽略 15 秒 request timeout 而等待最長 1,200 秒；重複點擊亦殘留未 invalidate 的 `URLSession`。同時，自訂模型 ID 拼錯、Vertex 專案未開通 API 或模型不支援該 Location（如 `gemini-4-neon` 誤設不支援區域）皆會誤報「驗證成功」，直到實際轉錄才失敗（亦見 `docs/functional-review-2026-10-17.md:33`）。
- **【具體改善方向】**：
  - 為互動式連線測試建立 `waitsForConnectivity = false`、`timeoutIntervalForResource = 15` 的短效 `URLSession` 並於 `defer` 執行 `finishTasksAndInvalidate()`。
  - AI Studio 測試改為同時驗證金鑰與 `GET /v1beta/models/<selectedModelID>` 模型存在性，細分憑證無效（401/403）、模型不存在或無權限（404）、配額／限流（429）與網路錯誤。
  - Vertex AI 測試在取得 Token 後，驗證端點參數與模型支援區域（如 Neon / Hydrogen 僅允許 `global`/`us`/`eu`），並對目標模型執行一次輕量零生成探測（查詢 publisher model metadata 或最小 `countTokens`），如實回報 IAM／區域／模型可用狀態。

### OPT-07（P1）：本機 Qwen 自動下載模型漏傳 `HF_TOKEN`、`HF_HOME` 覆寫使登入憑證失效，且手動下載缺逾時保護
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextCore/ASRBackend.swift:1010-1041`：`helperEnvironment` 環境白名單未包含 `HF_TOKEN` 與 `HUGGING_FACE_HUB_TOKEN`（而 `AppViewModel.swift:3158-3159` 的手動下載有包含）。
  - `Sources/RecordToTextCore/ASRBackend.swift:1037` 與 `Sources/RecordToTextApp/AppViewModel.swift:3173`：兩處皆將 `HF_HOME` 指向 `~/Library/Application Support/record-to-text/Models` 但未傳遞 `HF_TOKEN_PATH`，導致 `huggingface_hub` 改去 `Models/token` 尋找憑證，使使用者依 `README.md:92` 執行 `huggingface-cli login` 產生的 `~/.cache/huggingface/token` 完全失效。
  - `Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py:474-482`：`configure_environment` 在 `offline` 為假時未 `pop` 掉前次請求留下的 `HF_HUB_OFFLINE` 與 `TRANSFORMERS_OFFLINE`（對照 `qwen_asr_transformers_runner.py:271-273` 有清除）。
  - `Sources/RecordToTextApp/AppViewModel.swift:3066-3085, 3141-3144`：`performModelDownload` 執行 `snapshot_download` 未設 `inactivityTimeout`；`copyModelFromDefaultHFCache` 直接刪除目標後原地 `copyItem`，中斷時會留下不完整目錄。
- **【風險與影響】**：
  - 使用者依 `README.md:84-93` 配置 Hugging Face Token 後，首次按轉錄自動下載 2.3–3.8 GB 模型仍以匿名連線下載，易遭限流失敗；下載中途若網路停滯則無限卡住。
- **【具體改善方向】**：
  - 統一 `ASRBackend.helperEnvironment` 與 `AppViewModel.modelDownloadEnvironment` 的 Hugging Face 憑證傳遞：放行 `HF_TOKEN`、`HUGGING_FACE_HUB_TOKEN`、`HF_TOKEN_PATH`，且當未指定 `HF_TOKEN_PATH` 而預設 `~/.cache/huggingface/token` 存在時自動帶入。
  - 補齊 `qwen_asr_mlx_runner.py` 的離線環境變數清除、`modelDownloadRunner.run` 的 `inactivityTimeout: 300`，以及本機快取匯入的同目錄暫存 staging + 原子搬移。

### OPT-08（P1）：`GCloudAuthService` 子程序環境未白名單化與補齊 `PATH`，且預設專案快取永不更新
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextCore/GCloudAuthService.swift:122-127, 175-180`：呼叫 `runner.run` 時 `environment` 為 `nil`；依 `ProcessRunner.swift:216-218`，子程序直接繼承宿主完整環境變數。
  - `Sources/RecordToTextCore/GCloudAuthService.swift:41-42, 164-199`：`cachedToken` 有 30 分鐘有效期限，但 `cachedProjectID` 無任何 TTL。
- **【風險與影響】**：
  - 從 Finder／Dock 雙擊啟動 App 時，系統給予的 `PATH` 不含 `/opt/homebrew/bin` 與 `/usr/local/bin`，可能導致 Homebrew 安裝之 `gcloud` wrapper 找不到關聯 `python3` 或認證外掛【待環境確認：視使用者 Google Cloud SDK 為 Homebrew 公式或官方獨立套件而定】；從終端機啟動時則違反 `SECURITY.md:21` 最小環境變數原則。此外，App 開啟期間使用者若於終端機切換 `gcloud config set project`，未手動填寫 Project ID 的工作仍會誤用舊專案。
- **【具體改善方向】**：
  - 為 `GCloudAuthService` 建立專屬環境變數白名單（保留 `HOME`、`USER`、`LOGNAME`、`TMPDIR`、`CLOUDSDK_*`、`GOOGLE_APPLICATION_CREDENTIALS`、Proxy 與 SSL 憑證變數），並將 `executableURL` 所在目錄、`/opt/homebrew/bin`、`/usr/local/bin` 明確加入 `PATH`；為 `cachedProjectID` 加上 5 分鐘 TTL。

### OPT-09（P2）：未知／自訂雲端模型誤套用舊版 Flash 費率估價，且完成日誌與歷史摘要計費口徑不一致
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextCore/CloudTranscriptionModels.swift:277-306`：`estimatedCostUSD(modelID:)` 只精確排除 4 個預設字串，其餘未知／自訂或帶版號之 Gemini 4 模型（如 `gemini-4-neon-001`、`gemini-2.5-pro`）皆落入第 302 行 `else` 分支，硬套 `$0.75 / $3.75` 費率。
  - `Sources/RecordToTextApp/AppViewModel.swift:2719` 與 `Sources/RecordToTextCore/CloudTranscriptionModels.swift:266-272`：未如 `TranscriptionJob.cloudTokenSummary`（第 247 行）呼叫 `CloudTranscriptionMetadataAggregator.totalEstimatedCostUSD(metadata)`，仍將總 token 按單一模型費率重算。
- **【風險與影響】**：
  - 自訂模型顯示不實美元預估金額；多段 fallback 工作的卡片、日誌與重開後的 `RecentJobRow` 金額可能不一致（見 `docs/functional-review-2026-10-17.md:35`）。
- **【具體改善方向】**：
  - 移除 `estimatedCostUSD(modelID:)` 的 `else` 預設費率分支，未知模型與 `gemini-4` 前綴模型一律回傳 `nil`（僅顯示 token 數）；`appendCloudResultSummary` 改用 `totalEstimatedCostUSD(metadata)`，並於 `RecentJobSummary` 選填保存已算妥的 `estimatedCostUSD`。

### OPT-10（P2）：長駐 Qwen MLX Helper 閒置與切換雲端後不釋放數 GB 記憶體，且模型切換瞬間雙重駐留
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextApp/AppViewModel.swift:137-138, 2488-2496` 與 `Sources/RecordToTextCore/ASRBackend.swift:667, 817-838`：`reusableEngine` 與 `PersistentASRHelperSession` 建立後直到 App 結束前不會在佇列閒置或切換至 `googleAIStudio` 時停止。
  - `Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py:520-565`：`load_model_once` 在載入新模型（第 548 行）後才覆蓋全域 `_MODEL_CACHE`（第 553 行），新舊模型權重同時存在記憶體中。
- **【風險與影響】**：
  - `Qwen3-ASR-1.7B-bf16` 常駐約 3.8 GB 統一記憶體；在 16 GB Mac 上長時間不關 App 或改跑雲端工作時會持續佔用大量系統記憶體，同 session 切換模型時峰值可逾 6 GB【待環境確認：視使用者機型記憶體容量與同時開啟之應用程式負載而定】。
- **【具體改善方向】**：
  - `qwen_asr_mlx_runner.py` 載入新模型前先清空 `_MODEL_CACHE = None`、執行 `gc.collect()` 並釋放 MLX Metal 快取；`AppViewModel` 於佇列排空閒置滿 5 分鐘、或無執行中工作而切換至非 `.localQwen` 後端時，主動停止長駐 helper session。

### OPT-11（P2）：工具列預設本機模型選單雙重勾選、`README.md` 漏列雲端 `opencc` 依賴與主視窗單例收斂
- **【事實與程式碼證據】**：
  - `Sources/RecordToTextApp/MainWindow/ToolbarModelMenu.swift:24-34, 48-60` 與 `Sources/RecordToTextCore/QuickTranscriptionChoice.swift:5-15`：選單列出 3 款本機 Qwen 模型，但 `QuickTranscriptionChoice` 只含 `.qwen3ASR1_7BBF16`；選取預設 `1.7B 8-bit` 時 `selectedQuickTranscriptionChoice` 為 `nil`，觸發頂部額外顯示「目前自訂／進階選擇」勾選列。
  - `README.md:27, 106` 宣稱雲端模式不需 OpenCC，但 `Sources/RecordToTextCore/RuntimeEnvironment.swift:390-404, 467-475` 將 `.opencc` 列為 `googleAIStudio` 與 `vertexAI` 的必要元件。
  - `Sources/RecordToTextApp/RecordToTextApp.swift:95` 使用 `WindowGroup("record-to-text")` 綁定單一 `@StateObject viewModel`，若透過系統標籤列開新視窗會共用同一組 Sheet 狀態。
- **【風險與影響】**：
  - 選取預設本機模型時選單呈現重複且矛盾的「自訂選擇」標示；乾淨環境使用者照 `README.md` 測雲端模式會因缺 `opencc` 被環境檢查擋下；多視窗時 Sheet 行為異常。
- **【具體改善方向】**：
  - 在 `QuickTranscriptionChoice` 補齊 `1.7B 8-bit` 與 `0.6B 8-bit`（或於 `ToolbarModelMenu` 排除內建本機模型觸發自訂區塊）；同步修正 `README.md` 的雲端 `opencc` 說明；將主視窗 Scene 由 `WindowGroup` 改為 `Window("record-to-text", id: "main")`。

---

## 4. 明確排除項目（Out of Scope）與建議執行順序

### 4.1 明確排除項目（拒絕過度設計）
1. **不強行拆解 `AppViewModel.swift`（3,587 行）與 `TranscriptionEngine.swift`（3,545 行）**：誠如 `docs/code-size-review-2026-09-21.md:26` 所評估，兩者分別承載嚴密的 `@MainActor` 單工佇列與跨階段復原狀態機，在無業務變動下單純為縮減行數而拆成多個 Actor／Service，極易破壞取消競態防護與持久化時序。
2. **不引入 SQLite / SwiftData 取代 JSON Journal**：佇列與最近工作規模上限僅數十筆，現行 `JobPersistenceCoordinator` + `AtomicFileWriter` 已具備非同步合併寫入、損壞隔離（`LenientCollectionLoader`）與 SHA-256 發布憑據，無須引入資料庫遷移成本。
3. **不引入外部 SwiftPM 第三方套件**：維持純原生 Apple 框架實作，避免擴大供應鏈與簽署複雜度。
4. **不在本輪混做長程發佈里程碑**：受管理 Python Runtime 安裝器（`PD-006`）、Intel 實機驗證（`PD-005`）、自動檢查更新（`PD-015`）與 Windows 版移植（`docs/windows-edition-spec-2026-11-25.md`）維持各自獨立排程。

### 4.2 建議分階段執行順序
- **Phase 1 — 立即風險與發佈阻礙清零（P0：`OPT-01`、`OPT-02`、`OPT-03`）**：修正重複檔案確認之引擎同步、收緊 Files API 檔名驗證與日誌白名單、修復 `sign-app.sh` 內嵌執行檔簽署與 `verify-release.sh` 架構檢查。改動範圍獨立且低風險，建議優先合併。
- **Phase 2 — 轉錄可靠性與環境驗證強化（P1：`OPT-04`、`OPT-05`、`OPT-06`、`OPT-07`、`OPT-08`）**：補齊雲端磁碟空間預檢、背景信封回吐攔截、AI Studio／Vertex 真實模型連線測試與短逾時 Session、Hugging Face 憑證路徑與 `gcloud` 白名單環境。
- **Phase 3 — 體驗細節、記憶體回收與文件對齊（P2：`OPT-09`、`OPT-10`、`OPT-11`）**：收斂未知模型估價口徑、加入 Qwen 長駐 helper 閒置回收與模型切換清快取、修正工具列選單與 `README.md` 環境說明並改用單一 `Window` Scene。
