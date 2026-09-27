#!/usr/bin/env python3
"""Local v2 checkpoint reader/writer shared by the Qwen ASR helpers.

The Swift app owns ``identity.json`` and ``manifest.json`` and freezes them
before inference starts. This module is the single writer for
``roots/<rootID>.json``; Swift only reads and validates it.

Two rules from the phase 0 contract shape everything here:

* the Python side digests the bytes Swift wrote instead of re-encoding JSON and
  hoping the hashes agree;
* a leaf is committed to disk (temp file, fsync, atomic rename) before the
  ``checkpointCommitted`` event is emitted, so a lost event is recoverable while
  an event without a committed file is not.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

SCHEMA_VERSION = 2
_HASH_BATCH_BYTES = 1_048_576

STATE_PENDING = "pending"
STATE_RUNNING = "running"
STATE_COMPLETED = "completed"
STATE_VERIFIED_SILENCE = "verifiedSilence"
STATE_GAP = "gap"
STATE_FAILED = "failed"
STATE_SPLIT = "split"

TERMINAL_STATES = frozenset(
    {STATE_COMPLETED, STATE_VERIFIED_SILENCE, STATE_GAP, STATE_FAILED}
)
COVERING_STATES = frozenset({STATE_COMPLETED, STATE_VERIFIED_SILENCE, STATE_GAP})

# Recorded on every split so a later reader knows which boundary policy chose
# the cut point.
SPLIT_POLICY_TOKEN_MIDPOINT = "token-limit-midpoint"
SPLIT_POLICY_TOKEN_SILENCE = "token-limit-silence"


class CheckpointContractError(Exception):
    """A v2 checkpoint cannot be trusted, with a stable machine-readable code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def canonical_dumps(payload: Any) -> str:
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_file(path: Path, *, offset: int = 0, length: int | None = None) -> str:
    hasher = hashlib.sha256()
    remaining = length
    with path.open("rb") as handle:
        if offset:
            handle.seek(offset)
        while True:
            requested = _HASH_BATCH_BYTES if remaining is None else min(_HASH_BATCH_BYTES, remaining)
            if requested <= 0:
                break
            block = handle.read(requested)
            if not block:
                break
            hasher.update(block)
            if remaining is not None:
                remaining -= len(block)
    if remaining:
        raise CheckpointContractError(
            "local_checkpoint_invalid",
            f"讀 {path.name} 時提前結束，尚缺 {remaining} bytes。",
        )
    return hasher.hexdigest()


def wave_pcm_layout(path: Path) -> tuple[int, int, int, int, int]:
    """Return ``(data_offset, data_bytes, format_tag, channels, sample_rate)``.

    The PCM digest must describe only the samples handed to the model, so RIFF
    headers and metadata chunks are excluded.
    """
    with path.open("rb") as handle:
        header = handle.read(min(_HASH_BATCH_BYTES, 1 << 20))
    if len(header) < 12 or header[0:4] != b"RIFF" or header[8:12] != b"WAVE":
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"{path.name} 不是有效的 RIFF/WAVE 檔案。"
        )

    format_tag = channels = sample_rate = bits = None
    data_offset = data_bytes = None
    cursor = 12
    while cursor + 8 <= len(header):
        chunk_id = header[cursor : cursor + 4]
        chunk_size = int.from_bytes(header[cursor + 4 : cursor + 8], "little")
        payload = cursor + 8
        if chunk_id == b"fmt " and payload + 16 <= len(header):
            format_tag = int.from_bytes(header[payload : payload + 2], "little")
            channels = int.from_bytes(header[payload + 2 : payload + 4], "little")
            sample_rate = int.from_bytes(header[payload + 4 : payload + 8], "little")
            bits = int.from_bytes(header[payload + 14 : payload + 16], "little")
        elif chunk_id == b"data":
            data_offset = payload
            data_bytes = chunk_size
            break
        cursor = payload + chunk_size + (chunk_size % 2)

    if format_tag is None or data_offset is None or channels is None or sample_rate is None:
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"{path.name} 缺少 fmt 或 data chunk。"
        )
    if format_tag != 1:
        raise CheckpointContractError(
            "local_pcm_mismatch", f"{path.name} 格式標籤 {format_tag} 不是未壓縮 PCM。"
        )
    if bits is None or bits <= 0 or channels <= 0:
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"{path.name} 的 fmt 欄位不完整。"
        )
    available = path.stat().st_size - data_offset
    if available < data_bytes:
        raise CheckpointContractError(
            "local_pcm_mismatch",
            f"{path.name} 的 data chunk 宣告 {data_bytes} bytes，檔案只剩 {available} bytes。",
        )
    return data_offset, data_bytes, format_tag, channels, sample_rate


