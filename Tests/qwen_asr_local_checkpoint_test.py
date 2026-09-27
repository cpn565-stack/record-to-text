#!/usr/bin/env python3
"""Contract tests for the local v2 checkpoint writer and the runner's v2 path.

Metal-free: the model is a stub, so these exercise coordinates, commits and
evidence rather than inference.
"""

from __future__ import annotations

from pathlib import Path
import hashlib
import json
import os
import struct
import sys
import tempfile
import unittest
from typing import Sequence
from unittest.mock import patch


RESOURCE_DIRECTORY = (
    Path(__file__).parents[1]
    / "Sources"
    / "RecordToTextApp"
    / "Resources"
)
sys.path.insert(0, str(RESOURCE_DIRECTORY))

import qwen_asr_local_checkpoint as cp  # noqa: E402

# The runner reserves stdout for JSONL at import time; restore it immediately.
_ORIGINAL_STDOUT_FD = os.dup(sys.stdout.fileno())
try:
    import qwen_asr_mlx_runner as mlx_runner  # noqa: E402
finally:
    os.dup2(_ORIGINAL_STDOUT_FD, sys.stdout.fileno())
    os.close(_ORIGINAL_STDOUT_FD)


SAMPLE_RATE = 16_000
ROOT_START = 0
ROOT_END = 1_920_000        # 120 s
CHUNK_BOUNDARY = 960_000    # 60 s; exactly the smallest splittable span
ROOT_ID = "root-fixture0000000"
PLAN_ID = "plan-" + "0" * 59
NODE_A = "node-aaaaaaaaaaaaaaaa"
NODE_B = "node-bbbbbbbbbbbbbbbb"

DEFAULT_CHUNKS: tuple[tuple[str, int, int], ...] = (
    (NODE_A, ROOT_START, CHUNK_BOUNDARY),
    (NODE_B, CHUNK_BOUNDARY, ROOT_END),
)
#: One chunk over the whole root, so a capped leaf has room to recurse.
SINGLE_CHUNK: tuple[tuple[str, int, int], ...] = (
    (NODE_A, ROOT_START, ROOT_END),
)

SILENCE_PLAN_FILENAME = "silence-plan.json"
NORMALIZATION_PROFILE = {
    "version": "rec2t-local-normalize-v1", "sampleRate": 16000, "channels": 1,
    "codec": "pcm_s16le", "byteOrder": "little", "trackSelection": "a:0",
    "stripVideo": True, "sliceSeek": "input-seek-on-source",
    "rootExtraction": "output-seek-on-normalized-pcm",
}
NORMALIZATION_DIGEST = cp.sha256_text(cp.canonical_dumps(NORMALIZATION_PROFILE))


def silence_plan_payload(
    *,
    intervals: Sequence[tuple[int, int]] = (),
    truncated: bool = False,
    recursive_search_seconds: str = "5.000000",
    noise_profile: str = "-35dB",
) -> dict:
    """A plan shaped exactly like Swift's canonical `silence-plan.json`.

    Doubles travel as ``"%.6f"`` text because the canonical JSON subset has no
    float type; writing them as numbers here would hide a real drift.
    """

    return {
        "schemaVersion": cp.SCHEMA_VERSION,
        "plannerVersion": "local-silence-v1",
        "enabled": True,
        "detector": "ffmpeg-silencedetect",
        "thresholds": {
            "maximumRootSeconds": "1200.000000", "outerSearchSeconds": "30.000000",
            "displayGroupSeconds": "600.000000", "displaySearchSeconds": "5.000000",
            "chunkSeconds": "120.000000", "innerSearchSeconds": "5.000000",
            "minimumChildSeconds": "30.000000", "maximumIntervalCount": 100000,
            "noiseProfile": noise_profile,
            "minimumSilenceDurationSeconds": "0.350000",
            "recursiveSearchSeconds": recursive_search_seconds,
        },
        "coveredStartSample": ROOT_START,
        "coveredEndSample": ROOT_END,
        "sourceSHA256": "f" * 64,
        "scanPCMSHA256": hashlib.sha256(pcm_payload(ROOT_END)).hexdigest(),
        "normalizationDigest": NORMALIZATION_DIGEST,
        "scanCount": 1, "cacheHitCount": 0, "outerSilenceCuts": 0, "outerFallbacks": 0,
        "innerSilenceCuts": 0, "innerFallbacks": 0,
        "scannedAudioSeconds": "120.000000", "scanElapsedMilliseconds": "1.000000",
        "truncated": truncated,
        "intervals": [
            {"startSample": start, "endSample": end} for start, end in intervals
        ],
    }


def freeze_silence_plan(fixture: "CheckpointFixture", payload: dict) -> bytes:
    """Write the plan and rebind the manifest to its digest, as Swift does."""

    raw = cp.canonical_dumps(payload).encode("utf-8")
    cp.atomic_write_bytes(raw, fixture.v2 / SILENCE_PLAN_FILENAME)
    fixture.manifest["plannerVersion"] = "local-silence-v1"
    fixture.manifest["normalizedPCMSHA256"] = fixture.pcm
    fixture.manifest["silencePlanRelativePath"] = SILENCE_PLAN_FILENAME
    fixture.manifest["silencePlanDigest"] = hashlib.sha256(raw).hexdigest()
    cp.atomic_write_bytes(
        cp.canonical_dumps(fixture.manifest).encode("utf-8"),
        fixture.v2 / "manifest.json",
    )
    return raw


def make_identity() -> dict:
    return {
        "schemaVersion": cp.SCHEMA_VERSION,
        "jobID": "job-1",
        "source": {
            "sourceSHA256": "f" * 64,
            "sourceByteCount": 1_000_000,
            "workStartSample": ROOT_START,
            "workEndSample": ROOT_END,
        },
        "normalizationProfile": NORMALIZATION_PROFILE,
        "inference": {"modelID": "mlx-community/Qwen3-ASR-1.7B-8bit"},
    }


def make_manifest(
    *,
    pcm_sha256: str,
    identity_digest: str,
    chunks: Sequence[tuple[str, int, int]] = DEFAULT_CHUNKS,
) -> dict:
    return {
        "schemaVersion": cp.SCHEMA_VERSION,
        "jobID": "job-1",
        "identityDigest": identity_digest,
        "inferenceDigest": "inf-" + "0" * 60,
        "normalizationDigest": NORMALIZATION_DIGEST,
        "sampleRate": SAMPLE_RATE,
        "workStartSample": ROOT_START,
        "workEndSample": ROOT_END,
        "planID": PLAN_ID,
        "plannerVersion": "local-fixed-v2",
        "roots": [
            {
                "rootID": ROOT_ID,
                "order": 0,
                "startSample": ROOT_START,
                "endSample": ROOT_END,
                "pcmSHA256": pcm_sha256,
                "audioRelativePath": f"audio/{ROOT_ID}.wav",
                "stateRelativePath": f"roots/{ROOT_ID}.json",
                "initialChunks": [
                    {
                        "nodeID": node_id,
                        "startSample": start,
                        "endSample": end,
                    }
                    for node_id, start, end in chunks
                ],
            }
        ],
        "displayGroups": [
            {"groupID": "group-0", "startSample": ROOT_START, "endSample": ROOT_END}
        ],
        "createdAt": "2026-09-27T00:00:00Z",
    }


def pcm_payload(sample_count: int, *, value: int = 7) -> bytes:
    return struct.pack("<h", value) * sample_count


def write_wav(path: Path, sample_count: int, *, value: int = 7) -> str:
    """Write a 16-bit mono PCM WAV and return the digest of its data chunk."""
    payload = pcm_payload(sample_count, value=value)
    fmt = b"fmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16
    )
    data = b"data" + struct.pack("<I", len(payload)) + payload
    body = fmt + data
    path.write_bytes(
        b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body
    )
    return hashlib.sha256(payload).hexdigest()


