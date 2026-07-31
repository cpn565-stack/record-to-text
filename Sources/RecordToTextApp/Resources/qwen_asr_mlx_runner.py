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
    parser.add_argument("--request-json", required=True)
    parser.add_argument("--events-jsonl", default="-")
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

    chunk_duration = request.get("chunkDurationSeconds", 1200)
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

    emit("stage", value="loading_model")

    # MLX can terminate at the native layer when Metal is unavailable. Keep this
    # import inside the helper process so such a failure cannot crash the Swift app.
    with heartbeat("正在載入 Qwen3-ASR 模型"):
        with contextlib.redirect_stdout(sys.stderr):
            from mlx_audio.stt.utils import load_audio, load_model

            model_reference = resolve_model_reference(request)
            model = load_model(model_reference)

    signature = inspect.signature(model.generate)
    supports_system_prompt = "system_prompt" in signature.parameters
    supports_context = "context" in signature.parameters
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
    chunk_duration = float(request.get("chunkDurationSeconds", 1200))
    sample_rate = int(getattr(model, "sample_rate", 16000))
    maximum_tokens = int(generation_arguments["max_tokens"])

    with contextlib.redirect_stdout(sys.stderr):
        audio = load_audio(request["audioPath"])
    samples_per_chunk = max(int(chunk_duration * sample_rate), sample_rate)
    audio_length = len(audio)
    total_chunks = max(1, (audio_length + samples_per_chunk - 1) // samples_per_chunk)
    texts: list[str] = []

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
        with heartbeat(f"正在處理第 {index + 1} / {total_chunks} 個音訊分段"):
            with contextlib.redirect_stdout(sys.stderr):
                result = model.generate(chunk, **generation_arguments)

        text = getattr(result, "text", None)
        if not isinstance(text, str):
            raise RuntimeError("MLX-Audio did not return a text transcript")
        generation_tokens = int(getattr(result, "generation_tokens", 0) or 0)
        if generation_tokens >= maximum_tokens:
            emit(
                "error",
                code="chunk_token_limit_reached",
                message=f"第 {index + 1} 個音訊分段達到 token 上限，為避免靜默截斷，工作已停止。",
                recoverable=True,
            )
            raise SystemExit(3)
        texts.append(text)
        emit(
            "progress",
            current=index + 1,
            total=total_chunks,
            unit="chunks",
        )

    text = " ".join(part for part in texts if part)

    output = Path(request["outputPath"])
    atomic_write_text(text, output)
    emit(
        "completed",
        outputPath=str(output),
        durationSeconds=time.monotonic() - started,
    )


def main() -> int:
    signal.signal(signal.SIGINT, lambda _signal, _frame: raise_keyboard_interrupt())
    args = parse_args()
    if args.events_jsonl != "-":
        emit(
            "error",
            code="invalid_request",
            message="MLX helper 目前只支援 --events-jsonl -。",
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
        return int(error.code or 1)
    except Exception as error:
        emit(
            "error",
            code="asr_failed",
            message="Qwen3-ASR 轉錄失敗。",
            recoverable=True,
        )
        print(f"{type(error).__name__}: {error}", file=sys.stderr, flush=True)
        return 1


def raise_keyboard_interrupt() -> None:
    raise KeyboardInterrupt


if __name__ == "__main__":
    raise SystemExit(main())
