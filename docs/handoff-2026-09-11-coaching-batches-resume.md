# interview-copilot 顧問多則提示：2026-09-11 暫停交班

來源：`/Users/mike/Projects/AI工作區域/interview-copilot`

## 目前狀態

- 使用者要求因用量接近上限，在安全位置停止；沒有 commit、push、重設或清理工作樹。
- interview-copilot 工作樹保留所有既有修改與新增檔案；基底 HEAD 仍為 `89b30072`。
- 本檔是接續交班；同目錄的 `handoff-2026-09-11-coaching-batches.md` 是先前版本的完整歷史內容。

## 本輪已完成或已寫入

- 延續跨 LM Studio／Vertex／DeepSeek 的 batch 回覆：追問、提點、延伸可同批並存，預設每批 0–3 則、每類最多一則；保留舊單則 API 相容層。
- runtime、浮窗、ledger、Markdown／JSON／PDF 匯出已接到完整 batch；同 batch 卡片保持展開，逐則可標記已問／已採用、回饋與原因，重開可恢復。
- 參考資料入口、6,000 字限制、文件／段落引用、session snapshot、local context budget 與超額通知已寫入。
- 修正提點／延伸使用與追問相同 gap 時不應消耗 question coverage 或 cooldown。
- 離線分析 window 增加 optional `suggestionRecordIDs` 保存所有兄弟，保留 singular `suggestionRecordID` 相容欄位。
- 開始改造比較工具，目標是 provider 選擇、逐則驗證、參考資料有／無配對、模型／context／usage／latency 分開記錄；這部分尚未完成驗收，請先檢查工作樹實際 diff。

## 最新驗證結果

最後一次 `swift test` 使用 canonical scratch：

```sh
swift test --package-path native/MuesliNative \
  --scratch-path /Users/mike/Library/Caches/muesli-spm/alpha0 \
  --filter 'CoachingBatchTests|InterviewCopilotLocalLLMTests|InterviewCopilotContextPolicyTests|InterviewCopilotDeepSeekTests|InterviewCopilotCoachingContextTests|InterviewCopilotAppTests|InterviewCopilotIMP04Tests|InterviewCopilotPhase6Tests'
```

結果未完成，**不是全綠**：編譯在新增 `CoachingBatchTests.swift` 的 `independentCoverage` 測試停止，錯誤是 `InterviewGuide` initializer 缺少必要的 `purpose` 參數（約 line 126）；後續加入的 E2E 測試尚未得到執行結果。日誌：`/tmp/interview-coaching-resume-tests.log`。`git diff --check` 通過。

前一輪較早結果有 92 tests／8 suites，其中既有測試仍失敗：兩個過時 prompt 文字斷言、overlay ledger 日期精度比較、Phase 6 將自動新 evidence 當作 cancellation 的舊行為斷言。這些斷言後來已嘗試修正，但修正後因上述編譯錯誤未重新驗收。

## 下一步

1. 先修 `CoachingBatchTests.swift` 的 `InterviewGuide(title:purpose:outline:)` 建構呼叫，明確指定 `.manual` 的 `FollowUpTrigger`（若編譯器仍無法推斷）。
2. 重跑同一批回歸；再針對失敗逐項修正，不能把早期通過結果當最終結果。
3. 檢查並完成 `scripts/evaluate_interview_context.py` 與 `scripts/interview-context-eval/main.swift` 的 provider／參考資料比較；目前 Swift 比較工具仍是舊版，上一輪重寫嘗試未套用。
4. 加入或保留完整 runner → 三卡 → feedback → export → reopen 的合成 E2E，並確認 PDF／JSON／Markdown 皆包含三則、回饋與參考快照。
5. 不要上傳真實 session、啟動付費 API 或宣稱真實模型品質已驗證。不要安裝或覆蓋 App。

## 重要檔案

- `native/MuesliNative/Sources/MuesliCore/InterviewCopilot/CoachingSuggestions.swift`
- `native/MuesliNative/Sources/MuesliCore/InterviewCopilot/InterviewFollowUp.swift`
- `native/MuesliNative/Sources/MuesliCore/InterviewCopilot/LLMClients.swift`
- `native/MuesliNative/Sources/MuesliCore/InterviewCopilot/FollowUpOverlayState.swift`
- `native/MuesliNative/Sources/InterviewCopilotRuntime/InterviewSessionRunner.swift`
- `native/MuesliNative/Tests/InterviewCopilotTests/CoachingBatchTests.swift`
- `native/MuesliNative/Tests/InterviewCopilotAppTests/InterviewCopilotAppTests.swift`
- `scripts/evaluate_interview_context.py`
- `scripts/interview-context-eval/main.swift`

