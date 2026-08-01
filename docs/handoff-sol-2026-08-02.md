# record-to-text 交接狀態（給 Sol）

更新日期：2026-08-02（台北時間）  
專案路徑：/Users/mike/Projects/AI工作區域/record-to-text

## 先講結論

目前不是「模型完全不能處理 20 分鐘音訊」。同一個 26.1 分鐘錄音，在新版 App process 重啟後可以完成兩個外部分段；最後一次實測也已成功移除模型回吐到尾端的 Prompt。

但這個專案目前仍有大量未提交變更，且 App Support 裡還有一筆狀態可疑的工作 0D7A2702-3838-40C8-8A4F-C3BCD0EC974C。因此目前適合交接檢查，不應直接宣稱已完全 production-ready。

## 實測檔案

來源：

/Users/mike/My Drive/Specifique1/01_專案/會議記錄/會議錄音/會議錄音 2026-07-19 10.24.55.m4a

ffprobe 顯示約 26.1 分鐘。App 的外部分段設定是每段最多 1200 秒，所以規劃為：

- 第 1 段：0–1200 秒
- 第 2 段：1200 秒–結束

最後一次成功工作的 ID：

8A52FBEF-24BC-468A-957C-F3E98D1697EF

成功輸出：

/Users/mike/My Drive/Specifique1/01_專案/會議記錄/會議錄音/轉出的文字/會議錄音 2026-07-19 10.24.55_逐字稿_3.txt

此檔案檢查結果：

- 16,526 bytes、UTF-8、非空
- 沒有「【此處約缺少 ...】」缺口標記
- 沒有 Prompt 開頭污染字串
- 26.1 分鐘完整完成

前兩份是修正前污染版本，不要拿來判斷最新結果：

- ..._逐字稿.txt：尾端含 Prompt
- ..._逐字稿_2.txt：尾端含 Prompt
- ..._逐字稿_3.txt：目前乾淨版本

## 已確認的錯誤原因

### 1. Persistent helper 的 JSONL 協定錯誤

