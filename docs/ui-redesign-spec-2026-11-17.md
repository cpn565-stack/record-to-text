# record-to-text 前端 UI/UX 全面翻新規格書

- **日期**：2026-11-17（Asia/Taipei）
- **狀態**：設計規格已定稿（OD-1～OD-4 已拍板，待實作）
- **基準分支 / 版本**：`codex/log-visibility-retry-observability`（`0.2.1`，`DEFAULT_BUILD_NUMBER=21`）
- **實作範圍**：僅限 `Sources/RecordToTextApp/` 前端介面與互動層（不變動 `Sources/RecordToTextCore/` 資料契約與轉錄管線）
- **現況參考截圖**：[ui-before-2026-11-17.png](evidence/ui-before-2026-11-17.png)
- **品牌識別來源**：[AppIcon-1024.png](../Config/AppIcon-1024.png)

---

## 1. 目標與設計方向

### 1.1 設計願景

在功能與穩定性已趨成熟（長音分段、雲端串流重試與可展開診斷、完成後休眠、多模型支援、檢查點續跑）的基礎上，將整體介面升級為**沈穩、克制、原生 macOS 生產力工具**：

1. **降低視覺與文字噪音**：移除重複標題、巢狀卡片外框、過長的常駐說明段落與重複顯示的模型技術 ID，讓視線聚焦在「放入錄音」與「掌握進度／開啟文字稿」。
2. **漸進式揭露（Progressive Disclosure）**：日常流程保持極簡清爽；進階參數（詞庫、補充詞彙、錄音背景、執行日誌、分段診斷）透過 Popover 或展開面板隨需取用。
3. **操作顯性且就手**：常用動作（切換模型、開始轉文字、打開／預覽文字稿、重試失敗工作）直接可見且具明確層級，不把關鍵操作藏進 hover 或純圖示裡。
4. **一致的次要視窗體驗**：統一 `SettingsView`、`OnboardingView`、`GlossaryManagerView`、`EnvironmentCheckView`、`RecoveryScanView` 與 `PromptPreviewView` 的標頭、卡片選擇器與行動引導。

### 1.2 品牌色調定調

由 [AppIcon-1024.png](../Config/AppIcon-1024.png) 提取視覺語言：頂部靛紫（Indigo-Violet `#6E66C4`）漸層至深海軍藍（`#162B47`），搭配白色聲波與文字稿橫線。設計系統以此建立**靛青（Indigo）為主軸**、搭配系統語意色的冷靜專業調性。

---

## 2. 現況診斷（依截圖與現有程式碼盤點）

對照 [ui-before-2026-11-17.png](evidence/ui-before-2026-11-17.png) 與現行 `Sources/RecordToTextApp/` 實作，整理出以下介面與體驗痛點：

| 編號 | 問題類別 | 現況問題描述 | 影響 |
| --- | --- | --- | --- |
| D-01 | **標頭冗餘** | 視窗標題列已顯示 `record-to-text`，滾動內容區頂部又放置 `28pt` 的 `record-to-text` 大標題與副標題 | 佔用寶貴首屏垂直空間，且資訊重複 |
| D-02 | **Toolbar 圖示模糊** | 右上角 `text.book.closed`、`checkmark.shield`、`externaldrive.badge.timemachine`、`gearshape` 全為純圖示無標籤；其中 `externaldrive.badge.timemachine` 在小尺寸下外觀近似汽車 | 初次或低頻使用難以辨識按鈕用途，增加記憶負擔 |
| D-03 | **模型選單過載** | 頂部選單上方寫著「新錄音與尚未開始的工作」小字，內部 `QuickTranscriptionChoice.allCases` 為 13 筆扁平清單，且名稱同時含長前綴與模型名 | 掃視困難、文字過長，選單定位不夠直覺 |
| D-04 | **Intake Card 混雜與過早收縮** | 同一個 `AppCard`（`.regularMaterial`）塞入「轉錄設定」Disclosure、DropZone、休眠核取方塊、「合併文字稿…」按鈕與「輸出位置」；且 DropZone 只要 `!viewModel.jobs.isEmpty`（即使全部工作都已完成）就縮成扁條 | 控制項性質混雜，且僅剩歷史完成紀錄時拖放入口反而不明顯 |
| D-05 | **雙層巢狀卡片** | `queueCard` 外層已經是 `.regularMaterial` 圓角卡片，內部每筆 `JobRowView` 又是一張 `.controlBackgroundColor` 圓角框卡片 | 雙重邊框與多餘內距產生視覺重量與壓迫感 |
| D-06 | **工作卡資訊重複與原始 ID 外露** | 每筆雲端工作第一行顯示 `Vertex AI · gemini-4-hydrogen`，第二行又重複 `・gemini-4-hydrogen`；模型名稱直接顯示 raw ID 而非人類可讀名稱 | 畫面充斥重複技術字串，重要資訊（完成時間、耗時、Token）被擠在一起 |
| D-07 | **已完成列夾帶多餘日誌摘要** | 已完成工作仍透過 `statusSummary(from:)` 顯示「轉錄完成！已儲存至：… / 完成，耗時 5 分 51 秒。」，與上方「完成 12:52」及展開日誌功能重疊 | 列表高度拉長、每列資訊密度過高 |
| D-08 | **次要按鈕過小且缺提示層級** | `JobRowView` 與 `RecentJobRow` 右上操作為 3 個無邊框純圖示（`folder`、`doc.text`、`trash`），最重要的「打開文字檔」沒有主按鈕視覺權重；`timestampNotice` 直接以整段橘字裸露 | 核心交付結果（文字檔）不夠突出；警告缺乏容器區隔 |
| D-09 | **設定頁分類與文案過重** | `SettingsView` 僅 `640×520`；「一般」分頁塞入開發除錯用的「關於此 App（含 bundle path）」；「Runtime」分頁用 Segmented Picker 切換三大截然不同後端並堆滿長段落說明文字 | 閱讀負擔重，使用者不易確認哪個引擎已設定完成 |
| D-10 | **Onboarding 缺乏實際選擇** | `OnboardingView` 第一步僅靜態條列說明雲端／本機差異，無法直接選定預設後端，也未呈現 App Icon 建立品牌信任感 | 新手仍需自行摸索去「設定」找引擎開關 |

---

## 3. 設計原則與 Design Tokens

實作時須在 `Sources/RecordToTextApp/DesignSystem/` 建立集中管理的 Token，禁止在各 View 散落 magic numbers。

### 3.1 色彩系統（`AppColors`）

專案採 SwiftPM 建置（無 Xcode `.xcassets`），顏色須以程式碼定義於 `AppColors` 並確保自動支援 Light / Dark Mode 與 High Contrast。

