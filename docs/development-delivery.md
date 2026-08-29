# Development build 交付與安裝

## 版本來源

- `Config/version.env` 是 marketing version 與本機預設 build number 的單一來源。
- `Config/Info.plist` 保留 `0.0.0 (0)` placeholder，由建置時寫入真實版本。
- CI 以 GitHub run number 當 build number，所以每份 artifact 可追溯。

## 本機建置測試 DMG

```bash
scripts/package-development.sh
```

輸出：

- `dist/record-to-text-<version>-development.dmg`
- `dist/record-to-text-<version>-development.dmg.sha256`

這是未用 Developer ID 簽署、未經 Apple 公證的測試件，不得標示為 Stable 發行。

## GitHub Actions 下載

CI 通過後，該 run 的 Artifacts 會有 `record-to-text-macos-<commit SHA>`，內含測試 DMG 與 SHA-256 檔，預設保留 14 天。

## 安裝

1. 開啟 DMG。
2. 把 `record-to-text.app` 拖到 DMG 內的 `Applications` 捷徑。
3. 測試件可能被 Gatekeeper 阻擋；只能在可信任的開發測試 Mac 上使用。

## Stable 發行界線

對外 Stable DMG 仍必須完成：

- Developer ID Application 簽署。
- Apple notarization 與 stapling。
- 乾淨帳號首次啟動、雲端後端、Qwen runtime 與模型的驗收。
- DMG 與 checksum 通過 `scripts/verify-release.sh`。
