# Gemini 4 Hydrogen 與各模型思考強度（0.2.1 build 20）

## 使用方式

- 主視窗快捷選單、AI Studio 與 Vertex AI 設定的模型選單均可選 `gemini-4-hydrogen`。
- 「設定 → Runtime → Gemini 思考強度」提供 Hydrogen 的低／中／高／極高；首次選用預設極高（`xhigh`）。Carbon、Argon 保留低／中／高。Transcribe 與未知模型不顯示可操作的思考選單，也不傳送思考設定。
- 各模型分別保存選擇，同一模型跨 AI Studio／Vertex 共用。舊版全域設定保留為舊模型的初始值；Hydrogen 未有個別設定時才預設 xhigh。設定保存於 `geminiThinkingLevelsByModel`，原 `geminiThinkingLevel` 欄位保留作遷移基準。
- 一般未開始工作跟隨新設定；執行中、已開始及檢查點續跑工作保留快照的單一強度。重開 App 不會把已選 low／medium／high 的 Hydrogen 重設成 xhigh。

## 請求與輸出

- AI Studio 沿用 Files API／inline 音訊與 `v1beta/models/gemini-4-hydrogen:generateContent`；Vertex 沿用 OAuth、inline／GCS 音訊與 `v1/.../gemini-4-hydrogen:streamGenerateContent?alt=sse`。Vertex 地區支援 `global`、`us`、`eu`，不會默默改動使用者地區。
- 兩個後端送出 `generationConfig.thinkingConfig.thinkingLevel`。只允許 Hydrogen 使用 xhigh，其他模型的舊資料或直接呼叫若帶入 xhigh 會規範成 high，診斷紀錄採實際送出的值。不使用 `thinkingBudget`、temperature、topP 或 topK。
- Hydrogen 單次輸出上限為 **65,536 tokens**（含思考）；單次請求最多 **1,200 秒**，原始音訊段含準備、重試及細分共用 **1,800 秒**，仍遵守外部較短期限與取消。
- Vertex 使用者主動開啟的附加摘要也配置 65,536-token 上限，避免 xhigh 在原有 2,048-token 上限內耗盡額度；摘要仍預設關閉。其他模型既有額度保持原值。
- 沿用 20 分鐘音訊預切與自適應細分；`MAX_TOKENS`、`CONTINUATION` 等不完整回應不視為正式完成。未加入 long decode 或自動換模型。
- 既有 JSON／SSE 解析器排除 `thought: true` 的部分，只把最終文字交給逐字稿流程。保留真實 token 用量；Hydrogen 不套用 Flash 的費率估算。

## 官方依據（2026-11-13 核對）

- [Gemini API 思考設定](https://aistudio.google.com/docs/thinking#thinking-levels)：Hydrogen 支援 low／medium／high／xhigh，Google 原生預設 high；本 App 依需求預設 xhigh。Carbon 支援 low／medium／high。
- [Google Cloud Hydrogen 規格](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/4-hydrogen)：音訊輸入、單次前景輸出 65,536 tokens、地區與 API 限制。
- [Google Cloud 思考設定](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/thinking)：各模型支援等級與參數規範。

思考強度會影響推論過程、耗時與用量，可能改變逐字稿，但 xhigh 不保證更準；應以同一音檔比較漏字、專有名詞及講者辨識。

## 驗證範圍

新增 XCTest 涵蓋兩個後端的 Hydrogen 四等級／Carbon 三等級、預設值、實際請求與紀錄一致、JSON／SSE 思考內容過濾、Files API 清理、截斷拒收、期限、可選摘要、舊設定遷移、模型切換與重開、工作快照及排隊同步。

驗證使用模擬傳輸與測試音訊；未使用私人錄音呼叫 Google，未驗證使用者帳號的 Hydrogen 權限或真實辨識品質。完整 macOS 編譯、測試及開發 DMG 由此分支 PR 的 GitHub Actions CI 執行，結果以該次 run 為準。