| Token 名稱 | 建議定義 | 用途 |
| --- | --- | --- |
| `AppColors.accent` | `Color(nsColor: .systemIndigo)`（＝ SwiftUI `Color.indigo`；系統自動提供 Light／Dark／增加對比變體，**不要**自訂 hex） | 主行動按鈕（`.borderedProminent`）、進行中左導引線、Active 進度條漸層、拖放高亮框（根視圖套用 `.tint(AppColors.accent)`） |
| `AppColors.success` | `Color.green` | 轉錄完成（無缺口）、環境就緒、API 連線測試成功 |
| `AppColors.warning` | `Color.orange` | 完成但含缺口、可復原的中斷工作、Google/網路暫停冷卻、遺失檔案、時間戳提醒 |
| `AppColors.danger` | `Color.red` | 失敗狀態、欄位驗證錯誤、破壞性刪除動作 |
| `AppColors.neutral` | `Color.secondary` | 等待中、已取消、次要 metadata |
| `AppColors.windowBackground` | `Color(nsColor: .windowBackgroundColor)` | 主視窗底色（乾淨底布） |
| `AppColors.cardBackground` | `Color(nsColor: .controlBackgroundColor)` | 工作列、Composer 卡片、設定分組卡片底色 |
| `AppColors.insetSurface` | `Color(nsColor: .textBackgroundColor).opacity(0.65)` | 日誌展開區、TextEditor、路徑預覽底色 |
| `AppColors.hairlineBorder` | `Color(nsColor: .separatorColor).opacity(0.5)` | 卡片與工作列邊框（1pt；High Contrast 下提高對比） |
| `AppColors.statusTintOpacity` | `0.09`（Callout 底色）／ `0.05`（Active Row 底色） | 狀態 Callout（紅／橙／綠）與進行中工作微底色 |

> **macOS 26 (Tahoe) Liquid Glass 相容性規範**：
> 專案 `Package.swift` 設定 `platforms: [.macOS(.v14)]`，開發環境為 Xcode 26.6 / macOS 26.6.2。若在 Toolbar 膠囊、Bottom Action Bar 或浮動徽章採用 macOS 26 Liquid Glass API（例如 `.glassEffect(...)`），**必須**使用 `if #available(macOS 26.0, *)` 包裝，並提供 macOS 14–15 的 `.regularMaterial`／`controlBackgroundColor` fallback；實際 API 簽章須於實作階段對照 macOS 26 SDK 確認後使用。

### 3.2 字體排印（`AppTypography`）

| 階層 | SwiftUI Font 規格 | 用途 |
| --- | --- | --- |
| `sectionTitle` | `.headline` | 佇列區段標頭（進行中／等待中／已結束） |
| `rowTitle` | `.body.weight(.semibold)`（macOS 13pt） | 工作檔名、Composer 主提示標題（由現行 `.subheadline` 提升一階，增強可掃視性） |
| `rowMeta` | `.callout` 或 `.subheadline` 搭配 `.foregroundStyle(.secondary)` | 狀態、後端、模型、完成時間、輸出檔名等次要列 |
| `chipLabel` | `.caption.weight(.medium)` | Composer 設定膠囊與狀態標籤 |
| `numericMeta` | `.callout.monospacedDigit()` / `.caption.monospacedDigit()` | 計時器、Token 數量、字數計數器 `0 / 500`、分秒倒數 |
| `monoDetail` | `.caption.monospaced()` | 展開執行日誌、分段診斷、檔名後綴預覽、系統路徑 |

### 3.3 間距與圓角（`AppSpacing` & `AppRadius`）

- **間距尺度（4pt Grid）**：`xs = 4`、`sm = 8`、`md = 12`、`lg = 16`、`xl = 20`、`xxl = 24`、`xxxl = 32`
- **圓角尺度（`AppRadius`）**：
  - `badge = 6`：小型標籤（如 `WAV`、`可取回部分稿`、狀態小 Tag）
  - `row = 10`：工作列（`JobRowView` / `RecentJobRow`）、Callout 框、文字編輯框
  - `composer = 14`：Composer 卡片與 Hero 拖放區
  - Chips 與控制按鈕：全膠囊 `Capsule()`

### 3.4 狀態圖示與顏色標準表

| 狀態 | SF Symbol | 主色 | 備註 |
| --- | --- | --- | --- |
| 排隊中 (`queued`) | `clock` | `.secondary` | 可從佇列移除、可對單檔切半 |
| 進行中 (`active`) | `waveform.circle.fill` | `AppColors.accent` | `!reduceMotion` 時可加 `.symbolEffect(.variableColor.iterative)`；卡片左側顯示 `3pt` Accent 膠囊線 |
| 雲端等待／冷卻 (`serviceRecovery` / `networkRecovery` 暫停或等待) | `pause.circle.fill` / `arrow.clockwise.circle.fill` | `.orange` | 暫停狀態改用橙色提示可介入（如立刻重試／重送） |
| 完成（完整 `complete`） | `checkmark.circle.fill` | `.green` | 剛完成時給予短暫綠色高亮脈衝 |
| 完成（含缺口 `hasGaps`） | `exclamationmark.triangle.fill` | `.orange` | 顯示「完成（含缺口）」與「重送未完成片段」按鈕 |
| 失敗 (`failed`) | `exclamationmark.circle.fill` | `.red` | 顯示錯誤 Callout 與復原操作 |
| 上次工作被中斷 (`interrupted`) | `arrow.clockwise.circle.fill`（或 `pause.circle.fill`） | `.orange` | **由原本灰色改為橙色**，明確傳達「可檢查點續跑／重試」 |
| 已取消 (`cancelled`) | `minus.circle.fill` | `.secondary` | 可重新加入或刪除 |
| 最近工作遺失檔案 (`fileStatus != .available`) | `folder.badge.questionmark` | `.orange` | 明確區別於轉錄失敗 |

---

## 4. 主視窗架構與四種核心狀態

### 4.1 佈局結構決策：單欄焦點視窗（Single-Column Window）

維持單欄視窗架構（不採用左側 NavigationSplitView 側欄），理由如下：
- 核心作業線性明確：**調整設定 → 拖入錄音 → 啟動與觀察進度 → 打開文字稿**。
- 歷史紀錄屬於輔助回查，不需長期佔據 220pt 側欄寬度；維持 `minWidth: 760, minHeight: 680`（預設 `900×780`）可讓主視窗在筆電半屏也能優雅使用。

視窗由上而下劃分為四個清晰區域：
1. **Window Chrome & Unified Toolbar**：原生視窗標題 + `.navigationSubtitle` 動態狀態摘要 + 右側分組工具列。
2. **Composer（新工作區）**：自適應拖放區（Hero / Compact）+ 設定膠囊列（`SettingChipsBar`）。
3. **Job List（無外框分區清單）**：直接置於視窗底色之上，依序分為「進行中」、「等待中」、「已結束」（支援折疊較早工作）。
4. **Sticky Bottom Action Bar（`.safeAreaInset(edge: .bottom)`）**：僅在有等待中工作、進行中工作、或休眠倒數時出現，固定提供啟動、切分、休眠選項與取消操作。

### 4.2 Unified Toolbar 規格

移除捲動區內的 `28pt` `record-to-text` 大標題與副標題，改用標準 macOS Toolbar 承載：

- **標題與副標題**：
  - 視窗標題維持 `"record-to-text"`
  - `.navigationSubtitle(...)` 依狀態動態顯示簡明摘要：
    - 閒置就緒：`就緒 · Vertex AI · Gemini 4 Hydrogen`（隨所選後端與短模型名變化）
    - 等待啟動資料載入：`正在載入啟動資料，完成後會開始`（搭配行內 Banner 提供「取消開始」）
    - 排隊中：`等待中 2 筆 · 準備使用 AI Studio`
    - 執行中：`轉錄中（1／3）：HQ-HD-R03.m4a`
