# record-to-text 交班單

- 交班日期：2026-07-30
- Repository：https://github.com/cpn565-stack/record-to-text
- 分支：`main`
- 實作基準：`ff401b4`（Phase 0 checkpoint）

## 一句話狀態

目前已完成可編譯、可測試的 **Phase 0 / Apple Silicon Developer Mode MVP**，但尚不是可交付一般使用者的 Stable 版本。下一個 checkpoint 必須先解決長錄音只輸出前段的完整性問題。

## 已確認完成

- 原生 SwiftUI macOS App 與 SwiftPM 專案。
- 詞庫、Prompt、工作 Snapshot、拖放、多檔單工佇列、取消、錯誤與最近工作。
- `ffprobe -> ffmpeg -> ASR helper -> OpenCC -> 原子 TXT` 管線。
- Apple Silicon MLX-Audio helper，以及標示為 Experimental 的 Intel helper。
- 非覆寫原子輸出、空白／非 UTF-8 拒收、失敗 WAV 復原與暫存清理。
- 14 項 executable self-test，以及成功、失敗復原、慢速取消三種管線整合測試。
- 45 個 XCTest。
- Release、簽署、公證、DMG 與驗證 scripts；缺少憑證時會停止，不會假裝正式發佈成功。

## 驗證狀態

- 本機 `scripts/run-checks.sh`：通過可在 Command Line Tools 執行的建置、自測與 mock 管線。
- GitHub Actions CI：成功。
  - Run：https://github.com/cpn565-stack/record-to-text/actions/runs/30532925926
  - 完整 Xcode 下 45 個 XCTest 通過。
  - unsigned App bundle 建置通過。
  - App bundle 無模型權重檢查通過。
- Codex 受限環境沒有可用 Metal，因此**尚未確認真實 Qwen3-ASR 端到端轉錄**。

## 下一次第一優先：30 分鐘預切

已實際觀察到直接處理長錄音可能只輸出前段。需求已補入原始規格與 `docs/NEXT_STEPS.md`，但尚未實作。

接續順序：

1. 由 Swift coordinator 使用 `ffprobe` 取得總時長。
2. 超過 30 分鐘時，以 `ffmpeg` 產生依序編號、每段最長 30 分鐘的 WAV。
3. 每段必須使用獨立 ASR 呼叫、token budget、完成事件與非空白 UTF-8 驗證。
4. 只有片段數量、順序與內容全部通過，才能依 LF 合併、執行 OpenCC 並原子提交正式 TXT。
5. 任一片段失敗、空白、達 token limit 或未送出 completed，整項工作失敗；不得留下部分正式 TXT。
6. 使用 31、65、120 分鐘 fixture，並在尾端放唯一驗證句，確認最後一段沒有遺失。

現有 Python helper 內部 chunk **不算完成**這項需求；切段與完整性 gate 必須在 coordinator 層可觀察、可驗證。

## 後續風險與待辦

依優先順序：

1. Job ledger 不可因 `recentJobLimit` 截掉 active／queued 工作。
2. 啟動時掃描 system temp 與 `Temp-Recovery`，處理 crash 後孤兒檔案。
3. 修正 ProcessRunner 在 launch 前取消的 race，並處理 helper 子程序樹。
4. 為 ffprobe、ffmpeg、OpenCC 加入 timeout／inactivity watchdog。
5. 同時檢查暫存位置與輸出 volume 的可用空間。
6. 顯示最近工作的來源／輸出檔是否已移動或刪除，並決定完成工作日誌保留策略。
7. 建立 App 管理、可重現且有簽章信任鏈的 arm64 Runtime／Model installer。
8. 完成真實 Metal ASR、Intel 實機、Universal 2、Developer ID、公證、乾淨帳號與正式 DMG 驗收。

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

若有完整 Xcode，`scripts/run-checks.sh` 會一併執行 XCTest。不要用真實長錄音開始下一輪；先以可控 fixture 完成 30 分鐘切段及尾段完整性測試。
