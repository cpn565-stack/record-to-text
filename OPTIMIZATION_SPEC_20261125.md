# record-to-text 優化改善技術規格書

- **制定日期**：2026-11-25
- **關聯建議書**：[`IMPROVEMENT_PROPOSAL_20261125.md`](IMPROVEMENT_PROPOSAL_20261125.md)
- **基準版本**：`0.2.1`（`DEFAULT_BUILD_NUMBER=22`，commit `bb15eed`）
- **目標平台**：macOS 14.0+（Swift 5.10 / SwiftPM）

---

## 1. 規格範疇與目標

### 1.1 涵蓋項目
本技術規格書定義 `IMPROVEMENT_PROPOSAL_20261125.md` 所列全部項目的可落地實作規格：
- **P0（立即修復）**：`OPT-01`（重複檔案確認引擎同步）、`OPT-02`（Files API 檔名驗證與雲端清理日誌去識別化）、`OPT-03`（內嵌 `ffmpeg`/`ffprobe` 簽署與打包驗證）。
- **P1（高價值改善）**：`OPT-04`（雲端磁碟空間預檢）、`OPT-05`（雲端錄音背景信封回吐攔截）、`OPT-06`（設定頁雲端模型可用性探測與短效 `URLSession`）、`OPT-07`（Hugging Face 憑證傳遞、MLX 離線變數重置與下載逾時防護）、`OPT-08`（`GCloudAuthService` 環境白名單與專案快取 TTL）。
- **P2（體驗與資源優化）**：`OPT-09`（移除未知模型猜測估價與統一歷史成本口徑）、`OPT-10`（長駐 Qwen Helper 閒置回收與切換前釋放權重）、`OPT-11`（工具列本機模型勾選、`README.md` `opencc` 說明與單一主視窗 `Window`）。

### 1.2 核心目標
1. **隱私與資安邊界零穿透**：後端切換即時同步所有待確認／待轉工作；雲端錯誤與清理日誌 100% 遵守 `CloudFailureDiagnostic` 白名單，遠端資源名稱必先驗證格式才帶金鑰發送請求。
2. **交付腳本由內而外合規**：確保開發包（ad-hoc）與正式發佈包（Developer ID + Hardened Runtime + 公證）對內嵌 `Contents/Helpers/*` 二進位檔簽章與架構驗證一致。
3. **轉錄前快速失敗（Fail-Fast）**：磁碟空間不足、API Key 無效、模型 ID 拼錯、Vertex 專案／區域無權限等問題皆於實際長音推論前精確攔截。
4. **完全向下相容**：不破壞既有 `settings.json`、`glossaries.json`、`job-journal.json`、`job-ledger.json`、`recent-jobs.json` 與 `Temp-Recovery` 檢查點格式。

### 1.3 非目標（Non-goals）
- 不變更現有雲端重試次數上限（每段／每模型最多 4 次）、20 秒網路重試倒數、HTTP 429 服務冷卻或單段時間預算（300s / 1,200s / 1,800s）。
- 不重構 `AppViewModel` 與 `TranscriptionEngine` 的既有佇列與持久化架構。
- 不實作受管理 Python Runtime 安裝器（`PD-006`）或自動更新檢查（`PD-015`）。

---

## 2. 模組化技術規格

### 2.1 佇列進件與重複檔案確認同步（`OPT-01`）
- **資料結構調整**（`Sources/RecordToTextApp/AppViewModel.swift`）：
  ```swift
  private struct IntakeContext {
      var settings: AppSettings          // 由 let 改為 var，允許隨引擎切換同步
      let prompt: PromptBuildResult
      let glossaryID: String?
      let glossaryName: String?
      let recordingContext: String
  }
  ```
- **處理流程與邊界條件**：
  1. 於 `synchronizeQueuedEngineSettings()`（`AppViewModel.swift:652-663`）新增對 `pendingDuplicateIntake` 的同步：當 `pendingDuplicateIntake != nil` 時，將引擎相關欄位（`backendType`、`selectedModels`、`googleAIStudioModelID`、`vertexAIModelID`、`vertexAIProjectID`、`vertexAILocation`、`vertexAIGCSBucket`、`vertexAIIncludeSummary`、`geminiThinkingLevelsByModel`、`cloudFallbackPolicy`、`silenceAwareCloudSegmentation`、`localSilenceAwareSegmentation`）由現行 `self.settings` 覆寫至 `pendingDuplicateIntake?.settings`，並保留加入當下原本的 `outputLocationMode`、`defaultOutputDirectory`、詞庫與 `recordingContext`。
  2. 於 `enqueueValidatedJobs(_:intake:)` 建立 `JobSnapshot` 時維持既有規則：若 `batchSettings.backendType == .localQwen`，快照可保留原 `recordingContext` 供切回雲端時參考（與 `AppRecordingContextTests.swift:70-75` 一致），但本機執行路徑絕不傳送雲端或讀取雲端憑證。