- **Toolbar Actions（由左至右）**：
  1. **`ToolbarModelMenu`（模型切換器）**：
     - 外觀：膠囊按鈕顯示 Provider 圖示（`cloud.fill` / `apple.logo` / `cpu`）+ 精簡模型名（例如 `Vertex AI · Gemini 4 Hydrogen` 或僅模型名搭配小 Provider Tag）+ 上下箭頭。
     - 選單內容：依後端分成三個 `Section`（不再使用 13 項扁平清單）：
       - `Google AI Studio`（Gemini 4 Hydrogen / Carbon / Argon / 3.8 Flash / 3.7 Flash / 3.5 Transcribe）
       - `Google Cloud Vertex AI`（同上）
       - `本機 Qwen（不上雲）`（Qwen3-ASR 1.7B BF16）
     - 每筆項目可附 1 行簡短副標或選單分區標題，選單底部附「更多模型與引擎設定…」直接開啟設定分頁。
     - 選擇 `gemini-3.5-transcribe` 時，若已展開提示或於錄音背景 Chip 上標註「專用轉錄不使用背景」，取代原本擠在標題右上角的兩行灰字。
  2. **`詞庫管理` 按鈕**：使用 `Label("詞庫管理", systemImage: "text.book.closed")`，工具列顯示明確標籤或提示（快捷鍵 `⌘⇧L`）。
  3. **`工具` 下拉選單（`Menu`）**：收整低頻率／輔助功能，取代原本難以辨識的小圖示：
     - `合併文字稿…`（`arrow.triangle.merge`，快捷鍵 `⌘⇧M`）
     - Divider
     - `環境檢查…`（`checkmark.shield`）
     - `復原掃描…`（`externaldrive.badge.timemachine` / `tray.and.arrow.down`）
  4. **`設定` 按鈕**：`SettingsLink`（`gearshape`，快捷鍵 `⌘,`）。

### 4.3 Composer（新工作與設定膠囊區）

`ComposerView` 是唯一頂部卡片，內部結構精簡為兩層：

1. **自適應 `DropZoneView`**：
   - **展開判準修正**：改以 `!viewModel.hasQueuedJobs && !viewModel.hasActiveJob` 判斷是否為 **Hero 大拖放區**（舊版用 `!viewModel.jobs.isEmpty` 導致只要底下有已完成工作，拖放區就被迫縮扁）。
   - **Hero 態**：包含大型階層感 `waveform.badge.plus` 圖示、`將錄音拖入視窗`、支援格式副標（`M4A、MP3、WAV、AAC、FLAC`）、主色 Prominent 按鈕「選擇錄音檔…」（`⌘O`）。若 `jobs.isEmpty && recentJobs.isEmpty`（完全空狀態），在下方顯示精簡 3 步驟導引列（`1. 調整詞庫或背景 → 2. 拖入錄音 → 3. 點擊開始轉文字`）。
   - **Compact 態**（有工作在等待或執行中時）：單列橫向高度約 `52pt`，左側圖示與「拖入更多錄音以加入佇列（M4A、MP3、WAV、AAC、FLAC）」，右側次按鈕「選擇錄音檔…」。
2. **設定膠囊列（`SettingChipsBar`）**：
   - 取代原本厚重的 `DisclosureGroup`，以橫向自動換行排列 4 顆可點擊膠囊（各自開啟專屬 `Popover` 或 `Menu`）：
     1. **專案詞庫 Chip**：顯示 `詞庫：不使用` 或 `詞庫：<名稱>`；點擊開啟 Popover，內含專案詞庫 `Picker`、「管理詞庫…」按鈕與「預覽轉錄提示」連結。
     2. **本次補充 Chip**：顯示 `補充詞彙：4 個`（無詞彙時顯示 `+ 補充詞彙`）；若解析錯誤則邊框轉紅。點擊開啟 Popover，內含多行 `TextEditor`、分隔字元說明與即時詞彙統計。
     3. **錄音背景 Chip**（僅 `backendType != .localQwen` 顯示）：顯示 `錄音背景：未填寫` 或 `錄音背景：48/500 字`；若 `gemini-3.5-transcribe` 則顯示灰階鎖定態（`專用轉錄不使用背景`）並附 tooltip；超過 500 字時邊框轉紅。點擊開啟 Popover，內含 `TextEditor`、`0 / 500` 等寬計數器與情境說明。
     4. **輸出位置 Chip**：顯示資料夾圖示 + 精簡位置（例如 `輸出：轉出的文字`、`輸出：與來源同資料夾`、`輸出：每次詢問`），hover `.help` 顯示完整路徑。點擊開啟選單／Popover，可切換輸出模式、選擇預設資料夾或「在 Finder 顯示」。
   - **靜態噪音移除**：原「詞庫與背景於加入時固定；模型可於開始前切換」、「加入後不會自動開始」等提示不再常駐佔版面，移入對應 Chip Popover 底部說明與 Tooltip。

### 4.4 佇列與歷史清單（`JobListView`）

移除整個清單外層的 `AppCard` 包裹，直接在 `ScrollView` 內呈現三個語意分區（無項目時該分區不渲染）：

1. **進行中（Active）**：顯示正在執行（`activeJobID`）或正處於雲端恢復暫停（`isCloudRecoveryPaused`）的工作，數量通常為 0～1。
2. **等待中（Queued）**：顯示 `stage == .queued` 的工作與數量計數（如 `等待中 · 2`）。
3. **已結束（Finished）**：
   - 合併現存 `jobs` 中所有 `stage.isTerminal`（扣除恢復暫停中）與去重後的 `recentJobs`，依 `completedAt ?? startedAt` 降序排列（live job 可再退回 `createdAt`；`RecentJobSummary` 沒有 `createdAt`，退回 `.distantPast`）。
   - 右側 Section Header 放置「刪除全部已結束」（維持確認對話框）。
   - **分組收合機制**：預設展開前 **5 筆**（或「今天」的工作），第 6 筆以後／「更早之前」收合於可展開的 `DisclosureGroup`（「較早紀錄（N）」），避免歷史清單無止盡拉長視窗。

### 4.5 Sticky Bottom Action Bar（`QueueActionBar`）

僅在 `viewModel.hasQueuedJobs || viewModel.hasActiveJob || viewModel.queueSleep.countdownUntil != nil || viewModel.queueSleep.message != nil` 時顯示於視窗底部（`.safeAreaInset(edge: .bottom)`），以 `.regularMaterial` 搭配頂部 `1pt` 分隔線固定：

- **情境 A（有排隊中工作 `hasQueuedJobs`）**：
  - 左側：`等待 N 筆 · 將以 <簡短後端> · <簡短模型> 執行` + `完成後讓電腦休眠` 核取方塊（詳細條件移至 `.help()`）。
  - 右側：若有可切分工作（`hasSplittableQueuedJobs`），顯示「切分再依序轉」（單一工作為 Button，多筆為 Menu）+ Prominent 主按鈕「開始轉文字」（`⌘↩`）。
- **情境 B（僅有執行中工作，無排隊工作）**：
  - 左側：執行中工作摘要 + `完成後讓電腦休眠` 核取方塊（執行途中仍可勾選或取消）。
  - 右側：Destructive 風格「取消目前工作」（`⌘.`）。
- **情境 C（休眠倒數或狀態訊息）**：
  - 醒目橫條顯示 `轉檔已全部成功，MM:SS 後休眠` 與「取消休眠」按鈕（或 `queueSleep.message` 通知）。

### 4.6 四種核心狀態 ASCII 線框圖

