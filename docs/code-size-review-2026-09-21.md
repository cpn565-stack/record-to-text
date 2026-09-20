# 程式體積檢查與 Gemini 精簡

日期：2026-09-21。比較基底：`dde71e7`（已完成網路恢復的 checkpoint）。

## 發現與處理

原始碼較大的檔案包括 `AppViewModel.swift`（2,835 行）、`TranscriptionEngine.swift`（2,665 行）、`MainView.swift`（1,643 行）、`Models.swift`（1,331 行）與兩個 Gemini backend（各超過 1,100 行）。行數本身不是效能問題；可直接改善的重複集中在兩個 backend 的回應解析、服務重試及模型 fallback。

此前相同的四次上限、取消檢查、deadline、重試診斷與 fallback 條件需要各改兩份；JSON 候選解析、thought 過濾、finishReason 判定與 Markdown 清理也幾乎重複。此次將這些規則集中到兩個內部元件：

- `GeminiGenerationRetry`：持有生成服務重試與使用者允許的模型 fallback。沿用 `CloudNetworkContext` 的每片段／模型 quota；傳輸層仍由 `GeminiTransportHelper` 管理。兩個 backend 只傳入真正送出生成請求的 closure，避免成串參數在主模型、重試與 fallback 間反覆傳遞。
- `GeminiResponseParser`：處理共同回應格式與文字清理。以內部錯誤 factory 協定保留既有 `GoogleAIStudioError`／`VertexAIError` 型別及 UI 文案；HTTP error message 解析也共用。

| 正式程式 | 修改前 | 修改後 |
| --- | ---: | ---: |
| `GoogleAIStudioBackend.swift` | 1,109 | 848 |
| `VertexAIGeminiBackend.swift` | 1,159 | 877 |
| `GeminiGenerationRetry.swift` | 0 | 115 |
| `GeminiResponseParser.swift` | 0 | 109 |
| 合計 | 2,268 | 1,949 |

正式程式淨減 **319 行**。這是維護成本的減少，沒有將行數變化宣稱為記憶體、App 容量或執行速度改善。

兩後端的差異仍保留：Vertex 的 STOP 空內容可同模型有限重試，並壓縮過多空白行；AI Studio 維持原有 emptyResponse 與空白行行為。網路錯誤不啟動模型 fallback；401／POSIX／URI 重建仍消耗原 quota。MAX_TOKENS 仍交由 adaptive 分段處理，不接受為完成逐字稿。

`AppViewModel` 和 `TranscriptionEngine` 的大型協調流程尚未拆分；本次沒有改其持久化、取消及續作生命週期，也沒有為了縮短檔案而放寬 private 存取。這些檔案仍是後續按職責拆分時的主要候選。

## 驗證

- 重點回歸：**72 tests／0 failures**，涵蓋兩後端、網路恢復、上傳、分段、回應合法性與診斷。
- 新增 `testSharedParserKeepsBackendWhitespaceAndExcludesThoughts`，鎖定兩後端既有的空白行差異、Markdown 清理與 thought 排除。
- 最終 `SKIP_APP_BUNDLE=1 REQUIRE_XCTEST=1 scripts/run-checks.sh`：**308 XCTest／0 failures**、Python 22＋3、executable self-test 72、pipeline 情境 10 組全部通過，退出碼 0。
- `git diff --check` 通過。

本機日誌：`/tmp/record-network-refactor-tests.log`、`/tmp/record-network-refactor-checks.log`。均為合成音訊／mock 驗證，未呼叫付費 API。

## 版本與執行中 App

使用者在驗證期間告知 App 正在執行，要求先不要重建。此時既有檢查已完成；後續只提交原始碼與文件，**不再重建、不安裝、不關閉 App**。

來源版本為 0.2.1 build 7；`/Applications/record-to-text.app` 仍為 build 6。先前製作的 `dist/record-to-text.app` 與 `dist/record-to-text-0.2.1-build7.dmg` 是精簡前的網路恢復版本，不含本次 refactor，沒有安裝或交付。後續需在使用者允許重建／安裝後，從最新來源重新建置。

GitHub 直連曾遇到 443 timeout；本次 push 使用 macOS 已啟用的本機 HTTP proxy，僅以單次 `git -c http.proxy=...` 傳入，未修改全域 Git、系統網路或 VPN 設定。