### 2.2 雲端資源名稱驗證與日誌去識別化（`OPT-02`）
- **介面與驗證規格**：
  1. **`GoogleAIStudioBackend.validateRemoteFileName(_ name: String) throws -> String`**：
     - 規則：`name.range(of: #"^files/[a-z0-9-]{1,40}$"#, options: .regularExpression) != nil`。
     - 套用點：`remoteFileMetadata(name:...)`、`finishFilesUpload(data:...)`（組裝 `pollURL` 前）與 `deleteRemoteFile(fileName:apiKey:)`（組裝 `deleteURL` 前）。驗證失敗於上傳階段拋出 `GoogleAIStudioError.fileUploadFailed("Files API 回傳無效的檔案識別碼")`，於刪除階段直接中止請求並回傳固定錯誤碼。
  2. **新增診斷階段與清理錯誤格式化**：
     - 於 `CloudDiagnosticStage`（`CloudJobDiagnostics.swift:3-10`）確認或新增 `case cleanup = "cleanup"`（`stageDisplayName` 對應 `"清理雲端暫存檔"`）。
     - `GoogleAIStudioBackend.deleteRemoteFile` 與 `VertexAIGeminiBackend.deleteGCSObject` 回傳型別改為 `CloudFailureDiagnostic?`（成功或 HTTP `200`/`204`/`404` 回傳 `nil`；非預期 HTTP 狀態回傳 `CloudFailureDiagnostic.http(statusCode, stage: .cleanup)`；網路例外回傳 `CloudFailureDiagnostic.classify(error, stage: .cleanup)`）。
     - `deleteRemoteFileShielded` 與 `deleteGCSObjectShielded`（僅限 `waitForCleanup == true` 分支）：日誌格式固定為 `"清理 Files API 暫存檔未完成（\(diagnostic.logCodeSummary)）。"`／`"清理 GCS 暫存檔未完成（\(diagnostic.logCodeSummary)）。"`，**嚴禁**輸出 `fileName`、`objectName`、`bucket` 或 `error.localizedDescription`。
     - `VertexAIGeminiBackend.swift:487` 改為 `logger?("info", "使用設定的 GCS 儲存貯體串流上傳音訊...")`；`VertexAIGeminiBackend.swift:1045-1060`（`waitForCleanup == false`）移除 `logger?` 呼叫，避免工作終止後背景 Task 補寫日誌。

### 2.3 簽署、開發打包與發佈驗證腳本（`OPT-03`）
- **`scripts/sign-app.sh` 由內而外簽署流程**：
  1. 先檢查 `${APP_PATH}/Contents/Helpers` 下所有一般可執行檔（`ffmpeg`、`ffprobe`），逐一執行：
     ```zsh
     codesign --force --timestamp --options runtime --sign "${IDENTITY}" "${helper_bin}"
     ```
     （注意：第三方 CLI 二進位檔不套用 App 主程式之 `Config/record-to-text.entitlements`，維持最小權限 Hardened Runtime）。
  2. 再對 `${APP_PATH}` 外層執行帶 `--entitlements "${PROJECT_DIR}/Config/record-to-text.entitlements"` 之簽署。
  3. 若外層已啟用透明壓縮需求，提示或允許搭配 `scripts/compact-app.sh` 後再次執行 `codesign --verify --deep --strict --verbose=2 "${APP_PATH}"`。
- **`scripts/package-development.sh` 與 `scripts/verify-release.sh`**：
  - `scripts/package-development.sh` 將 `ADHOC_SIGN=0` 改為 `ADHOC_SIGN=1`，使產出之開發測試 DMG 內的 `ffmpeg`、`ffprobe` 與修改過 `Info.plist` 的 `record-to-text.app` 具備一致的 ad-hoc 簽章；`verify-release.sh` 在 `ALLOW_UNSIGNED=1` 時若偵測到 `_CodeSignature` 存在，執行 `codesign --verify --deep --strict` 驗證結構完整性（不跑 `spctl` 與 `stapler`）。
  - `scripts/verify-release.sh` 新增對 `Contents/Helpers/ffmpeg` 與 `ffprobe` 的 `lipo -archs` 檢查：當 `REQUIRE_UNIVERSAL=1` 時，任一輔助執行檔缺少 `arm64` 或 `x86_64` 即以非零結束碼失敗並輸出明確錯誤訊息。

