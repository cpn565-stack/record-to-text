# 階段 1 實作說明：本機靜音感知切點

- 規格：`docs/qwen-local-01-silence-boundaries-spec-2026-09-27.md`
- 日期：2026-09-27
- 分支：`codex/record-to-text-reliability-v2`（HEAD `43f0fbd`）
- 狀態：**程式完成、自動化測試全綠；§8 的真實模型 A/B 與預設放行尚未驗證**
- 尚未 commit（工作區仍含階段 0 與先前的十分鐘時間戳變更，未動、未提交）

> 2026-09-27 獨立審查補註：已重跑確認 482 Swift／130 Python 測試通過，但另發現全靜音 root 的 Swift 空檔阻擋、靜音證據來源驗證不足、normalization digest 定義不一致與外層候選分歧。以下保留原實作紀錄；目前應視為「主要實作完成，階段驗收未完成」。下一輪依[審查與階段 1.1 修改規格](qwen-local-01-review-and-hardening-spec-2026-09-27.md)收尾，再進階段 2。
>
> 2026-09-27 階段 1.1 收尾補註：F1–F5 已修正，§9.2 的四項整合測試已補齊，另修掉兩個審查未列出的 P1（切片身分自己讀不回來、`checkpointCommitted` 被當成無效事件）。`SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh` 全綠：Swift 505／Python 133。**本文以下內容是階段 1 當時的紀錄，其中 §2.2 的 normalizationDigest 定義、§2.4 的預設值與 §9.2 的缺口都已被階段 1.1 取代**；實際驗收狀態見[階段 1.1 交付說明](qwen-local-01-hardening-delivery-2026-09-27.md)。§9.3 的真實模型 A/B、預設放行與效能量測仍未執行。

> 2026-09-27 再審修正補註：已修正 Swift／Python 對持久化整數的接受差異，新增 113 份共用檔案交叉驗證案例（計為一個 XCTest）與 Python Int64 邊界測試。最新完整檢查為 Swift 506／Python 134 全數通過，Swift 無失敗或跳過；修法與證據見交付說明 §1.4。

> 2026-09-27 安裝補註：本機測試 App 已升為 0.2.1（build 8）並啟動；原 build 7 已備份。封裝與安裝後檢查見交付說明 §6。本文上方的階段 1.1 測試數字是當時紀錄；真實模型 A/B 仍未執行。

---

## 1. 這一階段做了什麼

在三層切點上都接了靜音感知，而不是只接外層：

| 層 | 上限 | 搜尋窗 | 選點規則 | 實作位置 |
| --- | --- | --- | --- | --- |
| 外層 root | 1,200 秒 | 前 30 秒 | 取最接近上限的合格停頓 | Swift `SilenceAwareSegmentPlanner` |
| 十分鐘顯示格 | 600 秒 | ±5 秒 | 先貼齊既有 root 邊界，再取最接近目標的停頓 | Swift `LocalCheckpointPlanner.makeDisplayGroups` |
| 初始 ASR chunk | 120 秒 | 前 5 秒 | 取最接近上限的合格停頓，不可跨 root／displayGroup | Swift `LocalCheckpointPlanner.makeRootPlans` |
| token 超限遞迴 | parent 中點 | ±5 秒 | 兩個 child 都 ≥30 秒；無候選取合法中點 | Python `silence_choose_split` |

每個 sample 仍恰好屬於一個終端區間。靜音偵測只用來「選點」，不用來刪音訊（§1、§6）。

---

## 2. 資料契約

### 2.1 新檔案 `silence-plan.json`

位置：`Temp-Recovery/<job UUID>/local-checkpoint-v2/silence-plan.json`，權限 0600，
以 `AtomicFileWriter` 寫入，內容是 canonical JSON（key 依 UTF-8 位元組排序、無空白）。

為什麼是獨立檔案而不是塞進 `manifest.json`：§3.7 允許在靜音區間超過 100,000 筆時
「保留切點方案、丟掉區間清單」。`planID` 不涵蓋 `silencePlanDigest`，所以丟清單不會
改變 `planID`，也就不會讓已 commit 的 root state 失效。

欄位（重點）：

```
schemaVersion, plannerVersion, enabled, detector,
thresholds{ noiseProfile, minimumSilenceDurationSeconds, recursiveSearchSeconds, ... },
coveredStartSample, coveredEndSample,
scanPCMSHA256, normalizationDigest, sourceSHA256,
truncated, intervals[{startSample,endSample}],
scanCount, scannedAudioSeconds, scanElapsedMilliseconds, cacheHitCount,
outerSilenceCuts, outerFallbacks, innerSilenceCuts, innerFallbacks
```