#### State 1：首次／空狀態（Empty State）
```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   record-to-text                                                       │
│         就緒 · Vertex AI · Gemini 4 Hydrogen                                 │
│                       [ ☁ Gemini 4 Hydrogen ▾ ] [ 詞庫管理 ] [ 工具 ▾ ] [ ⚙ ] │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                                                                        │  │
│  │                            ((( 🎙+ )))                                 │  │
│  │                         將錄音拖入視窗                                  │  │
│  │                     M4A、MP3、WAV、AAC、FLAC                            │  │
│  │                                                                        │  │
│  │                        [ 選擇錄音檔… (⌘O) ]                             │  │
│  │                                                                        │  │
│  │   ① 設定詞庫或背景  ───▶  ② 拖入錄音檔  ───▶  ③ 開始轉成台灣繁體逐字稿      │  │
│  │                                                                        │  │
│  │  ────────────────────────────────────────────────────────────────────  │  │
│  │  ( 詞庫：不使用 ▾ )  ( + 補充詞彙 )  ( 錄音背景：未填寫 )  ( 輸出：轉出的文字 ▾ ) │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### State 2：已加入佇列等待開始（Queued State）
```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   record-to-text                                                       │
│         等待中 2 筆 · 將以 Vertex AI 執行                                      │
│                       [ ☁ Gemini 4 Hydrogen ▾ ] [ 詞庫管理 ] [ 工具 ▾ ] [ ⚙ ] │
├──────────────────────────────────────────────────────────────────────────────┤
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  🎙+  拖入更多錄音檔（M4A、MP3、WAV、AAC、FLAC）         [ 選擇錄音檔… ] │  │
│  │  ( 詞庫：半導體 ▾ ) ( 補充詞彙：4 個 ) ( 錄音背景：已填 ) ( 輸出：轉出的文字 ▾ )│  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  等待中 · 2                                                                   │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  🕒  20261117-客戶訪談-Part1.m4a                                    ✕  │  │
│  │      等待中 · Vertex AI · Gemini 4 Hydrogen · 詞庫：半導體               │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  🕒  20261117-客戶訪談-Part2.m4a                                    ✕  │  │
│  │      等待中 · Vertex AI · Gemini 4 Hydrogen · 詞庫：半導體               │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  將執行 2 筆 · [ ] 全部成功後休眠        [ ✂ 切分再依序轉 ]  [ ▶ 開始轉文字 ]  │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### State 3：轉錄進行中（Running State）
```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   record-to-text                                                       │
│         轉錄中：20261117-客戶訪談-Part1.m4a                                    │
│                       [ ☁ Gemini 4 Hydrogen ▾ ] [ 詞庫管理 ] [ 工具 ▾ ] [ ⚙ ] │
├──────────────────────────────────────────────────────────────────────────────┤
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  🎙+  拖入更多錄音檔（M4A、MP3、WAV、AAC、FLAC）         [ 選擇錄音檔… ] │  │
│  │  ( 詞庫：半導體 ▾ ) ( 補充詞彙：4 個 ) ( 錄音背景：已填 ) ( 輸出：轉出的文字 ▾ )│  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  進行中                                                                       │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │┃ ◉  20261117-客戶訪談-Part1.m4a                         02:41   [ ■ ]  │  │
│  │┃    Vertex AI · Gemini 4 Hydrogen · 第 2／4 段                         │  │
│  │┃                                                                       │  │
│  │┃    ✓ 準備音訊 ── ◉ 模型轉錄 ── ○ 繁體校正 ── ○ 寫入檔案                 │  │
│  │┃    █████████████░░░░░░░░░░░░░░░░░░░░░  已完成 1／4 段                 │  │
│  │┃    Gemini 轉錄中 · 第 2／4 段 · 本段已耗時 48 秒                        │  │
│  │┃                                                                       │  │
│  │┃    正在由 gemini-4-hydrogen 第 2/4 段 忠實轉錄。                        │  │
│  │┃    ▾ 展開日誌（14）   複製除錯資訊                                      │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  [ ] 全部成功後休眠                                        [ ■ 取消目前工作 ]  │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### State 4：完成與異常檢視（Completed & Failed States）
```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   record-to-text                                                       │
│         已完成 3 筆 · 就緒                                                    │
│                       [ ☁ Gemini 4 Hydrogen ▾ ] [ 詞庫管理 ] [ 工具 ▾ ] [ ⚙ ] │
├──────────────────────────────────────────────────────────────────────────────┤
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                        ((( 🎙+ ))) 將錄音拖入視窗        [ 選擇錄音檔… ] │  │
│  │                         M4A、MP3、WAV、AAC、FLAC                        │  │
│  │  ( 詞庫：不使用 ▾ )  ( + 補充詞彙 )  ( 錄音背景：未填寫 )  ( 輸出：轉出的文字 ▾ ) │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  已結束                                                   [ 🗑 刪除全部已結束 ] │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  ✅  HQ-HD-R03-20261117-宋小余.m4a           [ 👁 ] [ 打開文字檔 ] [ ⋯ ] │  │
│  │      完成 12:52 · 耗時 5分51秒 · Vertex AI · Gemini 4 Hydrogen · 126.0k │  │
│  │      輸出：HQ-HD-R03-20261117-宋小余_逐字稿.txt                          │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  ⚠   HQ-KD-R01-20261117-陈学军.m4a           [ 👁 ] [ 打開文字檔 ] [ ⋯ ] │  │
│  │      完成 13:00 · 耗時 7分54秒 · Vertex AI · Gemini 4 Hydrogen · 156.9k │  │
│  │      ┌──────────────────────────────────────────────────────────────┐  │  │
│  │      │ ⚠ 1 個片段的段內時間待核對；全文已保留，請依稿內實際音訊範圍回查。  │  │  │
│  │      └──────────────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  ❌  HQ-BAD-20261117-會議.m4a                     [ ↻ 重試 ]     [ ⋯ ] │  │
│  │      失敗 · Vertex AI · Gemini 4 Hydrogen                              │  │
│  │      ┌──────────────────────────────────────────────────────────────┐  │  │
│  │      │ 雲端回應逾時或網路中斷，已完成第 1／3 段，已保留可續跑檢查點。     │  │  │
│  │      │ [ 重送未完成片段 ]   [ 打開未完成稿 ]   [ 在 Finder 顯示復原資料 ] │  │  │
│  │      └──────────────────────────────────────────────────────────────┘  │  │
│  │      ▸ 展開日誌（28）   複製除錯資訊                                     │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ▸ 較早紀錄（6）                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 元件詳細規格

### 5.1 UI-Only 模型與後端名稱對映（`JobModelDisplayHelper`）

僅存在於 `RecordToTextApp` 層，**不改動** `RecordToTextCore` 的 `cloudModelSummary` 或 `JobDebugClipboard.dump` 輸出格式：

- **後端短標籤**：
  - `.googleAIStudio` → `"AI Studio"`
  - `.vertexAI` → `"Vertex AI"`
  - `.localQwen` → `"本機 Qwen"`
- **模型短顯示名稱**：
  - 查表 `GeminiModelDescriptor.presetModels`（`id == rawModelID`）取得 `preset.displayName`（例如 `"gemini-4-hydrogen"` → `"Gemini 4 Hydrogen"`）。
  - 本機 Qwen 查表 `ASRModelDescriptor.descriptor(id:)` 取得 `displayName`（例如 `"Qwen3-ASR 1.7B BF16"`）。
  - 自訂或未知模型 ID 則直接回傳原字串。
  - 若發生自動降級 fallback（實際模型與要求模型不同），UI 顯示 `"Gemini 3.8 Flash → 3.6 Flash"`（並將完整對照留在 Tooltip 與診斷面板）。

### 5.2 進行中工作進度與 Stage Stepper（`ActiveJobProgressView`）

