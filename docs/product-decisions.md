# record-to-text 產品與技術決策

版本：0.1
日期：2026-07-30

## 1. 使用方式

本文件記錄已接受、暫定與被外部條件阻塞的決策。若原始 v1.0 規格與本文件衝突，以本文件較新的決策為準，並應在後續規格版本同步修正。

狀態定義：

- **Accepted**：實作應遵守，變更需新增決策。
- **Provisional**：先按此方向驗證，Phase 0 結果可能改變決策。
- **Blocked**：不能靠目前 Apple Silicon 開發環境證明，禁止假裝完成。

## 2. 決策摘要

| ID | 決策 | 狀態 |
| --- | --- | --- |
| PD-001 | 專案與 repository 名稱為 `record-to-text` | Accepted |
| PD-002 | 先完成 Phase 0，再進入 Apple Silicon MVP；目前不標示 v1.0 Stable | Accepted |
| PD-003 | 第一版最低系統修正為 macOS 14.0 | Accepted |
| PD-004 | Phase 0 Apple Silicon 使用 Python + MLX-Audio helper | Provisional |
| PD-005 | Intel backend 保持 Experimental，實機與 x86_64 Runtime 完成前視為 Blocked | Accepted |
| PD-006 | Runtime trust anchor 必須內建於 App，不能信任 manifest 自我聲明 | Accepted |
| PD-007 | `settings.json` 是設定的唯一 source of truth | Accepted |
| PD-008 | 失敗 WAV 移入 `Temp-Recovery`，成功與取消則清除 | Accepted |
| PD-009 | 所有合法 JSONL event 都刷新 liveness，無事件時 helper 發 heartbeat | Accepted |
| PD-010 | 模型必須固定 revision 與 digest，不能只鎖 repo ID | Accepted |
| PD-011 | Phase 0 長音檔門檻為 30 分鐘；更長支援須另行驗證 | Provisional |
| PD-012 | 公開顯示名稱待品牌檢視，不以 Qwen 名稱暗示官方關係 | Accepted |
| PD-013 | 超過 30 分鐘的音檔必須由 coordinator 在 ASR 前明確切段；不得只依賴 backend 內部 chunk | Accepted |

## 3. 詳細決策

### PD-001：專案名稱

**決策**

- repository、Swift Package 與文件中的正式專案識別名稱為 `record-to-text`。
- 程式碼模組可使用 Swift 命名慣例，例如 `RecordToTextCore`。
- Application Support 根目錄使用：

```text
~/Library/Application Support/record-to-text/
```

**理由**

`QwenTranscriber` 只是原始規格中的暫名，而且公開使用 Qwen 名稱仍需品牌／商標檢視。中性專案名可避免把技術 backend 誤當產品品牌。

### PD-002：交付狀態

**決策**

交付順序固定為：

1. Phase 0 技術 Spike。
2. Apple Silicon Developer Mode 單檔垂直切片。
3. Apple Silicon MVP：SwiftUI、詞庫、設定、佇列與錯誤處理。
4. 正式 Runtime 與模型管理。
5. Universal 2 / Intel Experimental。
6. 簽署、公證、DMG 與 Stable release。

目前可以開始實作，但不得因為 Swift 核心或 mock 測試通過，就宣稱完整 P0、正式 Runtime 或 v1.0 Stable 已完成。

### PD-003：最低 macOS 版本修正

**決策**

- 第一版 deployment target 從原規格的 macOS 13.0 修正為 **macOS 14.0**。
- Swift Package、Xcode target、Runtime manifest 與 README 最終必須一致。
- 若未來要恢復 macOS 13，必須另立相容性工作，驗證 SwiftUI API、Python Runtime、MLX wheels、ffmpeg、OpenCC 與完整轉錄流程。

**理由**

目前 `mlx-audio-swift` 的公開要求是 macOS 14+、Xcode 15+；即使 Phase 0 先採 Python helper，把 P0 鎖在 macOS 14 可以降低兩套 backend 與最低系統矩陣的組合風險。原規格第 0.1 與 Runtime manifest 的 13.0 應視為已被本決策取代。

**實作注意**

文件做出決策不代表現有 package manifest 已完成更新；build 前必須檢查所有 deployment target。

### PD-004：Apple Silicon backend

**決策**

- Phase 0 使用本機 `mlx-audio 0.4.6` 的 Python helper。
- Apple Silicon prompt adapter 使用 `system_prompt`。
- helper 必須具備 capability event；不能依賴捕捉 `TypeError` 後默默拿掉 prompt。
- Release 最終採 Python Runtime 或 native Swift，等 Phase 0 完成後依下列證據決定：
  - prompt 支援；
  - 長音檔穩定性；
  - Runtime 大小；
  - 簽署與 Hardened Runtime 複雜度；
  - macOS 最低版本；
  - 可重現 build 與更新成本。