### 2.2 canonical JSON 沒有 float

所有 `Double` 一律以 `String(format: "%.6f", locale: en_US_POSIX)` 寫成字串
（`LocalSilenceThresholds.seconds(_:)`）。Python 端 `FrozenSilencePlan._seconds`
接受 int／float／str，但拒絕 `bool`、非有限值與負值。

**這次修掉的一個真 bug**：`LocalSilencePlan` 與 `LocalSilenceThresholds` 原本只有
synthesized `Decodable`，而 synthesized 版本會用 `Double` 去解 JSON 字串 → 自己寫的
位元組自己讀不回來。已補上明確的 `init(from decoder:)`（`decodeCanonicalSeconds`
同時接受字串與數字），並以 `testASilencePlanRoundTripsThroughItsOwnDigest` 固定。

### 2.3 manifest 新欄位

- `plannerVersion`：`local-fixed-v2`（固定切點）／`local-silence-v1`（靜音方案）。
  參與 `computePlanID`，所以換策略就是換計畫，不會默默沿用。
- `silencePlanDigest`：`silence-plan.json` **實際位元組**的 SHA-256。
- `silencePlanRelativePath`：相對 v2 目錄的路徑。

### 2.4 設定與 snapshot 欄位

- `AppSettings.localSilenceAwareSegmentation`：新工作預設 `true`，可在進階設定關閉。
- `JobSnapshot.localSilenceAwareSegmentation`：預設值是 `true`，但**解碼缺失時為
  `false`**——在此欄位存在之前就已排隊的工作，保留它被排隊時的固定切點語意。
- 沒有挪用 `silenceAwareCloudSegmentation`；雲端行為完全不受影響（§2）。
- 這個欄位**刻意不進 `LocalInferenceIdentity`**，所以續跑時切換設定不會觸發
  `frozenIdentityChanged`；它只被記錄在 manifest／silence-plan 裡。

### 2.5 座標

所有 v2 sample 值都是「原始錄音」座標下的絕對 16 kHz 索引。顯示時間 =
`absoluteSample / sampleRate`，**不加任何偏移**；v1 的 `timeOffsetSeconds` 不可用於
v2 標題。Python 的陣列索引 = `absoluteSample - audioStartSample`。
量化一律 `floor(seconds * rate + 0.5)`（`LocalAudioCoordinates.quantize` /
Python `math.floor`），不可用 Python 的 `round()`（銀行家捨入）。

---

## 3. 規劃順序（§4 指定）

`TranscriptionEngine.freezeLocalCheckpointV2` 內嚴格照這個順序，且**全部在推論之前**
凍結、驗證、落盤：

1. `LocalCheckpointPlanner.makeRootSpans` — 由實際解碼 sample 數累加，不用算術。
2. `makeDisplayGroups` — 目標是 `workStart + k×600s` 的**絕對格**，不是
   `previousEnd + 600s`；先嘗試貼齊 ±5 秒內的 root 邊界，再看停頓候選。
   起點與終點固定，不因靜音移動。
3. `makeRootPlans` → `makeChunkPlans` — 子區間來自 root 與 displayGroup 邊界的聯集，
   每個子區間內以 ≤120 秒切；交界與最後尾段允許短於 30 秒。
4. `freeze` / `openOrFreeze` 寫 `identity.json` → `silence-plan.json` → `manifest.json`
   （順序保證 manifest 記錄的 digest 已存在）。
5. token 超限只把受影響的 leaf 換成 `split` + 兩個 child，已完成的兄弟節點不動。

**同一份 displayGroups 物件同時交給 manifest 與 chunk 規劃**，避免兩處各自算一次而
讓 chunk 與標題對 group 起點的看法不一致。

### 續跑的決定性

外層 root 邊界決定 ffmpeg 在哪裡切，而切塊發生在 v2 凍結之前。所以 `run()` 一開始
就用 `LocalCheckpointPlanner.loadFrozenManifest(layout:)` 讀一次：有凍結計畫時，
`segmentPlan` 直接由 `manifest.roots` 還原（`segmentPlan(from:maximumSegmentDuration:)`），
**完全跳過靜音偵測**。`freezeLocalCheckpointV2` 回傳的 roots 也改用
`manifest.roots`，不是這次重算的。這樣才能滿足 §2「以持久化 planID 為準」與
§8「設定在續跑前改變 → 舊方案不變」。