def pcm_sample_count(path: Path) -> int:
    _data_offset, data_bytes, _tag, channels, _rate = wave_pcm_layout(path)
    bytes_per_sample = 2 * max(channels, 1)
    return data_bytes // bytes_per_sample


def pcm_sha256(path: Path) -> str:
    data_offset, data_bytes, _tag, _channels, _rate = wave_pcm_layout(path)
    return sha256_file(path, offset=data_offset, length=data_bytes)


def _require_int(payload: dict[str, Any], key: str, *, where: str) -> int:
    """Require a signed 64-bit integer, matching Swift coordinates and counters.

    ``bool`` is a subclass of ``int`` in Python and JSON ``true`` would
    otherwise decode as ``1``, silently shifting every downstream boundary.
    """
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or not -(1 << 63) <= value < (1 << 63):
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"{where}.{key} 必須是 Int64 範圍內的整數，不接受布林或浮點。"
        )
    return value


def _short_id(payload: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_dumps(payload).encode("utf-8")).hexdigest()[:16]


def split_child_id(parent_id: str, side: str, start_sample: int, end_sample: int) -> str:
    """Mirror of Swift ``LocalCheckpointID.splitChild``.

    Deriving child IDs from the parent plus the split point keeps a restarted run
    that splits the same way on the same subtree, instead of forking a second one
    under a fresh index-based name.
    """
    return "node-" + _short_id(
        {
            "kind": "split",
            "parent": parent_id,
            "side": side,
            "start": start_sample,
            "end": end_sample,
        }
    )


def split_child_ids(parent_id: str, start_sample: int, split_sample: int, end_sample: int) -> tuple[str, str]:
    return (
        split_child_id(parent_id, "a", start_sample, split_sample),
        split_child_id(parent_id, "b", split_sample, end_sample),
    )


def atomic_write_bytes(data: bytes, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle_fd, temporary_name = tempfile.mkstemp(
        dir=str(destination.parent), prefix=f".{destination.name}.", suffix=".tmp"
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(handle_fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def load_json_contract(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise CheckpointContractError("local_checkpoint_invalid", f"找不到 {path.name}。")
    try:
        payload = json.loads(path.read_bytes().decode("utf-8"))
    except Exception as error:  # noqa: BLE001 - reported as a contract failure
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"{path.name} 無法解析：{error}"
        ) from error
    if not isinstance(payload, dict):
        raise CheckpointContractError("local_checkpoint_invalid", f"{path.name} 不是物件。")
    return payload


def load_identity(v2_directory: Path) -> tuple[dict[str, Any], str]:
    """Return the identity document plus the digest of its exact bytes.

    The digest covers Swift's bytes verbatim; this module must never re-encode
    the document or the manifest's recorded digest stops matching.
    """
    path = v2_directory / "identity.json"
    if not path.is_file():
        raise CheckpointContractError(
            "local_checkpoint_invalid", "找不到 identity.json。"
        )
    try:
        raw = path.read_bytes()
        payload = json.loads(raw.decode("utf-8"))
    except Exception as error:  # noqa: BLE001 - reported as a contract failure
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"identity.json 無法解析：{error}"
        ) from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"identity.json 版本不符（需要 {SCHEMA_VERSION}）。"
        )
    return payload, hashlib.sha256(raw).hexdigest()


def load_manifest(v2_directory: Path, *, identity_digest: str) -> dict[str, Any]:
    path = v2_directory / "manifest.json"
    payload = load_json_contract(path)
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"manifest.json 版本不符（需要 {SCHEMA_VERSION}）。"
        )
    if payload.get("identityDigest") != identity_digest:
        raise CheckpointContractError(
            "local_identity_mismatch", "manifest 記錄的 identity digest 與 identity.json 不符。"
        )
    return payload


