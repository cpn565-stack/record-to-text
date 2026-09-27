#!/usr/bin/env python3
"""Version-aware JSONL helper for Qwen3-ASR through MLX-Audio.

The helper keeps stdout machine-readable. Third-party library output is redirected
to stderr so the Swift app can treat every stdout line as one JSON object.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.metadata
import inspect
import json
import math
import os
from pathlib import Path
import re
import signal
import sys
import tempfile
import threading
import time
from typing import Any, Sequence

from qwen_asr_chunking import (
    GapSpan,
    LeafSpan,
    SilenceCandidateIndex,
    SplitCounters,
    TokenLimitReached,
    TranscriptAccumulator,
    generate_span_with_token_guard,
    join_transcript_parts,
    silence_choose_split,
)
from qwen_asr_local_checkpoint import (
    SPLIT_POLICY_TOKEN_MIDPOINT,
    SPLIT_POLICY_TOKEN_SILENCE,
    STATE_COMPLETED,
    STATE_FAILED,
    STATE_GAP,
    STATE_VERIFIED_SILENCE,
    CheckpointContractError,
    find_root_plan,
    load_silence_plan,
    open_root_state_store,
    ordered_covering_leaves,
    split_child_ids,
    verify_root_plan_against_audio,
)


# Preserve one private descriptor for JSONL, then redirect fd 1 itself to
# stderr. This prevents native MLX/Metal output from corrupting the event stream.
_EVENTS_FD = os.dup(sys.stdout.fileno())
EVENTS = os.fdopen(
    _EVENTS_FD,
    "w",
    encoding="utf-8",
    buffering=1,
    closefd=True,
)
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
EVENT_LOCK = threading.Lock()
ALLOWED_MODEL_IDS = {
    "mlx-community/Qwen3-ASR-1.7B-8bit",
    "mlx-community/Qwen3-ASR-1.7B-bf16",
    "mlx-community/Qwen3-ASR-0.6B-8bit",
}
# Must stay equal to LocalCheckpointSchema.asrContractVersion; a Swift test
# asserts the pair so the two cannot drift apart silently.
ASR_CONTRACT_VERSION = "rec2t-local-asr-v2"

PROMPT_CHANNEL_SYSTEM = "system_prompt"
PROMPT_CHANNEL_CONTEXT = "context"
PROMPT_CHANNEL_NONE = "none"
ALLOWED_PROMPT_CHANNELS = frozenset(
    {PROMPT_CHANNEL_SYSTEM, PROMPT_CHANNEL_CONTEXT, PROMPT_CHANNEL_NONE}
)


def emit(event_type: str, **payload: Any) -> None:
    event = {"type": event_type, **payload}
    with EVENT_LOCK:
        EVENTS.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
        EVENTS.flush()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="record-to-text MLX ASR helper")
    parser.add_argument("--request-json")
    parser.add_argument("--events-jsonl", default="-")
    parser.add_argument(
        "--server",
        action="store_true",
        help="Keep one Python/MLX process alive and accept request JSON on stdin.",
    )
    parser.add_argument(
        "--report-runtime",
        action="store_true",
        help="Print one runtime capability line and exit, without loading a model.",
    )
    return parser.parse_args()


def load_request(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_request(request: dict[str, Any]) -> None:
    required_strings = [
        "jobID",
        "audioPath",
        "outputPath",
        "modelID",
        "language",
        "prompt",
        "modelCacheDirectory",
    ]
    for key in required_strings:
        value = request.get(key)
        if not isinstance(value, str):
            raise ValueError(f"Request field {key} must be a string")

    audio = Path(request["audioPath"])
    output = Path(request["outputPath"])
    cache = Path(request["modelCacheDirectory"])
    if not audio.is_absolute() or not audio.is_file():
        raise ValueError("audioPath must be an existing absolute file path")
    if not output.is_absolute() or not cache.is_absolute():
        raise ValueError("outputPath and modelCacheDirectory must be absolute paths")

    model_reference = request["modelID"]
    local_model = Path(model_reference)
    is_local_model = local_model.is_absolute() and local_model.is_dir()
    if model_reference not in ALLOWED_MODEL_IDS and not is_local_model:
        raise ValueError("modelID is not in the Apple Silicon runtime allowlist")
    if not is_local_model:
        revision = request.get("modelRevision")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise ValueError("Remote modelID requires a pinned 40-character modelRevision")

    terms = request.get("terms", [])
    if not isinstance(terms, list) or not all(isinstance(term, str) for term in terms):
        raise ValueError("terms must be an array of strings")

    maximum_tokens = request.get("maximumTokens", 16_384)
    if isinstance(maximum_tokens, bool) or not isinstance(maximum_tokens, int):
        raise ValueError("maximumTokens must be an integer")
    if maximum_tokens < 1 or maximum_tokens > 16_384:
        raise ValueError("maximumTokens must be between 1 and 16384")

    chunk_duration = request.get("chunkDurationSeconds", 120)
    if isinstance(chunk_duration, bool) or not isinstance(chunk_duration, (int, float)):
        raise ValueError("chunkDurationSeconds must be numeric")
    if chunk_duration < 1 or chunk_duration > 1200:
        raise ValueError("chunkDurationSeconds must be between 1 and 1200")

    time_offset = request.get("timeOffsetSeconds", 0)
    if (
        isinstance(time_offset, bool)
        or not isinstance(time_offset, (int, float))
        or not math.isfinite(time_offset)
        or time_offset < 0
    ):
        raise ValueError("timeOffsetSeconds must be a finite non-negative number")

    validate_checkpoint_v2(request.get("checkpointV2"))


def validate_checkpoint_v2(block: Any) -> None:
    """Reject a partially populated v2 coordinate block.

    Swift sends every coordinate or none. Accepting a half-present block would
    let the helper mix v2 evidence with index-derived guesses, which is exactly
    the ambiguity the contract exists to remove.
    """
    if block is None:
        return
    if not isinstance(block, dict):
        raise ValueError("checkpointV2 must be an object")

    strings = ["rootID", "planID", "identityDigest"]
    for key in strings:
        value = block.get(key)
        if not isinstance(value, str) or not value:
            raise ValueError(f"checkpointV2.{key} must be a non-empty string")

    prompt_channel = block.get("promptChannel")
    if not isinstance(prompt_channel, str) or prompt_channel not in ALLOWED_PROMPT_CHANNELS:
        raise ValueError(
            "checkpointV2.promptChannel must be one of "
            + ", ".join(sorted(ALLOWED_PROMPT_CHANNELS))
        )

    directory = block.get("directory")
    if not isinstance(directory, str) or not Path(directory).is_absolute():
        raise ValueError("checkpointV2.directory must be an absolute path")

    sample_rate = block.get("sampleRate")
    if isinstance(sample_rate, bool) or not isinstance(sample_rate, int):
        raise ValueError("checkpointV2.sampleRate must be an integer")
    if sample_rate != 16_000:
        raise ValueError("checkpointV2.sampleRate must be 16000")

    coordinates = ["audioStartSample", "workStartSample", "workEndSample"]
    values: dict[str, int] = {}
    for key in coordinates:
        value = block.get(key)
        if isinstance(value, bool) or not isinstance(value, int):
            raise ValueError(f"checkpointV2.{key} must be an integer")
        if value < 0:
            raise ValueError(f"checkpointV2.{key} must be non-negative")
        values[key] = value

    if values["workEndSample"] <= values["workStartSample"]:
        raise ValueError("checkpointV2.workEndSample must exceed workStartSample")
    if values["audioStartSample"] < values["workStartSample"]:
        raise ValueError("checkpointV2.audioStartSample must not precede workStartSample")


def installed_qwen_source() -> str:
    """Read the installed implementation without importing MLX or touching Metal."""
    try:
        distribution = importlib.metadata.distribution("mlx-audio")
        relative = Path("mlx_audio/stt/models/qwen3_asr/qwen3_asr.py")
        path = Path(distribution.locate_file(relative))
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def static_capability() -> tuple[bool, bool]:
    source = installed_qwen_source()
    return "system_prompt" in source, "context" in source


def resolve_prompt_channel(
    prompt: str,
    supports_system_prompt: bool,
    supports_context: bool,
) -> str:
    """Which generation argument the prompt will actually travel in.

    One function serves both the pre-flight report (static capability, before
    any model is loaded) and ``transcribe`` (runtime capability, after loading),
    so the declared and effective channels cannot drift apart.
    """
    if prompt and supports_system_prompt:
        return PROMPT_CHANNEL_SYSTEM
    if prompt and supports_context:
        return PROMPT_CHANNEL_CONTEXT
    return PROMPT_CHANNEL_NONE


def distribution_version(name: str) -> str | None:
    """Installed version of a distribution, read from metadata only."""
    try:
        return importlib.metadata.version(name)
    except Exception:
        return None


def report_runtime() -> None:
    """Publish the facts Swift needs before it freezes an identity document.

    Reads package metadata and the installed model source only: no MLX import,
    no Metal context, no weights. That keeps the probe cheap enough to run at
    job start and safe to run while another job is transcribing.
    """
    supports_system_prompt, supports_context = static_capability()
    emit(
        "runtime",
        asrContractVersion=ASR_CONTRACT_VERSION,
        supportsSystemPrompt=supports_system_prompt,
        supportsContext=supports_context,
        mlxVersion=distribution_version("mlx"),
        mlxAudioVersion=distribution_version("mlx-audio"),
    )


def atomic_write_text(text: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        suffix=".tmp",
        dir=destination.parent,
        text=True,
    )
    try:
        with os.fdopen(
            file_descriptor,
            "w",
            encoding="utf-8",
            newline="\n",
        ) as handle:
            handle.write(text.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, destination)
    except Exception:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def chunk_checkpoint_path(output: Path, request: dict[str, Any]) -> Path:
    directory_value = request.get("chunkCheckpointDirectory")
    if isinstance(directory_value, str) and directory_value.strip():
        directory = Path(directory_value)
        filename = (
            f"segment-{int(request.get('segmentIndex', 1)):04d}-"
            f"of-{int(request.get('segmentCount', 1)):04d}.chunks.json"
        )
        return directory / filename
    return output.with_name(f"{output.name}.chunks.json")


def chunk_checkpoint_fingerprint(
    request: dict[str, Any],
    *,
    audio_length: int,
    sample_rate: int,
    total_chunks: int,
    chunk_duration: float,
) -> str:
    payload = {
        "audioLength": audio_length,
        "sampleRate": sample_rate,
        "totalChunks": total_chunks,
        "chunkDurationSeconds": chunk_duration,
        "modelID": request.get("modelID"),
        "modelRevision": request.get("modelRevision"),
        "maximumTokens": request.get("maximumTokens"),
        "prompt": request.get("prompt"),
        "terms": request.get("terms"),
    }
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def render_timed_transcript(
    completed_chunks: list[dict[str, Any]],
    *,
    samples_per_chunk: int,
    sample_rate: int,
    audio_length: int,
    time_offset: float,
) -> str:
    """Group the existing 120-second chunks into ten-minute TXT sections.

    Checkpoints keep their original plain text; timing is reconstructed from
    sample positions on both fresh runs and resumes. These are audio-window
    boundaries, not sentence alignment. A partial draft ends at its last
    completed chunk, and a short final section ends at the actual audio end.
    """
    def timestamp(seconds: float) -> str:
        whole_seconds = int(seconds)
        hours, remainder = divmod(whole_seconds, 3600)
        minutes, seconds = divmod(remainder, 60)
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"

    sections: list[str] = []
    parts: list[str] = []
    section_bucket: int | None = None
    section_start = section_end = 0

    def flush() -> None:
        text = join_transcript_parts(parts)
        # A heading must never turn an empty ASR result into a valid transcript.
        if text:
            start = timestamp(time_offset + section_start / sample_rate)
            end = timestamp(time_offset + section_end / sample_rate)
            sections.append(f"[{start} - {end}]\n\n{text}")

    for chunk in completed_chunks:
        start = chunk["index"] * samples_per_chunk
        end = min(start + samples_per_chunk, audio_length)
        bucket = start // (600 * sample_rate)
        if bucket != section_bucket:
            flush()
            parts = []
            section_start = start
            section_bucket = bucket
        section_end = end
        parts.append(chunk["text"])
    flush()
    return "\n\n".join(sections)


def write_chunk_checkpoint(
    destination: Path,
    *,
    fingerprint: str,
    total_chunks: int,
    completed_chunks: list[dict[str, Any]],
) -> None:
    atomic_write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "fingerprint": fingerprint,
                "totalChunks": total_chunks,
                "completedChunks": completed_chunks,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ),
        destination,
    )


def load_chunk_checkpoint(
    source: Path,
    *,
    fingerprint: str,
    total_chunks: int,
) -> list[dict[str, Any]]:
    if not source.is_file():
        return []
    try:
        payload = json.loads(source.read_text(encoding="utf-8"))
    except Exception as error:
        emit(
            "warning",
            code="chunk_checkpoint_invalid",
            message=f"內部 chunk checkpoint 無法讀取，將從頭處理本段：{exception_details(error)}",
        )
        return []
    if (
        not isinstance(payload, dict)
        or payload.get("schemaVersion") != 1
        or payload.get("fingerprint") != fingerprint
        or payload.get("totalChunks") != total_chunks
    ):
        emit(
            "warning",
            code="chunk_checkpoint_incompatible",
            message="內部 chunk checkpoint 與目前音訊／模型／Prompt 不相容，將從頭處理本段。",
        )
        return []
    completed = payload.get("completedChunks")
    if not isinstance(completed, list) or len(completed) > total_chunks:
        return []
    validated: list[dict[str, Any]] = []
    for expected_index, item in enumerate(completed):
        if (
            not isinstance(item, dict)
            or item.get("index") != expected_index
            or not isinstance(item.get("text"), str)
            or not isinstance(item.get("containsSkippedAudio"), bool)
        ):
            emit(
                "warning",
                code="chunk_checkpoint_invalid",
                message="內部 chunk checkpoint 順序或內容無效，將從頭處理本段。",
            )
            return []
        validated.append(item)
    return validated


def configure_environment(request: dict[str, Any]) -> None:
    cache = request["modelCacheDirectory"]
    os.environ["HF_HOME"] = cache
    os.environ["HF_HUB_CACHE"] = str(Path(cache) / "hub")
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    if request.get("offline", False):
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"


def resolve_model_reference(request: dict[str, Any]) -> str:
    model_reference = request["modelID"]
    local_model = Path(model_reference)
    if local_model.is_absolute() and local_model.is_dir():
        return str(local_model)

    from huggingface_hub import snapshot_download

    return snapshot_download(
        repo_id=model_reference,
        revision=request["modelRevision"],
        cache_dir=str(Path(request["modelCacheDirectory"]) / "hub"),
        local_files_only=bool(request.get("offline", False)),
    )


@contextlib.contextmanager
def heartbeat(message: str):
    stopped = threading.Event()

    def run() -> None:
        while not stopped.wait(10):
            emit("heartbeat", message=message)

    thread = threading.Thread(target=run, name="record-to-text-heartbeat", daemon=True)
    thread.start()
    try:
        yield
    finally:
        stopped.set()
        thread.join(timeout=1)


_MODEL_CACHE: tuple[str, str | None, Any, bool, bool] | None = None


def load_model_once(request: dict[str, Any]) -> tuple[Any, bool, bool]:
    global _MODEL_CACHE

    cache_key = (request["modelID"], request.get("modelRevision"))
    if _MODEL_CACHE is not None:
        cached_id, cached_revision, model, supports_system_prompt, supports_context = _MODEL_CACHE
        if (cached_id, cached_revision) == cache_key:
            emit(
                "log",
                level="technical",
                message="模型快取命中：略過模型重新下載與載入。",
            )
            return model, supports_system_prompt, supports_context

    emit("stage", value="loading_model")
    emit(
        "log",
        level="technical",
        message="模型快取未命中：本次 helper session 只載入一次模型。",
    )

    # MLX can terminate at the native layer when Metal is unavailable. Keep this
    # import inside the helper process so such a failure cannot crash the Swift app.
    with heartbeat("正在載入 Qwen3-ASR 模型"):
        with contextlib.redirect_stdout(sys.stderr):
            from mlx_audio.stt.utils import load_model

            model_reference = resolve_model_reference(request)
            model = load_model(model_reference)

    signature = inspect.signature(model.generate)
    supports_system_prompt = "system_prompt" in signature.parameters
    supports_context = "context" in signature.parameters
    _MODEL_CACHE = (
        request["modelID"],
        request.get("modelRevision"),
        model,
        supports_system_prompt,
        supports_context,
    )
    emit(
        "log",
        level="technical",
        message="模型已載入並保留在長駐 helper；後續工作會重用。",
    )
    return model, supports_system_prompt, supports_context


def clean_leaf_text(
    text: str, *, prompt: str, terms: Sequence[str], emit: Any
) -> tuple[str, bool]:
    """Apply the existing prompt-echo cleaning to a single leaf's raw output."""
    accumulator = TranscriptAccumulator(prompt=prompt, terms=terms, emit=emit)
    accumulator.record_completed_text(text)
    return accumulator.text, accumulator.has_prompt_echo_only_chunk


