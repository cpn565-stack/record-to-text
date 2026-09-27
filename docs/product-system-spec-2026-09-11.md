# record-to-text 產品暨系統規格書

文件版本：1.0  
基準日期：2026-09-11（Asia/Taipei）  
適用 App：record-to-text 0.2.1，build 6  
文件性質：依目前實作整理的產品、操作、技術與維護規格；不是未來功能提案。

## 1. 文件定位與版本基準

本文件整合目前系統已實作的行為，供產品留存、後續維護、故障判讀與重新開發使用。功能敘述以本次盤點的原始碼為準；「已有自動化測試」「已有真實後端驗證」「已人工驗收」分開記載，不相互替代。

| 項目 | 本次盤點結果 |
| --- | --- |
| 專案 | record-to-text；不是 Interview Copilot，也不是 Muesli |
| 原始碼基準 | HEAD `7c337d2`，另有既有文件／驗證工具的工作樹變更 |
| 版本設定 | `Config/version.env`：0.2.1／6 |
| 建置產物 | `dist/record-to-text.app` 的 Info.plist：0.2.1／6 |
| 安裝版本 | `/Applications/record-to-text.app` 的 Info.plist：0.2.1／6 |
| 已記錄的自用 DMG 交付 | 0.2.1 build 5，2026-09-10 |
| 本階段定位 | 目前使用者 Mac 上的自用版；可在此功能基準進入維護期 |
| 不代表 | 已完成公開發行、乾淨 Mac 安裝、Developer ID 公證或所有人工品質驗收 |

安裝版與建置產物的版本號是本次唯讀檢查結果，不等於本次另做了執行檔位元比對、重新安裝或 GUI 驗收。build 6 的時間標記與診斷文件記載的是該次開發當下「尚未替換安裝版」；與現在讀到安裝版為 build 6 並不矛盾。

本文件作為上述基準的完整現況規格。[早期 v1.0 需求追蹤](product-spec.md)、[產品決策](product-decisions.md)及各日期專項文件保留歷史脈絡；其中「30 分鐘分段」「不支援續跑」「尚無 Apple Silicon 真實驗證」等舊敘述，不應再當成目前行為。文件版本 1.0 也不表示 App 已發行 1.0 Stable。

本次只盤點原始碼、文件與既有證據，未重跑測試、轉錄私人錄音或呼叫付費 API。

## 2. 產品定位、目標與非目標

### 2.1 核心任務

把既有錄音檔轉成可閱讀、可校對、可交給後續 ChatAI／LLM 使用的台灣繁體中文逐字稿 TXT。使用者可依資料敏感度、設備與雲端服務條件，選擇本機 Qwen、Google AI Studio 或 Vertex AI。

典型用途是會議、訪談、課程及中英混用、含專有名詞的長錄音。系統提供詞彙提示、單工佇列、長音訊分段、有限重試、檢查點續跑及失敗復原，降低人工搬檔與重做成本。

### 2.2 產品原則

- 原始音檔只讀：轉錄、拆段、重試與復原都不修改、搬移或刪除來源。
- 以逐字稿為主：預設不摘要、不改寫、不潤稿，不主動刪除口語重複或語助詞。
- 詞庫是辨識提示，不是要求模型把詞彙補進沒有出現的對話。
- 雲端輸出必須驗證；不能把截斷、空回應或缺失片段冒充完整成功。
- 已知缺口、時間標記可信度與文字辨識準確度是不同問題，必須分別呈現。
- 有完成片段時盡量保存可用成果；續跑只重做無法安全重用的部分。
- 不覆蓋既有逐字稿；完成狀態必須能對應到實際已發布的檔案。

### 2.3 現階段不包含

即時收音、錄音編輯、降噪、現場對談提示、Interview Copilot 的追問／提點／延伸、專用聲紋辨識、精準逐字時間對齊、SRT／VTT 字幕、多人平行 ASR、手機／Windows App，以及已完成驗證的 Mac App Store 或公開自動更新發行鏈。

雲端 Prompt 會要求講者輪替與時間區間，但不因此成為專用 diarization 或 forced-alignment 系統。Vertex 的選配摘要是唯一明確例外，不取代逐字稿。

## 3. 執行平台與系統架構

### 3.1 平台識別

| 項目 | 規格 |
| --- | --- |
| App 名稱／執行檔 | `record-to-text` |
| Bundle ID | `com.specifique.record-to-text` |
| 最低 macOS | 14.0 |
| 主要驗證架構 | Apple Silicon／arm64 |
| Intel | 有實驗性描述與 helper 路徑，不列為已完成支援的平台 |
| UI | 原生 SwiftUI，以繁體中文介面為主 |
| 套件 | SwiftPM；tools version 5.10、Swift 5 語言模式 |
| 主要 targets | RecordToTextCore、RecordToTextApp、RecordToTextSelfTest、RecordToTextMockHelper、RecordToTextPipelineSelfTest、RecordToTextCoreTests |
| 核心依賴 | ffprobe、ffmpeg、OpenCC；本機 ASR 另需 Python／MLX／模型；Vertex 另需 gcloud 認證 |

本專案有自己的 SwiftPM 與打包腳本，不能使用 Interview Copilot／Muesli 的建置或安裝腳本代替。

### 3.2 元件關係

```text
SwiftUI 主畫面／設定／詞庫／復原視窗
                    │
        AppViewModel：工作快照、單工佇列、持久化與提示
                    │
        TranscriptionEngine：探測、分段、取消、驗證、合併
                    │
        ┌───────────┼────────────────┐
        │           │                │
   Qwen Python   AI Studio        Vertex AI
     helper      Gemini API      Gemini API
        └───────────┼────────────────┘
                    │
       輸出契約／時間檢查／OpenCC s2twp
                    │
       publication intent → 原子 TXT → durable journal
                    │
       完成通知／最近工作／必要時保留 recovery
```

UI 狀態由 AppViewModel 管理，轉錄協調、雲端重試、資料模型與檔案契約位於 Core。Python helper 透過結構化請求與 JSONL 事件回報能力、進度、警告、錯誤及完成結果；不能只憑程序結束碼判斷文字可用。

主要來源：[Package.swift](../Package.swift)、[AppViewModel.swift](../Sources/RecordToTextApp/AppViewModel.swift)、[TranscriptionEngine.swift](../Sources/RecordToTextCore/TranscriptionEngine.swift)、[ASRBackend.swift](../Sources/RecordToTextCore/ASRBackend.swift)。

## 4. 操作介面與主要使用流程

### 4.1 主要畫面

