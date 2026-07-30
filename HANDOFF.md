# record-to-text 交班單

- 交班日期：2026-07-30
- Repository：https://github.com/cpn565-stack/record-to-text
- 分支：`main`
- 實作基準：`2283747`（長錄音完整性 checkpoint）

## 一句話狀態

目前已完成可編譯、可測試的 **Phase 0 / Apple Silicon Developer Mode MVP**、coordinator-level 30 分鐘預切、durable Job ledger，以及**啟動時唯讀復原掃描**；但尚不是可交付一般使用者的 Stable 版本。下一個 checkpoint 是復原掃描之上的清理／復原操作 UI（仍須確認且只動 App 管理範圍）。

## 已確認完成

- 原生 SwiftUI macOS App 與 SwiftPM 專案。
- 詞庫、Prompt、工作 Snapshot、拖放、多檔單工佇列、取消、錯誤與最近工作。
- `ffprobe -> ffmpeg -> ASR helper -> OpenCC -> 原子 TXT` 管線。
- 超過 30 分鐘時產生編號 WAV、逐段獨立 ASR、manifest 狀態追蹤與全段成功後順序合併。
- Job ledger 永遠保留 queued／active／interrupted 工作，`recentJobLimit` 只裁切 terminal history。
- Apple Silicon MLX-Audio helper，以及標示為 Experimental 的 Intel helper。
- 非覆寫原子輸出、空白／非 UTF-8 拒收、失敗 WAV 復原與暫存清理。
- 20 項 executable self-test，以及九種成功／失敗／取消／分段管線整合情境。
- 63 個 XCTest。
- Release、簽署、公證、DMG 與驗證 scripts；缺少憑證時會停止，不會假裝正式發佈成功。

## 驗證狀態

- 本機 `scripts/run-checks.sh`：通過可在 Command Line Tools 執行的建置、自測與 mock 管線。
- 長錄音 checkpoint GitHub Actions CI：成功。
  - Run：https://github.com/cpn565-stack/record-to-text/actions/runs/30537812415
  - 完整 Xcode 下 55 個 XCTest 通過。
  - 18 項 executable self-test 與九種管線情境通過。
  - unsigned App bundle 建置通過。
  - App bundle 無模型權重檢查通過。
- Codex 受限環境沒有可用 Metal，因此**尚未確認真實 Qwen3-ASR 端到端轉錄**。

## 已完成 checkpoint：30 分鐘預切

已實際觀察到直接處理長錄音可能只輸出前段。現在已在 Swift coordinator 完成：

- `AudioSegmentPlanner` 對 31／65／120 分鐘產生 2／3／4 段。
- `ffmpeg` 依計畫輸出 `segment-0001.wav` 起的 16 kHz mono PCM WAV。
- 每段使用獨立 ASR request 與 token budget。
- `segment-manifest.json` 記錄片段編號、時間範圍、路徑、狀態與 completed 次數。
- 只有片段連續、依序、非空白 UTF-8 且各恰好 completed 一次時才以 LF 合併。
- 縮時 mock E2E 已證明尾端唯一驗證句存在且順序正確。
- 中段／尾段失敗、空白、token limit 或未 completed 時，不產生 `_繁體.txt`。
- 失敗時 recovery 會保留 `normalized.wav`、`recovery.json` 與 segment manifest。

仍待以真實 Metal 模型及 31／65／120 分鐘音檔完成長時間驗收；目前不能宣稱任意長度會議已正式支援。

## 已完成 checkpoint：Job ledger

- `JobRetentionPolicy` 將 queued、active stages 與 crash 後的 interrupted 工作視為 durable。
- `recentJobLimit=0` 仍會保存全部未完成工作。
- 佇列即使長於歷史顯示上限也不會被 ledger 截斷。
- completed 不寫入 ledger；failed／cancelled 只保留最新 terminal history。
- 保存時每筆 ledger 日誌仍裁切為最後 100 行。
- 已加入 JSON round-trip、limit 0、長佇列、terminal 新舊排序與 log cap 測試。

## 已完成 checkpoint：啟動復原掃描（唯讀）

- `RecoveryScanner` 盤點 `{tmpdir}/record-to-text/<UUID>` 與 `Temp-Recovery/<UUID>`。
- 狀態：可復原／孤立／損壞；非 UUID 忽略；**不刪除**。
- 啟動有發現時顯示 sheet；工具列「復原掃描」可重跑。

## 後續風險與待辦

依優先順序：

1. 復原掃描的清理／復原操作 UI（二次確認、只動 App 管理範圍）。
2. 修正 ProcessRunner 在 launch 前取消的 race，並處理 helper 子程序樹。
3. 為 ffprobe、ffmpeg、OpenCC 加入 timeout／inactivity watchdog。
4. 同時檢查暫存位置與輸出 volume 的可用空間。
5. 顯示最近工作的來源／輸出檔是否已移動或刪除，並決定完成工作日誌保留策略。
6. 建立 App 管理、可重現且有簽章信任鏈的 arm64 Runtime／Model installer。
7. 完成真實 Metal ASR、Intel 實機、Universal 2、Developer ID、公證、乾淨帳號與正式 DMG 驗收。

## 重要界線

- 不得把目前版本標示為 v1.0 Stable。
- 不得宣稱真實 Qwen3-ASR 已端到端驗證。
- Intel 支援目前只能標示為 Blocked / Experimental。
- Developer Mode 可以使用 Homebrew 與 `~/mlx-audio-env`；Release Mode 必須使用 App 管理且已驗證的 Runtime。
- 不要在 Codex 受限環境執行 MLX／PyTorch 模型載入；該環境缺少可用 Metal，先前曾造成 native process crash。
- 不要把轉錄內容、詞庫、檔名、路徑或憑證加入 repository 或測試輸出。

## 接手時先看

1. `README.md`：專案定位、建置、執行與發佈方式。
2. `docs/NEXT_STEPS.md`：下一個 checkpoint。
3. `docs/product-decisions.md`：技術與產品決策。
4. `docs/product-spec.md`：需求追蹤。
5. `docs/technical-spike.md`：已驗證證據與外部條件。
6. `CHANGELOG.md`：目前變更與已知限制。

原始產品與技術規格書位於：

```text
/Users/mike/Downloads/Qwen_會議轉錄器_App_產品與技術規格書_v1.0.md
```

## 接手檢查

```bash
git pull --ff-only
git status --short
scripts/run-checks.sh
```

若有完整 Xcode，`scripts/run-checks.sh` 會一併執行 XCTest。下一輪先建立不執行刪除的 recovery scanner 與 fixture，確認只辨識 App 管理範圍後，再決定孤兒暫存的清理 UI。
