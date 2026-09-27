# Qwen 地端階段 1：實作品質審查與下一輪修改規格

日期：2026-09-27

審查對象：[階段 1 實作筆記](qwen-local-01-silence-boundaries-implementation-2026-09-27.md)、[原規格](qwen-local-01-silence-boundaries-spec-2026-09-27.md)及實際工作區。

基準：HEAD `43f0fbd` 加上未提交的階段 0／1 與十分鐘時間戳修改；以下行號以本次審查版本為準。

狀態：**階段 1.1 已實作完成，`SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh` 全綠（Swift 506／Python 134）；§4 的真實模型 A/B 與預設放行仍未執行。交付證據見[階段 1.1 交付說明](qwen-local-01-hardening-delivery-2026-09-27.md)。**

## 1. 品質結論

架構方向合理，實作完整度明顯高於只接上外層切點的原型。root／displayGroup／chunk 凍結、sample 座標、遞迴提交、空白結果保守處理都有實際程式與測試。原筆記也誠實列出缺少的整合測試與真實模型 A/B。

但「自動化全綠」不能當成「階段 1 已驗收」。目前有全靜音 root 無法通過 Swift 管線、靜音證據來源未驗證、外層候選與內層不一致等缺口。建議評價為：**可保留的實作基礎，尚未達到預設放行品質**。這是對當前程式碼的判斷，不是對撰寫模型整體能力的評分。

本次重新執行：

```sh
SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh
```

結果：Swift **482 tests、0 failures、0 skipped**；Python **130 tests**（41 chunking + 78 checkpoint + 11 runner）通過；72 項 executable self-tests 與 10 個 pipeline 情境通過。App bundle 建置依指令跳過，沒有安裝、發版或執行真實模型 A/B。

另以既有 Python fixture 與編譯後的 Swift core 做針對性反例。這些反例沒有加入正式測試集，因此不算在上述測試數內；下一輪必須轉成 regression tests。

## 2. Findings：按優先序

### F1／P1：整個 root 都是 verifiedSilence，仍被空 TXT 擋住

**已確認。** Python `record_empty_leaf` 能提交 `verifiedSilence`，全靜音 root 的 `render_timed_transcript_v2` 輸出空字串並發送 `completed`。但：

- [ASRBackend.swift](../Sources/RecordToTextCore/ASRBackend.swift) 884–889 行仍無條件呼叫 `readNonEmptyUTF8`。
- [TranscriptionEngine.swift](../Sources/RecordToTextCore/TranscriptionEngine.swift) 928–940 行也先讀非空 TXT，之後才驗證 v2 root state。

因此「前一 root 有對話、下一 root 全段靜音」會在後一 root 中止，無法抵達全工作合併。這與「整份工作完全沒有語音」是不同情況；後者原有 `noSpeechContent` 保護應保留。

重現證據：既有 Python 全靜音 fixture 得到 `verifiedSilence`／`completed`；帶 `checkpointV2` 的 Swift backend mock 回傳空檔＋合法單次 completed，實際得到 `ASRBackendError.outputEmpty`。直接呼叫引擎使用的 `OutputContractValidator.readTranscript` 亦得到 `TextFileValidationError.empty`。未將這項分層重現冒稱為完整引擎 E2E。

### F2／P1：檔案 digest 有驗，靜音證據是否屬於這份音訊沒有驗

**已確認。** [qwen_asr_local_checkpoint.py](../Sources/RecordToTextApp/Resources/qwen_asr_local_checkpoint.py) `load_silence_plan`（279 行起）驗證檔案 SHA-256；`FrozenSilencePlan.parse` 卻未比對 `sourceSHA256`、`scanPCMSHA256`、`normalizationDigest`、covered range、planner 與 enabled。非法 intervals 也可能被忽略成空集合。

以下各反例都使用與 manifest 所記 digest 相符的檔案位元組，以排除「只是沒更新 digest」的情況：

| 靜音計畫內容 | 目前 helper 結果 | 應有結果 |
| --- | --- | --- |
| source／PCM／normalization digest 刻意不符 | `verifiedSilence`、`completed` | identity mismatch |
| covered range 完全不含 leaf，intervals 卻含 leaf | `verifiedSilence`、`completed` | checkpoint invalid |
| `enabled=false` 仍有 intervals | `verifiedSilence`、`completed` | 不得用作靜音證據 |
| `truncated=true` 卻仍帶 intervals | `verifiedSilence`、`completed` | 拒絕矛盾計畫 |
| 未知 planner／detector | `verifiedSilence`、`completed` | 拒絕未知契約 |

