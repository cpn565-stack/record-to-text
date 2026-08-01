#!/usr/bin/env python3
"""Metal-free tests for the MLX helper's token-limit safety boundary."""

from __future__ import annotations

from contextlib import nullcontext
from pathlib import Path
import sys
import unittest


RESOURCE_DIRECTORY = Path(__file__).parents[1] / "Sources" / "RecordToTextApp" / "Resources"
sys.path.insert(0, str(RESOURCE_DIRECTORY))

from qwen_asr_chunking import (  # noqa: E402
    TokenLimitReached,
    generate_span_with_token_guard,
)


class FakeResult:
    def __init__(self, text: str, generation_tokens: int) -> None:
        self.text = text
        self.generation_tokens = generation_tokens


class FakeModel:
    def __init__(self, result_for) -> None:
        self.result_for = result_for
        self.calls: list[tuple[int, tuple[int, ...]]] = []

    def generate(self, span, **_arguments):
        values = tuple(span)
        self.calls.append((len(values), values))
        return self.result_for(values)


def run_guard(model, span, *, maximum_tokens: int = 10, **options):
    events: list[tuple[str, dict]] = []

    def emit(event_type: str, **payload) -> None:
        events.append((event_type, payload))

    result = generate_span_with_token_guard(
        model,
        span,
        generation_arguments={"max_tokens": maximum_tokens},
        sample_rate=10,
        maximum_tokens=maximum_tokens,
        label="測試塊",
        emit=emit,
        heartbeat_factory=lambda _message: nullcontext(),
        min_split_seconds=30,
        **options,
    )
    return result, events


class TokenGuardTests(unittest.TestCase):
    def test_under_cap_returns_text_without_splitting(self) -> None:
        model = FakeModel(lambda values: FakeResult(f"ok-{len(values)}", 9))

        result, events = run_guard(model, list(range(1200)))

        self.assertEqual(result, "ok-1200")
        self.assertEqual([call[0] for call in model.calls], [1200])
        self.assertEqual(events, [])

    def test_capped_span_recursively_splits_and_preserves_order(self) -> None:
        model = FakeModel(
            lambda values: FakeResult(
                f"part-{values[0]}-{values[-1]}",
                10 if len(values) > 600 else 9,
            )
        )
        leaves: list[str] = []

        result, events = run_guard(
            model,
            list(range(1200)),
            on_leaf_complete=leaves.append,
        )

        self.assertEqual(result, "part-0-599 part-600-1199")
        self.assertEqual([call[0] for call in model.calls], [1200, 600, 600])
        self.assertEqual([event[0] for event in events], ["log"])
        self.assertEqual(leaves, ["part-0-599", "part-600-1199"])

    def test_exactly_two_minimum_spans_are_split_into_minimum_chunks(self) -> None:
        model = FakeModel(
            lambda values: FakeResult(
                f"part-{values[0]}-{values[-1]}",
                10 if len(values) == 600 else 9,
            )
        )

        result, _events = run_guard(model, list(range(600)))

        self.assertEqual(result, "part-0-299 part-300-599")
        self.assertEqual([call[0] for call in model.calls], [600, 300, 300])

    def test_failure_on_left_side_fails_the_whole_span_before_right_side(self) -> None:
        def result_for(values):
            if len(values) > 600 or values[0] == 0:
                return FakeResult("possibly truncated", 10)
            return FakeResult("right", 9)

        model = FakeModel(result_for)

        with self.assertRaises(TokenLimitReached):
            run_guard(model, list(range(1200)))

        self.assertEqual([call[0] for call in model.calls], [1200, 600, 300])

    def test_irreducible_span_can_be_marked_and_later_audio_continues(self) -> None:
        def result_for(values):
            if len(values) > 600 or (values[0] == 0 and len(values) <= 600):
                return FakeResult("capped", 10)
            return FakeResult(f"part-{values[0]}-{values[-1]}", 9)

        model = FakeModel(result_for)
        skipped: list[TokenLimitReached] = []

        result, _events = run_guard(
            model,
            list(range(1200)),
            on_leaf_skipped=lambda error: (
                skipped.append(error) or f"[skip-{error.span_seconds:.0f}s]"
            ),
        )

        self.assertEqual(
            result,
            "[skip-30s] part-300-599 part-600-1199",
        )
        self.assertEqual(len(skipped), 1)
        self.assertEqual(skipped[0].span_seconds, 30)
        self.assertEqual(
            [call[0] for call in model.calls],
            [1200, 600, 300, 300, 600],
        )

    def test_minimum_size_token_limit_raises_instead_of_returning_truncated_text(self) -> None:
        model = FakeModel(lambda _values: FakeResult("truncated", 10))

        with self.assertRaises(TokenLimitReached) as context:
            run_guard(model, list(range(300)))

        self.assertEqual(context.exception.generation_tokens, 10)
        self.assertEqual(context.exception.maximum_tokens, 10)
        self.assertIn("達到 token 上限", str(context.exception))

    def test_maximum_depth_token_limit_raises(self) -> None:
        model = FakeModel(lambda _values: FakeResult("truncated", 10))

        with self.assertRaises(TokenLimitReached):
            run_guard(model, list(range(1200)), max_depth=0)

    def test_exact_token_cap_is_considered_a_limit(self) -> None:
        model = FakeModel(lambda _values: FakeResult("truncated", 10))

        with self.assertRaises(TokenLimitReached):
            run_guard(model, list(range(600)))

    def test_token_limit_failure_does_not_reach_output_or_completed_side_effects(self) -> None:
        model = FakeModel(lambda _values: FakeResult("truncated", 10))
        output_written = False
        completed = False

        try:
            text, _events = run_guard(model, list(range(600)))
            output_written = bool(text)
            completed = True
        except TokenLimitReached:
            pass

        self.assertFalse(output_written)
        self.assertFalse(completed)

    def test_injected_generate_callable_is_used_for_stdout_safe_runner_wrapper(self) -> None:
        calls: list[int] = []

        def generate(span):
            calls.append(len(span))
            return FakeResult("wrapped", 9)

        result = generate_span_with_token_guard(
            object(),
            list(range(20)),
            generation_arguments={"max_tokens": 10},
            sample_rate=10,
            maximum_tokens=10,
            label="wrapped",
            heartbeat_factory=lambda _message: nullcontext(),
            generate=generate,
        )

        self.assertEqual(result, "wrapped")
        self.assertEqual(calls, [20])


if __name__ == "__main__":
    unittest.main()
