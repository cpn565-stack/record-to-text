# 第 3、5 項安全暫停交班單

日期：2026-09-08，Asia/Taipei；最後針對性測試結束 23:31:25。
原因：使用者要求在用量耗盡前安全暫停。這是開發 checkpoint，**不是完成驗收或可發布交付**。

## 1. 接手位置與安全邊界

- 工作區：`/Users/mike/Projects/AI工作區域/record-to-text`
- 分支：`codex/record-to-text-reliability-v2`
- HEAD：`a889969be46f4acf909c64792fcc2406cf7fff35`
- 所有變更仍在工作區；本輪未 commit、push，也沒有安裝到 `/Applications/record-to-text.app`。
- `run-checks.sh` 曾重建 `dist/record-to-text.app`，但它是中途版本，**不包含之後所有修正**；不要拿它當目前 source 的交付包。
- 暫停時沒有本輪測試／build 程序仍在執行，最後 `git diff --check` 通過。
- 原始錄音、既有正式稿、正式 App 資料未拿來測試或修改。測試使用臨時 fixture 與 mock HTTP；沒有呼叫真實 Google API。
- 保留 Grok 第 4 項未提交改動；不要 reset、checkout 還原或覆寫整份引擎。
- 沒有使用子 agent。使用者這次要求寫工作區交班單；沒有另寫共享記憶庫。

先讀：

1. `docs/stability-performance-3-5-spec-2026-09-08.md`（正式需求，尚未逐條完成）。
2. `docs/stability-4-delivery-2026-09-08.md`（Grok 的第 4 項自述）。
3. 本文件、目前 diff、下列驗證紀錄。

## 2. Grok 第 4 項複核

原工作區與交班的檔案範圍一致，既有 cache／silence／adaptive 測試已包含在中途全套通過結果中；ffmpeg 非零起點 fixture 也在其中。

接第 3 項時補了：

- `JobSilenceAnalysisCache.swift` 的分析與 coordinator 路徑傳遞 `CloudSegmentDeadlineExceeded`，不把到期當成普通失敗退回中點。
- detector 返回後再次檢查取消／budget，避免晚到結果寫入 cache。
- 原交班說「工作結束有 summary」，但原碼僅部分成功路徑且 metrics 非零時輸出；改為 cache 建立後的 cloud run scope 用 defer 彙總，包含失敗／取消。

沒有量測真實錄音的 baseline／新版各三次，不可宣稱實際整體轉錄加速比例。

## 3. 第 3 項已實作

- 新增 `Sources/RecordToTextCore/CloudSegmentBudget.swift`：ContinuousClock、可注入 now／sleeper、預設 900 秒、root UUID、remaining／elapsed／stage、可辨識的到期錯誤。
- 使用單次 completion gate 與可取消的非結構化 worker／timer；不等待不合作 worker 才向呼叫端回報截止。外部 await 的晚到值無法回到 engine 提交路徑。
- `CloudBudgetContext` 使用 TaskLocal 沿同一 root 傳遞 context，不在 backend 共用可變 budget。
- `TranscriptionEngine.runCloudPipeline` 在每個根片段截取前建立 budget；所有 adaptive children 沿用 root UUID／同一物件；extract、probe、transcribe、split、commit 有檢查。
- `budget.commit` 用鎖讓同步片段 manifest 提交與到期檢查共用 gate；完成子段保留，其他未完成子段停止。
- `AudioSegmentRecord` 增加可選 rootSegmentID／deadlineReason；CloudResumeCheckpoint 與 recovery 複製保存 rootID、splitDepth。手動續跑重新建立 budget，不持久化 Instant。
- AI Studio／Vertex 的 request helper 接同一 budget，request timeout 取剩餘時間與原上限較小值；backoff 過長直接到期，不違反 Retry-After 提早重送。retry log 印 root、attempt、model、elapsed、remaining。
- Files API polling 改 ContinuousClock；poll 與 generation 分別保留正確到期 stage。
- 修掉實測發現的錯誤：Files API 到期原本被 prepareAudioPart 的通用 catch 吞掉，轉 inline 路徑；現在直接拋出到期。
- Vertex auth await 也接 budget，避免包成 authenticationFailed 後失去取消／到期語義。
- ProcessRunner 在啟動前檢查 context，timeout 取 min；deadline worker 取消沿既有 process termination 路徑送達。
- cloud context 內的遠端清理用独立最多 5 秒 allowance，在背景進行，不延遲錯誤顯示；直接 backend 無 context 的既有測試呼叫仍保留等待清理行為。
- 狀態 task 用時鐘差值算 elapsed；可顯示等待重試。