def find_root_plan(manifest: dict[str, Any], root_id: str) -> dict[str, Any]:
    for root in manifest.get("roots", []):
        if isinstance(root, dict) and root.get("rootID") == root_id:
            return root
    raise CheckpointContractError(
        "local_checkpoint_invalid", f"manifest 內找不到 rootID {root_id}。"
    )


def _is_digest(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def safe_relative_path(directory: Path, relative: str) -> Path:
    if not relative or Path(relative).is_absolute() or ".." in relative.split("/"):
        raise CheckpointContractError("local_checkpoint_invalid", "checkpoint 路徑不合法。")
    path = directory
    for part in relative.split("/"):
        path = path / part
        if path.is_symlink():
            raise CheckpointContractError("local_checkpoint_invalid", "checkpoint 不接受 symbolic link。")
    return path


def load_silence_plan(v2_directory: Path, manifest: dict[str, Any]) -> "FrozenSilencePlan | None":
    """Read the frozen silence analysis Swift persisted, or ``None``.

    ``None`` is the normal answer for a fixed-cut plan and for anything frozen
    before phase 1; it means "no candidates", not "the plan is broken".

    The digest covers the file's exact bytes, the same rule as ``identityDigest``:
    re-encoding the document here would make the comparison meaningless. A
    recorded digest with no readable file is a contract failure rather than an
    empty candidate list, because quietly planning the recursion on midpoints
    would hide that the two halves disagree about what was frozen.
    """

    relative = manifest.get("silencePlanRelativePath")
    expected = manifest.get("silencePlanDigest")
    planner = manifest.get("plannerVersion")
    if planner == "local-fixed-v2" and relative is None and expected is None:
        return None
    if (planner != "local-silence-v1" or not isinstance(relative, str) or not relative
            or not _is_digest(expected) or not _is_digest(manifest.get("normalizedPCMSHA256"))):
        raise CheckpointContractError("local_checkpoint_invalid", "manifest 靜音引用與策略不符。")
    path = safe_relative_path(v2_directory, relative)
    if not path.is_file():
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"找不到已凍結的靜音計畫 {relative}。"
        )

    raw = path.read_bytes()
    actual = hashlib.sha256(raw).hexdigest()
    if actual != expected:
        raise CheckpointContractError(
            "local_identity_mismatch",
            f"{relative} 的 SHA-256 與 manifest 記錄不符（{actual[:12]}… ≠ {expected[:12]}…）。",
        )
    try:
        payload = json.loads(raw.decode("utf-8"))
    except Exception as error:  # noqa: BLE001 - reported as a contract failure
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"{relative} 無法解析：{error}"
        ) from error
    if not isinstance(payload, dict):
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"{relative} 不是物件。"
        )
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        raise CheckpointContractError(
            "local_checkpoint_invalid",
            f"{relative} 版本不符（需要 {SCHEMA_VERSION}）。",
        )
    identity, identity_digest = load_identity(v2_directory)
    if identity_digest != manifest.get("identityDigest"):
        raise CheckpointContractError("local_identity_mismatch", "identity digest 不符。")
    return FrozenSilencePlan.parse(payload, where=relative, manifest=manifest, identity=identity, digest=actual)


