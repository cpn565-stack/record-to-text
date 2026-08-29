# Reliability v2 收尾規格書：CI、MAX_TOKENS 整合測試與文件同步

狀態：Implemented（工作 1、2 已由完整 CI 驗證；工作 3 於 2026-08-30 完成文件同步）
日期：2026-08-29
適用分支：`codex/record-to-text-reliability-v2`
原始基準 commit：`ccc3431174e1af8aa2a5eaf7e8a7d8e784ab6efd`
工作 2 驗證停點：`9c218344509d51b4c0fecbecec2e91a52725d2ca`
產品版本：`0.2.0 (1)`

## 1. 目的

本規格收斂 Reliability v2 目前已知的三項收尾工作：

1. 修正 GitHub Actions 的 XCTest 編譯錯誤，恢復完整 CI。
2. 補上 `MAX_TOKENS → 自適應切段 → 子段 STOP → 正式稿合併` 的完整 `TranscriptionEngine` 整合測試。
3. 整理 0.2.0 後已過期或互相矛盾的文件敘述。

完成本規格代表這三項工作有可重現的自動化證據，不代表已完成真實 Gemini、長音 MLX、Intel、Universal 2、Developer ID、notarization 或 Stable DMG 驗收。

## 實作紀錄

| 工作 | Commit／證據 | 結果 |
|---|---|---|
| 1. XCTest／CI 修復 | `1d6870c`；GitHub Actions Run `33251816818` | 175 項 XCTest，0 failures。 |
| 2. MAX_TOKENS 整合測試 | `fdeaef9`、`a3ac87d`、`9c21834`；Run `33263989282` | 178 項 XCTest，成功／子段失敗／最大深度三條整合路徑全綠。 |
| 3. 文件一致性 | 2026-08-30 docs-only 同步 | 更新 CHANGELOG、決策、NEXT_STEPS、validation 與歷史 handoff；不修改 Sources／Tests。 |

工作 2 的證據來自本地 URLProtocol／短音檔 fixture 與完整 CI，不是付費 Gemini API 的實機證據。

## 2. 基準與已確認問題

### 2.1 Git 與建置基準

- 本機與 `origin/codex/record-to-text-reliability-v2` 應從相同 SHA 開始。
- 開工前必須記錄：

  ```bash
  git status --short --branch
  git rev-parse HEAD
  git rev-parse origin/codex/record-to-text-reliability-v2
  ```

- 不得 reset、revert 或覆蓋使用者既有修改。
- 私人錄音、逐字稿、API Key、token、App Support runtime data 不得加入 Git。

### 2.2 開工時已確認的問題（歷史基線）

- `scripts/run-checks.sh` 在目前本機可通過 Python、Swift executable self-test、mock pipeline、App bundle build 與 `git diff --check`。
- 本機只有 Command Line Tools，因此完整 `swift test` 會被跳過。
- `5e7ff57`、`26da9aa`、`ccc3431` 的 GitHub Actions 都在完整 XCTest 編譯階段失敗。
- 失敗點為 `Tests/RecordToTextCoreTests/CloudAdaptiveSegmentationTests.swift`：`splitBoundary(...)` 回傳 `TimeInterval?`，測試卻直接把 optional 傳給要求 `Double` 的 `XCTAssertEqual(..., accuracy:)`。
- 當時測試已涵蓋 `MAX_TOKENS` parser fail-closed、切點選擇、最大深度、最小子段與 manifest 重編號，但尚未完整驅動 `TranscriptionEngine` 走完自適應重試流程；此缺口後續已由工作 2 補齊。

## 3. 工作一：修正 XCTest／恢復 CI

### 3.1 目標

讓完整 Xcode 環境可以編譯並執行全部 XCTest，且 GitHub Actions 後續的 development artifact、App bundle 驗證與 artifact upload 不再因測試編譯失敗而被跳過。

### 3.2 實作要求

1. 將 `testSplitBoundaryPrefersNearestEligibleSilence()` 改為可明確處理 optional：
   - 建議把測試函式標記為 `throws`；
   - 使用 `try XCTUnwrap(...)` 取得非 optional boundary；
   - 保留 `619 ± 0.001` 的原始斷言。
2. 不得以 `boundary ?? 619`、強制解包或移除精度斷言掩蓋失敗。
3. 既有「達最大深度／不足最小子段時回傳 nil」測試必須保留。
4. 若修正測試後暴露 production code 行為錯誤，必須另列根因；不得只放寬測試期待值讓 CI 變綠。

### 3.3 驗收條件