| 介面 | 內容與用途 |
| --- | --- |
| 首次啟動引導 | 初始設定、執行環境與操作說明；保留完成引導狀態 |
| 主畫面 | 輸入音檔、快速切換引擎、詞彙區、Prompt 預覽、佇列與工作狀態 |
| 詞庫管理 | 共用詞彙與具名稱的專案詞庫；選擇詞庫及本次補充 |
| 設定 | 輸出位置、完成動作、紀錄保留、模型、雲端帳號、進階執行環境 |
| 環境檢查 | 依選定後端列出必要元件是否可用與失敗原因 |
| 工作卡片 | 階段、進度、實際模型、錯誤、完成結果、重試／續跑與診斷 |
| 最近工作 | 有限數量的完成／終止工作摘要、開啟輸出、重新加入與診斷 |
| 復原掃描 | 管理範圍內的可復原、孤立或損壞資料；顯示、重新加入、確認刪除 |

### 4.2 一般轉錄流程

1. 確認後端、模型與環境可用；需要雲端時先設定憑證。
2. 準備共用詞彙、專案詞庫與本次補充，檢視合成 Prompt。
3. 拖入或選取一或多個音檔；同一來源重複加入時由使用者確認。
4. 依輸出位置設定決定目的資料夾，建立每個工作的設定快照。
5. 手動開始佇列；若使用者啟用自動開始，加入後進入相同處理流程。
6. 依序驗證音訊、準備環境、分段／轉檔、轉錄、檢查與合併文字。
7. 統一台灣繁體格式，發布新 TXT，持久化完成結果。
8. 依設定顯示 Finder、開啟文字或通知；有警告時保留明確提示。

### 4.3 拆分與合併

- 「拆成兩段」作用於尚未開始的佇列工作，保留原始音檔，建立具有來源時間範圍的兩個工作。
- 拆分後各自輸出 TXT、依單工佇列執行；不是破壞性音訊剪輯，也不自動把兩個工作合成一份。
- 手動合併逐字稿至少選兩個 TXT。若所有檔名都有一致且無重複的 `_第N-M段` 編號，依段號排列；否則採本地化檔名排序。
- 合併時修整各檔首尾空白，以空行分隔，另存含 `_合併` 的新檔；不改寫輸入 TXT，仍遵守名稱衝突保護。

主要來源：[MainView.swift](../Sources/RecordToTextApp/MainView.swift)、[SettingsView.swift](../Sources/RecordToTextApp/SettingsView.swift)、[TranscriptMerger.swift](../Sources/RecordToTextCore/TranscriptMerger.swift)。

## 5. 輸入與前置驗證

### 5.1 接受的輸入

支援副檔名 M4A、MP3、WAV、AAC、FLAC；可多檔選取或拖放。副檔名是入口篩選，實際是否含可解碼音訊仍由 ffprobe／ffmpeg 確認，不保證任意同副檔名檔案都可處理。

路徑可含中文、空格與特殊字元；外部程序以參數傳遞路徑，不把音檔名稱當成 shell 指令。重複來源以正規化路徑判斷，不以檔名相同推定內容相同。

### 5.2 開始前檢查

檢查來源存在、可讀、音訊資訊有效、來源切片範圍可用、目的資料夾可寫，以及所選後端的必要環境。音訊探測取得長度、codec、採樣率及聲道數，供分段、進度及容量估計使用。

來源若在排隊後被移動或刪除，工作應明確失敗，不能用錯誤路徑或前次輸出替代。系統不替使用者修改壞檔，也不自動刪除失敗來源。

## 6. 詞庫與 Prompt 規格

### 6.1 三層詞彙

合併順序固定為「共用詞彙 → 目前專案詞庫 → 本次補充」，相同詞彙保留首次出現的順序。詞庫資料含識別碼、名稱、詞彙與建立／更新時間；本次補充及上次選擇可隨設定保存。

| 規則 | 現況 |
| --- | --- |
| 分隔符號 | 半形／全形逗號、頓號、半形／全形分號、換行及 CR |
| 清理 | 去除前後空白與空項目 |
| 去重 | 精確文字比對，區分大小寫，保留第一次出現 |
| 中文空格 | 全中文的空格分詞可拆開 |
| 英文／混合詞 | 保留英文多字詞，以及如「專案 A」的混合詞 |
| 上限 | 合併後最多 500 個詞；詞彙 Unicode scalar 合計最多 8,000 |
| 超限 | 回報錯誤，不默默截去後半詞庫 |

### 6.2 Prompt 契約

- 最終 Prompt 由相同詞彙資料生成並納入工作快照，預覽與送出應使用一致的內容。
- 雲端共用 Prompt 只放入一份詞彙上下文，不重複附加相同詞庫。
- 明確要求依實際聽到的內容辨識，不以詞庫憑空補入人名或術語。
- 本機 Qwen helper 檢查推論介面是否支援 `system_prompt`。不支援時回報能力不符，不能假裝詞庫已生效。
- 使用者可明確同意「不使用詞庫」重試；這是新的使用者選擇，不是隱性 fallback。

主要來源：[TermParser.swift](../Sources/RecordToTextCore/TermParser.swift)、[GeminiTranscriptPrompt.swift](../Sources/RecordToTextCore/GeminiTranscriptPrompt.swift)、[GlossaryManagerView.swift](../Sources/RecordToTextApp/GlossaryManagerView.swift)。

## 7. 後端、模型與憑證

### 7.1 三種後端

| 項目 | 本機 Qwen | Google AI Studio | Vertex AI |
| --- | --- | --- | --- |
| 執行位置 | 使用者 Mac | Google 雲端 | Google Cloud 專案 |
| 主要模型 | Qwen3-ASR | 設定的 Gemini 模型 | 設定的 Gemini 模型 |
| 認證 | 不需雲端轉錄憑證 | API key／Keychain | gcloud Application Default Credentials |
| 音訊 | 16 kHz、mono PCM WAV | 16 kHz、mono MP3 | 16 kHz、mono MP3 |
| 外部傳輸 | 環境備妥後可本機轉錄 | 上傳音訊及 Prompt | 上傳音訊及 Prompt |
| 大檔傳輸 | 本機檔案 | Files API | 設定的 GCS bucket |
| 額外摘要 | 無 | 無此產品選項 | 使用者可明確啟用 |
| 續跑 | helper chunk checkpoint | cloud segment checkpoint | cloud segment checkpoint |

三者輸出都會經 OpenCC `s2twp` 統一台灣繁體。選擇雲端不需要本機 Qwen 模型，但仍需要音訊處理與文字轉換環境。

### 7.2 模型選擇

主畫面快速選單目前有五種組合：

- Qwen3-ASR 1.7B BF16。
- Vertex AI／Gemini 3.8 Flash。
- AI Studio／Gemini 3.8 Flash。
- Vertex AI／Gemini 3.7 Flash。
- AI Studio／Gemini 3.7 Flash。

進階設定另有其他模型選項，包括本機 Qwen 量化版本及 Gemini 設定清單。Apple Silicon 的設定初始模型是 Qwen3-ASR 1.7B 8-bit；快速選單的 BF16 不等於設定預設值。雲端新設定的預設模型 ID 仍是 `gemini-3.7-flash`，不能由快速選單順序推定已改為 3.8。