### 2.4 雲端轉錄磁碟空間預檢（`OPT-04`）
- **介面擴充**（`Sources/RecordToTextCore/AudioServices.swift`）：
  ```swift
  public func validateCloudDiskSpace(
      for metadata: AudioMetadata,
      temporaryDirectory: URL,
      outputDirectory: URL
  ) throws
  ```
- **計算公式與邊界條件**：
  - 雲端壓縮音訊為 16kHz 單聲道 24kbps MP3（約 `3_000 bytes/sec`）。預估工作暫存峰值 = `ceil(metadata.duration) * 6_000`（原始分段 MP3 + 切片緩衝）+ `33_554_432`（32 MiB，涵蓋 Inline Base64 JSON 請求暫存檔與合併文字暫存）+ `AudioProcessTimeouts.minimumTemporaryReserve`（使用 `addingReportingOverflow` 防溢位）。
  - 輸出區檢查沿用 `AudioProcessTimeouts.minimumOutputReserve`（當目標檔案系統不回報容量時維持現有容錯放行）。
- **呼叫時機**：於 `TranscriptionEngine.run`（`TranscriptionEngine.swift:445` 建立 `outputDirectory` 後、第 `456` 行分派 `googleAIStudio`／`vertexAI` 前）立即呼叫 `try probeService.validateCloudDiskSpace(for: metadata, temporaryDirectory: workingDirectory, outputDirectory: outputDirectory)`。

### 2.5 雲端錄音背景信封回吐攔截（`OPT-05`）
- **驗證規則擴充**（`Sources/RecordToTextCore/OutputContractValidator.swift`）：
  - 新增私有輔助函式 `recordingContextEchoCandidates(from block: String) -> [String]`：
    1. 完整 `removingWhitespace(from: block)`。
    2. 若 `block` 含 `【錄音背景開始】` 與 `【錄音背景結束】`，擷取包含起訖標記之子字串去空白版本，以及起訖標記中間之單行 `{"recording_context":...}` JSON 字串去空白版本。
  - 在 `validate(text:path:canonicalPrompt:terms:recordingContextBlock:)`（`OutputContractValidator.swift:31-46`）中：
    - 若任一非空 candidate 滿足 `normalized.hasPrefix(candidate) || normalized.hasSuffix(candidate)`，或 `withoutHeadings` 同時包含字面標記 `"【錄音背景開始】"` 與 `"【錄音背景結束】"`，立即拋出 `OutputContractValidationError.promptEcho(path)`。
    - 純口語對話出現背景內文（不含 `【錄音背景...】` 標記亦不含 `{"recording_context":` JSON 外殼）時維持放行，100% 相容 `CloudRecordingContextTests.testExplicitEchoRejectsEnvelopeButAllowsSpokenContext`。

### 2.6 雲端連線與所選模型可用性探測（`OPT-06`）
- **短效探測 Session**（`GeminiTransportHelper.swift`）：
  ```swift
  public static func makeInteractiveProbeSession(
      protocolClasses: [AnyClass]? = nil,
      timeoutSeconds: TimeInterval = 15
  ) -> URLSession
  ```
  - 設定：`URLSessionConfiguration.ephemeral`、`waitsForConnectivity = false`、`timeoutIntervalForRequest = timeoutSeconds`、`timeoutIntervalForResource = timeoutSeconds`。
- **Google AI Studio 模型與金鑰驗證**（`GoogleAIStudioBackend.swift`）：
  ```swift
  public struct CloudModelProbeResult: Equatable, Sendable {
      public let modelID: String
      public let displayName: String?
  }

  public func validateConnectionAndModel(
      apiKey: String,
      modelID: String
  ) async throws -> CloudModelProbeResult
  ```
  - 流程：
    1. 先執行 `Self.validateModelID(modelID)`；金鑰空白拋出 `.missingAPIKey`。
    2. 使用注入之 `urlSession`（`SettingsView` 傳入 `makeInteractiveProbeSession()` 並於 `defer { session.finishTasksAndInvalidate() }` 釋放）發送 `GET https://generativelanguage.googleapis.com/v1beta/models/\(modelID)`（附 `x-goog-api-key`）。
    3. HTTP `200`：解析選填 `displayName` 回傳成功。
    4. HTTP `400` / `401` / `403`：若訊息指向 API Key 無效則拋出 `.invalidAPIKey`，若為權限不足則回報清楚的權限說明；HTTP `404`：拋出專用錯誤或明確訊息「API Key 有效，但找不到模型 `\(modelID)` 或此帳號無權限使用」；HTTP `429` / `5xx`：維持 `.rateLimited` / `.requestFailed`。