1. **4 階段視覺里程碑（Stage Stepper）**：
   將 `TranscriptionStage` 的細粒度狀態收斂成使用者一眼可懂的四步進度條：
   - **步驟 1 準備音訊**：`.validating`、`.preparingRuntime`、`.downloadingModel`、`.convertingAudio`、`.loadingModel`
   - **步驟 2 模型轉錄**：`.transcribing`
   - **步驟 3 繁體校正**：`.convertingTraditionalChinese`
   - **步驟 4 寫入檔案**：`.writingOutput`
   - 已完成步驟顯示綠色小勾，進行中步驟使用 `AppColors.accent` 高亮點，未開始步驟使用灰階圓點（760pt 窄寬度下保持單列不折行）。
2. **`BreathingProgressBar` 行為契約（嚴禁破壞）**：
   - 保持 `displayedFraction(at:)` 既有運算：完成段數佔 `completedSegments / totalSegments`，進行中段落以 `estimatedSegmentSeconds` 推估並**嚴格限制上限為 `0.90`**，絕對不可在未收到段完成或安全缺口前滿格或倒退。
   - `.postprocessing`（繁體校正與寫入階段）進度條維持 100% 滿格，不倒退。
   - `@Environment(\.accessibilityReduceMotion)` 為 `true` 時，停止閃爍呼吸漸層動畫，改為靜態漸層；且更新週期從 `0.35s` 放緩為 `1s`。
3. **時間資訊**：
   - `JobElapsedView`（`TimelineView(.periodic(from: .now, by: 1))`）**僅渲染於進行中工作列**，顯示已執行總時長 `HH:MM:SS`（`.monospacedDigit()`）。
   - 若為雲端分段轉錄，可於進度列下方副標呈現 `第 X／Y 段 · 已完成 K 段`（有先前段延遲紀錄時附本段預估參考）。
4. **網路／服務恢復 Inline Callout**：
   - `serviceRecovery`（`.coolingDown` / `.retrying`）或 `networkRecovery`（`.waiting` / `.retrying`）以圓角橙色 Callout 呈現，保留 1 秒倒數與「立刻重試」按鈕（`canRetryNetworkImmediately`）。
5. **執行中白話摘要與展開日誌**：
   - 顯示 `JobDebugClipboard.statusSummary(from: job.logLines)` 最多 2 句白話最新訊息。
   - 下方保留 `展開日誌（N）`／`收合日誌` 與 `複製除錯資訊`，由父層 `MainView` 的 `JobLogExpansionState` 管理狀態，確保每 30 秒新增心跳日誌時**不自動收合**也不強拉捲動位置。

### 5.3 已完成、失敗、取消與中斷工作列（`JobRowView` / `RecentJobRow`）

1. **統一外觀結構**：
   - 合併 live terminal `JobRowView` 與歸檔 `RecentJobRow` 的視覺規格（底色 `AppColors.cardBackground`、邊框 `AppColors.hairlineBorder`、`10pt` 圓角、`12pt` 內距），讓使用者在畫面上感受一致，不會因 App 重啟歸檔而外觀突變。
   - 當某筆工作剛由進行中轉為 `.completed`（無缺口）時，該列短暫閃現柔和綠色邊框／底色 Highlight（約 `1.5s` 後淡出，Respect Reduce Motion），並使該最新完成列的「打開文字檔」按鈕使用 `.borderedProminent` 樣式（其餘舊完成列用 `.bordered`）。
2. **已完成列資訊精簡**：
   - **移除**「轉錄完成！已儲存至：… / 完成，耗時…」日誌摘要文字。
   - 第 1 行：狀態圖示 + 檔名（`.body.weight(.semibold)`）+ 右側顯性操作列。
   - 第 2 行（單行整合 metadata）：`完成 12:52 · 耗時 5分51秒 · Vertex AI · Gemini 4 Hydrogen · 126.0k tokens (思考 40.3k)`（若使用詞庫則補 `· 詞庫：<名稱>`）。
   - 第 3 行（如有輸出檔）：`輸出：<檔名>.txt`（使用 `.caption` 搭配 `.middle` 截斷，點擊或右鍵可打開）。
   - 若 `outputGapReason != nil` 或 `timestampNotice != nil` 或檔案遺失（`fileStatus != .available`）：放進統一的圓角橙色 `InlineCallout` 框，不再直接輸出裸體長橘字。
3. **顯性操作與更多選單（拒絕 Hover-Only 隱藏）**：
   - **已完成工作**：
     - Quick Look 快速預覽按鈕（圖示 `eye`，以 `.quickLookPreview` 預覽文字檔，檔案存在時啟用）
     - 主要文字按鈕：`打開文字檔`（`.borderedProminent` 若為最新完成且無缺口，否則 `.bordered`）
     - `⋯` 更多選單（`Menu`）：
       - `在 Finder 顯示`
       - `展開日誌／診斷`（若有日誌或 `cloudDiagnostics`）
       - `複製除錯資訊`
       - `檢視轉錄提示`（僅 live job 有 `snapshot`）
       - `用目前設定建立新工作`（若來源音訊仍存在）
       - Divider → `從列表刪除`（`.destructive`，觸發確認框）
   - **失敗／已取消／上次工作被中斷**：
     - 右上顯性操作：`重試`（或雲端斷點存在時優先顯示 `重送未完成片段`）+ `⋯` 更多選單（`用目前設定建立新工作`、`檢視轉錄提示`、`複製除錯資訊`、`從列表刪除`）。
     - 紅／橙色 Callout 區塊顯示 `failure.userMessage`，並在下方以小型膠囊按鈕排列復原動作：`打開未完成稿`、`從已完成 Qwen chunk 續跑`、`在 Finder 顯示復原資料`、`刪除保留資料…`。
   - **右鍵選單（`.contextMenu`）**：完整保留現行項目，與 `⋯` 更多選單行為一致。
4. **開發者模式專屬除錯捷徑**：
   - 依設計原則，當 `viewModel.settings.developerMode == true` 時，可在展開後的 `JobDebugPanel` 標頭補入快速診斷資訊（如 Job UUID 一鍵複製、成本與重試次數小標籤），平常不干擾一般使用者。

### 5.4 Quick Look 內建預覽（`QuickLookPreview`）

- 在 `JobListView`（父層）持有單一 `@State private var previewURL: URL?`，並掛上 SwiftUI `.quickLookPreview($previewURL)`（`import QuickLook`，macOS 11+，無需 `QLPreviewPanel` 資料來源／responder chain）。
- 完成列 `eye` 按鈕僅設定 `previewURL = URL(fileURLWithPath: outputPath)`；按鈕是否可用依 `.onAppear`／`.onChange` 快取的「輸出檔存在」狀態決定（不得在 `body` 內呼叫 `FileManager`）。
- 檔案不存在時按鈕停用並以 `.help("文字檔已移動或刪除")` 說明；不預覽原始音檔、不預覽未完成稿（未完成稿維持 `openPartialTranscript`）。

---

## 6. 次要視窗與 Sheet 規格

所有 Sheet 共用統一的 `SheetHeader` 元件（標題 `.title2.weight(.semibold)`、單行副標題 `.callout.foregroundStyle(.secondary)`、右上角次要動作與 `.defaultAction`「完成／關閉」按鈕），搭配統一 `20pt–22pt` 外距與底部 `Divider`。

### 6.1 設定視窗（`SettingsView`）

視窗寬度放寬為 **`680pt`**，高度依分頁內容自適應（建議 `minHeight: 500, idealHeight: 580`），分為四個語意清晰的分頁：

