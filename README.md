# record-to-text

本機會議錄音 → 台灣繁體逐字稿。

`record-to-text` 是原生 macOS App：把 M4A / MP3 / WAV / AAC / FLAC 拖進去，先整理專有名詞，再在本機完成轉錄。管線依序是 **ffmpeg → Qwen3-ASR → OpenCC**，輸出 UTF-8 繁體 TXT；音檔與文字都留在你的電腦上，不經過雲端。

| | |
| --- | --- |
| **現況** | Phase 0 / Apple Silicon Developer Mode MVP |
| **目標平台** | Apple Silicon（macOS 14+） |
| **Intel** | 不做正式支援（僅保留 Experimental 骨架，未驗證） |
| **不是** | v1.0 Stable、已公證 DMG、或已驗證的真實長會議產品 |

適合：開發者本機試用、管線驗證、後續加 Runtime／簽署前的工程基底。  
不適合：直接發給一般使用者當正式軟體（**乾淨 Mac 雙擊 DMG 還不能轉錄**）。

## 使用前需要的環境（必讀）

目前 **沒有** 把 Python／ffmpeg／模型打進 App。要在本機真正轉出文字，請先準備下列項目。

### 硬體與系統

| 項目 | 要求 |
| --- | --- |
| CPU | **Apple Silicon**（M1／M2／M3…） |
| 系統 | **macOS 14** 或更新 |
| 記憶體 | 建議 **16 GB+**（1.7B 8-bit）；BF16 需要更多 |
| 磁碟 | 模型約 **2.3 GB**（8-bit）或 **3.8 GB**（BF16），另留暫存空間 |
| Intel Mac | **不支援正式使用**（僅 Experimental 骨架，未驗證） |

### 本機必須安裝的工具

