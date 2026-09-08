# record-to-text 穩定性與效能改善：第 3～5 項詳細規格

日期：2026-09-08
狀態：設計規格，尚未實作第 3～5 項。
適用：macOS record-to-text 0.2.0；目前分支 codex/record-to-text-reliability-v2。
基準 HEAD：88f9f69904f6991924f43d15638a754a50ea4ca2，另包含工作區的 MAX_TOKENS 與第 1、2 項修正。
範圍：只處理穩定性、效能與使用者進度體驗。本文數值是實作預設／驗收目標，不是已量測成果。

## 共同前提

- 第 1 項已改為背景載入 AI Studio 憑證，等待期間保留視窗操作；AI Studio 佇列等待載入完成。
- 第 2 項已讓 AI Studio／Vertex 的轉錄 generation 請求對指定暫時性網路錯誤有限重試。每模型最多 4 次，重用已準備的音訊；網路錯誤耗盡不切換模型。
- 雲端初始片段最多 20 分鐘；MAX_TOKENS 子段至少 60 秒、最多 4 層。
- 正式稿仍只接受完整成功的回應；已完成片段必須可供續跑。改善不得讓部分文字被當成完整稿。
- 不新增多段同時生成、預先上傳下一段、修改 thinking 等級、模型快取重構或本機 Qwen 並行。
- 所有變更先補會失敗的測試，再改 production 路徑。mock、真實 API、GUI、長音訊量測分開記錄。
- 建議順序：第 3 項 → 第 4 項 → 第 5 項；每項可獨立驗收、打包與回退。

# 3. 雲端片段總時間預算

## 3.1 問題與可觀察行為

現況：
- GoogleAIStudioBackend／VertexAIGeminiBackend 分別有 request timeout、重試次數與 fallback。
- 每次重試、模型切換、自適應分段各自建立等待，沒有共用的根片段總時間上限。
- Files API polling 使用 Date；註解稱單調時鐘，但實際不具備單調保證。
- makeCloudStatusTask 每睡 30 秒就加 30，程序排程延遲時可能低估真實經過時間。

期望：
- 使用者能區分「Google 正在處理」「網路重試等待」「本片段已超過等待上限」。
- 同一原始片段即使換模型、切成子段，也不能無限制重新取得完整等待時間。
- 到期保留已完成文字、停止新增請求，提供從未完成位置續跑。

## 3.2 預算定義

| 範圍 | 預設 | 規則 |
|---|---:|---|
| 一個初始根片段 | 900 秒 | 開始截取該根片段前建立；最多 20 分鐘錄音對應一份預算 |
| generation 單次請求 | 上限 300 秒 | 同時不得超過根片段剩餘時間 |
| Files API ready polling | 上限 60 秒 | 同時不得超過根片段剩餘時間 |
| 到期後本機停止目標 | 5 秒 | 停止 retry、poll、子段調度，取消本機請求／處理程序 |
| 到期後遠端檔案清理 | 額外最多 5 秒 | 不能阻塞錯誤呈現；不得重新 generation |
| 狀態更新 | 每 30 秒 | 用 clock 差值計算，不用迴圈累加 |

900 秒包含該根片段的壓縮、上傳、檔案等待、generation、backoff、fallback、切小重試與必要的切點分析。初始全檔靜音分析在根片段開始前，仍用既有程序 timeout；不冒充已受本規格總預算控制。

此值先作內部可注入設定，不新增使用者偏好欄位。使用後的 elapsed、deadline exhausted 比率及成功率決定是否調整。

## 3.3 核心介面與責任

新增 CloudSegmentBudget，包含：
- rootSegmentID：穩定 UUID，所有子段共用。
- startedAtInstant、deadlineInstant：ContinuousClock 的 Instant。
- limit：Duration。
- remaining()、elapsed()、checkRemaining(stage:)。
- withDeadline(operation:)：整個非同步操作的到期控制。
- 測試注入 clock／sleeper，不用真等 900 秒。

TranscriptionEngine：
- 初始片段各建立 budget；從根片段到所有子段傳同一 budget。
- 在 extract、probe、transcribe、split 前檢查；不得在深度增加或 HTTP 重試時重置。
- 已完成子段寫入 manifest 後，budget 到期不得回頭刪掉其文字。
- 復原資料保留 rootSegmentID 與最後到期原因；舊 manifest 無此欄位仍可解碼。
- 使用者明確續跑是新一次執行，建立新 budget，保留舊 splitDepth，日誌說明重新計時。
- 不把單調時間 Instant 寫入磁碟後跨程序重用。

