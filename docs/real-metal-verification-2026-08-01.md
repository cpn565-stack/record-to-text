# 2026-08-01 真實 Metal 驗證報告

狀態：局部通過；完整長會議未通過，且已正確 fail-closed

## 結論先講

這項驗證需要做，而且結果證明它不能被省略：

- 真實 MLX／Metal／Qwen3-ASR 1.7B 8-bit 路徑可以載入並工作。
- 新的 token-limit hardening 確實在真實錄音上被觸發，並成功把 120 秒 chunk 遞迴切到 60 秒、再切到 30 秒。
- 第一段約 75 分鐘完成。
- 第二段約 98 分鐘在約第 48–48.5 分鐘位置，即使切到 30 秒仍達 `16384` token，因此以 `chunk_token_limit_reached`、exit code 3 停止，沒有產生正式逐字稿。
- 因此目前不能宣稱這個約兩個半小時的會議已被目前版本可靠完成；原本 Grok 版本能顯示完成，不等於該困難位置沒有截斷風險。

## 測試條件

- 硬體：Apple M1 Max、32 GB RAM、arm64。
- Python：`/Users/mike/mlx-audio-env/bin/python`。
- `mlx-audio`：0.4.6；`mlx`：0.32.0。
- 模型：Qwen3-ASR 1.7B 8-bit，本機 snapshot revision `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`。
- 音訊：原始兩段錄音先用 ffmpeg 正規化為 16 kHz、mono、PCM s16le WAV。
- 預設：`maximumTokens=16384`、helper chunk 120 秒、遞迴最小 chunk 30 秒。
- Prompt capability：實際載入後 `supportsSystemPrompt=true`、`supportsContext=false`，符合 Apple Silicon 既定路徑。

## 實測結果

### 60 秒 preflight

- 真實模型載入成功。
- 60 秒音訊成功完成，耗時約 2.37 秒。
- 送出 `completed`，沒有錯誤事件。

### 第一段：00:00:00–01:15:00

- 音訊長度：4500 秒。
- 120 秒 chunk：38 塊。
- 結果：成功完成。
- 耗時：約 416.78 秒（6 分 57 秒）。
- 輸出：約 73 KB raw Qwen transcript。
- 實際觀察到第 1 個 chunk 達到 `16384` token，之後成功自動切半並繼續完成。

### 第二段：01:15:00–結束

- 音訊長度：約 5888.5 秒。
- 120 秒 chunk：50 塊。
- 第 25 個 chunk（約第二段的 48–50 分鐘區間）達到 token 上限。
- 先切成 60 秒仍達上限，再切成 30 秒仍達上限。
- 最終事件：`chunk_token_limit_reached`。
- exit code：3。
- 正式 output：未產生；沒有 `completed`。

## 判讀

這不是模型環境完全不能用：60 秒 preflight 與第一段 75 分鐘都證明真實 Metal 路徑可用。問題集中在第二段特定音訊區間，且該區間即使縮到 30 秒仍讓模型生成頂滿，較像高密度／不清楚語音造成的模型失控或該區間音訊條件異常，而不是單純 20 分鐘分段太大。

原本的 warning-success 行為在這裡確實不安全：如果保留 30 秒的頂滿文字並繼續送出 `completed`，App 會把一個可能已截斷的局部結果當成整份逐字稿成功。現在的結果雖然是失敗，但失敗是可辨識、可復原、且不污染正式輸出的。

## 尚未宣稱的事項

- 尚未完成這個約兩個半小時錄音的整段正式繁體輸出；本次直接驗證的是 MLX helper raw transcript。
- 尚未逐句人工評分第一段的辨識品質；錄音本身講話快、音質不清，raw ASR 已可看到不少誤辨識，OpenCC 只能轉字體，不能修正辨識錯誤。
- 尚未證明把最小 chunk 再降到 15 秒能可靠解決該區間；不應直接用更小切段掩蓋模型品質問題。

## 建議下一步

1. 保留目前 fail-closed，不恢復 warning-success。
2. 針對原始錄音約 2 小時 03 分至 2 小時 03 分 30 秒附近的音訊做人工聆聽與波形／靜音檢查。
3. 以該局部片段比較 1.7B 8-bit、1.7B BF16 與其他可用模型；若只有特定模型失控，再決定模型 fallback，而不是把截斷文字當成功。
4. 若日後要把 15 秒以下列為產品策略，需另做耗時、上下文遺失與品質比較，不能只因單一案例直接下調全域最小 chunk。
