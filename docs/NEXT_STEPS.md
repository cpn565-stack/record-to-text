# 下一次接續

更新日期：2026-08-30
基準 commit：`9c21834`（`codex/record-to-text-reliability-v2`）
目前 checkpoint：**0.2.0 / Reliability v2 自動化收尾完成** — 仍不是可交付一般使用者的 Stable DMG。

---

## 已完成（目前 reliability-v2 分支具備）

### 長錄音與 token 防護

- PD-013：coordinator 以 **1,200 秒（20 分鐘）** 預切；每段 ASR **`maximumTokens=16384`**。
- Helper 內部預設 **120 秒** chunk；滿 token 遞迴對半切，最短約 **30 秒**。
- 不可再切的 leaf 達上限：明確**缺口標記**，不把截斷文字當成功；一般錯誤仍 fail-closed。
- 失敗時保留 `partial-transcript.txt` 救援草稿；正式 TXT 仍須全段通過 gate。
- Segment manifest、31／65／120 分鐘 planner fixture、mock 管線 fail-closed 測試通過。
- 本機真實 Metal／Qwen3-ASR：短檔、約 26 分整檔、長會手動切兩段等路徑已跑通（見 `docs/real-metal-verification-2026-08-01.md`、`docs/handoff-sol-2026-08-02.md`）。

### 長駐 helper 與輸出品質

- 長駐 session 使用 **compact 單行 JSON（JSONL）**，修正 pretty JSON 造成的早期 `JSONDecodeError`。
- 同一 job 內重用 Python／MLX helper 與 model cache。
- 輸出尾端 **Prompt echo** 以 `remove_prompt_echo()` 清除。
- Chunk 規劃抽成 `qwen_asr_chunking.py` + 單元測試。

### Job ledger、復原、取消

- PD-014：durable work 不受 `recentJobLimit` 裁切；completed 不進 ledger。
- `RecoveryScanner`：啟動／手動掃描；刪孤立／損壞；可復原可重新加入來源（不自動刪、不刪原文／正式 TXT）。
- `ProcessRunner`：launch 前取消 race；`setpgid` + process group 終止。

### 產品 UX（Phase 0）

- 模型選擇含 BF16；下載／匯入本機模型。
- 預設輸出後綴 `_逐字稿`；手動「開始轉文字」（無自動開始）。
- 連續進度列、刪除已完成工作、About（版本／build／分段與 token 政策）。
- 圓形 App 圖示；README 環境需求說明。

### 驗證門檻（自動化）

- `scripts/run-checks.sh`：Python tests、executable self-tests、pipeline self-tests。
- 完整 XCTest 需本機／CI 完整 Xcode（CLTs 環境會 SKIP）。

---

## 已完成（2026-08-02）

| # | 項目 | 實作結果 |
|---|------|------|
| 1 | **Timeout／inactivity watchdog** | ProcessRunner 支援絕對 timeout 與 inactivity timeout；ffprobe、ffmpeg、OpenCC、ASR helper 已接入。 |
| 2 | **磁碟空間檢查** | 轉錄前同時檢查暫存 volume 與實際輸出 volume，並保留安全餘裕。 |
| 3 | **最近工作檔案狀態** | 最近工作會標示來源／輸出檔案已移動或刪除；既有 ledger、terminal history 與日誌裁切策略維持不變。 |
| 4 | **模型載入生命週期** | 同一 App 佇列重用 engine／長駐 helper；相同 model revision 命中 Python cache 時跳過重載，並新增技術日誌可辨識 cache hit。 |
| 6 | **輸出契約再驗證** | 新增 final output contract，檢查 BOM、NUL、Prompt echo，並在 segment、merge、OpenCC 後再次驗證。 |
| 7 | **手動 TXT 合併** | 可選取多份 TXT，依分段編號排序合併成新檔；原始檔案不覆寫，後續 LLM 可直接使用。 |
| 15 | **前端等分切片佇列** | 錄音加入佇列後，可在「開始轉文字」旁將單一來源切成前後兩個時間範圍工作；第一段先處理，第二段留在佇列，各自產生有順序的 TXT。 |

## 已完成（2026-08-28，Reliability v2 Phase 4–6）

| 階段 | 結果 |
|---|---|
| **4 啟動效能與復原 UX（P1）** | 模型快取與 RecoveryScanner 改在 utility-priority 背景任務執行；加入取消／generation gate，避免舊結果覆蓋新選擇；復原畫面顯示掃描中與完成時間。 |
| **5 CI、版本、安裝與交付（P1）** | `Config/version.env` 成為單一版本來源；CI 避免重複 App bundle 建置，強制 150 MiB 體積門檻，產生未簽署測試 DMG 與 SHA-256 artifact。 |
| **6 架構整理、repo 清理、體積（P2）** | 啟動盤點邏輯抽成 `StartupInventory`；移除一次性 Gemini patcher；SwiftPM 改為明確打包 3 支 helper，防止 `__pycache__` 進入 App；加入 repo hygiene 與建置體積 gate。 |