App 將 ASR request 以 pretty-printed JSON 寫入長駐 helper 的 stdin，但 helper server 是逐行讀取 JSONL。於是它先讀到單獨的 {，產生：

JSONDecodeError: Expecting property name enclosed in double quotes: line 2 column 1 (char 2)

修正位置：

Sources/RecordToTextCore/ASRBackend.swift

長駐 session 現在使用 compact one-line JSON；單次模式仍可使用 pretty JSON。

### 2. 測試時 App process 沒有跟著新版 binary 重啟

前幾次失敗的 App process 是舊 process。即使 source/bundle 後來已經更新，正在執行中的 Swift App 仍會沿用舊的 Swift 邏輯。

因此前幾次看到的泛化 asr_failed 與 JSONDecodeError，不應解讀為模型連續多次無法辨識。它們都在 loadingModel 附近、約數秒內失敗，並非完整推論後失敗。

重新啟動新版 App 後，同一音檔成功完成：

- 11F0D474-6424-440F-B325-1170F86D243F：成功，但 Prompt 污染
- 453BB6C7-A28B-4306-911A-48ACA684520F：成功，但 Prompt 污染
- 8A52FBEF-24BC-468A-957C-F3E98D1697EF：成功且 Prompt 已清除

### 3. 模型輸出偶爾回吐 Prompt

Qwen3-ASR 的 generate(..., system_prompt=...) 在這次錄音的輸出尾端回吐了部分 Prompt。它不是完整 Prompt，而是回吐到專有名詞清單前：

這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：

原本的完成驗證只有確認：

- helper 發出 completed
- 輸出檔存在
- 輸出是非空 UTF-8

所以污染內容被錯誤視為成功。

目前已在：

Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py

加入 remove_prompt_echo()：

- 只檢查文字尾端
- 只比對 Prompt 的完整開頭行片段
- 不做模糊的全文刪除
- 移除時發出 prompt_echo_removed warning

這個防護目前已用實測檔案驗證成功。

## 目前長音訊與 token 防護邏輯

主要程式：

- Sources/RecordToTextApp/Resources/qwen_asr_mlx_runner.py
- Sources/RecordToTextApp/Resources/qwen_asr_chunking.py
- Sources/RecordToTextCore/ASRBackend.swift
- Sources/RecordToTextCore/TranscriptionEngine.swift

目前策略：

- App 外部長段上限：1200 秒（20 分鐘）
- helper 內部預設切成 120 秒
- maximumTokens=16384
- 若某塊達到 token 上限，遞迴對半再切
- 最短約 30 秒
- 最短片段仍達上限時，會明確標記缺口並繼續後續音訊；不把截斷文字當成功
- 同一個 job 內使用長駐 Python/MLX helper 與 model cache，避免每個 coordinator segment 重新載入模型

## 驗證結果

最後一次 ./scripts/run-checks.sh：

- Python tests：10 passed
- Swift executable self-tests：26 passed
- Pipeline self-test：9 個情境通過
- 完整 XCTest：SKIP，因目前環境沒有完整 Xcode，只能使用 executable self-tests
- git diff --check：通過

Source 與 App bundle 的 runner SHA1 相同：

b5f82464d7f6de88b5de6bf3c9d747236c010448

## 目前未解／請 Sol 優先看的地方

### A. App Support 有一筆可疑的工作

位置：

/Users/mike/Library/Application Support/record-to-text/job-ledger.json

工作：

0D7A2702-3838-40C8-8A4F-C3BCD0EC974C

目前顯示 transcribing，但當下沒有看到 qwen helper process。它的 Prompt 詞彙也不是本次重試使用的「康師傅」，而是：

味全 典華 學習長

這可能是另一筆舊佇列工作，也可能是 App 在測試過程中留下的異常狀態。請先確認 UI 與 process，再決定是否取消或清理；不要直接刪 ledger。

### B. Prompt echo 防護是否應該放在 helper 還是更上層

目前放在 helper 的 leaf output callback，能攔到本次已知污染。但 Sol 可評估：

- 是否應保留 raw output 供診斷
- 是否應在 TextFileValidator 或 final merge 再做一次輸出契約驗證
- 是否應縮短送給 ASR 的 system prompt，只保留 glossary 必要資訊
- 是否存在其他非尾端的 Prompt echo 形式

### C. 大量未提交變更

目前沒有 commit，也沒有做 reset。git status 有 17 個已修改 tracked files，以及以下未追蹤檔案：

- Sources/RecordToTextApp/Resources/qwen_asr_chunking.py
- Tests/qwen_asr_chunking_test.py
- docs/long-audio-token-limit-hardening.md
- docs/real-metal-verification-2026-08-01.md

這些變更混合了先前專案工作與本次修正。請先看 diff 與文件，不要直接 reset、checkout 或大量重寫。

## 建議 Sol 的檢查順序

1. 先讀本文件與 docs/long-audio-token-limit-hardening.md。
2. 檢查 ASRBackend.swift 的長駐 session lifecycle、stdin JSONL、stdout/stderr pipe race。
3. 檢查 qwen_asr_mlx_runner.py 的 serve()、exception handling、remove_prompt_echo()。
4. 檢查 0D7A... 是否為 stale job，先不要刪除任何 recovery data。
5. 用一個短音檔重測 Prompt echo guard，再決定是否需要重跑長音檔。
6. 最後才評估是否要把輸出檔名去重、清理污染版本；不要未確認就覆蓋使用者檔案。

## 交接判斷

目前最準確的描述是：

「已找到並修正造成多次早期失敗的 App/JSONL/process 問題；已完成一次新版 end-to-end 長音檔實測，並修正已觀察到的 Prompt 尾端污染。token 防護與基本 pipeline 測試通過，但因存在未提交的大量變更與一筆可疑 transcribing job，仍需要第二位工程師做 code review 與狀態確認。」