本文模型名稱是目前原始碼中配置的識別碼，不是供應商可用性、生命週期或價格的承諾；執行仍取決於帳號、專案、區域與服務狀態。

### 7.3 雲端傳輸與生成

- AI Studio 小檔可 inline；目前 inline 邊界為 20 MiB，大檔使用 Files API。上傳檔案進入可用狀態後才生成，傳輸路徑可處理 payload 過大的切換。
- Vertex 使用專案、區域與 ADC token；大檔超過 inline 路徑能力時需有可用 GCS bucket，不能把未設定 bucket 當成上傳成功。
- 雲端暫存物件有清理流程，但遠端刪除結果受網路與服務回應影響；本機清理成功不代表供應商端所有資料立即消失。
- 目前已知 Flash 3.6／3.7／3.8 的請求配置上限為 65,536 output tokens；其他模型走較保守的 16,384 配置。這是 App payload 規則，不是精確可輸出字數。
- Thinking 設定會納入工作快照及對應模型的請求；未知／自訂模型不能任意套用已知模型全部參數。

### 7.4 憑證

AI Studio API key 在設定畫面可保存、測試及清除，持久化位置為 macOS Keychain。舊設定內的 key 有移轉處理；JobSnapshot 的編碼不保存 key，執行前才注入所需憑證。

Vertex 的 project、location、bucket 是工作設定；短期 access token 不是工作歷史的一部分。認證失效應更新或提示，不把 token 寫入逐字稿或診斷。

主要來源：[QuickTranscriptionChoice.swift](../Sources/RecordToTextCore/QuickTranscriptionChoice.swift)、[GoogleAIStudioBackend.swift](../Sources/RecordToTextCore/GoogleAIStudioBackend.swift)、[VertexAIGeminiBackend.swift](../Sources/RecordToTextCore/VertexAIGeminiBackend.swift)、[GeminiGenerationConfig.swift](../Sources/RecordToTextCore/GeminiGenerationConfig.swift)、[GoogleAIStudioCredentialStore.swift](../Sources/RecordToTextApp/GoogleAIStudioCredentialStore.swift)。

## 8. 工作快照、佇列與狀態

### 8.1 工作快照

每次加入建立獨立 Job ID，記錄來源、可選的來源切片、詞彙／Prompt、後端／模型、輸出位置與後處理、雲端區域及重試相關設定。快照是工作可追溯性的基礎，不以目前 UI 顯示值重建已執行工作的歷史。

目前有一個明確例外：使用者切換快速引擎或相應引擎設定時，會更新「尚未開始」的排隊工作，而不是讓它們一直使用加入時的舊引擎。必須同時符合：

- 階段為 `queued`。
- 不是目前 active job。
- `startedAt` 尚未設定。
- 不是指定 recovery directory 的續跑工作。

只更新引擎相關設定，保留 Job ID、詞庫、Prompt、來源切片與輸出目的。已開始、已終止及續跑工作不被改寫。工作卡片必須顯示自己實際的後端／模型，不只顯示頂部目前選項。

### 8.2 單工排程與控制

同一時間只執行一個轉錄工作；多檔、手動拆段與重試都進入同一佇列。排隊工作可移除，目前工作可取消；終止紀錄可刪除，但不能因此刪除來源音檔或已交付 TXT。

失敗後重試可沿用原工作設定，或由使用者選擇目前設定，並建立新工作。一般重試與重新加入來源從頭執行；有檢查點時，必須使用專用續跑動作才會重用片段。

### 8.3 狀態語意

| 狀態 | 意義 |
| --- | --- |
| queued | 等待執行 |
| validating | 驗證音檔、路徑及工作條件 |
| preparingRuntime／downloadingModel | 準備或檢查必要環境／模型 |
| convertingAudio | 正規化或壓縮音訊 |
| loadingModel | 本機模型載入 |
| transcribing | 執行 ASR／雲端生成 |
| convertingTraditionalChinese | OpenCC 台灣繁體轉換 |
| writingOutput | 準備與發布輸出 |
| completed | 工作流程已產生可交付輸出；另看完整性與警告 |
| failed | 無法依契約完成，保留原因及可用復原資料 |
| cancelled | 使用者取消 |
| interrupted | 重開時發現前次工作未正常收尾 |

表列為語意狀態，不是所有後端都逐一經過的嚴格線性步驟。分段雲端工作可反覆進入轉檔／轉錄，本機才會有模型載入；不能用固定順序畫面推斷某步漏做。執行中顯示經過時間，完成後使用完成時間及保存的統計。

主要來源：[Models.swift](../Sources/RecordToTextCore/Models.swift)、[JobSnapshotEngineSettings.swift](../Sources/RecordToTextCore/JobSnapshotEngineSettings.swift)、[JobStateMachine.swift](../Sources/RecordToTextCore/JobStateMachine.swift)。

## 9. 音訊分段與長錄音管線

### 9.1 協調層分段

目前 production 上限是每段 1,200 秒，即 20 分鐘，不是早期文件的 30 分鐘。超過上限的音訊依序分段，各段獨立處理，最後依來源順序合併。

分段計畫須連續覆蓋來源範圍，沒有重疊、漏段或錯序；來源切片的時間以原始音檔座標計算。manifest 保存片段編號、總數、起訖、狀態、輸出路徑與完成證據，不能只以「資料夾裡有幾份 TXT」判定成功。

### 9.2 雲端靜音切點

預設啟用靜音感知分段。接近硬性上限時，在前方最多 30 秒內尋找至少 0.35 秒的靜音；偵測閾值為 -35 dB，規劃避免形成短於 60 秒的片段。沒有可用靜音或偵測失敗時，回退到可確定覆蓋範圍的硬切。

靜音分析在同一工作中快取，供初始分段與後續自適應切分重用。此功能只改善邊界，沒有去除靜音、降噪或保證句子完整的語意判斷能力。

### 9.3 本機細分

本機流程先產生 16 kHz mono PCM WAV；MLX helper 在協調層片段內再用預設 120 秒 chunk 控制推論長度。helper 細分不是主畫面上新增多個工作，也不等於 20 分鐘協調層上限改成 120 秒。

每段輸出需符合 manifest 與文字契約，包括合理片段數、順序及一次有效 completed 事件。helper 回報跳過音訊時必須留下缺口資訊，不能把跳過視為普通完成。

### 9.4 雲端輸出截斷

當 Gemini 回報 `MAX_TOKENS`，父片段的截斷文字不能當成完整成果。協調層可把該片段再切成左右子段，優先使用適合的已知靜音邊界，並以子段完整結果替代父段。

自適應切分最多 4 層，子段最短 60 秒；達到切分或時間預算限制時明確停止，不無限分裂或偷偷刪除內容。被捨棄父段的耗時仍保存於診斷。

