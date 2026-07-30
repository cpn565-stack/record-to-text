# record-to-text Phase 0 技術 Spike

版本：0.1
日期：2026-07-30
狀態：進行中，尚未完成真實音檔端到端驗證

## 1. 目的

本文件把《Qwen 會議轉錄器 App 產品與技術規格書 v1.0》中的 Phase 0，收斂成可驗證、不可含糊的技術門檻。

Phase 0 的目的不是產生完整 UI，也不是宣稱 v1.0 Stable，而是先證明以下垂直管線在目前 Apple Silicon Mac 上成立：

```text
音檔
  -> ffprobe 驗證
  -> ffmpeg 正規化為 16 kHz / mono / PCM s16le WAV
  -> Qwen3-ASR 1.7B 8-bit，確實套用專有名詞 prompt
  -> OpenCC s2twp
  -> UTF-8、LF、無 BOM 的 *_繁體.txt
```

任何尚未實際執行的項目，都不得以「應該可行」寫成已通過。

## 2. 證據狀態定義

| 狀態 | 定義 |
| --- | --- |
| 已確認 | 已由本機環境、原始碼或實際命令取得直接證據 |
| 本次可驗證 | 不需外部憑證或其他實機，完成實作後可在目前 Mac 驗證 |
| 需外部條件 | 需要完整 Xcode、GitHub 登入、Developer ID、Intel 實機、乾淨帳號或正式 Runtime artifact |
| 尚未驗證 | 目前沒有足夠證據，不得作為產品承諾 |

## 3. 已確認的事實

### 3.1 本機與開發環境

- 目前主機是 Apple Silicon M1 Max、32 GB RAM，作業系統為 macOS 15.7.3。
- 工作目錄是 `record-to-text`，初始狀態為空目錄；目前已開始建立 Swift Package 核心結構。
- 系統有 Swift 6.1.2 與 macOS SDK，但目前只選用 Command Line Tools。
- 完整 Xcode 尚未安裝或未可用；`xcodebuild` 會回報目前 developer directory 只是 Command Line Tools。
- `/opt/homebrew/bin/ffmpeg`、`ffprobe`、`opencc` 可供 Developer Mode 使用。
- `~/mlx-audio-env` 存在，已安裝 `mlx-audio 0.4.6`。
- 本機 Hugging Face cache 已有 `mlx-community/Qwen3-ASR-1.7B-8bit`，約 2.3 GB。
- 以上只證明開發依賴存在，不等於 ASR 端到端已通過。

### 3.2 Qwen3-ASR prompt 能力

- 本機 `mlx-audio 0.4.6` 的 Qwen3-ASR 原始碼包含 `system_prompt` 參數。
- MLX backend 應使用 `system_prompt`。
- 官方 Qwen Transformers wrapper 使用的是 `context`；這是 Intel backend 的獨立 adapter，不應把兩個參數當成同一 API 做盲目 fallback。
- helper 必須先回報 capability，再開始含詞庫的工作。若兩者皆不支援，必須停下並要求使用者明確同意無詞庫轉錄。

### 3.3 目前尚未取得的證據

- 本次 Codex 自動化 process 未完成 Metal 推論，不能據此宣稱模型已成功載入或完成轉錄。
- 尚未以 1 分鐘與 30 分鐘音檔完成真實管線。
- 尚未量測 1.7B 8-bit 的載入時間、峰值記憶體、real-time factor 或長音檔穩定性。
- 「1.7B 8-bit 與 BF16 逐字內容差異很小」仍是待驗證假設。

## 4. 本次可驗證的範圍

以下項目不需要 Developer ID、Intel Mac 或正式下載站：

1. TermParser、PromptBuilder、OutputNameBuilder、JSONLParser、狀態機與 JSON repository 的單元測試。
2. Mock helper 的 JSONL 分段輸入、錯誤輸入、Unicode 與取消測試。
3. Developer Mode 的 `ffprobe -> ffmpeg -> mock ASR -> OpenCC -> 原子輸出`。
4. 在目前 M1 Max 上，以本機 MLX env 與模型 cache 執行真實 Qwen3-ASR helper。
5. `system_prompt` capability 檢查與「不得靜默忽略詞庫」行為。
6. 中文、空格、括號與單引號路徑，不經 shell 字串拼接。
7. 成功刪除暫存 WAV；失敗時把 WAV 與最小 recovery metadata 移入 `Temp-Recovery`。
8. helper heartbeat、coordinator liveness 計時與分級取消。
9. UTF-8、LF、無 BOM、OpenCC `s2twp`、命名遞增與來源 hash 不變。
10. 使用 Command Line Tools 執行 executable self-test；完整 XCTest 仍需 Xcode，這不等於正式 `.app` 已通過。

## 5. 需外部條件的範圍

