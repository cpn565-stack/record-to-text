# 階段 2：地端段級續跑與前處理跳過

日期：2026-09-27

狀態：待實作規格。

前置：[階段 0](qwen-local-00-identity-spans-spec-2026-09-27.md)、[階段 1](qwen-local-01-silence-boundaries-spec-2026-09-27.md)；下一階段：[缺口補稿](qwen-local-03-gap-repair-spec-2026-09-27.md)。

## 1. 成果定義

已完成 root 直接沿用結構化文字，不重做 normalize／extract、不要求載入該段音訊、不啟動該段 ASR。只為尚未完成 root 準備音訊；root 內已提交 leaf 也不重算。

來源全內容 hash 與 checkpoint 檢查仍須執行，不能把「跳過前處理」解讀成零 I/O。全完成的續跑只需驗證、合併、OpenCC、原子發布，不應啟動 Python／MLX。

## 2. 續跑資格

建議新增 `LocalResumeCheckpointLoader`，在背景依階段 0 做完整驗證後產出不可變 `LocalResumePlan`：

| 分類 | 行為 |
| --- | --- |
| root 全部 completed／verifiedSilence | `reuseTextOnly` |
| root 含 gap、沒有 pending／failed | 一般續跑保留 gap 與既有結果；不是自動補稿 |
| root 有 pending／failed／未提交 running | `prepareAudioAndResumeLeaves`，只推論未完成 leaf |
| 來源／推論 identity 不符 | 拒絕續跑，不局部沿用 |
| checkpoint text hash／結構不符 | 拒絕自動續跑、保留原資料；不把損壞文字降級成已完成 |
| 合法 checkpoint 但 WAV 遺失／毀損 | 捨棄該音訊快取引用，重建必要範圍；文字結果仍有效 |

來源、manifest、displayGroups、node tree、每個已提交 text digest／輸出契約全部驗證。`completedEventCount` 或檔案存在只能作輔助，不能取代內容證據。

只缺重組用的 root TXT 時，可從完整 leaf state 重新生成；缺少 leaf state 的舊 TXT 不能反向猜出 v2 結果。

## 3. 調度次序

```text
讀取／驗證來源與 checkpoint
→ 建立 LocalResumePlan
→ 建立獨立 child 工作及 recovery 副本，durable 保存
→ 沿用所有合法已完成 leaf
→ 對需要的 root：挑音訊來源 → 驗證 PCM → helper 只做未完成 leaf
→ 全範圍覆蓋驗證 → 每十分鐘排版 → OpenCC → 原子新檔 → 保存完成狀態
```

- 復用判斷必須移到目前全檔 normalize／逐段 extract 之前；不能在音訊都準備完之後才 `continue`。
- `canResumeLocalQwenJob` 的 UI 快速檢查只表示「可能有 checkpoint」；真正開工前還是要做背景完整驗證。
- 已完成 root 不傳 request 給 helper；不可透過 helper 載入模型／音訊後再發現全部已完成。
- 部分 root 的 request 明確列出需要的 node IDs 與 manifest revision；helper 不能自行從頭建立新的切分方案。
- 若所有文字已完成但前次卡在 OpenCC／發布，直接重組輸出，ASR 呼叫數為零。

## 4. 音訊重建策略

按照以下順序選擇，每個來源都要符合 normalization identity 與該 root 的 PCM digest：

1. 已存在且驗證成功的 root WAV：直接使用，extract=0。
2. 已存在且驗證成功的 normalized 工作 WAV：只抽取需要的 root；已完成 root extract=0。
3. 無可用 WAV：從階段 0 的已驗證來源 snapshot 解碼需要的 root，校準 sample 起訖並比對預存 root PCM digest。
4. 部分 codec／seek／resample 路徑無法重現相同 PCM 時，允許**一次、明確記錄的全工作 normalize fallback**，再只抽取未完成 root。不能反覆 normalize 嘗試湊 hash。
5. fallback 後仍不符：`local_pcm_mismatch`，停止並保留結果，不用等長 WAV 冒充相同音訊。

直接 `ffmpeg -ss/-t` 不足以證明 sample 相同。實作要針對支援的 M4A／MP3／AAC／FLAC／WAV 建立實際 codec fixture，驗證 decoder delay、seek preroll、resample 與裁切語意；以解碼 payload digest 為最終準則。

已知不支援精確直接重建的 codec/profile 可直接進第 4 步，避免先做一次必然失敗的解碼。能力表須有測試證據，不能只依副檔名猜測。