主要來源：[AudioSegmentation.swift](../Sources/RecordToTextCore/AudioSegmentation.swift)、[SilenceAwareSegmentation.swift](../Sources/RecordToTextCore/SilenceAwareSegmentation.swift)、[JobSilenceAnalysisCache.swift](../Sources/RecordToTextCore/JobSilenceAnalysisCache.swift)、[qwen_asr_mlx_runner.py](../Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py)。

## 10. 雲端時間預算、重試與取消

| 控制 | 現況規格 |
| --- | --- |
| root segment 時間預算 | 900 秒，包含該段前處理、雲端流程、等待與自適應子段 |
| 子段預算 | 共享父 root 的剩餘額度，不各自重設 900 秒 |
| HTTP 操作上限 | 不超過 300 秒或剩餘預算；部分操作使用更短限制 |
| 同模型重試 | 一般 retry policy 最多 4 次嘗試，包含第一次 |
| 可重試 HTTP | 408、429、500、502、503、504 |
| 其他可恢復情況 | 部分網路／傳輸錯誤、STOP 空文字或只有 thought 的回應 |
| 模型 fallback | 預設停用；明確啟用時依白名單使用 Flash fallback |
| 續跑 | 新工作建立新的執行預算；重用片段不產生新的生成請求 |

不同錯誤有對應控制，不代表所有失敗都無条件重試四次。明示安全政策攔截、無效輸出契約與不可恢復設定錯誤不能被普通網路重試掩蓋。

使用者啟用的 `flashOnly` 策略，對受支援模型可在原模型有限嘗試後改用 `gemini-3.6-flash`；必須保存 requested model、effective model 與 fallback 事實。這不是在三種後端之間自動選價或跨供應路徑切換。

取消會傳遞至工作、雲端請求與外部程序。外部程序依 SIGINT → SIGTERM → SIGKILL 逐級收尾；取消後的晚到結果不能重新把工作標成成功。helper 約每 5 秒檢查活動，30 秒無活動可提示警告；警告不是完成證據，也不直接證明模型已死鎖。

取消本機等待不保證遠端已停止運算或不計費，重試／fallback／重新轉錄也可能增加費用。App 不提供雲端精確帳單金額保證。

主要來源：[CloudSegmentBudget.swift](../Sources/RecordToTextCore/CloudSegmentBudget.swift)、[CancellableCloudRequest.swift](../Sources/RecordToTextCore/CancellableCloudRequest.swift)、[ProcessRunner.swift](../Sources/RecordToTextCore/ProcessRunner.swift)、[HelperLivenessMonitor.swift](../Sources/RecordToTextCore/HelperLivenessMonitor.swift)。

## 11. 逐字稿、講者與摘要

### 11.1 正文格式

正式輸出是純文字，不是 Markdown 文件、JSON 或模型解釋。保留口語內容，雲端以講者輪替組織段落，換講者可空行分隔。以下僅為人工合成格式示意，不代表模型會精準辨識：

```text
[00:00 - 05:00]

講者 1：我們先確認這次專案的安排。

講者 2：好，我補充一下目前的進度。
```

模型無法保證逐字正確、無幻覺或永不漏聽。詞庫、轉繁體與完整性檢查都不能取代人工聽校。

### 11.2 講者

沒有可確定姓名時使用「講者 N：」。只有音訊或已提供資訊能支持對應時才使用姓名，不能根據語氣猜身份。

跨段 SpeakerRoster 可把之前出現的非泛用講者名稱提供為上下文，但不是已驗證聲紋。各段 generic 編號不能視為全場永久身分識別；程式不以任意重新編號或文字替換假裝完成跨段講者對齊。

### 11.3 選配摘要

只有 Vertex 的「附加內容摘要」設定開啟時，在全部片段合併後最多再產生一次摘要，附於完整逐字稿後。預設關閉。

摘要失敗時保留已完成逐字稿並發出警告，不能使主要轉錄工作因此失敗。摘要與逐字稿應明顯分隔；摘要本身仍可能需要人工確認，且額外請求會使用雲端資源。

## 12. 時間標記與可信度

### 12.1 雲端時間格式

共用 Prompt 提供實際片段起訖，要求五分鐘區間；話題轉換可提早換段，最後區間不能超過實際終點。切片或長錄音後段使用原始音檔的時間座標。

這是粗粒度時間標記，不是逐字／逐句強制對齊，也不保證每次模型都遵守。App 會在完整回應建立檢查點前驗證，而非直接相信文字中的時間。

### 12.2 build 6 的保守修正

- 只校正可由已知片段邊界確定的起訖，不按字數推估段內位置。
- 缺少預期區間、時間倒退、重疊或越界時，移除該片段不可靠的時間標記。
- 保留所有對話文字，改以已知的實際片段範圍，加上「段內時間待核對」提示。
- 不因修正時間再呼叫模型，不重送已完成音訊，不覆寫之前另存的 TXT。
- 工作卡片與最近工作顯示時間需核對的提示。
- 新產生與檢查點重用的文字都適用同一驗證。

時間格式異常不等於音訊未完成，因此不自動標成 `hasGaps`，也不把可用逐字稿改成 failed。

主要來源：[TranscriptTimestampValidator.swift](../Sources/RecordToTextCore/TranscriptTimestampValidator.swift)、[時間標記與診斷實作紀錄](timestamp-diagnostics-spec-2026-09-11.md)。

### 12.3 本機 Qwen MLX 十分鐘時間區間（2026-09-27）

- TXT 每十分鐘標記一個 `[HH:mm:ss - HH:mm:ss]` 區間；不足十分鐘的尾段標到實際音訊終點。
- 內部仍以 120 秒推論，每五塊合成一個文字區間，不增加模型推論或改變 token 超限重切機制。
- 時間由音訊 sample 位置計算，加上手動切片與外層分段的起點，對回原始錄音；切片從自己的實際起點每十分鐘分組。
- checkpoint 保留原有純文字格式，續跑時重建時間標記，避免重複推論；未完成草稿只標到最後完成的塊。
- 時間區間用於定位錄音，並非逐句或逐字對齊；不新增講者辨識。Intel Experimental helper 不在此次變更範圍。

## 13. 輸出完整性與已知缺口

| 值／情況 | 顯示及意義 |
| --- | --- |
| `complete` | 「完成」：系統沒有已知未完成片段；不是準確率保證 |
| `hasGaps` | 「完成（含缺口）」：已產生可用成果，但有明示未完成音訊 |
| `unknown`／舊資料缺欄位 | 相容載入，通常仍顯示「完成」；不能倒推曾通過新完整性驗證 |
| 時間待核對 | 文字可用但段內時間不可信；與上述完整性分開 |

本機 helper 若在有限嘗試後跳過 chunk，需保存跳過事實。雲端若受到明確安全政策攔截，可保留其他已完成片段，插入含片段編號、起訖及原因的缺口標記；manifest 與結果必須反映該缺口。

completed、completedWithGaps、blockedBySafety、failed 等片段狀態不能混為一般完成。具有待補缺口的工作與復原資料不應被普通最近紀錄上限直接裁掉。