| 分頁名稱（新） | 圖示 | 內容重組與改進要點 |
| --- | --- | --- |
| **一般** | `switch.2` | 保留「工作流程」（完成後在 Finder 顯示、打開文字檔、保留 Qwen 原始逐字稿）與「通知」開關。**將「關於此 App」移出此頁**至「資料與關於」，使一般頁乾淨專注。 |
| **轉錄引擎** *(原 `Runtime` 改名)* | `cpu` | 1. 頂部改為 **3 張並排視覺化選擇卡（`BackendSelectionCard`）**：`Google AI Studio`、`Vertex AI`、`本機 Qwen`。每張卡片顯示圖示、名稱、一句隱私／方式說明與**狀態 Badge**（如「已存 Key」、「已設定專案」、「未設定」、「本機離線」）。<br>2. 下方依所選後端群組化呈現 `Form` 區段：**連線與憑證**、**模型與思考強度**、**分段與後處理**。<br>3. 保留既有測試必要 ID：`gemini-model-picker`、`gemini-custom-model-id`、`gemini-apply-custom-model`、`gemini-thinking-level-picker`。<br>4. 過長的技術說明（如 OpenCC、Thinking 耗時、Silence-aware 細節）精簡為 1 行短說明，補充細節收入輔助 `?` Popover 或 `DisclosureGroup`。 |
| **輸出** | `folder` | 保留輸出位置模式與資料夾選擇器；「檔名格式」新增更直覺的**即時檔名預覽卡片**（左顯示 `錄音.m4a` → 右顯示 `錄音_逐字稿.txt` 標籤）；編碼資訊維持精簡。 |
| **資料與關於** *(原 `儲存` 擴充)* | `externaldrive` | 1. **最近工作**：保留筆數 `Stepper` 與清除記錄。<br>2. **App 資料**：`Application Support` 路徑搭配**「複製路徑」**與「在 Finder 顯示」雙按鈕。<br>3. **關於此 App**（從一般頁移入）：版本、建置與執行路徑（附複製按鈕）、長音預切策略（20 分鐘）、單段輸出上限（16,384 tokens）。<br>4. **重設**：維持雙層確認對話框（保留詞庫重設／全部重設）。 |

### 6.2 首次引導（`OnboardingView`）

維持 `680 × 520` 視窗與上方膠囊進度條（3 步），升級每步驟互動性：

1. **Step 1：認識與選擇轉錄方式**
   - 頂部顯示真實 App Icon（`Image(nsImage: NSApp.applicationIconImage)` 尺寸 `64×64` 圓角陰影）取代通用 SF Symbol。
   - 下方提供 **3 張可點選的 `BackendSelectionCard`**（點選時呼叫 `viewModel.setSetting(\.backendType, to:)` 後 `viewModel.refreshEnvironment()`；`settings` 為 `private(set)`，不可直接雙向綁定），使用者在引導階段就能決定走 AI Studio、Vertex AI 或本機 Qwen，並清楚看見隱私與長音分段特點。
2. **Step 2：選擇文字稿的家**
   - 顯示目前預設輸出資料夾路徑卡片 +「選擇其他資料夾…」+ 簡潔提醒（亦可事後於設定切換為與來源同資料夾）。
3. **Step 3：確認轉錄環境**
   - 自動執行 `viewModel.refreshEnvironment()` 並顯示狀態 Banner。
   - 若環境未就緒，除「查看詳情」外提供直達修復按鈕（「前往設定…」可於結束引導後自動開啟設定，或直接提示缺少元件名稱）。

### 6.3 詞庫管理（`GlossaryManagerView`）

保留 `HSplitView`（`760 × 540`），強化編輯體驗：
- **共用 `SheetHeader`**：標題與一句說明。
- **Sidebar 升級**：
  - 頂部加入搜尋篩選框（即時依詞庫名稱過濾專案詞庫）。
  - 「共用詞彙」與每個專案詞庫右側顯示**詞彙數量膠囊 Badge**（例如 `12`）。
- **編輯器狀態回饋**：
  - 偵測 `draftName` 或 `draftTerms` 與已存狀態不同時，於標題旁顯示橙色小圓點「未儲存變更」（Unsaved Dot），並於切換詞庫／關閉前維持現有儲存保護。
  - 按下「儲存」（`⌘S`）後於底部工具列顯示短暫綠色 Toast「已儲存」（約 1.5 秒淡出）。

### 6.4 環境檢查（`EnvironmentCheckView`）

- 改用共用 `SheetHeader`。
- 每個 `EnvironmentComponentRow` 新增語意化 Badge（`就緒` / `缺少` / `未驗證`），當元件未就緒且具明確指引時（例如缺 Google API Key 或未開啟開發 Runtime），右側提供快捷引導按鈕（如「切換開發 Runtime」或「複製安裝提示」）。

### 6.5 復原掃描（`RecoveryScanView`）

- 改用共用 `SheetHeader`。
- 頂部 3 顆統計 Chip（可取回／孤立暫存／損壞異常）統一圓角 `10pt` 與語意底色 tint。
- 每筆 `RecoveryScanRow` 的技術標籤（`WAV`、`recovery.json`、`manifest`、`可取回部分稿`）依語意著色（如 `可取回部分稿` 用綠色或靛青強調），動作按鈕排列整齊且不於 680pt 寬度折行。

### 6.6 轉錄提示預覽（`PromptPreviewView`）

- 改用共用 `SheetHeader`，並在「完成」旁新增「複製提示詞」按鈕（附已複製確認回饋），方便除錯或與他人核對詞彙提示。

---

## 7. 系統整合、文案與無障礙規格

### 7.1 系統整合（Dock Badge & Menu Commands）

1. **Dock Tile Badge**：
   - 在 `AppViewModel` 計算 `pendingWorkCount = jobs.filter { !$0.stage.isTerminal }.count`（即進行中 + 排隊中工作總數）。
   - 於 MainActor 更新 `NSApp.dockTile.badgeLabel = pendingWorkCount > 0 ? "\(pendingWorkCount)" : nil`（於初始化、佇列異動及 App 終止清理時同步更新）。
   - *註：MenuBarExtra 常駐狀態列列為後續低優先級增強項目，不納入本版必須範圍。*
2. **選單列與鍵盤快捷鍵**：
   - **保留**：`⌘O`（選擇錄音檔…）、`⌘↩`（開始轉文字）、`⌘.`（取消目前工作）、`⌘,`（設定）、`⌘S`（詞庫管理儲存）、`Return`（Sheet 完成）。
   - **新增**：
     - `⌘⇧L`：打開「詞庫管理…」
     - `⌘⇧M`：執行「合併文字稿…」
     - （以上快捷鍵於 `RecordToTextApp.swift` `.commands` 宣告，經核對無既有衝突。）

### 7.2 文案精簡原則

- 刪除主畫面重複說明文字（「詞庫與背景於加入時固定；模型可於開始前切換」、「加入後不會自動開始」、「可直接選取切半後的多份 TXT；原檔不會被覆寫。」），將補充解釋納入 Tooltip（`.help()`）或對應 Popover 內部副標。
- 狀態字詞簡短明確：如「完成 12:52」而非重複兩次狀態與長句；失敗或缺口只用一句白話引導下一步行動。

### 7.3 無障礙與視覺適應性

