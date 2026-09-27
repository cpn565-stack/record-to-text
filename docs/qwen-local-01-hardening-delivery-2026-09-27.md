# 階段 1.1 交付說明：靜音證據收緊與整合驗收

- 規格：[審查與階段 1.1 修改規格](qwen-local-01-review-and-hardening-spec-2026-09-27.md)
- 前一份實作紀錄：[階段 1 靜音感知切點](qwen-local-01-silence-boundaries-implementation-2026-09-27.md)
- 日期：2026-09-27
- 分支：`codex/record-to-text-reliability-v2`（HEAD `43f0fbd`，工作區含階段 0／1／1.1，尚未 commit）
- 狀態：**H1–H5 程式完成，`SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh` 全綠；§4 的真實模型 A/B 與預設放行仍未執行**

驗證指令與結果：

```sh
SKIP_APP_BUNDLE=1 ./scripts/run-checks.sh   # ✅ 全部驗證通過！
```

- Swift：**506 tests、0 failures、0 skipped**（階段 1 結束時 482，含獨立審查後修正共 +24）
- Python：**134 tests OK**（chunking 41 + local checkpoint 82 + mlx runner 11；階段 1 結束時 130）
- `Sources/RecordToTextApp/Resources/` 只有四個 `.py`，沒有 `__pycache__`
- 上述完整自動化檢查依指令跳過 App bundle；其後另行建置並安裝本機測試版，見 §6。沒有執行真實模型推論或公開發版

---

## 1. 這一輪修了什麼

### 1.1 審查列出的 F1–F5

| 編號 | 结论 | 修正位置 |
| --- | --- | --- |
| F1 全靜音 root 被空 TXT 擋住 | 已修正 | `OutputContractValidator.readLocalTranscript`，由 `HelperASRBackend`（`checkpointV2 != nil` 時）與引擎逐 root 完成處理共同使用；只有「root 精確覆蓋且全部 leaf 都是有效 verifiedSilence」才接受空檔，其他空白輸出維持失敗 |
| F2 靜音證據來源未驗證 | 已修正 | Swift 新增 `LocalSilenceValidation`／`VerifiedLocalSilence`；Python `FrozenSilencePlan.parse` 補上 source／PCM／normalization／covered range／enabled／truncated／detector／planner／intervals 檢查。兩邊各有契約變造測試；整數型別另以**同一份落盤檔案**交叉驗證判定與錯誤碼，見 §1.4 |
| F3 normalizationDigest 定義不一致 | 已修正 | producer 統一為完整 profile 的 canonical JSON SHA-256（`LocalDigest.sha256(LocalNormalizationProfile.current)`），與 `LocalCheckpointPlanner.freeze` 相同。舊的 version-only 定義現在是一個**拒絕**測試案例，不是預設值 |
| F4 外層與內層候選不一致 | 已修正 | 新增 `LocalSilenceScanner.makeOuterPlan`，start／cap／搜尋窗／終點全部在 Int64 sample 空間決定，秒數只存在於抽取 adapter。審查的反例（`[1197,1199]` 與 `[1198,1200]`）現在是測試，結果為 **1198.5 秒** |
| F5 A/B 未完成卻預設開啟 | 已修正 | `AppSettings` 與 `JobSnapshot` 的新安裝預設、缺欄解碼、`withEngineSettings` 同步路徑全部為 `false`，並有測試。設定頁文字改為「實驗性、預設關閉、可主動開啟、尚未通過 A/B 與人工核對」 |

### 1.2 這一輪新發現的兩個缺陷（審查未列出）

**F6／P1：`sliceStartSeconds` 寫成 canonical 字串，但用 synthesized `Decodable` 讀。**

`LocalSourceIdentity.canonicalValue` 依 canonical 規則把 `sliceStartSeconds` 寫成
`"5.000000"`，而型別只有 synthesized `Decodable`，它要求 JSON 數字：

```
DecodingError.typeMismatch: expected value of type Double.
Path: source.sliceStartSeconds
```

