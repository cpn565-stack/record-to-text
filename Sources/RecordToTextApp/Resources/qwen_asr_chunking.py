"""Token-budget guarded audio-span generation for the MLX Qwen helper.

This module intentionally has no MLX imports.  Keeping the recursive chunking
policy here makes the safety boundary testable on machines without Metal.
"""

from __future__ import annotations

from bisect import bisect_left, bisect_right
from contextlib import AbstractContextManager, nullcontext
from dataclasses import dataclass
import re
from typing import Any, Callable, Sequence


Emit = Callable[..., Any]
HeartbeatFactory = Callable[[str], AbstractContextManager[Any]]
Generate = Callable[[Any], Any]
OnLeafComplete = Callable[[str], None]


class TokenLimitReached(RuntimeError):
    """Raised when a span is still capped after safe recursive splitting."""

    def __init__(
        self,
        *,
        label: str,
        span_seconds: float,
        generation_tokens: int,
        maximum_tokens: int,
    ) -> None:
        self.label = label
        self.span_seconds = span_seconds
        self.generation_tokens = generation_tokens
        self.maximum_tokens = maximum_tokens
        super().__init__(
            f"{label}（約 {span_seconds:.0f} 秒）達到 token 上限 "
            f"({generation_tokens}>={maximum_tokens})；為避免截斷，工作已停止。"
        )


OnLeafSkipped = Callable[[TokenLimitReached], str]


@dataclass(frozen=True)
class LeafSpan:
    """A finished span with its position in *original recording* samples.

    Positions are absolute, so the caller never has to reconstruct them from a
    chunk index. ``depth`` records how many token-limit splits produced it.
    """

    text: str
    start_sample: int
    end_sample: int
    generation_tokens: int | None
    maximum_tokens: int
    reached_token_limit: bool
    finish_reason: str
    span_seconds: float
    depth: int


@dataclass(frozen=True)
class GapSpan:
    """An irreducible span that hit the token cap and was recorded as a gap."""

    error: TokenLimitReached
    start_sample: int
    end_sample: int
    span_seconds: float
    depth: int


OnLeafResult = Callable[[LeafSpan], None]
OnLeafGap = Callable[[GapSpan], str]
#: ``(parent_start_sample, split_sample, parent_end_sample)`` in absolute
#: coordinates. Emitted before either child is generated so the caller can
#: commit the parent's ``split`` state and both pending children at once.
OnSpanSplit = Callable[[int, int, int], None]
#: ``(span_start, span_length, min_split_samples, midpoint)`` → the offset to
#: split at, measured from ``span_start``. Phase 1 replaces the arithmetic
#: midpoint with a nearby silence boundary; phase 0 keeps the midpoint.
ChooseSplit = Callable[[int, int, int, int], int]


@dataclass
class SplitCounters:
    """§7: recursive silence-cut and fallback counts, tracked per root.

    Kept separate from the Swift-side outer/inner tallies because the helper
    cannot add an RPC this phase; these travel out through the ``log`` stream.
    """

    silence_cuts: int = 0
    fallbacks: int = 0