class CheckpointFixture:
    """A v2 directory on disk plus the audio it describes."""

    def __init__(
        self,
        root: Path,
        *,
        sample_count: int = ROOT_END,
        chunks: Sequence[tuple[str, int, int]] = DEFAULT_CHUNKS,
    ) -> None:
        self.root = root
        self.sample_count = sample_count
        self.chunks = chunks
        self.v2 = root / "local-checkpoint-v2"
        (self.v2 / "roots").mkdir(parents=True)
        (self.v2 / "audio").mkdir(parents=True)
        self.audio = root / "input.wav"
        self.pcm = write_wav(self.audio, sample_count)
        self.identity = make_identity()
        cp.atomic_write_bytes(
            cp.canonical_dumps(self.identity).encode("utf-8"),
            self.v2 / "identity.json",
        )
        # The manifest binds to the identity bytes actually on disk, exactly as
        # Swift does when it freezes the plan.
        self._identity_digest = hashlib.sha256(
            (self.v2 / "identity.json").read_bytes()
        ).hexdigest()
        self.manifest = make_manifest(
            pcm_sha256=self.pcm,
            identity_digest=self._identity_digest,
            chunks=chunks,
        )
        cp.atomic_write_bytes(
            cp.canonical_dumps(self.manifest).encode("utf-8"),
            self.v2 / "manifest.json",
        )

    @property
    def state_path(self) -> Path:
        return self.v2 / f"roots/{ROOT_ID}.json"

    @property
    def identity_digest(self) -> str:
        return self._identity_digest

    def request_block(self) -> dict:
        return {
            "directory": str(self.v2),
            "rootID": ROOT_ID,
            "planID": PLAN_ID,
            "identityDigest": self.identity_digest,
            "sampleRate": SAMPLE_RATE,
            "audioStartSample": ROOT_START,
            "workStartSample": ROOT_START,
            "workEndSample": ROOT_END,
            "promptChannel": mlx_runner.PROMPT_CHANNEL_SYSTEM,
        }

    def store(self, events: list | None = None) -> cp.RootStateStore:
        def emit(event_type: str, **payload) -> None:
            if events is not None:
                events.append((event_type, payload))

        return cp.RootStateStore(
            self.state_path,
            root_plan=cp.find_root_plan(self.manifest, ROOT_ID),
            plan_id=PLAN_ID,
            identity_digest=self._identity_digest,
            emit=emit,
        )

    def read_state(self) -> dict:
        return json.loads(self.state_path.read_bytes().decode("utf-8"))


class CanonicalFormTests(unittest.TestCase):
    def test_canonical_dumps_matches_the_swift_reference_vector(self):
        payload = {
            "b": 1,
            "a": "x",
            "arr": [{"z": 2, "y": "中文"}],
            "n": None,
            "t": True,
            "f": False,
            "e": "",
        }
        self.assertEqual(
            cp.canonical_dumps(payload),
            '{"a":"x","arr":[{"y":"中文","z":2}],"b":1,"e":"","f":false,"n":null,"t":true}',
        )
        self.assertEqual(
            cp.sha256_text(cp.canonical_dumps(payload)),
            "b4d136db5d962ba1f7bddeec1c8e470a8935830108387150499b468066dab558",
        )

    def test_canonical_dumps_keeps_non_ascii_verbatim(self):
        self.assertEqual(cp.canonical_dumps({"s": "中文"}), '{"s":"中文"}')


class StrictIntegerTests(unittest.TestCase):
    def test_boolean_is_not_an_integer_coordinate(self):
        with self.assertRaises(cp.CheckpointContractError) as caught:
            cp._require_int({"startSample": True}, "startSample", where="node")
        self.assertEqual(caught.exception.code, "local_checkpoint_invalid")

    def test_float_is_not_an_integer_coordinate(self):
        with self.assertRaises(cp.CheckpointContractError):
            cp._require_int({"startSample": 1.0}, "startSample", where="node")

    def test_accepts_a_real_integer(self):
        self.assertEqual(
            cp._require_int({"startSample": 16000}, "startSample", where="node"), 16000
        )

    def test_integer_range_matches_swift_int64(self):
        for value in (-(1 << 63), 0, (1 << 63) - 1):
            with self.subTest(value=value):
                self.assertEqual(cp._require_int({"value": value}, "value", where="fixture"), value)
        for value in (-(1 << 63) - 1, 1 << 63):
            with self.subTest(value=value):
                with self.assertRaises(cp.CheckpointContractError) as caught:
                    cp._require_int({"value": value}, "value", where="fixture")
                self.assertEqual(caught.exception.code, "local_checkpoint_invalid")


class SplitChildIDTests(unittest.TestCase):
    def test_matches_the_swift_reference_vectors(self):
        self.assertEqual(
            cp.split_child_id("node-abc", "a", 0, 60), "node-baa0e6ace3062875"
        )
        self.assertEqual(
            cp.split_child_id("node-abc", "b", 60, 120), "node-1b451270becc7638"
        )

    def test_sides_differ(self):
        left, right = cp.split_child_ids("node-abc", 0, 60, 120)
        self.assertNotEqual(left, right)
        self.assertEqual(left, cp.split_child_id("node-abc", "a", 0, 60))
        self.assertEqual(right, cp.split_child_id("node-abc", "b", 60, 120))