**不代表**

本決策不表示把 `~/mlx-audio-env` 當成正式發佈方案。它只允許 Developer Mode 驗證。

### PD-005：Intel 阻塞與產品標示

**決策**

- Intel UI 與 backend resolver 可以先實作。
- Intel 預設模型仍為 Qwen3-ASR 0.6B CPU，狀態固定為 `Experimental`。
- 在完成 x86_64 Runtime 與 Intel 實機轉錄前，Intel 功能狀態是 **Blocked**，不是「已支援但較慢」。
- Apple Silicon Stable 不應被 Intel 實機缺席永久阻擋；但 Universal DMG 若在 Intel 上可啟動卻不能轉錄，UI 必須在加入工作前明確說明。

**Intel 升級條件**

至少在一台 Intel Mac 完成：

- Runtime 安裝與 Gatekeeper；
- 0.6B float32 模型載入；
- 1 分鐘與 30 分鐘音檔；
- 峰值 RAM、real-time factor 與熱穩定性；
- prompt `context`；
- 取消、失敗與重新啟動。

完成前不得宣稱 Intel 推論已驗證，也不得用 Apple Silicon 上的 Rosetta 結果代替 Intel 實機。

### PD-006：Runtime 信任鏈

**決策**

正式 Runtime 必須符合以下信任鏈：

1. App bundle 內建允許的 Runtime manifest signing public key 或等價的離線 trust anchor。
2. App 內建允許的 Apple Team Identifier；不得直接信任遠端 manifest 的 `teamIdentifier` 欄位。
3. Manifest 本身有可驗證簽章，並包含：
   - runtime version；
   - architecture；
   - minimum macOS；
   - download URL；
   - archive SHA-256；
   - 解壓後檔案清單與 digest；
   - 相容 App 版本範圍；
   - 所有 component 的精確版本。
4. Archive 只透過 HTTPS 下載，先寫入 staging。
5. 驗證 archive hash、manifest signature、Mach-O code signature、Team ID 與 nested dylib／Python extension。
6. 驗證完成後才原子切換 `current` runtime；失敗保留上一版。
7. 不得以移除 quarantine、關閉 Gatekeeper 或接受任意 URL 作為修正方式。

**尚未解決**

- Runtime archive 的實際 hosting。
- arm64 與 x86_64 可重現 build pipeline。
- Python native extensions 的簽署與 library validation entitlements。
- notarization 的封裝單位。

因此目前只能完成 schema、驗證器、mock artifact 與 dry-run；正式 Runtime 仍需外部 artifact 與 Developer ID。

### PD-007：設定的唯一 source of truth

**決策**

`~/Library/Application Support/record-to-text/settings.json` 是所有持久化 AppSettings 的唯一 canonical store。

包含：

- default output directory；
- output location mode；
- last input/output directory；
- selected glossary；
- temporary terms；
- architecture-specific model selection；
- auto start；
- notification / Finder / open text；
- keep raw transcript；
- overwrite policy；
- queue concurrency；
- recent job limit。

規則：

- JSON 必須有 `schemaVersion`。
- 以 Codable 讀寫並採同資料夾原子 rename。
- UserDefaults 只允許保存不影響工作可重現性的 UI 狀態或一次性 migration marker。
- 同一設定不得同時在 UserDefaults 與 `settings.json` 各存一份。
- 未來導入 security-scoped bookmark 時，仍由 `settings.json` 保存 bookmark payload 與 schema migration。

**理由**

原規格同時提到 UserDefaults 與 `settings.json`，會形成雙重 source of truth。現有 Application Support 資料模型已預留 `settings.json`，因此採 JSON 作為 canonical store。

### PD-008：Temp-Recovery

**決策**

- 工作中 WAV 位於系統 temp 的 job-specific directory。
- 成功：正式 TXT 完成原子寫入後刪除工作 temp。
- 失敗：若 WAV 已完成，移至：

```text
~/Library/Application Support/record-to-text/Temp-Recovery/<jobID>/normalized.wav
```

- 取消：預設刪除 temp，不保存 WAV。
- App 啟動時掃描 `Temp-Recovery`，顯示可復原項目，但不自動重跑。
- 使用者可在 Finder 顯示或明確刪除。
- recovery metadata 不保存逐字稿正文、完整詞庫或音訊以外的內容副本。

**理由**

系統 temporary directory 不能提供重開 App 後的可靠復原；直接把失敗 WAV 永久留在 temp 也沒有清理生命週期。

### PD-009：Heartbeat 與 liveness

**決策**