class SilenceCandidateIndex:
    """The pauses Swift froze, as absolute-sample interval and midpoint lists.

    Mirrors Swift ``LocalSilenceCandidateIndex``. The helper only ever *selects*
    from what was persisted, so both sides have to agree on midpoint arithmetic:
    Swift uses ``start + (end - start) / 2`` on ``Int64``, which truncates
    exactly like Python ``//`` on the non-negative coordinates this holds.
    """

    __slots__ = ("intervals", "candidates")

    def __init__(self, intervals: Sequence[tuple[int, int]]) -> None:
        merged = self._merge(intervals)
        self.intervals: tuple[tuple[int, int], ...] = tuple(merged)
        self.candidates: tuple[int, ...] = tuple(
            sorted({start + (end - start) // 2 for start, end in merged})
        )

    @classmethod
    def from_plan(cls, intervals: Sequence[Any] | None) -> "SilenceCandidateIndex":
        """Build from the ``intervals`` array of a frozen ``silence-plan.json``."""

        pairs: list[tuple[int, int]] = []
        for entry in intervals or []:
            if not isinstance(entry, dict):
                continue
            start = entry.get("startSample")
            end = entry.get("endSample")
            # ``bool`` subclasses ``int``; a JSON ``true`` must not become
            # sample 1 and silently shift every boundary after it.
            if isinstance(start, bool) or not isinstance(start, int):
                continue
            if isinstance(end, bool) or not isinstance(end, int):
                continue
            if end > start >= 0:
                pairs.append((start, end))
        return cls(pairs)

    @staticmethod
    def _merge(intervals: Sequence[tuple[int, int]]) -> list[tuple[int, int]]:
        result: list[tuple[int, int]] = []
        for start, end in sorted(intervals):
            if end <= start:
                continue
            if result and start <= result[-1][1]:
                result[-1] = (result[-1][0], max(result[-1][1], end))
            else:
                result.append((start, end))
        return result

    def __bool__(self) -> bool:
        return bool(self.candidates)

    def candidates_in(self, lower: int, upper: int) -> Sequence[int]:
        """Candidates inside ``[lower, upper]``, in ascending order."""

        if lower > upper or not self.candidates:
            return ()
        first = bisect_left(self.candidates, lower)
        last = bisect_right(self.candidates, upper)
        return self.candidates[first:last]

    def covers(self, start_sample: int, end_sample: int) -> bool:
        """§6: does *every* sample of ``[start, end)`` lie inside one pause?

        Only a whole-leaf answer may turn an empty transcription into
        ``verifiedSilence``. Intervals arrive merged, so contiguous coverage can
        only come from a single one — a 90%-silent leaf is not evidence, and
        deleting the remaining 10% is exactly what §1 forbids.
        """

        if end_sample <= start_sample:
            return False
        return any(
            start <= start_sample and end >= end_sample
            for start, end in self.intervals
        )


def silence_choose_split(
    index: SilenceCandidateIndex,
    *,
    search_samples: int,
    counters: SplitCounters | None = None,
) -> ChooseSplit:
    """§4 row 4: the token-recursion split point.

    Candidates are pause midpoints within ``search_samples`` of the parent's
    arithmetic midpoint, and only ones that leave *both* children at or above
    ``min_split_samples`` qualify. Ties go to the earlier candidate so the same
    audio always plans the same way. With no qualifying candidate the legal
    midpoint is used — the caller's own termination policy decides whether that
    is still worth splitting.
    """

    window = max(int(search_samples), 0)

    def choose(
        span_start: int,
        span_length: int,
        min_split_samples: int,
        midpoint: int,
    ) -> int:
        parent_end = span_start + span_length
        target = span_start + midpoint
        best: int | None = None
        best_distance = -1
        for candidate in index.candidates_in(span_start, parent_end):
            distance = abs(candidate - target)
            if distance > window:
                continue
            if candidate - span_start < min_split_samples:
                continue
            if parent_end - candidate < min_split_samples:
                continue
            # Strict ``<`` keeps the first, i.e. earliest, of an equidistant pair.
            if best is None or distance < best_distance:
                best = candidate
                best_distance = distance
        if best is None or best == target:
            if counters is not None:
                counters.fallbacks += 1
            return midpoint
        if counters is not None:
            counters.silence_cuts += 1
        return best - span_start

    return choose


def _flexible_fragment(value: str) -> str:
    """Build a whitespace-tolerant regex fragment for model text."""

    parts = [part for part in re.split(r"\s+", value.strip()) if part]
    return r"\s+".join(re.escape(part) for part in parts)


def _prompt_candidates(prompt: str) -> list[str]:
    lines = [line.strip() for line in prompt.splitlines() if line.strip()]
    if not lines:
        return []

    candidates = [prompt.strip()]
    for line_count in range(len(lines) - 1, 0, -1):
        candidate = " ".join(lines[:line_count])
        if len(candidate) >= 40:
            candidates.append(candidate)
    return candidates


def _is_cjk_token(value: str) -> bool:
    return bool(value) and all(
        (0x3400 <= ord(char) <= 0x4DBF)
        or (0x4E00 <= ord(char) <= 0x9FFF)
        or (0xF900 <= ord(char) <= 0xFAFF)
        for char in value
    )


def _expand_implicit_cjk_terms(terms: Sequence[str]) -> list[str]:
    """Match the Swift parser's shorthand for space-separated CJK terms."""

    expanded: list[str] = []
    for term in terms:
        pieces = [piece for piece in re.split(r"\s+", term.strip()) if piece]
        if len(pieces) >= 2 and all(_is_cjk_token(piece) for piece in pieces):
            expanded.extend(pieces)
        elif term.strip():
            expanded.append(term.strip())
    return expanded


def remove_prompt_echo(
    text: str,
    prompt: str,
    terms: Sequence[str] | None = None,
    *,
    emit: Emit | None = None,
) -> str:
    """Remove model-repeated prompt text without changing real transcript text.

    Qwen3-ASR may repeat the system prompt either at the beginning or at the
    end of a chunk.  With glossary hints it can also emit the complete ordered
    term list followed by punctuation at the beginning, e.g. ``A B C。``.
    Only an exact full-list match is removed; a single term or an approximate
    match is left untouched to avoid deleting words actually spoken in the
    recording.
    """

    cleaned = text.strip()
    prompt = prompt.strip()
    if not cleaned:
        return cleaned

    def report(code: str, message: str) -> None:
        if emit is not None:
            emit("warning", code=code, message=message)

    for index, candidate in enumerate(_prompt_candidates(prompt)):
        if index > 0 and len(candidate) < 40:
            continue
        pattern = _flexible_fragment(candidate)
        leading_match = re.match(rf"^{pattern}\s*", cleaned)
        if leading_match is not None:
            cleaned = cleaned[leading_match.end():].lstrip()
            report(
                "prompt_echo_removed",
                "模型輸出開頭重複了送入的 Prompt，已移除重複內容。",
            )
            break

    normalized_terms = _expand_implicit_cjk_terms(
        [term for term in (terms or []) if term.strip()]
    )
    if len(normalized_terms) >= 2:
        term_sequence = r"(?:[\s,，、;；:：|/。．.!！?？]+)".join(
            _flexible_fragment(term) for term in normalized_terms
        )
        leading_terms = re.match(
            rf"^\s*{term_sequence}"
            r"\s*[。．.!！?？；;,:：,，、]+\s*",
            cleaned,
        )
        if leading_terms is not None:
            cleaned = cleaned[leading_terms.end():].lstrip()
            report(
                "leading_glossary_echo_removed",
                "模型輸出開頭重複了完整詞庫清單，已移除重複內容。",
            )

    for index, candidate in enumerate(_prompt_candidates(prompt)):
        if index > 0 and len(candidate) < 40:
            continue
        pattern = _flexible_fragment(candidate)
        trailing_match = re.search(rf"\s*{pattern}\s*$", cleaned)
        if trailing_match is not None:
            cleaned = cleaned[:trailing_match.start()].rstrip()
            report(
                "prompt_echo_removed",
                "模型輸出末尾重複了送入的 Prompt，已移除重複內容。",
            )
            break

    return cleaned


def _default_emit(_event_type: str, **_payload: Any) -> None:
    return None


def _is_cjk_punct(char: str) -> bool:
    return bool(char) and (
        (0x3000 <= ord(char) <= 0x303F) or (0xFF00 <= ord(char) <= 0xFFEF)
    )


def _is_cjk_char(char: str) -> bool:
    return _is_cjk_token(char) or _is_cjk_punct(char)


def _needs_word_separator(left: str, right: str) -> bool:
    """Decide whether two transcript fragments need a space at the seam.

    Chinese text flows without spaces, so no separator is inserted between
    CJK characters or around CJK punctuation.  A space is only added when it
    is needed to keep Latin/digit words from gluing together.
    """

    if not left or not right:
        return False
    if _is_cjk_punct(left[-1]) or _is_cjk_punct(right[0]):
        return False
    if _is_cjk_token(left[-1]) and _is_cjk_token(right[0]):
        return False
    return True


def join_transcript_parts(parts: Sequence[str]) -> str:
    """Join chunk/split fragments without injecting spurious spaces."""

    joined = ""
    for part in parts:
        if not part:
            continue
        if joined and _needs_word_separator(joined, part):
            joined += " "
        joined += part.strip()
    return joined.strip()


class TranscriptAccumulator:
    """Collect cleaned leaf output while retaining failure-quality signals."""

    def __init__(
        self,
        *,
        prompt: str,
        terms: Sequence[str] | None = None,
        emit: Emit = _default_emit,
    ) -> None:
        self._prompt = prompt
        self._terms = terms or []
        self._emit = emit
        self._parts: list[str] = []
        self._has_prompt_echo_only_chunk = False
        self._contains_skipped_audio = False

    def record_completed_text(self, text: str) -> None:
        original = text.strip()
        cleaned = remove_prompt_echo(
            text,
            self._prompt,
            self._terms,
            emit=self._emit,
        )
        if original and not cleaned:
            self._has_prompt_echo_only_chunk = True
        if cleaned:
            self._parts.append(cleaned)

    def record_skipped_span(self, error: TokenLimitReached) -> str:
        self._contains_skipped_audio = True
        self._emit(
            "warning",
            code="chunk_skipped_token_limit",
            message=(
                f"{error.label} 約 {error.span_seconds:.0f} 秒仍達到 token 上限，"
                "已跳過此片段並繼續後續轉錄。"
            ),
        )
        marker = (
            f"【此處約缺少 {error.span_seconds:.0f} 秒：模型達到 token 上限，"
            "已跳過此片段】"
        )
        self._parts.append(marker)
        return marker

    def record_checkpoint_text(
        self,
        text: str,
        *,
        contains_skipped_audio: bool = False,
    ) -> None:
        cleaned = text.strip()
        if cleaned:
            self._parts.append(cleaned)
        self._contains_skipped_audio = (
            self._contains_skipped_audio or contains_skipped_audio
        )

    def mark_prompt_echo_only(self) -> None:
        self._has_prompt_echo_only_chunk = True

    @property
    def text(self) -> str:
        return join_transcript_parts(self._parts)

    @property
    def has_prompt_echo_only_chunk(self) -> bool:
        return self._has_prompt_echo_only_chunk

    @property
    def contains_skipped_audio(self) -> bool:
        return self._contains_skipped_audio


def _default_heartbeat(_message: str) -> AbstractContextManager[Any]:
    return nullcontext()


def generate_span_with_token_guard(
    model: Any,
    span: Any,
    *,
    generation_arguments: dict[str, Any],
    sample_rate: int,
    maximum_tokens: int,
    label: str,
    emit: Emit = _default_emit,
    heartbeat_factory: HeartbeatFactory = _default_heartbeat,
    generate: Generate | None = None,
    on_leaf_complete: OnLeafComplete | None = None,
    on_leaf_skipped: OnLeafSkipped | None = None,
    on_leaf_result: OnLeafResult | None = None,
    on_leaf_gap: OnLeafGap | None = None,
    on_span_split: OnSpanSplit | None = None,
    choose_split: ChooseSplit | None = None,
    span_start: int = 0,
    min_split_seconds: float = 30.0,
    max_depth: int = 6,
    depth: int = 0,
) -> str:
    """Generate a span, recursively splitting only when the token cap is hit.

    A span that remains capped at the minimum size or maximum depth raises
    ``TokenLimitReached`` unless ``on_leaf_skipped`` is provided.  The optional
    callback can replace that irreducible span with an explicit gap marker so
    the caller can continue processing later audio without treating truncated
    text as valid.

    ``span_start`` is this span's first sample in *original recording*
    coordinates. It is threaded through every recursion so leaf and gap callbacks
    report absolute positions; callers must never rebuild them from a chunk
    index. A missing ``generation_tokens`` is reported as ``None`` rather than
    coerced to zero, so the caller can refuse to treat it as a proven completion.
    """

    with heartbeat_factory(label):
        if generate is None:
            result = model.generate(span, **generation_arguments)
        else:
            result = generate(span)

    text = getattr(result, "text", None)
    if not isinstance(text, str):
        raise RuntimeError("MLX-Audio did not return a text transcript")

    raw_tokens = getattr(result, "generation_tokens", None)
    generation_tokens: int | None
    if isinstance(raw_tokens, bool) or not isinstance(raw_tokens, int):
        generation_tokens = None
    else:
        generation_tokens = int(raw_tokens)
    span_seconds = len(span) / float(sample_rate)
    span_end = span_start + len(span)
    capped = generation_tokens is not None and generation_tokens >= maximum_tokens

    if not capped:
        if on_leaf_complete is not None:
            on_leaf_complete(text)
        if on_leaf_result is not None:
            on_leaf_result(
                LeafSpan(
                    text=text,
                    start_sample=span_start,
                    end_sample=span_end,
                    generation_tokens=generation_tokens,
                    maximum_tokens=maximum_tokens,
                    reached_token_limit=False,
                    finish_reason="stop" if generation_tokens is not None else "unknown",
                    span_seconds=span_seconds,
                    depth=depth,
                )
            )
        return text

    min_split_samples = max(int(min_split_seconds * sample_rate), sample_rate)
    if len(span) >= min_split_samples * 2 and depth < max_depth:
        emit(
            "log",
            level="info",
            message=(
                f"{label} 達到 token 上限 "
                f"({generation_tokens}>={maximum_tokens}，約 {span_seconds:.0f} 秒)，"
                f"自動對半再轉（深度 {depth + 1}）。"
            ),
        )
        midpoint = len(span) // 2
        if choose_split is None:
            split_at = midpoint
        else:
            # Clamp so a silence-aware chooser can never yield an empty or
            # below-minimum half, which would recurse forever.
            lower = min_split_samples
            upper = len(span) - min_split_samples
            split_at = max(
                lower,
                min(
                    upper,
                    int(choose_split(span_start, len(span), min_split_samples, midpoint)),
                ),
            )
        absolute_split = span_start + split_at
        if on_span_split is not None:
            on_span_split(span_start, absolute_split, span_end)
        left = generate_span_with_token_guard(
            model,
            span[:split_at],
            generation_arguments=generation_arguments,
            sample_rate=sample_rate,
            maximum_tokens=maximum_tokens,
            label=f"{label}·左",
            emit=emit,
            heartbeat_factory=heartbeat_factory,
            generate=generate,
            on_leaf_complete=on_leaf_complete,
            on_leaf_skipped=on_leaf_skipped,
            on_leaf_result=on_leaf_result,
            on_leaf_gap=on_leaf_gap,
            on_span_split=on_span_split,
            choose_split=choose_split,
            span_start=span_start,
            min_split_seconds=min_split_seconds,
            max_depth=max_depth,
            depth=depth + 1,
        )
        right = generate_span_with_token_guard(
            model,
            span[split_at:],
            generation_arguments=generation_arguments,
            sample_rate=sample_rate,
            maximum_tokens=maximum_tokens,
            label=f"{label}·右",
            emit=emit,
            heartbeat_factory=heartbeat_factory,
            generate=generate,
            on_leaf_complete=on_leaf_complete,
            on_leaf_skipped=on_leaf_skipped,
            on_leaf_result=on_leaf_result,
            on_leaf_gap=on_leaf_gap,
            on_span_split=on_span_split,
            choose_split=choose_split,
            span_start=absolute_split,
            min_split_seconds=min_split_seconds,
            max_depth=max_depth,
            depth=depth + 1,
        )
        return join_transcript_parts((left, right))

    error = TokenLimitReached(
        label=label,
        span_seconds=span_seconds,
        generation_tokens=int(generation_tokens or 0),
        maximum_tokens=maximum_tokens,
    )
    if on_leaf_gap is not None:
        return on_leaf_gap(
            GapSpan(
                error=error,
                start_sample=span_start,
                end_sample=span_end,
                span_seconds=span_seconds,
                depth=depth,
            )
        )
    if on_leaf_skipped is not None:
        return on_leaf_skipped(error)
    raise error