- **Vertex AI 憑證、區域與模型探測**（`VertexAIGeminiBackend.swift` & `SettingsView.swift`）：
  ```swift
  public static func validateModelLocationCompatibility(modelID: String, location: String) throws
  public func validateConnectionAndModel(
      projectID: String?,
      location: String,
      modelID: String
  ) async throws -> String // 回傳實際解析之 projectID
  ```
  - 流程：
    1. 驗證 `gemini-4-neon` 與 `gemini-4-hydrogen` 若 `location` 不在 `["global", "us", "eu"]` 時直接回報區域不相容提示。
    2. 透過 `authService` 強制刷新取得 `resolvedProjectID` 與 `accessToken`，執行 `Self.validateEndpointParameters(...)`。
    3. 使用短效 `probeSession`（`defer` invalidate）向 `https://\(host)/v1/projects/\(resolvedProjectID)/locations/\(location)/publishers/google/models/\(modelID)` 發送 `GET`（若 publisher model GET 在特定區域回 `404`/`405`，退回極小純文字 `countTokens` 探測，不消耗生成輸出 token）。
    4. 明確區分：`gcloud` 憑證失敗、Project 未啟用 Vertex AI API / 缺 IAM 權限（`403`）、模型或區域不存在（`404`）、網路連線逾時。

### 2.7 本機模型下載憑證、離線環境重置與逾時防護（`OPT-07`）
- **共用 Hugging Face 環境組裝**（抽出內部輔助或同步更新 `ASRBackend.swift:1010-1057` 與 `AppViewModel.swift:3147-3181`）：
  1. `ASRBackend.helperEnvironment` 白名單補入 `"HF_TOKEN"`、`"HUGGING_FACE_HUB_TOKEN"`、`"HF_TOKEN_PATH"`。
  2. 在 `ASRBackend.helperEnvironment` 與 `AppViewModel.modelDownloadEnvironment` 中，當繼承環境未提供 `HF_TOKEN`、`HUGGING_FACE_HUB_TOKEN` 與 `HF_TOKEN_PATH` 時，檢查預設路徑 `~/.cache/huggingface/token` 是否為一般檔案；若是則設定 `environment["HF_TOKEN_PATH"] = defaultTokenPath`（不會把 token 明文讀進 Swift 記憶體或寫入 log）。
- **Python MLX Runner 環境變數重置**（`Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py:474-482`）：
  ```python
  if request.get("offline", False):
      os.environ["HF_HUB_OFFLINE"] = "1"
      os.environ["TRANSFORMERS_OFFLINE"] = "1"
  else:
      os.environ.pop("HF_HUB_OFFLINE", None)
      os.environ.pop("TRANSFORMERS_OFFLINE", None)
  ```
- **下載逾時與原子匯入**（`Sources/RecordToTextApp/AppViewModel.swift`）：
  - `performModelDownload` 呼叫 `modelDownloadRunner.run(...)` 補入 `timeout: 7_200`（2 小時硬上限）與 `inactivityTimeout: 300`（5 分鐘無輸出自動中斷）。
  - `copyModelFromDefaultHFCache` 改為先複製至同層暫存目錄 `.import-\(UUID().uuidString)`，驗證 `ModelCache.isDownloaded` 通過後再替換正式 `destination`，並在 `defer` 清理殘留暫存目錄。

### 2.8 `GCloudAuthService` 子程序環境白名單與專案快取 TTL（`OPT-08`）
- **環境變數白名單與 `PATH` 組裝**（`Sources/RecordToTextCore/GCloudAuthService.swift`）：
  - 新增 `private func gcloudEnvironment(executableURL: URL) -> [String: String]`：
    - 僅自 `ProcessInfo.processInfo.environment` 白名單複製非空值：`HOME`、`USER`、`LOGNAME`、`TMPDIR`、`LANG`、`LC_ALL`、`TZ`、`CLOUDSDK_CONFIG`、`CLOUDSDK_PYTHON`、`CLOUDSDK_PYTHON_ARGS`、`CLOUDSDK_ACTIVE_CONFIG_NAME`、`GOOGLE_APPLICATION_CREDENTIALS`、`HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY`、`http_proxy`、`https_proxy`、`no_proxy`、`SSL_CERT_FILE`、`SSL_CERT_DIR`。
    - `PATH` 固定組裝為去重後的 `[executableURL.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]`。
  - `getAccessToken` 與 `getDefaultProjectID` 呼叫 `runner.run(...)` 時一律傳入 `environment: gcloudEnvironment(executableURL: executableURL)`。
- **預設專案快取 TTL**：
  - 將 `cachedProjectID: String?` 改為 `CachedProject { let projectID: String; let expiresAt: Date }`，TTL 設為 `300` 秒（5 分鐘），避免終端機切換專案後長期失效。

