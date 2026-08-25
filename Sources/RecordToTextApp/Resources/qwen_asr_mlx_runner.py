#!/usr/bin/env python3
"""Version-aware JSONL helper for Qwen3-ASR through MLX-Audio.

The helper keeps stdout machine-readable. Third-party library output is redirected
to stderr so the Swift app can treat every stdout line as one JSON object.
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.metadata
import inspect
import json
import os
from pathlib import Path
import re
import signal
import sys
import tempfile
import threading
import time
from typing import Any

from qwen_asr_chunking import (
    TokenLimitReached,
    TranscriptAccumulator,
    generate_span_with_token_guard,
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
    samples_per_chunk = max(int(chunk_duration * sample_rate), sample_rate)
    audio_length = len(audio)
    total_chunks = max(1, (audio_length + samples_per_chunk - 1) // samples_per_chunk)
    output = Path(request["outputPath"])
    transcript = TranscriptAccumulator(
        prompt=prompt,
        terms=terms,
        emit=emit,
    )

    def preserve_partial_output() -> None:
        partial_text = transcript.text
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
        for index in range(total_chunks):
            start = index * samples_per_chunk
            end = min((index + 1) * samples_per_chunk, audio_length)
            chunk = audio[start:end]
            emit(
                "progress",
                current=index,
                total=total_chunks,
                unit="chunks",
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
                on_leaf_complete=transcript.record_completed_text,
                on_leaf_skipped=transcript.record_skipped_span,
                min_split_seconds=min_split_seconds,
                max_depth=6,
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

    text = transcript.text

    atomic_write_text(text, output)
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