| 項目 | 所需外部條件 | 在條件完成前的正確標示 |
| --- | --- | --- |
| `xcodebuild test`、Archive 與互動驗收 | 完整 Xcode | SwiftPM `.app` 已建置；XCTest／互動未驗證 |
| Universal 2 與 x86_64 slice | 完整 Xcode；必要時 Rosetta／Intel 實機 | 未驗證 |
| GitHub Actions 完整 XCTest | GitHub hosted runner 與完整 Xcode | workflow 已建立；首次執行結果待確認 |
| Developer ID 簽署 | Developer ID Application 憑證與 Team ID | unsigned / dry-run |
| Apple notarization 與 staple | notarytool credentials | 未公證 |
| 正式 arm64 Runtime | 可重現的 runtime build、簽署 artifact、manifest 與 HTTPS hosting | Developer Mode only |
| 正式 x86_64 Runtime | x86_64 Python／PyTorch artifact 與 Intel 實機 | Blocked / Experimental |
| Intel 0.6B CPU 轉錄 | 至少一台 Intel Mac | 不得宣稱可用 |
| 乾淨帳號首次啟動 | 無 Homebrew／Python 的乾淨帳號或測試機 | AC-20 未驗證 |
| macOS 最低版本 | macOS 14 測試機或 VM | deployment target 已決定，尚未實測 |
| 正式發佈名稱 | 品牌／商標檢視 | 專案名維持 `record-to-text` |

## 6. Phase 0 固定技術基線

### 6.1 Apple Silicon Developer Mode

| 項目 | Phase 0 基線 |
| --- | --- |
| Backend | Python helper + MLX-Audio |
| MLX-Audio | 先鎖定本機已知版本 0.4.6；升版需重跑 capability 與整合測試 |
| Model | `mlx-community/Qwen3-ASR-1.7B-8bit` |
| Model revision | Phase 0 可讀本機 cache revision；Release 前必須固定 commit revision 與 digest |
| Prompt | `system_prompt` |
| 語言 | `Chinese` |
| 音訊 | 16 kHz、mono、PCM s16le WAV |
| 繁體轉換 | OpenCC `s2twp` |
| 同時工作數 | 1 |
| 正式輸出 | UTF-8、LF、無 BOM 的 `*_繁體.txt` |

Python helper 是 Phase 0 的驗證工具，不等於正式 Runtime 包裝已決定。Release backend 仍須依 Runtime 大小、簽署、公證與最低系統實測決定。

### 6.2 測試音檔

至少準備以下 fixture：

- 30 至 60 秒中文語音，包含可辨識的專有名詞。
- 相同內容轉成 M4A、MP3、WAV、AAC、FLAC。
- 一個檔名包含中文、空格、括號與單引號。
- 一個損壞檔或副檔名刻意改錯的檔案。
- 一個 30 分鐘音檔，用於 Phase 0 長工作門檻。

測試詞彙至少包含 `SPECIFIQUE`、`OGSTM` 與一個中文人名。驗收重點是 prompt 確實傳入，不能只以單次辨識結果猜測 prompt 是否生效。

## 7. Helper 協定

### 7.1 輸入

helper 只接受 request JSON 路徑，不接受 shell 拼接：

```json
{
  "jobID": "UUID",
  "audioPath": "/absolute/path/normalized.wav",
  "outputPath": "/absolute/path/raw.txt",
  "modelID": "mlx-community/Qwen3-ASR-1.7B-8bit",
  "modelRevision": "pinned-revision",
  "language": "Chinese",
  "prompt": "完整 prompt",
  "modelCacheDirectory": "/absolute/path/Models",
  "offline": true
}
```

`offline` 只有在 ModelManager 已確認完整模型存在後才能是 `true`。helper 不負責暗中下載模型。

### 7.2 Capability

在使用詞庫前，helper 必須輸出 capability event：

```json
{"type":"capabilities","supportsSystemPrompt":true,"supportsContext":false}
```

Apple Silicon Phase 0 的通過條件是 `supportsSystemPrompt=true`。若為 false，coordinator 必須停下，不能把 prompt 丟掉後繼續。

### 7.3 Heartbeat mapping

- 每一筆合法 JSONL event 都更新 coordinator 的 `lastActivityAt`。
- helper 沒有自然產生 `stage` 或 `progress` event 時，至少每 10 秒輸出：

```json
{"type":"heartbeat"}
```

- `heartbeat` 不顯示在一般 UI，也不寫入使用者可見日誌。
- 連續 30 秒沒有任何合法 event 時，coordinator 標記為 `unresponsive` 並顯示警告；不得只因長時間推論就直接殺掉工作。
- 使用者取消後依 `SIGINT -> SIGTERM -> SIGKILL` 分級；各階段的等待秒數需固定並有測試。

## 8. 暫存與失敗復原

工作中的 WAV 可先放在系統 temporary directory：

```text
<system-temp>/record-to-text/<jobID>/normalized.wav
```

結束規則：

