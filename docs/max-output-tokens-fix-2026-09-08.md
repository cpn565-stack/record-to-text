# Gemini MAX_TOKENS 修正（2026-09-08）

基準：codex/record-to-text-reliability-v2，HEAD 88f9f69904f6991924f43d15638a754a50ea4ca2。本次變更尚未 commit/push；原有 local-segment-fill-spec-2026-09-04.md 未修改。

## 已確認
- 9/8 的兩筆失敗工作使用 gemini-3.8-flash / high。第一次在深度 2 停止；續跑最後約 7 分鐘片段無法產生兩個至少 4 分鐘的子段。
- 轉錄請求原先固定 maxOutputTokens=16384。失敗後仍宣稱將切小重試。
- MAX_TOKENS 無正文或只有 thought parts 時，原程式先丟 emptyResponse，未進入切段復原。
- 舊日誌沒有失敗回應的 token 明細；不能斷言每次都是 thinking 耗盡預算。

## 修正
- 已知 Gemini 3.6/3.7/3.8 Flash 轉錄上限改為 65536；未知模型仍用 16384。AI Studio 與 Vertex 共用此政策；摘要上限不變。
- 官方模型規格：https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash （3.6/3.7 對應模型頁同為 65536）。
- 保留原 thinking 設定。較高上限允許更多實際輸出與費用，並非每次固定耗用上限。
- 自動切段最多 4 層、子段至少 60 秒。20 分鐘初始分段不變；持續失敗仍有限停止。
- 先判斷 MAX_TOKENS，再判斷正文是否為空；截斷稿絕不進正式合併稿。
- 終止錯誤包含時長、深度與限制，不再承諾重試。
- 請求日誌記錄上限；截斷回應記錄 response/model 與正文/thinking token 數，不記錄正文。

## 驗證
- 修改前：針對性 18 tests / 8 assertions failed，重現舊切段限制及空正文分類錯誤。
- 第一輪 scripts/run-checks.sh 全通過：含 182 XCTest、Python、Swift self-test、10 mock pipeline scenarios、App 打包。
- 最後新增空正文端到端 mock 與請求 body / 未知模型上限檢查後：針對性 30 tests / 0 failures，重新打包通過。
- git diff --check 通過。
- 沒有呼叫真實 Google API，沒有重送使用者錄音；真實改善率及長音訊成本仍未驗證。

## 安裝與啟動
- 已安裝 /Applications/record-to-text.app，與 dist executable SHA256 一致：
  8c3cd9a5174cda972cf51759a36b957774116a616dee91ebeecb58d32d1d61da
- codesign --verify --deep --strict 通過。
- 舊版 ZIP：~/Library/Application Support/record-to-text/AppBackups/20260908-204854/record-to-text.app.zip
- 關閉前 UI 確認兩筆均已失敗、無執行中工作；沒有修改原始錄音與復原資料。
- 新程序已啟動，但主執行緒 sample 顯示等待 Keychain SecItemCopyMatching；CUA 讀取視窗逾時。
- SecurityAgent 無法由電腦操作工具存取（工具安全限制）。需要使用者處理 macOS 鑰匙圈提示，才能完成 GUI 啟動確認。
- 啟動後請對第二筆「第 7/7 段」失敗工作選「從已完成片段續跑」；既有六個完成片段會先驗證並沿用。舊失敗卡保留的是歷史錯誤文字。