### 2.9 雲端費用估算收斂與顯示一致性（`OPT-09`）
- **`CloudUsageMetadata.estimatedCostUSD(modelID:)`**（`Sources/RecordToTextCore/CloudTranscriptionModels.swift:277-306`）：
  - 將前綴 `modelID.lowercased().hasPrefix("gemini-4") || modelID.lowercased().contains("/gemini-4")` 一律回傳 `nil`。
  - 將第 302–306 行的 `else` 預設費率改為 `return nil`（僅保留明確匹配的歷史 `3.8`、`3.7`、`3.6`、`3.1-pro` 費率），杜絕未知自訂模型假造美元金額。
- **統一完成日誌與 `RecentJobSummary` 成本欄位**：
  - `AppViewModel.appendCloudResultSummary`（`AppViewModel.swift:2719`）改為呼叫 `CloudTranscriptionMetadataAggregator.totalEstimatedCostUSD(metadata)`。
  - `RecentJobSummary`（`Models.swift:1119-1213`）新增選填欄位 `public let cloudEstimatedCostUSD: Double?`（`init(job:)` 由 `CloudTranscriptionMetadataAggregator.totalEstimatedCostUSD(cloudMetadata)` 計算填入；舊 JSON 解碼為 `nil` 時，`RecentJobSummary.cloudTokenSummary` 退回 `cloudUsage?.summaryDisplay(modelID: model)`）。

### 2.10 本機 Qwen 長駐 Helper 記憶體回收（`OPT-10`）
- **Python 端切換模型前釋放舊權重**（`Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py:520-565`）：
  - 在 `load_model_once` 判定 cache miss 且 `_MODEL_CACHE is not None` 時，先執行：
    ```python
    _MODEL_CACHE = None
    gc.collect()
    try:
        import mlx.core as mx
        if hasattr(mx, "clear_cache"):
            mx.clear_cache()
        elif hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
            mx.metal.clear_cache()
    except Exception:
        pass
    ```
    再呼叫 `load_model(model_reference)`。
- **Swift 端閒置與跨後端回收**（`ASRBackend.swift`、`TranscriptionEngine.swift`、`AppViewModel.swift`）：
  - `HelperASRBackend` 新增 `public func stopPersistentSession()`（內部呼叫 `recyclePersistentSession()`），並由 `TranscriptionEngine.releaseIdleResources()` 轉發。
  - `AppViewModel` 新增 `private var idleEngineReleaseTask: Task<Void, Never>?`（預設閒置延遲 `300` 秒，可由 init 注入方便單元測試）：
    1. 當 `runJob` 啟動時取消 `idleEngineReleaseTask`。
    2. 當 `drainQueue()` 結束且 `!hasActiveJob && !hasQueuedJobs` 時，排程 300 秒後呼叫 `reusableEngine?.releaseIdleResources()`。
    3. 當 `setSetting` 將 `backendType` 改為非 `.localQwen` 且 `activeJobID == nil` 時，立即呼叫 `reusableEngine?.releaseIdleResources()`。

### 2.11 工具列本機模型勾選、文件依賴說明與單一視窗收斂（`OPT-11`）
- **`QuickTranscriptionChoice` 與 `ToolbarModelMenu`**：
  - 於 `QuickTranscriptionChoice`（`QuickTranscriptionChoice.swift:5-103`）新增 `case qwen3ASR1_7B8bit` 與 `case qwen3ASR0_6B8bit`，補齊 `displayName`、`backendType`、`applying(to:)` 與 `matches(_:)`；`ToolbarModelMenu.selectLocalModel` 統一透過對應 `QuickTranscriptionChoice` 或在頂部判斷排除所有 `viewModel.availableModels` 成員，消除選取預設 `1.7B 8-bit` 時的雙重勾選。
- **`README.md` 環境說明對齊**：
  - 修正 `README.md:22-27, 40-46, 106`：明確說明 Google AI Studio 與 Vertex AI 雖已內建 `ffmpeg`／`ffprobe`，但最終稿繁體字形統一仍需本機安裝 `opencc`（`brew install opencc`）。
- **主視窗單一 Scene**（`Sources/RecordToTextApp/RecordToTextApp.swift:95`）：
  - 將 `WindowGroup("record-to-text")` 改為 `Window("record-to-text", id: "main")`，防止透過視窗分頁列產生多個共用同一 `AppViewModel` Sheet 狀態的視窗實例。

---

## 3. 逐檔修改清單（File-by-File Change Plan）

