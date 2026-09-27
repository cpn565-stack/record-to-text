# 階段 1：Qwen 地端靜音感知切點

日期：2026-09-27

狀態：待實作規格。

前置：[階段 0 的身分與區間契約](qwen-local-00-identity-spans-spec-2026-09-27.md)驗收完成；下一階段為[段級續跑](qwen-local-02-segment-resume-spec-2026-09-27.md)。

## 1. 預期行為

在原先切點附近找停頓，降低字詞被切成兩半的機會。每一個 sample 仍恰好屬於一個終端區間，不能把靜音偵測變成刪除低音量對話的機制。

這一階段涵蓋三層：Swift 外層最長 1,200 秒、Python 初始最長 120 秒、token 超限遞迴切分。只接上外層 `SilenceAwareSegmentPlanner` 不算完成。

## 2. 設定與方案版本

- 新增本機獨立設定／snapshot 欄位 `localSilenceAwareSegmentation`，新工作預設開啟；不可挪用 `silenceAwareCloudSegmentation` 改變雲端行為。
- 有 v2 checkpoint 的舊工作以持久化 `planID` 為準；設定改變只影響新工作。沒有新欄位、尚未開始的舊佇列快照解碼為 false，保留原排隊語意。
- planner version：固定切點 `local-fixed-v2`，靜音方案 `local-silence-v1`。版本與所有門檻寫入 manifest；續跑不得暗中重算已存在的 root／chunk／displayGroup。
- 允許進階設定關閉此功能，作為 A/B 與新工作的回退方式；不是失敗後自動換方案。

## 3. 靜音分析

重用 [SilenceDetectionService／SilenceAwareSegmentPlanner](../Sources/RecordToTextCore/SilenceAwareSegmentation.swift) 與 [JobSilenceAnalysisCache](../Sources/RecordToTextCore/JobSilenceAnalysisCache.swift) 的 parsing、取消、範圍覆蓋與統計，不直接假定其現有 source-relative 座標可當本機 sample 使用。

1. 優先分析已由階段 0 驗證的 normalized PCM。偵測與推論使用同一軌、同一混音與取樣率；若共用服務目前只接來源檔，要擴充 adapter，不能兩套音訊混用。
2. 每工作先掃描完整工作範圍一次；採現有 `noise=-35dB`、`minimumSilenceDuration=0.35s` 作初始值。這些是工程預設，並非已驗證的最佳辨識參數。
3. 偵測結果由掃描相對秒轉為絕對 sample，量化後夾限於掃描範圍，去除倒序／非法值，合併相接或重疊區間。
4. cache key 使用來源 digest、normalization profile、實際 PCM identity、noise profile、最短靜音門檻。不得只用來源 path／mtime。
5. 完整掃描成功但沒有靜音是有效空集合；後續切點查詢不能反覆重掃。
6. 一般分析錯誤：記一次原因，未規劃部分回退原固定切點。取消／來源不符／checkpoint 錯誤必須向上停止，不能吞成「沒找到靜音」。
7. 最多保存 100,000 個偵測區間；超限時仍保存由當次結果產生的切點方案，但不保存全量偵測列表。當次 helper 遞迴缺少候選時依 §7 回退中點，不啟動另一套掃描流程。

在 v2 保存成功掃描的 covered range 與 digest，供後續執行查驗；原本記憶體 cache 不自動等於跨執行持久化 cache。不得因此要求階段 2 為已完成 root 重新建立 WAV。

## 4. 決定性選點規則

所有候選為靜音區間中點，轉成整數 sample。候選必須符合實際上下限；平手選較早者。同一份輸入、profile 與候選清單必須產生相同方案。

| 層級 | 目標／搜尋範圍 | 約束與 fallback |
| --- | --- | --- |
| 外層 root | 目前 start + 1,200 秒之前 30 秒 | 選最接近上限的合格停頓，root 不超過 1,200 秒；無候選取原上限 |
| TXT 十分鐘分組 | workStart + k×600 秒，前後 5 秒 | 優先採此範圍內既有 root 邊界，再選最接近目標的停頓；無候選取精確目標 |
| 初始 ASR chunk | 本子區間 start + 120 秒之前 5 秒 | 子區間不可跨 root 或 displayGroup；無候選取上限或子區間終點 |
| token 遞迴 | 父區間中點前後 5 秒 | 兩個 child 都至少 30 秒；無候選取合法中點，否則停止切分 |

完整規劃順序：

1. 先建立外層 root plan。
2. 以工作起點的 600 秒網格建立全工作的 displayGroup；目標附近有 root 邊界時取最近的 root 邊界，避免只差幾秒卻形成不必要小片段。起點與終點固定，不因靜音移動。
3. 以 root 與 displayGroup 邊界聯集切出規劃子區間，對各子區間安排最長 120 秒 ASR chunk。交界／最後尾段允許短於 30 秒；30 秒是**遞迴子段下限**，不是刪除短尾音的門檻。
4. 所有初始 chunk、displayGroup 與 root 範圍凍結、驗證並持久化後，才開始模型推論。
5. token 超限時僅替換相應 leaf 成 split+children，寫入階段 0 的原子 root state；已完成 siblings 不動。