這證明的是**驗證器未守住契約**，不代表已觀察到正常使用者的錄音遭到誤刪。風險在錯接分析檔、producer bug 或恢復資料不一致時，錯誤證據仍能讓空白段被當成完成；若其他 leaf 有文字，整稿可能看似無缺口。

Swift 也有同一缺口：`LocalSilencePlanStore.load` 目前只在測試呼叫，production 的 `loadFrozenManifest`／`openOrFreeze`／`verifyLocalCheckpointV2Root` 沒有串入它；`LocalCheckpointValidator` 對 `verifiedSilence` 只核對 evidence 範圍與空文字，沒有驗證它來自哪份已驗證分析。階段 2 若直接跳過 helper，會更依賴這個尚未完成的驗證層。

### F3／P2：normalizationDigest 的 producer 已經使用不同定義

**已確認。** `TranscriptionEngine.swift` 3200–3202 行對 `LocalNormalizationProfile.current.version` 字串取 hash；`LocalCheckpointPlanner.freeze` 對完整 `identity.normalizationProfile` 的 canonical JSON 取 hash。

本機呼叫正式 `LocalDigest` 得到不同值：完整 profile 前綴 `a6a84a07fc64`，version 字串前綴 `4dc2409486e8`。目前因 F2 未核對，錯誤被隱藏。單純補上相等檢查而不修 producer，會使目前寫出的靜音計畫全數失敗。

### F4／P2：外層與內層使用不同候選集合

**已確認。** `TranscriptionEngine.swift` 3157–3170 行先得到量化、合併後的 `candidates`，卻把未合併的 `detected` 傳给外層 `SilenceAwareSegmentPlanner`。內層與 helper 則使用合併後的整數 sample 中點。

正式 Swift API 反例：工作長 2400 秒，停頓 `[1197,1199]`、`[1198,1200]`。外層選 **1199 秒**；合併後區間為 `[1197,1200]`，共用 sample 中點為 **1198.5 秒**。因此筆記宣稱所有層遵守同一份候選／量化規則並不完整。一般 ffmpeg 是否頻繁產生這種資料未量測；契約必須處理重疊／相接區間，不能依賴它不發生。

### F5／P1 放行阻擋：A/B 未完成，卻已預設開啟

**已確認的設定，另含規格判斷。** `AppSettings` 預設值及缺欄解碼均為 true，新 `JobSnapshot` 預設也是 true；舊 snapshot 缺欄為 false，這一點正確。

原規格 §2 要求新工作預設開啟，§8 又把預設開啟綁在 A/B 放行條件，兩者缺少實驗期的明確優先序。實作遵照了 §2，但「可關閉」並不等於通過 §8。不能將這一點全歸咎於實作者；下一輪應把政策寫清楚：**放行前為可主動開啟的實驗功能，放行後才變更預設。**

### 測試與文件的其他缺口

- 原筆記 §9.2 的四項整合測試仍需完成，尤其 fake helper 只寫非空 leaf 的測試無法抓到 F1。
- `planLocalSilenceBoundaries` catch 除取消外全部降級。一般 ffmpeg 故障應回退；若注入的 detector／adapter 丟來源或 checkpoint 錯誤，現分支也會吞掉。這是可由程式直接確認的分類缺口，未宣稱內建 ffmpeg detector 正常情況會產生該錯誤。
- 成功且無靜音的 cache 行為已有基礎測試；還要驗證本機引擎只掃一次、落盤及續跑不重掃。
- 掃描失敗時 local cache metrics 隨 nil 返回遺失；遞迴計數只在正常退出迴圈後列印，失敗路徑看不到。需要補齊可觀察性，但優先度低於 F1／F2。
- `docs/NEXT_STEPS.md` 與 roadmap 原狀態仍寫四階段未實作，已不符合工作區。這次僅補充審查狀態與連結，保留歷史基準。

## 3. 下一輪範圍：階段 1.1 收尾

交付目標：靜音證據從凍結到 helper／Swift 合併皆可驗證；全靜音 root 不阻擋其他正常稿；所有切點使用一致候選；補齊故障與續跑整合測試。

本輪不實作階段 2 的選擇性 normalize／extract、不增加補稿 UI、不改模型、prompt、token 預算、雲端策略；不加入 overlap、文字模糊刪重或 helper→Swift 新 RPC。繼續使用現有 v2 目錄及原子提交原則。

建議按下列工作包交付；每包更新實作筆記並列出新增的驗收證據。

### H1：統一靜音證據契約與 production loader（先做）

