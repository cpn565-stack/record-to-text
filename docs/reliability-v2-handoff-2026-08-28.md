# Reliability v2 安全停點與接手筆記（2026-08-28）

> **歷史快照／已被後續交班取代。** 本文保留 2026-08-28 當時的工作樹與驗證狀態。Phase 4–6 後續已進入 `26da9aa`，視窗標題修正已進入 `ccc3431`，XCTest CI 修正已進入 `1d6870c`，MAX_TOKENS 整合測試已進入 `9c21834`。目前狀態請以 `docs/handoff-2026-08-30-reliability-v2-closeout.md` 與 `docs/reliability-v2-validation.md` 為準。

## Git 狀態

- 分支：`codex/record-to-text-reliability-v2`
- 基準：`7b3c426 feat: harden Gemini transcription and add model controls`
- Reliability v2 主體已以 `5e7ff57` commit 並 push；Phase 4–6 在 2026-08-28 當時尚未 commit／push，後續已進入 `26da9aa`。
- 工作樹通過 `git diff --check`。
- 私人錄音、逐字稿、API Key、token 均未加入工作樹。

## 目前安全狀態

最後一次 `scripts/run-checks.sh`：

- Python：22 項 chunking tests 通過。
- Python：3 項 MLX runner contract tests 通過。
- Swift executable self-test：68 passed, 0 failed。
- Mock pipeline：10 項通過。
- Core／App／工具均可建置。
- `dist/record-to-text.app` 建置及 ad-hoc signing 成功。
- 完整 XCTest 仍因本機只有 Command Line Tools 而跳過。
- 已進行真實 10 分鐘 MLX／Metal 「中止 → checkpoint resume」驗收。
- 尚未進行真實 Gemini API、真實 30／173 分鐘 MLX soak 或完整 GUI 驗收。

## 階段 0：已完成

- 建立獨立分支。
- CI 增加本分支 push 與 `workflow_dispatch` 入口。
- 新增 `docs/reliability-v2-validation.md`，定義自動與真實驗收矩陣。
- 2026-08-28 當時 CI 修改尚未推送；後續 `9c21834` 的 GitHub Actions Run `33263989282` 已完整通過。

## 階段 4–6：後續實作

- 啟動模型快取與復原掃描已移到背景 utility task，並加入過期結果 gate。
- 復原畫面顯示掃描中、上次完成時間，文案不再誤稱全部情境都無法斷點續跑。
- 版本收旂到 `Config/version.env`；CI 產生 development DMG 與 SHA-256 artifact。
- 移除一次性 patcher／workflow，並防止 Python cache 進入 App bundle。
- 此階段完整驗證結果以本次最終 `scripts/run-checks.sh` 與 development DMG 建置為準。

## 階段 1：MAX_TOKENS 已完成自動化實作與本機契約驗證

### 行為

- Gemini `MAX_TOKENS` 不再回傳可正式交付的文字。
- Backend 改丟 `CloudOutputTruncatedError`，partial text 只能作未完成救援稿。
- Cloud coordinator 收到截斷狀態後：
  - 優先找中點附近靜音。
  - 動態把該 span 切成左右子段。
  - 最多切兩層，約 20 → 10 → 5 分鐘。
  - 重編 manifest 的 segment index／count。
  - 全部葉節點 `STOP` 才能合併正式稿。
- manifest schema 使用 version 3，舊 optional 欄位仍可解碼。
- checkpoint resume 保存每個動態 segment 的 split depth。

### 已驗證

- `MAX_TOKENS` parser fail-closed。
- 靜音中點選擇。
- 最大 split depth／最小 child duration。
- manifest split 後連續、重編號、無重疊。
- 舊 cloud resume tests 未退化。

### 後續驗證狀態（更新於 2026-08-30）

- 完整 `TranscriptionEngine.run` 整合測試已於 `fdeaef9`、`a3ac87d`、`9c21834` 補齊：父段 `MAX_TOKENS` 後子段全部 `STOP` 才交付正式稿；子段非重試錯誤與最大 split depth 維持 fail-closed。
- GitHub Actions Run `33263989282` 已通過 178 項 XCTest，`CloudAdaptiveSegmentationTests` 6 項全綠。
- 尚未跑真實付費 Gemini 截斷案例。

## 階段 2：跨段講者一致性已完成自動化實作與本機契約驗證

### 行為

- 新增 `SpeakerRoster`／`SpeakerIdentity`。
- 由行首 speaker prefix、自我介紹與相符詞庫建立 canonical label。
- 後續分段 Prompt 加入既有 canonical labels 與 aliases。
- 簡稱、稱謂與唯一近似 alias 可映射回 canonical label。
- 正規化只改行首 `講者：`，不改正文內容。
- speaker roster 寫入 cloud manifest，checkpoint resume 會沿用。
- final merge 再以完整 roster 正規化所有 segment。

### 已驗證

- 全名 → 簡稱。
- 稱謂同音字 alias。
- generic label + 自我介紹。
- 詞庫可覆蓋錯誤自我介紹。
- roster prompt 與 cloud resume persistence。

### 未驗證／風險