用 [Homebrew](https://brew.sh)（Apple Silicon 預設在 `/opt/homebrew`）：

```bash
brew install ffmpeg opencc
```

確認路徑存在：

```bash
which ffmpeg ffprobe opencc
# 預期類似：
# /opt/homebrew/bin/ffmpeg
# /opt/homebrew/bin/ffprobe
# /opt/homebrew/bin/opencc
```

### Python 與 MLX-Audio（ASR）

App Developer Mode 預設使用：

```text
~/mlx-audio-env/bin/python
```

請自行建立虛擬環境並安裝 **mlx-audio**（含 MLX、可跑 Qwen3-ASR 的依賴）。版本需與本機 Metal／mlx 相容；安裝完成後確認：

```bash
~/mlx-audio-env/bin/python -c "import mlx_audio; print('ok')"
```

也可用設定 → Runtime 指定自訂 Python／Helper 路徑。

### 模型（首次轉錄會下載）

| 模型（設定可選） | 約略大小 | 說明 |
| --- | --- | --- |
| `mlx-community/Qwen3-ASR-1.7B-8bit` | ~2.3 GB | 預設，較省空間 |
| `mlx-community/Qwen3-ASR-1.7B-bf16` | ~3.8 GB | 較吃記憶體 |
| `mlx-community/Qwen3-ASR-0.6B-8bit` | 較小 | 較快、品質通常較差 |

- 下載來源：Hugging Face；權重存於  
  `~/Library/Application Support/record-to-text/Models/`  
  （與預設 `~/.cache/huggingface` **不是同一個目錄**，App 可能會再下一份）
- 建議設定環境變數加速／提高額度（可選）：

```bash
export HF_TOKEN="你的_Hugging_Face_Read_Token"
# 若用終端機開 App，可：
open /path/to/record-to-text.app
```

從 Dock 雙擊開啟時，有時吃不到 shell 的 `HF_TOKEN`；可先 `huggingface-cli login` 或從已 export 的終端 `open` App。

### 體積心理預期

| 項目 | 約略大小 |
| --- | --- |
| 目前開發用 `.app`／DMG | 數 MB |
| 本機 Python + mlx-audio 環境 | 約 **0.5 GB** |
| ffmpeg + OpenCC（Homebrew） | 約 **數十 MB** |
| 預設 8-bit 模型 | 約 **2.3 GB** |
| **首次跑通合計** | 多半要準備 **約 3 GB+** 磁碟 |

### 快速自檢清單

在 App 內：**環境檢查**（右上角盾牌 icon），確認 Python、ffmpeg、ffprobe、OpenCC、helper 皆就緒後，再按「開始轉文字」。

1. Apple Silicon + macOS 14+  
2. `ffmpeg` / `ffprobe` / `opencc` 在 PATH（Homebrew）  
3. `~/mlx-audio-env/bin/python` 可 `import mlx_audio`  
4. 能連線 Hugging Face（或模型已在 App Models 目錄）  
5. 輸出資料夾可寫入  

若以上任一項沒有，**不要預期**「下載 Release 就能在同事電腦直接用」。正式「免環境 Runtime」尚未完成，見下方「目前未完成」。

## 現在已經有什麼

- 原生 SwiftUI macOS App。
- 專有名詞解析、去重、Prompt 預覽與工作 Snapshot。
- 拖放、多選、單工佇列、取消、錯誤與最近工作。
- `ffprobe → ffmpeg → ASR helper → OpenCC → 原子寫入 TXT`。
- 超過 **20 分鐘**：coordinator 切成編號 WAV、逐段獨立 ASR（預設 token 預算 16384）；全部通過 manifest gate 後才合併，中段／尾段失敗不交部分結果。
- Apple Silicon：MLX-Audio helper；Prompt 走 `system_prompt`，不支援則 fail closed。
- 設定／詞庫 JSON、失敗 WAV `Temp-Recovery`、來源檔不修改。
- Job ledger：queued／active／interrupted 為 durable，不受「最近工作」上限裁切。
- App 圖示（`Config/AppIcon.icns`）與 `scripts/build-app.sh` 開發用 `.app` 封裝。
- XCTest（需完整 Xcode）、executable self-test、mock 管線（成功／失敗復原／取消／長音檔 fail-closed）。
- 簽署、公證、DMG scripts；缺憑證時會停，不假裝正式發佈。

## 重要修正

原始規格的兩個前提不能直接成立：

1. 第一版最低系統由 macOS 13 修正為 **macOS 14**。目前 MLX runtime 與候選 Swift backend 都以 macOS 14 為基線。
2. Intel 不是「只要換成 Transformers CPU」就成立。PyTorch 已停止現行 macOS x86_64 binary；Intel 只保留精確舊版堆疊的 Experimental spike，在 Intel 真機通過前不宣稱可用。

完整決策與證據邊界見：

- [Phase 0 技術 Spike](docs/technical-spike.md)
- [產品與技術決策](docs/product-decisions.md)
- [需求追蹤](docs/product-spec.md)
- [下一次接續](docs/NEXT_STEPS.md)
- [交班單](HANDOFF.md)

## 開發環境

### Apple Silicon Developer Mode

- macOS 14+
- Swift 5.10+（目前以 Swift 6.1 compiler 的 Swift 5 language mode 驗證）
- SwiftPM App bundle 可用 Command Line Tools 建置；完整 XCTest／Archive 仍需要 Xcode
- Phase 0 可使用：
  - `~/mlx-audio-env/bin/python`
  - `/opt/homebrew/bin/ffmpeg`
  - `/opt/homebrew/bin/ffprobe`
  - `/opt/homebrew/bin/opencc`

Homebrew 與 `~/mlx-audio-env` **只允許 Developer Mode**。正式發佈版必須改用 App 管理、簽署、公證且鎖版的 Runtime。

### 建置

一般環境：

```bash
swift build --product record-to-text
```

Codex sandbox／受限環境可使用：

```bash
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
swift build --disable-sandbox --scratch-path .build --product record-to-text
```

產生開發用 `.app`：

```bash
scripts/build-app.sh
```

輸出：

```text
dist/record-to-text.app
```

### 不依賴 Xcode 的檢查

```bash
scripts/run-checks.sh
```

這會執行：

- Core 與 App 編譯。
- 20 項 executable self-test。
- Swift mock helper 編譯。
- 真實 ffprobe／ffmpeg／OpenCC 成功管線。
- Mock ASR 失敗時的 `Temp-Recovery`、正確失敗階段與暫存清除。
- 慢速 Mock ASR 取消與取消後暫存清除。
- 可控短音檔模擬長錄音切分，驗證逐段順序合併與尾端唯一驗證句。
- 模擬中段／尾段失敗、空白、token limit 與缺少 completed；皆不得產生部分正式 TXT。

完整 Xcode 可用後再執行：

```bash
swift test
```

## 執行

請先完成上方 **「使用前需要的環境」**，再：

1. 開啟 App（開發建置：`scripts/build-app.sh` → `dist/record-to-text.app`；或 Release 上的 unsigned DMG）。
2. **設定 → 一般**：確認版本；完成 onboarding（輸出資料夾等）。
3. **設定 → Runtime**：開啟 **Developer Mode**，確認 Python／helper；用「環境檢查」全部打勾。
4. 選模型（預設 1.7B 8-bit）、整理詞庫。
5. 拖入音檔 → 檔案會進佇列 → 按 **「開始轉文字」**（不會一丟就跑）。
6. 首次使用會下載模型，時間依網路而定。

正式 Runtime 尚未完成前，未開 Developer Mode 時會正確顯示環境未準備，而不是偷偷使用 Homebrew。

## 資料位置

```text
~/Library/Application Support/record-to-text/
├── settings.json
├── glossaries.json
├── recent-jobs.json
├── job-ledger.json
├── Models/
├── Runtimes/
├── Logs/
└── Temp-Recovery/
```

轉錄內容、詞庫、檔名與路徑不會上傳。網路只預留給 Runtime／模型下載及使用者主動檢查更新。

`recent-jobs.json` 只保存不含 Prompt、詞彙與日誌的摘要。可重試工作的完整 Snapshot 僅在 `job-ledger.json` 保存；queued／active／interrupted 工作不受 `recentJobLimit` 影響，只有 terminal history 會裁切，單筆日誌仍限制行數。

## 目前未完成

完整分級清單見 **`docs/NEXT_STEPS.md`**。摘要：

- **免安裝 Homebrew／自架 Python 的 App 管理 Runtime**（乾淨 Mac 一鍵可用）。
- Timeout／磁碟空間檢查；模型每段重複載入優化。
- 系統性 MLX soak（31／65／120 分鐘）與正式「任意長度會議」產品承諾。
- 模型 digest 完整性與正式 installer。
- Intel 實機、Universal 2。
- Developer ID 簽署、公證、Stable DMG、乾淨帳號首次啟動。
- 自動檢查更新（PD-015，規劃中，約每週一次）。

本機 Apple Silicon + Developer Mode 真實轉錄路徑已可用；上述為正式分發與後續工程，不是「完全不能轉錄」。

## 發佈

正式發佈順序：

```bash
scripts/build-release.sh
scripts/sign-app.sh dist/record-to-text.app
scripts/notarize.sh dist/record-to-text.app
scripts/create-dmg.sh dist/record-to-text.app
scripts/notarize.sh dist/record-to-text.dmg
scripts/verify-release.sh dist/record-to-text.app dist/record-to-text.dmg
scripts/publish-release.sh <version> dist/record-to-text.dmg
```

所需憑證與環境變數見各 script 的 `--help`。沒有 Developer ID 或 notarytool profile 時，script 會停止並清楚指出缺少的條件。

## 名稱與授權

專案與 repository 名稱固定為 `record-to-text`；這避免把 Qwen backend 誤當成產品品牌或官方背書。第三方元件與發佈注意事項見 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