已驗證的重要行為：左子段完成、右子段 generation 到期後，recovery 保存左段、rootID、右段到期原因，沒有完整正式稿，晚到回應不修改 recovery；mock 網路失敗／503 不再越過 budget 重試；polling 不接著 generation。

## 4. 第 5 項已實作

- 新增 `Sources/RecordToTextCore/JobPersistenceCoordinator.swift`，包含 value snapshot、actor coordinator、durable receipt API、serial I/O queue 與 journal store。
- 至多一個 writing 與最新 pending；coalescible 250ms debounce、最長 1 秒；critical 立即開始；revision 過舊忽略，flush 等目標或更高 revision。
- writer 失敗保留最新待存，1／2／4 秒有限重試；可明確重試，沒有轉錄重送行為。
- canonical snapshot 在背景執行 retention、編碼、排序、裁切；保留完整 recent summaries，不只從裁過的 ledger 重建。
- 原子 journal → ledger → recent，保留 current 與 previous journal；兩個相容輸出有 revision，舊版缺 revision 解為 0。
- startup 以 journal 的完整 snapshot 為準；App 初始化只讀 journal，不同步重寫輸出，後续背景 writer 修復。journal 無法解碼時阻止覆寫，保留錯誤與原檔。
- JSONRepositories 不再跨執行緒共享全域可變 ISO formatter；repository encoder 捕捉自己建立的 formatter。
- AppViewModel.persistJobs 改 submit value snapshot；stage 非終止更新 coalescible，加入／移除／重試與 terminal 等原本呼叫預設 critical。
- MainView 顯示持續的「工作紀錄尚未儲存」與重試按鈕。
- applicationShouldTerminate 使用 terminateLater／async flush，失敗或超過 5 秒時提供重試儲存／取消退出／仍然退出，沒有主執行緒 semaphore。
- credential loading／legacy migration 尚未完成的保存會 deferred；flush 不得把 deferred 誤報成功。
- 舊憑證 migration、清除 API Key／reset 改可等待的操作，先等 ledger durable 才刪 Keychain。SettingsView 及 migration tests 已更新 async 呼叫；曾抓到遷移回歸，修後 13 項 migration tests 通過。
- TranscriptionEngine.run 新增 optional `persistCompletion` callback：正式稿產出後、清除工作暫存前交给 AppViewModel 記錄完整 result 並 flush。失敗／逾時保留工作暫存；不將已成功轉錄改成失敗再送 API。非 App 呼叫可不提供 callback，維持原行為。
- AtomicFileWriter／JSONRepository 有 optional checkpoint hook，供 journal crash fixture 使用。
- `Tools/SelfTest/main.swift --persistence-crash-fixture DIRECTORY STAGE` 是新測試入口；只用專用臨時 fixture 目錄，會 `_exit(73)` 模擬程序直接終止，不跑 defer。

## 5. 驗證紀錄與其邊界

環境：macOS／arm64，Xcode 26.6（17F113），SwiftPM，Swift language mode 5。

### 中途完整檢查：通過，但不是最後工作樹的完整驗收

命令：`./scripts/run-checks.sh`

保存：`docs/validation/stability-3-5-full-checks-intermediate-2026-09-08.txt`

- 228 XCTest／0 failures。
- Swift self-test 72 passed。
- mock pipeline 10 情境通過。
- Python 測試與 App build 通過；末尾顯示全部驗證通過。
- 之後又加入 deferred-flush 防線、5 秒 process 測試、真實 `_exit` crash harness 及 AtomicFileWriter checkpoint hook。**接手後仍需重跑全套**。

### 最後工作樹針對性檢查：11 tests／0 failures

命令：`swift test --filter 'JobPersistenceCoordinatorTests|CloudSegmentBudgetTests'`

保存：`docs/validation/stability-3-5-targeted-checkpoint-2026-09-08.txt`

- Budget 5 項，包含 fake monotonic clock、取消區別、晚到非合作結果、Retry-After、實際 5 秒 budget 的本機 sleep 程序取消。該 process test 約 5.105 秒結束，低於「到期後 5 秒停止」目標。
- Persistence 6 項，包含 slow writer＋MainActor heartbeat、100 次更新合併、新舊 revision、ENOSPC 注入可重試、journal 修復、fixture benchmark。
- crash matrix 用獨立 self-test 程序 `_exit(73)`，覆蓋 beforeJournal、journal temporaryCreated、journal beforeRename、afterJournal、afterLedger、afterRecent；重啟只讀到前／新完整 revision，不復活已刪工作。
- 此矩陣沒有覆蓋「完成正式稿已產出但 completed journal 還未提交」的程序中止，見下節最高優先缺口。