後果：**任何帶非零切片的地端 v2 工作，凍結出的 `identity.json` 自己讀不回來**。
階段 0 之後這只在續跑（`loadFrozenManifest`／`openOrFreeze`）發作；F1 的修正讓
`readLocalTranscript` 在每個 root 完成時也讀一次 identity，於是變成「切片工作在
第一個 root 完成時就中止」。與階段 1 已修掉的 `LocalSilencePlan` 問題同一類，
當時漏了 `LocalSourceIdentity`。

修正：明確的 `init(from decoder:)`，秒數走 `decodeCanonicalSeconds`（字串與數字都
接受），`sourceByteCount`／`workStartSample`／`workEndSample` 走
`StrictCheckpointDecoding.int64`（`true` 不可變成 `1`）。
回歸測試：`testASlicedIdentityRoundTripsThroughItsOwnCanonicalBytes`，同時固定
canonical 位元組型態、`null` 仍是 `nil`、以及布林座標被拒絕。

**F7／P1：`checkpointCommitted` 被當成 `invalid_jsonl`。**

`qwen_asr_local_checkpoint.RootStateStore.commit` 每次落地一個 leaf 就發一個
`checkpointCommitted` 事件，但 `HelperASRBackend.allowedEventTypes` 沒有這個型別，
於是**任何走真實 backend 的 v2 執行都在第一個 leaf commit 就中止**。這正是審查只能
「分層重現」F1、無法跑完整引擎 E2E 的原因：不是測試不夠，是通道本身不通。

修正：把 `checkpointCommitted` 加進白名單。它不是 `completed` 也不是 `error`，
所以不會終止串流；`HelperEventState.observe` 與引擎的事件轉送都有 `default: break`，
不會被誤讀成完成。白名單維持 fail-closed，未知型別照樣拒絕。

### 1.3 其他收緊

- **錯誤碼對齊**：Python 原本對 `sourceSHA256` 不符回報 `local_identity_mismatch`，
  Swift 的既有分類是 `local_source_changed`。同一份變造檔在兩邊被解釋成兩件事，
  已把 Python 對齊 Swift；兩邊測試現在都斷言錯誤碼，不只是「有拒絕」。
- **`VerifiedLocalSilence.validate` 自己就拒絕帶文字的 verifiedSilence leaf**。
  原本這條只在 `LocalCheckpointValidator.validateTerminalEvidence` 檢查，但階段 2
  會直接重用這個驗證器，所以它必須自足。
- **三個 loader 保留型別化錯誤**：`loadIdentity`／`loadManifest`／`loadRootState`
  過去把所有解碼失敗壓成 `invalidJSON`，strict 整數檢查的欄位名會被吃掉。現在已是
  `LocalCheckpointError` 的原樣丟出。
- **fake helper 的 `Audio.__getitem__` 支援開放切片**。token 遞迴用 `span[:mid]`／
  `span[mid:]`，舊的 stand-in 遇到 `None` 邊界就 TypeError，所以整合測試**從來沒有
  真正跑過一次 token 遞迴**。修好之後才可能寫出「左 child 完成、右 child 失敗」的
  引擎層測試。

---

### 1.4 獨立審查後修正：持久化整數的 Swift／Python 一致性

審查重現：用正式 Swift planner 凍結合法資料後，把 sample 改成 `0.0`、版本改成
`2.0`，或區間端點改成浮點表示，並同步更新 manifest 內的檔案 digest，Swift
`loadFrozenManifest` 仍接受，Python `load_silence_plan` 卻拒絕。原有各自建置的變造
測試沒有涵蓋這個差異；因此原本的「兩邊一致」證據並不完整。

修正內容：

- `LocalSilencePlan.decodePersisted` 在 typed decode 前，檢查原始 JSON 數字型別。
  `LocalSilenceValidation.load` 與 `LocalSilencePlanStore.load` 共用此入口，版本、
  sample 座標、計數與區間上限只接受 Int64 範圍內的 JSON 整數；拒絕浮點、指數、
  布林、數字字串、null 及溢位。Foundation 的 `decode(Int64.self)` 本身不足以
  執行這項規則，因為它接受整數值的浮點 token，甚至可能捨入極接近整數的小數。
- Python `_require_int` 補上 signed Int64 範圍檢查，避免 Python 任意精度整數讓
  超大計數通過，卻無法由 Swift 讀回。
