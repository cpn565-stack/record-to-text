# 0.2.1 build 5 本機自用交付

日期：2026-09-10（Asia/Taipei）。使用者接受目前驗證範圍，決定直接交付 DMG，不需要另附 SHA 檔。

## 成品

- App：0.2.1（5），Apple Silicon，release configuration。
- App 程式基準：`e6bbb36d952b7b7cce00bd1aeaf1fc34ebdb0c8c`。
- DMG：`dist/record-to-text-0.2.1-build5.dmg`。
- 使用現有已測試的 build 5 App 重新封裝；本次沒有修改 App 程式或提高 build number。
- 定案範圍依原規格：目前這台 Mac 的自用版本；公開發行、公證仍屬另一個里程碑。

## 已完成驗證

| 項目 | 結果 |
| --- | --- |
| build 5 完整自動化 | 262 項 XCTest、25 項 Python、72 項 executable self-tests、10 種 pipeline 情境通過；已核對本機完整紀錄 |
| 原 45 分鐘安裝版工作 | 15:20:28–15:24:45，Vertex `gemini-3.8-flash` 完成，工作紀錄為 complete、0 次重試 |
| Qwen 3 分鐘 | 安裝版 helper、既有 BF16 模型、離線執行，約 15.3 秒完成，無明示缺口；執行後 App 簽章仍通過，無新增 Python bytecode |
| AI Studio 3 分鐘 | 真實 Files API 與 `gemini-3.8-flash`，約 44.1 秒完成，無明示缺口 |
| 真實 Vertex 取消／程序重啟／續跑 | 第一段完成後取消並結束 probe；新程序載入 checkpoint，第一段不重送，第二與第三段完成；續跑約 104.4 秒 |
| 分段覆蓋 | 0–1200、1200–2400、2400–2700.010667 秒，三段各一次 completed；第一段標記 reusedFromCheckpoint，無範圍缺口或重疊 |
| 重試與輸出保護 | 第一段實際遇到 STOP 空回應，有限重試一次後成功；續跑另存 `_逐字稿_2.txt`，預置同名 TXT 及原始錄音保持不變 |
| 交付對齊 | 先前 development DMG、dist 與安裝版執行檔一致；重新封裝後以逐位元比較確認新 DMG 內執行檔一致，並驗證 bundle 簽章 |

補跑工具是 [FinalizationProbe.swift](validation/FinalizationProbe.swift)，連結 build 5 release Core objects，使用安裝版 ffmpeg／ffprobe／Qwen helper。這些補跑屬於真實後端及核心流程驗證，並非安裝版 GUI 操作驗收。工具不在一般測試套件中，不會讓 CI 自動呼叫付費 API；所有補跑輸出位於隔離資料夾，未修改 live App 設定或 journal。

## 使用者接受的驗收界線

人工逐字聽校、至少五次講者輪替對照、15 分鐘 GUI 互動及 GUI 取消重開操作，未宣告通過。本輪 System Events 回報「osascript 不允許輔助取用」（-1728）。使用者在取得此進度後選擇直接打包。

已備妥開頭、20／40 分鐘邊界及結尾的抽查片段與獨立 Qwen 參考稿。四個片段與長錄音對應位置的 PCM 相關係數均大於 0.999；40 分鐘附近的短片轉錄與長稿仍有文字差異，待人工確認。流程 complete 表示沒有系統已知的未完成片段，不能當作逐字準確率或講者身分的認證。

本機證據與人工檢查單：`dist/finalization-20260910/continuation.rif0Dp/`。內含音訊／私人文字的資料未提交到 Git。