- 自我介紹與近似 alias 使用 heuristic，必須用真實多人錄音檢查是否錯併不同講者。
- 尚未驗證中途真正加入第三位相似姓名講者的情境。
- 這仍不是專用 diarization，不得宣稱聲紋準確度。

## 階段 3：Qwen watchdog／chunk checkpoint 已完成實作、契約與短時實機驗證

### 行為

- 固定 180 秒 hard timeout 改成 `HelperInactivityPolicy`：
  - 1.7B BF16、120 秒 chunk：600 秒。
  - 1.7B 8-bit：依 chunk duration 動態計算。
  - 0.6B：較短，但最低仍為 300 秒。
  - hard cap 20 分鐘。
- Persistent helper timeout 後自動重啟一次。
- Python 每完成一個內部 chunk 就原子寫 `.chunks.json`。
- checkpoint fingerprint 包含音訊長度、sample rate、模型 revision、Prompt、terms、token 與 chunk 設定。
- helper 重啟時只沿用連續且 fingerprint 相符的 completed chunks。
- 成功後清除 `.partial.txt`；checkpoint 保留至整個 App job 完成，再由 Swift 清除 recovery directory。
- 本機失敗工作若存在 chunk checkpoints，主畫面提供「從已完成 Qwen chunk 續跑」。
- checkpoint 目錄強制為 `0700`，checkpoint 檔由原子寫入維持 `0600`。
- App 取消或上次非正常結束時，會重新辨識結構正確的 local checkpoint 並提供續跑。
- 復原掃描會排除仍被執行中工作使用的新舊 checkpoint 目錄，避免 UI 誤刪。
- 若取消發生在第一個 chunk 完成前，會清掉空復原目錄，不製造假的可續跑狀態。

### 已驗證

- 動態 hard timeout 計算。
- 第一個 chunk 完成、第二個失敗後會留下 checkpoint。
- 第二次執行只生成剩餘 chunk，輸出按順序合併。
- incompatible／invalid checkpoint 會安全退回從頭處理該 coordinator segment。
- App/Core 可以編譯，既有 pipeline tests 全綠。
- 實機 Qwen3-ASR 1.7B BF16：10 分鐘音檔切成 20 chunk，第 7 chunk 後中止，第二次明確「沿用前 7／20 塊」，最後 20／20 完成。
- 實機輸出 3,857 字元，無 skipped-audio marker。

### 未驗證／風險

- 尚未跑真實 30／173 分鐘 MLX／Metal soak。
- timeout 後 persistent process tree 的終止與立即重啟尚未做真實 soak。
- local resume 成功後清理舊 recovery directory 的完整 UI／檔案行為尚未驗證。
- 目前自動重啟只處理 `helperTimedOut`，一般 native crash 仍維持 fail-closed。

## 主要修改檔案

- `.github/workflows/ci.yml`
- `Sources/RecordToTextCore/TranscriptionEngine.swift`
- `Sources/RecordToTextCore/ASRBackend.swift`
- `Sources/RecordToTextCore/LocalChunkCheckpoint.swift`
- `Sources/RecordToTextCore/AudioSegmentation.swift`
- `Sources/RecordToTextCore/CloudResumeCheckpoint.swift`
- `Sources/RecordToTextCore/CloudTranscriptionModels.swift`
- `Sources/RecordToTextCore/SpeakerRoster.swift`
- `Sources/RecordToTextCore/GeminiPromptFeedbackParser.swift`
- `Sources/RecordToTextCore/GeminiTranscriptPrompt.swift`
- `Sources/RecordToTextCore/GoogleAIStudioBackend.swift`
- `Sources/RecordToTextCore/VertexAIGeminiBackend.swift`
- `Sources/RecordToTextApp/AppViewModel.swift`
- `Sources/RecordToTextApp/MainView.swift`
- `Sources/RecordToTextApp/Resources/qwen_asr_chunking.py`
- `Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py`
- 對應 Swift／Python tests 與 self-test。

## 下次接手順序

1. 先讀本檔與 `docs/reliability-v2-validation.md`。
2. 執行：

   ```bash
   git status --short --branch
   git diff --check
   scripts/run-checks.sh
   ```

3. cloud adaptive split mock pipeline test 與完整 Xcode CI 已於 `9c21834`／Run `33263989282` 完成。
4. 以短音檔驗證真實 Vertex／AI Studio `MAX_TOKENS` 行為；設定支出上限，不重複大量付費測試。
5. 用 30 分鐘多人錄音驗證 speaker roster，檢查 canonical labels 是否誤合併。
6. 用 Qwen BF16 先跑 30 分鐘，再跑原 173 分鐘 soak；測試 timeout restart 與手動 chunk resume。
7. 以 App GUI 驗證 active cloud progress、High Contrast、Reduce Motion、recovery scan、resume button、取消與清理。
8. 真實驗收完成前不要合併主分支、建立 Stable release 或替換正式使用版本。

## 回滾

- 本段原本的「沒有 commit」只描述 2026-08-28 當時狀態；目前可靠停點是 `9c21834`，不可再把 `7b3c426` 當成目前 HEAD。
- 不要使用 `git reset --hard`；需回看舊基準時使用獨立 worktree，避免破壞目前分支。
- 未刪除任何既有復原資料、模型或使用者輸出。