- **VoiceOver**：
  - `DropZoneView`、`ActiveJobProgressView` 與所有 Setting Chips 皆須設定清晰的 `accessibilityLabel`、`accessibilityValue` 與 `accessibilityHint`（使用 `.accessibilityElement(children: .combine)` 避免多餘碎片朗讀）。
  - 既有的 4 個 `accessibilityIdentifier`（`gemini-model-picker`、`gemini-custom-model-id`、`gemini-apply-custom-model`、`gemini-thinking-level-picker`）**必須原封不動保留**。
- **動態字體與視窗最小尺寸**：
  - 主視窗 `minWidth: 760, minHeight: 680` 下所有工具列按鈕、Setting Chips（採 Flow/Wrapping 佈局）、工作列操作按鈕皆不可截斷或重疊。
- **Reduce Motion & High Contrast**：
  - `@Environment(\.accessibilityReduceMotion)` 為 `true` 時，停用 SF Symbol `.symbolEffect`、呼吸進度條脈動、及展開／完成高亮過渡動畫。
  - High Contrast 下邊框不依賴低透明度白／灰線，採用系統 `separatorColor` 實色或提高 opacity。

---

## 8. 效能與工程護欄（Guardrails）

1. **Core 邊界不越線**：不得修改 `Sources/RecordToTextCore/` 內的 `AppSettings`、`JobSnapshot`、`TranscriptionJob`、`RecentJobSummary` Codable schema 或 `TranscriptionEngine` 管線契約。所有 UI 專用型別（如模型短名稱對映、階段 Stepper 對映）皆寫在 `Sources/RecordToTextApp/`。
2. **測試與診斷 API 相容性**：
   - 必須完整保留 `JobLogExpansionState`（`isExpanded` / `setExpanded` / `toggle` / `prune`）與 `JobDebugClipboard` 的所有 static 方法簽章及回傳格式（包含 `statusSummary(from:)`、`isDebugLine(_:)`、`logToggleTitle(...)`、`recentDiagnosticsToggleTitle(...)`、`expandedContent(for:)`、`dump(...)`），確保 `Tests/RecordToTextCoreTests/JobDebugClipboardTests.swift` 100% 通過。
3. **防止 SwiftUI Graph Hang（SelectionOverlay 風險）**：
   - 承襲 [ui-polish-2026-09-09.md](ui-polish-2026-09-09.md) 經驗，**禁止**在頻繁更新的進行中工作列主體、模型標籤或狀態摘要上掛載 `.textSelection(.enabled)`（靜態展開後的 `ExpandableDebugTextPanel` 內文與設定頁路徑才允許選取）。
4. **檔案系統 I/O 不進 `body`**：
   - `FileManager.default.fileExists`（判斷來源／輸出檔是否存在、Quick Look 是否可用）只能透過 `.onAppear` 與 `.onChange` 快取到 `@State`，嚴禁於 `body` 計算屬性同步存取磁碟。
5. **Timer 更新隔離**：
   - `TimelineView` 計時器僅限縮在 `ActiveJobProgressView` / `JobElapsedView` / `BreathingProgressBar` 等正在執行中的元件內，避免造成整張 `LazyVStack` 每秒重繪。
6. **拖放與破壞性防護**：
   - 保留主視窗全區單一 `.onDrop(of: [UTType.fileURL])` 目的端。
   - 保留所有破壞性確認對話框（刪除全部已結束、從列表刪除、刪除復原資料、刪除詞庫、重設設定／詞庫）。
   - 保留所有非破壞性對話框與 Sheet 掛載：重複檔案確認（`isDuplicateConfirmationPresented`）、不用詞庫重試同意（`isPromptConsentPresented`）、`alert`、Onboarding（`interactiveDismissDisabled`）、詞庫管理、環境檢查、復原掃描、轉錄提示預覽。
7. **移除大標題後仍須保留的狀態提示**：
   - `jobPersistenceError`：Composer 上方顯示橙色 `InlineCallout`「工作紀錄尚未儲存」＋錯誤內容＋「重試儲存」（`retryJobPersistence()`），不可因移除 `titleBlock` 而消失。
   - `isWaitingForStartup`：Composer 上方顯示資訊 Callout「正在載入啟動資料，完成後會開始」＋「取消開始」（`cancelPendingStart`）。
8. **測試依賴的 View 入口**：`JobDebugClipboardTests.testMainViewRendersWithExpandableJobAndRecentDiagnostics` 直接以 `MainView(viewModel:)` 建構並放入 `NSHostingView`；拆檔後 `MainView` 名稱與此初始化器必須維持。

---

## 9. 檔案重構藍圖

現行 [MainView.swift](../Sources/RecordToTextApp/MainView.swift) 達 1,938 行，應趁本次改版按職責拆分至子資料夾（`Package.swift` 已指定 `path: "Sources/RecordToTextApp"`，新增子目錄會自動納入編譯）：

```text
Sources/RecordToTextApp/
├── RecordToTextApp.swift                 # App 入口、Menu Commands（含 ⌘⇧M / ⌘⇧L）
├── AppViewModel.swift                    # 既有 VM（補充 Dock badge 同步與設定輔助計算屬性）
├── QueueCompletionSleepCoordinator.swift # 休眠協調（QueueSleepControls 可移至 MainWindow 或保留）
├── GoogleAIStudioCredentialStore.swift
├── JobPersistenceError.swift
│
├── DesignSystem/
│   ├── AppColors.swift                   # Brand Indigo、語意色、Surfaces、macOS 26 availability helper
│   ├── AppSpacing.swift                  # 4pt Grid 間距與 AppRadius 常數
│   ├── AppTypography.swift               # 字級與等寬數字樣式輔助
│   └── AppComponents.swift               # AppCard、SheetHeader、StatusBadge、InlineCallout、SettingChip
│
├── MainWindow/
│   ├── MainView.swift                    # 主視窗殼、Toolbar、Global Drop Target、Sheets & Dialogs 掛載
│   ├── ToolbarModelMenu.swift            # 分組模型選單與工具 Overflow 選單
│   ├── ComposerView.swift                # 新工作組裝區容器
│   ├── DropZoneView.swift                # Hero / Compact 自適應拖放區 + 3 步導引
│   ├── SettingChipsBar.swift             # 詞庫、補充詞彙、錄音背景、輸出位置膠囊與 Popovers
│   ├── QueueActionBar.swift              # 底部 Sticky Action Bar（開始／切分／休眠／取消）
│   ├── JobListView.swift                 # 進行中／等待中／已結束（含可折疊較早紀錄）分區清單
│   ├── JobRowView.swift                  # 佇列／進行／完成／失敗統一工作卡片與操作鈕
│   ├── ActiveJobProgressView.swift       # Stage Stepper、BreathingProgressBar、計時器與恢復 Callout
│   ├── RecentJobRow.swift                # 已歸檔紀錄列（與完成態視覺統一）
│   ├── JobModelDisplayHelper.swift       # UI-only 後端與模型友善名稱對映
│   ├── JobDebugPanel.swift               # JobLogExpansionState、JobDebugClipboard、ExpandableDebugTextPanel
│   └── QuickLookPreview.swift            # `.quickLookPreview` 綁定與輸出檔存在狀態快取
│
└── Sheets/
    ├── SettingsView.swift                # 4 分頁重組（一般／轉錄引擎／輸出／資料與關於）
    ├── BackendSelectionCard.swift        # 設定頁與 Onboarding 共用的 3 後端視覺卡片
    ├── GeminiModelPicker.swift           # 既有模型選擇器（保留 accessibilityIdentifier）
    ├── OnboardingView.swift              # 含 AppIcon、後端卡片、輸出與環境檢查的 3 步引導
    ├── GlossaryManagerView.swift         # 含搜尋、詞數 Badge、Unsaved Dot 與已儲存 Toast
    ├── EnvironmentCheckView.swift        # 統一 SheetHeader 與元件修復快捷鈕
    ├── RecoveryScanView.swift            # 統一 SheetHeader 與色碼統計 Chips
    └── PromptPreviewView.swift           # 統一 SheetHeader 與一鍵複製提示詞
```