Cloud backend：
- 接收 budget，不自行建立另一份 deadline。
- upload、poll、generation、重試與 fallback 都傳遞相同 context。
- 每個 request timeout 取 min(該 request 原上限, remaining)；remaining <= 0 直接到期。
- Retry-After 超過剩餘預算時直接結束，不提早重送來違反服務端等待指示。
- 明確區分 user cancellation、deadline exhausted、網路失敗，避免到期錯誤被第 2 項再重試。

ProcessRunner：
- 本規格涉及的 ffmpeg／ffprobe timeout 同樣取 min(原上限, remaining)。
- 使用既有取消／終止機制。到期後不得新增子程序。

## 3.4 到期競態與完成邊界

- 不只使用 request.timeoutInterval；必須有根操作的獨立 deadline 控制。
- 不得以必須等待不合作 child task 結束的 task group，假裝達成硬截止。
- 明確保存可取消的 URLSessionTask／Process handle；deadline gate 只能完成一次。
- 到期先贏得 completion gate：禁止晚到回應寫正式稿或推進 manifest。
- generation 結果已通過完整性驗證並提交片段 manifest 才算完成；僅收到 HTTP 200 不算。
- 一旦片段已完成提交，即使下一刻到期也保留其完成狀態；後續未完成子段停止。
- 遠端伺服器可能仍在運算；本機停止不能宣稱遠端已停止或不會計費。

## 3.5 錯誤、日誌與 UI

新增可識別的 CloudSegmentDeadlineExceeded：
rootSegmentID、segmentIndex、splitDepth、elapsedSeconds、limitSeconds、stage。
LocalizedError 示例：
「本片段已等待 15 分鐘，已停止自動重試。已完成的片段已保留，可稍後從未完成處續跑。」

日誌必含：
- budget 建立、模型切換與子段沿用 root ID。
- 每次嘗試的 attempt、reason、elapsed、remaining。
- deadline exhausted、cancel requested、cancel completed。
- 只記錄流程與時間，不把全文放入效能日誌。

UI 不顯示推算的轉錄百分比。顯示「正在處理／等待重試」及實際經過時間。到期後不再顯示「將重試」。

## 3.6 必要測試與驗收

1. fake clock 前進到截止：新 generation／upload／split 次數不再增加。
2. 連續網路重試、HTTP 503、fallback 共用同一 deadline，不能各取得 900 秒。
3. 父段 MAX_TOKENS → 左子段完成 → 右子段到期：左子段可續用，無完整正式稿。
4. 在 backoff／poll／upload／generation／ffmpeg 各階段到期，均得到正確 stage。
5. deadline 與成功／使用者取消同時抵達：只完成一次，不出現完成後又失敗。
6. 模擬不合作的晚到 response：不得寫檔、修改已終止工作、發送額外請求。
7. 修改系統時間不改變剩餘預算；睡眠喚醒後按 ContinuousClock 判斷已用時間。
8. 舊 recovery 可解碼；手動續跑獲得新預算，已完成片段不重送。
9. mock 5 秒小預算驗證：到期後 5 秒內本機停止；遠端清理不延長此呈現上限。
10. 真實 API 只在明確指定測試錄音後執行，記錄請求數、總時間、結果與用量；不能以 mock 宣稱驗證完成。

涉及檔案：TranscriptionEngine.swift、兩個 Gemini backend、GeminiTransportHelper.swift、ProcessRunner.swift（必要時）、AudioSegmentation.swift、CloudResumeCheckpoint.swift、新增 budget 型別與測試。

# 4. 靜音分析快取與切段前置檢查

## 4.1 問題與目標

makeCloudSegmentPlan 已分析整份音訊；adaptiveCloudSplitBoundary 每次 MAX_TOKENS 又呼叫 ffmpeg。
目前先分析、後判斷 splitBoundary 是否允許分段，已達深度／時長限制仍會做無用分析。
adaptiveCloudSplitBoundary 的 try? 也會吞掉 CancellationError。

