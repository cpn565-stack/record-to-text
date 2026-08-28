# record-to-text Reliability v2 驗收基線

## 基準

- 基準 commit：`7b3c426`
- 實作分支：`codex/record-to-text-reliability-v2`
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

## 最終 Go 條件

- 不會交付隱藏截斷稿。
- 跨段 speaker label 一致或明確標示不確定。
- 長音 Qwen 不會被固定 180 秒 watchdog 誤殺。
- 完整 XCTest 與真實 runtime 驗收均通過。