`segmentPlan(from:)` 把絕對 sample 減掉 `workStartSample` 換回正規化音訊秒數；
切片偏移已經 baked-in，**不會被套兩次**（`testAFrozenPlanResumesWithoutApplyingTheSliceOffsetTwice`）。

---

## 4. 靜音掃描（§3）

`TranscriptionEngine.planLocalSilenceBoundaries(...)`：

- **§3.1** 掃的是階段 0 已驗證的 normalized PCM，與推論同一軌／同一混音／同一取樣率。
- **§3.2** 每個工作對整個工作範圍掃一次。`noise=-35dB`、`d=0.35s` 是工程預設值，
  不是已驗證的最佳值（文件與設定頁都這樣寫）。
- **§3.3** 偵測器輸出是「掃描相對秒數」。`LocalSilenceScanner.absoluteIntervals`
  做：有限性檢查 → 量化 → 加 `scanStartSample` → clamp 到掃描範圍 → 丟棄反轉／退化
  → merge 相鄰與重疊。超出範圍的停頓是 **clamp 而不是丟棄**。
- **§3.4** cache key 綁 `SilenceAnalysisContentIdentity(sourceSHA256, pcmSHA256,
  normalizationProfile)`，全部沿用階段 0 已算出的 digest；不用 path／mtime。
- **§3.5** 成功但沒有靜音 = 合法空集合，之後的查詢不可重掃。
- **§3.7** 超過 `maximumIntervalCount`（100,000）時：切點方案照存，
  `intervals` 寫成 `[]`、`truncated: true`。helper 端候選自然為空 → 遞迴改用合法中點
  並記 log。沒有第二條偵測器管線。

### 掃描器與服務的單一資料源

`SilenceDetectionServicing` 新增 `noiseProfile` / `minimumSilenceDuration`
（protocol extension 給預設值，既有的三個測試 mock 不需改）。
`SilenceDetectionService` 用**自己的欄位**組 ffmpeg filter，而不是寫死字串；
`LocalSilenceThresholds.resolving(...)` 再把注入服務的實際值放進要持久化的 thresholds。
這樣 manifest 記錄的數字不可能與 ffmpeg 實際收到的不同。

### ProcessRunner 限制

`probeService`／`ffmpegService`／`silenceDetectionService`／`backend` 共用一個
`ProcessRunner`，重疊會丟 `.alreadyRunning`。所以身分探測與靜音掃描**必須序列執行**；
目前掃描只在 `localPreparation` 完成、正規化 WAV 已存在之後才跑，符合這個限制。

---

## 5. 候選清單如何交到 helper（§7，不可新增 RPC）

這一階段禁止新的 helper→Swift RPC，所以：

- Swift 把候選（區間清單）寫進 `silence-plan.json`，digest 記在 manifest。
- helper 用 `manifest["silencePlanRelativePath"]` 對 `block["directory"]` 解析路径，
  **不改 request block**，所以不存在第二個可能彼此矛盾的通道。
- `load_silence_plan` 的失敗語意：
  - 兩個欄位都不存在 → `None`（固定切點、階段 1 以前的計畫，正常）
  - 路徑逃出 v2 目錄 → `local_checkpoint_invalid`
  - 有 digest 但檔案不在 → `local_checkpoint_invalid`（**不是**當成空候選）
  - 位元組不符 → `local_identity_mismatch`
  - `noiseProfile` 不是 dB 值 → 拒絕，不猜成 0 dB
- 遞迴切點計數（`SplitCounters`）留在 helper，透過既有 `log` 事件流出去；
  Swift 端則用 `LocalSilencePlan.metricsSummary()` 单独一行印出四項掃描指標與
  外層／內層切點計數，**不混進模型推論時間**。

### 中點算術必須兩邊一致

Swift `LocalSilenceInterval.midpointSample = start + (end - start) / 2`（`Int64` 截斷），
Python `start + (end - start) // 2`。對本型別只持有的非負座標，兩者完全相同。
`SilenceCandidateIndex` 的 docstring 與兩側測試都固定了這件事。

### split 政策的紀錄方式

`on_span_split` 不從遞迴往下傳旗標，而是**由已 commit 的邊界反推**：
`split_sample == parent 算術中點` → `token-limit-midpoint`，否則
`token-limit-silence`。理由：切點是唯一能說明「誰選的」的事實，傳旗標有可能與
實際落盤的結果不一致。

---

## 6. 空文字與 verifiedSilence（§6）

