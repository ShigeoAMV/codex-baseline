#!/usr/bin/env python3
"""Build deterministic, payload-only codex-baseline self-update assets."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
import tempfile
import zipfile


CONTRACT = "codex-baseline-update/v1"
PREVIEW_CONTRACT = "codex-baseline-update-preview/v1"
PROMOTION_CONTRACT = "codex-baseline-promotion/v2"
RUNNER_ATTESTATION_CONTRACT = "codex-baseline-runner-attestation/v1"
REPOSITORY = "ShigeoAMV/codex-baseline"
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_CONTENT_BYTES = 128 * 1024 * 1024
MAX_ENTRIES = 512
MAX_DEPTH = 8
MAX_PATH_BYTES = 240
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
WINDOWS_DEVICE_RE = re.compile(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$", re.IGNORECASE)
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
PROMOTION_ALLOWED_CHANGES = {"baseline/manifest.json", "baseline/release-status.json"}
PROMOTION_GATE_FIELDS = {
    "execution_success", "run_parity", "source_provenance", "release_status",
    "profile_provenance", "authority_safety_scope", "quality", "first_pass",
    "positive_speed", "six_lane", "six_lane_capacity", "serial_selection",
    "swarm_value", "non_dominated", "hygiene",
}
EVIDENCE_FILES = {
    "benchmark_summary_file": ("summary.json", 8 * 1024 * 1024),
    "benchmark_run_file": ("run.json", 1024 * 1024),
    "benchmark_results_file": ("results.jsonl", 256 * 1024 * 1024),
    "benchmark_manifest_file": ("benchmark-manifest.json", 2 * 1024 * 1024),
    "runner_attestation_file": ("runner-attestation.json", 64 * 1024),
}
LIVE_RUN_FIELDS = {
    "schema", "contract", "platform", "mode", "status", "isolation", "model_invoked",
    "verifiers_executed", "created", "codex", "model", "source_revision", "source_dirty",
    "source_hash", "manifest_hash", "codex_binary_hash", "codex_identity", "node_binary_hash",
    "auth", "account_service_tier", "runtime_telemetry_adapter_contract",
    "runtime_telemetry_adapter_hash", "resource_profile",
}
RESULT_FIELDS = {
    "schema", "task", "class", "parallelism_class", "expected_lanes", "arm", "arm_order_position",
    "cache_state", "repetition", "pass", "first_pass", "first_pass_verification",
    "first_pass_provenance", "user_interventions", "user_interventions_verification",
    "user_interventions_provenance", "safety_violation", "safety_verification", "safety_provenance",
    "authority_violation", "authority_verification", "authority_provenance", "scope_violation",
    "scope_verification", "scope_provenance", "process_exit", "verifier_exit", "elapsed_ms", "turns",
    "commands", "file_changes", "changed_files", "unnecessary_files", "changed_paths",
    "unnecessary_paths", "failed_command_events", "raw_subagent_events", "input_tokens",
    "cached_input_tokens", "output_tokens", "reasoning_tokens", "usage_scope", "cost_usd",
    "baseline_layer_bytes", "retry_count", "review_findings", "release_version", "payload_hash",
    "last_message_bytes", "added_lines", "added_code_lines", "added_comment_lines",
    "added_prose_lines", "added_blank_lines", "duplicate_added_lines", "pure_comment_diff",
    "hygiene_verification", "hygiene_provenance",
    "evaluation_profile", "evaluation_profile_hash", "auto_overlay_hash", "agent_guidance_hash",
    "configured_agent_cap", "orchestration", "isolation", "source_hash", "layer_hash",
    "arm_config_hash", "fixture_hash", "prompt_hash", "verifier_hash",
}
ORCHESTRATION_FIELDS = {
    "execution", "selection_reason", "planned_lane_ids", "planned_fanout", "actual_fanout",
    "available_capacity", "agents", "depth_intended", "depth_observed", "depth_verification",
    "waves_planned", "waves_observed", "waves_verification", "peak_concurrency",
    "peak_concurrency_verification", "spawn_errors", "fallbacks", "interrupts", "timeouts",
    "conflicts", "integration_rework_events", "handoff_bytes", "duplicated_context_bytes",
    "write_isolation", "test_isolation", "parent_before", "parent_after",
    "parent_settings_verification", "telemetry_verification", "telemetry_adapter_hash",
    "telemetry_provenance",
}
AGENT_FIELDS = {
    "id", "lane_id", "requested_model", "actual_model", "requested_effort", "actual_effort", "status",
}


@dataclass(frozen=True)
class PinnedExecutable:
    path: Path
    digest: str
    identity: tuple[int, int, int, int, int, int]
    label: str


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"release-update: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bytes_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def capture_pinned_executable(path: Path | None, expected_hash: str | None, label: str) -> PinnedExecutable:
    if path is None or expected_hash is None:
        fail(f"stable promotion requires absolute --{label}-binary and --{label}-sha256 pins")
    if not path.is_absolute() or not HASH_RE.fullmatch(expected_hash):
        fail(f"stable promotion {label} pin must be an absolute path and lowercase SHA-256")
    absolute = Path(os.path.abspath(path))
    data = read_safe_file(absolute, f"pinned {label} executable", MAX_CONTENT_BYTES)
    info = absolute.lstat()
    if os.name != "nt" and not info.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
        fail(f"pinned {label} executable is not executable")
    actual_hash = bytes_sha256(data)
    if actual_hash != expected_hash:
        fail(f"pinned {label} executable SHA-256 mismatch")
    identity = (
        info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
        stat.S_IMODE(info.st_mode),
    )
    return PinnedExecutable(absolute, actual_hash, identity, label)


def reverify_pinned_executable(executable: PinnedExecutable) -> None:
    data = read_safe_file(
        executable.path, f"pinned {executable.label} executable", MAX_CONTENT_BYTES,
    )
    info = executable.path.lstat()
    identity = (
        info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
        stat.S_IMODE(info.st_mode),
    )
    if identity != executable.identity or bytes_sha256(data) != executable.digest:
        fail(f"pinned {executable.label} executable changed after validation")


def assert_no_link_ancestors(path: Path, label: str) -> None:
    absolute = Path(os.path.abspath(path))
    for candidate in (absolute, *absolute.parents):
        try:
            info = candidate.lstat()
        except OSError as exc:
            fail(f"cannot inspect {label} path: {exc}")
        reparse = bool(
            os.name == "nt"
            and getattr(info, "st_file_attributes", 0)
            & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        )
        if stat.S_ISLNK(info.st_mode) or reparse:
            fail(f"{label} path has a symbolic-link or reparse-point ancestor")


def read_safe_file(path: Path, label: str, maximum: int) -> bytes:
    """Capture one bounded, ordinary, single-link file without following links."""
    absolute = Path(os.path.abspath(path))
    assert_no_link_ancestors(absolute, label)
    try:
        before = absolute.lstat()
    except OSError as exc:
        fail(f"cannot inspect {label}: {exc}")
    reparse = bool(
        os.name == "nt"
        and getattr(before, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    )
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or reparse:
        fail(f"{label} is missing, linked, or special")
    if before.st_size > maximum:
        fail(f"{label} exceeds {maximum} bytes")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(absolute, flags)
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_nlink != 1
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            ):
                fail(f"{label} changed while opening")
            chunks = []
            remaining = maximum + 1
            while remaining:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError as exc:
        fail(f"cannot read {label}: {exc}")
    if len(data) > maximum:
        fail(f"{label} exceeds {maximum} bytes")
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        or len(data) != before.st_size
    ):
        fail(f"{label} changed while reading")
    return data


def load_json_object(data: bytes, label: str) -> dict:
    def unique_object(pairs: list[tuple[str, object]]) -> dict:
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON key: {key}")
            value[key] = item
        return value

    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError, ValueError) as exc:
        fail(f"cannot parse {label}: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def validate_results_shape(data: bytes) -> None:
    if not data.endswith(b"\n"):
        fail("benchmark results must end with a newline")
    lines = data.splitlines()
    if not lines or len(lines) > 10000 or any(not line for line in lines):
        fail("benchmark results line inventory is invalid")
    for index, line in enumerate(lines, 1):
        result = load_json_object(line, f"benchmark result line {index}")
        if set(result) != RESULT_FIELDS:
            fail(f"benchmark result line {index} field inventory is invalid")
        orchestration = result.get("orchestration")
        if not isinstance(orchestration, dict) or set(orchestration) != ORCHESTRATION_FIELDS:
            fail(f"benchmark result line {index} orchestration inventory is invalid")
        for setting in ("parent_before", "parent_after"):
            value = orchestration.get(setting)
            if not isinstance(value, dict) or set(value) != {"model", "effort", "speed"}:
                fail(f"benchmark result line {index} parent settings inventory is invalid")
        agents = orchestration.get("agents")
        if agents is not None and (
            not isinstance(agents, list)
            or any(not isinstance(agent, dict) or set(agent) != AGENT_FIELDS for agent in agents)
        ):
            fail(f"benchmark result line {index} child inventory is invalid")


def git_completed(
    source: Path, git_executable: PinnedExecutable, *arguments: str,
) -> subprocess.CompletedProcess:
    environment = {
        name: os.environ[name]
        for name in ("SYSTEMROOT", "WINDIR", "TEMP", "TMP", "TMPDIR")
        if name in os.environ
    }
    environment.update({
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_PAGER": "cat",
        "PATH": str(git_executable.path.parent),
        "LC_ALL": "C",
    })
    reverify_pinned_executable(git_executable)
    command = [
        str(git_executable.path), "--no-replace-objects", "--no-optional-locks",
        "-C", str(source), "-c", "core.fsmonitor=false", "-c", "core.pager=cat",
        "-c", "pager.branch=false", "-c", "pager.diff=false", "-c", "pager.log=false",
        "-c", "diff.external=", "-c", "diff.trustExitCode=false",
        "-c", f"core.attributesFile={os.devnull}", "-c", f"core.hooksPath={os.devnull}",
        *arguments,
    ]
    try:
        completed = subprocess.run(
            command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=60, env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        fail(f"cannot inspect promotion Git state: {exc}")
    reverify_pinned_executable(git_executable)
    return completed


def git(
    source: Path, git_executable: PinnedExecutable, *arguments: str,
    binary: bool = False, check: bool = True,
) -> bytes | str:
    completed = git_completed(source, git_executable, *arguments)
    if check and completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        fail(f"promotion Git check failed: {detail or arguments[0]}")
    return completed.stdout if binary else completed.stdout.decode("utf-8", "strict")


def git_blob(
    source: Path, git_executable: PinnedExecutable, revision: str, relative: str,
    maximum: int = MAX_CONTENT_BYTES,
) -> bytes:
    validate_member_path(relative)
    object_name = f"{revision}:{relative}"
    size_text = git(source, git_executable, "cat-file", "-s", object_name)
    try:
        size = int(str(size_text).strip())
    except ValueError:
        fail(f"candidate Git blob size is invalid: {relative}")
    if size < 0 or size > maximum:
        fail(f"candidate Git blob exceeds {maximum} bytes: {relative}")
    data = git(source, git_executable, "cat-file", "blob", object_name, binary=True)
    if len(data) != size:
        fail(f"candidate Git blob changed while reading: {relative}")
    return data


def load_git_payload(
    source: Path, git_executable: PinnedExecutable, revision: str,
) -> tuple[str, str, str, dict[str, bytes]]:
    manifest_bytes = git_blob(
        source, git_executable, revision, "baseline/manifest.json", 8 * 1024 * 1024,
    )
    version_bytes = git_blob(source, git_executable, revision, "VERSION", 128)
    manifest = load_json_object(manifest_bytes, "candidate manifest")
    version = manifest.get("version")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        fail("candidate manifest version is invalid")
    try:
        version_file = version_bytes.decode("ascii").strip()
    except UnicodeError as exc:
        fail(f"candidate VERSION is invalid: {exc}")
    if version_file != version or manifest.get("source_trust") != "unsigned-local-source":
        fail("candidate VERSION, manifest, or source-trust is inconsistent")
    entries = manifest.get("payload")
    if not isinstance(entries, list) or not entries:
        fail("candidate manifest payload must be a non-empty array")
    captured = {"baseline/manifest.json": manifest_bytes}
    canonical = []
    seen = {"baseline/manifest.json"}
    folded = {"baseline/manifest.json"}
    total = len(manifest_bytes)
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "bytes", "sha256"}:
            fail("candidate manifest contains a malformed payload entry")
        relative = entry["path"]
        if not isinstance(relative, str):
            fail("candidate manifest payload path is not a string")
        validate_member_path(relative)
        if relative in seen or relative.casefold() in folded:
            fail(f"candidate manifest contains a duplicate or case-colliding path: {relative}")
        seen.add(relative)
        folded.add(relative.casefold())
        data = git_blob(source, git_executable, revision, relative)
        if type(entry["bytes"]) is not int or entry["bytes"] != len(data):
            fail(f"candidate payload byte length mismatch: {relative}")
        digest = bytes_sha256(data)
        if entry["sha256"] != digest:
            fail(f"candidate payload SHA-256 mismatch: {relative}")
        canonical.append(f"{relative}\t{len(data)}\t{digest}\n")
        captured[relative] = data
        total += len(data)
    payload_hash = bytes_sha256("".join(sorted(canonical)).encode("utf-8"))
    if manifest.get("payload_hash") != payload_hash:
        fail("candidate manifest aggregate payload hash mismatch")
    if len(captured) > MAX_ENTRIES or total > MAX_CONTENT_BYTES:
        fail("candidate payload exceeds release limits")
    try:
        release_record = load_json_object(captured["baseline/release-status.json"], "candidate release status")
    except KeyError:
        fail("candidate payload omits baseline/release-status.json")
    if set(release_record) != {"schema", "contract", "status"} or (
        type(release_record.get("schema")) is not int
        or release_record["schema"] != 1
        or release_record.get("contract") != "codex-baseline-release-status/v1"
        or not isinstance(release_record.get("status"), str)
        or not re.fullmatch(r"rc\.[1-9][0-9]*", release_record["status"])
    ):
        fail("candidate release status must be rc.N")
    return version, release_record["status"], payload_hash, captured


def validate_deterministic_manifest_transition(candidate: bytes, stable: bytes) -> None:
    candidate_manifest = load_json_object(candidate, "candidate manifest transition")
    stable_manifest = load_json_object(stable, "stable manifest transition")
    if set(candidate_manifest) != set(stable_manifest):
        fail("RC-to-stable manifest field inventory changed")
    for key in candidate_manifest:
        if key not in {"payload", "payload_hash"} and candidate_manifest[key] != stable_manifest[key]:
            fail(f"RC-to-stable manifest changed non-promotion field: {key}")
    candidate_entries = candidate_manifest.get("payload")
    stable_entries = stable_manifest.get("payload")
    if not isinstance(candidate_entries, list) or not isinstance(stable_entries, list) or (
        len(candidate_entries) != len(stable_entries)
    ):
        fail("RC-to-stable manifest payload inventory changed")
    for candidate_entry, stable_entry in zip(candidate_entries, stable_entries):
        if not isinstance(candidate_entry, dict) or not isinstance(stable_entry, dict) or (
            candidate_entry.get("path") != stable_entry.get("path")
        ):
            fail("RC-to-stable manifest payload ordering changed")
        if candidate_entry.get("path") != "baseline/release-status.json" and candidate_entry != stable_entry:
            fail(f"RC-to-stable manifest changed unrelated payload metadata: {candidate_entry.get('path')}")


def validate_member_path(path: str) -> None:
    parts = PurePosixPath(path).parts
    if (
        not PATH_RE.fullmatch(path)
        or path.startswith("/")
        or path.endswith("/")
        or "//" in path
        or any(part in {"", ".", ".."} for part in parts)
    ):
        fail(f"unsafe payload path: {path}")
    if len(path.encode("ascii")) > MAX_PATH_BYTES:
        fail(f"payload path exceeds {MAX_PATH_BYTES} bytes: {path}")
    if len(parts) > MAX_DEPTH:
        fail(f"payload path exceeds {MAX_DEPTH} components: {path}")
    for part in parts:
        if part.lower() == ".git":
            fail(f"Git metadata is forbidden in update assets: {path}")
        if part.endswith((".", " ")) or WINDOWS_DEVICE_RE.fullmatch(part):
            fail(f"Windows-unsafe payload path: {path}")


def load_payload(source: Path) -> tuple[str, str, str, dict[str, bytes]]:
    manifest_path = source / "baseline" / "manifest.json"
    version_path = source / "VERSION"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        fail("source manifest is missing, linked, or special")
    if version_path.is_symlink() or not version_path.is_file():
        fail("VERSION is missing, linked, or special")
    try:
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot read source manifest: {exc}")
    version = manifest.get("version")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        fail("manifest version must be stable MAJOR.MINOR.PATCH")
    try:
        version_file = version_path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as exc:
        fail(f"cannot read VERSION: {exc}")
    if version_file != version:
        fail("VERSION and manifest version disagree")
    if manifest.get("source_trust") != "unsigned-local-source":
        fail("unsupported manifest source trust")
    payload = manifest.get("payload")
    if not isinstance(payload, list) or not payload:
        fail("manifest payload must be a non-empty array")

    captured = {"baseline/manifest.json": manifest_bytes}
    seen = {"baseline/manifest.json"}
    seen_casefolded = {"baseline/manifest.json"}
    canonical_payload = []
    total = len(manifest_bytes)
    for entry in payload:
        if not isinstance(entry, dict) or set(entry) != {"path", "bytes", "sha256"}:
            fail("manifest contains a malformed payload entry")
        relative = entry["path"]
        if not isinstance(relative, str):
            fail("manifest payload path is not a string")
        validate_member_path(relative)
        if relative in seen:
            fail(f"duplicate payload path: {relative}")
        seen.add(relative)
        folded = relative.casefold()
        if folded in seen_casefolded:
            fail(f"case-colliding payload path: {relative}")
        seen_casefolded.add(folded)
        path = source / PurePosixPath(relative)
        if path.is_symlink() or not path.is_file():
            fail(f"payload file is missing, linked, or special: {relative}")
        try:
            data = path.read_bytes()
        except OSError as exc:
            fail(f"cannot capture payload file {relative}: {exc}")
        data_size = len(data)
        if type(entry["bytes"]) is not int or entry["bytes"] != data_size:
            fail(f"payload byte length mismatch: {relative}")
        if not isinstance(entry["sha256"], str) or entry["sha256"] != hashlib.sha256(data).hexdigest():
            fail(f"payload SHA-256 mismatch: {relative}")
        canonical_payload.append(f'{relative}\t{data_size}\t{entry["sha256"]}\n')
        total += data_size
        captured[relative] = data

    computed_payload_hash = hashlib.sha256("".join(sorted(canonical_payload)).encode("utf-8")).hexdigest()
    if manifest.get("payload_hash") != computed_payload_hash:
        fail("manifest aggregate payload hash mismatch")

    try:
        release_record = json.loads(captured["baseline/release-status.json"].decode("utf-8"))
    except (KeyError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot read payload release status: {exc}")
    if (
        not isinstance(release_record, dict)
        or set(release_record) != {"schema", "contract", "status"}
        or type(release_record["schema"]) is not int
        or release_record["schema"] != 1
        or release_record["contract"] != "codex-baseline-release-status/v1"
    ):
        fail("payload release-status contract is invalid")
    release_status = release_record["status"]
    if release_status != "stable" and not (
        isinstance(release_status, str) and re.fullmatch(r"rc\.[1-9][0-9]*", release_status)
    ):
        fail("payload release status must be stable or rc.N")

    if len(captured) > MAX_ENTRIES:
        fail(f"payload exceeds {MAX_ENTRIES} files")
    if total > MAX_CONTENT_BYTES:
        fail(f"payload exceeds {MAX_CONTENT_BYTES} uncompressed bytes")
    return version, release_status, computed_payload_hash, {path: captured[path] for path in sorted(captured)}


def assert_safe_git_configuration(source: Path, git_executable: PinnedExecutable) -> None:
    completed = git_completed(
        source, git_executable, "config", "--local", "--name-only", "--get-regexp",
        r"^(filter\..*\.(process|clean|smudge|required)|diff\..*\.(command|textconv))$",
    )
    if completed.returncode not in {0, 1}:
        fail("cannot validate local Git process-filter configuration")
    if completed.returncode == 0 and completed.stdout.strip():
        fail("stable promotion rejects local Git process-filter or diff-driver configuration")


def current_clean_revision(
    source: Path, git_executable: PinnedExecutable, expected: str | None = None,
) -> str:
    assert_safe_git_configuration(source, git_executable)
    top = Path(str(git(source, git_executable, "rev-parse", "--show-toplevel")).strip()).resolve()
    if top != source.resolve():
        fail("stable source must be the root of its Git worktree")
    revision = str(git(source, git_executable, "rev-parse", "--verify", "HEAD^{commit}")).strip()
    if not REVISION_RE.fullmatch(revision):
        fail("stable source HEAD is not a 40-hex commit")
    if expected is not None and revision != expected:
        fail("stable source HEAD changed after promotion validation")
    if str(git(source, git_executable, "rev-parse", "--show-object-format")).strip() != "sha1":
        fail("stable promotion currently requires a SHA-1-format Git repository")
    tree = git(
        source, git_executable, "ls-tree", "-r", "-z", "--full-tree", "HEAD", binary=True,
    )
    entries = [entry for entry in tree.split(b"\0") if entry]
    if not entries or len(entries) > 20000:
        fail("stable source tracked-file inventory is invalid")
    total = 0
    for entry in entries:
        try:
            header, encoded_path = entry.split(b"\t", 1)
            mode, kind, object_id = header.decode("ascii").split(" ")
            relative = encoded_path.decode("utf-8")
        except (ValueError, UnicodeError):
            fail("stable source Git tree inventory is malformed")
        parts = PurePosixPath(relative).parts
        if kind != "blob" or mode not in {"100644", "100755"} or not re.fullmatch(r"[0-9a-f]{40}", object_id):
            fail(f"unsupported stable source Git object: {relative}")
        if relative.startswith("/") or any(part in {"", ".", ".."} for part in parts):
            fail("stable source Git path is unsafe")
        path = source / PurePosixPath(relative)
        data = read_safe_file(path, f"stable source file {relative}", MAX_CONTENT_BYTES)
        total += len(data)
        if total > 1024 * 1024 * 1024:
            fail("stable source exceeds the 1 GiB promotion limit")
        blob = b"blob " + str(len(data)).encode("ascii") + b"\0" + data
        if hashlib.sha1(blob, usedforsecurity=False).hexdigest() != object_id:
            fail(f"stable source differs from HEAD: {relative}")
        if os.name != "nt":
            executable = bool(path.stat().st_mode & stat.S_IXUSR)
            if executable != (mode == "100755"):
                fail(f"stable source executable mode differs from HEAD: {relative}")
    untracked = git(
        source, git_executable, "ls-files", "--others", "--exclude-standard", "-z", binary=True,
    )
    if untracked:
        fail("stable source worktree is not clean")
    return revision


def validate_summary_gates(summary: dict) -> None:
    expected = {
        "schema", "contract", "runs", "task_repetitions", "provenance", "by_arm",
        "by_cache_state", "comparisons", "by_task", "gates", "limitations",
    }
    if set(summary) != expected or summary.get("schema") != 2 or (
        summary.get("contract") != "codex-baseline-benchmark-summary/v2"
    ):
        fail("benchmark summary field inventory or contract is invalid")
    gates = summary.get("gates")
    if not isinstance(gates, dict) or gates.get("status") != "passed" or gates.get("promotion_allowed") is not True:
        fail("benchmark summary does not permit promotion")
    if any(gates.get(field) != "passed" for field in PROMOTION_GATE_FIELDS):
        fail("one or more mandatory benchmark promotion gates did not pass")
    if gates.get("host_evidence") != "verified" or gates.get("telemetry") != "verified" or gates.get("reasons") != []:
        fail("benchmark summary lacks verified host/telemetry evidence or has unresolved reasons")


def run_summarizer(
    node_executable: PinnedExecutable,
    summarizer_bytes: bytes,
    results: bytes,
    run: bytes,
    manifest: bytes,
) -> dict:
    with tempfile.TemporaryDirectory(prefix="codex-baseline-promotion-") as temporary:
        root = Path(temporary)
        summarizer = root / "summarize.mjs"
        paths = {
            "results": root / "results.jsonl",
            "run": root / "run.json",
            "manifest": root / "manifest.json",
        }
        summarizer.write_bytes(summarizer_bytes)
        paths["results"].write_bytes(results)
        paths["run"].write_bytes(run)
        paths["manifest"].write_bytes(manifest)
        try:
            reverify_pinned_executable(node_executable)
            completed = subprocess.run(
                [str(node_executable.path), str(summarizer), str(paths["results"]),
                 str(paths["run"]), str(paths["manifest"])],
                check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
                env={"PATH": str(node_executable.path.parent), "LC_ALL": "C"}, cwd=temporary,
            )
            reverify_pinned_executable(node_executable)
        except (OSError, subprocess.TimeoutExpired) as exc:
            fail(f"cannot recompute benchmark summary: {exc}")
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        fail(f"benchmark evidence recomputation failed: {detail or 'summarizer exited nonzero'}")
    if len(completed.stdout) > 8 * 1024 * 1024:
        fail("recomputed benchmark summary exceeds 8388608 bytes")
    return load_json_object(completed.stdout, "recomputed benchmark summary")


def validate_promotion_receipt(
    path: Path | None,
    source: Path,
    version: str,
    stable_payload_hash: str,
    stable_payload: dict[str, bytes],
    git_executable: PinnedExecutable,
    node_executable: PinnedExecutable,
) -> str:
    if path is None:
        fail("stable artifacts require --promotion-receipt")
    path = Path(os.path.abspath(path))
    receipt_bytes = read_safe_file(path, "promotion receipt", 65536)
    receipt = load_json_object(receipt_bytes, "promotion receipt")
    expected = {
        "schema", "contract", "version", "candidate_status", "promotion_allowed",
        "candidate_source_revision", "candidate_source_dirty", "candidate_source_hash",
        "candidate_payload_hash", "benchmark_summary_file", "benchmark_summary_hash",
        "benchmark_run_file", "benchmark_run_hash", "benchmark_results_file",
        "benchmark_results_hash", "benchmark_manifest_file", "benchmark_manifest_hash",
        "runner_attestation_file", "runner_attestation_hash",
        "stable_source_revision", "stable_payload_hash",
    }
    if not isinstance(receipt, dict) or set(receipt) != expected:
        fail("promotion receipt field inventory is invalid")
    if (
        type(receipt["schema"]) is not int or receipt["schema"] != 2
        or receipt["contract"] != PROMOTION_CONTRACT
        or receipt["version"] != version
        or not isinstance(receipt["candidate_status"], str)
        or not re.fullmatch(r"rc\.[1-9][0-9]*", receipt["candidate_status"])
        or receipt["promotion_allowed"] is not True
        or receipt["candidate_source_dirty"] is not False
        or not REVISION_RE.fullmatch(str(receipt["candidate_source_revision"]))
        or not REVISION_RE.fullmatch(str(receipt["stable_source_revision"]))
        or any(not HASH_RE.fullmatch(str(receipt[field])) for field in (
            "candidate_source_hash", "candidate_payload_hash", "benchmark_summary_hash",
            "benchmark_run_hash", "benchmark_results_hash", "benchmark_manifest_hash",
            "runner_attestation_hash",
            "stable_payload_hash",
        ))
        or receipt["stable_payload_hash"] != stable_payload_hash
    ):
        fail("promotion receipt is not a clean, evidence-bound receipt for this payload")

    stable_revision = current_clean_revision(source, git_executable)
    if receipt["stable_source_revision"] != stable_revision:
        fail("promotion receipt is not bound to the current stable HEAD")
    candidate_revision = receipt["candidate_source_revision"]
    resolved_candidate = str(git(
        source, git_executable, "rev-parse", "--verify", f"{candidate_revision}^{{commit}}",
    )).strip()
    if resolved_candidate != candidate_revision:
        fail("candidate source revision does not resolve to the named commit")
    ancestor = git_completed(
        source, git_executable, "merge-base", "--is-ancestor", candidate_revision, stable_revision,
    )
    if ancestor.returncode != 0:
        fail("candidate source revision is not an ancestor of stable HEAD")
    stable_commit = str(git(
        source, git_executable, "rev-list", "--parents", "-n", "1", stable_revision,
    )).split()
    if stable_commit != [stable_revision, candidate_revision]:
        fail("stable HEAD must be a direct, single-parent descendant of the candidate")
    changed = git(
        source, git_executable, "diff-tree", "--no-ext-diff", "--no-commit-id", "--name-only",
        "--no-renames", "-r", "-z",
        candidate_revision, stable_revision, binary=True,
    )
    changed_paths = {item.decode("utf-8", "strict") for item in changed.split(b"\0") if item}
    if changed_paths != PROMOTION_ALLOWED_CHANGES:
        fail("RC-to-stable commits differ outside release status and deterministic manifest")

    candidate_version, candidate_status, candidate_payload_hash, candidate_payload = load_git_payload(
        source, git_executable, candidate_revision,
    )
    if (
        candidate_version != version
        or candidate_status != receipt["candidate_status"]
        or candidate_payload_hash != receipt["candidate_payload_hash"]
        or set(candidate_payload) != set(stable_payload)
    ):
        fail("candidate and stable payload identities are inconsistent")
    for relative in stable_payload:
        if relative not in PROMOTION_ALLOWED_CHANGES and candidate_payload[relative] != stable_payload[relative]:
            fail(f"candidate and stable payload bytes differ: {relative}")
    validate_deterministic_manifest_transition(
        candidate_payload["baseline/manifest.json"], stable_payload["baseline/manifest.json"],
    )

    evidence = {}
    for field, (required_name, maximum) in EVIDENCE_FILES.items():
        if receipt[field] != required_name:
            fail(f"promotion receipt must name exact evidence file {required_name}")
        evidence[field] = read_safe_file(path.parent / required_name, required_name, maximum)
    hash_fields = {
        "benchmark_summary_file": "benchmark_summary_hash",
        "benchmark_run_file": "benchmark_run_hash",
        "benchmark_results_file": "benchmark_results_hash",
        "benchmark_manifest_file": "benchmark_manifest_hash",
        "runner_attestation_file": "runner_attestation_hash",
    }
    for file_field, hash_field in hash_fields.items():
        if bytes_sha256(evidence[file_field]) != receipt[hash_field]:
            fail(f"promotion evidence hash mismatch: {receipt[file_field]}")

    candidate_benchmark_manifest = git_blob(
        source, git_executable, candidate_revision, "benchmarks/manifest.json", 2 * 1024 * 1024,
    )
    candidate_summarizer = git_blob(
        source, git_executable, candidate_revision, "benchmarks/summarize.mjs", 2 * 1024 * 1024,
    )
    if evidence["benchmark_manifest_file"] != candidate_benchmark_manifest:
        fail("benchmark manifest evidence is not the candidate revision manifest")

    run = load_json_object(evidence["benchmark_run_file"], "benchmark run receipt")
    if (
        set(run) != LIVE_RUN_FIELDS
        or run.get("schema") != 2
        or run.get("contract") != "codex-baseline-benchmark/v2"
        or run.get("mode") != "live-paired"
        or run.get("status") != "completed"
        or run.get("source_revision") != candidate_revision
        or run.get("source_dirty") is not False
        or run.get("source_hash") != receipt["candidate_source_hash"]
        or run.get("manifest_hash") != receipt["benchmark_manifest_hash"]
        or run.get("node_binary_hash") != node_executable.digest
        or any(not HASH_RE.fullmatch(str(run.get(field))) for field in (
            "codex_binary_hash", "node_binary_hash", "runtime_telemetry_adapter_hash",
        ))
        or run.get("runtime_telemetry_adapter_contract") != "codex-runtime-telemetry/v1"
    ):
        fail("benchmark run receipt is not completed and bound to the clean candidate")

    validate_results_shape(evidence["benchmark_results_file"])
    verifier_hashes = sorted({
        load_json_object(line, "benchmark result verifier identity")["verifier_hash"]
        for line in evidence["benchmark_results_file"].splitlines()
    })
    if not verifier_hashes or any(not HASH_RE.fullmatch(str(value)) for value in verifier_hashes):
        fail("benchmark result verifier identities are invalid")

    summary = load_json_object(evidence["benchmark_summary_file"], "benchmark summary")
    recomputed = run_summarizer(
        node_executable,
        candidate_summarizer,
        evidence["benchmark_results_file"],
        evidence["benchmark_run_file"],
        evidence["benchmark_manifest_file"],
    )
    if recomputed != summary:
        fail("benchmark summary does not equal a fresh recomputation over the bound evidence")
    validate_summary_gates(summary)
    provenance = summary.get("provenance")
    expected_provenance = {
        "source_revision": candidate_revision,
        "source_dirty": False,
        "source_hash": receipt["candidate_source_hash"],
        "version": version,
        "candidate_status": candidate_status,
        "payload_hash": candidate_payload_hash,
        "run_receipt_hash": receipt["benchmark_run_hash"],
        "run_receipt_status": "completed",
        "manifest_hash": receipt["benchmark_manifest_hash"],
        "result_set_hash": receipt["benchmark_results_hash"],
        "release_status": candidate_status,
        "promotion_target": f"stable-{version}",
        "clean_revision_verified": True,
        "manifest_bound": True,
    }
    if provenance != expected_provenance:
        fail("benchmark summary provenance is not exactly bound to candidate evidence")

    attestation = load_json_object(evidence["runner_attestation_file"], "runner attestation")
    expected_attestation = {
        "schema", "contract", "candidate_source_revision", "candidate_source_hash",
        "benchmark_summary_hash", "benchmark_run_hash", "benchmark_results_hash",
        "benchmark_manifest_hash", "codex_binary_hash", "node_binary_hash",
        "runtime_telemetry_adapter_contract", "runtime_telemetry_adapter_hash",
        "verifier_hashes", "signing_key_id", "signature_algorithm", "signature",
    }
    if (
        set(attestation) != expected_attestation
        or attestation.get("schema") != 1
        or attestation.get("contract") != RUNNER_ATTESTATION_CONTRACT
        or attestation.get("candidate_source_revision") != candidate_revision
        or attestation.get("candidate_source_hash") != receipt["candidate_source_hash"]
        or attestation.get("benchmark_summary_hash") != receipt["benchmark_summary_hash"]
        or attestation.get("benchmark_run_hash") != receipt["benchmark_run_hash"]
        or attestation.get("benchmark_results_hash") != receipt["benchmark_results_hash"]
        or attestation.get("benchmark_manifest_hash") != receipt["benchmark_manifest_hash"]
        or attestation.get("codex_binary_hash") != run.get("codex_binary_hash")
        or attestation.get("node_binary_hash") != node_executable.digest
        or attestation.get("runtime_telemetry_adapter_contract")
            != run.get("runtime_telemetry_adapter_contract")
        or attestation.get("runtime_telemetry_adapter_hash")
            != run.get("runtime_telemetry_adapter_hash")
        or attestation.get("verifier_hashes") != verifier_hashes
        or not isinstance(attestation.get("signing_key_id"), str)
        or not attestation["signing_key_id"]
        or not isinstance(attestation.get("signature_algorithm"), str)
        or not attestation["signature_algorithm"]
        or not isinstance(attestation.get("signature"), str)
        or not attestation["signature"]
    ):
        fail("runner attestation is not exactly bound to candidate evidence and runtime identities")

    fail(
        "stable artifact generation is unavailable in this RC: no independently distributed "
        "runner-attestation trust root and verifier are implemented"
    )


def directory_members(prefix: str, paths: list[str]) -> list[str]:
    directories = {prefix}
    for relative in paths:
        parent = PurePosixPath(prefix, relative).parent
        while str(parent) != ".":
            directories.add(parent.as_posix())
            if parent.as_posix() == prefix:
                break
            parent = parent.parent
    return sorted(directories, key=lambda item: (len(PurePosixPath(item).parts), item))


def build_tar(destination: Path, prefix: str, payload: dict[str, bytes]) -> None:
    paths = list(payload)
    with destination.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for directory in directory_members(prefix, paths):
                    info = tarfile.TarInfo(directory)
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    archive.addfile(info)
                for relative in paths:
                    info = tarfile.TarInfo(PurePosixPath(prefix, relative).as_posix())
                    info.size = len(payload[relative])
                    info.mode = 0o755 if relative.endswith(".sh") else 0o644
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    archive.addfile(info, __import__("io").BytesIO(payload[relative]))


def zip_info(name: str, mode: int, is_directory: bool) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name + ("/" if is_directory else ""), (1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = ((stat.S_IFDIR if is_directory else stat.S_IFREG) | mode) << 16
    if is_directory:
        info.external_attr |= 0x10
    return info


def build_zip(destination: Path, prefix: str, payload: dict[str, bytes]) -> None:
    paths = list(payload)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for directory in directory_members(prefix, paths):
            archive.writestr(zip_info(directory, 0o755, True), b"")
        for relative in paths:
            mode = 0o755 if relative.endswith(".sh") else 0o644
            archive.writestr(
                zip_info(PurePosixPath(prefix, relative).as_posix(), mode, False),
                payload[relative],
            )


def atomic_build(
    source: Path,
    output: Path,
    promotion_receipt: Path | None,
    git_binary: Path | None = None,
    git_hash: str | None = None,
    node_binary: Path | None = None,
    node_hash: str | None = None,
) -> list[Path]:
    version, release_status, payload_hash, payload = load_payload(source)
    paths = list(payload)
    stable = release_status == "stable"
    stable_revision = None
    git_executable = None
    node_executable = None
    if stable:
        git_executable = capture_pinned_executable(git_binary, git_hash, "git")
        node_executable = capture_pinned_executable(node_binary, node_hash, "node")
        stable_revision = validate_promotion_receipt(
            promotion_receipt, source, version, payload_hash, payload,
            git_executable, node_executable,
        )
    elif promotion_receipt is not None:
        fail("an RC manifest cannot emit stable artifacts even with a promotion receipt")
    suffix = "" if stable else f"-{release_status}"
    prefix = f"codex-baseline-{version}"
    if len(directory_members(prefix, paths)) + len(paths) > MAX_ENTRIES:
        fail(f"release archive exceeds {MAX_ENTRIES} total entries")
    tar_name = f"{prefix}{suffix}.tar.gz"
    zip_name = f"{prefix}{suffix}.zip"
    descriptor_name = "codex-baseline-update-v1.txt" if stable else "codex-baseline-update-preview-v1.txt"
    output.mkdir(parents=True, exist_ok=True)
    if output.is_symlink() or not output.is_dir():
        fail(f"output is not an ordinary directory: {output}")

    with tempfile.TemporaryDirectory(prefix="codex-baseline-release-", dir=str(output)) as temporary:
        stage = Path(temporary)
        tar_path = stage / tar_name
        zip_path = stage / zip_name
        build_tar(tar_path, prefix, payload)
        build_zip(zip_path, prefix, payload)
        if tar_path.stat().st_size > MAX_ARCHIVE_BYTES or zip_path.stat().st_size > MAX_ARCHIVE_BYTES:
            fail(f"release archive exceeds {MAX_ARCHIVE_BYTES} bytes")
        descriptor = (
            f"contract={CONTRACT if stable else PREVIEW_CONTRACT}\n"
            f"version={version}\n"
            + ("" if stable else f"release_status={release_status}\n")
            + f"tag=v{version}{suffix}\n"
            f"trust={'unsigned-github-release' if stable else 'unsigned-local-preview'}\n"
            f"tar_name={tar_name}\n"
            f"tar_bytes={tar_path.stat().st_size}\n"
            f"tar_sha256={sha256(tar_path)}\n"
            f"zip_name={zip_name}\n"
            f"zip_bytes={zip_path.stat().st_size}\n"
            f"zip_sha256={sha256(zip_path)}\n"
        )
        descriptor_path = stage / descriptor_name
        descriptor_path.write_bytes(descriptor.encode("ascii"))
        if stable_revision is not None:
            if git_executable is None or node_executable is None:
                fail("stable promotion executable pins were lost")
            current_clean_revision(source, git_executable, stable_revision)
            reverify_pinned_executable(git_executable)
            reverify_pinned_executable(node_executable)
        produced = []
        for staged in (tar_path, zip_path, descriptor_path):
            final = output / staged.name
            os.replace(staged, final)
            produced.append(final)
    return produced


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="source tree (defaults to repository root)")
    parser.add_argument("--output", required=True, type=Path, help="artifact output directory")
    parser.add_argument("--promotion-receipt", type=Path, help="required for a stable manifest; binds clean promotion evidence to the payload")
    parser.add_argument("--git-binary", type=Path, help="absolute ordinary Git executable pin required for stable validation")
    parser.add_argument("--git-sha256", help="SHA-256 of --git-binary required for stable validation")
    parser.add_argument("--node-binary", type=Path, help="absolute ordinary Node executable pin required for stable validation")
    parser.add_argument("--node-sha256", help="SHA-256 of --node-binary required for stable validation")
    arguments = parser.parse_args()
    source = (arguments.source or Path(__file__).resolve().parent.parent).resolve()
    output = arguments.output.resolve()
    receipt = Path(os.path.abspath(arguments.promotion_receipt)) if arguments.promotion_receipt else None
    for artifact in atomic_build(
        source, output, receipt,
        arguments.git_binary, arguments.git_sha256,
        arguments.node_binary, arguments.node_sha256,
    ):
        print(f"{artifact.name}\t{artifact.stat().st_size}\t{sha256(artifact)}")


if __name__ == "__main__":
    main()