部分 root 可重建／載入整個 root 以便 PCM 驗證，**本階段不承諾只解碼未完成的 30 秒 leaf**。leaf 的 GPU 推論仍只執行尚未提交部分。

## 5. 狀態、進度與取消

- `LocalResumePlan` 同時列出重用 root／leaf 數、待處理 sample 數、已知 gap sample 數與音訊來源決策。
- 進度以已處理 sample 範圍計算，不以新舊 root 數均分；重用不能導致倒退，正式發布前不显示 100%。
- 顯示「已沿用 X 段，準備剩餘 Y 段」；不要把來源 hash 階段標成正在模型推論。
- 取消在 hash、複製、extract、helper、OpenCC、發布各步都傳遞。沒有提交 leaf 的晚到結果不能改寫取消後的新 revision。
- child 工作寫入 ledger 成功後才開工；重複點擊只得到一個 active child，parent 原稿與 checkpoint 不變。
- 不修改既有 cloud continuation 的語意。可重用其 parent/child durable 保存原理，但本機 eligibility 與 loader 必須獨立。

## 6. 快取與保存

- WAV 與來源 snapshot 為可回收的大檔快取；manifest、identity、leaf text 是恢復證據，不可由磁碟空間清理順帶移除。
- 音訊快取移除必須原子更新引用，不能把刪 WAV 當成丟失已完成工作。
- 工作執行中所引用的 recovery root 不可被掃描清理；parent/child 引用也要列入保護。
- 完整無缺口且發布／ledger 已 durable 的工作才可清理本機恢復證據；含缺口保留規則依階段 3。階段 3 尚未實作前，不新增「能補缺口」的 UI 承諾。
- 改 decoder／normalization profile 的新版本不能默默混用舊 WAV。只有完整相容驗證通過才沿用；否則清楚拒絕並讓使用者另建新工作。

## 7. 量測

記錄每次續跑的 `source_hash_ms`、`snapshot_ms`、`checkpoint_validation_ms`、`normalize_calls/ms`、`extract_calls/ms`、`decoded_audio_seconds`、`audio_load_calls`、`model_load_calls`、`generate_calls`、`reused_root_count`、`reused_leaf_count`、`normalization_fallback_reason`。

固定切點 173 分鐘 fixture：共 9 個 root；前 8 個完整，第 9 個部分完成。

- 有有效 normalized WAV：normalize=0、前 8 段 extract=0、第 9 段最多 extract=1；generate 只涵蓋第 9 段未完成 leaf。
- 有有效第 9 段 WAV：normalize=0、extract=0。
- WAV 全遺失：精確直接重建成功時只解碼第 9 root；必要 fallback 時 normalize≤1，前 8 段 extract 仍為 0。
- 全部完成只剩發布：normalize=0、extract=0、Python／model／generate=0。

靜音模式 root 數可能不同，測試依 persisted plan 分類，不硬寫成 9。baseline／新版本各跑至少三次，分別報告冷／熱快取與中位數，不把來源 hash 省略以製造加速數字。

## 8. 測試與實作位置

1. spy 證明已完成 root 的 ffmpeg、audio load、helper request 都是 0；部分 root 已完成 leaf 的 generate 是 0。
2. normalized WAV 不存在、root WAV 毀損、來源變更、文字被改、manifest 失效各走正確分支。
3. PCM 直接重建不符只允許一次 normalize fallback；第二次不符停止，沒有無限迴圈。
4. 非零 source slice、靜音變長方案、跨小時、遞迴完成一半後取消，恢復稿與連續執行的範圍／文字順序相同。
5. 全完成 checkpoint 且模型 runtime 不可用：只重組 TXT 時不得因不需要的 MLX 檢查而阻擋；ffmpeg 是否需要依來源驗證／快取需求判斷，OpenCC 仍必須可用。
6. publication intent 已存在、App 崩潰後重啟：依既有發布協定認領完成輸出，不多生一份結果或重開 ASR。
7. checkpoint 提交／child ledger 保存／原子輸出各邊界 fault injection；parent 與已提交葉節點不被破壞。

主要調整：[TranscriptionEngine](../Sources/RecordToTextCore/TranscriptionEngine.swift)、[AudioServices](../Sources/RecordToTextCore/AudioServices.swift)、[AppViewModel](../Sources/RecordToTextApp/AppViewModel.swift)、[RuntimeEnvironment](../Sources/RecordToTextCore/RuntimeEnvironment.swift)、[OutputPublicationStore](../Sources/RecordToTextCore/OutputPublicationStore.swift)、階段 0 的 loader／manifest 與 helper。