- 秒數與耗時仍接受 canonical 字串或 JSON 數值，不因收緊整數欄位而改變契約。

`testPersistedIntegerRepresentationsAgreeWithPythonOnSharedBytes` 是一個 XCTest，
涵蓋 **113 份共用檔案案例**：正式 Swift freeze 的基準、12 個整數欄位各 9 種
非法表示，以及數值秒數、數值耗時、Int64 最大計數與整數 `-0` 四個合法控制組。
每份變造資料都有相符的檔案 digest；Swift production loader 與實際 Python
production loader 讀取完全相同的檔案，比對接受／拒絕及錯誤碼，並確認讀取後
靜音證據檔位元組不變。Python 另有 `test_integer_range_matches_swift_int64` 驗證
兩端界限及越界。這些案例不是 113 個額外 XCTest，也不取代真實模型 A/B。

## 2. H1–H5 對應的驗收證據

### H1 靜音證據契約

| 要求 | 證據 |
| --- | --- |
| 1. normalizationDigest 統一定義 | `testProvenanceAndContractMutationsAreRefused` 的 `normalizationDigest` 列（version-only hash 現在被拒絕）；Python 同一列 |
| 2. 工作 normalized PCM digest 明確持久化 | manifest `normalizedPCMSHA256`；`planLocalSilenceBoundaries` 寫入 `measurement.pcmSHA256`，`freezeLocalCheckpointV2` 寫入同一個值；續跑核對 `scanPCMSHA256` |
| 3. 共用驗證邏輯，兩邊一致 | Swift `LocalSilenceValidation.validate`（18 個變造案例）／Python `FrozenSilencePlan.parse`（11 個變造案例）驗證契約錯誤碼；另以 §1.4 的 113 份共用落盤檔交叉驗證整數型別與範圍 |
| 4. path 與 digest 成對必填 | `testTheSilenceReferenceIsAPairAndAnOrphanFileIsNotEvidence`：固定切點帶引用→拒絕；固定切點無引用→`nil`；silence 缺任一→拒絕；孤立檔不成證據 |
| 5. covered range 等於工作範圍 | `testProvenanceAndContractMutationsAreRefused` 的 covered range 列；`VerifiedLocalSilence.validate` 再核對 `evidence.coveredSpan == node.span` |
| 6. intervals 為有效整數、在範圍內、排序、已合併、不重疊 | reversed／unsorted／overlapping／out-of-range 四列；Python `{"startSample": True, ...}` 拒絕布林 |
| 7. truncated 要求空清單；未知 detector／planner 拒絕；門檻有限且符合支援策略 | truncated+intervals、unknown detector、unknown plannerVersion、negative search window、non-positive chunk、noiseProfile 兩列、negative metric、interval count 超過上限 |
| 8. 路徑相對 v2 根目錄解析 | `testASilencePlanPathThatEscapesTheCheckpointRootIsRefused`（`../../`、絕對路徑、中段跳脫）；Python 端既有 10 個 traversal 測試 |
| 9. 接到 production | `LocalCheckpointPlanner.freeze` 首次凍結前；`loadFrozenManifest`／`openOrFreeze` 續跑載入；helper 首次 generate 前；`verifyLocalCheckpointV2Root` 與 `mergeLocalCheckpointV2` 接受 root 前。驗證失敗不走 fixed fallback |
| 10. silenceEvidence 記錄 silencePlanDigest | `testALeafIsSilenceOnlyWhenTheFrozenPlanProvesItsWholeSpan`（10 個拒絕案例，含「另一個計畫的 digest」「未記錄 digest」「部分涵蓋」）；`testVerifiedEvidenceIsBoundToThePlanItWasLoadedFrom`；Python `test_existing_silence_leaf_must_bind_to_the_same_evidence` |

### H2 全靜音 root

`testWholeSilentRootBetweenSpeechRootsPublishesThroughRealBackend`：三段 120 秒，
中間整段靜音，走**真實 `HelperASRBackend` + `TranscriptionEngine` + 真實 Python
checkpoint writer**，只有推論是 stub。正式稿保留 root A／C，沒有虛構缺稿標記，
`containsSkippedAudio == false`，detector 只掃一次，三個 root 各 generate 一次。