- JSONL 新增 `heartbeat` event。
- `stage`、`progress`、`log`、`warning`、`capabilities`、`heartbeat`、`completed`、`error` 任一合法 event 都刷新 `lastActivityAt`。
- 沒有自然進度時，helper 每 10 秒發 heartbeat。
- 30 秒無任何合法 event 時標記 `unresponsive` 並提示使用者；不自動把長 ASR 判定為失敗。
- helper 退出碼、`completed` event 與輸出檔存在三者一致才算 ASR helper 成功。
- 取消採 `SIGINT -> SIGTERM -> SIGKILL`，等待秒數必須由常數管理並可測試。

**UI mapping**

| Event | UI |
| --- | --- |
| `stage` | 更新工作階段 |
| `progress` | 只有 total 可信時顯示百分比 |
| `log` | 寫入展開式日誌 |
| `warning` | 顯示不中止警告 |
| `capabilities` | 內部能力判斷，不當作進度 |
| `heartbeat` | 不顯示，只更新 liveness |
| `error` | 工作失敗 |
| `completed` | 等待 coordinator 驗證輸出後再進下一階段 |

### PD-010：模型完整性

**決策**

Release 不得只白名單 `mlx-community/Qwen3-ASR-1.7B-8bit` 這個可變 repo ID。Model manifest 必須固定：

- Hugging Face repository；
- commit revision；
- 必要檔案清單；
- 每個檔案的預期大小與 digest；
- 模型授權資訊；
- 相容 backend 與 Runtime 版本。

下載中斷或 digest 不符時，staging 不得被標示為已安裝。Phase 0 可使用本機 cache，但實測報告必須記錄實際 revision。

### PD-011：長音檔承諾

**決策**

- Phase 0 的最低長工作驗收是 30 分鐘。
- 每個 chunk 必須有獨立且足夠的 token budget，不能讓整份長錄音共享一個會靜默耗盡的總 budget。
- 若生成達 token limit，helper 必須回報可讀錯誤或警告，不得把截斷文字當成功。
- 在 60／120 分鐘 soak test 完成前，產品文件不得宣稱已正式支援任意長度會議。

這是暫定決策；正式最大時長要依實測速度、記憶體與 token 使用量決定。

### PD-012：公開名稱

**決策**

- 開發期間 repository 與 bundle 工作名使用 `record-to-text`。
- UI 可暫用中性名稱「會議轉錄器」。
- 公開發佈前完成 Qwen 商標／品牌檢視。
- About 與授權頁清楚說明 Qwen3-ASR 是第三方模型，不暗示本 App 由 Qwen／Alibaba 官方發行或背書。

### PD-013：長錄音必須先切段

**已觀察事實**

2026-07-30 直接以指令處理長錄音時，曾產生只有前段、缺少後段的輸出。目前尚未確認唯一根因，不能把推測寫成已證實原因。

**決策**

- 超過 30 分鐘的來源音檔，在送入 ASR 前由 coordinator 切成每段最長 30 分鐘的編號 WAV。
- 每段使用獨立 ASR 呼叫與獨立 token budget。
- 預期片段全部成功、非空白、UTF-8、順序完整後，才可合併並提交正式 TXT。
- 任一片段失敗、缺漏、達 token limit 或未 completed，整筆工作失敗；不得把前段輸出當成完整結果。
- 驗收音檔尾端必須放置唯一驗證句，證明最後一段確實存在。

**目前狀態**

Coordinator-level 30 分鐘預切、分段 manifest 與完整性 gate 已完成。31／65／120 分鐘的 deterministic planner fixture，以及縮時 ffmpeg／OpenCC／mock ASR E2E 已驗證順序合併、尾段唯一驗證句與「中段／尾段失敗、空白、token limit、未 completed 時不提交正式 TXT」。

尚未完成的證據邊界是真實 Metal 模型搭配 31／65／120 分鐘實際音檔的 soak test；在此之前不得把本決策的程式完成誤寫成正式支援任意長度。

## 4. Phase 0 決策閘門

Phase 0 完成時必須回答：

1. 目前 MLX-Audio 版本是否確實套用 `system_prompt`？
2. 1 分鐘與 30 分鐘中文音檔是否無截斷完成？
3. 1.7B 8-bit 的載入時間、峰值 RAM 與 real-time factor 為何？
4. Developer Mode 的取消與 heartbeat 是否可靠？
5. Python Runtime 能否在 Hardened Runtime 下形成可簽署、可公證、可更新的 artifact？
6. native Swift route 的 prompt、長音檔與最低 macOS 條件是否更有利？
7. Release backend 應選 Python helper、native Swift，或保留兩者分工？

答案與證據寫入 `docs/technical-spike.md`。若證據不足，決策保持 Provisional，不以時程壓力改寫成已確認。

## 5. 明確尚未完成

- 完整 Xcode build/test。
- Apple Silicon 真實 ASR 端到端。
- Universal 2。
- Intel CPU 推論。
- 正式 Runtime artifact。
- Developer ID、notarization 與 DMG。
- 乾淨帳號首次啟動。
- 首次 GitHub Actions 完整 XCTest 執行。