---

## 10. 分階段實作計畫與驗收標準

| Phase | 範圍與工作項目 | 完成定義（DoD） |
| --- | --- | --- |
| **Phase 1：Design System 與純重構拆檔** | 建立 `DesignSystem/`、`MainWindow/`、`Sheets/`；將 `MainView.swift` 拆分為獨立檔案，先**不改變**既有視覺與功能行為。 | 1. Swift build 零錯誤，且不新增編譯警告。<br>2. `./scripts/run-checks.sh` 與 `JobDebugClipboardTests` 全數通過。<br>3. 確認 `Package.swift` 與資源檔案路徑正常打包。 |
| **Phase 2：主視窗框架、Toolbar 與 Composer** | 移除重複大標題改用 `.navigationSubtitle`；實作 `ToolbarModelMenu`（分組選單 + 工具選單）；打造 `ComposerView`（Hero/Compact 自適應 `DropZoneView`、`SettingChipsBar` Popovers）與 `QueueActionBar`（Sticky Bottom Bar）。 | 1. 空狀態／僅有完成工作時皆顯示開闊 Hero Drop Zone。<br>2. 4 顆 Setting Chips 在 760pt 寬度正常換行且 Popover 讀寫與舊版 `AppViewModel` 狀態同步。<br>3. 底部 Bar 的開始、切分、休眠與取消行為與快捷鍵完全可用。 |
| **Phase 3：工作佇列分區與卡片重設計** | 移除佇列外層 `AppCard`；實作「進行中／等待中／已結束（含可折疊較早紀錄）」；翻新 `JobRowView` 與 `RecentJobRow`（`JobModelDisplayHelper`、Stage Stepper、精簡完成列、顯性按鈕與 `⋯` 選單、錯誤 Callout）、`QuickLookPreview` 與 Dock Badge。 | 1. 模型顯示友善名稱、不再重複顯示技術字串。<br>2. 完成工作支援 Quick Look 預覽與「打開文字檔」。<br>3. 進行中工作 `BreathingProgressBar` 與展開日誌在心跳更新時穩定不跳動、不收合。<br>4. Dock Badge 正確反映執行中 + 排隊中數量並於歸零時消失。 |
| **Phase 4：次要視窗與 Sheet 翻新** | 實作共用 `SheetHeader` 與 `BackendSelectionCard`；重組 `SettingsView` 4 分頁；更新 `OnboardingView`（含真實 App Icon 與可選後端卡）、`GlossaryManagerView`（搜尋／Badge／Unsaved Dot／Toast）、`EnvironmentCheckView`、`RecoveryScanView` 與 `PromptPreviewView`。 | 1. 所有既有無障礙識別碼（`gemini-*`）與自動儲存／Keychain 邏輯正常運作。<br>2. `SettingsView` 680pt 寬度無裁切；Onboarding 可直接切換後端並反映至主視窗。 |
| **Phase 5：視覺打磨、無障礙與全面驗證** | 核對 Light / Dark Mode、macOS 26 vs 14–15 fallback、High Contrast、Reduce Motion、VoiceOver 與 760pt 最小寬度截圖審查。 | 1. 執行 `./scripts/run-checks.sh`（含全部 XCTest）通過。<br>2. 產出實機跑起來的前後對比截圖並歸檔至 `docs/evidence/`。 |

---

## 11. QA 驗證矩陣

| 測試面向 | 檢查項目 | 預期結果 |
| --- | --- | --- |
| **自動化驗證腳本** | `./scripts/run-checks.sh`（Swift build、Python tests、Self-Test、10 個 Mock Pipeline 情境、XCTest、Bundle 打包） | 全部通過，0 failures；`JobDebugClipboardTests` 100% 通過 |
| **視窗尺寸適應** | `760×680`（最小）、`900×780`（預設）、`1280×900`（寬屏） | 無文字截斷、按鈕重疊、或 Toolbar 溢位；Setting Chips 自然換行 |
| **外觀與系統偏好** | Light Mode、Dark Mode、High Contrast、Reduce Motion | 對比清晰；Reduce Motion 下無呼吸／符號動畫；macOS 26 與 fallback 視覺一致 |
| **核心拖放與工作流程** | 全視窗拖放多檔 → 設詞庫／背景 → `⌘↩` 開始 → 切半 → 合併文字稿 → 休眠倒數 | 單一 Drop Target 正常接收；Snapshot 正確鎖定；休眠倒數與取消正常 |
| **雲端與本機異常態** | 進行中展開日誌、Google 429 冷卻、網路中斷立刻重試、完成含缺口、失敗含部分稿／Qwen chunk 續跑 | 進行中展開日誌不自動收合或跳位；各 Callout 操作與確認對話框正確觸發 |
| **次要視窗與系統整合** | Settings 4 分頁、Onboarding 3 步、詞庫搜尋與儲存、Quick Look 預覽、Dock Badge | 快捷鍵 `⌘O`/`⌘↩`/`⌘.`/`⌘⇧L`/`⌘⇧M`/`⌘,` 無衝突；Dock 數字準確 |
| **效能與無卡頓檢查** | 載入 20+ 筆最近工作與即時更新進行中長日誌（100+ 行） | 滑動流暢、無 `SelectionOverlay` 卡頓、非進行中列無每秒重建 |

---

## 12. 已拍板設計決策（Confirmed Decisions）

以下 4 項關鍵架構與互動選擇已於 2026-11-17 經使用者確認，後續實作代理應直接依定案內容施工：

| 編號 | 決策議題 | 拍板定案（實作基準） | 備註 |
| --- | --- | --- | --- |
| **OD-1** | **主題強調色來源** | **採用選項 A（Brand Indigo）**：固定使用與 AppIcon 同色系的系統 Indigo（`Color(nsColor: .systemIndigo)`），於 `MainView`、`SettingsView` 與各 Sheet 根視圖套用 `.tint(AppColors.accent)`。 | 不用自訂 hex，交給 macOS 處理深色模式與增加對比 |
| **OD-2** | **Composer 轉錄設定呈現** | **採用選項 A（4 顆膠囊 Chips + Popover）**：以「專案詞庫」、「補充詞彙」、「錄音背景」、「輸出位置」膠囊展開 Popover，維持主畫面極簡高度。 | — |
| **OD-3** | **「已完成」與「最近工作」分區** | **採用選項 A（單一「已結束」分區）**：合併 live 完成工作與已歸檔 `recentJobs`，預設展開最新 5 筆、其餘收合於「較早紀錄（N）」。 | 仍保留 `RecentJobSummary` 與 `TranscriptionJob` 各自底層資料結構不變 |
| **OD-4** | **Quick Look 與 Menu Bar Extra** | **採用選項 A**：Phase 3 以 SwiftUI `.quickLookPreview($previewURL)`（`import QuickLook`，macOS 11+）快速預覽輸出文字稿；Menu Bar Extra 列為後續獨立里程碑，本版不實作。 | 不自行實作 `QLPreviewPanel` responder chain，降低 SwiftUI 整合風險 |