`testAllSilentWorkKeepsEvidenceButDoesNotPublishEmptyTranscript`：整份工作全靜音時
state 全部是 `verifiedSilence` 且可驗證，但不發布空正式稿，維持 `noSpeechContent`。

### H3 外層同一份候選

- `testTheOuterPlanSelectsTheMergedCandidateSoEveryLayerAgrees` — 審查 F4 的反例，
  結果 1198.5 秒，三段精確鋪滿 2400 秒
- `testTheOuterPlanHardCutsOnTheCapWhenNoCandidateIsInRange` — 無候選硬切，覆蓋不變
- `testTheOuterPlanIgnoresCandidatesOutsideItsSearchWindow` — 30 秒窗外的停頓不移動切點
- `testTheOuterPlanTilesExactlyFromANonZeroWorkStartWithOddLengths` — 非零切片、奇數
  sample 數、秒數仍相對 normalized PCM（不套兩次 offset）
- `testTheOuterPlanRefusesADegenerateRange` — 退化範圍是拒絕，不是零段計畫

**H3.5 的真實 ffmpeg fixture**：
`testRealFFmpegExtractionAtFractionalBoundariesReassemblesTheExactPCM`。
112,001 sample（7.0000625 秒，非整秒）的位置相依 payload，用 `makeOuterPlan` 產生
邊界 `39999 / 87999`（奇數 sample），以引擎實際使用的 `FFmpegService.extractSegment`
抽取三段，再串接比對：

- 每段的 `startSeconds`／`endSeconds` 重新量化後必須等於計畫的整數 sample 邊界
- 每段解碼出的 sample 數必須等於計畫長度
- 串接後的 payload 與原始 normalized PCM **逐位元組相同**（digest 與 `Data` 都比）

結果：`%.6f` 的秒數表示在奇數 sample 邊界上仍然是 sample-exact，**抽取 adapter
不需要修改**。這條現在是測試而不是假設；若未來改了 `ffmpegTime` 的精度或抽取參數，
它會直接失敗。

### H4 引擎層測試表

| 必測情境 | 測試 |
| --- | --- |
| detector 一般錯誤 | `testDetectorFailureFallsBackOnceAndLogsMeasuredCost`：warning 恰好一次、首次計畫為 fixed、無 silence 引用、log 含 `silence_scan_count=1` 與 `fallback_reason=detector_error` |
| detector 取消／來源／checkpoint 錯誤 | `testDetectorCancellationAndIdentityErrorsStopBeforeInference`：三種錯誤都向上停止，`generate == 0`，不寫 manifest，不記一般 fallback |
| 偵測成功空集合 | `testASuccessfulEmptyScanPersistsAValidEmptyPlanAndAResumeDoesNotRescan`：掃一次、無 `local_silence_scan_failed`、log 可區分空集合與失敗、持久化 `intervals: []` 且 `truncated: false`、邊界在固定格上、production loader 接受、續跑不重掃且 manifest 位元組不變 |
| true↔false 凍結後切換 | `testFrozenPlanSurvivesBothSettingChangesWithoutRescanningOrRegeneratingCompletedRoot`：雙向都驗，planID／roots／manifest 位元組不變，detector 0 次，只 generate 未完成的那一段 |
| 非零切片＋跨 root group | `testNonzeroSliceRendersOneGroupAcrossTwoRoots`：slice 5 秒起、1210 秒，root 邊界落在 1190 秒，`[00:10:05 - 00:20:05]` 標題恰好一個，無二次 offset |
| 左 child 完成右 child 失敗後續跑 | `testAFailedRightChildResumesWithoutReplanningOrRegeneratingTheLeft`：parent 為 `split`、左 child `completed` 且 node 物件逐欄位不變、續跑只 generate `960000`、manifest 位元組不變、split parent 的截斷文字不出現在正式稿 |
| 全靜音 root 夾在兩個有文字 root | `testWholeSilentRootBetweenSpeechRootsPublishesThroughRealBackend` |
| 整工作全靜音 | `testAllSilentWorkKeepsEvidenceButDoesNotPublishEmptyTranscript` |
| 靜音檔缺失／digest 不符／來源不符／越界 | Swift `testTheSilenceReferenceIsAPairAndAnOrphanFileIsNotEvidence`、`testASilencePlanPathThatEscapesTheCheckpointRootIsRefused`、`testATamperedSilencePlanIsRefused`、`testProvenanceAndContractMutationsAreRefused`；Python `SilenceHardeningTests` 與既有 traversal 測試 |
| 區間超過保存上限 | `testATruncatedScanKeepsTheCutPlanAndDropsTheIntervalList`、`testATruncatedPlanIsValidButProvesNoLeafSilence`（丟掉清單後不可再當靜音證據）；Python `test_a_truncated_plan_falls_back_to_legal_midpoints` |

