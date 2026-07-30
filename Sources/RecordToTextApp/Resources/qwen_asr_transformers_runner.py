#!/usr/bin/env python3
"""Experimental Intel-only JSONL helper for Qwen3-ASR.

This adapter is intentionally tied to qwen-asr 0.0.6. Its prompt contract is
qwen-asr's ``context`` argument; it never guesses another prompt parameter and
never continues when that contract is unavailable.

Only JSONL events are written to the process's original stdout. Python and
third-party diagnostics are redirected to stderr before any ML package import.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import importlib.metadata
import inspect
import json
import os
from pathlib import Path
import platform
import re
import signal
import sys
import tempfile
import threading
import time
from typing import Any, Iterator


BACKEND_NAME = "qwen-asr-transformers-intel"
EXPECTED_MODEL_ID = "Qwen/Qwen3-ASR-0.6B"
EXPECTED_DISTRIBUTIONS = {
    "qwen-asr": "0.0.6",
    "torch": "2.2.2",
    "transformers": "4.57.6",
    "accelerate": "1.12.0",
}
MAX_CONTEXT_CHARACTERS = 65_536
MAX_NEW_TOKENS = 4_096
HEARTBEAT_INTERVAL_SECONDS = 10.0


# Keep a private duplicate of the original stdout pipe for machine events, then
# redirect fd 1 itself to stderr. This also catches native dependencies that
# write directly to stdout instead of respecting contextlib.redirect_stdout.
_events_fd = os.dup(sys.stdout.fileno())
EVENTS = os.fdopen(
    _events_fd,
    "w",
    encoding="utf-8",
    buffering=1,
    closefd=True,
)
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
EVENT_LOCK = threading.Lock()


class HelperContractError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        recoverable: bool,
        exit_code: int,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.recoverable = recoverable
        self.exit_code = exit_code


def emit(event_type: str, **payload: Any) -> None:
    event = {"type": event_type, **payload}
    line = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
    with EVENT_LOCK:
        EVENTS.write(line + "\n")
        EVENTS.flush()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="record-to-text experimental Intel ASR helper"
    )
    parser.add_argument("--request-json", required=True)
    parser.add_argument("--events-jsonl", default="-")
    return parser.parse_args()


def require_string(
    request: dict[str, Any],
    key: str,
    *,
    allow_empty: bool = False,
) -> str:
    value = request.get(key)
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise HelperContractError(
            "invalid_request",
            f"Request 欄位 {key} 必須是字串。",
            recoverable=False,
            exit_code=2,
        )
    return value


def load_request(path: str) -> dict[str, Any]:
    request_path = Path(path)
    if not request_path.is_absolute() or not request_path.is_file():
        raise HelperContractError(
            "invalid_request",
            "request JSON 必須是已存在的絕對路徑。",
            recoverable=False,
            exit_code=2,
        )
    try:
        with request_path.open("r", encoding="utf-8") as handle:
            request = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise HelperContractError(
            "invalid_request",
            "無法讀取 request JSON。",
            recoverable=False,
            exit_code=2,
        ) from error
    if not isinstance(request, dict):
        raise HelperContractError(
            "invalid_request",
            "request JSON 的最外層必須是物件。",
            recoverable=False,
            exit_code=2,
        )
    return request


def validate_request(request: dict[str, Any]) -> None:
    audio_path = Path(require_string(request, "audioPath"))
    output_path = Path(require_string(request, "outputPath"))
    cache_path = Path(require_string(request, "modelCacheDirectory"))
    model_reference = require_string(request, "modelID")
    prompt = require_string(request, "prompt", allow_empty=True)

    if not audio_path.is_absolute() or not audio_path.is_file():
        raise HelperContractError(
            "invalid_request",
            "audioPath 必須是已存在音檔的絕對路徑。",
            recoverable=False,
            exit_code=2,
        )
    if not output_path.is_absolute():
        raise HelperContractError(
            "invalid_request",
            "outputPath 必須是絕對路徑。",
            recoverable=False,
            exit_code=2,
        )
    if not cache_path.is_absolute():
        raise HelperContractError(
            "invalid_request",
            "modelCacheDirectory 必須是絕對路徑。",
            recoverable=False,
            exit_code=2,
        )

    local_model = Path(model_reference)
    is_valid_local_model = (
        local_model.is_absolute()
        and local_model.is_dir()
    )
    if model_reference != EXPECTED_MODEL_ID and not is_valid_local_model:
        raise HelperContractError(
            "unsupported_model",
            "Intel Experimental 後端只接受 Qwen3-ASR 0.6B 或其本地 snapshot。",
            recoverable=False,
            exit_code=2,
        )
    if not is_valid_local_model:
        revision = request.get("modelRevision")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            raise HelperContractError(
                "invalid_request",
                "遠端 Intel 模型必須提供固定的 40 字元 modelRevision。",
                recoverable=False,
                exit_code=2,
            )

    if len(prompt) > MAX_CONTEXT_CHARACTERS:
        raise HelperContractError(
            "invalid_request",
            "專有名詞 prompt 過長，Intel Experimental 後端拒絕執行。",
            recoverable=True,
            exit_code=2,
        )

    terms = request.get("terms", [])
    if not isinstance(terms, list) or not all(
        isinstance(term, str) for term in terms
    ):
        raise HelperContractError(
            "invalid_request",
            "terms 必須是字串陣列。",
            recoverable=False,
            exit_code=2,
        )
    if terms and not prompt.strip():
        raise HelperContractError(
            "glossary_not_supported",
            "工作包含專有名詞，但 request 沒有可傳入 context 的 prompt。",
            recoverable=True,
            exit_code=2,
        )


def installed_versions() -> dict[str, str]:
    versions: dict[str, str] = {}
    for distribution, expected in EXPECTED_DISTRIBUTIONS.items():
        try:
            actual = importlib.metadata.version(distribution)
        except importlib.metadata.PackageNotFoundError as error:
            raise HelperContractError(
                "intel_runtime_incompatible",
                f"Intel Experimental Runtime 缺少 {distribution}=={expected}。",
                recoverable=False,
                exit_code=3,
            ) from error
        if actual != expected:
            raise HelperContractError(
                "intel_runtime_incompatible",
                (
                    f"Intel Experimental Runtime 需要 {distribution}=={expected}，"
                    f"目前是 {actual}。"
                ),
                recoverable=False,
                exit_code=3,
            )
        versions[distribution] = actual
    return versions


def validate_runtime() -> dict[str, str]:
    if platform.system() != "Darwin" or platform.machine() != "x86_64":
        raise HelperContractError(
            "intel_runtime_incompatible",
            "此 helper 僅供 Intel macOS x86_64 實機進行 Experimental spike。",
            recoverable=False,
            exit_code=3,
        )
    if sys.version_info[:2] != (3, 12):
        raise HelperContractError(
            "intel_runtime_incompatible",
            "Intel Experimental Runtime 必須使用 Python 3.12。",
            recoverable=False,
            exit_code=3,
        )
    return installed_versions()


def configure_environment(request: dict[str, Any]) -> None:
    cache = Path(request["modelCacheDirectory"])
    cache.mkdir(parents=True, exist_ok=True)
    os.environ["HF_HOME"] = str(cache)
    os.environ["HF_HUB_CACHE"] = str(cache / "hub")
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    if bool(request.get("offline", False)):
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
    else:
        os.environ.pop("HF_HUB_OFFLINE", None)
        os.environ.pop("TRANSFORMERS_OFFLINE", None)


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


@contextmanager
def heartbeat(stage: str) -> Iterator[None]:
    stop = threading.Event()

    def send_heartbeats() -> None:
        while not stop.wait(HEARTBEAT_INTERVAL_SECONDS):
            emit(
                "heartbeat",
                value=stage,
                message="Intel Experimental Qwen3-ASR 仍在處理。",
            )

    thread = threading.Thread(
        target=send_heartbeats,
        name="record-to-text-intel-heartbeat",
        daemon=True,
    )
    thread.start()
    try:
        yield
    finally:
        stop.set()
        thread.join(timeout=0.25)


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
            normalized = (
                text.replace("\r\n", "\n")
                .replace("\r", "\n")
                .lstrip("\ufeff")
            )
            handle.write(normalized)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, destination)
    except Exception:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def resolved_max_new_tokens(request: dict[str, Any]) -> int:
    value = request.get("maximumTokens", MAX_NEW_TOKENS)
    if isinstance(value, bool):
        value = 0
    try:
        requested = int(value)
    except (TypeError, ValueError) as error:
        raise HelperContractError(
            "invalid_request",
            "maximumTokens 必須是正整數。",
            recoverable=False,
            exit_code=2,
        ) from error
    if requested <= 0:
        raise HelperContractError(
            "invalid_request",
            "maximumTokens 必須是正整數。",
            recoverable=False,
            exit_code=2,
        )
    if requested > MAX_NEW_TOKENS:
        emit(
            "warning",
            code="intel_token_budget_capped",
            message=(
                f"Intel Experimental 後端把 max_new_tokens 限制為 "
                f"{MAX_NEW_TOKENS}；此值仍須 Intel 實機調校。"
            ),
        )
        return MAX_NEW_TOKENS
    return requested


def transcribe(request: dict[str, Any]) -> None:
    validate_request(request)
    configure_environment(request)

    emit(
        "warning",
        code="intel_backend_experimental",
        message="Intel Qwen3-ASR CPU 後端尚未通過 Intel 實機驗證。",
    )
    emit("stage", value="validating_runtime")
    versions = validate_runtime()
    started = time.monotonic()

    # fd 1 already points to stderr. These imports therefore cannot corrupt the
    # Swift-facing JSONL stream even if a dependency prints during import.
    with heartbeat("importing_runtime"):
        import torch
        from qwen_asr import Qwen3ASRModel

    transcribe_signature = inspect.signature(Qwen3ASRModel.transcribe)
    supports_context = "context" in transcribe_signature.parameters
    emit(
        "capability",
        backend=BACKEND_NAME,
        experimental=True,
        promptTransport="context",
        supportsSystemPrompt=False,
        supportsContext=supports_context,
        libraryVersions=versions,
    )
    if not supports_context:
        raise HelperContractError(
            "glossary_not_supported",
            "已安裝的 qwen-asr 沒有 context 參數；為避免忽略 prompt，工作已停止。",
            recoverable=True,
            exit_code=2,
        )

    maximum_tokens = resolved_max_new_tokens(request)
    requested_chunk_duration = request.get("chunkDurationSeconds", 1200)
    try:
        chunk_duration = float(requested_chunk_duration)
    except (TypeError, ValueError):
        chunk_duration = 1200.0
    if chunk_duration != 1200.0:
        emit(
            "warning",
            code="intel_chunk_duration_fixed",
            message="qwen-asr 0.0.6 固定以最長 1200 秒切段，忽略自訂切段秒數。",
        )

    emit("stage", value="loading_model")
    with heartbeat("loading_model"):
        model_reference = resolve_model_reference(request)
        model = Qwen3ASRModel.from_pretrained(
            model_reference,
            dtype=torch.float32,
            device_map="cpu",
            max_inference_batch_size=1,
            max_new_tokens=maximum_tokens,
        )

    # Re-check the bound method so a proxy or alternate implementation cannot
    # bypass the class-level capability gate.
    bound_signature = inspect.signature(model.transcribe)
    if "context" not in bound_signature.parameters:
        emit(
            "capability",
            backend=BACKEND_NAME,
            experimental=True,
            promptTransport="context",
            supportsSystemPrompt=False,
            supportsContext=False,
        )
        raise HelperContractError(
            "glossary_not_supported",
            "載入的模型沒有 context 參數；為避免忽略 prompt，工作已停止。",
            recoverable=True,
            exit_code=2,
        )

    emit("stage", value="transcribing")
    emit("heartbeat", message="Intel Experimental Qwen3-ASR 已開始處理音訊。")
    with heartbeat("transcribing"):
        results = model.transcribe(
            audio=request["audioPath"],
            context=request.get("prompt") or "",
            language=request.get("language") or "Chinese",
            return_time_stamps=False,
        )

    if not isinstance(results, list) or len(results) != 1:
        raise RuntimeError("qwen-asr did not return exactly one transcription")
    text = getattr(results[0], "text", None)
    if not isinstance(text, str):
        raise RuntimeError("qwen-asr returned a transcription without text")

    output = Path(request["outputPath"])
    atomic_write_text(text, output)
    emit(
        "completed",
        outputPath=str(output),
        durationSeconds=time.monotonic() - started,
    )


def raise_keyboard_interrupt() -> None:
    raise KeyboardInterrupt


def main() -> int:
    signal.signal(
        signal.SIGINT,
        lambda _signal, _frame: raise_keyboard_interrupt(),
    )
    args = parse_args()
    if args.events_jsonl != "-":
        emit(
            "error",
            code="invalid_request",
            message="Intel helper 目前只支援 --events-jsonl -。",
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
    except HelperContractError as error:
        emit(
            "error",
            code=error.code,
            message=error.message,
            recoverable=error.recoverable,
        )
        print(
            f"{type(error).__name__}: {error}",
            file=sys.stderr,
            flush=True,
        )
        return error.exit_code
    except Exception as error:
        emit(
            "error",
            code="asr_failed",
            message="Intel Experimental Qwen3-ASR 轉錄失敗。",
            recoverable=True,
        )
        print(
            f"{type(error).__name__}: {error}",
            file=sys.stderr,
            flush=True,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
