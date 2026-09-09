# Qwen helper 執行後簽章完整性修正

兩條 Python helper 啟動路徑共用的 `helperEnvironment` 固定設定
`PYTHONDONTWRITEBYTECODE=1`，避免 import 在 App resource bundle 新增 `.pyc`。
建置時清理快取仍保留；單靠建置時清理無法阻止執行後再次產生快取。

## 驗證

- 新增 `HelperBytecodeTests`，經真正的 `HelperASRBackend.transcribe` 啟動 Python，
  分別測長駐與單次模式。兩者皆匯入同目錄模組、完成輸出，再檢查沒有 `__pycache__`。
- 修正前同一測試出現兩個 assertion failures；修正後通過。
- `./scripts/run-checks.sh` 通過：242 XCTest、72 Swift self-tests、10 mock pipeline 情境及 Python 檢查。
- 對重新建置的 ad hoc App，以停用 bytecode 的環境執行真實 MLX helper `--help`；
  執行前後 `codesign --verify --deep --strict` 均通過，App 內沒有 `.pyc` 或 `__pycache__`。
- 此次沒有重跑模型推論或長音檔；上述 helper 檢查涵蓋造成問題的 import 階段。

## 交付

以 `BUILD_NUMBER=2 ./scripts/package-development.sh` 產生 0.2.1（2）開發 DMG。
`hdiutil verify`、SHA-256 核對與唯讀掛載後的 bundle verification 均通過；
DMG 內執行檔與 dist release 執行檔逐位元相同。
DMG SHA-256：`a3723acf24e6e8f069e31c3f1b6fe33a97a26dccff6d4fd155d3fdbfbf537909`。
此包沒有 Developer ID 簽署或 Apple 公證。已安裝的舊 App 需用新包替換，
程式碼修正不會自動修復舊包已受破壞的簽章。