## 已完成（2026-08-29，Reliability v2 自動化收尾）

| 項目 | 結果 |
|---|---|
| **工作 1：恢復完整 XCTest CI** | `1d6870c` 修正 optional XCTest 編譯；GitHub Actions Run `33251816818` 通過 175 項 XCTest。 |
| **工作 2：MAX_TOKENS 自適應切段整合測試** | `fdeaef9`、`a3ac87d`、`9c21834` 直接以 `TranscriptionEngine.run` 驗證父段截斷後子段成功、非重試錯誤與最大深度 fail-closed。 |
| **目前完整 CI** | 工作 2：`9c21834`／Run `33263989282`；docs-only 收尾：`30153df`／Run `33264569435`。兩者均通過 178 項 XCTest、development DMG、App bundle 驗證與 artifact 上傳。 |

以上是自動化、決定性證據；沒有呼叫真實 Google API，也沒有取代真實長音或 GUI 驗收。

## 驗證待辦（程式已實作，不等於尚未做）

| 項目 | 尚缺證據 |
|---|---|
| **真實 Gemini 自適應切段** | 以受控短音檔驗證真實 AI Studio／Vertex `MAX_TOKENS`、子段 `STOP`、segment coverage 與成本。 |
| **Speaker roster** | 30 分鐘多人錄音、相似姓名、中途加入第三位講者，確認 heuristic 不會錯併。 |
| **Qwen soak／復原** | 30 分鐘與原 173 分鐘 BF16；timeout restart、手動 chunk resume、成功後 recovery cleanup。 |
| **GUI／輔助使用** | 真實 active cloud job 的 90% 進度、High Contrast、Reduce Motion、recovery scan／resume／取消。 |
| **效能量測** | engine／helper reuse 的耗時、記憶體與 `Fetching 11 files` 前後比較。 |

## 待修改／尚未做（優先序）

### P2 — 產品規劃已定、程式未做

| # | 項目 | 說明 |
|---|------|------|
| 5 | **PD-015 自動檢查更新** | 預設約每 7 天查 GitHub Releases；有新版再提示；設定內手動檢查；只檢查＋引導下載。細節見下方。 |

### P3 — 外部／發佈條件（Blocked 或需資源）

| # | 項目 | 說明 |
|---|------|------|
| 8 | **App 管理 Runtime installer** | 免 Homebrew／自架 Python；簽章信任鏈、digest；乾淨 Mac 一鍵可用。 |
| 9 | **模型 installer 與 digest 驗證** | 正式 installer；固定 revision＋digest（PD-010 完整落地）。 |
| 10 | **Intel 實機** | PD-005：Experimental／Blocked；x86_64 Runtime + 真機轉錄前不得宣稱支援。 |
| 11 | **Universal 2** | arm64 + x86_64 正式建置與驗收。 |
| 12 | **Developer ID、公證、Stable DMG** | 簽署、notarization、乾淨帳號首次啟動、正式發佈流程。 |
| 14 | **品牌／商標** | PD-012：公開名稱不以 Qwen 暗示官方關係；發佈前品牌檢視。 |

---

## 規劃細節：自動檢查更新（PD-015）

- **間隔**：約 7 天（可關／每天／每週）。
- **時機**：啟動後且超過間隔；背景安靜、不擋佇列。
- **有新版**：非阻斷提示；顯示版號與 Release 摘要；使用者決定是否開下載頁。
- **失敗／離線**：安靜失敗或只在設定顯示上次檢查時間。
- **手動**：「立即檢查更新」。
- **來源**：GitHub Releases；Stable 與 prerelease 策略分開。
- **範圍**：App 更新 ≠ 模型重下；模型仍走 Models 流程。
- **依賴**：較適合有正式 Release 流程後上線；Phase 0 可先 stub／週期邏輯。

---

## 明確不做或暫緩

- **Intel 當一等公民**：完成前保持 Blocked／Experimental 標示。
- **把 Developer Mode 偷偷當正式 Runtime**：未就緒須 fail-closed 提示。
- **未確認就 reset／重寫** 大量已驗證的 ASR 正確性路徑。

---

## 建議下一輪開工順序

1. 受控真實 Gemini `MAX_TOKENS` 與 segment coverage 回歸
2. 30 分鐘多人 speaker roster 與 30／173 分鐘 Qwen soak
3. 真實 active cloud job、High Contrast、Reduce Motion 與 recovery cleanup GUI 驗收
4. PD-015 自動檢查更新
5. Runtime installer／簽署／公證（P3，與產品發佈時程綁定）
