# Third-party components

本文件是工程盤點，不構成法律意見。正式公開發佈前仍需完成授權與商標檢視。

| 元件 | 用途 | 上游／授權 | 發佈注意 |
| --- | --- | --- | --- |
| Qwen3-ASR | 語音辨識模型 | [QwenLM/Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)，Apache-2.0 | 模型 ID、revision、檔案 digest 與模型卡需隨 Release 固定 |
| MLX-Audio | Apple Silicon ASR runtime | [Blaizzy/mlx-audio](https://github.com/Blaizzy/mlx-audio)，MIT | Phase 0 鎖定 0.4.6；正式 runtime 需含完整 transitive notices |
| MLX / MLX-LM | Apple Silicon inference | [ml-explore/mlx](https://github.com/ml-explore/mlx)，MIT | native binaries 必須簽署與公證 |
| OpenCC | 台灣繁體轉換 | [BYVoid/OpenCC](https://github.com/BYVoid/OpenCC)，Apache-2.0 | 必須包含 `s2twp` 設定與字典授權 |
| FFmpeg / FFprobe 9.0 | 音訊探測與雲端上傳前壓縮 | [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de/) 的 macOS arm64 static 9.0（含 libmp3lame）；上游 [FFmpeg](https://ffmpeg.org/legal.html) | 目前打進 App `Contents/Helpers` 的是含 x264/x265 的 GPL build，只給朋友／Developer 試用。正式公證發行必須改成經檢視的 LGPL 相容 build，並附完整 notice |
| PyTorch | Intel Experimental inference | [pytorch/pytorch](https://github.com/pytorch/pytorch)，BSD-style | macOS x86_64 僅為停止支援的舊版 spike，不可直接標成正式支援 |
| qwen-asr | Intel Experimental adapter | [QwenLM/Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | 鎖定版本與 `context` API；需 Intel 實機驗證 |
| Transformers | tokenizer／Intel adapter | [huggingface/transformers](https://github.com/huggingface/transformers)，Apache-2.0 | arm64 與 Intel runtime 版本不同，不可共用 env |

公開介面或產品名稱使用「Qwen」前需完成品牌／商標檢視，且不得暗示本 App 由 Qwen 團隊官方發佈或背書。
