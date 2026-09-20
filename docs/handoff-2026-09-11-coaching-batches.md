# 顧問多則提示：完成紀錄與原始交班

## 2026-09-11 接續完成

使用者已重新授權接續；下方 2026-09-10 暫停內容僅保留歷史，不再代表最新待辦。

### 已完成

- 跨 LM Studio／Vertex／DeepSeek 每批一次請求，追問、提點、延伸可並存，0–3 則、每類最多一則、不湊數；舊單物件可讀。
- 同批全鏈路：逐則驗證／排序／去重 → runtime 全部事件 → 三卡展開 → 獨立採用／回饋 → ledger 重開及 MD／JSON／PDF 匯出。正式呼叫端已稽核；單則 wrappers 僅留相容或舊 selftest 介面。
- 兩組選用參考資料、6,000 字限制、開場快照、文件／段落引用、local context 正整數檢查與超額通知。router 轉 queued 的超額分支也顯示專用通知，不再落成一般失敗。
- 提點不消耗問題 coverage／cooldown；同 gap 高優先提點先入庫也不會擋追問。全不合法批次與合法空清單分開處理。
- 離線 window 新增 optional `suggestionRecordIDs` 保存全部兄弟，singular ID 保留相容；全不合法失敗保存後仍繼續下一批；provider attempt／usage 不按卡片重算。
- 比較工具支援三 provider、配對有／無參考資料、每則 evidence 驗證、模型／policy／refs／usage／latency，保存 prepared input 和 request 指紋。本地 preflight 失敗留清楚紀錄，不產生可發送 request。舊 ledger 缺狀態更新時間，replay 只使用 creation snapshot，避免未來採用／回饋洩漏。
- 修正測試編譯、日期精度、過時 prompt 與手動取消斷言。新 E2E 假音訊改為 5 秒，確實超過 segment end＋1.5 秒 reorder watermark；等整批完成事件；PDFKit 擷取使用相容字及標點正規化，但保留所有內容字元驗證。
- 清除 system prompt 殘存 emit=false／why 指令，統一空 suggestions／reason；參考素材不得改寫系統與輸出合約。

### 驗證

- 主回歸：96 tests／8 suites 通過，包含新增核心及假 ASR → runtime → 回饋 → 三種匯出 → 重開整合測試。真實 provider smoke 維持未啟用，不算品質實測。
- 離線／跨段相容性：`InterviewCopilotIMP07Tests|InterviewCopilotCrossSegmentTests`，40 tests／2 suites 通過。
- 比較工具暫存 Swift package：19 tests／2 suites 通過。
- `scripts/test_evaluate_interview_context.py`：5 項合成回歸通過，涵蓋三 provider，HTTP 傳輸 mock，零付費請求。
- 主回歸日誌 `/tmp/interview-coaching-finish-tests.log`；E2E 日誌 `/tmp/interview-coaching-e2e-tests.log`；比較工具編譯日誌 `/tmp/coaching-replay-build.log`。暫存檔不屬耐久交付，可依 docs 命令重現。

### 安裝紀錄

- 2026-09-11 最終以專用 `scripts/build_interview_copilot_alpha0.sh` 安裝並啟動 `/Applications/InterviewCopilotAlpha0.app`，bundle ID `com.specifique.interviewcopilot.alpha0`，資料目錄 `~/Library/Application Support/InterviewCopilotAlpha0`；ad-hoc 簽章及安裝後驗證通過。
- Build ID：`EDA2AE40-0FC9-4CEE-B77E-09188565C38F`；安裝後確認顯示名稱 `Interview Copilot α0` 且正確 executable 正在執行。沒有重跑測試或發送模型請求。
- 曾誤用只建主程式的 `scripts/dev-test.sh --lane B`，造成 Muesli onboarding。已關閉並將 `/Applications/MuesliDevB.app` 移到可復原的 `~/.Trash/MuesliDevB-wrong-install-codex-20260911.app`；未刪除其獨立 Application Support 資料。
- 錯誤路徑曾以 Homebrew 安裝 `xcodegen 2.46.0`、`cmake 4.4.3` 並產生完整 gitignored LocalVQE runtime；未擅自卸載系統工具。後續安裝 Interview Copilot 必須先核對 Package.swift product 與專用腳本，不得再用 Muesli dev lane。

