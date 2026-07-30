# Apple Silicon Runtime

狀態：Phase 0 candidate，尚非可下載的正式 Runtime。

建議基線：

- macOS 14+
- Python 3.12（固定 patch version）
- `mlx-audio==0.4.6`
- `transformers==5.12.1`
- `mlx-community/Qwen3-ASR-1.7B-8bit`
- model revision `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`

`requirements.lock.txt` 目前只記錄已核查的核心版本，不是假裝完整的 hash lock。正式 Runtime 必須在乾淨 arm64 builder 解出全部 transitive wheels 與 SHA-256，包含 LGPL 相容 ffmpeg、ffprobe、OpenCC 與字典，再完成 nested signing、notarization 與 Gatekeeper 驗證。