目前已提供雲端「重送未完成片段」；它不是「改用本機模型自動補雲端缺口」。後者雖有獨立規劃文件，但尚未在目前 UI／AppViewModel 接成可用流程。

主要來源：[CloudTranscriptionModels.swift](../Sources/RecordToTextCore/CloudTranscriptionModels.swift)、[Models.swift](../Sources/RecordToTextCore/Models.swift)、[JobRetentionPolicy.swift](../Sources/RecordToTextCore/JobRetentionPolicy.swift)。

## 14. 失敗復原、檢查點與續跑

### 14.1 四種動作必須區分

| 動作 | 是否重用已完成片段 | 設定來源 |
| --- | --- | --- |
| 一般重試／重新加入來源 | 否，從頭處理 | 原設定或使用者選擇的目前設定 |
| 雲端檢查點續跑／重送未完成片段 | 驗證通過者直接重用 | 原工作快照 |
| 本機 Qwen checkpoint 續跑 | helper 驗證指紋後重用 chunk | 原工作快照 |
| 復原掃描中的「從頭重新加入」 | 否 | 重新建立來源工作 |

### 14.2 雲端續跑

可續跑資料必須位於 App 管理的 Temp-Recovery 直接子目錄；正規化及解析 symbolic link 後仍須通過範圍檢查。UI 可先做唯讀可用性檢查，真正執行時再以重新探測的音訊確認。

主要條件包含：

- recovery metadata 至少 schema 2，類型為 `cloudCheckpoint`。
- 來源正規化路徑、來源切片與雲端 backend 相符。
- manifest 有合理片段數、連續編號／邊界、合法長度與可安全解析的輸出。
- 來源長度與分段上限比較容許誤差為 0.75 秒。
- 重用文字的路徑不能逃出復原資料的 segments 目錄。
- 至少有一個可安全重用的成果；不能只因資料夾存在就開放續跑。

建立新工作後，已完成且合格的片段不重新壓縮、上傳或生成；其餘片段用來源音檔重建。原工作記錄不被改寫成新執行。重用的時間標記重新檢查，診斷標示 `reusedFromCheckpoint`。

邊界：目前雲端載入檢查主要依來源路徑、時間範圍、長度與 manifest，不是完整來源音訊的密碼學身分認證。若使用者在同一路徑替換成等長但不同內容，不能宣稱一定可偵測；維護流程應保留原音檔直到續跑結束。

### 14.3 本機續跑

本機 recovery 下的 `chunk-checkpoints/` 保存 `*.chunks.json`。Swift 做保守結構檢查：schema 1、正整數總 chunk 數、64 位十六進位指紋、從 index 0 開始連續且非空的已完成文字。

Python helper 在真正重用前，比對由音訊樣本數、採樣率、總 chunk 數、chunk 秒數、模型 ID／revision、maximum tokens、Prompt 與詞彙組成的 SHA-256 指紋。UI 判定可續跑不等於 helper 最終已接受；不相符時不能強行拼接舊結果。checkpoint 目錄使用 0700 權限。

這是音訊規格與推論設定的指紋，不是整份音訊內容的 SHA-256。與雲端續跑相同，不應在待續跑期間把來源替換成長度相同但內容不同的錄音。

本機 failed／cancelled／interrupted 工作在來源存在且有可用 checkpoint 時可續跑。保留的 WAV、文字與 checkpoint 可能含敏感內容，使用者可在不再需要時透過復原管理刪除。

### 14.4 復原掃描與清理

啟動或手動掃描時識別 recoverable、orphaned、damaged 資料，提供 Finder 顯示、取回部分文字、重新加入與確認刪除。損壞資料不應悄悄宣告恢復成功。

完整成功且完成狀態已 durable 保存後才能清理可重建暫存。失敗、取消、尚有缺口或持久化不確定時，保留必要復原資料。刪除復原資料須確認，不能連帶刪除來源音檔或既有正式輸出。

主要來源：[CloudResumeCheckpoint.swift](../Sources/RecordToTextCore/CloudResumeCheckpoint.swift)、[LocalChunkCheckpoint.swift](../Sources/RecordToTextCore/LocalChunkCheckpoint.swift)、[RecoveryScanner.swift](../Sources/RecordToTextCore/RecoveryScanner.swift)、[RecoveryScanView.swift](../Sources/RecordToTextApp/RecoveryScanView.swift)。

## 15. TXT 契約、檔名與發布一致性

### 15.1 文字與命名

| 項目 | 規格 |
| --- | --- |
| 正式格式 | 純文字 TXT；UTF-8、LF、無 BOM |
| 最低有效條件 | 非空、可解碼、無 NUL；拒絕不合契約的回應／Prompt 回音 |
| 繁體處理 | OpenCC `s2twp` |
| 預設正式名稱 | 原始檔名主體 + `_逐字稿.txt` |
| 選配原始文字 | 預設不保留；suffix 預設 `_Qwen原始` |
| 衝突 | 使用 `_2` 等後續編號，不覆蓋 |
| 輸出位置 | 固定資料夾、與來源相同、每次詢問 |
| 原始音訊 | 所有輸出策略均不得變更 |

選配 raw 是本機 Qwen 在 OpenCC 轉換前的辨識文字，不是另一份原始音檔；目前保留 raw 的實作位於本機路徑，不宣稱雲端有同等 raw 輸出。若另存 raw 失敗，正式繁體稿仍保留，工作顯示警告。

### 15.2 原子發布

正常流程是「準備 publication intent → 獨占發布 TXT → 保存工作完成 → 清理 receipt／temp」。

發布透過 `renamex_np(RENAME_EXCL)` 保護，不只是先檢查檔案存在再覆寫。若在選好名稱與實際發布間發生競爭，必須重新選名稱。使用者既有 TXT 及預先放置的同名檔不能被犧牲。

publication intent 保存 Job ID、輸出位置、預期 SHA-256、結果與相關時間，讓「檔案已寫出，但 App 在保存 completed 前終止」仍可復原。

### 15.3 重開後校正

啟動只為 journal 已知的未正常終止工作檢查 receipt。必須確認輸出檔存在、非空、雜湊吻合，才可恢復完成狀態。檔案缺失、損壞或不相符時不得標完成；已由使用者刪除的工作也不能由孤立 receipt 復活。

此機制保障應用層發布與紀錄的一致性，不承諾可抵抗任意磁碟硬體故障或恢復所有斷電情境。

主要來源：[OutputContractValidator.swift](../Sources/RecordToTextCore/OutputContractValidator.swift)、[AtomicFileWriter.swift](../Sources/RecordToTextCore/AtomicFileWriter.swift)、[OutputPublicationStore.swift](../Sources/RecordToTextCore/OutputPublicationStore.swift)、[OutputNameBuilder.swift](../Sources/RecordToTextCore/OutputNameBuilder.swift)。