@dataclass(frozen=True)
class FrozenSilencePlan:
    """Phase 1's frozen analysis, already interpreted.

    Every scalar is read once here so the runner never re-parses the canonical
    strings mid-root. Doubles travel as ``"%.6f"`` text because the canonical
    JSON subset has no float type, and the dB threshold travels inside the
    ``noiseProfile`` string ffmpeg was actually given — deriving the number from
    that string keeps one source of truth instead of two that could disagree.
    """

    digest: str
    detector: str
    threshold_db: float
    minimum_duration_seconds: float
    recursive_search_seconds: float
    truncated: bool
    intervals: list[dict[str, Any]]

    @staticmethod
    def _seconds(payload: dict[str, Any], key: str, *, where: str) -> float:
        value = payload.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float, str)):
            raise CheckpointContractError(
                "local_checkpoint_invalid", f"{where} 的 {key} 不是數值。"
            )
        try:
            seconds = float(value)
        except (ValueError, OverflowError):
            raise CheckpointContractError(
                "local_checkpoint_invalid", f"{where} 的 {key}「{value}」不是數值。"
            ) from None
        if not math.isfinite(seconds) or seconds < 0:
            raise CheckpointContractError(
                "local_checkpoint_invalid", f"{where} 的 {key} 必須是有限非負實數。"
            )
        return seconds

    @classmethod
    def parse(cls, payload: dict[str, Any], *, where: str, manifest: dict, identity: dict, digest: str) -> "FrozenSilencePlan":
        thresholds = payload.get("thresholds")
        if not isinstance(thresholds, dict):
            raise CheckpointContractError(
                "local_checkpoint_invalid", f"{where} 缺少 thresholds 物件。"
            )
        profile = thresholds.get("noiseProfile")
        if not isinstance(profile, str):
            raise CheckpointContractError(
                "local_checkpoint_invalid", f"{where} 的 noiseProfile 不是字串。"
            )
        text = profile.strip()
        if len(text) < 3 or text[-2:].lower() != "db":
            raise CheckpointContractError(
                "local_checkpoint_invalid",
                f"{where} 的 noiseProfile「{profile}」不是 dB 值，無法作為靜音證據。",
            )
        try:
            threshold_db = float(text[:-2])
        except ValueError:
            raise CheckpointContractError(
                "local_checkpoint_invalid",
                f"{where} 的 noiseProfile「{profile}」不是 dB 值，無法作為靜音證據。",
            ) from None
        if not math.isfinite(threshold_db):
            raise CheckpointContractError(
                "local_checkpoint_invalid", f"{where} 的 noiseProfile 不是有限數值。"
            )

        def invalid(field: str) -> None:
            raise CheckpointContractError("local_checkpoint_invalid", f"{where}.{field} 與凍結契約不符。")

        if (type(payload.get("schemaVersion")) is not int or payload["schemaVersion"] != SCHEMA_VERSION
                or payload.get("plannerVersion") != manifest.get("plannerVersion")
                or payload.get("enabled") is not True or payload.get("detector") != "ffmpeg-silencedetect"
                or type(payload.get("truncated")) is not bool or threshold_db > 0):
            invalid("strategy")
        start = _require_int(payload, "coveredStartSample", where=where)
        end = _require_int(payload, "coveredEndSample", where=where)
        if start < 0 or end <= start or start != manifest.get("workStartSample") or end != manifest.get("workEndSample"):
            invalid("coveredRange")
        source = identity.get("source") or {}
        # Swift's taxonomy reports a source digest mismatch as "the source
        # changed", which is the more actionable of the two codes. The helpers
        # must agree on the code as well as on the verdict, or the same tampered
        # file would be explained two ways depending on which side caught it.
        for field, expected, code in (
            ("sourceSHA256", source.get("sourceSHA256"), "local_source_changed"),
            ("normalizationDigest", manifest.get("normalizationDigest"), "local_identity_mismatch"),
            ("scanPCMSHA256", manifest.get("normalizedPCMSHA256"), "local_identity_mismatch"),
        ):
            if not _is_digest(payload.get(field)) or payload[field] != expected:
                raise CheckpointContractError(code, f"{where}.{field} 不符。")
        profile = identity.get("normalizationProfile")
        if not isinstance(profile, dict) or sha256_text(canonical_dumps(profile)) != manifest.get("normalizationDigest"):
            raise CheckpointContractError("local_identity_mismatch", "normalization profile digest 不符。")
        values = {key: cls._seconds(thresholds, key, where=where) for key in (
            "maximumRootSeconds", "displayGroupSeconds", "chunkSeconds", "minimumChildSeconds",
            "minimumSilenceDurationSeconds", "outerSearchSeconds", "displaySearchSeconds",
            "innerSearchSeconds", "recursiveSearchSeconds")}
        if (not 0 < values["maximumRootSeconds"] <= 1200 or values["displayGroupSeconds"] != 600
                or values["chunkSeconds"] != 120 or values["minimumChildSeconds"] != 30
                or values["minimumSilenceDurationSeconds"] <= 0 or values["outerSearchSeconds"] > 30
                or any(values[key] > 5 for key in ("displaySearchSeconds", "innerSearchSeconds", "recursiveSearchSeconds"))):
            invalid("thresholds")
        maximum = _require_int(thresholds, "maximumIntervalCount", where=where)
        intervals = payload.get("intervals")
        if (not 0 < maximum <= 100_000 or not isinstance(intervals, list) or len(intervals) > maximum
                or (payload["truncated"] and intervals)):
            invalid("intervals")
        previous = None
        for interval in intervals:
            if not isinstance(interval, dict):
                invalid("interval")
            a = _require_int(interval, "startSample", where=where)
            b = _require_int(interval, "endSample", where=where)
            if not start <= a < b <= end or (previous is not None and a <= previous):
                invalid("interval.range")
            previous = b
        for key in ("scanCount", "cacheHitCount", "outerSilenceCuts", "outerFallbacks", "innerSilenceCuts", "innerFallbacks"):
            if _require_int(payload, key, where=where) < 0:
                invalid(key)
        for key in ("scannedAudioSeconds", "scanElapsedMilliseconds"):
            cls._seconds(payload, key, where=where)
        return cls(digest=digest, detector=payload["detector"], threshold_db=threshold_db,
                   minimum_duration_seconds=values["minimumSilenceDurationSeconds"],
                   recursive_search_seconds=values["recursiveSearchSeconds"],
                   truncated=payload["truncated"], intervals=intervals)

    def validate_leaf(self, node: dict, root_plan: dict) -> None:
        result = node.get("result") or {}
        evidence = result.get("silenceEvidence") or {}
        start = _require_int(node, "startSample", where="leaf")
        end = _require_int(node, "endSample", where="leaf")
        if (not isinstance(result.get("text"), str) or result["text"].strip()
                or result.get("textSHA256") != sha256_text(result["text"])
                or result.get("pcmSHA256") != root_plan.get("pcmSHA256")
                or evidence.get("silencePlanDigest") != self.digest
                or evidence.get("detector") != self.detector
                or evidence.get("thresholdDB") != self.threshold_db
                or evidence.get("minimumDurationSeconds") != self.minimum_duration_seconds
                or _require_int(evidence, "coveredStartSample", where="silenceEvidence") != start
                or _require_int(evidence, "coveredEndSample", where="silenceEvidence") != end
                or not any(i["startSample"] <= start < end <= i["endSample"] for i in self.intervals)):
            raise CheckpointContractError("local_empty_unverified", "leaf 靜音證據無法驗證。")

    def search_samples(self, sample_rate: int) -> int:
        """The recursion window in samples, rounded the way Swift rounds.

        ``LocalAudioCoordinates.quantize`` is ``floor(seconds * rate + 0.5)``;
        using Python's banker's ``round`` here would put the two sides one sample
        apart on an exact half and pick a different pause.
        """

        return int(math.floor(self.recursive_search_seconds * float(sample_rate) + 0.5))