def format_sample_time(samples: int, *, sample_rate: int) -> str:
    """Clock label for an absolute sample position, matching the TXT headings.

    v2 coordinates are already in original-recording space, so no offset is
    applied here; adding one would double-count a sliced job.
    """
    whole_seconds = int(samples) // sample_rate
    hours, remainder = divmod(whole_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def gap_marker(leaf: dict[str, Any], *, sample_rate: int) -> str:
    """Render a gap from structured evidence, never from stored prose."""
    span_seconds = (
        int(leaf["endSample"]) - int(leaf["startSample"])
    ) / sample_rate
    return (
        f"【此處約缺少 {span_seconds:.0f} 秒：模型達到 token 上限，"
        "已跳過此片段】"
    )


def render_timed_transcript_v2(
    leaves: list[dict[str, Any]],
    *,
    display_groups: list[dict[str, Any]],
    sample_rate: int,
) -> str:
    """Group verified leaves into ten-minute TXT sections by absolute samples.

    Section boundaries come from the frozen manifest, never from a leaf index,
    so a resumed or recursively split tree renders exactly like a fresh one.
    """
    sections: list[str] = []
    for group in display_groups:
        group_start = int(group["startSample"])
        group_end = int(group["endSample"])
        parts: list[str] = []
        first_start: int | None = None
        last_end = group_start
        for leaf in leaves:
            start = int(leaf["startSample"])
            end = int(leaf["endSample"])
            if start < group_start or start >= group_end:
                continue
            if leaf.get("state") == "gap":
                parts.append(gap_marker(leaf, sample_rate=sample_rate))
            else:
                text = str((leaf.get("result") or {}).get("text") or "").strip()
                if text:
                    parts.append(text)
            if first_start is None:
                first_start = start
            last_end = max(last_end, end)
        text = join_transcript_parts(parts)
        # A heading must never turn an empty ASR result into a valid transcript.
        if not text or first_start is None:
            continue
        heading_start = format_sample_time(first_start, sample_rate=sample_rate)
        heading_end = format_sample_time(last_end, sample_rate=sample_rate)
        sections.append(f"[{heading_start} - {heading_end}]\n\n{text}")
    return "\n\n".join(sections)


def transcribe_v2(
    *,
    request: dict[str, Any],
    block: dict[str, Any],
    model: Any,
    generation_arguments: dict[str, Any],
    sample_rate: int,
    maximum_tokens: int,
    min_split_seconds: float,
    audio: Any,
    prompt: str,
    terms: Sequence[str],
    output: Path,
    started: float,
) -> None:
    """Transcribe one root from its frozen v2 plan, committing every leaf.

    All boundaries come from the manifest. The array index into ``audio`` is
    always ``absoluteSample - audioStartSample``; nothing is derived from
    ``segmentIndex`` or a chunk counter.
    """
    root_id = str(block["rootID"])
    audio_start = int(block["audioStartSample"])
    store, _identity, manifest, _identity_digest = open_root_state_store(
        Path(block["directory"]), root_id=root_id, emit=emit
    )

    # The request states what Swift believes it froze. If the manifest on disk
    # disagrees, this helper is pointed at someone else's plan.
    for key in ("identityDigest", "planID"):
        if str(manifest.get(key)) != str(block[key]):
            raise CheckpointContractError(
                "local_identity_mismatch",
                f"request 的 {key} 與 manifest 不符，拒絕沿用 checkpoint。",
            )
    for key in ("sampleRate", "workStartSample", "workEndSample"):
        if int(manifest.get(key, -1)) != int(block[key]):
            raise CheckpointContractError(
                "local_identity_mismatch",
                f"request 的 {key} 與 manifest 不符，拒絕沿用 checkpoint。",
            )

    root_plan = find_root_plan(manifest, root_id)
    root_start = int(root_plan["startSample"])
    root_end = int(root_plan["endSample"])
    pcm_digest, plan_samples = verify_root_plan_against_audio(
        root_plan,
        audio_path=Path(request["audioPath"]),
        audio_start_sample=audio_start,
    )
    store.load()

    audio_length = len(audio)
    if audio_length < plan_samples:
        raise CheckpointContractError(
            "local_pcm_mismatch",
            f"解碼得到 {audio_length} 個 sample，少於 plan 記錄的 {plan_samples}；"
            "拒絕用較短的音訊冒充完整 root。",
        )

    display_groups = list(manifest.get("displayGroups") or [])
    completed_before = len(ordered_covering_leaves(store.state))

    # §7: Swift froze the analysis; the helper only selects from it. No second
    # ffmpeg pipeline runs here, and an absent plan means midpoint splits.
    silence_plan = store.silence_plan
    silence_index = (
        SilenceCandidateIndex.from_plan(silence_plan.intervals)
        if silence_plan is not None
        else SilenceCandidateIndex(())
    )
    split_counters = SplitCounters()
    choose_split = (
        silence_choose_split(
            silence_index,
            search_samples=silence_plan.search_samples(sample_rate),
            counters=split_counters,
        )
        if silence_plan is not None
        else None
    )
    if silence_plan is not None:
        emit(
            "log",
            level="info",
            message=(
                f"已載入凍結的靜音計畫：{len(silence_index.intervals)} 段靜音、"
                f"{len(silence_index.candidates)} 個候選切點"
                f"（遞迴搜尋 ±{silence_plan.recursive_search_seconds:.2f} 秒）"
                + ("；清單已超過保存上限，遞迴改用合法中點。" if silence_plan.truncated else "。")
            ),
        )

    def rendered_text() -> str:
        return render_timed_transcript_v2(
            ordered_covering_leaves(store.state),
            display_groups=display_groups,
            sample_rate=sample_rate,
        )

    def preserve_partial_output() -> None:
        partial_text = rendered_text()
        if not partial_text:
            return
        partial_output = output.with_name(f"{output.name}.partial.txt")
        try:
            atomic_write_text(partial_text, partial_output)
        except Exception as error:
            emit(
                "warning",
                code="partial_output_write_failed",
                message=f"無法保存未完成草稿：{exception_details(error)}",
            )
            return
        emit("log", level="warning", message=f"已保留本段未完成草稿：{partial_output}")

    def generate_with_redirect(span: Any) -> Any:
        # Keep MLX/native stdout away from the JSONL event stream.
        with contextlib.redirect_stdout(sys.stderr):
            return model.generate(span, **generation_arguments)

    pending = store.pending_leaves()
    emit(
        "log",
        level="info",
        message=(
            f"root {root_id} 覆蓋 {root_start}–{root_end}"
            f"（{plan_samples / sample_rate:.0f} 秒），"
            f"已完成 leaf {completed_before} 個，本次待轉錄 {len(pending)} 個。"
        ),
    )

    prompt_echo_only = False
    try:
        for position, leaf in enumerate(pending):
            node_id = str(leaf["nodeID"])
            leaf_start = int(leaf["startSample"])
            leaf_end = int(leaf["endSample"])
            emit(
                "progress",
                current=completed_before + position,
                total=completed_before + len(pending),
                unit="leaves",
            )
            store.mark_running(node_id)

            def resolve(span_start: int, span_end: int) -> str:
                target = store.node_spanning(span_start, span_end)
                if target is None:
                    raise CheckpointContractError(
                        "local_checkpoint_invalid",
                        f"找不到涵蓋 [{span_start}, {span_end}) 的 leaf 節點。",
                    )
                return str(target["nodeID"])

            def on_leaf_result(result: LeafSpan) -> None:
                nonlocal prompt_echo_only
                cleaned, echo_only = clean_leaf_text(
                    result.text, prompt=prompt, terms=terms, emit=emit
                )
                if echo_only:
                    prompt_echo_only = True
                node_id = resolve(result.start_sample, result.end_sample)
                if not cleaned.strip():
                    record_empty_leaf(node_id, result)
                    return
                store.record_leaf(
                    node_id,
                    state=STATE_COMPLETED,
                    text=cleaned,
                    generation_tokens=result.generation_tokens,
                    maximum_tokens=result.maximum_tokens,
                    reached_token_limit=result.reached_token_limit,
                    finish_reason=result.finish_reason,
                    pcm_sha256=pcm_digest,
                )

            def record_empty_leaf(node_id: str, result: LeafSpan) -> None:
                """§6: an empty leaf is silence only when the whole leaf is.

                A detected pause inside the span says nothing about the rest of
                it, and neither does a low average level — -35dB is not a model of
                human speech. Partial coverage therefore fails the leaf instead
                of publishing a gap-free transcript that quietly dropped audio.
                """

                if silence_plan is not None and silence_index.covers(
                    result.start_sample, result.end_sample
                ):
                    store.record_leaf(
                        node_id,
                        state=STATE_VERIFIED_SILENCE,
                        text="",
                        pcm_sha256=pcm_digest,
                        silence_evidence={
                            "silencePlanDigest": silence_plan.digest,
                            "detector": silence_plan.detector,
                            "coveredStartSample": int(result.start_sample),
                            "coveredEndSample": int(result.end_sample),
                            "thresholdDB": silence_plan.threshold_db,
                            "minimumDurationSeconds": (
                                silence_plan.minimum_duration_seconds
                            ),
                        },
                    )
                    emit(
                        "log",
                        level="info",
                        message=(
                            f"{format_sample_time(result.start_sample, sample_rate=sample_rate)}–"
                            f"{format_sample_time(result.end_sample, sample_rate=sample_rate)}"
                            " 全段落在已驗證靜音區間，記錄為 verifiedSilence。"
                        ),
                    )
                    return
                store.record_leaf(
                    node_id,
                    state=STATE_FAILED,
                    text="",
                    pcm_sha256=pcm_digest,
                )
                raise CheckpointContractError(
                    "local_empty_unverified",
                    f"{format_sample_time(result.start_sample, sample_rate=sample_rate)}–"
                    f"{format_sample_time(result.end_sample, sample_rate=sample_rate)}"
                    " 模型回傳空文字，但整段未被已驗證靜音涵蓋；"
                    "不得宣稱完成，已保留先前文字。",
                )

            def on_leaf_gap(gap: GapSpan) -> str:
                accumulator = TranscriptAccumulator(
                    prompt=prompt, terms=terms, emit=emit
                )
                marker = accumulator.record_skipped_span(gap.error)
                store.record_leaf(
                    resolve(gap.start_sample, gap.end_sample),
                    state=STATE_GAP,
                    text="",
                    pcm_sha256=pcm_digest,
                    gap_reason=(
                        f"約 {gap.span_seconds:.0f} 秒仍在 token 上限"
                        f"（{gap.error.maximum_tokens}）內無法完成，"
                        f"已切到深度 {gap.depth} 仍頂滿。"
                    ),
                    gap_error_code="token_limit_reached",
                )
                return marker

            def on_span_split(
                parent_start: int, split_sample: int, parent_end: int
            ) -> None:
                parent_id = resolve(parent_start, parent_end)
                left_id, right_id = split_child_ids(
                    parent_id, parent_start, split_sample, parent_end
                )
                # Derived from the committed boundary rather than passed down:
                # the split point is the only fact that says which policy chose
                # it, and a flag threaded through the recursion could disagree
                # with what actually landed on disk.
                midpoint = parent_start + (parent_end - parent_start) // 2
                store.split_node(
                    parent_id,
                    split_sample=split_sample,
                    policy=(
                        SPLIT_POLICY_TOKEN_MIDPOINT
                        if split_sample == midpoint
                        else SPLIT_POLICY_TOKEN_SILENCE
                    ),
                    left_id=left_id,
                    right_id=right_id,
                )

            generate_span_with_token_guard(
                model,
                audio[leaf_start - audio_start : leaf_end - audio_start],
                generation_arguments=generation_arguments,
                sample_rate=sample_rate,
                maximum_tokens=maximum_tokens,
                label=(
                    f"{format_sample_time(leaf_start, sample_rate=sample_rate)}–"
                    f"{format_sample_time(leaf_end, sample_rate=sample_rate)}"
                ),
                emit=emit,
                heartbeat_factory=heartbeat,
                generate=generate_with_redirect,
                on_leaf_result=on_leaf_result,
                on_leaf_gap=on_leaf_gap,
                on_span_split=on_span_split,
                choose_split=choose_split,
                min_split_seconds=min_split_seconds,
                max_depth=6,
                span_start=leaf_start,
            )
    except Exception:
        preserve_partial_output()
        raise

    finally:
        if silence_plan is not None and (
            split_counters.silence_cuts or split_counters.fallbacks
        ):
            emit(
                "log",
                level="info",
                message=(
                    f"root {root_id} token 遞迴切點：移到停頓 {split_counters.silence_cuts} 次、"
                    f"使用合法中點 {split_counters.fallbacks} 次。"
                ),
            )

    if prompt_echo_only:
        preserve_partial_output()
        emit(
            "error",
            code="prompt_echo_only",
            message="模型只回吐了送入的 Prompt／詞庫，沒有產生可用逐字稿。",
            recoverable=True,
        )
        raise SystemExit(2)

    leaves = ordered_covering_leaves(store.state)
    atomic_write_text(rendered_text(), output)
    try:
        output.with_name(f"{output.name}.partial.txt").unlink()
    except FileNotFoundError:
        pass
    emit(
        "completed",
        outputPath=str(output),
        durationSeconds=time.monotonic() - started,
        containsSkippedAudio=any(leaf.get("state") == STATE_GAP for leaf in leaves),
    )


def transcribe(request: dict[str, Any]) -> None:
    validate_request(request)
    configure_environment(request)
    static_system_prompt, static_context = static_capability()
    emit(
        "capability",
        supportsSystemPrompt=static_system_prompt,
        supportsContext=static_context,
    )

    terms = request.get("terms") or []
    allow_missing = bool(request.get("allowMissingPrompt", False))
    if terms and not (static_system_prompt or static_context) and not allow_missing:
        emit(
            "error",
            code="glossary_not_supported",
            message="目前安裝的 MLX-Audio 後端不支援專有名詞提示。",
            recoverable=True,
        )
        raise SystemExit(2)

    with contextlib.redirect_stdout(sys.stderr):
        from mlx_audio.stt.utils import load_audio

    model, supports_system_prompt, supports_context = load_model_once(request)
    emit(
        "capability",
        supportsSystemPrompt=supports_system_prompt,
        supportsContext=supports_context,
    )

    prompt = request.get("prompt") or ""
    if terms and not (supports_system_prompt or supports_context) and not allow_missing:
        emit(
            "error",
            code="glossary_not_supported",
            message="目前 MLX-Audio 後端不支援專有名詞提示。",
            recoverable=True,
        )
        raise SystemExit(2)

    generation_arguments: dict[str, Any] = {
        "language": request.get("language") or "Chinese",
        "max_tokens": int(request.get("maximumTokens", 16_384)),
        "verbose": False,
    }
    if prompt and supports_system_prompt:
        generation_arguments["system_prompt"] = prompt
    elif prompt and supports_context:
        generation_arguments["context"] = prompt
    elif terms:
        emit(
            "warning",
            code="glossary_ignored_by_user",
            message="使用者已明確允許不套用專有名詞提示。",
        )

    # A v2 checkpoint froze the prompt channel along with every other inference
    # input. If the loaded model routes the prompt somewhere else, the persisted
    # leaves were produced under different conditions and must not be reused.
    effective_channel = resolve_prompt_channel(
        prompt,
        supports_system_prompt,
        supports_context,
    )
    declared_block = request.get("checkpointV2") or {}
    declared_channel = declared_block.get("promptChannel")
    if declared_channel is not None and declared_channel != effective_channel:
        raise CheckpointContractError(
            "local_identity_mismatch",
            f"checkpoint 宣告的 prompt channel 為 {declared_channel}，"
            f"但本次實際可用的是 {effective_channel}；拒絕以不同條件沿用既有結果。",
        )

    emit("stage", value="transcribing")
    started = time.monotonic()
    # Default 120s: dense Chinese meetings can fill 16k tokens even in 5 minutes.
    chunk_duration = float(request.get("chunkDurationSeconds", 120))
    sample_rate = int(getattr(model, "sample_rate", 16000))
    maximum_tokens = int(generation_arguments["max_tokens"])
    # Do not split below this when retrying after token-limit hits.
    min_split_seconds = 30.0

    with contextlib.redirect_stdout(sys.stderr):
        audio = load_audio(request["audioPath"])

    v2_block = request.get("checkpointV2")
    if v2_block:
        if sample_rate != int(v2_block["sampleRate"]):
            raise CheckpointContractError(
                "local_pcm_mismatch",
                f"模型 sample rate {sample_rate} 與 checkpoint 記錄的 "
                f"{int(v2_block['sampleRate'])} 不符；座標換算會錯位。",
            )
        transcribe_v2(
            request=request,
            block=v2_block,
            model=model,
            generation_arguments=generation_arguments,
            sample_rate=sample_rate,
            maximum_tokens=maximum_tokens,
            min_split_seconds=min_split_seconds,
            audio=audio,
            prompt=prompt,
            terms=terms,
            output=Path(request["outputPath"]),
            started=started,
        )
        return

    samples_per_chunk = max(int(chunk_duration * sample_rate), sample_rate)
    audio_length = len(audio)
    total_chunks = max(1, (audio_length + samples_per_chunk - 1) // samples_per_chunk)
    output = Path(request["outputPath"])
    transcript = TranscriptAccumulator(
        prompt=prompt,
        terms=terms,
        emit=emit,
    )
    checkpoint = chunk_checkpoint_path(output, request)
    checkpoint_fingerprint = chunk_checkpoint_fingerprint(
        request,
        audio_length=audio_length,
        sample_rate=sample_rate,
        total_chunks=total_chunks,
        chunk_duration=chunk_duration,
    )
    completed_chunks = load_chunk_checkpoint(
        checkpoint,
        fingerprint=checkpoint_fingerprint,
        total_chunks=total_chunks,
    )
    for item in completed_chunks:
        transcript.record_checkpoint_text(
            item["text"],
            contains_skipped_audio=item["containsSkippedAudio"],
        )
    starting_chunk = len(completed_chunks)
    if starting_chunk > 0:
        emit(
            "log",
            level="info",
            message=(
                f"已驗證內部 chunk checkpoint，沿用前 {starting_chunk}/{total_chunks} 塊；"
                "不重新推論已完成音訊。"
            ),
        )

    def rendered_text() -> str:
        return render_timed_transcript(
            completed_chunks,
            samples_per_chunk=samples_per_chunk,
            sample_rate=sample_rate,
            audio_length=audio_length,
            time_offset=float(request.get("timeOffsetSeconds", 0)),
        )

    def preserve_partial_output() -> None:
        partial_text = rendered_text()
        if not partial_text:
            return
        partial_output = output.with_name(f"{output.name}.partial.txt")
        try:
            atomic_write_text(partial_text, partial_output)
        except Exception as error:
            emit(
                "warning",
                code="partial_output_write_failed",
                message=f"無法保存未完成草稿：{exception_details(error)}",
            )
            return
        emit(
            "log",
            level="warning",
            message=f"已保留本段未完成草稿：{partial_output}",
        )

    emit(
        "log",
        level="info",
        message=(
            f"本段音訊約 {audio_length / sample_rate:.0f} 秒，"
            f"內部以 {chunk_duration:.0f} 秒切成 {total_chunks} 塊，"
            f"每塊 max_tokens={maximum_tokens}；"
            f"若頂滿 token 會自動對半再切（最短約 {min_split_seconds:.0f} 秒）；"
            "最短片段仍頂滿時會標記缺口並繼續。"
        ),
    )

    def generate_with_redirect(span: Any) -> Any:
        # Keep MLX/native stdout away from the JSONL event stream.
        with contextlib.redirect_stdout(sys.stderr):
            return model.generate(span, **generation_arguments)

    try:
        for index in range(starting_chunk, total_chunks):
            start = index * samples_per_chunk
            end = min((index + 1) * samples_per_chunk, audio_length)
            chunk = audio[start:end]
            emit(
                "progress",
                current=index,
                total=total_chunks,
                unit="chunks",
            )
            chunk_transcript = TranscriptAccumulator(
                prompt=prompt,
                terms=terms,
                emit=emit,
            )
            generate_span_with_token_guard(
                model,
                chunk,
                generation_arguments=generation_arguments,
                sample_rate=sample_rate,
                maximum_tokens=maximum_tokens,
                label=f"第 {index + 1}/{total_chunks} 內部塊",
                emit=emit,
                heartbeat_factory=heartbeat,
                generate=generate_with_redirect,
                on_leaf_complete=chunk_transcript.record_completed_text,
                on_leaf_skipped=chunk_transcript.record_skipped_span,
                min_split_seconds=min_split_seconds,
                max_depth=6,
            )
            if chunk_transcript.has_prompt_echo_only_chunk:
                transcript.mark_prompt_echo_only()
                preserve_partial_output()
                emit(
                    "error",
                    code="prompt_echo_only",
                    message="模型只回吐了送入的 Prompt／詞庫，沒有產生可用逐字稿。",
                    recoverable=True,
                )
                raise SystemExit(2)
            transcript.record_checkpoint_text(
                chunk_transcript.text,
                contains_skipped_audio=chunk_transcript.contains_skipped_audio,
            )
            completed_chunks.append(
                {
                    "index": index,
                    "text": chunk_transcript.text,
                    "containsSkippedAudio":
                        chunk_transcript.contains_skipped_audio,
                }
            )
            write_chunk_checkpoint(
                checkpoint,
                fingerprint=checkpoint_fingerprint,
                total_chunks=total_chunks,
                completed_chunks=completed_chunks,
            )
            emit(
                "progress",
                current=index + 1,
                total=total_chunks,
                unit="chunks",
            )
    except Exception:
        preserve_partial_output()
        raise

    if transcript.has_prompt_echo_only_chunk:
        preserve_partial_output()
        emit(
            "error",
            code="prompt_echo_only",
            message="模型只回吐了送入的 Prompt／詞庫，沒有產生可用逐字稿。",
            recoverable=True,
        )
        raise SystemExit(2)

    text = rendered_text()

    atomic_write_text(text, output)
    try:
        output.with_name(f"{output.name}.partial.txt").unlink()
    except FileNotFoundError:
        pass
    emit(
        "completed",
        outputPath=str(output),
        durationSeconds=time.monotonic() - started,
        containsSkippedAudio=transcript.contains_skipped_audio,
    )


def _raise_cancelled(_signal: int, _frame) -> None:
    raise KeyboardInterrupt


def install_signal_handlers() -> None:
    """Route both SIGINT and SIGTERM through the cancellation path.

    The Swift side escalates SIGINT -> SIGTERM -> SIGKILL. Without a SIGTERM
    handler, a helper that misses the first signal exits without emitting the
    `cancelled` event or preserving partial output.
    """

    signal.signal(signal.SIGINT, _raise_cancelled)
    try:
        signal.signal(signal.SIGTERM, _raise_cancelled)
    except (ValueError, OSError):
        pass


def main() -> int:
    install_signal_handlers()
    args = parse_args()
    if args.events_jsonl != "-":
        emit(
            "error",
            code="invalid_request",
            message="MLX helper 目前只支援 --events-jsonl -。",
            recoverable=False,
        )
        return 2
    if args.report_runtime:
        try:
            report_runtime()
            return 0
        except Exception as error:
            details = exception_details(error)
            emit(
                "error",
                code="runtime_report_failed",
                message=f"無法回報本機 ASR runtime 身分：{details}",
                recoverable=False,
            )
            return 1
    if args.server:
        # A cancel arriving while blocked on stdin must not escape as an
        # uncaught KeyboardInterrupt traceback.
        try:
            return serve()
        except KeyboardInterrupt:
            emit(
                "error",
                code="cancelled",
                message="轉錄已取消。",
                recoverable=True,
            )
            return 130
    if not args.request_json:
        emit(
            "error",
            code="invalid_request",
            message="MLX helper 單次模式需要 --request-json。",
            recoverable=False,
        )
        return 2
    try:
        request = load_request(args.request_json)
        transcribe(request)
        return 0
    except KeyboardInterrupt:
        emit(
            "error",
            code="cancelled",
            message="轉錄已取消。",
            recoverable=True,
        )
        return 130
    except SystemExit as error:
        # SystemExit(0)/SystemExit() mean success; only real codes are errors.
        if error.code is None or error.code == 0:
            return 0
        return int(error.code)
    except CheckpointContractError as error:
        # The taxonomy codes are the contract Swift reasons about, so they must
        # survive instead of collapsing into a generic asr_failed.
        emit(
            "error",
            code=error.code,
            message=error.message,
            recoverable=False,
        )
        return 4
    except TokenLimitReached as error:
        emit(
            "error",
            code="chunk_token_limit_reached",
            message=str(error),
            recoverable=True,
        )
        return 3
    except Exception as error:
        details = exception_details(error)
        emit(
            "error",
            code="asr_failed",
            message=f"Qwen3-ASR 轉錄失敗：{details}",
            recoverable=True,
        )
        print(details, file=sys.stderr, flush=True)
        return 1


def serve() -> int:
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("server request must be a JSON object")
            transcribe(request)
        except KeyboardInterrupt:
            emit(
                "error",
                code="cancelled",
                message="轉錄已取消。",
                recoverable=True,
            )
            return 130
        except SystemExit:
            # transcribe() already emitted the contract error. Keep the
            # long-lived process available for a later retry in this job.
            continue
        except CheckpointContractError as error:
            emit(
                "error",
                code=error.code,
                message=error.message,
                recoverable=False,
            )
        except TokenLimitReached as error:
            emit(
                "error",
                code="chunk_token_limit_reached",
                message=str(error),
                recoverable=True,
            )
        except Exception as error:
            details = exception_details(error)
            emit(
                "error",
                code="asr_failed",
                message=f"Qwen3-ASR 轉錄失敗：{details}",
                recoverable=True,
            )
            print(details, file=sys.stderr, flush=True)
    return 0


def exception_details(error: Exception) -> str:
    return f"{type(error).__name__}: {error}".strip()


if __name__ == "__main__":
    raise SystemExit(main())
