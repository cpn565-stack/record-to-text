#!/usr/bin/env python3
"""Metal-free contract tests for the MLX helper's outer transcription loop."""

from __future__ import annotations

from contextlib import nullcontext
from pathlib import Path
import os
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


RESOURCE_DIRECTORY = (
    Path(__file__).parents[1]
    / "Sources"
    / "RecordToTextApp"
    / "Resources"
)
sys.path.insert(0, str(RESOURCE_DIRECTORY))

# The helper reserves stdout for JSONL at import time. Restore the test runner's
# stdout immediately after import; emit() is replaced in each test below.
_ORIGINAL_STDOUT_FD = os.dup(sys.stdout.fileno())
try:
    import qwen_asr_mlx_runner as mlx_runner  # noqa: E402
finally:
    os.dup2(_ORIGINAL_STDOUT_FD, sys.stdout.fileno())
    os.close(_ORIGINAL_STDOUT_FD)


class FakeResult:
    def __init__(self, text: str, generation_tokens: int = 1) -> None:
        self.text = text
        self.generation_tokens = generation_tokens


class FakeModel:
    sample_rate = 1

    def __init__(self, results) -> None:
        self._results = iter(results)

    def generate(self, _span, **_arguments):
        result = next(self._results)
        if isinstance(result, BaseException):
            raise result
        return result


class MLXRunnerTests(unittest.TestCase):
    prompt = "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。"

    def make_request(self, directory: str) -> dict[str, object]:
        root = Path(directory)
        audio = root / "input.wav"
        audio.write_bytes(b"fake wav")
        return {
            "jobID": "test-job",
            "audioPath": str(audio),
            "outputPath": str(root / "transcript.txt"),
            "modelID": "mlx-community/Qwen3-ASR-1.7B-8bit",
            "modelRevision": "a" * 40,
            "language": "Chinese",
            "prompt": self.prompt,
            "terms": [],
            "modelCacheDirectory": str(root / "models"),
            "offline": True,
            "allowMissingPrompt": False,
            "maximumTokens": 10,
            "chunkDurationSeconds": 2,
        }

    def run_with_fake_runtime(self, request, model, events):
        utils = types.ModuleType("mlx_audio.stt.utils")
        utils.load_audio = lambda _path: [0, 1, 2, 3]
        mlx_audio = types.ModuleType("mlx_audio")
        mlx_audio_stt = types.ModuleType("mlx_audio.stt")

        with patch.dict(
            sys.modules,
            {
                "mlx_audio": mlx_audio,
                "mlx_audio.stt": mlx_audio_stt,
                "mlx_audio.stt.utils": utils,
            },
        ), patch.object(mlx_runner, "emit", side_effect=lambda event_type, **payload: events.append((event_type, payload))), patch.object(
            mlx_runner,
            "static_capability",
            return_value=(True, False),
        ), patch.object(
            mlx_runner,
            "load_model_once",
            return_value=(model, True, False),
        ), patch.object(
            mlx_runner,
            "heartbeat",
            side_effect=lambda _message: nullcontext(),
        ):
            return mlx_runner.transcribe(request)

    def test_prompt_echo_in_later_chunk_fails_and_preserves_partial(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            events: list[tuple[str, dict]] = []
            model = FakeModel([
                FakeResult("前一個 chunk 的正常內容。"),
                FakeResult(self.prompt),
            ])

            with self.assertRaises(SystemExit) as context:
                self.run_with_fake_runtime(request, model, events)

            self.assertEqual(context.exception.code, 2)
            output = Path(request["outputPath"])
            partial = output.with_name(f"{output.name}.partial.txt")
            self.assertFalse(output.exists())
            self.assertEqual(partial.read_text(encoding="utf-8"), "前一個 chunk 的正常內容。")
            self.assertNotIn("completed", [event_type for event_type, _ in events])
            self.assertIn(
                ("error", {"code": "prompt_echo_only", "message": "模型只回吐了送入的 Prompt／詞庫，沒有產生可用逐字稿。", "recoverable": True}),
                events,
            )

    def test_general_chunk_failure_preserves_completed_partial(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            events: list[tuple[str, dict]] = []
            model = FakeModel([
                FakeResult("前一個 chunk 的正常內容。"),
                RuntimeError("fake native failure"),
            ])

            with self.assertRaisesRegex(RuntimeError, "fake native failure"):
                self.run_with_fake_runtime(request, model, events)

            output = Path(request["outputPath"])
            partial = output.with_name(f"{output.name}.partial.txt")
            self.assertFalse(output.exists())
            self.assertEqual(partial.read_text(encoding="utf-8"), "前一個 chunk 的正常內容。")
            self.assertNotIn("completed", [event_type for event_type, _ in events])


if __name__ == "__main__":
    unittest.main()