class RootStateStore:
    """Single-writer store for ``roots/<rootID>.json``.

    Every mutation goes through :meth:`commit`, which bumps the monotonic
    revision, writes atomically, and only then announces the event. A parent
    turning into ``split`` and both children appearing as ``pending`` happen in
    one commit, so a crash can never leave a parent claiming children that were
    never written.
    """

    def __init__(
        self,
        path: Path,
        *,
        root_plan: dict[str, Any],
        plan_id: str,
        identity_digest: str,
        emit: Callable[..., None],
    ) -> None:
        self._path = path
        self._root_plan = root_plan
        self._plan_id = plan_id
        self._identity_digest = identity_digest
        self._emit = emit
        self._lock = threading.Lock()
        self._state: dict[str, Any] | None = None
        self.silence_plan: FrozenSilencePlan | None = None

    @property
    def root_id(self) -> str:
        return str(self._root_plan["rootID"])

    @property
    def state(self) -> dict[str, Any]:
        assert self._state is not None, "RootStateStore.load() must run first"
        return self._state

    @property
    def revision(self) -> int:
        return int(self.state["revision"])

    def load(self) -> dict[str, Any]:
        plan = self._root_plan
        if self._path.is_file():
            existing = load_json_contract(self._path)
            if existing.get("schemaVersion") != SCHEMA_VERSION:
                raise CheckpointContractError(
                    "local_checkpoint_invalid",
                    f"root state 版本不符（需要 {SCHEMA_VERSION}）。",
                )
            for key, expected in (
                ("rootID", plan["rootID"]),
                ("planID", self._plan_id),
                ("identityDigest", self._identity_digest),
            ):
                if existing.get(key) != expected:
                    raise CheckpointContractError(
                        "local_identity_mismatch",
                        f"root state 的 {key} 與 manifest 不符，拒絕沿用。",
                    )
            revision = _require_int(existing, "revision", where="rootState")
            if revision < 0:
                raise CheckpointContractError(
                    "local_checkpoint_invalid", "root state revision 不可為負。"
                )
            nodes = existing.get("nodes")
            if not isinstance(nodes, list):
                raise CheckpointContractError(
                    "local_checkpoint_invalid", "root state 缺少 nodes 清單。"
                )
            existing["nodes"] = [self._reset_uncommitted(node) for node in nodes]
            self._state = existing
        else:
            self._state = {
                "schemaVersion": SCHEMA_VERSION,
                "identityDigest": self._identity_digest,
                "planID": self._plan_id,
                "rootID": plan["rootID"],
                "revision": 0,
                "splitPolicy": None,
                "nodes": [
                    self._pending_node(chunk, depth=0, parent_id=None)
                    for chunk in plan["initialChunks"]
                ],
            }
            self._write()
        return self._state

    def _pending_node(
        self, chunk: dict[str, Any], *, depth: int, parent_id: str | None
    ) -> dict[str, Any]:
        return {
            "nodeID": chunk["nodeID"],
            "parentID": parent_id,
            "startSample": _require_int(chunk, "startSample", where="chunk"),
            "endSample": _require_int(chunk, "endSample", where="chunk"),
            "splitDepth": depth,
            "state": STATE_PENDING,
            "childrenIDs": [],
            "attempts": [],
            "result": None,
            "splitPolicy": None,
        }

    @staticmethod
    def _reset_uncommitted(node: Any) -> dict[str, Any]:
        """An interrupted ``running`` node is unproven work, never a completion."""
        if not isinstance(node, dict):
            raise CheckpointContractError(
                "local_checkpoint_invalid", "root state 含有非物件的 node。"
            )
        if node.get("state") == STATE_RUNNING:
            node = dict(node)
            node["state"] = STATE_PENDING
            node["result"] = None
        return node

    def node(self, node_id: str) -> dict[str, Any] | None:
        for candidate in self.state["nodes"]:
            if candidate["nodeID"] == node_id:
                return candidate
        return None

    def nodes(self) -> list[dict[str, Any]]:
        return list(self.state["nodes"])

    def pending_leaves(self) -> list[dict[str, Any]]:
        """Work still to do, in audio order.

        ``running`` is deliberately excluded: :meth:`load` already demoted any
        interrupted node back to ``pending``, so a node observed as running here
        is one this process is working on right now.
        """
        return sorted(
            (
                node
                for node in self.state["nodes"]
                if node["state"] == STATE_PENDING
            ),
            key=lambda node: int(node["startSample"]),
        )

    def node_spanning(self, start_sample: int, end_sample: int) -> dict[str, Any] | None:
        """Find the live node covering exactly ``[start_sample, end_sample)``.

        Splitting the tree never renumbers nodes, and a tiling gives each span
        at most one non-split owner, so coordinates are a stable handle for the
        callbacks that only report positions.
        """
        for candidate in self.state["nodes"]:
            if candidate["state"] == STATE_SPLIT:
                continue
            if (
                int(candidate["startSample"]) == start_sample
                and int(candidate["endSample"]) == end_sample
            ):
                return candidate
        return None

    def mark_running(self, node_id: str) -> int:
        def mutate(state: dict[str, Any]) -> None:
            target = self._must_find(state, node_id)
            target["state"] = STATE_RUNNING

        return self.commit(mutate, node_id=node_id)

    def record_leaf(
        self,
        node_id: str,
        *,
        state: str,
        text: str = "",
        generation_tokens: int | None = None,
        maximum_tokens: int | None = None,
        reached_token_limit: bool = False,
        finish_reason: str = "unknown",
        pcm_sha256: str = "",
        gap_reason: str | None = None,
        gap_error_code: str | None = None,
        silence_evidence: dict[str, Any] | None = None,
        attempt: dict[str, Any] | None = None,
    ) -> int:
        if state not in TERMINAL_STATES:
            raise CheckpointContractError(
                "local_checkpoint_invalid", f"{state} 不是終端狀態。"
            )
        if state == STATE_COMPLETED and generation_tokens is None:
            raise CheckpointContractError(
                "local_empty_unverified",
                "執行環境未回報 generationTokens，無法證明這段文字未被截斷；缺 token 計數不得當成 0。",
            )
        if state == STATE_COMPLETED and not text.strip():
            raise CheckpointContractError(
                "local_empty_unverified",
                "completed leaf 的文字為空；空輸出不可宣稱完成。",
            )
        if state == STATE_GAP and not gap_reason:
            raise CheckpointContractError(
                "local_checkpoint_invalid", "gap leaf 必須記錄原因。"
            )

        result: dict[str, Any] = {
            "text": text,
            "textSHA256": sha256_text(text),
            "pcmSHA256": pcm_sha256,
            "finishEvidence": (
                None
                if generation_tokens is None
                else {
                    "generationTokens": int(generation_tokens),
                    "maximumTokens": int(maximum_tokens or 0),
                    "reachedTokenLimit": bool(reached_token_limit),
                    "finishReason": finish_reason,
                }
            ),
            "silenceEvidence": silence_evidence,
            "gapReason": gap_reason,
            "gapErrorCode": gap_error_code,
        }

        def mutate(payload: dict[str, Any]) -> None:
            target = self._must_find(payload, node_id)
            if state == STATE_VERIFIED_SILENCE:
                if self.silence_plan is None:
                    raise CheckpointContractError("local_empty_unverified", "沒有已驗證的靜音計畫。")
                self.silence_plan.validate_leaf({**target, "result": result}, self._root_plan)
            target["state"] = state
            target["result"] = result
            if attempt is not None:
                target.setdefault("attempts", []).append(attempt)

        return self.commit(mutate, node_id=node_id)

    def split_node(
        self,
        node_id: str,
        *,
        split_sample: int,
        policy: str,
        left_id: str,
        right_id: str,
    ) -> int:
        """Turn a parent into ``split`` and add both children in ONE commit."""

        def mutate(state: dict[str, Any]) -> None:
            parent = self._must_find(state, node_id)
            start = _require_int(parent, "startSample", where="node")
            end = _require_int(parent, "endSample", where="node")
            if not isinstance(split_sample, int) or isinstance(split_sample, bool):
                raise CheckpointContractError(
                    "local_checkpoint_invalid", "split 點必須是整數 sample。"
                )
            if not start < split_sample < end:
                raise CheckpointContractError(
                    "local_checkpoint_invalid",
                    f"split 點 {split_sample} 不在 ({start}, {end}) 內。",
                )
            if parent["state"] == STATE_SPLIT:
                raise CheckpointContractError(
                    "local_checkpoint_invalid", f"{node_id} 已經是 split。"
                )
            depth = int(parent.get("splitDepth", 0)) + 1
            parent["state"] = STATE_SPLIT
            parent["childrenIDs"] = [left_id, right_id]
            parent["splitPolicy"] = policy
            # A split parent's truncated text must never reach the transcript.
            parent["result"] = None
            state["splitPolicy"] = policy
            for child_id, child_start, child_end in (
                (left_id, start, split_sample),
                (right_id, split_sample, end),
            ):
                if any(existing["nodeID"] == child_id for existing in state["nodes"]):
                    raise CheckpointContractError(
                        "local_checkpoint_invalid", f"子節點 {child_id} 已存在。"
                    )
                state["nodes"].append(
                    {
                        "nodeID": child_id,
                        "parentID": node_id,
                        "startSample": child_start,
                        "endSample": child_end,
                        "splitDepth": depth,
                        "state": STATE_PENDING,
                        "childrenIDs": [],
                        "attempts": [],
                        "result": None,
                        "splitPolicy": policy,
                    }
                )

        return self.commit(mutate, node_id=node_id)

    def _must_find(self, state: dict[str, Any], node_id: str) -> dict[str, Any]:
        for candidate in state["nodes"]:
            if candidate["nodeID"] == node_id:
                return candidate
        raise CheckpointContractError(
            "local_checkpoint_invalid", f"root state 內找不到 node {node_id}。"
        )

    def commit(
        self, mutate: Callable[[dict[str, Any]], None], *, node_id: str | None = None
    ) -> int:
        with self._lock:
            assert self._state is not None, "RootStateStore.load() must run first"
            mutate(self._state)
            self._state["revision"] = int(self._state["revision"]) + 1
            self._write()
            revision = int(self._state["revision"])
        self._emit(
            "checkpointCommitted",
            rootID=self.root_id,
            revision=revision,
            nodeID=node_id,
        )
        return revision

    def _write(self) -> None:
        atomic_write_bytes(canonical_dumps(self._state).encode("utf-8"), self._path)