- 成功：完成正式 TXT 原子寫入後，刪除整個工作 temp directory。
- ASR 或後處理失敗：將 WAV 移入 `Application Support/record-to-text/Temp-Recovery/<jobID>/normalized.wav`。
- 取消：預設刪除暫存，避免不必要保留錄音衍生檔。
- recovery metadata 只保存 job ID、來源路徑、失敗階段、建立時間與技術錯誤；不保存逐字稿正文。
- UI 必須提供「在 Finder 顯示」與「刪除復原資料」。

## 9. Phase 0 驗收

| ID | 驗收項目 | 通過證據 |
| --- | --- | --- |
| SP-01 | 核心單元測試 | 本機 executable self-test 通過；完整 Xcode／CI 的 `swift test` 另列 |
| SP-02 | helper capability | JSONL 證明 `supportsSystemPrompt=true` |
| SP-03 | 1 分鐘真實轉錄 | 真實 Qwen3-ASR 完成，記錄版本、模型 revision、耗時與輸出 |
| SP-04 | Prompt 不被忽略 | helper 測試或 instrumentation 證明 prompt 進入 `system_prompt` |
| SP-05 | 完整後處理 | OpenCC `s2twp`、UTF-8、LF、無 BOM、正確命名 |
| SP-06 | 原始檔安全 | 轉錄前後來源 path 與 SHA-256 不變 |
| SP-07 | 特殊路徑 | 中文、空格、括號與單引號路徑完成，不經 shell |
| SP-08 | 失敗復原 | 模擬 ASR 失敗後 WAV 位於 `Temp-Recovery` |
| SP-09 | 取消與 liveness | heartbeat 正常；取消能完成分級終止且狀態為 cancelled |
| SP-10 | 30 分鐘工作 | 完成且沒有 token-budget 靜默截斷 |
| SP-11 | Mock E2E | ffmpeg、mock ASR、OpenCC、原子輸出整合測試通過 |
| SP-12 | 技術結論 | 本文件補上實測結果、限制與 Release backend 建議 |

Phase 0 只有在 SP-01 至 SP-12 都有實際證據後才算完成。若 Metal、Xcode 或其他環境限制阻擋，應明確標示 blocked，不得以 mock 結果代替真實 ASR。

## 9.1 2026-07-30 實作驗證快照

已通過：

- `RecordToTextCore` 以 Swift 6.1.2 compiler、Swift 5 language mode 編譯成功。
- executable self-test：18 passed，0 failed。
- Swift mock helper 編譯成功。
- 使用真實 ffprobe、ffmpeg 與 OpenCC 的 mock ASR E2E 成功。
- 路徑包含中文、空格、全形括號與單引號；來源 SHA-256 前後相同。
- 成功工作清除暫存；mock ASR 失敗時保存 normalized WAV、recovery metadata 與 segment manifest 到 `Temp-Recovery`，且 failure stage 正確記錄為 `transcribing`。
- 慢速 mock helper 可被取消，取消後不留下工作暫存或 recovery WAV。
- 30 秒無合法 helper event 的 liveness monitor 會發出可繼續等待／取消的警告。
- 最終輸出採 exclusive atomic rename；競態下不覆寫既有檔案。
- OpenCC `s2twp`、UTF-8、LF、無 BOM 與 `_繁體.txt` 命名驗證成功。
- 31／65／120 分鐘 planner fixture 分別產生 2／3／4 段；縮時 E2E 使用真實 ffmpeg／OpenCC 驗證逐段 ASR、LF 順序合併與尾端唯一驗證句。
- 中段／尾段 ASR 失敗、空白輸出、token limit 與缺少 completed event 時，皆不產生部分正式 TXT。
- SwiftPM debug／release App 與 `.app` bundle 建置成功，兩個 helper resource 均位於 `Contents/Resources`。
- 55 個 XCTest 已由 GitHub Actions 完整 Xcode runner 通過；本機 Command Line Tools 仍無 XCTest module。

仍未通過：

- 真實 Qwen3-ASR／Metal 推論。
- 1 分鐘、30 分鐘與 2 小時真實音檔。
- 正式 Runtime、模型下載完整性、Intel、Universal 2、Developer ID、公證與乾淨帳號。
- 互動式 UI 驗收。

## 10. Phase 0 不包含

- Intel CPU 可用性承諾。
- 正式 Runtime 下載、簽署、公證與 rollback 的完成證明。
- Developer ID DMG。
- GitHub Release。
- Mac App Store、Sandbox 或 XPC helper。
- BF16 品質優勢的產品宣稱。
- 超過 30 分鐘音檔的正式支援承諾；更長時數須另做 soak test 與 token-budget 驗證。

## 11. 參考

- 產品規格：`Qwen_會議轉錄器_App_產品與技術規格書_v1.0.md`
- MLX-Audio：https://github.com/Blaizzy/mlx-audio
- MLX-Audio Swift：https://github.com/Blaizzy/mlx-audio-swift
- Qwen3-ASR：https://github.com/QwenLM/Qwen3-ASR