helper 的 `record_empty_leaf`：

- 只有在 `silence_plan` 存在**且**整段 leaf 被單一已驗證靜音區間完整涵蓋時，
  才記 `verifiedSilence`，並寫 `silenceEvidence{detector, coveredStartSample,
  coveredEndSample, thresholdDB, minimumDurationSeconds}`。
- 部分涵蓋 → `failed` + 丟 `CheckpointContractError("local_empty_unverified")`，
  由外層 `except` 呼叫 `preserve_partial_output()` 保留先前文字。
  `ordered_covering_leaves` 排除 `failed`，所以未完成的那段不會被當成完成。
- 沒有任何靜音計畫時，空文字一律 `failed`（fail-closed，與階段 0 相同）。
- **不用靜音比例、不用平均音量猜**。-35dB 不是人聲活動模型；正常非空文字不会因为
  落在偵測靜音區間而被刪除。

`LocalSilenceCandidateIndex.covers(_:)`（Swift）與 `SilenceCandidateIndex.covers`
（Python）這次對齊了空／反轉範圍的行為：兩者都回 `False`。原本 Swift 對
`[100,100)` 會回 `True`，與 Python 分歧——雖然目前 Swift 端尚無生產呼叫者，
但階段 3 會用它，分歧的 helper 比沒有 helper 更糟。

初版仍對所有初始 chunk 推論，「偵測到靜音」不等於「跳過 ASR」。

---

## 7. 失敗處理（§3.6）

`planLocalSilenceBoundaries` 的錯誤分類：

| 情況 | 行為 |
| --- | --- |
| 一般分析錯誤（ffmpeg 失敗、解析失敗） | `cache.recordFallback()` + 記一次 `local_silence_scan_failed` warning，回 `nil` → 未規劃部分回退固定切點 |
| `CancellationError` | 重新丟出，**不吞成「沒找到靜音」** |
| 來源不符／checkpoint 錯誤 | 由更上層丟出，整個工作停止 |
| 設定關閉 | 記 info log，回 `nil`（這是 A/B 與新工作的回退方式，不是失敗後自動換方案） |

`nil` 的語意是「這次用固定切點」，`freezeLocalCheckpointV2` 會把 `plannerVersion`
記為 `local-fixed-v2`，且不寫 `silence-plan.json`。

---

## 8. 檔案清單

### 新增

- `Sources/RecordToTextCore/LocalSilencePlanner.swift`
  （`LocalPlannerStrategy`、`LocalSilenceThresholds`、`LocalSilenceInterval`、
  `LocalSilenceCandidateIndex`、`LocalSilenceScanner`、`LocalBoundaryDecision`、
  `LocalSilenceBoundarySelector`、`LocalSilencePlan`、`LocalSilencePlanStore`）
- `Tests/RecordToTextCoreTests/LocalSilencePlannerTests.swift`（47 個測試）

### 修改（Swift）

- `Sources/RecordToTextCore/SilenceAwareSegmentation.swift`
- `Sources/RecordToTextCore/JobSilenceAnalysisCache.swift`
- `Sources/RecordToTextCore/LocalCheckpointManifest.swift`
- `Sources/RecordToTextCore/LocalCheckpointPlanner.swift`
- `Sources/RecordToTextCore/LocalCheckpointValidator.swift`
- `Sources/RecordToTextCore/Models.swift`
- `Sources/RecordToTextCore/JobSnapshotEngineSettings.swift`
- `Sources/RecordToTextCore/TranscriptionEngine.swift`
- `Sources/RecordToTextApp/SettingsView.swift`
- `Sources/RecordToTextApp/AppViewModel.swift`

### 修改（Python helper）

- `qwen_asr_chunking.py`：`SilenceCandidateIndex`、`SplitCounters`、
  `silence_choose_split`；`ChooseSplit` 契約改為
  `(span_start, span_length, min_split_samples, midpoint) -> offset`
- `qwen_asr_local_checkpoint.py`：`load_silence_plan`、`FrozenSilencePlan`、
  `SPLIT_POLICY_TOKEN_SILENCE`
- `qwen_asr_mlx_runner.py`：載入凍結計畫、`record_empty_leaf`、split 政策、遞迴計數 log

### 修改（測試）

- `Tests/qwen_asr_chunking_test.py` 22 → 41
- `Tests/qwen_asr_local_checkpoint_test.py` 59 → 78
- `Tests/RecordToTextCoreTests/LocalCheckpointV2Tests.swift`（`openOrFreeze` 回傳 tuple）