### 邊界與後續

- 程式實作、合成接線及獨立 Interview Copilot α0 安裝完成；沒有開啟真實錄音、上傳真實 session 或執行付費模型。人眼 UI／大字級／捲動體驗及各模型的實際建議品質仍未驗收，不當作已完成。
- `/Applications/InterviewCopilotAlpha0.app` 已可供手動驗收；原音與真實案例不屬本輪測試範圍。這是專用 Alpha-0 shell，不是 Muesli rebrand。
- 使用者材料不是三類提示開發前提；校準品質可提供方法論摘要、本場計畫、3–5 段去識別對話與理想／不適合提示。格式在 [規劃第 6 節](../docs/plans/plan-2026-09-10-coaching-suggestions.md)。
- HEAD 仍為 `89b30072`，無新增 commit／push；原工作樹與新增檔案全部保留，不要清除未追蹤內容。此次更新是可交付源碼，不是已發佈版本。
- 使用者反映權限詢問過多；後續沿用已批准的 Swift test 命令與 canonical scratch，避免只為更換 log 名稱重複觸發授權。
- 最新使用說明：[context 與品質比較](../docs/interview-context-evaluation.md)。新版比較結果需新目錄 prepare，不能混用舊版單則結果。

---

## 以下為 2026-09-10 原始暫停紀錄（歷史）

日期：2026-09-10。使用者因用量接近上限，要求在安全位置停止並交班。

## 目前狀態

**這是未完成、尚未完整驗收的工作樹，不可宣稱功能已完成或直接發佈。**

- 基底 HEAD：`89b30072`（DeepSeek connection test）。沒有新增 commit、沒有切換分支或重設既有修改。
- 已保留本輪全部源碼與文件修改，包括三個尚未追蹤的新檔；不要清理未追蹤檔案。
- 未安裝或覆蓋 `/Applications` 的 App，未開啟錄音，未跑真實模型／付費 API。
- Swift 測試使用既有 `/Users/mike/Library/Caches/muesli-spm/alpha0`。所有本輪啟動的測試命令已返回結束狀態，沒有需保留的互動測試工作。
- 程序檢查另發現舊 `swiftpm-testing-helper`：PID 30257（package-local `.build`，已約兩天）、PID 61322（`simple-dev` scratch，已約四天）。它們不是本輪啟動，沒有停止或修改。
- 最新測試日誌：`/tmp/interview-coaching-tests.log`。它記錄的是下述失敗那次，**不是全綠結果**。

## 使用者已確認的方向

1. 追問、顧問提點、延伸觀點是跨模型共用能力，適用 LM Studio、Vertex/Gemini、DeepSeek。
2. 三類可同批並存，不需三選一；目前實作預設每類最多一則、每批 0–3 則，不強制湊數。
3. 已授權開始實作 [完整規劃](../docs/plans/plan-2026-09-10-coaching-suggestions.md)：先多則完整鏈路，再共用參考資料，最後品質回饋與比較工具。
4. 多則功能不必等使用者準備材料。真實方法論／案例用來校準品質，不是開發前置條件。

## 已寫入工作樹的內容

### 共用資料、模型與驗證

- 新增 `Sources/MuesliCore/InterviewCopilot/CoachingSuggestions.swift`：`CoachingBatchResponse`、`CoachingAnalysisResult`、參考文件／段落／引用模型、`CoachingFeedback`。
- `LLMRouting.swift`：completion 改持有 batch；保留 legacy `response` getter/setter 與單則 initializer，舊呼叫端可繼續編譯。
- `LLMClients.swift`：共用 prompt 支援三類同時存在，新增版本 2 envelope schema（`schemaVersion`、`suggestions`、`reason`）；每個提示仍用 version 1 單則模型供 ledger／validator 相容。
- LM Studio／DeepSeek／Vertex 正式 client 改讀完整 batch；舊 parser wrapper 仍回傳第一則，其他呼叫端需繼續稽核。
- 新 batch parser 容忍單個格式損壞項目，建立拒絕紀錄用 placeholder，保留合法兄弟項目；Vertex `MAX_TOKENS` 視為截斷。
- 預設輸出額度：LM Studio 2,048、Vertex 2,048、DeepSeek 4,096；App 地端設定已同步。尚未驗真模型延遲／截斷。
- `InterviewFollowUp.swift`：新增 `handleBatchTrigger`，逐則驗證／排序／保存；batch ID + index 避免重複寫入；每批每類一則。舊 `handleTrigger` wrapper 回傳最後一則，仍會保存完整清單。
- 新 batch 不受舊每時間窗最多兩則限制；legacy 無 batch 呼叫維持舊 gate。批次內重複 kind、相似內容分別抑制。
- 全部提示不合法時 throw invalidJSON；合法空清單用 suppressed no-suggestion 紀錄保存原因。
- coverage 只更新合法追問，重用已存在 record 時不再次 markHit。

