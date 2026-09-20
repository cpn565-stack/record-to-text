# record-to-text 0.2.1 定案前檢查與收尾規格

交付更新（2026-09-10 晚間）：F-01～F-03 已完成；補跑真實後端與取消續跑後，使用者接受目前驗證範圍並要求直接打包。成品與未完成的人工驗收界線見 [build 5 交付紀錄](finalization-closeout-2026-09-10.md)。以下保留原始檢查規格與當時結論。

日期：2026-09-10（Asia/Taipei）  
檢查基準：`codex/record-to-text-reliability-v2`／`81c5ceb006e6bad68ca6921a2e813c5788d3dd76`  
起始工作區：乾淨。這輪只檢查、重現與寫規格，未修改正式程式、安裝 App、呼叫真實轉錄 API 或發布版本。

## 1. 定案結論與範圍

**建議再做一輪有限收尾：修正 F-01～F-03，完成 F-04 驗收後凍結功能。**

目前不建議直接宣告「完全定案」：五個最小案例已重現三類問題，涉及逐字稿講者歸屬、啟動工作可靠性及缺口警示的持續保留。這些是會影響使用者判斷的問題，不是美化或偏好調整。

本規格的定案對象是「目前這台 Apple Silicon Mac、現有 Runtime 與設定下的自用版本」。這是依現有開發與安裝方式採用的收尾範圍；若要交付一般使用者，Developer ID、公證、乾淨機安裝屬另一個發布里程碑。

檢查範圍包括最近三次提交、啟動與工作佇列、持久化、輸出發布與復原、講者處理、現有自動化及安裝包簽章。沒有逐行審計整個專案，沒有做本輪真實音訊品質評測或長時間 GUI 操作。

## 2. 本輪證據

| 檢查 | 結果與邊界 |
| --- | --- |
| 工具鏈 | Xcode 26.6，Build 17F113 |
| 現有自動化 | `SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 ./scripts/run-checks.sh` 成功；250 項 XCTest、25 項 Python tests、72 項 executable self-tests、10 種 pipeline 情境通過；包含 Swift App build，刻意略過 App bundle 重新打包 |
| 新增診斷案例 | 5 項、5 個預期行為 assertion 失敗，分別重現 F-01 三例、F-02 一例、F-03 一例；不是編譯或測試環境故障 |
| 安裝版 | `/Applications/record-to-text.app`，0.2.1（1）；本輪 `codesign --verify --deep --strict` 通過 |
| 安裝版執行檔 SHA-256 | `861ab015a122014f76a97a0753e53fcd1a975ef928fe76fa66c5ee188547a3bb` |
| dist 執行檔 SHA-256 | `b1eff6c415cba62fa5c3beef6f59cbc3fc5c63c4f30bd4017d25e4d0ee38b730`；與安裝版不同，不能視為同一份成品；差異本身不等於功能回歸 |
| 真實供應端／長音／GUI | 本輪未跑；過往成功紀錄不代替最後版本的驗收 |

完整本機紀錄：`/tmp/record-final-review-20260910.log`、`/tmp/record-final-probes-20260910.log`。`/tmp` 可能清除，關鍵摘錄另存於 [本輪驗證摘錄](validation/finalization-evidence-2026-09-10.md)。

五個重現案例最初保留在 docs 下；實作時已移入 [FinalizationReviewProbeTests.swift](../Tests/RecordToTextCoreTests/FinalizationReviewProbeTests.swift)，並延伸正式流程驗證。

## 3. F-01：講者處理不得自行製造姓名或錯併人物（P1，必修）

### 已確認問題

程式在 Gemini 回傳文字後，還會自行推斷姓名、改寫行首並將結果帶往後續片段。下列輸入不需呼叫任何模型即可重現：

| 輸入／情境 | 目前實際結果 | 需求 |
| --- | --- | --- |
| `講者 1：我是負責這個專案的窗口。` | 行首改為 `負責這：` | 保留 `講者 1`，不得把普通述語當姓名 |
| 已有王小明、陳小明，後段只有 `小明：` | 選第一筆王小明並改名 | 有歧義就保留原標籤，不依陣列順序決定人物 |
| 第 1 段 `講者 1：我叫王小明。`；第 2 段 `講者 1：我叫陳大文。` | 第 2 段仍被改成王小明 | 泛稱重用不代表同一人，不得蓋掉新片段的矛盾證據 |

程式定位：`Sources/RecordToTextCore/SpeakerRoster.swift` 的 `observe`、`matchingIdentityIndex`、`selfIntroducedName`；`TranscriptionEngine.swift` 的片段及最終 `normalizingSpeakerLabels` 呼叫。

### 修改規格

