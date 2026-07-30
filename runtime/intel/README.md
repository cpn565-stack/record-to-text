# Intel x86_64 Runtime（Experimental / Blocked）

這個目錄只定義 Intel Mac 技術 spike 的候選 runtime，**不代表 Intel
轉錄已受支援**。在真正的 Intel Mac 完成安裝、模型載入、長音檔、prompt、
取消及熱穩定性測試前，產品狀態必須維持 `Experimental / Blocked`。
Apple Silicon 上的 Rosetta 結果不能替代 Intel 實機證據。

## 固定的 spike 組合

| 元件 | 固定值 | 證據邊界 |
| --- | --- | --- |
| 作業系統／CPU | macOS x86_64 | helper 會拒絕其他平台 |
| Python | 3.12.x x86_64 | 正式 artifact 仍須在 manifest 固定 patch 版與 digest |
| PyTorch | `2.2.2` | 最後仍提供官方 macOS x86_64 wheel 的版本 |
| qwen-asr | `0.0.6` | 官方 wrapper；prompt 參數是 `context` |
| Transformers | `4.57.6` | qwen-asr 0.0.6 的固定相依版本 |
| Accelerate | `1.12.0` | qwen-asr 0.0.6 的固定相依版本 |
| 模型 | `Qwen/Qwen3-ASR-0.6B`、float32、CPU、batch 1 | 尚未取得 Intel 真機速度與記憶體數據 |

不要改用 Transformers 5.13+ 的 `Qwen3-ASR-0.6B-hf` 當 Intel fallback。
該路徑需要 PyTorch 2.4+，而官方已不再提供相對應的 macOS x86_64
binary wheel。

`requirements.lock.txt` 是 **spike 核心相容版本鎖**，不是可發布的完整
runtime lock。qwen-asr 的部分 transitive dependencies 在上游仍未固定。
完成 Intel 真機 cold install 後，必須另產生：

- 完整 dependency closure；
- 每個 wheel 的 SHA-256；
- Python 精確 patch 版；
- x86_64 wheelhouse；
- runtime manifest、簽章及公證證據。

在上述資料產生前，不得把這個 requirements 檔描述成可重現的 release
lock，也不得上傳為正式 runtime artifact。

## Helper 協定

App 以 bundled Python 執行：

```text
qwen_asr_transformers_runner.py \
  --request-json /absolute/path/request.json \
  --events-jsonl -
```

request 使用與 Apple Silicon helper 相同的 JSON schema。Intel helper 額外
限制：

- `audioPath`、`outputPath`、`modelCacheDirectory` 必須是絕對路徑。
- `modelID` 必須是 `Qwen/Qwen3-ASR-0.6B`，或已存在的本地 model snapshot
  絕對路徑。
- 有詞庫時必須同時有非空 `prompt`。
- prompt **只會**傳入 `model.transcribe(..., context=prompt)`。
- helper 會同時檢查 class method 與 bound method 是否真的含有 `context`。
  任一檢查失敗即回傳 `glossary_not_supported`，不嘗試 `system_prompt`、
  `prompt` 或任何其他 fallback，也不理會 `allowMissingPrompt`。
- App 目前實際解析的 capability event 名稱是 `capability`（單數）。

stdout 僅允許一行一個 JSON event。helper 在匯入任何 ML 套件前會把一般
stdout 及 native fd 1 導向 stderr，並保留一個專用 fd 寫 JSONL，避免套件
的 banner、warning 或 `print` 破壞 Swift parser。

典型事件順序：

```json
{"type":"warning","code":"intel_backend_experimental","message":"..."}
{"type":"stage","value":"validating_runtime"}
{"type":"capability","promptTransport":"context","supportsSystemPrompt":false,"supportsContext":true,"experimental":true}
{"type":"stage","value":"loading_model"}
{"type":"heartbeat","value":"loading_model","message":"..."}
{"type":"stage","value":"transcribing"}
{"type":"completed","outputPath":"/absolute/path/raw.txt","durationSeconds":123.4}
```

模型匯入、載入與轉錄期間，每 10 秒至少送出一筆 heartbeat。使用者送出
`SIGINT` 時，helper 回傳 `cancelled` JSONL event 並以 130 結束。

## 模型固定與離線模式

Release 不應在推論時使用浮動的 Hugging Face HEAD。Intel spike 應先把
`Qwen/Qwen3-ASR-0.6B` 下載到由 revision 固定的本地 snapshot，再把該
snapshot 的絕對路徑放進 request。2026-07-30 觀察到的候選 revision 是：

```text
5eb144179a02acc5e5ba31e748d22b0cf3e303b0
```

這只是待回歸測試的候選，不是已核准 release revision。凍結前仍須保存
expected files、sizes、SHA-256 與 license。模型完整存在後，request 應設
`offline=true`；helper 會設定 `HF_HUB_OFFLINE=1` 與
`TRANSFORMERS_OFFLINE=1`。

## 必須在 Intel 實機通過的門檻

1. 乾淨帳號以 x86_64 Python 3.12 cold install，確認所有 wheels 與 hashes。
2. 斷網後載入 0.6B float32 模型。
3. 1、10、60 分鐘音檔完成，記錄 real-time factor、峰值 RAM 與溫度。
4. 以 spy／instrumentation 證明詞庫 prompt 進入 `context`，不能只比較辨識結果。
5. 驗證空 prompt、含詞庫 prompt、超長 prompt 與不相容 runtime 都會
   fail closed。
6. 驗證 heartbeat、`SIGINT -> SIGTERM -> SIGKILL` 取消流程及重新啟動。
7. 驗證 UTF-8／LF／無 BOM、特殊字元路徑，以及來源音檔 hash 不變。

本次新增 helper 時沒有執行 Python、PyTorch、Transformers 或 qwen-asr；
所有推論與相容性狀態仍是未驗證。