### Runtime、浮窗與相容性

- `InterviewSessionRunner.swift` 改拿完整 result、逐則發事件／追加，最後發 `analysisCompleted`，避免壞兄弟項目把整批 UI 誤標為沒有提示。
- `FollowUpOverlayState.swift` 同 batch 提示保持展開；新批次才摺疊前批。追加相同 ID 不重複；重開能保留類型、batch 與回饋。
- `InterviewSessionEvent.swift`、App state 新增整批完成與 context 超額狀態；CLI 輸出正確類型名稱。
- `DeepSeekConnectionProbe.swift`／CLI probe 改驗所有 batch 項目。
- `OfflineAudioIngestion.swift` 改按全批記錄計算 visible／suppressed 數量；仍保留舊 window 的單一 suggestionRecordID（指第一則），需要檢查是否要補可選 ID 清單。

### 參考資料與回饋

- `InterviewAnalysisContext` 增加 optional referenceDocuments／localContextTokenLimit，沿用 `analysis-context.json` 快照及舊檔相容。
- 開始畫面新增可展開的「本場參考資料」：方法論／案例、本場背景／既有產出兩欄，貼文字或匯入 Markdown/TXT，可取消本場使用、顯示 6,000 字總量。
- Coordinator 在開場前固定資料與預算；所有模型透過同一 reference section 取得資料，不依賴地端省略的 raw guide。
- 地端 context 預算以 UTF-8 bytes + output + 固定餘量保守估算，使用者填 LM Studio 載入 context（預設 8,192）。這是保守 preflight，**不是實際 tokenizer 或自動讀取的模型容量**。每批超額有明確 UI 狀態。
- 每個引用必須指向選用文件的有效段落；參考來源不能取代現場引文。
- OGSTM 內建範例已改成三類可並存。
- ledger 增加 optional feedback／feedbackNote，浮窗「回饋」可選有幫助／太泛／重複／誤解及原因；單則操作，關閉不等於負評。
- Markdown／JSON／PDF 匯出已加入回饋與參考來源；參考資料快照透過 export context 帶入三種輸出。

上述都是已修改程式的範圍，不代表每一項已通過測試。

## 驗證紀錄與最後一個修正

1. 第一輪編譯遇到新增 `contextBudget` 後 DeepSeek error switch 不完整，已補 case。
2. 隨後三個既有 suite（`InterviewCopilotContextPolicyTests`、`InterviewCopilotDeepSeekTests`、`InterviewCopilotCoachingContextTests`）回報 21 tests 通過；真實 DeepSeek probe 因未啟用環境開關而 skipped。**這次通過早於後續匯出／新測試等修改，不是最終工作樹驗證。**
3. 新增 `Tests/InterviewCopilotTests/CoachingBatchTests.swift`，涵蓋 0–3 則、單則壞引文／重複類型、全部不合法、版本相容、三個 provider payload、參考資料快照／預算、浮窗與回饋持久化、批次 UI 狀態。
4. 最新較廣回歸停在新測試 line 約 149：`#require(store.ingest(...))` macro 內少 `try`。已改成 `#require(try store.ingest(...))`。
5. **最後這個一行修正後未重跑測試**，依使用者要求停止。`git diff --check` 通過。

接續先跑（不要同時以其他 worktree 共用此 scratch）：