目標：
- 無法切分時，ffmpeg 靜音分析呼叫數為零。
- 同一份工作已完整分析過的時間範圍，切子段直接重用。
- 快取失敗不影響完整性；正常分析失敗可退回中點，使用者取消必須傳遞。

## 4.2 快取生命週期與資料

新增 JobSilenceAnalysisCache；由單次 TranscriptionEngine.run 擁有，不跨工作、不寫磁碟。
不使用全域 singleton，結束／取消工作時釋放。

Cache identity：
- 標準化 source URL。
- 可取得時的檔案 resource identifier。
- file size 與 content modification date。
- 偵測設定：noise=-35dB、minimumSilence=0.35s。
- 未能確認來源 identity，直接不用快取，不猜測是同一檔案。

Cache entry：
- coveredAbsoluteRange：[start, end)。
- silences：以原始來源音訊絕對秒數儲存的 start/end。
- 成功掃描可有空 silence 清單；空清單代表「已掃描、沒找到」，不是未掃描。
- 失敗與取消不新增 covered range。
- 每工作最多 100,000 個 silence interval；超過則不快取該次結果，保留本次分析結果供當前分段使用。
- 第一版不做部分覆蓋拼接：只有完整涵蓋要求區間才命中，否則掃描整個要求區間。

## 4.3 時間座標規則

- SilenceDetectionService 需明確保證回傳時間是相對本次掃描起點；以測試確認 ffmpeg 輸出語義。
- 寫入 cache：absolute = scanStartSeconds + detectedRelativeSeconds。
- 初始 planner 使用工作切片的相對時間：relative = absolute - sourceSliceStart。
- adaptive planner 使用 record 相對時間：relative = absolute - record.startSeconds。
- record.startSeconds 已是來源的絕對位置，不能再加一次 sourceSlice.startSeconds。
- 截掉超出掃描範圍的 silence interval；非法 NaN、負長度、倒序區間拒絕寫入 cache。
- 邊界選擇必須與未使用快取時一致：選符合子段最短時長、最接近中點的 silence midpoint；無候選則中點。

## 4.4 執行順序

初始分段：
1. 建立根 source identity。
2. silence-aware 設定啟用且需要分段才掃描；成功後存入 cache。
3. 用同一份結果建立初始 plan。

MAX_TOKENS：
1. 檢查取消與第 3 項 budget（已實作時）。
2. 先以空 silences 呼叫 planner 判斷是否有合法切點。
3. 若無合法切點，直接走現有終止錯誤，不啟動 ffmpeg。
4. 關閉 silence-aware 設定時，直接使用合法中點，遵守使用者設定。
5. 啟用時查 cache；完整涵蓋則取得候選，不呼叫程序。
6. 未命中才分析該範圍，成功存入 cache。
7. 正常分析錯誤記一次 warning 並回退中點；CancellationError／budget 到期向上傳遞。
8. 建立子段與 manifest 的方式不變。

## 4.5 日誌與量測

每工作彙總：
silence_scan_count、silence_scanned_audio_seconds、silence_scan_elapsed_ms、
silence_cache_hit_count、silence_skip_ineligible_count、silence_fallback_count。
範圍／次數可記錄；不要以「快取命中」推算整份轉錄快了多少。

效能比較固定同一份音訊與同一份預設 MAX_TOKENS 回應序列：
- baseline 與新版本各跑至少 3 次。
- 報告靜音分析累計耗時、ffmpeg 呼叫數、整體準備耗時中位數。
- 驗收首要是消除重複掃描；整體百分比僅作實測結果，不設無根據的承諾。

## 4.6 必要測試與驗收

1. 已達 depth=4：分析服務 spy 呼叫 0 次。
2. 片段短於 120 秒：分析服務呼叫 0 次。
3. 初始全檔掃描成功，父／子段均在涵蓋範圍：後續分析 0 次，切點與舊算法一致。
4. 全檔掃描成功但結果空：仍命中 cache，不重掃。
5. sourceSlice 從非零開始，連續兩層子段：全部切點位於正確絕對時間，沒有重複偏移。
6. 掃描失敗後可在下次重試掃描；取消後不產生子段。
7. 來源 size／mtime／identifier 改變：cache 失效，不能沿用舊結果。
8. 關閉 silence-aware：初始與 adaptive 都不啟動分析。
9. 掃描範圍不完整涵蓋時不誤命中；大量 silence 超過上限不造成無限記憶體增長。
10. 以 ffmpeg fixture 驗證 scanStart 非零時的時間語義，再跑真實錄音準備階段基準。