class WaveLayoutTests(unittest.TestCase):
    def test_pcm_digest_ignores_container_metadata(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            plain = root / "plain.wav"
            digest = write_wav(plain, 1600)
            self.assertEqual(cp.pcm_sha256(plain), digest)
            self.assertEqual(cp.pcm_sample_count(plain), 1600)

            tagged = root / "tagged.wav"
            payload = pcm_payload(1600)
            listed = b"LIST" + struct.pack("<I", 4) + b"INFO"
            body = (
                b"fmt "
                + struct.pack("<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16)
                + listed
                + b"data"
                + struct.pack("<I", len(payload))
                + payload
            )
            tagged.write_bytes(
                b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body
            )
            self.assertEqual(cp.pcm_sha256(tagged), digest)
            self.assertNotEqual(
                hashlib.sha256(tagged.read_bytes()).hexdigest(),
                hashlib.sha256(plain.read_bytes()).hexdigest(),
            )

    def test_non_pcm_and_truncated_are_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            float_wav = root / "float.wav"
            payload = b"\x00" * 3200
            body = (
                b"fmt "
                + struct.pack("<IHHIIHH", 16, 3, 1, SAMPLE_RATE, SAMPLE_RATE * 4, 4, 32)
                + b"data"
                + struct.pack("<I", len(payload))
                + payload
            )
            float_wav.write_bytes(
                b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body
            )
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.pcm_sha256(float_wav)
            self.assertEqual(caught.exception.code, "local_pcm_mismatch")

            truncated = root / "truncated.wav"
            truncated.write_bytes(
                b"RIFF"
                + struct.pack("<I", 36 + 3200)
                + b"WAVE"
                + b"fmt "
                + struct.pack("<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16)
                + b"data"
                + struct.pack("<I", 3200)
                + b"\x00" * 16
            )
            with self.assertRaises(cp.CheckpointContractError):
                cp.pcm_sha256(truncated)


class AtomicWriteTests(unittest.TestCase):
    def test_writes_0600_and_leaves_no_temporary_files(self):
        with tempfile.TemporaryDirectory() as raw:
            destination = Path(raw) / "roots" / "state.json"
            cp.atomic_write_bytes(b'{"a":1}', destination)
            self.assertEqual(destination.read_bytes(), b'{"a":1}')
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            self.assertEqual(
                [p.name for p in destination.parent.iterdir()], ["state.json"]
            )


class IdentityAndManifestTests(unittest.TestCase):
    def test_missing_identity_is_a_contract_error(self):
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_identity(Path(raw))
            self.assertEqual(caught.exception.code, "local_checkpoint_invalid")

    def test_manifest_bound_to_the_identity_bytes_on_disk(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            _identity, digest = cp.load_identity(fixture.v2)
            manifest = cp.load_manifest(fixture.v2, identity_digest=digest)
            self.assertEqual(manifest["planID"], PLAN_ID)

            # Editing identity.json invalidates the manifest's recorded digest.
            edited = dict(fixture.identity, jobID="job-tampered")
            cp.atomic_write_bytes(
                cp.canonical_dumps(edited).encode("utf-8"),
                fixture.v2 / "identity.json",
            )
            _identity, new_digest = cp.load_identity(fixture.v2)
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_manifest(fixture.v2, identity_digest=new_digest)
            self.assertEqual(caught.exception.code, "local_identity_mismatch")

    def test_unknown_schema_version_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            cp.atomic_write_bytes(
                cp.canonical_dumps(dict(fixture.identity, schemaVersion=3)).encode("utf-8"),
                fixture.v2 / "identity.json",
            )
            with self.assertRaises(cp.CheckpointContractError):
                cp.load_identity(fixture.v2)

    def test_unknown_root_id_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            with self.assertRaises(cp.CheckpointContractError):
                cp.find_root_plan(fixture.manifest, "root-doesnotexist")


class RootStateStoreTests(unittest.TestCase):
    def test_fresh_store_seeds_pending_leaves_from_the_plan(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            store = fixture.store()
            state = store.load()
            self.assertEqual(state["revision"], 0)
            self.assertEqual(
                [node["nodeID"] for node in store.pending_leaves()], [NODE_A, NODE_B]
            )
            self.assertTrue(all(n["state"] == cp.STATE_PENDING for n in state["nodes"]))
            self.assertEqual(fixture.state_path.stat().st_mode & 0o777, 0o600)

    def test_completed_leaf_commits_text_and_finish_evidence(self):
        with tempfile.TemporaryDirectory() as raw:
            events: list = []
            fixture = CheckpointFixture(Path(raw))
            store = fixture.store(events)
            store.load()
            revision = store.record_leaf(
                NODE_A,
                state=cp.STATE_COMPLETED,
                text="第一段文字",
                generation_tokens=42,
                maximum_tokens=16_384,
                reached_token_limit=False,
                finish_reason="stop",
                pcm_sha256=fixture.pcm,
            )
            self.assertEqual(revision, 1)
            node = store.node(NODE_A)
            self.assertEqual(node["state"], cp.STATE_COMPLETED)
            self.assertEqual(node["result"]["textSHA256"], cp.sha256_text("第一段文字"))
            self.assertEqual(node["result"]["finishEvidence"]["generationTokens"], 42)
            self.assertFalse(node["result"]["finishEvidence"]["reachedTokenLimit"])
            # The event is emitted only after the file is committed.
            self.assertEqual(events[-1][0], "checkpointCommitted")
            self.assertEqual(events[-1][1]["revision"], 1)
            self.assertEqual(events[-1][1]["nodeID"], NODE_A)

    def test_completed_leaf_without_a_token_count_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            store = CheckpointFixture(Path(raw)).store()
            store.load()
            with self.assertRaises(cp.CheckpointContractError) as caught:
                store.record_leaf(
                    NODE_A,
                    state=cp.STATE_COMPLETED,
                    text="有文字但沒有 token 計數",
                    generation_tokens=None,
                )
            self.assertEqual(caught.exception.code, "local_empty_unverified")

    def test_completed_leaf_with_blank_text_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            store = CheckpointFixture(Path(raw)).store()
            store.load()
            with self.assertRaises(cp.CheckpointContractError) as caught:
                store.record_leaf(
                    NODE_A, state=cp.STATE_COMPLETED, text="   ", generation_tokens=5
                )
            self.assertEqual(caught.exception.code, "local_empty_unverified")

    def test_gap_leaf_requires_a_reason(self):
        with tempfile.TemporaryDirectory() as raw:
            store = CheckpointFixture(Path(raw)).store()
            store.load()
            with self.assertRaises(cp.CheckpointContractError):
                store.record_leaf(NODE_A, state=cp.STATE_GAP)
            store.record_leaf(
                NODE_A,
                state=cp.STATE_GAP,
                gap_reason="token 上限",
                gap_error_code="token_limit_reached",
            )
            self.assertEqual(store.node(NODE_A)["state"], cp.STATE_GAP)

    def test_split_commits_parent_and_both_children_atomically(self):
        with tempfile.TemporaryDirectory() as raw:
            events: list = []
            fixture = CheckpointFixture(Path(raw))
            store = fixture.store(events)
            store.load()
            midpoint = CHUNK_BOUNDARY // 2
            left, right = cp.split_child_ids(NODE_A, ROOT_START, midpoint, CHUNK_BOUNDARY)
            revision = store.split_node(
                NODE_A,
                split_sample=midpoint,
                policy=cp.SPLIT_POLICY_TOKEN_MIDPOINT,
                left_id=left,
                right_id=right,
            )
            self.assertEqual(revision, 1)
            self.assertEqual(len(events), 1, "one split is exactly one commit")
            parent = store.node(NODE_A)
            self.assertEqual(parent["state"], cp.STATE_SPLIT)
            self.assertEqual(parent["childrenIDs"], [left, right])
            self.assertIsNone(parent["result"], "a split parent must not carry text")
            self.assertEqual(store.node(left)["state"], cp.STATE_PENDING)
            self.assertEqual(store.node(right)["state"], cp.STATE_PENDING)
            self.assertEqual(store.node(left)["splitDepth"], 1)
            # The parent leaves the pending set; both children join it in order.
            self.assertEqual(
                [n["nodeID"] for n in store.pending_leaves()], [left, right, NODE_B]
            )

    def test_split_outside_the_parent_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            store = CheckpointFixture(Path(raw)).store()
            store.load()
            with self.assertRaises(cp.CheckpointContractError):
                store.split_node(
                    NODE_A,
                    split_sample=CHUNK_BOUNDARY,
                    policy=cp.SPLIT_POLICY_TOKEN_MIDPOINT,
                    left_id="node-x",
                    right_id="node-y",
                )

    def test_running_is_never_resumed_as_completed(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            first = fixture.store()
            first.load()
            first.mark_running(NODE_A)
            reloaded = fixture.store()
            reloaded.load()
            node = reloaded.node(NODE_A)
            self.assertEqual(node["state"], cp.STATE_PENDING)
            self.assertIsNone(node["result"])
            self.assertEqual(
                [n["nodeID"] for n in reloaded.pending_leaves()], [NODE_A, NODE_B]
            )

    def test_node_spanning_ignores_split_parents(self):
        with tempfile.TemporaryDirectory() as raw:
            store = CheckpointFixture(Path(raw)).store()
            store.load()
            self.assertEqual(store.node_spanning(ROOT_START, CHUNK_BOUNDARY)["nodeID"], NODE_A)
            midpoint = CHUNK_BOUNDARY // 2
            left, right = cp.split_child_ids(NODE_A, ROOT_START, midpoint, CHUNK_BOUNDARY)
            store.split_node(
                NODE_A,
                split_sample=midpoint,
                policy=cp.SPLIT_POLICY_TOKEN_MIDPOINT,
                left_id=left,
                right_id=right,
            )
            # The split parent no longer owns its span; the two children do.
            self.assertIsNone(store.node_spanning(ROOT_START, CHUNK_BOUNDARY))
            self.assertEqual(store.node_spanning(ROOT_START, midpoint)["nodeID"], left)
            self.assertEqual(store.node_spanning(midpoint, CHUNK_BOUNDARY)["nodeID"], right)
            self.assertIsNone(store.node_spanning(ROOT_START, midpoint - 1))

    def test_revision_is_monotonic_and_reloads(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            store = fixture.store()
            store.load()
            store.mark_running(NODE_A)
            store.record_leaf(
                NODE_A, state=cp.STATE_COMPLETED, text="文字", generation_tokens=3
            )
            self.assertEqual(store.revision, 2)
            reloaded = fixture.store()
            reloaded.load()
            self.assertEqual(reloaded.revision, 2)
            self.assertEqual(reloaded.node(NODE_A)["state"], cp.STATE_COMPLETED)

    def test_rejects_a_state_file_belonging_to_another_plan(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            store = fixture.store()
            store.load()
            payload = fixture.read_state()
            payload["planID"] = "plan-" + "9" * 59
            fixture.state_path.write_bytes(
                cp.canonical_dumps(payload).encode("utf-8")
            )
            with self.assertRaises(cp.CheckpointContractError) as caught:
                fixture.store().load()
            self.assertEqual(caught.exception.code, "local_identity_mismatch")


class CoverageTests(unittest.TestCase):
    def test_covering_leaves_are_ordered_and_gaps_are_reported(self):
        with tempfile.TemporaryDirectory() as raw:
            store = CheckpointFixture(Path(raw)).store()
            store.load()
            store.record_leaf(
                NODE_B, state=cp.STATE_COMPLETED, text="後段", generation_tokens=4
            )
            leaves = cp.ordered_covering_leaves(store.state)
            self.assertEqual(
                [(n["startSample"], n["endSample"]) for n in leaves],
                [(CHUNK_BOUNDARY, ROOT_END)],
            )
            self.assertEqual(
                cp.coverage_gap_samples(
                    store.state, root_start=ROOT_START, root_end=ROOT_END
                ),
                [(ROOT_START, CHUNK_BOUNDARY)],
            )

    def test_a_fully_covered_root_reports_no_gaps(self):
        with tempfile.TemporaryDirectory() as raw:
            store = CheckpointFixture(Path(raw)).store()
            store.load()
            for node_id in (NODE_A, NODE_B):
                store.record_leaf(
                    node_id, state=cp.STATE_COMPLETED, text="文字", generation_tokens=4
                )
            self.assertEqual(
                cp.coverage_gap_samples(
                    store.state, root_start=ROOT_START, root_end=ROOT_END
                ),
                [],
            )


class VerifyRootPlanTests(unittest.TestCase):
    def test_accepts_matching_audio(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            digest, count = cp.verify_root_plan_against_audio(
                cp.find_root_plan(fixture.manifest, ROOT_ID),
                audio_path=fixture.audio,
                audio_start_sample=ROOT_START,
            )
            self.assertEqual(digest, fixture.pcm)
            self.assertEqual(count, ROOT_END)

    def test_rejects_replaced_audio(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            write_wav(fixture.audio, ROOT_END, value=9)
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.verify_root_plan_against_audio(
                    cp.find_root_plan(fixture.manifest, ROOT_ID),
                    audio_path=fixture.audio,
                    audio_start_sample=ROOT_START,
                )
            self.assertEqual(caught.exception.code, "local_pcm_mismatch")

    def test_rejects_a_wrong_absolute_start(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            with self.assertRaises(cp.CheckpointContractError):
                cp.verify_root_plan_against_audio(
                    cp.find_root_plan(fixture.manifest, ROOT_ID),
                    audio_path=fixture.audio,
                    audio_start_sample=ROOT_START + 1,
                )

    def test_rejects_a_shorter_decode(self):
        """A plan whose span disagrees with its own PCM digest is corrupt.

        The digest matches the file, so only the sample-count check can catch
        that the root claims more audio than was actually hashed.
        """
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            fixture = CheckpointFixture(root)
            short = root / "short.wav"
            write_wav(short, CHUNK_BOUNDARY)
            tampered = dict(
                cp.find_root_plan(fixture.manifest, ROOT_ID),
                pcmSHA256=cp.pcm_sha256(short),
            )
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.verify_root_plan_against_audio(
                    tampered, audio_path=short, audio_start_sample=ROOT_START
                )
            self.assertEqual(caught.exception.code, "local_pcm_mismatch")


class RequestValidationTests(unittest.TestCase):
    def block(self) -> dict:
        with tempfile.TemporaryDirectory() as raw:
            return CheckpointFixture(Path(raw)).request_block()

    def test_accepts_a_complete_block(self):
        mlx_runner.validate_checkpoint_v2(self.block())

    def test_absent_block_is_allowed_for_v1_requests(self):
        mlx_runner.validate_checkpoint_v2(None)

    def test_every_missing_field_is_rejected(self):
        base = self.block()
        for key in list(base):
            partial = dict(base)
            del partial[key]
            with self.assertRaises(ValueError, msg=key):
                mlx_runner.validate_checkpoint_v2(partial)

    def test_a_boolean_coordinate_is_rejected(self):
        with self.assertRaises(ValueError):
            mlx_runner.validate_checkpoint_v2(
                dict(self.block(), audioStartSample=True)
            )

    def test_a_wrong_sample_rate_is_rejected(self):
        with self.assertRaises(ValueError):
            mlx_runner.validate_checkpoint_v2(dict(self.block(), sampleRate=44_100))

    def test_a_relative_directory_is_rejected(self):
        with self.assertRaises(ValueError):
            mlx_runner.validate_checkpoint_v2(
                dict(self.block(), directory="local-checkpoint-v2")
            )

    def test_an_inverted_work_span_is_rejected(self):
        with self.assertRaises(ValueError):
            mlx_runner.validate_checkpoint_v2(
                dict(self.block(), workStartSample=ROOT_END, workEndSample=ROOT_START)
            )

    def test_an_unknown_prompt_channel_is_rejected(self):
        """The channel is part of the frozen identity, so it is all-or-nothing.

        A missing or invented value must not be read as "whatever the model
        happened to support", which is exactly the ambiguity that would let a
        glossary run reuse a no-glossary checkpoint.
        """
        for value in ["systemPrompt", "", None, True, 0, ["system_prompt"]]:
            with self.assertRaises(ValueError, msg=repr(value)):
                mlx_runner.validate_checkpoint_v2(
                    dict(self.block(), promptChannel=value)
                )


class PromptChannelTests(unittest.TestCase):
    def test_system_prompt_wins_over_context(self):
        self.assertEqual(
            mlx_runner.resolve_prompt_channel("專有名詞", True, True),
            mlx_runner.PROMPT_CHANNEL_SYSTEM,
        )

    def test_context_is_used_when_system_prompt_is_absent(self):
        self.assertEqual(
            mlx_runner.resolve_prompt_channel("專有名詞", False, True),
            mlx_runner.PROMPT_CHANNEL_CONTEXT,
        )

    def test_an_empty_prompt_never_claims_a_channel(self):
        for capability in [(True, True), (True, False), (False, True), (False, False)]:
            self.assertEqual(
                mlx_runner.resolve_prompt_channel("", *capability),
                mlx_runner.PROMPT_CHANNEL_NONE,
                msg=capability,
            )

    def test_no_capability_means_no_channel(self):
        self.assertEqual(
            mlx_runner.resolve_prompt_channel("專有名詞", False, False),
            mlx_runner.PROMPT_CHANNEL_NONE,
        )


class RuntimeReportTests(unittest.TestCase):
    """The probe Swift runs before it freezes identity.json.

    It may not import MLX or touch Metal: the whole point is that Swift can learn
    which prompt channel will be used before any model is loaded.
    """

    def capture(self, *, capability=(True, False), versions=("0.30.0", "0.4.6")) -> list:
        events: list = []
        known = {"mlx": versions[0], "mlx-audio": versions[1]}
        with patch.object(
            mlx_runner,
            "emit",
            side_effect=lambda event_type, **payload: events.append((event_type, payload)),
        ), patch.object(
            mlx_runner, "static_capability", return_value=capability
        ), patch.object(
            mlx_runner, "distribution_version", side_effect=known.get
        ):
            mlx_runner.report_runtime()
        return events

    def test_reports_one_runtime_event_carrying_every_identity_field(self):
        events = self.capture()
        self.assertEqual([event_type for event_type, _ in events], ["runtime"])
        self.assertEqual(
            events[0][1],
            {
                "asrContractVersion": mlx_runner.ASR_CONTRACT_VERSION,
                "supportsSystemPrompt": True,
                "supportsContext": False,
                "mlxVersion": "0.30.0",
                "mlxAudioVersion": "0.4.6",
            },
        )

    def test_capability_follows_the_installed_model_source(self):
        payload = self.capture(capability=(False, True))[0][1]
        self.assertFalse(payload["supportsSystemPrompt"])
        self.assertTrue(payload["supportsContext"])

    def test_an_unreadable_distribution_is_reported_as_null_not_guessed(self):
        payload = self.capture(versions=(None, None))[0][1]
        self.assertIsNone(payload["mlxVersion"])
        self.assertIsNone(payload["mlxAudioVersion"])

    def test_the_contract_version_matches_the_swift_constant(self):
        """Two literals in two languages; a drift would break every resume."""
        swift = (
            Path(__file__).parents[1]
            / "Sources"
            / "RecordToTextCore"
            / "LocalCheckpointManifest.swift"
        ).read_text(encoding="utf-8")
        self.assertIn(
            f'asrContractVersion = "{mlx_runner.ASR_CONTRACT_VERSION}"',
            swift,
        )


class SilencePlanLoadingTests(unittest.TestCase):
    """§7: the helper reads the analysis Swift froze; it never re-derives it."""

    def test_a_fixed_cut_plan_records_no_silence_file(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            self.assertIsNone(
                cp.load_silence_plan(fixture.v2, fixture.manifest),
                "a phase-0 manifest must keep loading as 'no candidates'",
            )

    def test_a_frozen_plan_round_trips_its_thresholds(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            freeze_silence_plan(
                fixture,
                silence_plan_payload(intervals=[(960_000, 1_008_000)]),
            )
            plan = cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertIsNotNone(plan)
            self.assertEqual(plan.detector, "ffmpeg-silencedetect")
            self.assertEqual(plan.threshold_db, -35.0)
            self.assertEqual(plan.minimum_duration_seconds, 0.35)
            self.assertEqual(plan.recursive_search_seconds, 5.0)
            self.assertFalse(plan.truncated)
            self.assertEqual(
                plan.intervals, [{"startSample": 960_000, "endSample": 1_008_000}]
            )
            # Swift quantizes as floor(seconds * rate + 0.5); banker's rounding
            # would land one sample away on an exact half and pick another pause.
            self.assertEqual(plan.search_samples(SAMPLE_RATE), 5 * SAMPLE_RATE)
            self.assertEqual(plan.search_samples(16_000), 80_000)

    def test_search_samples_never_rounds_the_window_up(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            freeze_silence_plan(
                fixture, silence_plan_payload(recursive_search_seconds="4.500000")
            )
            plan = cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertEqual(plan.search_samples(SAMPLE_RATE), int(4.5 * SAMPLE_RATE))

    def test_a_tampered_plan_is_refused_by_its_digest(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            raw_bytes = freeze_silence_plan(fixture, silence_plan_payload())
            plan_path = fixture.v2 / SILENCE_PLAN_FILENAME
            tampered = raw_bytes.replace(b'"enabled":true', b'"enabled":false')
            self.assertNotEqual(tampered, raw_bytes, "the fixture must really differ")
            plan_path.write_bytes(tampered)
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertEqual(caught.exception.code, "local_identity_mismatch")

    def test_a_recorded_digest_without_its_file_is_a_contract_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            freeze_silence_plan(fixture, silence_plan_payload())
            (fixture.v2 / SILENCE_PLAN_FILENAME).unlink()
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertEqual(caught.exception.code, "local_checkpoint_invalid")

    def test_a_relative_path_escaping_the_v2_directory_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            freeze_silence_plan(fixture, silence_plan_payload())
            escape = fixture.root / "escape.json"
            payload = silence_plan_payload()
            body = cp.canonical_dumps(payload).encode("utf-8")
            escape.write_bytes(body)
            fixture.manifest["silencePlanRelativePath"] = "../escape.json"
            fixture.manifest["silencePlanDigest"] = hashlib.sha256(body).hexdigest()
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertEqual(caught.exception.code, "local_checkpoint_invalid")
            self.assertIn("路徑", str(caught.exception))

    def test_a_half_recorded_reference_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            freeze_silence_plan(fixture, silence_plan_payload())
            del fixture.manifest["silencePlanRelativePath"]
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertEqual(caught.exception.code, "local_checkpoint_invalid")

    def test_a_noise_profile_without_db_is_not_guessed_as_zero(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            freeze_silence_plan(fixture, silence_plan_payload(noise_profile="-35"))
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertEqual(caught.exception.code, "local_checkpoint_invalid")
            self.assertIn("dB", str(caught.exception))

    def test_a_wrong_schema_version_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            payload = silence_plan_payload()
            payload["schemaVersion"] = cp.SCHEMA_VERSION + 1
            body = cp.canonical_dumps(payload).encode("utf-8")
            cp.atomic_write_bytes(body, fixture.v2 / SILENCE_PLAN_FILENAME)
            fixture.manifest["silencePlanRelativePath"] = SILENCE_PLAN_FILENAME
            fixture.manifest["silencePlanDigest"] = hashlib.sha256(body).hexdigest()
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertEqual(caught.exception.code, "local_checkpoint_invalid")

    def test_a_negative_search_window_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            freeze_silence_plan(
                fixture, silence_plan_payload(recursive_search_seconds="-5.000000")
            )
            with self.assertRaises(cp.CheckpointContractError) as caught:
                cp.load_silence_plan(fixture.v2, fixture.manifest)
            self.assertEqual(caught.exception.code, "local_checkpoint_invalid")


class FakeResult:
    def __init__(self, text: str, generation_tokens: int = 1) -> None:
        self.text = text
        self.generation_tokens = generation_tokens


class NoTokenResult:
    """A runtime that reports no token count cannot prove it was not truncated."""

    text = "有文字"


class FakeAudio:
    """Decoded-sample stand-in whose slices remember their absolute origin."""

    def __init__(self, offset: int, count: int) -> None:
        self.offset = offset
        self.count = count

    def __len__(self) -> int:
        return self.count

    def __getitem__(self, item):
        if isinstance(item, slice):
            start = item.start or 0
            stop = self.count if item.stop is None else item.stop
            return FakeAudio(self.offset + start, stop - start)
        return self.offset + item


class FakeModel:
    sample_rate = SAMPLE_RATE

    def __init__(self, results) -> None:
        self._results = list(results)
        self.spans: list[tuple[int, int]] = []

    def generate(self, span, **_arguments):
        self.spans.append((span.offset, len(span)))
        result = self._results.pop(0)
        if isinstance(result, BaseException):
            raise result
        return result


class TranscribeV2Tests(unittest.TestCase):
    prompt = "請忠實轉錄音訊內容。"

    def run_v2(self, fixture: CheckpointFixture, model: FakeModel) -> list:
        events: list = []
        request = {
            "audioPath": str(fixture.audio),
            "outputPath": str(fixture.root / "transcript.txt"),
        }
        original_emit = mlx_runner.emit
        mlx_runner.emit = lambda event_type, **payload: events.append((event_type, payload))
        try:
            mlx_runner.transcribe_v2(
                request=request,
                block=fixture.request_block(),
                model=model,
                generation_arguments={"max_tokens": 16_384},
                sample_rate=SAMPLE_RATE,
                maximum_tokens=16_384,
                min_split_seconds=30.0,
                audio=FakeAudio(0, fixture.sample_count),
                prompt=self.prompt,
                terms=[],
                output=Path(request["outputPath"]),
                started=0.0,
            )
        finally:
            mlx_runner.emit = original_emit
        return events

    def test_a_fresh_root_completes_both_leaves_in_span_order(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            model = FakeModel([FakeResult("第一段"), FakeResult("第二段")])
            events = self.run_v2(fixture, model)
            # The model saw exactly the planned spans, in order, at full length.
            self.assertEqual(
                model.spans,
                [(ROOT_START, CHUNK_BOUNDARY), (CHUNK_BOUNDARY, CHUNK_BOUNDARY)],
            )
            state = fixture.read_state()
            self.assertEqual(
                [n["state"] for n in state["nodes"]],
                [cp.STATE_COMPLETED, cp.STATE_COMPLETED],
            )
            self.assertEqual(state["nodes"][0]["result"]["text"], "第一段")
            self.assertEqual(state["nodes"][0]["result"]["pcmSHA256"], fixture.pcm)
            committed = [e for e in events if e[0] == "checkpointCommitted"]
            self.assertEqual(len(committed), 4, "2 running + 2 completed commits")
            completed = [e for e in events if e[0] == "completed"]
            self.assertEqual(len(completed), 1)
            self.assertFalse(completed[0][1]["containsSkippedAudio"])
            text = Path(fixture.root / "transcript.txt").read_text(encoding="utf-8")
            self.assertIn("[00:00:00 - 00:02:00]", text)
            self.assertIn("第一段", text)
            self.assertIn("第二段", text)

    def test_a_resumed_root_skips_completed_leaves(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            store = fixture.store()
            store.load()
            store.record_leaf(
                NODE_A,
                state=cp.STATE_COMPLETED,
                text="第一段",
                generation_tokens=11,
                pcm_sha256=fixture.pcm,
            )
            model = FakeModel([FakeResult("第二段")])
            self.run_v2(fixture, model)
            self.assertEqual(
                model.spans, [(CHUNK_BOUNDARY, CHUNK_BOUNDARY)],
                "only the pending leaf is re-run",
            )
            text = Path(fixture.root / "transcript.txt").read_text(encoding="utf-8")
            self.assertIn("第一段", text)
            self.assertIn("第二段", text)

    def test_a_token_limit_splits_and_commits_both_children(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            model = FakeModel(
                [
                    FakeResult("頂滿", generation_tokens=16_384),
                    FakeResult("左半"),
                    FakeResult("右半"),
                    FakeResult("第二段"),
                ]
            )
            self.run_v2(fixture, model)
            by_id = {n["nodeID"]: n for n in fixture.read_state()["nodes"]}
            parent = by_id[NODE_A]
            self.assertEqual(parent["state"], cp.STATE_SPLIT)
            self.assertIsNone(parent["result"])
            left_id, right_id = parent["childrenIDs"]
            self.assertEqual(by_id[left_id]["result"]["text"], "左半")
            self.assertEqual(by_id[right_id]["result"]["text"], "右半")
            self.assertEqual(by_id[left_id]["endSample"], by_id[right_id]["startSample"])
            self.assertEqual(
                by_id[left_id]["splitPolicy"], cp.SPLIT_POLICY_TOKEN_MIDPOINT
            )
            # Children sit inside the parent, so the union still tiles the root.
            self.assertEqual(by_id[left_id]["startSample"], ROOT_START)
            self.assertEqual(by_id[right_id]["endSample"], CHUNK_BOUNDARY)

    def test_an_irreducible_span_becomes_a_gap_and_the_run_continues(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            capped = lambda: FakeResult("頂滿", generation_tokens=16_384)  # noqa: E731
            model = FakeModel(
                [capped(), capped(), capped(), FakeResult("第二段")]
            )
            events = self.run_v2(fixture, model)
            gaps = [
                n for n in fixture.read_state()["nodes"] if n["state"] == cp.STATE_GAP
            ]
            self.assertEqual(len(gaps), 2, "both irreducible halves are preserved")
            for gap in gaps:
                self.assertEqual(gap["result"]["gapErrorCode"], "token_limit_reached")
                self.assertTrue(gap["result"]["gapReason"])
                self.assertEqual(gap["result"]["text"], "")
            completed = [e for e in events if e[0] == "completed"]
            self.assertTrue(completed[0][1]["containsSkippedAudio"])
            text = Path(fixture.root / "transcript.txt").read_text(encoding="utf-8")
            self.assertIn("【此處約缺少 30 秒", text)
            self.assertIn("第二段", text)

    def test_a_leaf_without_a_token_count_fails_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            model = FakeModel([NoTokenResult()])
            with self.assertRaises(cp.CheckpointContractError) as caught:
                self.run_v2(fixture, model)
            self.assertEqual(caught.exception.code, "local_empty_unverified")

    def test_a_mismatched_plan_id_is_refused_before_any_inference(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            model = FakeModel([FakeResult("第一段"), FakeResult("第二段")])
            with self.assertRaises(cp.CheckpointContractError) as caught:
                mlx_runner.transcribe_v2(
                    request={"audioPath": str(fixture.audio)},
                    block=dict(fixture.request_block(), planID="plan-" + "1" * 59),
                    model=model,
                    generation_arguments={"max_tokens": 16_384},
                    sample_rate=SAMPLE_RATE,
                    maximum_tokens=16_384,
                    min_split_seconds=30.0,
                    audio=FakeAudio(0, fixture.sample_count),
                    prompt=self.prompt,
                    terms=[],
                    output=Path(fixture.root / "transcript.txt"),
                    started=0.0,
                )
            self.assertEqual(caught.exception.code, "local_identity_mismatch")
            self.assertEqual(model.spans, [], "no audio may be transcribed")

    def test_replaced_audio_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            write_wav(fixture.audio, ROOT_END, value=11)
            model = FakeModel([FakeResult("第一段"), FakeResult("第二段")])
            with self.assertRaises(cp.CheckpointContractError) as caught:
                self.run_v2(fixture, model)
            self.assertEqual(caught.exception.code, "local_pcm_mismatch")
            self.assertEqual(model.spans, [])

    def test_a_short_decode_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw), sample_count=CHUNK_BOUNDARY)
            model = FakeModel([FakeResult("第一段")])
            with self.assertRaises(cp.CheckpointContractError) as caught:
                self.run_v2(fixture, model)
            self.assertEqual(caught.exception.code, "local_pcm_mismatch")
            self.assertEqual(model.spans, [])

    # §4 row 4 / §6: the token recursion selects from the frozen analysis.

    def silence_run(
        self,
        fixture: CheckpointFixture,
        model: FakeModel,
        payload: dict,
    ) -> list:
        freeze_silence_plan(fixture, payload)
        return self.run_v2(fixture, model)

    def test_a_capped_leaf_splits_on_the_frozen_pause(self):
        pause = (62 * SAMPLE_RATE, 64 * SAMPLE_RATE)  # midpoint 63 s
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
            capped = FakeResult("頂滿", generation_tokens=16_384)
            model = FakeModel([capped, FakeResult("左半"), FakeResult("右半")])
            events = self.silence_run(
                fixture, model, silence_plan_payload(intervals=[pause])
            )
            self.assertEqual(
                model.spans,
                [
                    (ROOT_START, ROOT_END),
                    (ROOT_START, 63 * SAMPLE_RATE),
                    (63 * SAMPLE_RATE, ROOT_END - 63 * SAMPLE_RATE),
                ],
                "the cut moves to the pause, not to the arithmetic midpoint",
            )
            by_id = {n["nodeID"]: n for n in fixture.read_state()["nodes"]}
            parent = by_id[NODE_A]
            self.assertEqual(parent["state"], cp.STATE_SPLIT)
            self.assertEqual(
                parent["splitPolicy"], cp.SPLIT_POLICY_TOKEN_SILENCE
            )
            left_id, right_id = parent["childrenIDs"]
            self.assertEqual(by_id[left_id]["endSample"], 63 * SAMPLE_RATE)
            self.assertEqual(by_id[right_id]["startSample"], 63 * SAMPLE_RATE)
            self.assertEqual(by_id[right_id]["endSample"], ROOT_END)
            self.assertEqual(by_id[left_id]["result"]["text"], "左半")
            self.assertEqual(by_id[right_id]["result"]["text"], "右半")
            counters = [
                e[1]["message"]
                for e in events
                if e[0] == "log" and "token 遞迴切點" in e[1].get("message", "")
            ]
            self.assertEqual(len(counters), 1)
            self.assertIn("移到停頓 1 次", counters[0])
            self.assertIn("使用合法中點 0 次", counters[0])

    def test_a_pause_exactly_on_the_midpoint_records_the_midpoint_policy(self):
        # NODE_A is 60 s, so the only legal split is 30 s; a pause sitting right
        # there is still a midpoint cut, and must not be dressed up as a move.
        pause = (29 * SAMPLE_RATE, 31 * SAMPLE_RATE)  # midpoint 30 s
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            capped = FakeResult("頂滿", generation_tokens=16_384)
            model = FakeModel(
                [capped, FakeResult("左半"), FakeResult("右半"), FakeResult("第二段")]
            )
            events = self.silence_run(
                fixture, model, silence_plan_payload(intervals=[pause])
            )
            by_id = {n["nodeID"]: n for n in fixture.read_state()["nodes"]}
            self.assertEqual(
                by_id[NODE_A]["splitPolicy"], cp.SPLIT_POLICY_TOKEN_MIDPOINT
            )
            self.assertEqual(
                model.spans[1], (ROOT_START, CHUNK_BOUNDARY // 2)
            )
            counters = [
                e[1]["message"]
                for e in events
                if e[0] == "log" and "token 遞迴切點" in e[1].get("message", "")
            ]
            self.assertIn("使用合法中點 1 次", counters[0])

    def test_a_pause_outside_the_search_window_is_ignored(self):
        # A 20 s pause is 40 s away from the 60 s midpoint of a 120 s leaf: far
        # outside ±5 s, so the recursion keeps the legal midpoint.
        pause = (19 * SAMPLE_RATE, 21 * SAMPLE_RATE)
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
            capped = FakeResult("頂滿", generation_tokens=16_384)
            model = FakeModel([capped, FakeResult("左半"), FakeResult("右半")])
            self.silence_run(fixture, model, silence_plan_payload(intervals=[pause]))
            by_id = {n["nodeID"]: n for n in fixture.read_state()["nodes"]}
            self.assertEqual(
                by_id[NODE_A]["splitPolicy"], cp.SPLIT_POLICY_TOKEN_MIDPOINT
            )
            self.assertEqual(model.spans[1], (ROOT_START, ROOT_END // 2))

    def test_a_truncated_plan_falls_back_to_legal_midpoints(self):
        # §3.7: past the storage cap Swift keeps the cut plan but drops the
        # interval list, so the helper finds no candidates and says so.
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
            capped = FakeResult("頂滿", generation_tokens=16_384)
            model = FakeModel([capped, FakeResult("左半"), FakeResult("右半")])
            events = self.silence_run(
                fixture, model, silence_plan_payload(intervals=(), truncated=True)
            )
            by_id = {n["nodeID"]: n for n in fixture.read_state()["nodes"]}
            self.assertEqual(
                by_id[NODE_A]["splitPolicy"], cp.SPLIT_POLICY_TOKEN_MIDPOINT
            )
            self.assertEqual(model.spans[1], (ROOT_START, ROOT_END // 2))
            self.assertTrue(
                any(
                    e[0] == "log" and "超過保存上限" in e[1].get("message", "")
                    for e in events
                )
            )

    def test_a_run_without_a_silence_plan_reports_no_silence_metrics(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            model = FakeModel([FakeResult("第一段"), FakeResult("第二段")])
            events = self.run_v2(fixture, model)
            self.assertFalse(
                any(
                    "已載入凍結的靜音計畫" in e[1].get("message", "")
                    for e in events
                    if e[0] == "log"
                ),
                "a fixed-cut plan must not claim a silence analysis it never ran",
            )

    def test_an_empty_leaf_wholly_inside_a_pause_is_verified_silence(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
            model = FakeModel([FakeResult("")])
            events = self.silence_run(
                fixture,
                model,
                silence_plan_payload(intervals=[(ROOT_START, ROOT_END)]),
            )
            node = fixture.read_state()["nodes"][0]
            self.assertEqual(node["state"], cp.STATE_VERIFIED_SILENCE)
            evidence = node["result"]["silenceEvidence"]
            self.assertEqual(evidence["detector"], "ffmpeg-silencedetect")
            self.assertEqual(evidence["coveredStartSample"], node["startSample"])
            self.assertEqual(evidence["coveredEndSample"], node["endSample"])
            self.assertEqual(evidence["thresholdDB"], -35.0)
            self.assertEqual(evidence["minimumDurationSeconds"], 0.35)
            self.assertEqual(node["result"]["text"], "")
            completed = [e for e in events if e[0] == "completed"]
            self.assertEqual(len(completed), 1)
            self.assertFalse(completed[0][1]["containsSkippedAudio"])
            text = Path(fixture.root / "transcript.txt").read_text(encoding="utf-8")
            self.assertNotIn("【此處約缺少", text)

    def test_an_empty_leaf_only_partly_silent_fails_and_keeps_prior_text(self):
        # §6: a detected pause inside the span says nothing about the rest of
        # it, and -35dB is not a model of human speech. Publishing this as a
        # gap-free completion would silently drop a minute of audio.
        partial = (CHUNK_BOUNDARY, CHUNK_BOUNDARY + 30 * SAMPLE_RATE)
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw))
            model = FakeModel([FakeResult("第一段"), FakeResult("")])
            with self.assertRaises(cp.CheckpointContractError) as caught:
                self.silence_run(
                    fixture, model, silence_plan_payload(intervals=[partial])
                )
            self.assertEqual(caught.exception.code, "local_empty_unverified")
            by_id = {n["nodeID"]: n for n in fixture.read_state()["nodes"]}
            self.assertEqual(by_id[NODE_A]["state"], cp.STATE_COMPLETED)
            self.assertEqual(by_id[NODE_A]["result"]["text"], "第一段")
            self.assertEqual(by_id[NODE_B]["state"], cp.STATE_FAILED)
            self.assertIsNone(by_id[NODE_B]["result"]["silenceEvidence"])
            partial_path = fixture.root / "transcript.txt.partial.txt"
            self.assertTrue(partial_path.is_file())
            preserved = partial_path.read_text(encoding="utf-8")
            self.assertIn("第一段", preserved)
            self.assertNotIn("第二段", preserved)
            self.assertFalse(
                Path(fixture.root / "transcript.txt").exists(),
                "a failed leaf must not be published as the final transcript",
            )

    def test_an_empty_leaf_without_a_silence_plan_still_fails_closed(self):
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
            model = FakeModel([FakeResult("")])
            with self.assertRaises(cp.CheckpointContractError) as caught:
                self.run_v2(fixture, model)
            self.assertEqual(caught.exception.code, "local_empty_unverified")
            self.assertEqual(
                fixture.read_state()["nodes"][0]["state"], cp.STATE_FAILED
            )

    def test_a_failed_right_child_leaves_the_committed_left_half_recoverable(self):
        """§8: the left commit and its span survive a right-half failure.

        Recovering must not mean replanning: the parent is already ``split`` on
        disk with both children's boundaries, so a resume re-runs only the half
        that never finished and keeps the text the first run proved.
        """

        pause = (62 * SAMPLE_RATE, 64 * SAMPLE_RATE)  # midpoint 63 s
        split_at = 63 * SAMPLE_RATE
        with tempfile.TemporaryDirectory() as raw:
            fixture = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
            freeze_silence_plan(fixture, silence_plan_payload(intervals=[pause]))
            capped = FakeResult("頂滿", generation_tokens=16_384)
            crashed = FakeModel(
                [capped, FakeResult("左半"), RuntimeError("Metal 配置失敗")]
            )
            with self.assertRaises(RuntimeError):
                self.run_v2(fixture, crashed)

            by_id = {n["nodeID"]: n for n in fixture.read_state()["nodes"]}
            parent = by_id[NODE_A]
            self.assertEqual(parent["state"], cp.STATE_SPLIT)
            left_id, right_id = parent["childrenIDs"]
            left = by_id[left_id]
            self.assertEqual(left["state"], cp.STATE_COMPLETED)
            self.assertEqual(left["result"]["text"], "左半")
            self.assertEqual(left["startSample"], ROOT_START)
            self.assertEqual(left["endSample"], split_at)
            self.assertEqual(by_id[right_id]["state"], cp.STATE_PENDING)
            partial_path = fixture.root / "transcript.txt.partial.txt"
            self.assertIn("左半", partial_path.read_text(encoding="utf-8"))

            resumed = FakeModel([FakeResult("右半")])
            self.run_v2(fixture, resumed)
            self.assertEqual(
                resumed.spans, [(split_at, ROOT_END - split_at)],
                "only the unfinished right half is transcribed again",
            )
            by_id = {n["nodeID"]: n for n in fixture.read_state()["nodes"]}
            self.assertEqual(by_id[left_id]["result"]["text"], "左半")
            self.assertEqual(by_id[right_id]["result"]["text"], "右半")
            text = Path(fixture.root / "transcript.txt").read_text(encoding="utf-8")
            self.assertIn("左半", text)
            self.assertIn("右半", text)


class SilenceHardeningTests(unittest.TestCase):
    run_v2 = TranscribeV2Tests.run_v2
    silence_run = TranscribeV2Tests.silence_run
    prompt = TranscribeV2Tests.prompt
    def test_wrong_but_digest_valid_provenance_never_generates(self):
        """H1.3: the same fixture, the same verdict and the same code as Swift.

        `LocalSilencePlannerTests.testProvenanceAndContractMutationsAreRefused`
        mutates these exact fields from the Swift side and asserts these exact
        codes. Every mutation keeps the file digest in sync with the manifest,
        so what is being refused is the contract, not a stale hash.
        """
        invalid = "local_checkpoint_invalid"
        mutations = [
            ("sourceSHA256", "a"*64, "local_source_changed"),
            ("scanPCMSHA256", "b"*64, "local_identity_mismatch"),
            ("normalizationDigest", "c"*64, "local_identity_mismatch"),
            ("coveredStartSample", ROOT_END+1, invalid),
            ("enabled", False, invalid),
            ("truncated", True, invalid),
            ("detector", "unknown", invalid),
            ("plannerVersion", "unknown", invalid),
            ("intervals", [{"startSample": True, "endSample": ROOT_END}], invalid),
            ("intervals", [{"startSample": 0, "endSample": ROOT_END+1}], invalid),
            ("intervals", "bad", invalid),
        ]
        for key, value, code in mutations:
            with self.subTest(key=key, value=value), tempfile.TemporaryDirectory() as raw:
                f = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
                payload = silence_plan_payload(intervals=[(ROOT_START, ROOT_END)])
                payload[key] = value
                freeze_silence_plan(f, payload)
                model = FakeModel([FakeResult("")])
                with self.assertRaises(cp.CheckpointContractError) as caught:
                    self.run_v2(f, model)
                self.assertEqual(caught.exception.code, code)
                self.assertEqual(model.spans, [])
                self.assertFalse((f.root / "transcript.txt").exists())

    def test_existing_silence_leaf_must_bind_to_the_same_evidence(self):
        with tempfile.TemporaryDirectory() as raw:
            f = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
            self.silence_run(f, FakeModel([FakeResult("")]), silence_plan_payload(intervals=[(0, ROOT_END)]))
            state = f.read_state()
            state["nodes"][0]["result"]["silenceEvidence"]["silencePlanDigest"] = "0" * 64
            path = f.v2 / "roots" / (ROOT_ID + ".json")
            cp.atomic_write_bytes(cp.canonical_dumps(state).encode(), path)
            before = path.read_bytes()
            model = FakeModel([])
            with self.assertRaises(cp.CheckpointContractError):
                self.run_v2(f, model)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(model.spans, [])

    def test_failed_recursion_still_logs_cut_counts_and_keeps_left(self):
        with tempfile.TemporaryDirectory() as raw:
            f = CheckpointFixture(Path(raw), chunks=SINGLE_CHUNK)
            freeze_silence_plan(f, silence_plan_payload(intervals=[(62*SAMPLE_RATE,64*SAMPLE_RATE)]))
            events = []
            original = mlx_runner.emit
            # run_v2 owns emit, so observe calls through a wrapping emit collector.
            model = FakeModel([FakeResult("cap",16384), FakeResult("left"), RuntimeError("right failed")])
            def capture(event_type, **payload):
                events.append((event_type,payload))
            mlx_runner.emit = capture
            try:
                with self.assertRaises(RuntimeError):
                    mlx_runner.transcribe_v2(request={"audioPath":str(f.audio)}, block=f.request_block(),
                        model=model, generation_arguments={"max_tokens":16384}, sample_rate=SAMPLE_RATE,
                        maximum_tokens=16384, min_split_seconds=30, audio=FakeAudio(0,ROOT_END),
                        prompt="", terms=[], output=f.root/"out.txt", started=0)
            finally:
                mlx_runner.emit = original
            self.assertTrue(any("token 遞迴切點" in e[1].get("message","") for e in events))
            left = [n for n in f.read_state()["nodes"] if n["state"] == "completed"][0]
            resumed = FakeModel([FakeResult("right")])
            self.run_v2(f,resumed)
            self.assertEqual(resumed.spans, [(63*SAMPLE_RATE, ROOT_END-63*SAMPLE_RATE)])
            self.assertEqual([n for n in f.read_state()["nodes"] if n["nodeID"] == left["nodeID"]][0], left)


class RenderV2Tests(unittest.TestCase):
    step = 600 * SAMPLE_RATE

    def leaf(self, start: int, end: int, text: str, state: str = cp.STATE_COMPLETED):
        return {
            "startSample": start,
            "endSample": end,
            "state": state,
            "result": {"text": text, "gapReason": None},
        }

    def groups(self) -> list:
        return [
            {
                "groupID": f"group-{i}",
                "startSample": i * self.step,
                "endSample": (i + 1) * self.step,
            }
            for i in range(2)
        ]

    def test_sections_follow_the_manifest_groups_not_leaf_indices(self):
        leaves = [
            self.leaf(0, self.step, "第一節"),
            self.leaf(self.step, self.step + 120 * SAMPLE_RATE, "第二節"),
            self.leaf(
                self.step + 120 * SAMPLE_RATE,
                self.step + 240 * SAMPLE_RATE,
                "",
                state=cp.STATE_GAP,
            ),
            self.leaf(self.step + 240 * SAMPLE_RATE, 2 * self.step, "第三節"),
        ]
        text = mlx_runner.render_timed_transcript_v2(
            leaves,
            display_groups=self.groups(),
            sample_rate=SAMPLE_RATE,
        )
        self.assertIn("[00:00:00 - 00:10:00]", text)
        self.assertIn("[00:10:00 - 00:20:00]", text)
        for expected in ("第一節", "第二節", "第三節"):
            self.assertIn(expected, text)

    def test_a_gap_renders_from_its_own_span(self):
        leaves = [
            self.leaf(0, self.step, "第一節"),
            self.leaf(
                self.step, self.step + 120 * SAMPLE_RATE, "", state=cp.STATE_GAP
            ),
        ]
        text = mlx_runner.render_timed_transcript_v2(
            leaves,
            display_groups=self.groups(),
            sample_rate=SAMPLE_RATE,
        )
        self.assertIn("【此處約缺少 120 秒", text)

    def test_a_sliced_job_reads_mid_recording_without_any_offset(self):
        """Absolute coordinates already carry the slice origin.

        A slice starting at 1800 s must render 00:30:00 headings with no offset
        parameter anywhere; adding one would double-count the slice start.
        """
        origin = 1800 * SAMPLE_RATE
        groups = [
            {
                "groupID": "group-slice",
                "startSample": origin,
                "endSample": origin + self.step,
            }
        ]
        text = mlx_runner.render_timed_transcript_v2(
            [self.leaf(origin, origin + self.step, "第一節")],
            display_groups=groups,
            sample_rate=SAMPLE_RATE,
        )
        self.assertIn("[00:30:00 - 00:40:00]", text)

    def test_an_empty_group_produces_no_heading(self):
        text = mlx_runner.render_timed_transcript_v2(
            [self.leaf(0, self.step, "第一節")],
            display_groups=self.groups(),
            sample_rate=SAMPLE_RATE,
        )
        self.assertEqual(text.count("["), 1)
        self.assertNotIn("[00:10:00", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