| 動作 | 檔案路徑（相對根目錄） | 目標型別／函式／區塊 | 修改重點摘要 | 對應編號 |
| :---: | :--- | :--- | :--- | :---: |
| 修改 | `Sources/RecordToTextApp/AppViewModel.swift` | `IntakeContext`、`synchronizeQueuedEngineSettings()`、`appendCloudResultSummary`、`performModelDownload`、`copyModelFromDefaultHFCache`、`modelDownloadEnvironment`、`drainQueue`、`setSetting` | 同步 `pendingDuplicateIntake` 引擎設定；補齊 `HF_TOKEN_PATH`、下載 `inactivityTimeout: 300` 與 staging 原子匯入；完成日誌改用分段總成本；新增閒置／切雲端釋放長駐 helper | `OPT-01`, `OPT-07`, `OPT-09`, `OPT-10` |
| 修改 | `Sources/RecordToTextCore/GoogleAIStudioBackend.swift` | `validateRemoteFileName`、`validateConnectionAndModel`、`finishFilesUpload`、`deleteRemoteFileShielded`、`deleteRemoteFile` | 強制驗證 `^files/[a-z0-9-]{1,40}$`；新增所選模型探測 API；清理失敗改用 `CloudFailureDiagnostic` 白名單代碼 | `OPT-02`, `OPT-06` |
| 修改 | `Sources/RecordToTextCore/VertexAIGeminiBackend.swift` | `prepareAudioPart`、`validateModelLocationCompatibility`、`validateConnectionAndModel`、`deleteGCSObjectShielded`、`deleteGCSObject` | 移除日誌中 GCS `bucket` 與 `objectName` 明文及 `localizedDescription`；移除 `waitForCleanup == false` 之延遲 `logger`；新增專案／區域／模型連線探測 API | `OPT-02`, `OPT-06` |
| 修改 | `Sources/RecordToTextCore/CloudJobDiagnostics.swift` | `CloudDiagnosticStage` | 補入 `case cleanup = "cleanup"` 供遠端暫存檔清理錯誤白名單分類使用 | `OPT-02` |
| 修改 | `Sources/RecordToTextCore/GeminiTransportHelper.swift` | `stageDisplayName`、`makeInteractiveProbeSession` | 支援 `.cleanup` 顯示名稱；新增 `waitsForConnectivity = false`、15 秒逾時之探測專用 `URLSession` 工廠 | `OPT-02`, `OPT-06` |
| 修改 | `scripts/sign-app.sh` | 簽署主流程（L23-L31） | 先對 `Contents/Helpers/*` 執行 Developer ID + `--options runtime --timestamp` 簽署，再簽外層 `.app` | `OPT-03` |
| 修改 | `scripts/package-development.sh` | `build-app.sh` 呼叫參數（L18-L24） | 將 `ADHOC_SIGN=0` 改為 `ADHOC_SIGN=1`，確保 Apple Silicon 開發 DMG 內 bundle 簽章一致 | `OPT-03` |
| 修改 | `scripts/verify-release.sh` | 架構與未簽署驗證區段（L55-L68, L97-L121） | `REQUIRE_UNIVERSAL=1` 時同步以 `lipo -archs` 驗證 `Contents/Helpers/ffmpeg` 與 `ffprobe`；ad-hoc 存在時驗證結構簽章 | `OPT-03` |
| 修改 | `Sources/RecordToTextCore/AudioServices.swift` | `AudioProbeService.validateCloudDiskSpace` | 新增雲端 MP3 + JSON 暫存峰值估算與輸出目錄空間預檢 | `OPT-04` |
| 修改 | `Sources/RecordToTextCore/TranscriptionEngine.swift` | `run(...)`、`releaseIdleResources()` | 於進入雲端管線前執行 `validateCloudDiskSpace`；公開釋放閒置長駐 helper 介面 | `OPT-04`, `OPT-10` |
| 修改 | `Sources/RecordToTextCore/OutputContractValidator.swift` | `validate(text:path:canonicalPrompt:terms:recordingContextBlock:)` | 新增攔截 `【錄音背景開始】…【錄音背景結束】` 與單獨 `{"recording_context":…}` JSON 信封回吐 | `OPT-05` |
| 修改 | `Sources/RecordToTextApp/Sheets/SettingsView.swift` | `testGoogleAIStudioAPIKey()`、`testVertexAIAuthentication()` | 改用短效 `probeSession`（`defer` invalidate）並驗證目前選定之模型、區域與專案權限 | `OPT-06` |
| 修改 | `Sources/RecordToTextCore/ASRBackend.swift` | `helperEnvironment`、`stopPersistentSession()` | 白名單補入 `HF_TOKEN`、`HUGGING_FACE_HUB_TOKEN` 與預設 `HF_TOKEN_PATH`；公開停止長駐 session 方法 | `OPT-07`, `OPT-10` |
| 修改 | `Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py` | `configure_environment`、`load_model_once` | 補入 `import gc`；非離線時 `pop` 掉離線環境變數；切換模型載入前先清空 `_MODEL_CACHE` 與 Metal 快取 | `OPT-07`, `OPT-10` |
| 修改 | `Sources/RecordToTextCore/GCloudAuthService.swift` | `CachedProject`、`gcloudEnvironment`、`getAccessToken`、`getDefaultProjectID` | 建立最小環境變數白名單與前置 Homebrew `PATH`；`cachedProjectID` 加入 5 分鐘 TTL | `OPT-08` |
| 修改 | `Sources/RecordToTextCore/CloudTranscriptionModels.swift` | `RecentJobSummary.cloudTokenSummary`、`CloudUsageMetadata.estimatedCostUSD` | 移除未知模型 `else` 猜測費率並排除 `gemini-4*` 前綴；`RecentJobSummary` 優先使用持久化之精確分段總成本 | `OPT-09` |
| 修改 | `Sources/RecordToTextCore/Models.swift` | `RecentJobSummary` | 新增選填 `cloudEstimatedCostUSD: Double?`（保持 Codable 向下相容） | `OPT-09` |
| 修改 | `Sources/RecordToTextCore/QuickTranscriptionChoice.swift` | `QuickTranscriptionChoice` | 補入 `qwen3ASR1_7B8bit` 與 `qwen3ASR0_6B8bit` 選項與匹配邏輯 | `OPT-11` |
| 修改 | `Sources/RecordToTextApp/MainWindow/ToolbarModelMenu.swift` | `ToolbarModelMenu` | 對齊內建本機模型選擇狀態，消除預設 `1.7B 8-bit` 的重複自訂勾選區塊 | `OPT-11` |
| 修改 | `Sources/RecordToTextApp/RecordToTextApp.swift` | `RecordToTextApp.body` | 將 `WindowGroup("record-to-text")` 改為 `Window("record-to-text", id: "main")` | `OPT-11` |
| 修改 | `README.md` | 環境需求與快速自檢章節 | 補齊雲端模式需本機 `opencc` 之說明，與 `RuntimeEnvironment.swift` 一致 | `OPT-11` |
| 修改／新增 | `Tests/RecordToTextCoreTests/*` & `Tests/qwen_asr_mlx_runner_test.py` | 對應單元測試檔 | 補齊 `OPT-01`～`OPT-11` 自動化回歸測試（詳見第 5 章） | 全部 |

