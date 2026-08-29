# 交班單 — 2026-08-29 UI／0.2.0

> **歷史 UI 交班。** 0.2.0 UI 與標題狀態仍有效；Reliability v2 工作 1–3 的後續自動化與文件收尾請見 `docs/handoff-2026-08-30-reliability-v2-closeout.md`。

## 安全停點

- 分支：`codex/record-to-text-reliability-v2`
- 已 push：`26da9aa`（0.2.0 本體）以及後續標題修正 commit。
- 行銷版本：`Config/version.env` → **0.2.0**（契約是 `x.y.z`，不能寫成 0.2）
- 工作區在這份交班寫下時應為乾淨。
- 不要 reset／revert 這條分支。
- 本機 `/Applications/record-to-text.app` 已重裝成 0.2.0 build 1，標題為純 `record-to-text`。
- 完整 XCTest 在 CLTs 環境仍會 `no such module 'XCTest'`。

## 已提交（26da9aa 與標題修正）

承接 Codex `docs/ui-refresh-handoff-2026-08-29.md` 之後的 UI 調整，並把 reliability v2 未提交工作一起進 0.2.0。

### 進行中卡片

- 整張洗藍拿掉；進行中只留左邊 3pt 藍線。底色、邊框與其他卡片相同。
- 卡片上不再顯示模型名稱、token、thinking。
- 取消按鈕仍在佇列標題列與卡片 stop icon。

### 進度條

- 已完成段才實心填滿（契約不變）。
- **目前這一格**用前段 `latencySeconds` 中位數估時，按經過時間往前填，最多該格 **90%**。沒有前段時預設 90 秒。
- 超過預估就停在 90%，等該段真正回來再跳滿。不會倒退，也不把預測百分比寫進 ledger。
- 文案只講「第 n／m 段 · 已完成 x 段」，不寫預測的整體 %。

### 日誌

- 主畫面最多兩句白話狀態（濾掉 HTTP／JSON／thinkingConfig／token 等）。
- 完整紀錄改走 **複製除錯資訊**（卡片連結 + 右鍵選單）。

### 進件區

- 佇列有工作時，拖放區收成一列。
- 「開始轉文字」與切分移到拖放區正下方；佇列標題列不再放開始。
- 沒有等待中工作時，文案是「等待加入檔案」。

### 版本

- `Config/version.env`：`MARKETING_VERSION=0.2.0`，`DEFAULT_BUILD_NUMBER=1`
- `CHANGELOG.md` 已開 `[0.2.0] - 2026-08-29`

## 標題修正（已提交）

使用者指出標題不該寫版本號。

- 視窗標題回到 `record-to-text`
- 主畫面標題下那行版本已刪
- 版本仍在設定裡；除錯剪貼簿仍帶版本字串

## 本機 App

| 位置 | 狀態 |
|---|---|
| `/Applications/record-to-text.app` | 0.2.0 (1)，標題已是純 `record-to-text` |
| `/Applications/record-to-text 2.app` | 8/14 舊版，**沒動** |
| `dist/record-to-text.app` | 與 Applications 同一份重裝來源 |

三份仍共用 bundle id `com.specifique.record-to-text`。認法改看開啟路徑，不要再靠標題版本。

## 刻意沒做／不要做

- 不要把 `MAX_TOKENS` 截斷文字當正式稿（那是舊討論，0.2.0 這條線維持 fail-closed／切小）。
- 不要為了認 App 再把版本寫回標題。
- 本輪當時尚未做窄視窗、深色模式、High Contrast、Reduce Motion 系統性目視；後續已確認 760-point 最小寬度、深色模式與摺疊／展開狀態，High Contrast、Reduce Motion 與真實 active cloud job 仍未驗證。
- `record-to-text2`（`d99b442`）是另一個 repo，與這條 reliability-v2 無關。

## 建議下一手

1. 有佇列工作時看拖放區是否夠扁、「開始轉文字」是否在進件區下方。
2. 跑一筆雲端多段工作，確認進度條在段內會走、在 90% 封頂、完成後才跳下一格。
3. 不要從這條分支 checkout 去 `d99b442` 或 reset。