### 相容性

- v1 `chunk-checkpoints/*.chunks.json` 完全不被覆寫；v2 用新目錄。
- `RecoveryScanner.knownRecoveryFileNames` 已含 `local-checkpoint-v2` 目錄名，
  目錄內的 `silence-plan.json` 不会被当成未知项目，**不需要再改 allowlist**。
- 沒有 `silence-plan.json` 的舊 v2 計畫：helper `load_silence_plan` 回 `None`，
  遞迴用合法中點，行為與階段 0 相同。
- 回退不会把 v2 结果交给旧 helper 猜读。

---

## 9. 驗收狀態

指令：`SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh` → `✅ 全部驗證通過！`

- Swift：**482 tests, 0 failures, 0 skipped**（階段 0 結束時是 435，本階段 +47）
- Python：**130 tests OK**（chunking 41 + local checkpoint 78 + mlx runner 11；
  階段 0 結束時是 92）
- `__pycache__` 已清除，`Sources/RecordToTextApp/Resources/` 只剩四個 `.py`。

### 9.1 §8 測試表：已驗證

| §8 列 | 涵蓋測試 |
| --- | --- |
| 停頓剛好在 120 秒前／後 → 用較早的合法候選，後者不可把 chunk 推過上限 | `testALimitBoundaryTakesThePauseBeforeTheCapAndNeverOneAfterIt`、`testOuterCountsFollowTheAccumulatingNominalNotMultiplesOfTheCap`、Python `test_a_pause_outside_the_search_window_is_ignored` |
| 無停頓／連續背景噪音 → 固定切點回退，覆蓋不變 | `testALimitBoundaryWithNoCandidateKeepsTheCap`、`testAnAllFixedOuterPlanCountsEveryCutAsAFallback`、`testWithoutCandidatesChunksLandOnTheExactChunkGrid`、Python `test_a_truncated_plan_falls_back_to_legal_midpoints` |
| 60 秒 parent 頂滿 → 只允許 30+30，不可產生 29 秒 child | `testASixtySecondParentAtTheCapOnlyAdmitsThirtyPlusThirty`、Python `test_a_60_second_parent_only_admits_the_exact_midpoint`、`test_a_pause_inside_the_window_but_below_the_child_floor_is_rejected` |
| 45 秒／短尾頂滿 → 不可切成兩個 <30 秒 | `testAShortTailHasNoLegalWindowAndTheSelectorRefusesToGuess`、Python `test_a_45_second_capped_tail_produces_a_gap_and_no_split` |
| 遞迴左完成右失敗 → 左的 commit 與起訖可回復，不必重新規劃 | Python `test_a_failed_right_child_leaves_the_committed_left_half_recoverable` |
| 空文字 + 部分靜音 vs 全段靜音 | Python `test_an_empty_leaf_only_partly_silent_fails_and_keeps_prior_text`、`test_an_empty_leaf_wholly_inside_a_pause_is_verified_silence`、`test_an_empty_leaf_without_a_silence_plan_still_fails_closed` |
| 十分鐘顯示不得累加漂移、每個內部目標偏移 ≤5 秒 | `testDisplayGroupTargetsStayOnTheAbsoluteGridWithNoAccumulatedDrift`、`testDisplayGroupStartAndEndAreFixedAndNeverMoveToAPause` |
| 初始 chunk 不可跨 displayGroup；交界／尾段可短於 30 秒 | `testInitialChunksNeverCrossADisplayGroup`、`testABoundaryTailShorterThanThirtySecondsIsKeptNotDeleted`、`testAChunkStraddlingADisplayGroupBoundaryIsRejected` |
| 同一份輸入必產生相同方案 | `testTheSameInputAlwaysProducesTheSamePlan` |
| 續跑不得套用第二次偏移 | `testAFrozenPlanResumesWithoutApplyingTheSliceOffsetTwice`、`testAFrozenPlanWithoutRootsIsRefusedRatherThanCutToNothing` |
| 掃描指標與切點計數分開記錄 | `testASilencePlanRoundTripsThroughItsOwnDigest`（`metricsSummary()` 九項 key） |
| 候選清單超過上限 → 保留切點、丟清單 | `testATruncatedScanKeepsTheCutPlanAndDropsTheIntervalList` |
| digest 保護與 traversal | `testATamperedSilencePlanIsRefused`、`testARecordedDigestWithNoFileIsRefusedButNoDigestLoadsAsNil`、Python `test_a_relative_path_escaping_the_v2_directory_is_refused` 等 10 個 |