主要位置：`LocalSilencePlanner`、`LocalCheckpointManifest`、`LocalCheckpointPlanner`、`LocalCheckpointValidator`、`TranscriptionEngine`、`qwen_asr_local_checkpoint.py`、runner。

1. `normalizationDigest` 統一為完整 normalization profile 的 canonical JSON SHA-256，沿用 manifest 現有定義。
2. freeze 前由已量測的 normalized PCM、已驗證 source facts 與 identity 核對 silence plan。將工作 normalized PCM 的 digest 明確持久化到 manifest（建議新增 optional `normalizedPCMSHA256`；新靜音計畫必填），使續跑可核對 `scanPCMSHA256`，不能拿任一 root digest 冒充全工作 digest。
3. 共用邏輯需驗證：版本／planner 支援、enabled、source digest、normalization digest、scan PCM digest、covered range、detector、門檻與 intervals。Swift/Python 對同一份 fixture 必須接受／拒絕一致。
4. silence 計畫的 path 與 digest 必須成對且必填。固定切點／階段 1 前的舊 v2 可兩者皆無；固定 planner 夾帶 silence 計畫、silence planner 缺計畫均拒絕。無引用的孤立檔不可自動成為證據。
5. covered range 必須覆蓋工作範圍；目前全工作掃描的新資料要求與 manifest work range 完全一致。若實際 root sample 合計不一致，先釐清抽取誤差，不能擴張靜音證據來湊範圍。
6. intervals 為有效整數 sample（Python bool 不算 int），全部在 covered range 內、排序、已合併且不重疊。持久化契約錯誤要拒絕；不可把壞資料靜默過濾成「掃描成功但沒有停頓」。detector 原始輸入的清洗則仍在凍結前處理。
7. `truncated=true` 要求 intervals 為空；數量不超過允許上限；未知 detector／planner 拒絕。搜尋窗必須有限非負、chunk／root／group 長度及最短門檻必須有限且大於零，並遵守目前支援策略的限制。
8. 路徑相對 v2 根目錄解析並採 Swift/Python 相同規則，拒絕絕對路徑、越界與符號連結繞過。
9. 將驗證接到 production：首次 freeze 前、續跑 manifest 載入時、helper 首次 generate 前、Swift 接受 root 完成／收集 leaf 前。驗證失败不得改走 fixed fallback。
10. 新 `silenceEvidence` 記錄所依據的 `silencePlanDigest`。Swift 驗證 leaf 全段位於該計畫有效 interval、門檻／detector 相符，不能只相信 helper 自填的 coveredStart/End。需要時將已驗證分析作不可變 context 傳入，避免每 leaf 重讀檔案。

錯誤分類：digest／來源／profile／PCM 不符使用既有 identity／PCM mismatch；缺檔、壞結構、未知版本或不合法 interval 使用 checkpoint invalid。失敗都要保留原 checkpoint 與已提交文字，generate=0（如在處理前發現）。

相容性：舊 fixed v2 照常讀取。已寫出的舊 silence 計畫若缺少必要證據或仍使用錯誤 version-only digest，不可改寫 digest 後假裝原結果仍有證據；此輪可明確拒絕自動續跑、保留資料供取回／另開新工作。若要加入相容轉換，須另提供可驗證轉換測試，不能順手放寬 validator。不得為檢查已持久化的靜音證據而要求已完成 root 重建 WAV，避免阻擋階段 2。

### H2：讓全靜音 root 通過 v2 完成驗證

主要位置：`HelperASRBackend`、引擎逐 root 完成處理、`LocalTranscriptMerger`。

1. v2 的 authoritative 結果是經 H1 驗證的 root state。調整 backend 與 engine 兩處空檔檢查的順序／責任，讓「全部 leaf 都是有效 verifiedSilence」可回傳完成。
2. 不得用 `checkpointV2 != nil` 或 completed event 作為略過驗證的充分條件。空檔只有在 root 精確覆蓋且全部有有效靜音證據時才可通過；pending／running／failed／缺證據一律失敗。
3. 檔案缺失、非 UTF-8、路徑錯誤、重複 completed event 等原有保護保留。非空 completed leaf 與空輸出矛盾也不能接受。
4. 中間 root 不要求自己有語音；全工作合併才判斷是否具有語音內容。root A 有文字、root B 全靜音、root C 有文字時，正式稿保留 A/C、範圍無缺口，B 不插入假缺稿標記。
5. 整個工作皆 verifiedSilence：保留 state，維持現有 `noSpeechContent`／不發布空正式稿語意，不以時間標題或虛構文字假造成功。v1／雲端非空契約維持現状。

驗收必須跑到真實 `HelperASRBackend` 與 `TranscriptionEngine`，只測 Python 的 `record_empty_leaf` 不足以結案。

