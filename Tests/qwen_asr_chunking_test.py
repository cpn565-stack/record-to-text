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
    SilenceCandidateIndex,
    SplitCounters,
    TokenLimitReached,
    TranscriptAccumulator,
    generate_span_with_token_guard,
    join_transcript_parts,
    remove_prompt_echo,
    silence_choose_split,
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


def run_guard(
    model,
    span,
    *,
    maximum_tokens: int = 10,
    sample_rate: int = 10,
    min_split_seconds: float = 30.0,
    **options,
):
    events: list[tuple[str, dict]] = []

    def emit(event_type: str, **payload) -> None:
        events.append((event_type, payload))

    result = generate_span_with_token_guard(
        model,
        span,
        generation_arguments={"max_tokens": maximum_tokens},
        sample_rate=sample_rate,
        maximum_tokens=maximum_tokens,
        label="測試塊",
        emit=emit,
        heartbeat_factory=lambda _message: nullcontext(),
        min_split_seconds=min_split_seconds,
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


class PromptEchoTests(unittest.TestCase):
    def test_prompt_echo_only_after_real_chunk_is_marked_for_fail_closed(self) -> None:
        prompt = (
            "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。"
        )
        accumulator = TranscriptAccumulator(prompt=prompt)

        accumulator.record_completed_text("前一個 chunk 的正常內容。")
        accumulator.record_completed_text(prompt)

        self.assertTrue(accumulator.has_prompt_echo_only_chunk)
        self.assertEqual(accumulator.text, "前一個 chunk 的正常內容。")

    def test_removes_complete_glossary_list_echoed_at_the_beginning(self) -> None:
        prompt = (
            "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。\n"
            "以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：\n\n"
            "味全\n典華\n學習長"
        )

        self.assertEqual(
            remove_prompt_echo(
                "味全 典華 學習長。 嗯，真正的會議內容。",
                prompt,
                ["味全", "典華", "學習長"],
            ),
            "嗯，真正的會議內容。",
        )

    def test_expands_space_separated_cjk_term_snapshot_before_echo_cleanup(self) -> None:
        prompt = (
            "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。\n"
            "以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：\n\n"
            "味全 典華 學習長"
        )

        self.assertEqual(
            remove_prompt_echo(
                "味全 典華 學習長。 嗯，真正的會議內容。",
                prompt,
                ["味全 典華 學習長"],
            ),
            "嗯，真正的會議內容。",
        )

    def test_removes_glossary_echo_when_model_puts_sentence_punctuation_between_terms(self) -> None:
        prompt = (
            "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。\n"
            "以下詞彙可能出現在錄音中。只有當音訊內容相符時才使用以下寫法；沒有出現的詞彙不要自行加入：\n\n"
            "味全\n典華\n學習長"
        )

        self.assertEqual(
            remove_prompt_echo(
                "味全。典華。學習長。 嗯，真正的會議內容。",
                prompt,
                ["味全", "典華", "學習長"],
            ),
            "嗯，真正的會議內容。",
        )

    def test_does_not_remove_a_single_term_at_the_beginning(self) -> None:
        self.assertEqual(
            remove_prompt_echo(
                "OGSTM。 這是實際錄音內容。",
                "請忠實轉錄。\nOGSTM",
                ["OGSTM"],
            ),
            "OGSTM。 這是實際錄音內容。",
        )

    def test_removes_prompt_echo_at_either_edge(self) -> None:
        prompt = "這是一段中文會議錄音。請忠實轉錄音訊內容，不要摘要、改寫、刪除或補充。"

        self.assertEqual(
            remove_prompt_echo(f"{prompt} 真正內容。", prompt),
            "真正內容。",
        )
        self.assertEqual(
            remove_prompt_echo(f"真正內容。\n{prompt}", prompt),
            "真正內容。",
        )


class TranscriptJoinTests(unittest.TestCase):
    def test_cjk_fragments_join_without_spurious_spaces(self) -> None:
        self.assertEqual(join_transcript_parts(["我們開始", "今天的會議"]), "我們開始今天的會議")

    def test_cjk_punctuation_boundary_does_not_gain_a_space(self) -> None:
        self.assertEqual(join_transcript_parts(["第一句。", "第二句"]), "第一句。第二句")
        self.assertEqual(join_transcript_parts(["前半", "，後半"]), "前半，後半")
        self.assertEqual(
            join_transcript_parts(["內容", "【此處約缺少 30 秒：模型達到 token 上限，已跳過此片段】", "續內容"]),
            "內容【此處約缺少 30 秒：模型達到 token 上限，已跳過此片段】續內容",
        )

    def test_latin_words_keep_a_separator(self) -> None:
        self.assertEqual(join_transcript_parts(["Michael", "Jordan spoke"]), "Michael Jordan spoke")

    def test_mixed_cjk_and_latin_keeps_a_separator(self) -> None:
        self.assertEqual(join_transcript_parts(["使用", "MLX 轉錄"]), "使用 MLX 轉錄")
        self.assertEqual(join_transcript_parts(["finished the report", "然後結束"]), "finished the report 然後結束")

    def test_empty_parts_are_dropped(self) -> None:
        self.assertEqual(join_transcript_parts(["", "內容", "", "續"]), "內容續")
        self.assertEqual(join_transcript_parts([]), "")

    def test_accumulator_text_has_no_space_between_chinese_chunks(self) -> None:
        accumulator = TranscriptAccumulator(prompt="請忠實轉錄。")
        accumulator.record_completed_text("上半段的內容")
        accumulator.record_completed_text("下半段的內容。")

        self.assertEqual(accumulator.text, "上半段的內容下半段的內容。")


class SilenceCandidateIndexTests(unittest.TestCase):
    """Phase 1 §4/§6: the helper selects from Swift's frozen list, so the two
    sides have to agree on midpoint arithmetic and on what counts as covered."""

    def test_midpoint_truncates_like_swift_int64_division(self) -> None:
        # Swift is ``start + (end - start) / 2`` on Int64, which truncates.
        self.assertEqual(SilenceCandidateIndex([(0, 3)]).candidates, (1,))
        self.assertEqual(SilenceCandidateIndex([(1, 4)]).candidates, (2,))
        self.assertEqual(SilenceCandidateIndex([(5, 6)]).candidates, (5,))

    def test_touching_and_overlapping_intervals_merge_into_one_candidate(self) -> None:
        index = SilenceCandidateIndex([(0, 50), (40, 100), (100, 150)])
        self.assertEqual(index.intervals, ((0, 150),))
        self.assertEqual(index.candidates, (75,))

    def test_reversed_and_empty_intervals_are_dropped(self) -> None:
        index = SilenceCandidateIndex([(10, 10), (30, 20), (0, 8)])
        self.assertEqual(index.intervals, ((0, 8),))
        self.assertEqual(index.candidates, (4,))

    def test_from_plan_rejects_booleans_masquerading_as_samples(self) -> None:
        # JSON ``true`` decodes to ``1``; a bool is an ``int`` subclass, so an
        # unchecked read would silently shift every boundary after it.
        index = SilenceCandidateIndex.from_plan(
            [
                {"startSample": True, "endSample": 100},
                {"startSample": 0, "endSample": False},
                {"startSample": 0.5, "endSample": 100},
                {"startSample": 10, "endSample": 20},
                "not-a-dict",
            ]
        )
        self.assertEqual(index.intervals, ((10, 20),))

    def test_from_plan_tolerates_a_missing_list(self) -> None:
        self.assertFalse(SilenceCandidateIndex.from_plan(None))
        self.assertEqual(SilenceCandidateIndex.from_plan(None).intervals, ())

    def test_candidates_in_is_inclusive_and_ordered(self) -> None:
        index = SilenceCandidateIndex([(0, 10), (100, 110), (200, 210)])
        self.assertEqual(index.candidates, (5, 105, 205))
        self.assertEqual(tuple(index.candidates_in(5, 105)), (5, 105))
        self.assertEqual(tuple(index.candidates_in(6, 104)), ())
        self.assertEqual(tuple(index.candidates_in(300, 100)), ())

    def test_covers_demands_the_whole_span(self) -> None:
        index = SilenceCandidateIndex([(0, 100)])
        self.assertTrue(index.covers(0, 100))
        self.assertTrue(index.covers(20, 80))
        self.assertFalse(index.covers(0, 101))
        self.assertFalse(index.covers(-1, 50))

    def test_a_gap_between_pauses_is_not_coverage(self) -> None:
        # §6: 90% silent is not evidence. Only merged, contiguous coverage
        # counts, so a word sitting in the gap survives.
        index = SilenceCandidateIndex([(0, 50), (60, 100)])
        self.assertEqual(index.intervals, ((0, 50), (60, 100)))
        self.assertFalse(index.covers(0, 100))
        self.assertTrue(index.covers(0, 50))
        self.assertTrue(index.covers(60, 100))

    def test_an_empty_span_is_never_verified_silence(self) -> None:
        index = SilenceCandidateIndex([(0, 100)])
        self.assertFalse(index.covers(50, 50))
        self.assertFalse(index.covers(80, 20))


class SilenceChooseSplitTests(unittest.TestCase):
    """§4 row 4: parent midpoint ±5 s, both children at least 30 s."""

    rate = 16_000
    search = 5 * 16_000
    minimum = 30 * 16_000

    def choose(self, intervals, counters=None):
        return silence_choose_split(
            SilenceCandidateIndex(intervals),
            search_samples=self.search,
            counters=counters,
        )

    def span_pair(self, start, length):
        return (start, length, self.minimum, length // 2)

    def test_a_pause_near_the_midpoint_moves_the_split(self) -> None:
        parent_start, length = 0, 120 * self.rate
        pause_midpoint = 63 * self.rate  # 3 s after the 60 s midpoint
        choose = self.choose([(62 * self.rate, 64 * self.rate)])
        self.assertEqual(
            choose(*self.span_pair(parent_start, length)),
            pause_midpoint - parent_start,
        )

    def test_a_pause_outside_the_window_is_ignored(self) -> None:
        length = 120 * self.rate
        counters = SplitCounters()
        # 6 s after the midpoint, one second past the ±5 s window.
        choose = self.choose([(65 * self.rate, 67 * self.rate)], counters)
        self.assertEqual(choose(*self.span_pair(0, length)), length // 2)
        self.assertEqual((counters.silence_cuts, counters.fallbacks), (0, 1))

    def test_equidistant_pauses_resolve_to_the_earlier_one(self) -> None:
        length = 120 * self.rate
        choose = self.choose(
            [(57 * self.rate, 59 * self.rate), (61 * self.rate, 63 * self.rate)]
        )
        # Both midpoints sit 2 s from the target; the same input must always
        # plan the same way, so the earlier one wins.
        self.assertEqual(choose(*self.span_pair(0, length)), 58 * self.rate)

    def test_a_sixty_second_parent_only_admits_the_exact_midpoint(self) -> None:
        # §8: at 60 s the legal window collapses to one point, so a nearby pause
        # must not produce a 29 s child.
        length = 60 * self.rate
        counters = SplitCounters()
        choose = self.choose([(28 * self.rate, 30 * self.rate)], counters)
        self.assertEqual(choose(*self.span_pair(0, length)), length // 2)
        self.assertEqual((counters.silence_cuts, counters.fallbacks), (0, 1))

    def test_a_pause_inside_the_window_but_below_the_child_floor_is_rejected(
        self,
    ) -> None:
        # 65 s parent: the ±5 s search window reaches 29 s and 36 s, but the
        # 30 s child floor only admits [30 s, 35 s]. The floor has to win.
        length = 65 * self.rate
        choose = self.choose([(28 * self.rate, 30 * self.rate)])  # midpoint 29 s
        self.assertEqual(choose(*self.span_pair(0, length)), length // 2)
        choose = self.choose([(35 * self.rate, 37 * self.rate)])  # midpoint 36 s
        self.assertEqual(choose(*self.span_pair(0, length)), length // 2)

    def test_the_window_follows_a_non_zero_span_start(self) -> None:
        parent_start = 1_920_000
        length = 120 * self.rate
        choose = self.choose([(parent_start + 63 * self.rate - self.rate,
                               parent_start + 63 * self.rate + self.rate)])
        self.assertEqual(
            choose(*self.span_pair(parent_start, length)),
            63 * self.rate,
            "the chooser returns an offset, not an absolute sample",
        )

    def test_a_pause_exactly_on_the_midpoint_counts_as_a_fallback(self) -> None:
        length = 120 * self.rate
        counters = SplitCounters()
        choose = self.choose([(59 * self.rate, 61 * self.rate)], counters)
        self.assertEqual(choose(*self.span_pair(0, length)), length // 2)
        self.assertEqual((counters.silence_cuts, counters.fallbacks), (0, 1))

    def test_an_empty_index_always_returns_the_midpoint(self) -> None:
        length = 120 * self.rate
        counters = SplitCounters()
        choose = self.choose([], counters)
        self.assertEqual(choose(*self.span_pair(0, length)), length // 2)
        self.assertEqual(counters.silence_cuts, 0)
        self.assertEqual(counters.fallbacks, 1)


class SilenceAwareRecursionTests(unittest.TestCase):
    """The guard plus a silence chooser, end to end and Metal-free."""

    rate = 16_000

    def test_a_capped_leaf_splits_on_the_pause_and_reports_absolute_spans(
        self,
    ) -> None:
        length = 120 * self.rate
        span_start = 1_000_000
        pause = span_start + 63 * self.rate
        model = FakeModel(
            lambda values: FakeResult(
                "滿" if len(values) == length else f"葉@{len(values)}",
                generation_tokens=10 if len(values) == length else 3,
            )
        )
        leaves: list = []
        splits: list = []
        counters = SplitCounters()
        run_guard(
            model,
            tuple(range(length)),
            maximum_tokens=10,
            sample_rate=self.rate,
            on_leaf_result=leaves.append,
            on_span_split=lambda start, split, end: splits.append((start, split, end)),
            choose_split=silence_choose_split(
                SilenceCandidateIndex([(pause - self.rate, pause + self.rate)]),
                search_samples=5 * self.rate,
                counters=counters,
            ),
            span_start=span_start,
        )
        self.assertEqual(splits, [(span_start, pause, span_start + length)])
        self.assertEqual(
            [(leaf.start_sample, leaf.end_sample) for leaf in leaves],
            [(span_start, pause), (pause, span_start + length)],
        )
        self.assertEqual(counters.silence_cuts, 1)
        self.assertEqual(counters.fallbacks, 0)

    def test_a_short_tail_is_never_split_into_two_sub_minimum_children(self) -> None:
        # §8: 45 s at the cap has no legal split, so the established termination
        # policy applies even though a pause sits right where a cut would go.
        length = 45 * self.rate
        model = FakeModel(lambda values: FakeResult("滿", generation_tokens=10))
        gaps: list = []
        splits: list = []
        run_guard(
            model,
            tuple(range(length)),
            maximum_tokens=10,
            sample_rate=self.rate,
            on_leaf_gap=lambda gap: gaps.append(gap) or "【缺口】",
            on_span_split=lambda start, split, end: splits.append((start, split, end)),
            choose_split=silence_choose_split(
                SilenceCandidateIndex([(22 * self.rate, 23 * self.rate)]),
                search_samples=5 * self.rate,
            ),
            span_start=0,
            min_split_seconds=30.0,
        )
        self.assertEqual(splits, [])
        self.assertEqual(len(gaps), 1)
        self.assertEqual((gaps[0].start_sample, gaps[0].end_sample), (0, length))
        self.assertEqual(model.calls and len(model.calls), 1, "no retry after the cap")


if __name__ == "__main__":
    unittest.main()