### 9.2 §8 測試表：尚未以自動化測試涵蓋

> **2026-09-27 階段 1.1 已補齊以下四項**，測試名稱逐項列在後面；完整證據見
> [階段 1.1 交付說明 §2 H4](qwen-local-01-hardening-delivery-2026-09-27.md)。
> 以下保留當時的原始描述。

這四項是我停下來的地方，**不是已驗證**：

1. **非零切片 + displayGroup 跨 root 的渲染**：Swift 側已驗「無第二次 offset」與
   「絕對格」，但還沒有一个测试同时具备「非零 `sourceSlice.startSeconds`」+
   「一个 displayGroup 内含来自两个 root 的 leaf」并断言最终 TXT 标题与内容。
   需要扩 `LocalV2IntegrationTests` 或 Python `RenderV2Tests`。
   → 已補：`testNonzeroSliceRendersOneGroupAcrossTwoRoots`（slice 5 秒起、root 邊界
   1190 秒、`[00:10:05 - 00:20:05]` 標題恰好一個）。
2. **偵測器失敗 → 可觀察回退**：`planLocalSilenceBoundaries` 的 catch 分支會發
   `local_silence_scan_failed` warning 并回 `nil`，但没有测试注入一个会失败的
   `SilenceDetectionServicing` 去断言这条 warning 与随后的固定切点。
   → 已補：`testDetectorFailureFallsBackOnceAndLogsMeasuredCost`；空集合另由
   `testASuccessfulEmptyScanPersistsAValidEmptyPlanAndAResumeDoesNotRescan` 區分。
3. **取消 → 向上停止**：`CancellationError` 被重新丢出，但没有测试证明它不会被
   当成「没找到静音」。
   → 已補：`testDetectorCancellationAndIdentityErrorsStopBeforeInference`
   （取消、來源錯誤、checkpoint 錯誤三種都向上停止，`generate == 0`，不寫 manifest）。
4. **引擎层的「设定在续跑前改变 → 旧方案不变」**：`openOrFreeze` 与
   `loadFrozenManifest` 各自有测试，但没有一个 end-to-end 测试把
   `localSilenceAwareSegmentation` 从 true 改成 false 后续跑，并断言 `segmentPlan`
   仍来自冻结的 manifest。
   → 已補：`testFrozenPlanSurvivesBothSettingChangesWithoutRescanningOrRegeneratingCompletedRoot`
   （true→false 與 false→true 雙向，manifest 位元組不變、detector 0 次）。

### 9.3 无法在此环境验证（需要真实模型／真实音讯／人工）

- **§8 的真实模型 A/B**：同模型、同 revision、同 prompt、同 token、同素材、
  固定解码设定下比较固定切点 vs 静音切点，涵盖多说话人连续语音、低音量、
  背景噪音、专有名词、语码转换，并**由人工核对每个被移动切点前后 ±5 秒**。
  这台机器没有安装 `mlx_audio`，无法执行。
- **§8 的预设放行门槛**：覆盖与时序测试全过、无新增内容遗失、比较样本的边界错误
  总数不高于 baseline。未验证 → 依规格「若不能证明稳定，维持可选设定并记录
  未放行理由」，功能目前是**进阶设定中可关闭、新工作预设开启**，设定页的说明
  文字已明写「此选项保留可关闭，是因为切点效果尚未通过真实模型 A/B 与人工核对」。
- **§3.2 的 -35dB / 0.35 秒是否适合弱音、远距离、背景音乐素材**：未实测。
  这两个数字在文件与程式注释中都标注为工程预设值，不是已验证的最佳值。
- **§9.10 的 30 分钟／173 分钟 fixture 扫描与推论耗时**：阶段 0 就未实测，
  本阶段只把扫描耗时单独记为 info log，未做量测断言。

---

## 10. 下一步

1. 补齐 §9.2 的四项测试（其中 2、3、4 需要一个可注入失败／取消侦测器的引擎，
   `LocalV2IntegrationTests.makeEngine` 是现成入口）。
2. 取得可跑 MLX 的环境后执行 §9.3 的真实模型 A/B，人工核对 ±5 秒，
   再决定要不要把预设从「可关闭」改成「放行」。
3. 阶段 2（段级续跑与前处理跳过）：本阶段已经先把
   `loadFrozenManifest` / `segmentPlan(from:)` / `effectiveRoots` 建好，
   阶段 2 可以直接站在「续跑绝不重算已冻结边界」这个前提上。