涉及檔案：TranscriptionEngine.swift、SilenceAwareSegmentation.swift、新增 JobSilenceAnalysisCache.swift、CloudAdaptiveSegmentationTests.swift 與 silence tests。

# 5. 工作紀錄背景寫入與更新合併

## 5.1 問題與目標

AppViewModel 為 MainActor；persistJobs 在主執行緒整理工作與近期清單，同步寫兩份 JSON。
階段切換會觸發此路徑。大量歷史／較慢磁碟可能拖慢畫面；目前尚未量測實際卡頓比例。

目標：
- UI 狀態更新立即完成，磁碟編碼與 I/O 不占主執行緒。
- 非關鍵更新可合併；完成、失敗、取消、退出不能只存在記憶體。
- 舊 snapshot 絕不能較晚完成後蓋掉新 snapshot。
- 第 1 項載入期間與舊格式遷移處理不能被背景寫入破壞。

## 5.2 元件與資料契約

新增 JobPersistenceCoordinator：
- 接收不可變 PersistenceSnapshot：revision、jobs、recentHistoryLimit、timestamp。
- revision 是同一程序內嚴格遞增的 UInt64，在 MainActor 取得 snapshot 時配置。
- submit(snapshot, urgency)、flush(throughRevision:)、status。
- urgency：coalescible 或 critical。
- critical submit 回傳可 await 的 durable receipt；receipt 包含 revision 與落盤結果。
- actor 管理順序／待辦；實際 JSON 編碼、排序、裁切與檔案寫入使用獨立 serial I/O queue。
- JSONEncoder、JSONDecoder 與 ISO8601DateFormatter 只在同一 writer 隔離範圍使用。現有 JSONRepositories 的全域 formatter 不得直接被多執行緒同時存取。
- 不跨執行緒傳 AppViewModel 或可變 jobs reference；傳 Codable／Sendable value snapshot。

## 5.3 更新合併與佇列上限

| 更新類型 | 行為 |
|---|---|
| 一般非終止 stage、非關鍵 log | debounce 250ms，最多 1 秒內啟動寫入 |
| 加入工作、移除工作、重試／續跑建立 | critical |
| completed、failed、cancelled、interrupted | critical |
| App 退出、明確 flush | barrier，等待指定 revision durable |
| 純進度動畫／每秒 UI 顯示 | 不新增持久化頻率，維持現行選擇 |

- 至多一個正在寫入 snapshot、一個最新 pending snapshot，避免進度事件堆滿記憶體。
- newer snapshot 可取代 pending older snapshot；被取代的 critical waiter 必須在 newer revision 落盤後才完成。
- 正在寫入的舊 revision 不強制中止；完成後立即處理最新 snapshot。
- 某 revision 已 durable，任何較舊提交直接忽略／回報 superseded，不得再寫。
- 非關鍵 debounce 使用單調 clock；新增事件不可讓 max 1 秒等待無限延後。
- 重要狀態可立即顯示，但不得在 durable 前清除其唯一救援資料。

## 5.4 兩份檔案的一致性

檔案：job-ledger.json 為工作主紀錄；recent-jobs.json 為歷史摘要。
歷史摘要可能含 ledger 已裁切掉的舊工作，不可僅用目前 jobs 重建而把歷史全清掉。

新增可向後解碼的 schemaVersion／revision 欄位：
- 缺少欄位視為舊版 revision=0。
- 新 writer 的 canonical snapshot 必須包含本次完整 recent summaries，保留 JobRetentionPolicy 語義。
- 建議以單一 journal snapshot 作提交依據，原兩份檔案作相容輸出。
- 先原子寫 journal，再輸出 ledger／recent；每檔各自原子替換。
- journal durable 才能發 critical receipt；啟動時遇到兩份版本不同，以 journal 修復。
- journal 缺失時按現有 lenient loader 載入，不要求使用者手動搬檔。
- journal 不可長期無上限堆積：保留 current 與一份前版即可。
- 不得宣稱兩次獨立 rename 等於跨檔交易。若採其他方案，仍須通過下列 crash matrix。
- 恢復後要維持刪除工作結果，不能因讀到舊 recent file 使已刪資料復活。