```sh
swift test --package-path native/MuesliNative \
  --scratch-path /Users/mike/Library/Caches/muesli-spm/alpha0 \
  --filter 'CoachingBatchTests|InterviewCopilotLocalLLMTests|InterviewCopilotContextPolicyTests|InterviewCopilotDeepSeekTests|InterviewCopilotCoachingContextTests|InterviewCopilotAppTests|InterviewCopilotIMP04Tests|InterviewCopilotPhase6Tests'
```

沙箱曾因 clang／SwiftPM cache 不可寫而失敗，已取得 `swift test` escalation prefix。需要寫共用快取時使用正式 escalation，不建立替代外接卷。

## 尚待完成／優先檢查

1. 修完上述回歸的實際失敗，再加入 runtime 一次回覆三則的完整整合驗證，以及匯出後重開全部紀錄／回饋／資料快照的驗證。現有新測試主要驗核心與 state，尚未涵蓋完整錄音 runner。
2. 稽核全不合法時新 throw 行為對 legacy orchestrator／離線分析測試的影響，以及 batch 去重是否仍可能把 dismissed／asked 後重送結果誤計為新提示。
3. 檢查批次 prompt 的舊單則措辭、版本驗證及所有 `.response`／`parseVertex`／`parseWithUsage` 呼叫，避免只看第一項或接受不支援版本。
4. 新的 local maxTokens 預設已由 512 改 2,048，對應一個既有測試已更新；其餘硬編碼額度／舊 token 比例斷言尚待回歸確認。
5. 參考 budget 是保守近似且預設 local 8,192；需驗空白／非法 context 值、超額訊息及大字體介面。參考文件 title／version 暫用兩組固定名稱與版本 1；場次快照固定內容。
6. **品質比較工具尚未改**：`scripts/evaluate_interview_context.py` 和 `scripts/interview-context-eval/main.swift` 仍是 Vertex-only、驗第一則。接續需支援選 provider、三則驗證、有／無參考資料對照，分開記錄模型、context、耗時與 usage，避免按卡片重算費用。
7. 不要啟動既有 replay 去上傳真實私密 session。先用合成資料驗工具；真實品質評估需使用者提供案例及明確資料範圍。
8. 更新規劃及評估文件狀態。目前 `docs/plans/plan-2026-09-10-coaching-suggestions.md`、product spec／context evaluation 仍寫多則尚未實作，應在驗證完成後改成精確進度。
9. App 未安裝、未做人眼 UI 驗收。若後續要建置安裝，先讀該 product 建置腳本與 AGENTS.md 的 LocalVQE 要求，不直接把未驗證版本覆蓋既有 App。

## 重要檔案

路徑皆在 `native/MuesliNative/` 下（另有前述 docs 與 Context）。

- `Sources/MuesliCore/InterviewCopilot/CoachingSuggestions.swift`：新模型，未追蹤。
- `Sources/MuesliCore/InterviewCopilot/LLMClients.swift`、`LLMRouting.swift`、`InterviewFollowUp.swift`：批次合約與核心流程。
- `Sources/MuesliCore/InterviewCopilot/FollowUpOverlayState.swift`、`InterviewSessionModels.swift`、`InterviewSessionExporter.swift`、`OfflineAudioIngestion.swift`、`DeepSeekConnectionProbe.swift`。
- `Sources/InterviewCopilotRuntime/InterviewSessionRunner.swift`、`InterviewSessionConfiguration.swift`、`InterviewSessionEvent.swift`、`main.swift`。
- `Sources/InterviewCopilotApp/InterviewCopilotAppState.swift`、`InterviewCopilotAppCoordinator.swift`、`InterviewCopilotViews.swift`。
- `Sources/InterviewCopilotUI/FollowUpOverlayPanelController.swift`、`InterviewPDFExporter.swift`、`InterviewDeliveryRenderer.swift`。
- `Tests/InterviewCopilotTests/CoachingBatchTests.swift`：新測試，未追蹤；`InterviewCopilotLocalLLMTests.swift`：預設輸出額度測試更新。

Engram 已保存使用者決定及此暫停狀態；不使用 legacy vault 或 Codex native memory。