### H5 實驗期預設與可觀察性

- `testLocalSilenceSegmentationStaysOptInUntilTheABReleaseGatePasses`：新安裝
  `AppSettings` 為 false、新 `JobSnapshot` 為 false、true/false 都能round-trip，
  且經 `withEngineSettings`（佇列工作重新同步的實際路徑）不被翻轉
- `testLegacySettingsAndSnapshotDefaultToSafeCloudPolicies` 補上缺欄解碼為 false，
  同時確認雲端 `silenceAwareCloudSegmentation` 的預設**沒有**被連動改動
- 掃描成功／失敗／空集合三者可區分：失敗記 `silence_scan_count` 與
  `fallback_reason=detector_error`；空集合的 log 是「0 段靜音、0 個候選切點」且
  不發 warning
- helper 遞迴統計改在 `finally` 輸出，右 child 失敗也保留左側切點紀錄
  （Python `test_failed_recursion_still_logs_cut_counts_and_keeps_left`）
- 計數定義：**「因候選而移動的切點」**。切點恰好落在上限（包含中點恰與候選相等）
  算 fallback，不算 silence cut，所以這組欄位不可解讀成停頓命中率。定義寫在
  `LocalBoundaryDecision.usedSilence` 與 `LocalSilenceScanner.countOuterCuts`

---

## 3. 檔案變更

### 新增（本輪）

- `Sources/RecordToTextCore/LocalSilenceValidation.swift`

### 修改（本輪，Swift）

- `ASRBackend.swift`（`checkpointCommitted` 白名單；v2 完成檢查改用 `readLocalTranscript`）
- `LocalSourceIdentity.swift`（明確 `init(from decoder:)`）
- `LocalCheckpointValidator.swift`（保留型別化錯誤；normalizationDigest 核對）
- `LocalSilencePlanner.swift`（`makeOuterPlan`）
- `LocalCheckpointManifest.swift`（`normalizedPCMSHA256`、`silencePlanDigest`／`RelativePath`）
- `TranscriptionEngine.swift`（外層改用 `makeOuterPlan`；normalizationDigest 統一定義；
  掃描失敗／取消／來源錯誤分類；凍結與驗證接上 `LocalSilenceValidation`）
- `OutputContractValidator.swift`（`readLocalTranscript`）
- `Models.swift`（`localSilenceAwareSegmentation` 預設 false）
- `SettingsView.swift`、`AppViewModel.swift`（實驗性文案與同步）

### 修改（本輪，Python helper）

- `qwen_asr_local_checkpoint.py`（`FrozenSilencePlan.parse` 完整契約檢查；
  `sourceSHA256` 錯誤碼對齊 Swift）
- `qwen_asr_mlx_runner.py`（`record_empty_leaf` 綁定 `silencePlanDigest`；
  遞迴統計移到 `finally`）
- `qwen_asr_chunking.py`（候選索引與 `silence_choose_split`）

### 測試

- `LocalV2IntegrationTests` 4 → **12**（本輪 +2：空集合掃描、左完成右失敗續跑）
- `LocalSilencePlannerTests` 47 → **60**（+5 外層 sample 空間、+7 證據契約、+1 共用檔案整數一致性）
- `LocalCheckpointV2Tests` → **65**（+1 切片身分 round-trip）
- `LocalV2PipelineTests` → **29**（+1 真實 ffmpeg 抽取）
- `CloudTranscriptionModelsTests` → **6**（+1 實驗期預設）
- `qwen_asr_local_checkpoint_test.py` 78 → **82**（含新增 Int64 邊界測試）