1. 最小安全方案：停止從逐字稿正文自動擷取並覆寫姓名，移除「我是／我叫後面的文字超過四字就取前三字」規則。現有正式姓名標籤可保留；不新增姓名設定畫面或第二次 LLM 判人流程。
2. 自動改名只允許已有明確依據、且唯一對應的映射。未具備此種依據時保留模型原始標籤。詞庫中唯一同姓、稱謂相似或編輯距離為 1，都不能單獨充當人物同一性的證明。
3. `講者 1`、`主持人` 等泛稱以當前音訊片段為範圍，不得自動變成跨段永久別名。回復 checkpoint 也須遵守相同規則。
4. roster prompt 應表達「前段出現過的標籤，僅供參考」，不得把 heuristic 結果一概稱為「已確認」或要求無條件鎖定。遇到矛盾，保留不確定性。
5. 合併最後稿時不得再用最終 roster 回頭改寫先前所有片段，把後段學到的歧義映射套回前段。
6. 不承諾跨段聲紋識別。講者辨識本身仍可能有模型誤差，本項只消除 App 額外製造的錯誤。

### 驗收條件

- 上述三個案例通過；調換王小明／陳小明出現順序也不得影響結果。
- 「我是負責…」「我是覺得…」不產生新姓名；明確姓名行首不變，正文逐字保留。
- 舊有測試若要求單靠同音或同姓就改成完整姓名，須依本規格修正契約，不可為保住舊 assertion 繼續錯併。
- 經 `TranscriptionEngine` 雲端分段、合併及 checkpoint 續跑各驗證一次；不能只測 roster 單一函式。

## 4. F-02：啟動保存條件未就緒時，不得把本機工作判失敗（P1，必修）

### 已確認問題

Keychain 載入尚未返回時，Qwen 可進入 `runJob`，但 `persistJobs` 因 `isGoogleAIStudioCredentialLoading` 而延後；緊接著 `flushJobPersistence` 拋出 Cocoa 512「無法儲存檔案」，工作成為 failed。診斷用受控 credential store 暫停回傳，已在真實 AppViewModel 佇列入口重現；尚未啟動 Runtime 或 provider。

程式定位：`Sources/RecordToTextApp/AppViewModel.swift` 的 `scheduleQueueIfNeeded`、`drainQueue`、`runJob`、`persistJobs`、`flushJobPersistence`。前兩者目前只攔 AI Studio，後兩者則限制所有後端。

### 修改規格

1. 統一「可以持久化後才開始執行」的條件；等候中的工作維持 queued，不填入 startedAt，不記為失敗。
2. 最小修正可讓所有後端在啟動保存條件未就緒時先排隊；畫面顯示「正在載入啟動資料，完成後會開始」，仍可加入、移除工作及取消開始意圖。
3. 使用者已按開始時，初始化成功或失敗返回後，重新評估可執行條件。一般無舊金鑰遷移的 Qwen／Vertex 工作不應因 AI Studio Keychain 讀取錯誤而永久停住。
4. 保留既有安全契約：不得先跑工作再補存身分，不得跳過舊明文金鑰的安全遷移；有遷移阻礙時明確說明原因並保留來源資料。
5. 真正 journal 損壞、磁碟寫入失敗仍須顯示錯誤；不能把所有儲存例外都轉成安靜等待。

### 驗收條件

- 受控暫停 Keychain 時，Qwen、Vertex、AI Studio 均不因初始化延後而變 failed；來源不啟動任何外部呼叫。
- 分別釋放為成功、無金鑰、讀取失敗；Qwen／Vertex 在保存就緒後能進入後續流程，AI Studio 按自己的認證條件處理。
- 等待期間移除工作、取消開始、退出 App，再釋放初始化，不得幽靈啟動。
- 舊金鑰遷移及 journal 真實失敗測試繼續通過。

## 5. F-03：稿件缺口狀態必須跨重開保留（P1，必修）

### 已確認問題

`RecentJobSummary` 沒有稿件完整性或缺口欄位。completed 工作被 `JobRetentionPolicy.ledgerJobs` 排除後，只留下顯示「完成」的 recent summary；原本 `failure` 中的缺口警示不會帶過去。診斷以 completed + 缺口警示經正式 canonicalization 與 JSON 往返重現。

此外，本機 `acceptCompletedResult` 只在 log 提到 token 缺口，未將 `containsSkippedAudio` 轉成持久化缺口屬性。原 TXT 的缺口標記仍在，這不是已確認的文字遺失；問題是 App 的完成狀態使人可能誤認稿件完整。

程式定位：`Models.swift` 的 `RecentJobSummary`、`PipelineResult`；`AppViewModel.swift` 的 `acceptCompletedResult`；`JobRetentionPolicy.swift`；`OutputPublicationStore.swift`；`MainView.swift`。

