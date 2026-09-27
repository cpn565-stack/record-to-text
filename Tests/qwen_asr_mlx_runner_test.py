#!/usr/bin/env python3
"""Metal-free contract tests for the MLX helper's outer transcription loop."""

from __future__ import annotations

from contextlib import nullcontext
from pathlib import Path
import json
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
        self.chunk_lengths = []

    def generate(self, _span, **_arguments):
        self.chunk_lengths.append(len(_span))
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

    def run_with_fake_runtime(
        self, request, model, events, *, audio_length=4, runtime_capability=(True, False)
    ):
        utils = types.ModuleType("mlx_audio.stt.utils")
        utils.load_audio = lambda _path: list(range(audio_length))
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
            return_value=(model, *runtime_capability),
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
            self.assertEqual(partial.read_text(encoding="utf-8"), "[00:00:00 - 00:00:02]\n\n前一個 chunk 的正常內容。")
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
            self.assertEqual(partial.read_text(encoding="utf-8"), "[00:00:00 - 00:00:02]\n\n前一個 chunk 的正常內容。")
            self.assertNotIn("completed", [event_type for event_type, _ in events])

    def test_retry_resumes_from_completed_chunk_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            first_events: list[tuple[str, dict]] = []
            first_model = FakeModel([
                FakeResult("第一塊內容。"),
                RuntimeError("fake timeout"),
            ])

            with self.assertRaisesRegex(RuntimeError, "fake timeout"):
                self.run_with_fake_runtime(request, first_model, first_events)

            output = Path(request["outputPath"])
            checkpoint = output.with_name(f"{output.name}.chunks.json")
            self.assertTrue(checkpoint.exists())

            second_events: list[tuple[str, dict]] = []
            second_model = FakeModel([FakeResult("第二塊內容。")])
            self.run_with_fake_runtime(request, second_model, second_events)

            self.assertEqual(
                output.read_text(encoding="utf-8"),
                "[00:00:00 - 00:00:04]\n\n第一塊內容。第二塊內容。",
            )
            self.assertTrue(checkpoint.exists())
            checkpoint_payload = json.loads(checkpoint.read_text(encoding="utf-8"))
            self.assertEqual(len(checkpoint_payload["completedChunks"]), 2)
            self.assertEqual(checkpoint_payload["completedChunks"][0]["text"], "第一塊內容。")
            self.assertFalse(
                output.with_name(f"{output.name}.partial.txt").exists()
            )
            self.assertTrue(
                any(
                    event_type == "log"
                    and "沿用前 1/2 塊" in payload.get("message", "")
                    for event_type, payload in second_events
                )
            )

    def test_ten_minute_sections_preserve_two_minute_inference_and_short_tail(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            request["chunkDurationSeconds"] = 120
            request["timeOffsetSeconds"] = 3600
            model = FakeModel([FakeResult(f"第{i}塊。") for i in range(1, 12)])
            self.run_with_fake_runtime(request, model, [], audio_length=1250)
            text = Path(request["outputPath"]).read_text()
            self.assertEqual(model.chunk_lengths, [120] * 10 + [50])
            self.assertEqual(text, (
                "[01:00:00 - 01:10:00]\n\n第1塊。第2塊。第3塊。第4塊。第5塊。\n\n"
                "[01:10:00 - 01:20:00]\n\n第6塊。第7塊。第8塊。第9塊。第10塊。\n\n"
                "[01:20:00 - 01:20:50]\n\n第11塊。"
            ))

    def test_resume_rebuilds_time_sections_without_repeating_completed_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            request["chunkDurationSeconds"] = 120
            # A manually sliced job plus an outer segment offset, not a round hour.
            request["timeOffsetSeconds"] = 2477
            first = FakeModel([FakeResult(f"第{i}塊。") for i in range(1, 7)] + [RuntimeError("interrupted")])
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                self.run_with_fake_runtime(request, first, [], audio_length=780)
            output = Path(request["outputPath"])
            partial = output.with_name(f"{output.name}.partial.txt").read_text()
            self.assertIn("[00:51:17 - 00:53:17]", partial)
            resumed = FakeModel([FakeResult("第7塊。")])
            self.run_with_fake_runtime(request, resumed, [], audio_length=780)
            self.assertEqual(resumed.chunk_lengths, [60])
            self.assertEqual(output.read_text(), (
                "[00:41:17 - 00:51:17]\n\n第1塊。第2塊。第3塊。第4塊。第5塊。\n\n"
                "[00:51:17 - 00:54:17]\n\n第6塊。第7塊。"
            ))

    def test_empty_audio_result_does_not_become_heading_only_output(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            self.run_with_fake_runtime(request, FakeModel([FakeResult(""), FakeResult(" ")]), [])
            self.assertEqual(Path(request["outputPath"]).read_text(), "")

    def test_gap_marker_remains_under_its_actual_audio_section(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            request["timeOffsetSeconds"] = 1200
            events = []
            self.run_with_fake_runtime(request, FakeModel([FakeResult("前段。"), FakeResult("capped", 10)]), events)
            text = Path(request["outputPath"]).read_text()
            self.assertTrue(text.startswith("[00:20:00 - 00:20:04]\n\n前段。"))
            self.assertIn("此處約缺少 2 秒", text)
            self.assertTrue(next(payload for event, payload in events if event == "completed")["containsSkippedAudio"])

    def test_invalid_time_offset_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            for offset in [-1, float("nan"), float("inf"), True, "120"]:
                with self.subTest(offset=offset):
                    request["timeOffsetSeconds"] = offset
                    with self.assertRaisesRegex(ValueError, "timeOffsetSeconds"):
                        mlx_runner.validate_request(request)

    def checkpoint_v2_block(self, directory: str, *, prompt_channel: str) -> dict:
        """A syntactically valid block; the coordinates are never reached here.

        The prompt channel is asserted before any audio is decoded, so these
        tests need the field validated but not a real plan on disk.
        """
        return {
            "directory": str(Path(directory) / "local-checkpoint-v2"),
            "rootID": "root-fixture0000000",
            "planID": "plan-" + "0" * 59,
            "identityDigest": "i" * 64,
            "sampleRate": 16_000,
            "audioStartSample": 0,
            "workStartSample": 0,
            "workEndSample": 4,
            "promptChannel": prompt_channel,
        }

    def test_a_checkpoint_declaring_another_channel_is_refused(self):
        """The frozen identity says the glossary travelled as a system prompt.

        Running it through `context` instead would write differently-conditioned
        text into leaves that a later resume treats as already proven.
        """
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            request["checkpointV2"] = self.checkpoint_v2_block(
                directory, prompt_channel=mlx_runner.PROMPT_CHANNEL_CONTEXT
            )
            model = FakeModel([FakeResult("文字")])
            with self.assertRaises(mlx_runner.CheckpointContractError) as caught:
                self.run_with_fake_runtime(request, model, [])
            self.assertEqual(caught.exception.code, "local_identity_mismatch")
            self.assertEqual(model.chunk_lengths, [], "no audio may be transcribed")

    def test_a_runtime_that_lost_the_declared_channel_is_refused(self):
        """Static capability promised system_prompt; the loaded model has neither.

        A downgraded MLX-Audio must not quietly produce glossary-free text under
        a checkpoint that claims the glossary was applied.
        """
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            request["checkpointV2"] = self.checkpoint_v2_block(
                directory, prompt_channel=mlx_runner.PROMPT_CHANNEL_SYSTEM
            )
            model = FakeModel([FakeResult("文字")])
            with self.assertRaises(mlx_runner.CheckpointContractError) as caught:
                self.run_with_fake_runtime(
                    request, model, [], runtime_capability=(False, False)
                )
            self.assertEqual(caught.exception.code, "local_identity_mismatch")
            self.assertEqual(model.chunk_lengths, [])

    def test_a_request_without_a_block_is_unaffected(self):
        """v1 jobs carry no declared channel, so nothing is asserted."""
        with tempfile.TemporaryDirectory() as directory:
            request = self.make_request(directory)
            self.run_with_fake_runtime(
                request,
                FakeModel([FakeResult("這是 mock 逐字稿。")]),
                [],
                audio_length=2,
                runtime_capability=(False, False),
            )
            self.assertIn(
                "這是 mock 逐字稿。", Path(request["outputPath"]).read_text()
            )


if __name__ == "__main__":
    unittest.main()