- `CloudAdaptiveSegmentationTests.swift` 在完整 Xcode 環境可編譯。
- `swift test` 全部通過，沒有 skipped XCTest。
- `scripts/run-checks.sh` 全部通過。
- GitHub Actions 的下列步驟全部成功：
  - Validate version and repository hygiene
  - Build and test
  - Build development delivery artifact
  - Verify functional App bundle contents
  - Upload development App artifact
- CI 成功 run 必須對應預期的 branch SHA，不得拿舊 run 當完成證據。

## 4. 工作二：MAX_TOKENS 自適應切段整合測試

### 4.1 目標

以無網路、無付費 API、可重現的測試，證明 `TranscriptionEngine` 在父段回傳 `CloudOutputTruncatedError` 時會捨棄截斷文字、切成子段重試，並且只有所有子段正常完成後才產生正式稿。

### 4.2 測試層級

這不是 parser 單元測試，也不是只測 `CloudAdaptiveSegmentPlanner` 或 manifest helper。測試必須實際呼叫 `TranscriptionEngine.run(...)`，並觀察：

- cloud request 呼叫順序；
- manifest 狀態轉換；
- warning／progress update；
- partial text 處理；
- 最終輸出內容與完整性 gate；
- 失敗時是否拒絕正式交付。

### 4.3 測試接縫

現有 `TranscriptionEngine` 直接持有 concrete final cloud backends，且 production split policy 使用 240 秒最小子段。為避免測試製造八分鐘以上音檔或連到真實 Google，允許加入最小、內部可測試接縫：

- cloud transcribe sequence closure／protocol；
- adaptive split policy 或 boundary provider；
- 必要的 probe／audio preparation fixture injection。

要求：

1. production initializer 的預設行為、240 秒最小子段、最大 split depth 2 均不得改變。
2. 測試接縫維持 `internal`，由 `@testable import` 使用；不要為測試擴大公開 API。
3. 不得以 mock 整個 `TranscriptionEngine.run(...)` 取代要驗證的流程。
4. 測試不得使用真實 API Key、gcloud credential 或外部網路。

若選擇用自訂 `URLProtocol` 驅動 `GoogleAIStudioBackend`，必須固定 request sequence，並把 `useFilesAPI`／fallback 設定鎖定為測試可預期的值；不得讓測試因網路或 Google 回應變動而不穩定。

### 4.4 必測成功情境

建立一個短、可重現的音訊 fixture，測試 cloud 回應順序如下：

1. 父段第一次請求回傳 `CloudOutputTruncatedError`，partial text 使用明顯字串，例如 `這段截斷文字不得進入正式稿`。
2. 左子段回傳 `STOP` 與 `左子段完整稿`。
3. 右子段回傳 `STOP` 與 `右子段完整稿`。

斷言：

- request 順序為父段、左子段、右子段，沒有重送已完成子段。
- manifest 最終只有連續、無重疊、無缺口的兩個完成子段。
- 子段 `splitDepth == 1`，segment index／count 已重新編號。
- 產生 `cloud_segment_split_max_tokens` warning。
- 正式稿依序包含左右子段完整稿。
- 正式稿不包含父段 partial text、重複文字或 skipped-audio marker。
- `PipelineResult.containsSkippedAudio == false`。
- 正式輸出只在兩個子段都 completed 後建立。

### 4.5 必測失敗情境

至少補一個 fail-closed 情境：

- 父段 `MAX_TOKENS` 後，任一子段失敗；或
- 到達最大 split depth 後仍 `MAX_TOKENS`。

斷言：

- 不產生可被當成完整結果的正式 TXT。
- 已完成子段與診斷資料保留在 recovery／partial 路徑。
- 父段截斷文字不會混入正式輸出。
- 錯誤與 manifest 狀態可指出實際失敗子段。

### 4.6 測試品質要求

- 使用 `TestSupport.makeTemporaryDirectory()` 或等價的 UUID temp root。
- 測試結束清理自行建立的 temp data。
- 測試不得讀寫 `~/Library/Application Support/record-to-text`。
- 成功與失敗測試都必須在 CI 的完整 XCTest 中執行。
- 不得只把相同行為重複加進 executable self-test；完整 XCTest 是必要證據。

### 4.7 驗收條件

- 新測試在本機可用檢查與 GitHub Actions 均通過。
- 測試在無網路、無 credential 狀態仍穩定。
- 測試若故意把 production code 改回「直接接受父段 partial text」，必須失敗。
- 測試若故意跳過其中一個子段，必須失敗。

## 5. 工作三：文件一致性整理

### 5.1 目標

讓 0.2.0 的現況、已完成項目、未驗證項目與發布邊界在文件中一致，同時保留歷史 handoff 的證據價值。

### 5.2 必改文件

#### `CHANGELOG.md`