## 16. 本機資料、模型與持久化

### 16.1 資料位置

主要資料根目錄為 `~/Library/Application Support/record-to-text/`。

```text
record-to-text/
├── settings.json                 使用者設定；不保存 API key
├── glossaries.json               共用詞彙、專案詞庫
├── job-journal.json              權威工作／最近工作快照
├── job-journal.previous.json     前一份 journal
├── job-ledger.json               可修復的工作資料視圖
├── recent-jobs.json              可修復的最近工作視圖
├── Models/                      本機模型
├── Runtimes/                    受管理執行環境
├── Logs/                        執行紀錄
├── Publication-Receipts/         輸出發布／復原憑據
└── Temp-Recovery/               未完成工作的最小復原資料
```

工作中的暫存另位於系統 temp 的 `record-to-text/<JobID>/`，可能包含正規化 WAV、雲端 MP3、片段文字與 manifest。雲端最小 recovery 以文字、manifest 及必要 metadata 為主，不把暫存 MP3 當成永久 checkpoint；本機 recovery 可能保留 WAV 與 chunk checkpoint。

Models 是 App 管理範圍，與一般 Hugging Face cache 不必相同；環境管理可利用既有模型，但不能假定每台 Mac 都已有它們。刪除模型或 Runtime 會影響後續工作，不能當成一般歷史紀錄清理。

### 16.2 核心資料模型

| 模型 | 主要責任 |
| --- | --- |
| AppSettings | 使用者偏好、後端設定、路徑、保留策略 |
| GlossaryCollection／GlossaryPreset | 共用詞彙及具識別碼的詞庫 |
| JobSnapshot | 工作所用設定與詞彙／Prompt；排除持久化憑證 |
| TranscriptionJob | ID、來源、狀態、時間、輸出、錯誤、logs、checkpoint、完整性及診斷 |
| RecentJobSummary | 最近工作所需摘要，保留可選的雲端與完成診斷 |
| AudioSegmentManifest | 片段覆蓋、完成證據、metadata 與可重用輸出 |
| RecoveryMetadata | 復原類型、來源及與工作相容的必要資訊 |
| OutputPublicationIntent | 輸出發布與工作狀態之間的復原憑據 |
| PersistenceSnapshot | 同一 revision 的 ledger／recent 一致快照 |
| CloudJobDiagnostics | 不含內容與憑證的結構化執行診斷 |

schema 與新增欄位需支援舊資料載入；缺少診斷或完整性欄位不等於資料錯誤，也不等於舊工作已符合新驗證標準。

### 16.3 持久化與保留策略

- 工作保存採背景序列寫入、revision 及合併更新，避免每次進度事件都阻塞 UI。
- journal 是權威資料；ledger／recent 是可修復視圖。journal 損壞時不能把不同版本的視圖混接成看似正常的歷史。
- 在啟動會產生外部成本的工作、完成發布及結束 App 等關鍵位置，使用關鍵保存／flush。
- 無法保存時顯示警告與「重試儲存」，不能把未保存狀態當作 durable 成功。
- 預設最近工作保留 10 筆；限制主要作用於可裁切的終止歷史。
- queued、active、interrupted 與尚有待補缺口的工作不應因最近數量設定為 0 而消失。
- 持久化的工作 log 採有限尾端保留；不是無限制保存全部 console 輸出。

主要來源：[ApplicationPaths.swift](../Sources/RecordToTextCore/ApplicationPaths.swift)、[JobPersistenceCoordinator.swift](../Sources/RecordToTextCore/JobPersistenceCoordinator.swift)、[JSONRepositories.swift](../Sources/RecordToTextCore/JSONRepositories.swift)、[StartupInventory.swift](../Sources/RecordToTextCore/StartupInventory.swift)。

## 17. 診斷、可觀測性與隱私

### 17.1 build 6 完成工作診斷

完成工作及最近工作可保留並複製音訊長度、片段範圍、結果、前處理耗時、雲端呼叫總耗時，以及可觀測的認證、上傳、輪詢、生成請求及退避等待耗時。

重試原因使用固定分類，包括 rateLimited、serverError、network、emptyResponse、authenticationRefresh、transportReset、modelFallback、inlineUploadFallback。保留自適應切分時被捨棄父段的成本與時間提示。

`reusedFromCheckpoint` 表示來自前次執行，不計作本次新耗時。生成請求耗時包含網路與伺服器處理，不能當作純模型運算時間；無法觀測的欄位保持未知，而不是填 0 或用總時間推算。

### 17.2 資料邊界

結構化診斷只包含數值、固定枚舉與範圍，不包含 Prompt、詞庫、逐字稿、原始錯誤訊息、雲端 URL、API key 或 token，並可經 publication intent、journal、recent history 保存與恢復。

這個承諾只適用於指定診斷資料，不能擴張成「所有 App 資料都已去識別」：工作快照有 Prompt／詞彙，來源路徑與一般工作 log、復原文字、WAV、TXT 都可能含個人或機密資訊。分享工作資料或復原資料前仍須檢查內容。

本機模式在模型與環境備妥後可離線推論；首次下載、環境準備與使用雲端是不同網路行為。雲端會接收所需音訊與 Prompt，第三方保存政策不由本 App 保證。App 未提供自身的檔案加密層，資料保護另依 macOS、帳號與磁碟設定。

主要來源：[CloudJobDiagnostics.swift](../Sources/RecordToTextCore/CloudJobDiagnostics.swift)、[GeminiTransportHelper.swift](../Sources/RecordToTextCore/GeminiTransportHelper.swift)、[SensitiveCodingTests.swift](../Tests/RecordToTextCoreTests/SensitiveCodingTests.swift)、[JobDebugClipboardTests.swift](../Tests/RecordToTextCoreTests/JobDebugClipboardTests.swift)。

## 18. 錯誤行為與復原決策

| 情境 | 系統行為 | 使用者／維護者下一步 |
| --- | --- | --- |
| 來源不存在／不可讀／非有效音訊 | 前置驗證失敗 | 修正來源後重新加入 |
| ffmpeg、OpenCC、Python 或模型不可用 | 環境檢查／準備失敗 | 修正所選後端的環境，不任意改用其他後端 |
| API key／ADC／專案／bucket 不可用 | 認證或傳輸錯誤 | 在設定修正，再重試或續跑 |
| 詞庫過長或數量超限 | 阻止無效 Prompt | 精簡詞彙後建立工作 |
| 本機 helper 不支援詞庫 Prompt | 明示能力錯誤／同意流程 | 更新環境，或明確同意不使用詞庫 |
| 可重試網路／服務錯誤 | 在次數與時間預算內重試 | 額度用盡後保留錯誤與可用 checkpoint |
| STOP 空文字／只有 thought | 有限重試，不視為有效逐字稿 | 檢視模型與診斷 |
| MAX_TOKENS | 捨棄截斷父結果，有限自適應切分 | 達限制仍失敗時保留可用成果 |
| 明確安全政策攔截 | 明示缺口或失敗，不偽造正文 | 檢視服務限制及可用的重送動作 |
| 時間標記不可信 | 保留全文，標示段內時間待核對 | 人工對照錄音，不誤判音訊缺口 |
| 使用者取消／程序中斷 | 終止流程，保留可用復原資料 | 使用專用續跑或從頭重試 |
| 輸出名稱碰撞 | 選新名稱後獨占發布 | 不需先刪舊 TXT |
| 磁碟寫入／持久化失敗 | 顯示錯誤，保留 receipt／recovery | 檢查容量、權限並重試儲存 |
| Vertex 選配摘要失敗 | 完整逐字稿照常保留，附警告 | 不必重做已完成的 ASR |
| checkpoint 不相容／損壞 | 拒絕危險重用 | 保留資料供檢查，必要時從頭加入 |