本版不加 overlap、不使用文字模糊比對刪重、不將前一段辨識結果放進下一段 prompt。這樣可以單獨測量切點效果，避免重複句被誤刪。找不到停頓的連續講話仍可硬切，不能宣稱風險已完全消失。

## 5. 十分鐘時間戳的相容方式

- 600 秒是排版目標，不是固定五個 chunk。靜音切點可能讓區間變為 `[00:00:00 - 00:09:58]`、`[00:09:58 - 00:20:00]`，標題必須忠實反映真實起訖。
- 每個內部目標相對原工作起點的偏移不得超過五秒，不能逐組累加漂移。最終尾段可以較短。
- 不因 root 邊界增加 TXT 標題；同一 displayGroup 可含多個 root 的 leaf，需在 Swift 全工作合併層完成排版。
- 初始 chunk 不跨 displayGroup；遞迴 children 繼承 groupID。合併器不能按字數把已辨識的一塊文字拆到兩個標題下。
- 手動切片從自己的實際原始錄音起點每十分鐘分組；續跑／補稿沿用原 groupID 與邊界，不因新工作 ID 重設時間。
- 偵測失敗可使部分目標採硬切，但只要方案已持久化，恢復時不改寫它。

## 6. 空白結果與靜音證據

偵測結果只用於選點；有靜音不代表要跳過 ASR。初版仍對所有初始 chunk 推論。

空結果只有在**整個 leaf** 被同 profile 的已驗證靜音區間涵蓋時才可提交 `verifiedSilence`，不得以局部靜音比例或平均音量猜測整塊沒人說話。文字為空且無完整靜音證據時走 `failed/local_empty_unverified`，保留已有文字，不回報無缺口完成。

這是保守分類，-35dB 並非人聲活動模型；弱音、遠距離、背景音樂素材要包含在實測。正常非空文字不能因落在偵測靜音區間而刪除。

## 7. 介面與故障邊界

- Swift 負責 source identity、全工作 root／display／initial chunk 方案、偵測快取；helper 載入有 digest 的方案，驗證後按真實 sample 切陣列。
- Python 的無 MLX chunking 模組接收 `startSample/endSample`、候選停頓與 bounds；遞迴 callback 回傳結構化 leaf，不再只傳文字。
- Swift 保存初始候選清單或可驗證分析引用；helper 查詢父範圍內候選不再另呼叫 ffmpeg。未涵蓋範圍由 Swift 準備後重新下發，無需 Python 啟動另一套 detector。
- 此階段不新增任意 helper→Swift RPC：若初始候選過量未保留，當次遞迴允許合法中點 fallback 並記錄，後續版本才可增加按需分析協定。
- `silence_scan_count/scanned_audio_seconds/elapsed_ms/cache_hits` 納入本機彙總；另記 outer／inner／recursive 的 silence cut 與 fallback 次數。
- 不以「偵測到靜音」作辨識品質成功指標，亦不把掃描耗時藏在模型推論時間內。

## 8. 測試與放行

| 情境 | 必須成立 |
| --- | --- |
| 停頓剛好在 120 秒前／後 | 前方合法候選被採用，後方不使 chunk 超限 |
| 沒有停頓／持續背景噪音 | 固定切點 fallback，音訊覆蓋不變 |
| 60 秒父 leaf 達 cap | 只允許 30＋30 秒；附近其他停頓不能造出 29 秒 child |
| 45 秒／短尾段達 cap | 不能拆成兩個小於 30 秒 child；走既定終止策略 |
| 遞迴左段完成、右段失敗 | 左段提交與 start/end 可恢復，不重新規劃 |
| 非零切片＋跨 root 的 displayGroup | 十分鐘顯示正確，無二次 offset、無按字數拆稿 |
| detector 失敗／取消／空集合 | 分別為可觀察 fallback／取消停止／有效 cache hit |
| 設定在續跑前改變 | 舊方案不變；新工作才採新設定 |
| 空文字＋局部靜音／完整靜音 | 前者不可正常完成，後者可 verifiedSilence |

真實模型 A/B：同模型、revision、prompt、tokens、素材與固定解碼設定，比較固定切點與靜音切點。至少涵蓋多人連續講話、低音量、背景噪音、專有名詞、中英混用；每個被移動的切點前後各五秒由人工核對。記錄邊界錯／漏／重複字及全稿可用性，不只看總字數。

預設開啟的放行條件：覆蓋與時間測試全過、無新增內容遺失、比較樣本的邊界錯誤總數不高於 baseline；若不能證明穩定，維持可選設定並記錄未放行理由。效能分別記掃描與 ASR 時間，不承諾固定百分比。