---

## 4. 仍未驗證（需要真實模型／真實音訊／人工）

這些項目**沒有**被本輪的自動化測試涵蓋，也不能由它們推論：

1. **真實模型 A/B**（審查 §4）。本機 `~/mlx-audio-env/bin/python` 已可載入 `mlx_audio`，但尚未執行真實模型推論或 A/B。需要
   同模型 revision、同 runtime、同 prompt／terms、同 token 預算、同素材，基準與
   實驗各開**新工作**（不可沿用同一 frozen plan），涵蓋多人連續講話、低音量／
   遠距離、背景噪音／音樂、專有名詞、中英混用，並由人工核對每個被移動切點前後
   ±5 秒。交付 `docs/qwen-local-01-ab-results-<日期>.md`。
2. **預設放行**。A/B 未通過前維持「進階設定可主動開啟、新工作預設關閉」。
   放行才改預設，且要有明確放行紀錄。
3. **`-35dB`／`0.35 秒` 是否適合弱音、遠距離、背景音樂素材**：未實測。兩個數字在
   文件與程式註釋中都標為工程預設值。
4. **30 分鐘／173 分鐘 fixture 的掃描與推論耗時**：未量測，本輪只把掃描耗時單獨
   記為 info log，沒有做時間斷言，也沒有提出任何未量測的效能百分比。
5. **App bundle 建置與安裝**：完整自動化檢查依 `SKIP_APP_BUNDLE=1` 跳過；其後另行建置並安裝本機測試版，見 §6。公開發版與人工 GUI 驗收仍未執行。

---

## 5. 下一階段

階段 1.1 的完成定義（審查 §5）中，可自動化的項目全部成立；不可自動化的 A/B 與
效能項目已記錄為未執行，依規格不阻塞其他工作。

[階段 2：段級續跑與前處理跳過](qwen-local-02-segment-resume-spec-2026-09-27.md)
可以直接站在兩個前提上：

- 續跑絕不重算已凍結邊界（`loadFrozenManifest`／`segmentPlan(from:)`，已有雙向
  設定切換測試）
- 靜音證據的 Swift 完整驗證已存在且自足（`VerifiedLocalSilence.validate`），
  全完成／全靜音 root 可以在不啟動 helper、不要求重建 WAV 的情況下分類

---

## 6. 本機測試 App 安裝（2026-09-27）

依使用者要求，`Config/version.env` 的預設 build number 從 7 升至 8，
以 `CONFIGURATION=release ./scripts/build-app.sh` 建置，安裝並啟動
`/Applications/record-to-text.app`。安裝前已正常退出原本執行的 build 7；
工作紀錄當時只有完成或失敗項目，沒有進行中的工作。舊 App 留在
`dist/install-backups/before-qwen-phase1-build8-20260927/` 供回復。

| 安裝核對 | 結果 |
| --- | --- |
| 版本與架構 | 0.2.1（build 8）、arm64、約 135 MiB |
| `verify-release.sh` 封裝檢查 | dist、安裝前暫存與安裝後 App 均通過；四個 Python helper、ffmpeg／ffprobe 齊全，無 Python bytecode |
| 簽章 | dist 與安裝後均通過 `codesign --verify --deep --strict`；ad-hoc 簽章，不是公開發行簽章 |
| 執行檔一致性 | dist 與安裝後 SHA-256 均為 `b27c504d7f5995d8831fdcdef6ae0d55c52ede98ede35e11cf41cca5ad897c9c` |
| 新 helper 位元組 | 封裝的 `qwen_asr_local_checkpoint.py` SHA-256 與工作區來源一致 |
| 啟動與 Runtime | 安裝後 App 程序正常運作；`~/mlx-audio-env/bin/python -B -c 'import mlx_audio'` 成功 |

這次沒有執行真實模型轉錄、A/B、DMG 公開發版或人工 GUI 驗收。
要測試新的靜音切點，請在 App 設定中開啟「實驗性：本機切塊優先尋找靜音切點」，
再新增地端 Qwen 工作；設定預設為關閉，已凍結工作不會因切換而重新規劃。