任何診斷都不能擅自刪除使用者來源、既有輸出或整個 Application Support。重送原本缺口也不代表先前政策或服務錯誤已消失。

## 19. 重要預設值與可調設定

下表是新建 AppSettings 的原始碼預設；使用者已保存設定可不同，不能用本表推定目前 live 設定。

| 設定 | 預設 |
| --- | --- |
| 後端 | Google AI Studio |
| AI Studio／Vertex 模型 ID | `gemini-3.7-flash` |
| Vertex location | `global` |
| Vertex project／GCS bucket | 未設定 |
| Apple Silicon 本機模型 | Qwen3-ASR 1.7B 8-bit |
| Gemini thinking | high |
| Cloud fallback | disabled |
| 雲端靜音感知分段 | 開啟 |
| Vertex 附加摘要 | 關閉 |
| 加入後自動開始 | 關閉 |
| 輸出位置模式 | 固定資料夾；實際路徑由初始化／使用者設定提供 |
| 完成後顯示 Finder | 開啟 |
| 完成後開啟文字 | 關閉 |
| 完成通知 | 開啟；仍受系統通知權限影響 |
| 保留 raw transcript | 關閉 |
| 正式／raw suffix | `_逐字稿`／`_Qwen原始` |
| 最近工作上限 | 10 |
| Developer Mode | 關閉 |
| 自訂 Python／helper／gcloud 路徑 | 未設定 |
| 初次引導完成旗標 | false |

設定重設與詞庫清除是不同操作，可保留詞庫或明確選擇一併重設。修改設定不能等同授權刪除原始音檔、正式輸出或任意執行環境資料。

## 20. 效能與可靠性要求

目前產品不承諾固定「錄音長度幾倍速」或固定雲端完成時間。實際耗時受模型、量化、設備、音訊內容、網路、認證、排隊與重試影響。

設計要求是單工控制資源、長檔有界分段、雲端有界預算、可取消、主執行緒不被大量持久化／啟動盤點占住，以及失敗時保留明確狀態。

既有穩定性工作有程序崩潰注入、輸出發布／journal 邊界、長佇列保存與取消回歸。這些證明被測的應用層情境，不構成所有電源中斷、kernel 卡住或遠端計費取消的保證。

歷史實測包含 45 分鐘 Vertex 工作，以及 3 分鐘 Qwen／AI Studio 工作；它們是特定環境樣本，不應升格為不同硬體與所有錄音的性能 SLA。亦未建立可對外宣稱的統一 WER、講者準確率或時間對齊誤差指標。

## 21. 建置、封裝與自用交付

### 21.1 開發與打包

`scripts/build-app.sh` 從版本設定建置 Swift app、組裝 bundle、帶入三個 Python helper 資源與必要的 ffmpeg／ffprobe Helpers，並處理封裝簽章及 bytecode hygiene。模型權重與完整 Python／MLX Runtime 不等於隨 App 自動附送。

維護時常用命令如下；本文件撰寫沒有執行它們：

```bash
CONFIGURATION=release REQUIRE_XCTEST=1 ./scripts/run-checks.sh
CONFIGURATION=release ./scripts/build-app.sh
./scripts/package-development.sh
```

一般自用開發包使用 ad-hoc 簽章。專案另有 sign-app、notarize、verify-release、build-release、publish-release 腳本，但腳本存在不等於 Developer ID、notarytool profile、正式 Runtime artifact 或公開發行驗收已完成。

### 21.2 執行環境限制

音訊工具可由 bundle Helpers、已配置的本機工具或受管理 Runtime 解析；Developer Mode 可使用已存在的 Python／MLX 環境及自訂路徑。非 Developer Mode 的本機推論需要合格的受管理 Runtime。

目前自用交付依賴已驗證的這台 Mac 環境，不能向乾淨 Mac 宣稱只拖進 Applications 就必定能跑三種後端。Intel、Universal 2、完整 Runtime 安裝器與公開公證各自需要另外驗收。

主要來源：[build-app.sh](../scripts/build-app.sh)、[RuntimeEnvironment.swift](../Sources/RecordToTextCore/RuntimeEnvironment.swift)、[build 5 自用交付紀錄](finalization-closeout-2026-09-10.md)。

## 22. 已有驗證證據

| 基準 | 已記錄的證據 | 不能由此推定 |
| --- | --- | --- |
| build 5 自動化 | 262 XCTest、25 Python、72 executable self-tests、10 種 pipeline 情境通過 | 所有 GUI 互動及所有模型品質通過 |
| build 5 真實 Vertex | 45 分鐘安裝版工作完成；另有取消、程序重啟及 checkpoint 續跑 probe | 每一個帳號／區域／錄音都相同 |
| build 5 真實 Qwen | 3 分鐘、安裝版 helper、既有 BF16 模型、離線完成 | 所有長檔及硬體已驗證 |
| build 5 真實 AI Studio | 3 分鐘 Files API 與設定模型完成 | 全部傳輸情境、額度與地域已驗證 |
| build 5 續跑覆蓋 | 0–1200、1200–2400、2400–2700.010667 秒；首段重用，後兩段完成 | GUI 點擊流程也因此通過 |
| build 5 輸出保護 | STOP 空回應有限重試；另存 `_逐字稿_2.txt`；原檔與同名 TXT 保留 | 使用者文字已人工校對 |
| build 6 自動化 | 275 XCTest、25 Python、72 executable self-tests、10 種 pipeline 情境通過 | 新增規則已用私人長錄音重跑 |
| build 6 模擬後端 | 時間區間缺失／越界／錯序、切分、續跑與診斷保存／相容性 | 模型今後永遠提供精準時間 |
| build 6 封裝 | release App、0.2.1／6、既有 codesign 嚴格驗證及無 Python bytecode 紀錄 | Developer ID 公證或乾淨帳號可用 |
| 本次文件盤點 | 核對原始碼、Config、dist 與安裝版 Info.plist | 本次重跑了任何自動化或真實轉錄 |

