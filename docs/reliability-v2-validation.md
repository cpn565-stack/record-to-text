# record-to-text Reliability v2 驗收基線

## 基準

- 基準 commit：`7b3c426`
- 實作分支：`codex/record-to-text-reliability-v2`
- 目前自動化停點：`9c218344509d51b4c0fecbecec2e91a52725d2ca`
- 工作 2 CI：`9c21834`／Run `33263989282`，178 項 XCTest，0 failures。
- 最新 docs-only 分支 CI：`30153df`／Run `33264569435`，同樣通過 178 項 XCTest、development DMG、App bundle 驗證與 artifact 上傳。
- 私人錄音、逐字稿與絕對路徑不得加入 Git。
- Mock／self-test 只能證明契約與流程，不能代替真實 Gemini、MLX、GUI 或長音驗收。

## 自動檢查

每一階段至少通過：

1. `scripts/run-checks.sh`
2. 完整 XCTest（GitHub Actions，`REQUIRE_XCTEST=1`）
3. App bundle 建置與內容驗證
4. `git diff --check`

## 實際基線

| 路徑 | 音訊 | 基準結果 |
| --- | --- | --- |
| Vertex AI / Gemini 3.7 Flash | 約 62 分鐘多人錄音 | 約 2 分 22 秒完成；仍有跨段講者名稱漂移 |
| Vertex AI / Gemini 3.7 Flash | 約 30 分鐘雙人錄音 | 可產生時間區間與講者標籤；後段可能改用簡稱 |
| 本機 Qwen3-ASR 1.7B BF16 | 約 173 分鐘錄音 | 第 3／9 coordinator segment 被固定 180 秒 inactivity watchdog 中止 |

## 階段 1：MAX_TOKENS

- `MAX_TOKENS` 不得標記為完整成功。
- partial text 只可放入復原資料。
- coordinator 應自動把截斷 span 細切後重跑。
- 子 span 全部 `STOP` 才能進正式稿。
- 不可有時間重疊、缺段或重複轉錄。

### 自動化證據（2026-08-29）

- `fdeaef9`：新增直接呼叫 `TranscriptionEngine.run` 的父段 `MAX_TOKENS` → 左右子段 `STOP` → 正式稿合併整合測試。
- `a3ac87d`、`9c21834`：子段使用非重試 HTTP 400 錯誤，驗證 fail-closed 與 recovery manifest／partial transcript；mock transport 回傳真實格式的 HTTP 400 response body。
- 成功路徑斷言父段截斷文字不進正式稿、請求順序為父段 → 左子段 → 右子段、working/recovery temp 成功清理。
- 失敗路徑斷言不產生正式 TXT、已完成子段與 manifest 保存於 recovery、最大 split depth 2 後拒絕交付。
- CI Run `33263989282`：`CloudAdaptiveSegmentationTests` 6 項全綠；全套 178 項 XCTest，0 failures。
- 測試使用本地 URLProtocol 與短音檔 fixture，沒有真實 API Key、網路或付費 Gemini 呼叫；不能替代真實雲端回歸。

## 階段 2：講者一致性

- 第一段建立 canonical speaker roster。
- 後續分段必須沿用既有標籤。
- 正規化只處理行首 speaker prefix，不修改正文。
- 復原續跑必須沿用相同 roster。
- 仍需標示「講者名稱由模型推定」。

## 階段 3：Qwen watchdog

- chunk 開始後由 Swift 依 chunk 時長與模型決定 deadline。
- 先 warning，超過 hard deadline 才終止。
- timeout／crash／取消都要保存已完成內部 chunk。
- helper 重啟後不得重複提交已完成音訊。
- 173 分鐘真實錄音必須完成，或能從最後 checkpoint 安全續跑。

## 真實驗收矩陣

### Gemini

- 5 分鐘短錄音：Low／Medium／High。
- 30 分鐘雙人錄音：Low／Medium／High。
- 62 分鐘多人錄音：Medium；High 視成本抽測。
- 曾回覆 `SAFETY`／`OTHER` 的音檔：Low／Medium。
- 人工 fixture：`STOP`、`MAX_TOKENS`、空 candidate、`SAFETY`、`OTHER`。

### Qwen

- 5 分鐘 smoke。
- 30 分鐘 BF16。
- 173 分鐘 soak。
- 取消、helper crash、App 重啟、checkpoint resume。

2026-08-28 已完成的實機子集：

- Qwen3-ASR 1.7B BF16，10 分鐘真實訪談音檔，30 秒內部 chunk。
- 於第 7／20 chunk 後中止；checkpoint 保留連續 index 0...6。
- 第二次明確沿用前 7／20 chunk，僅重跑剩餘 13 chunk。
- 最終 20／20 完成，輸出 3,857 個字元，`containsSkippedAudio=false`。
- 測試檔全在系統暫存區，未加入 Git。

## 最終 Go 條件與目前狀態

- **自動化已確認**：`MAX_TOKENS` 父段 partial text 不會成為正式稿；子段全部完成才交付，失敗與最大深度維持 fail-closed。
- **真實環境待驗**：真實 AI Studio／Vertex 截斷回應與 segment coverage。
- **真實環境待驗**：跨段 speaker label 在多人／相似姓名錄音上的一致性。
- **真實環境待驗**：30／173 分鐘 Qwen、timeout restart、resume cleanup。
- **已確認**：完整 CI XCTest 已通過；**尚未確認**：所有真實 runtime、GUI、簽署與正式發佈條件。
