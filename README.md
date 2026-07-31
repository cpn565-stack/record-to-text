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
不適合：直接發給一般使用者當正式軟體。

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

第一次啟動時：

1. 確認本機處理與網路使用範圍。
2. 選擇輸出資料夾。
3. 在「進階」開啟 Developer Mode，確認 Python、ffmpeg、ffprobe、OpenCC 與 helper 路徑。
4. 選擇詞庫、加入本次詞彙，再拖入音檔。

正式 Runtime 尚未完成前，Release Mode 會正確顯示環境未準備，而不是偷偷使用 Homebrew。

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

- 真實 MLX 模型端到端驗證：Codex 的受限執行環境沒有 Metal，不能把 native abort 當成 App 實測。
- 1 分鐘、30 分鐘與 2 小時真實音檔 benchmark。
- 31、65、120 分鐘真實音檔與真實模型的長時間驗收；coordinator 邏輯與縮時 mock 管線已完成。
- App 管理的 arm64 Runtime artifact、簽章信任鏈、下載與 rollback。
- 模型檔案完整 digest manifest 與下載 UI。
- Intel 實機推論。
- Universal 2 `.app` 實機矩陣。
- Developer ID 簽署、公證與正式 DMG。
- 乾淨帳號首次啟動驗收。
- 互動式 UI 驗收；63 個 XCTest 由 GitHub Actions 作為完整 gate。

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