### 修改規格

1. 將輸出完整性存成結構化狀態，例如 `complete / hasGaps / unknown`，並帶入工作、recent summary 及發布回復流程；顯示文案不得依賴會裁切的 log。
2. Qwen token 缺口與 Google safety 缺口均產生 `hasGaps`；UI 顯示「完成（含缺口）」及原因。可用的復原位置與片段資訊一併保存。
3. completed 但仍有有效未完成片段 checkpoint 的工作，須保留可續跑的必要資料。重開後「重送未完成片段」仍可使用，不得因 recent history 上限把唯一續跑資料裁掉。
4. 原來源、既有正式 TXT 與 recovery 資料不得因 metadata 遷移被覆寫或刪除。明確刪除工作仍遵守使用者選擇，不得由舊 receipt 復活工作。
5. 舊 JSON 缺少新欄位須能讀取。沒有證據的歷史紀錄用 `unknown`，不得遷移成「已驗證完整」；不要求批量掃描或重跑歷史音檔。

### 驗收條件

- 普通成功、Qwen token 缺口、Google safety 缺口三種工作，經 journal 存檔、App 重建與 recent 顯示後狀態一致。
- 含缺口與不含缺口的 publication crash-recovery 都保留正確完整性。
- 有有效 checkpoint 的缺口工作在 recent limit = 0 時仍可找回；沒有可用 checkpoint 則不提供無效續跑按鈕。
- 原檔雜湊不變；刪除工作不復活；舊 schema 可讀。

## 6. F-04：最後一次固定驗收與成品對齊（必要驗收，不預設新增修正）

先完成 F-01～F-03，再只做以下一輪。任一項失敗，修正該失敗及受影響測試；不因此重啟全盤優化。

| 驗收 | 固定條件／通過標準 |
| --- | --- |
| 自動化 | 完整 Xcode 的 `REQUIRE_XCTEST=1 ./scripts/run-checks.sh` 全部成功；本輪五例及各項整合案例進正式套件 |
| 最後版本長錄音 | 主用雲端後端跑一份至少 45 分鐘、跨 20／40 分鐘邊界的多人錄音；來源範圍覆蓋完整或明示缺口，不以文字非空充當品質通過 |
| 文字抽查 | 人工對照開頭／結尾各 30 秒、每個切段邊界前後各 30 秒、至少 5 個講者輪替；記錄缺句、重句及錯併。聲音身分仍無法判定者標明不確定 |
| 另兩後端 | 各一份 2～5 分鐘 smoke；Qwen 使用安裝版並於執行後驗 codesign。模型的既有短檔通過不能替代長錄音覆蓋 |
| 取消／續跑 | 一次已有完成片段的取消、重開及續跑；完成片段不重送，剩餘片段不遺失，輸出不覆寫 |
| GUI hang | 上述轉錄期間做至少 15 分鐘操作：工作列表捲動、轉錄設定展開收合、復原畫面開關、複製除錯資訊；無 beachball／hang，互動無可觀察到的超過 2 秒停頓。這是限定情境驗收，不是永久無卡頓保證 |
| 成品對齊 | 以一個最終 commit 建置，使用比既有交付更高且不重複的 build number；保存 commit、版號、build、App 執行檔與 DMG SHA-256；DMG 掛載內與安裝版執行檔一致，安裝後及 Qwen 執行後簽章通過 |

既有 `docs/ui-polish-2026-09-09.md` 只主張降低 hang 風險，且明列未做長時間壓力測試，因此本項不能直接勾選已完成。安裝版和 dist 本輪雜湊不同，也不能拿其中一份測試結果代表所有成品。

不要求刻意操控真實供應端產生 MAX_TOKENS／STOP 空回應，這些分支以既有及新增可控制的測試驗證；真實服務不一定能重現特定回應。付費轉錄與使用者錄音應在實作／驗收任務的授權範圍執行，本輪未做。

## 7. 明確延後與停止條件

本輪不做 UI 重設計、一般效能重構、新模型、自動更新、Runtime installer、Intel／Universal 2、聲紋辨識、公開發行公證。舊 `HANDOFF.md`／`NEXT_STEPS.md` 的歷史待辦不是本輪必改清單。

F-01～F-03 完成、F-04 通過並留下具體版本與驗證紀錄後，即可定為這個自用版本的收尾點。之後只受理能重現的資料損失、錯誤歸屬、工作失敗或交付阻礙；其他想法進下一版本，不阻擋此版結案。

本規格沒有證據支持「零風險」或「所有音檔都沒問題」，也不以既有 250 項全綠掩蓋本輪新增案例所揭露的缺口。