### Fixture 效能（各三次，最後測試 log）

| 工作數 | 每筆輸入 log | submit 最大值 | durable 中位數 |
| --- | --- | --- | --- |
| 10 | 400 | 0.0151 ms | 4.48 ms |
| 100 | 400 | 0.0124 ms | 19.73 ms |
| 1000 | 400 | 0.0131 ms | 152.72 ms |

注意：submit 測的是 value snapshot 到 coordinator 的邊界，**不是整段 AppViewModel.persistJobs 主執行緒 p95**。writer 沿既有 retention 將保存 log 裁為最多 100 行。未量測峰值 RSS／完整 UI submit p95，不能把這張表當作原規格所有效能目標已驗收。

修改前測試證據：最初 Budget 新 API 測試因 API 尚未存在而編譯失敗；另實際測到 migration 6 assertions 失敗、poll deadline stage 被 inline fallback 改成 generation，皆已修復。Persistence 最初 API 測試加入時前一輪 build 尚在進行，沒有保存一份獨立且完整的紅燈 log；不要宣稱每個新增測試都有完整 red-green 證據。

## 6. 接手最高優先工作：還不能宣稱全完成

1. **完成輸出與 journal 的 crash 邊界仍需設計及補測。** 目前 callback 保證「durable 前不清暫存」，但若正式稿已寫出、completed journal 尚未提交就程序中止，舊 ledger 可能只有 transcribing；重新啟動是否能找回正式稿位置尚未證明。下一步原打算研究 completion receipt／啟動復原機制，**尚未新增此型別或任何程式碼**。不要只把完整 TXT 存在磁碟視為完成狀態可復原。
   - 必須測 completed callback 前／journal 前／journal 後／cleanup 邊界。
   - 若採額外 recovery receipt，需同時避免已刪工作的舊 receipt 在下次啟動復活；不可盲目掃描所有 receipt 就加入 jobs。
   - 目前保存失敗會保留工作暫存；日後 writer 成功後如何安全回收這些保留目錄也尚未收尾。
2. 以原規格第 3、5 項逐條對照，再做一次細緻 review。特別檢查：
   - budget 到期與成功／取消 gate 的競態、同步 commit 可能被慢磁碟阻塞的邊界。
   - budgeted URLSession 現在使用 async upload/data 的取消傳遞；規格要求明確 URLSessionTask／Process handle，需評估是否要把 URLSession handle 管理顯式化，而不是只引用框架取消語義。
   - Vertex upload／auth／fallback、AI Studio upload 的各 stage 到期故障測試尚不足；目前有 AI Studio retry／poll／實際 engine generation 與 process 測試。
   - cancel requested／cancel completed 的完整日誌契約尚未逐條驗收，不可說全部規格日志都已完整。
   - receipt／flush cancellation 與重試耗盡、退出逾時後取消退出仍可操作；尚無 GUI 驗證。
   - pending snapshot 在 MainActor 排程至 actor 的短暫 Task 排隊、recent summaries 更新成本與實際 App submit p95。
   - 既有 `pruneHistoryIfNeeded` 等 UI 層仍有排序；主线程負荷是否符合規格需量測。
   - 同一時間多個 credential 操作跨 await 的重入防護，避免 async 化後引入競態。
3. formatter 並行壓力、1000 jobs UI benchmark／RSS、真實權限拒絕或暫時不可用磁碟等額外驗收尚未完成（已有注入 ENOSPC 與慢 writer）。
4. 最後完整 checks、GUI／退出選項檢查、更新正式交付紀錄與 source 對應 build。真實 Google API 仍需使用者指定測試錄音，這輪沒有授權選任何既有私人錄音來跑。
5. 不安裝、不發布中途 dist。完成後再依使用者指示處理 commit／push／正式 App 安裝。

## 7. 建議接手指令

```bash
cd '/Users/mike/Projects/AI工作區域/record-to-text'
git status --short
git branch --show-current
git rev-parse HEAD
xcodebuild -version
git diff --check
swift test --filter 'CloudSegmentBudgetTests|JobPersistenceCoordinatorTests|CloudAdaptiveSegmentationTests|AppCredentialMigrationTests'
```

注意 crash matrix 需要本次版本的 `.build/debug/record-to-text-self-test`。如果測試執行器沒有建該 product，先 `swift build --product record-to-text-self-test`。

完成缺口與針對性測試後：

```bash
./scripts/run-checks.sh
git diff --check
```

目前原始 `/tmp` log 也還在，但正式證據已另存 `docs/validation/`，不用依賴臨時檔。本文件與 log 是本輪暫停交班，沒有修改 Grok 的既有交付紀錄。
