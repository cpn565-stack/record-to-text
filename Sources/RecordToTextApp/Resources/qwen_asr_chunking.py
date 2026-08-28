"""Token-budget guarded audio-span generation for the MLX Qwen helper.

This module intentionally has no MLX imports.  Keeping the recursive chunking
policy here makes the safety boundary testable on machines without Metal.
"""

from __future__ import annotations

from contextlib import AbstractContextManager, nullcontext
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
    """

    with heartbeat_factory(label):
        if generate is None:
            result = model.generate(span, **generation_arguments)
        else:
            result = generate(span)

    text = getattr(result, "text", None)
    if not isinstance(text, str):
        raise RuntimeError("MLX-Audio did not return a text transcript")

    generation_tokens = int(getattr(result, "generation_tokens", 0) or 0)
    span_seconds = len(span) / float(sample_rate)
    if generation_tokens < maximum_tokens:
        if on_leaf_complete is not None:
            on_leaf_complete(text)
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
        left = generate_span_with_token_guard(
            model,
            span[:midpoint],
            generation_arguments=generation_arguments,
            sample_rate=sample_rate,
            maximum_tokens=maximum_tokens,
            label=f"{label}·左",
            emit=emit,
            heartbeat_factory=heartbeat_factory,
            generate=generate,
            on_leaf_complete=on_leaf_complete,
            on_leaf_skipped=on_leaf_skipped,
            min_split_seconds=min_split_seconds,
            max_depth=max_depth,
            depth=depth + 1,
        )
        right = generate_span_with_token_guard(
            model,
            span[midpoint:],
            generation_arguments=generation_arguments,
            sample_rate=sample_rate,
            maximum_tokens=maximum_tokens,
            label=f"{label}·右",
            emit=emit,
            heartbeat_factory=heartbeat_factory,
            generate=generate,
            on_leaf_complete=on_leaf_complete,
            on_leaf_skipped=on_leaf_skipped,
            min_split_seconds=min_split_seconds,
            max_depth=max_depth,
            depth=depth + 1,
        )
        return join_transcript_parts((left, right))

    error = TokenLimitReached(
        label=label,
        span_seconds=span_seconds,
        generation_tokens=generation_tokens,
        maximum_tokens=maximum_tokens,
    )
    if on_leaf_skipped is not None:
        return on_leaf_skipped(error)
    raise error