## 5.5 失敗與退出

寫入失敗：
- 保留最近 pending snapshot 與 lastDurableRevision。
- 同類錯誤不每次跳 modal；顯示持續的「工作紀錄尚未儲存」狀態。
- 可在 1、2、4 秒有限重試；耗盡後保留待存狀態，使用者可重試。
- 錯誤不得讓已成功的音訊轉錄重新送 API。
- 不繼續清除尚未可靠保存完成資訊的救援資料。

退出：
- RecordToTextApp.applicationShouldTerminate 改以既有 terminateLater 流程等待 critical flush。
- 不在主執行緒用 semaphore 或 dispatch sync 等待 writer。
- flush 目標 5 秒內完成；若失敗／逾時，顯示「重試儲存／取消退出／仍然退出」。
- 使用者選擇取消退出，App 回到可操作狀態；仍然退出不得謊稱紀錄已落盤。
- 退出時 snapshot 取最新 revision；待執行的 debounce 必須一併 flush。

第 1 項相容：
- 憑證載入／舊檔轉換未完成時，不可由 writer 提前改寫含舊資料的檔案。
- 這段期間的編輯保留最新 snapshot，完成載入後只送最新版本。
- 非同步載入結果不得用初始化時的舊 jobs／settings 覆蓋使用者編輯。

## 5.6 崩潰一致性驗收矩陣

對以下每個步驟注入程序中止，下次啟動後只允許「前一完整 revision」或「新完整 revision」：
1. journal 暫存寫入中。
2. journal 原子替換前。
3. journal durable、ledger 尚未更新。
4. ledger 更新、recent 尚未更新。
5. recent 更新、清理前版 journal 前。
6. completed critical 保存與工作區清理交界。

不允許：工作已完成卻無法找到正式稿位置、舊待辦復活、已刪工作復活、失敗稿被標為完成、兩份文件混合後丟失歷史。
receipt 承諾 process crash 的落盤一致性；若要承諾斷電恢復，需另驗證 fsync／檔案系統語義，不以 process crash 測試代替。

## 5.7 必要測試與效能驗收

1. 注入 500ms 慢 writer，MainActor heartbeat／設定修改仍能執行。
2. 100 次連續 coalescible 更新：pending 數有界，最後 revision 與記憶體一致。
3. coalescible 後立刻 completed：critical receipt 前不清 recovery。
4. 慢舊寫入 + 快新提交：磁碟最終只能是新 revision。
5. 刪除／重試／歷史裁切遵守原 retention policy，不能 resurrect。
6. journal／兩個輸出檔所有 crash points 通過重啟測試。
7. 寫滿磁碟、權限錯誤、資料夾暫時不可用：不卡 UI、不重送轉錄，可恢復儲存。
8. debounce 中退出：flush 保存最新資料；逾時取消退出仍可繼續工作。
9. formatter／encoder 並行壓力測試不產生損壞 JSON。
10. 比較 10、100、1,000 筆工作及每筆最多 400 行 log 的 fixture；各跑 3 次。
11. 記錄 submit 主執行緒時間、writer 時間、寫入次數、峰值記憶體。submit p95 目標 <16ms；若複製大 snapshot 超標，需改差異事件或 COW 策略並重新驗收。
12. 全套既有 persistence／recovery／credential migration 測試必須保持通過。

涉及檔案：AppViewModel.swift、RecordToTextApp.swift、JSONRepositories.swift、JobRetentionPolicy.swift、Models.swift、LenientCollectionLoader 相關型別、新增 coordinator／journal 與 crash tests。

# 交付要求

每項完成時交付：
- 實作檔案與改動理由。
- 修改前失敗、修改後通過的測試結果。
- 實際量測 fixture、機器、版本、命令與結果；未測項目明列。
- 安裝前備份、已安裝 bundle 與 build 的雜湊核對。
- 不覆蓋原始錄音、既有完整文字稿、未提交的其他規格。

參考：
- https://developer.apple.com/documentation/xcode/improving-app-responsiveness
- https://developer.apple.com/documentation/swift/continuousclock