def effective_leaves(state: dict[str, Any]) -> Iterable[dict[str, Any]]:
    return (node for node in state["nodes"] if node["state"] != STATE_SPLIT)


def ordered_covering_leaves(state: dict[str, Any]) -> list[dict[str, Any]]:
    return sorted(
        (node for node in effective_leaves(state) if node["state"] in COVERING_STATES),
        key=lambda node: node["startSample"],
    )


def coverage_gap_samples(state: dict[str, Any], *, root_start: int, root_end: int) -> list[tuple[int, int]]:
    """Holes left by pending or failed leaves, as ``[start, end)`` sample pairs."""
    holes: list[tuple[int, int]] = []
    cursor = root_start
    for node in ordered_covering_leaves(state):
        start = int(node["startSample"])
        end = int(node["endSample"])
        if start > cursor:
            holes.append((cursor, start))
        cursor = max(cursor, end)
    if cursor < root_end:
        holes.append((cursor, root_end))
    return holes


def verify_root_plan_against_audio(
    root_plan: dict[str, Any], *, audio_path: Path, audio_start_sample: int
) -> tuple[str, int]:
    """Prove the decoded PCM is the audio the plan describes.

    Returns the PCM digest and the decoded sample count. The digest is compared
    against the plan; the sample count decides the work end, never the container
    duration.
    """
    expected = str(root_plan.get("pcmSHA256") or "")
    actual = pcm_sha256(audio_path)
    if expected and expected != actual:
        raise CheckpointContractError(
            "local_pcm_mismatch",
            f"root {root_plan['rootID']} 的 PCM digest 不符（記錄 {expected[:12]}…，實際 {actual[:12]}…）。",
        )
    plan_start = _require_int(root_plan, "startSample", where="root")
    if plan_start != audio_start_sample:
        raise CheckpointContractError(
            "local_checkpoint_invalid",
            f"root 起點 {plan_start} 與載入音訊的絕對起點 {audio_start_sample} 不符。",
        )
    sample_count = pcm_sample_count(audio_path)
    plan_samples = _require_int(root_plan, "endSample", where="root") - plan_start
    if sample_count != plan_samples:
        raise CheckpointContractError(
            "local_pcm_mismatch",
            f"root 解碼 sample 數 {sample_count} 與 plan 記錄 {plan_samples} 不符。",
        )
    return actual, sample_count


def open_root_state_store(
    v2_directory: Path,
    *,
    root_id: str,
    emit: Callable[..., None],
) -> tuple[RootStateStore, dict[str, Any], dict[str, Any], str]:
    """Load identity + manifest, then bind a store for ``root_id``."""
    identity, identity_digest = load_identity(v2_directory)
    manifest = load_manifest(v2_directory, identity_digest=identity_digest)
    silence_plan = load_silence_plan(v2_directory, manifest)
    root_plan = find_root_plan(manifest, root_id)
    state_path = safe_relative_path(v2_directory, str(root_plan.get("stateRelativePath") or f"roots/{root_id}.json"))
    store = RootStateStore(
        state_path,
        root_plan=root_plan,
        plan_id=str(manifest["planID"]),
        identity_digest=identity_digest,
        emit=emit,
    )
    store.silence_plan = silence_plan
    store.load()
    for node in effective_leaves(store.state):
        if node["state"] == STATE_VERIFIED_SILENCE:
            if silence_plan is None:
                raise CheckpointContractError("local_empty_unverified", "沒有已驗證的靜音計畫。")
            silence_plan.validate_leaf(node, root_plan)
    return store, identity, manifest, identity_digest
