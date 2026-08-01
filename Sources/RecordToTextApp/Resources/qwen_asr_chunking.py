"""Token-budget guarded audio-span generation for the MLX Qwen helper.

This module intentionally has no MLX imports.  Keeping the recursive chunking
policy here makes the safety boundary testable on machines without Metal.
"""

from __future__ import annotations

from contextlib import AbstractContextManager, nullcontext
from typing import Any, Callable


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


def _default_emit(_event_type: str, **_payload: Any) -> None:
    return None


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
        return " ".join(part for part in (left, right) if part).strip()

    error = TokenLimitReached(
        label=label,
        span_seconds=span_seconds,
        generation_tokens=generation_tokens,
        maximum_tokens=maximum_tokens,
    )
    if on_leaf_skipped is not None:
        return on_leaf_skipped(error)
    raise error
