# 階段 0：音訊身分驗證與實際切塊起訖紀錄

日期：2026-09-27

狀態：待實作規格；本輪基礎契約。

前後關係：[總覽](qwen-local-roadmap-spec-2026-09-27.md) → 本文件 → [階段 1](qwen-local-01-silence-boundaries-spec-2026-09-27.md)。

## 1. 目標與界線

將「長度與設定相同」提升為「來源內容、轉換方式、推論設定與實際區間均相符」的續跑驗證。保留現行 1,200 秒／120 秒固定切塊，先建立可支援後續變長切點與定點補稿的資料契約。

本階段不啟用靜音切分、不加速前處理、不新增補稿按鈕；不因新欄位存在就宣稱已具備後三階段行為。

## 2. 來源與音訊身分

| 欄位 | 語意／驗證 |
| --- | --- |
| `sourceSHA256` | 原始檔案全部 bytes 的 SHA-256；不是檔頭、抽樣或路徑 hash |
| `sourceByteCount` | 原始檔案大小；快速排除用，不能取代 hash |
| `sourceLocator` | 找檔提示；路徑改變不等於內容改變，但 v1 不新增重新選檔 UI |
| `workStartSample` | 原始錄音座標，16 kHz；由 source slice 起點量化一次 |
| `workEndSample` | `workStartSample + 實際 normalized PCM sample 數` |
| `normalizationProfileID` | 版本化的 16 kHz、mono、signed PCM16 little-endian、選軌、切片／seek／resample 規則 |
| `decoderIdentity` | 實際 ffmpeg 版本／build 與相關參數簽章；不是只記可執行檔路徑 |
| `pcmSHA256` | 各 root 實際送入 ASR 的標準 PCM payload hash，排除 WAV header／metadata |

Swift 重用 [FileIntegrity](../Sources/RecordToTextCore/FileIntegrity.swift) 的串流 hash 原理，補背景執行、取消檢查與讀取錯誤傳遞。每批讀取建議 1 MiB；不得把整個音檔載入 RAM，也不得在 MainActor 同步 hash。

### 2.1 來源在執行中被修改

1. 準備音訊前建立 App 私有、不可由其他工作共寫的來源 snapshot：可用 copy-on-write clone，無法 clone 才串流複製。正常處理 snapshot，不直接反覆讀會被外部覆寫的原檔。
2. hash snapshot，並與當次原始檔全內容 hash 核對；既有工作還須符合 manifest 的 `sourceSHA256`。複製／hash 前後檔案屬性變化或內容不符則停止；不接受一次不穩定讀取。
3. 發布新正式稿前再核對原始檔 hash。中途變更時保留 snapshot 的已提交結果及原因，但不得混入新來源或宣稱已為新來源完成。
4. 只重組全部已完成文字的續跑不需建立音訊 snapshot，但仍需驗證當前來源 hash。
5. 原始檔不存在／不可讀：允許取回既有草稿與正式稿；本版不開始新推論或宣稱來源已驗證。來源替換則明確拒絕續跑，可另建從頭轉錄工作。

屬性只能輔助偵測；跨次執行不得因 path／size／mtime 相同省略全內容 hash。snapshot 防止管線混讀，並不宣稱對抗可任意修改 App 私有資料的惡意程序。

## 3. 座標契約

- 持久化全部音訊邊界使用 64-bit 整數 sample，`sampleRate=16000`，區間一律半開 `[startSample, endSample)`。
- `source slice` 起點以 `floor(seconds * 16000 + 0.5)` 量化；記錄原值與量化值，之後不得重複量化或累加浮點秒。
- root／chunk／leaf／displayGroup 的 start/end 都是**原始錄音的絕對 sample 座標**。Python array index = absolute sample − 當前載入音訊的 `audioStartSample`。
- `ffprobe` duration 只供預估；以實際解碼 sample 數決定工作終點。不得按容器 duration 強補不存在的尾音，或把明顯短解碼視為正常尾段；差異超過 100 ms 要報錯並保留診斷，此值為待實測的保守預設。
- `[start,end)` 必須有限、非負、start < end、位於工作範圍內。Python `bool` 不接受作 integer；Swift 解析不得溢位。
- TXT 可格式化至秒；底層驗證仍以 sample 精度為準，不使用顯示字串反推切點。

例：切片從 1,800 秒開始，root 從切片相對 1,200 秒開始，leaf 從 root 相對 120 秒開始，leaf 絕對起點為 3,120 秒（00:52:00）。只能做一次上述換算。

## 4. 推論相容性