上述數字是既有執行紀錄的引用，不是本文件新執行的測試結果。build 5 補跑工具連結當時 Core objects 並使用安裝版 Helpers，屬於真實後端／核心流程驗證，不是完整 GUI 驗收。

未宣告通過的人工範圍：逐字聽校、至少五次講者輪替對照、15 分鐘 GUI 互動，以及 GUI 取消／重開流程。使用者在得知這些界線後接受自用 DMG 交付；不應把這些保留項重述成已驗收，也不因此否定已完成的程式與核心驗證。

證據入口：[build 5 closeout](finalization-closeout-2026-09-10.md)、[build 6 時間／診斷](timestamp-diagnostics-spec-2026-09-11.md)、[run-checks.sh](../scripts/run-checks.sh)。歷史本機 log 與含私人資料的驗證資料夾不是可公開分享的產品附件。

## 23. 維護驗收矩陣

下表定義後續修訂至少應保留的行為與主要驗證入口，並不是要求每次文件編輯重跑全套測試。

| ID | 必須保留的行為 | 主要驗證入口 |
| --- | --- | --- |
| AC-01 | 三層詞彙順序、精確去重、上限與 Prompt 一致 | TermParserTests、PromptBuilderTests |
| AC-02 | 新設定預設與舊欄位解碼相容 | ModelsDefaultsTests、PersistenceTests |
| AC-03 | 尚未開始的工作可換引擎；不改 active／resume | CloudPipelinePresentationTests、AppViewModel |
| AC-04 | 20 分鐘規劃、連續覆蓋與靜音失敗 fallback | AudioSegmentationTests、SilenceAwareSegmentationTests |
| AC-05 | MAX_TOKENS 不發布截斷父文字 | CloudAdaptiveSegmentationTests |
| AC-06 | root／child 共用時間預算與有界重試 | CloudSegmentBudgetTests、CloudReliabilityTests |
| AC-07 | 取消後不接受晚到成功，保留可用復原 | AppCancellationRecoveryTests |
| AC-08 | 本機 checkpoint 結構與 helper 指紋檢查 | LocalChunkCheckpointTests、Python helper tests |
| AC-09 | 雲端 checkpoint 範圍、manifest、重用與相容檢查 | CloudResumeCheckpointTests |
| AC-10 | 不覆蓋檔案，發布中斷後正確復原 | OutputPublicationTests、OutputNameBuilderTests |
| AC-11 | UTF-8／LF／無 BOM／非空契約 | OutputContractValidatorTests、self-tests |
| AC-12 | complete／hasGaps／unknown 不混淆 | OutputCompletenessTests |
| AC-13 | 壞時間標記只保守修正，不改對話或多發請求 | TranscriptTimestampValidatorTests |
| AC-14 | 診斷無內容／憑證，重用／父段耗時可辨別 | CloudJobDiagnosticsTests、JobDebugClipboardTests |
| AC-15 | Keychain 移轉及 Snapshot 不編碼秘密 | AppCredentialMigrationTests、SensitiveCodingTests |
| AC-16 | journal 原子性、最近上限不裁掉待辦工作 | JobPersistenceCoordinatorTests、JobRetentionPolicyTests |
| AC-17 | 啟動盤點／復原不破壞來源與輸出 | StartupInventoryTests、RecoveryScannerTests |
| AC-18 | bundle 不被 helper 產生的 bytecode 污染 | HelperBytecodeTests、封裝檢查 |
| AC-19 | 真實詞彙、講者與錄音內容品質 | 使用者同意的人工聽校；不能由 mock 取代 |
| AC-20 | 公開發行品質 | 乾淨 Mac、正式 Runtime、簽署、公證及實機矩陣；另立里程碑 |

自動化入口位於 [Tests/RecordToTextCoreTests](../Tests/RecordToTextCoreTests) 及 [Tests](../Tests)。付費雲端／私人音訊驗證須有明確範圍，不加入一般自動化以免背景產生成本。

## 24. 開發收尾範圍與已知限制

### 24.1 可作為本階段功能基準的範圍

原生 macOS 操作介面、三種轉錄後端、詞庫／Prompt、單工佇列、排隊引擎更新、20 分鐘長檔分段、靜音切分、自適應處理截斷、有界重試／取消、雲端與本機續跑、缺口標示、台灣繁體 TXT、非覆蓋發布、journal 復原、完成工作診斷及自用封裝，均有目前程式實作與相應驗證基礎。

「開發告一段落」在本文件中的意思是凍結上述自用版本行為，進入必要修正與維護；不自動把原先規劃中的功能加入本輪待辦。

### 24.2 已知限制與延後項目

| 項目 | 現況／後續界線 |
| --- | --- |
| 逐字與講者品質 | 需人工校對；沒有全面準確率認證 |
| 段內時間精度 | 保守標記與提示，不是 forced alignment |
| 跨段姓名一致性 | Prompt／roster 輔助，不是聲紋驗證 |
| 雲端補段改用 Qwen | [已有規劃](local-segment-fill-spec-2026-09-04.md)，未列為已實作 |
| 續跑來源身分 | 雲端檢查路徑／範圍／長度；本機另驗音訊規格與推論設定指紋，兩者均不保證檢出所有等長內容替換 |
| 雲端模型／費用／可用性 | 受服務端與帳號影響；本規格不保證價格或生命週期 |
| 未完成的 GUI／人工驗收 | 保留第 22 節界線 |
| 乾淨 Mac／完整 Runtime 安裝 | 尚非已完成的公開交付能力 |
| Intel／Universal 2 | 不列入已驗證自用主平台 |
| Developer ID／公證／公開發布 | 與目前 ad-hoc 自用包分開 |
| 自動檢查／安裝 App 更新 | 歷史規劃不算現有已交付功能 |
| 長期性能／品質統計 | 未建立跨硬體、跨錄音資料集的保證值 |

## 25. 後續接手指引

1. 先確認正在維護的是 record-to-text，以及 Config、dist、安裝版的版本，避免引用另一個 App 的交班。
2. 以本文件閱讀現況，再查涉及功能的原始碼與專項文件；不要從早期 product-spec 的 Pending 字樣直接判定功能不存在。
3. 保留既有 dirty worktree、使用者音檔、詞庫、journal、recovery 與正式輸出；不要用重設資料當成預設修復方式。
4. 優先從去識別診斷定位問題，必要時才在使用者同意範圍內檢查其他資料。
5. 只執行受修改影響的必要驗證；變更轉錄管線、輸出原子性或持久化時，才擴大至相應回歸。
6. 修改行為後同步更新本文件、相關測試與版本紀錄；新的實測結果必須註明 App build、方法與未驗範圍。
7. 不把 build 5 真實後端樣本、build 6 模擬驗證與新修改混成一次「全部驗收完成」。

至此，本 App 的功能、資料契約、恢復邊界、交付證據與未承諾事項可由同一份文件查得；後續可依實際使用問題進行維護，不必把歷史規劃全部重新啟動。