---

## 4. 向下相容、備份遷移與回滾策略

1. **JSON Schema 與持久化相容性**：
   - `settings.json`（`schemaVersion = 2`）、`job-journal.json`、`job-ledger.json` 結構完全不變，無須執行資料遷移。
   - `recent-jobs.json` 的 `RecentJobSummary` 僅新增 Optional 欄位 `cloudEstimatedCostUSD: Double?`：舊版紀錄缺少該鍵時自動解碼為 `nil`；若使用者退回舊版 App，標準 `JSONDecoder` 會自動忽略未知鍵 `cloudEstimatedCostUSD`，雙向升降級皆不會觸發隔離（quarantine）或資料遺失。
2. **檢查點與復原資料相容性**：
   - 本機 Qwen v2 `ASR_CONTRACT_VERSION`（`rec2t-local-asr-v2`）與雲端 `segment-manifest.json`（`schemaVersion = 3`）保持不變，升級前後未完成的檢查點工作可直接續跑。
3. **打包與回滾策略**：
   - 依專案慣例（見 `docs/NEXT_STEPS.md:19`），本機更新 `/Applications/record-to-text.app` 前，先確認無進行中轉錄工作，將現行 `.app` 備份至 `dist/install-backups/before-build23-<date>.noindex/`，並遞增 `Config/version.env` 之 `DEFAULT_BUILD_NUMBER=23`。
   - 如升級後發現異常，直接關閉 App 並將備份 `.app` 覆蓋回 `/Applications/` 即可無損回滾，所有 Application Support 資料與 Keychain 憑證維持原狀可用。

---

## 5. 驗收標準（Acceptance Criteria）與測試計畫