### H3：外層 root 改用同一份整數 sample 候選

1. local 路徑以 `LocalSilenceScanner.absoluteIntervals` 清洗後的 `LocalSilenceCandidateIndex` 為所有層唯一候選來源。不要再將原始 `detected` 交給 local 外層秒數 planner。
2. 外層的 start、cap、搜尋窗、終點在 Int64 sample 空間決定；轉成 ffmpeg 秒數只放在抽取 adapter。保留 cloud 現有 planner 行為，可新增 local adapter，不必改雲端。
3. 外層每段 ≤1200 秒，搜尋上限前 30 秒，選最新合法中點；沒有候選則硬切。displayGroup 與 initial chunk 繼續用同一份 frozen 邊界。
4. 測試重疊／相接區間、奇數 sample 長度、半 sample 量化、非零切片、超界 clamp。F4 的結果必須是 1198.5 秒，且 root/chunk 精確鋪滿工作範圍。
5. 加一個非整秒切點的真實 ffmpeg PCM fixture：比較串接後 payload 與 normalized PCM 是否完全一致，檢查每段 start/end，而非只比較總長。若發現抽取誤差，要修抽取 adapter；不可用允許 0.1 秒差距替代覆蓋證明。此項是新增驗收要求，目前未宣稱已重現實際 sample 遺失。

### H4：補齊引擎層故障、渲染與續跑測試

擴充 `LocalV2IntegrationTests.makeEngine`，可注入 detector 與計數 spy；使用正式 checkpoint writer，模型推論以 stub 代替，不需要安裝 MLX 即可跑。

| 必測情境 | 精確驗收 |
| --- | --- |
| detector 一般錯誤 | 只發一次 `local_silence_scan_failed`；首次計畫為 fixed；無 silence 引用；音訊覆蓋不變 |
| detector 取消／Task 取消 | 向上取消；generate=0；不寫成功 silence 計畫；不發布；不能誤記一般 fallback |
| detector/adapter 回來源或 checkpoint 錯誤 | 原錯誤向上停止，不吞成沒有停頓；不推論 |
| 偵測成功空集合 | 掃描一次；後續 cache 查詢 hit；持久化有效空計畫；正常固定邊界 |
| true 凍結後切到 false；false 凍結後切到 true | 在同一 recovery 的引擎續跑：planID、roots、chunks、groups 及計畫位元組不變，detector=0；另開的新工作才用新設定 |
| 非零切片＋跨 root group | 例如 sourceSlice=1800 秒、root 邊界在工作 1190 秒；1800 起算的 600 秒 group 跨 root，最終只產生一個該 group 標題，leaf 順序正確、無二次 offset |
| 左 child 完成右 child 失敗後續跑 | 左 child state／text hash 不變，僅右側 generate，切點與 groupID 不重算 |
| 全靜音 root 夾在兩個有文字 root | 完整 backend→engine→merge 成功；非空內容都保留，無虛構 gap |
| 整工作全靜音 | 全覆蓋 state 可驗證，正式輸出維持 noSpeechContent 政策 |
| 靜音檔缺失／digest 不符／來源不符／越界 | Swift/Python 一致拒絕；重用與推論都不能先執行 |
| 區間超過保存上限 | 初始切點仍保留；清單空且 truncated；遞迴合法中點；空 leaf 不得靠已丟棄區間變 verifiedSilence |

frozen 設定切換測試針對現有同 recovery 引擎路徑；階段 2 的 child ledger／選擇性前處理另案實作，不能藉此擴大範圍。

### H5：明確定義實驗期預設與量測

此項是對原規格 §2／§8 衝突的**新修訂建議**：

- A/B 放行前，新安裝 AppSettings 預設 false；缺少設定欄位解碼為 false；新 snapshot 的預設也與此一致。使用者明確保存 true 的值保留，舊 snapshot 缺欄 false 保留。
- 有 frozen plan 的工作仍以 persisted plan 為準，變更預設不能暗中重切。切換提示說明「只影響新工作」。
- 設定頁標記實驗性、尚未完成 A/B，可主動開啟；不要寫成已證明改善辨識品質。
- 掃描成功、失敗、空集合與恢復沿用要能區分。失敗也記錄 scan count／duration／elapsed／fallback reason；續跑未掃描不可把歷史掃描次數當成本次掃描。
- helper 遞迴統計改在成功與失敗退出都能輸出，避免右 child 失敗時丟失左側切點紀錄。以 `finally` 等方式完成，但不能覆蓋原錯誤。
- 明確定義計數為「因候選而移動的切點」或「採用候選的切點」。目前中點恰與候選相等時算 fallback，若保留此定義，欄位／文件不可解讀成停頓命中率。