`inferenceIdentity` 至少包含 model ID／pinned revision、local model manifest digest、language、完整 prompt 與 terms 的內容摘要、maximumTokens、有效 sampler 設定、MLX／MLX-Audio 版本與 `asrContractVersion`。

- 本地模型不能只以資料夾路徑作身分；無可驗證的模型內容 manifest 時不得跨執行自動沿用結果。
- `allowMissingPrompt` 及真正採用的 prompt channel 要記錄，避免把有詞庫／無詞庫結果混用。
- `planID`／planner version 與 normalization identity 分開保存，再納入 root 的相容性驗證。
- 輸出路徑、工作 UUID、十分鐘排版版本、OpenCC 輸出選項不是 ASR 內容身分；這些變更允許重組輸出，不能因此重新推論。
- Swift 產生版本化 identity JSON 的固定 UTF-8 bytes，Python 直接對同一份 bytes 算 digest 並解析；不各自重編 JSON 後期待雜湊相同。保存 canonical bytes 供測試核對。
- 任何影響辨識的欄位不符皆拒絕混用；顯示原因，使用者可另建完整新工作，不默默重設舊 checkpoint。
- 只重組全部既有文字時，比對原工作快照與已保存 inference identity 即可，不要求重新載入模型、讀取權重或啟動目前 MLX runtime。只有要新增推論時才驗證當前 runtime／模型與原契約相符。

## 5. v2 目錄與資料格式

使用新的 `Temp-Recovery/<job UUID>/local-checkpoint-v2/`，不覆寫既有 `chunk-checkpoints/*.chunks.json`。

```text
local-checkpoint-v2/
  identity.json             # Swift 寫，已固定的推論與來源契約
  manifest.json             # Swift 寫，來源、工作範圍、root plan、displayGroups
  roots/<rootID>.json       # Python 寫，該 root 的 chunk／leaf 樹與提交狀態
  audio/<rootID>.wav        # 可選、可清除的音訊快取；不是續跑唯一證據
```

| 結構 | 必填資料 |
| --- | --- |
| manifest | schemaVersion=2、jobID、identity digest、sampleRate、work start/end、normalization identity、planID／version、roots、displayGroups |
| root plan | 穩定 rootID、order、絕對 start/end、PCM digest、initial chunk IDs／邊界、root file 相對路徑 |
| root state | schemaVersion=2、identity digest、planID、rootID、單調 revision、完整 node 清單 |
| node | 穩定 nodeID、parentID、start/end、splitDepth、state、children IDs、attempt 記錄 |
| 終端 leaf 結果 | text（原始辨識稿）、text SHA-256、PCM digest、generationTokens、finish evidence、gap reason／error code |
| displayGroup | groupID、start/end；只影響排版，leaf 必須能明確歸屬 |

rootID／nodeID 在首次規劃時產生並持久化，不能因插入子段或新工作而重新按 index 編號。`planID` 是固定順序的初始方案 canonical bytes 的 SHA-256，涵蓋 IDs、sampleRate、工作範圍、root／chunk／displayGroup 邊界、PCM digests 與 planner policy；不得只是隨機 ID。遞迴 split 不改初始 planID，另外在 root revision 保存完整子樹與採用的 split policy。

node state：`pending → running → completed | verifiedSilence | gap | failed | split`。`split` 必有兩個子節點，其聯集精確等於父範圍；父節點的截斷文字不能進正式稿。重啟後未提交的 `running` 視為 pending，不能當完成。

### 5.1 終端狀態語意

- `completed`：非空可用文字、輸出契約通過、可信 token／finish 證據且未達上限。缺少 token 計數不能沿用目前「當成 0」的行為。
- `verifiedSilence`：空文字且有與該 leaf 完整範圍相符的靜音證據。本階段尚未接分析時不會自動產生此狀態；階段 1 才可寫入。
- `gap`：token 上限等已定義可保留缺口原因。必須記錄範圍與原因；內容不是已完成文字。
- `failed`：其餘不可交付情形，包括無靜音證據的空結果、純 prompt echo、無效輸出或缺少完成證據；目前工作停止並保留其餘 leaf。
- 完成覆蓋檢查包括 completed／verifiedSilence／gap，不能把空字串、missing node 或 split 父節點當成覆蓋成功。
- root 可由 leaf 推導為 completed、completedWithGaps 或 incomplete；不信任單一布林欄位或百分比。

### 5.2 提交與並行

每次 leaf 完成／split 都先寫 root state 到同目錄暫存檔，flush／fsync、原子 rename，才發出帶 rootID／revision／nodeID 的 committed 事件。父轉 split 與兩子 pending 必須是同次提交，不能只寫出左子。