### 5.1 功能與資安驗收清單
- [ ] **AC-01（`OPT-01`）**：在 Google AI Studio 模式下拖入 `[a.wav, a.wav]` 觸發重複確認框，於確認前切換 `backendType` 為 `.localQwen`（或切換雲端模型），點擊「仍然加入」後，兩筆工作的 `snapshot.backendType` 與模型設定完全一致，且原本批鎖定的詞庫維持不變。
- [ ] **AC-02（`OPT-02`）**：模擬 Files API 回傳非法 `file.name`（如 `"files/../models/foo"` 或 `"https://evil.example"`）時，輪詢與 `DELETE` 均拒絕發送 HTTP 請求並拋出 `fileUploadFailed`；模擬 GCS／Files API 刪除遭遇含敏感 URL 之 `NSError` 時，`logLines` 不含 `bucket`、`objectName`、`fileName` 與原始 `localizedDescription`。
- [ ] **AC-03（`OPT-03`）**：執行 `scripts/package-development.sh` 產出之 `dist/record-to-text.app` 通過 `codesign --verify --deep --strict`；以臨時自我簽署憑證或 mock 驗證 `scripts/sign-app.sh` 會先簽署 `Contents/Helpers/ffmpeg` 與 `ffprobe` 再簽外層 `.app`；`REQUIRE_UNIVERSAL=1 scripts/verify-release.sh` 在 helper 僅有 `arm64` 時明確回傳非 0 退出碼。
- [ ] **AC-04（`OPT-04`）**：當暫存目錄或輸出目錄可用空間低於門檻時，`googleAIStudio` 與 `vertexAI` 工作在呼叫任何壓縮或雲端 API 前即拋出 `AudioServiceError.insufficientDiskSpace` / `insufficientDiskSpaceAt`。
- [ ] **AC-05（`OPT-05`）**：雲端回應開頭或結尾單獨回吐 `【錄音背景開始】{"recording_context":"..."}【錄音背景結束】` 或 `{"recording_context":"..."}` 時，被 `OutputContractValidator` 以 `promptEcho` 攔截；正常對話句子含背景文字時仍通過驗證。
- [ ] **AC-06（`OPT-06`）**：設定頁 AI Studio 與 Vertex AI「測試連線」使用 `waitsForConnectivity = false` Session（離線模擬下於 15 秒內快速失敗，不等待 1,200 秒），且能明確區分「憑證錯誤」、「模型不存在／無權限（404）」、「Neon/Hydrogen 不支援之 Vertex Location」與「連線成功」。
- [ ] **AC-07（`OPT-07`）**：`HelperASRBackend` 環境變數包含 `HF_TOKEN` 與預設 `HF_TOKEN_PATH`；`qwen_asr_mlx_runner.py` 連續處理 `offline=True` 後接 `offline=False` 請求時，`os.environ` 不殘留 `HF_HUB_OFFLINE`；手動下載模型具備 300 秒 inactivity timeout。
- [ ] **AC-08（`OPT-08`）**：`GCloudAuthService` 呼叫 `ProcessRunner` 時傳入之 `environment` 不含未白名單之外部憑證（如模擬 `GITHUB_TOKEN`），`PATH` 包含 `/opt/homebrew/bin` 與 `gcloud` 所在目錄，且預設 Project ID 於超過 TTL 後會重新查詢。
- [ ] **AC-09（`OPT-09`）**：`gemini-4-neon-001` 或任意未知自訂模型 ID 的 `estimatedCostUSD` 回傳 `nil`（僅顯示 token 數，不套用 `$0.75/$3.75`）；多模型 fallback 工作的卡片、完成日誌與 `RecentJobSummary` 顯示相同預估金額。
- [ ] **AC-10（`OPT-10`）**：`qwen_asr_mlx_runner.py` 切換載入不同 `modelID` 前會先清空舊 `_MODEL_CACHE` 並觸發 `gc.collect()`；`AppViewModel` 於無進行中工作時由 `.localQwen` 切往雲端後端，或佇列排空逾閒置門檻後，會停止長駐 Python helper 程序。
- [ ] **AC-11（`OPT-11`）**：選取預設 `Qwen3-ASR 1.7B 8-bit` 時，`ToolbarModelMenu` 不再出現「目前自訂／進階選擇」重複勾選列；`README.md` 已載明雲端模式需 `opencc`。

### 5.2 自動化與手動測試指令
實作完成後，依序執行下列檢查（所有自動化測試均使用本機合成音訊與 mock `URLProtocol`，**嚴禁**發送真實付費 Google API）：

```bash
# 1. Python helper 單元測試（含新增之 offline 環境變數重置與模型快取釋放測試）
python3 -B Tests/qwen_asr_chunking_test.py
python3 -B Tests/qwen_asr_local_checkpoint_test.py
python3 -B Tests/qwen_asr_mlx_runner_test.py

# 2. 完整專案門檻檢查（版本契約、repo hygiene、SelfTest、10 組 Pipeline 情境與完整 XCTest）
SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh

# 3. 驗證開發用 App Bundle 與 DMG 打包、ad-hoc 簽章及體積門檻
scripts/package-development.sh
codesign --verify --deep --strict --verbose=2 dist/record-to-text.app

# 4. 檢查空白字元與 Git 乾淨度
git diff --check
```