## 4. 真實模型 A/B：獨立於自動化驗收

H1–H5 通過後可完成「程式收尾」，仍不等於 A/B 已通過。若當下缺模型／音訊／人工標註，就記錄未執行，維持實驗期預設；不需要阻塞其他已授權的文件或測試工作。

使用同一組已授權素材，涵蓋多人連續講話、低音量／遠距離、背景噪音／音樂、專有名詞、中英混用。固定模型 revision、runtime、prompt／terms、token 預算及解碼設定；基準與實驗各開新工作，不能沿用同一 frozen plan 來冒充 A/B。

每個 A/B 切點集合的聯集都核對前後各五秒，記錄錯字、漏字、重複字、缺口 sample 數與全稿可用性。對無法固定的 runtime 隨機性記錄限制，必要時重複測量；不能只比較總字數。

交付 `docs/qwen-local-01-ab-results-<日期>.md`，至少含：

| 欄位 | 內容 |
| --- | --- |
| 素材 | 匿名 fixture ID、digest、長度、場景，不貼私人逐字稿 |
| 推論身分 | 模型／revision／runtime／設定 digest |
| 切點 | baseline／silence 各層實際 sample 範圍 |
| 品質 | 每個核對窗的錯／漏／重複與人工結論 |
| 覆蓋 | gap／failed／verifiedSilence sample 數 |
| 時間 | scan 與 ASR 分列，附冷／熱快取條件 |
| 放行 | 是否無新增內容遺失、總邊界錯誤是否 ≤ baseline；未通過的具體原因 |

預設開啟必須另有 A/B 證據與明確放行紀錄。效能不設未量測的百分比承諾。

## 5. 完成定義與階段 2 交接

- [x] F1–F4 修正且有失敗前能重現、修正後能通過的測試。
- [x] H4 所有適用場景通過，測試確實走 production loader／backend／engine。
- [x] H5 實驗期預設與設定迁移行為有測試，文件與 UI 一致。
- [x] `SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh` 全綠，記錄新測試總數及有無 skip。
      → Swift 506／0 failures／0 skipped；Python 134。
- [x] 原實作筆記更新為實際驗收狀態，標明仍未執行的 A/B／效能項目。
- [x] 沒有為了通過測試放寬 v1／雲端／正式稿契約，沒有改寫既有 frozen plan。

另修掉兩個本審查未列出的 P1（F6 切片身分自己讀不回來、F7 `checkpointCommitted`
被當成 `invalid_jsonl`），詳見[階段 1.1 交付說明 §1.2](qwen-local-01-hardening-delivery-2026-09-27.md)。

以上成立後才進入[階段 2：段級續跑與前處理跳過](qwen-local-02-segment-resume-spec-2026-09-27.md)。階段 2 必須重用 H1 的 Swift 完整證據驗證；全完成／全靜音 root 在不啟動 helper、不要求重建 WAV 的情況下也能分類。階段 1.1 不需要先實作階段 2 才能驗收。

## 附錄：F2 最小重現方式（現版本預期暴露缺陷）

在 repository 根目錄執行，僅使用暫存目錄及既有測試 fixture；沒有真實模型或外部 API：

```sh
python3 -B - <<'PY'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, 'Tests')
import qwen_asr_local_checkpoint_test as t

with tempfile.TemporaryDirectory() as raw:
    f = t.CheckpointFixture(Path(raw), chunks=t.SINGLE_CHUNK)
    p = t.silence_plan_payload(intervals=[(t.ROOT_START, t.ROOT_END)])
    p.update(sourceSHA256='a'*64, scanPCMSHA256='b'*64,
             normalizationDigest='c'*64,
             coveredStartSample=t.ROOT_END+1,
             coveredEndSample=t.ROOT_END+100)
    t.freeze_silence_plan(f, p)  # 同步記錄這份檔案的實際 SHA-256
    events = t.TranscribeV2Tests().run_v2(f, t.FakeModel([t.FakeResult('')]))
    print([n['state'] for n in f.read_state()['nodes']])
    print([e for e in events if e[0] == 'completed'])
PY
```

審查版本結果為 `['verifiedSilence']` 並發出 `completed`。此 fixture 本身還沿用 fixed planner，未包含完整 production identity；它正好也說明現 parser 接受不完整／矛盾契約。正式 regression 應先建立可由 Swift 凍結且兩邊均接受的完整合法 fixture，再逐欄變造並同步檔案 digest，避免測試只是被另一個缺欄擋住。
