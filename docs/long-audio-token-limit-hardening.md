# 長音檔 Token Limit Hardening 實作規格

狀態：程式實作完成；真實 Metal 已局部驗證，最小片段仍撞上限時改採明確缺口並繼續  
日期：2026-08-01  
適用範圍：Apple Silicon MLX-Audio Qwen3-ASR helper

## 1. 背景與問題

目前長音檔流程已用實際約兩個半小時會議錄音驗證成功：來源檔先切成兩段，再由 coordinator 以最長 20 分鐘切段；每個 coordinator segment 交給 MLX helper 後，再以 120 秒內部 chunk 處理。

現行 helper 在內部 chunk 達到 `maximumTokens` 時，會先對半遞迴切分；若最小約 30 秒仍無法安全辨識，該片段不再重試，改插入明確缺口標記並繼續處理後面的音訊。其他非 token-limit 錯誤仍維持失敗復原流程。

本次修改的目標是修正這個安全邊界，不改變目前已驗證有效的 120 秒內部切段策略。

## 2. 目標

1. 任一 ASR span 達到 token 上限且無法安全再切分時，只跳過該 span，不把可能截斷的文字當成辨識結果。
2. 跳過的 span 必須寫入明確缺口標記，並繼續處理後續音訊。
3. 仍可在 span 足夠長時遞迴對半切分並重新轉錄。
4. Swift coordinator 與 segment manifest 必須記錄「完成但有缺口」，正式輸出仍可產生，但不能看起來像完整無缺的逐字稿。
5. 其他錯誤仍走 Temp-Recovery partial transcript，不得把一般失敗當成功。
6. 在沒有 Metal 的環境中，用 fake model 測試上述行為。

## 3. 非目標

- 本次不調整 coordinator 的 20 分鐘上限。
- 本次不調整 helper 的 120 秒預設 chunk。
- 本次不處理每個 coordinator segment 重複 `Fetching 11 files` 的模型載入效能；該項目另列後續工作。
- 本次不宣稱已完成真實 Metal 長音檔品質驗收。

## 4. 行為規格

### 4.1 Token limit 判定

- `generation_tokens >= maximum_tokens` 視為該 span 達到生成上限。
- `generation_tokens < maximum_tokens` 才可視為未撞上限。
- 不把 warning 當成成功替代方案。

### 4.2 可再切分時

若符合以下條件，對 span 對半切分後遞迴處理：

- span 長度至少為最小切分長度的兩倍；以及
- 遞迴深度尚未達上限。

左右結果必須依原始時間順序合併；任一側抵達不可再切的 token-limit leaf 時，插入缺口標記後繼續處理另一側。

### 4.3 無法再切分時

helper 必須：

1. 送出 JSONL `warning` event。
2. 使用穩定警告碼 `chunk_skipped_token_limit`。
3. 不回傳該 span 的截斷文字給成功路徑。
4. 寫入類似 `【此處約缺少 30 秒：模型達到 token 上限，已跳過此片段】` 的缺口標記。
5. 繼續處理目前 coordinator segment 與後續 segment。
6. 全部後續處理完成後送出一次 `completed` event，並標記 `containsSkippedAudio=true`。

若發生一般 helper error、空白輸出或非 token-limit 例外，仍沿用 fail-closed：不送出 `completed`，並在 Temp-Recovery 保留 `partial-transcript.txt`。

### 4.4 Swift 端結果

`HelperASRBackend` 讀取 `containsSkippedAudio`，讓 `AudioSegmentManifest` 將該段標成 `completedWithGaps`。正式合併 gate 接受 `completed` 與 `completedWithGaps`，App 日誌明確提示輸出含缺口。

## 5. 實作設計

將目前 nested `generate_span` 抽成可測試的純協作函式，至少接受：

- model generate callable；
- audio span；
- generation arguments；
- sample rate；
- maximum tokens；
- minimum split seconds；
- maximum recursion depth；
- event emitter。

函式回傳按時間順序排列的文字與缺口標記；沒有提供 skip callback 的測試路徑仍會丟出明確的 `TokenLimitReached` 例外，維持安全邊界可測試。

MLX runner 提供 skip callback；只針對不可再切的 token-limit leaf 採 warning-success，移除任何把截斷文字當成功的 fallback。

## 6. 測試規格

新增不載入 MLX／Metal 的 Python `unittest` 測試，使用 fake model 與 fake result：

1. 未達上限：一次 generate，回傳文字。
2. 120 秒 span 達上限、60 秒左右兩側未達上限：成功合併且順序正確。
3. 遞迴切分後左側達上限：無 skip callback 時整個 span 失敗，不回傳部分文字。
4. 最小可切長度仍達上限：無 skip callback 時拋出 `TokenLimitReached`；有 skip callback 時留下缺口並繼續右側。
5. 遞迴深度達上限仍達上限：拋出 `TokenLimitReached`。
6. `generation_tokens == maximum_tokens`：視為達上限。
7. skip token-limit：寫入缺口標記、繼續後續內容，並只送一次帶 `containsSkippedAudio` 的 completed。
8. 一般 failure：不寫正式 output、不送 completed，並產生 recovery draft。
9. 正常成功：只送一次 completed，output 內容正確。

測試接入 `scripts/run-checks.sh`，不依賴完整 Xcode、不需要 Metal、不下載模型。

## 7. 驗收條件

- Python runner 語法檢查通過。
- 新增 runner unit tests 全部通過。
- 既有 `scripts/run-checks.sh` 的 Swift build、self-test、mock pipeline 全部通過。
- `git diff --check` 通過。
- 不可再切的 token-limit 只略過該 30 秒並留下缺口標記；一般 failure 仍不會產生 `completed` 或正式 helper output。
- 已驗證的 120 秒切段與 20 分鐘 coordinator 行為沒有被改變。

## 8. 後續工作

另開效能優化 checkpoint，調查每個 coordinator segment 反覆 `Fetching 11 files` 的模型載入生命週期；完成前必須保留本規格的 fail-closed 行為與長音檔完整性測試。
