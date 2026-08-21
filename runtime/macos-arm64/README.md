# Bundled FFmpeg (macOS Apple Silicon)

`scripts/fetch-bundled-ffmpeg.sh` 會下載 FFmpeg 9.0 arm64 static 到 `bin/`，再由 `scripts/build-app.sh` 複製進 App 的 `Contents/Helpers/`。

- 來源：https://ffmpeg.martin-riedl.de/ （release 9.0，build `1785863997_9.0`）
- 需要：`libmp3lame`（雲端管線壓縮成 16 kHz 單聲道 MP3）
- 此 build 含 GPL 編解碼器，只給朋友／Developer 試用，不是正式公證 Runtime

`bin/` 與 `downloads/` 不進 git。