manifest、identity 寫入後凍結；一個 root state 同時只允許一個 helper writer。Swift 只讀／驗證 root state，不另寫同一份檔案。重送工作使用獨立 child recovery 副本，禁止原地修改 parent 或用可共寫 hard link。

事件遺失但 root state 已合法提交可恢復；只有事件、沒有檔案提交不得沿用。revision 回退、重複完成、內容 hash 不符、交錯 jobID／rootID 都拒絕。

## 6. 時間戳與輸出

- 本階段 displayGroups 為工作起點起每 600 秒，尾段取實際終點；不是原始錄音整分時鐘的硬對齊。
- 合併器依絕對 leaf 範圍排序，驗證全覆蓋，再按 displayGroups 排版；不能用 `index * 120` 或 `segmentIndex * 1200` 重建位置。
- 短於十分鐘的尾段與未完成草稿只標到實際已提交 leaf 終點；尚未完成範圍不得放到已完成標題內。
- 原始 checkpoint text 不混入時間標題／缺口顯示字串；marker 從結構化 gap 產生。OpenCC 後原始與繁體稿使用同一個時間方案。
- 全部空白／只有 gap 或靜音標記，不得因標題非空就通過正式文字驗證。

## 7. v1 相容與安全降級

| 輸入 | 處理 |
| --- | --- |
| 合法 v2 且來源／設定相符 | 允許續跑 |
| v1 只有長度／設定 fingerprint | 可取回舊草稿；不自動續跑、不補寫當前 hash 假裝舊結果已驗證 |
| v1 有另存 WAV | 仍不足證明舊文字與當前來源對應；保留人工參考，本版不做推定遷移 |
| 未知版本／破損 v2／來源不符 | 拒絕沿用，保留原資料並說明原因 |
| v2 音訊快取遺失 | checkpoint 不因而損壞；依階段 2 規則重建需要的音訊 |

錯誤分類建議：`local_source_changed`、`local_identity_mismatch`、`local_checkpoint_invalid`、`local_checkpoint_legacy_unverified`、`local_pcm_mismatch`、`local_empty_unverified`。不提供略過身分驗證的靜默 fallback。

## 8. 安全、保留與實作位置

目錄權限 0700、含文字／音訊檔 0600；相對路徑須限制於 recovery root，拒絕 traversal／symlink 逃逸。日誌只記範圍、原因、時長，不列全文 prompt、詞庫或逐字稿。更新 RecoveryScanner allowlist 與版本辨識，不能把新目錄誤判為垃圾。

建議新增 `LocalSourceIdentity`、`LocalCheckpointManifest`、`LocalCheckpointValidator`；調整 [ASRRequest](../Sources/RecordToTextCore/ASRBackend.swift)、[LocalChunkCheckpoint](../Sources/RecordToTextCore/LocalChunkCheckpoint.swift)、[TranscriptionEngine](../Sources/RecordToTextCore/TranscriptionEngine.swift)、[RecoveryScanner](../Sources/RecordToTextCore/RecoveryScanner.swift) 與兩個 Python chunk／runner 模組。雲端 manifest 保持原語意，不把地端 v2 偷塞成雲端可讀格式。

## 9. 驗收

1. 同路徑、等長音訊替換，甚至還原 mtime：續跑拒絕；同 bytes 的來源路徑提示變動不改內容 digest。
2. hash／複製途中取消或來源變動：不啟動 ASR、不寫假的已驗證 manifest。
3. 語言／詞庫／model revision／有效 prompt channel 改變拒絕沿用；只改輸出位置／排版不重跑 ASR。
4. 非零切片、第二 root、跨小時、兩層 split、尾端不足一秒：sample 覆蓋精確，offset 不重複。
5. 存檔前／rename 後／事件前強制終止：最多重算尚未提交 leaf，已提交文字只出現一次。
6. 亂序、重疊、遺漏、越界、偽造 digest、bool／浮點 sample、路徑逃逸都被拒絕。
7. 第一個子 leaf 成功後第二個失敗：第一個可恢復，不退回整個 120 秒 chunk 重算。
8. 空文字無靜音證據、純 echo、missing token count 不被標為正常完成；合法 gap 有精確範圍。
9. v1 保留可取稿且禁止自動續跑；未知 v3 不誤讀。v2 可在 helper 未載模型時完成結構驗證。
10. 記錄 30 分鐘／173 分鐘素材的 hash、snapshot、checkpoint 大小／寫入成本；結果為量測，非固定加速承諾。