- 移除或修正「視窗標題顯示行銷版本與 build」的敘述。
- 正確敘述：視窗標題維持 `record-to-text`；版本仍可在設定與複製除錯資訊中取得。
- 在 CI 修復與完整 adaptive split integration test 完成後，把結果記錄在 `[Unreleased]`，不要回寫成 0.2.0 發布前已完成。

#### `docs/product-decisions.md`

- 從「明確尚未完成」移除已實作的項目：
  - ffprobe／ffmpeg／OpenCC timeout；
  - 磁碟空間檢查；
  - 最近工作來源／輸出檔遺失標示。
- 模型重用改成精確狀態：同 runtime／job 的 engine 與 persistent helper reuse 已實作，但真實長音的耗時、記憶體及 `Fetching 11 files` 改善仍待量測。
- 保留 PD-015、正式 Runtime、Intel、Universal 2、簽署／公證與系統性長音 soak 為未完成。

#### `docs/reliability-v2-handoff-2026-08-28.md`

- 不刪除歷史內容。
- 在文件開頭加入醒目的 superseded notice，指向 `docs/handoff-2026-08-29-ui.md` 與本規格。
- 註明 Phase 4–6 後續已進入 `26da9aa`，標題修正已進入 `ccc3431`；原本的「尚未 commit／push」只代表 8/28 當時狀態。
- 完成工作二後，更新原本「尚缺完整 TranscriptionEngine mock」的狀態，並連到新增測試檔。

#### `docs/ui-refresh-handoff-2026-08-29.md`

- 保留原始視覺驗收紀錄。
- 加入 superseded／follow-up 連結，明確說明 0.2.0 已提交、安裝及改回純產品標題。
- 不得把尚未跑的真實 active cloud job、High Contrast、Reduce Motion 寫成已驗證。

#### `docs/NEXT_STEPS.md`

- 更新文件日期與基準 commit。
- 移除已完成但仍殘留的工作；保留真正 backlog。
- 將完整 Gemini、speaker roster、30／173 分鐘 Qwen soak 分到「驗證待辦」，不要混寫成尚未實作。
- 保留 PD-015 與正式發布條件。

#### `docs/reliability-v2-validation.md`

- CI 成功後記錄成功 run URL、branch SHA 與 XCTest 結果。
- 記錄新的 adaptive split integration test 覆蓋範圍。
- 仍須保留「mock／XCTest 不能代替真實 Gemini、MLX、GUI、長音驗收」的邊界。

### 5.3 文件一致性檢查

修改後執行：

```bash
rg -n "視窗標題.*版本|尚未 commit|尚未 push|CI 修改尚未推送|ffprobe.*尚未|磁碟空間.*尚未" \
  CHANGELOG.md docs
git diff --check
```

搜尋結果中的歷史敘述若要保留，必須緊鄰日期或 superseded 說明，不能讓讀者誤認為目前狀態。

### 5.4 驗收條件

- 目前狀態只有一個明確來源，不再同時出現「已完成」與「尚未做」。
- 歷史 handoff 沒有被刪除或竄改成事後版本。
- 文件區分：已實作、已自動驗證、已真實驗證、尚未驗證、外部 blocked。
- 不得把 CI 綠燈寫成真實 Gemini／MLX／GUI／Stable release 證據。

## 6. 執行順序與提交邊界

固定順序：

1. 修正 XCTest optional 編譯問題。
2. 先讓完整 CI 通過，確認測試基線可用。
3. 加入 MAX_TOKENS 自適應切段整合測試及必要的最小 test seam。
4. 重跑本機檢查與完整 CI。
5. 依實際完成結果同步文件。

建議拆成三個可獨立審查的 commit：

1. `test: fix adaptive segmentation XCTest optional handling`
2. `test: cover cloud MAX_TOKENS adaptive split end to end`
3. `docs: reconcile reliability v2 status after 0.2.0`

是否 commit／push 必須依當次使用者授權；規格本身不授權發布、合併主分支、建立 Release 或替換 `/Applications`。

## 7. 完成定義

三項工作只有在以下全部成立時才算完成：

- [x] 本機工作樹沒有非預期修改。
- [x] `scripts/run-checks.sh` 通過。
- [x] 完整 `swift test` 通過，沒有編譯錯誤或 skipped XCTest。
- [x] GitHub Actions 對正確 branch SHA 全綠並產生 development artifact。
- [x] MAX_TOKENS 成功與 fail-closed 整合情境都有測試。
- [x] 父段 partial text 無法進入正式稿。
- [x] 文件已消除 0.2.0 狀態矛盾。
- [x] 最終報告分開列出已確認、仍未驗證與外部 blocked 項目。
