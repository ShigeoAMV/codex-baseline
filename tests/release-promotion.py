#!/usr/bin/env python3
"""Focused tests for fail-closed RC-to-stable promotion and synthetic fixtures."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
RELEASE = ROOT / "scripts" / "release-update.py"
SUMMARIZER = ROOT / "benchmarks" / "summarize.mjs"
HASH = "1" * 64


def executable_pin(name: str) -> tuple[Path, str]:
    found = shutil.which(name)
    if found is None:
        raise SystemExit(f"release promotion tests require {name}")
    path = Path(found).resolve(strict=True)
    if name == "git" and os.name == "nt" and path.stat().st_nlink != 1:
        ordinary = path.parent.parent / "bin" / "git.exe"
        if ordinary.is_file() and ordinary.stat().st_nlink == 1:
            path = ordinary
    return path, digest(path.read_bytes())


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> bytes:
    data = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()
    path.write_bytes(data)
    return data


def write_release_status(path: Path, status: str) -> bytes:
    data = (json.dumps({
        "schema": 1,
        "contract": "codex-baseline-release-status/v1",
        "status": status,
    }, indent=2) + "\n").encode()
    path.write_bytes(data)
    return data


def git(repository: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repository), *arguments], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    return completed.stdout.strip()


def payload_manifest(version: str, status_bytes: bytes) -> dict:
    entry_hash = digest(status_bytes)
    canonical = f"baseline/release-status.json\t{len(status_bytes)}\t{entry_hash}\n".encode()
    return {
        "version": version,
        "source_trust": "unsigned-local-source",
        "payload_hash": digest(canonical),
        "payload": [{
            "path": "baseline/release-status.json",
            "bytes": len(status_bytes),
            "sha256": entry_hash,
        }],
    }


def refresh_payload_manifest(repository: Path) -> dict:
    path = repository / "baseline" / "manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8"))
    payload = []
    canonical = []
    for original in manifest["payload"]:
        relative = original["path"]
        data = (repository / relative).read_bytes()
        entry = {"path": relative, "bytes": len(data), "sha256": digest(data)}
        payload.append(entry)
        canonical.append(f"{relative}\t{len(data)}\t{entry['sha256']}\n")
    manifest["payload"] = payload
    manifest["payload_hash"] = digest("".join(sorted(canonical)).encode())
    if set(manifest) == {"version", "source_trust", "payload_hash", "payload"}:
        write_json(path, manifest)
        return manifest
    scalar_order = (
        "schema", "version", "minimum_codex", "tested_codex", "research_checked",
        "research_review_by", "encoding", "line_endings", "global_block",
        "source_trust", "payload_hash",
    )
    lines = ["{"]
    for key in scalar_order:
        lines.append(f'  {json.dumps(key)}: {json.dumps(manifest[key], ensure_ascii=True, separators=(",", ":"))},')
    lines.append('  "payload": [')
    for index, entry in enumerate(payload):
        comma = "," if index + 1 < len(payload) else ""
        lines.append(
            f'    {{"path": {json.dumps(entry["path"])}, "bytes": {entry["bytes"]}, '
            f'"sha256": {json.dumps(entry["sha256"])}}}{comma}'
        )
    lines.extend(("  ]", "}"))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return manifest


def profile_hash(profile: dict) -> str:
    return digest(json.dumps(profile, separators=(",", ":"), sort_keys=True).encode())


def orchestration(arm: str, lanes: int) -> dict:
    auto = arm.startswith("auto-")
    planned = lanes if auto else 0
    capacity = 6 if arm != "baseline-solo" else 0
    agents = [{
        "id": f"child-{index}", "lane_id": f"lane-{index}",
        "requested_model": "test-model", "actual_model": "test-model",
        "requested_effort": "medium", "actual_effort": "medium", "status": "completed",
    } for index in range(planned)]
    execution = "SOLO" if planned == 0 else "TEAM" if planned <= 3 else "SWARM"
    return {
        "execution": execution, "selection_reason": "fixture telemetry", "planned_fanout": planned,
        "actual_fanout": planned, "available_capacity": capacity,
        "planned_lane_ids": [f"lane-{index}" for index in range(planned)], "agents": agents,
        "depth_intended": 1, "depth_observed": 1 if planned else 0, "depth_verification": "verified",
        "waves_planned": 1 if planned else 0, "waves_observed": 1 if planned else 0,
        "waves_verification": "verified", "peak_concurrency": max(1, planned),
        "peak_concurrency_verification": "verified", "spawn_errors": [], "fallbacks": 0,
        "interrupts": 0, "timeouts": 0, "conflicts": 0, "integration_rework_events": 0,
        "handoff_bytes": 0, "duplicated_context_bytes": 0, "write_isolation": "single-writer",
        "test_isolation": "serial",
        "parent_before": {"model": "test-model", "effort": "medium", "speed": "standard"},
        "parent_after": {"model": "test-model", "effort": "medium", "speed": "standard"},
        "parent_settings_verification": "verified", "telemetry_verification": "verified",
        "telemetry_adapter_hash": HASH,
        "telemetry_provenance": f"runtime-telemetry-adapter-sha256:{HASH}",
    }


def make_benchmark_evidence(repository: Path, evidence: Path, revision: str, version: str, payload_hash: str) -> dict:
    node_path, node_hash = executable_pin("node")
    arms = ["vanilla", "baseline-solo", "auto-homogeneous", "auto-routed"]
    profiles = {
        "vanilla": {"guidance": "absent"},
        "baseline-solo": {"guidance": "installed", "cap": 0},
        "auto-homogeneous": {"guidance": "auto", "cap": 6},
        "auto-routed": {"guidance": "auto", "cap": 6},
    }
    tasks = [
        {"id": "positive-two", "class": "medium", "parallelism_class": "parallel-positive", "expected_lanes": 2},
        {"id": "positive-three", "class": "medium", "parallelism_class": "parallel-positive", "expected_lanes": 3},
        {"id": "positive-four", "class": "large", "parallelism_class": "parallel-positive", "expected_lanes": 4},
        {"id": "positive-six", "class": "large", "parallelism_class": "parallel-positive", "expected_lanes": 6},
        {"id": "serial-one", "class": "small", "parallelism_class": "serial-negative", "expected_lanes": 0},
    ]
    benchmark_manifest = {
        "schema": 2, "suite": "promotion-fixture", "release_status": "rc.1",
        "promotion_target": f"stable-{version}", "default_repetitions": 1, "arms": arms,
        "bootstrap_resamples": 10000, "profiles": profiles, "tasks": tasks,
        "auto_overlay": {"path": "fixture", "sha256": HASH},
        "runtime_telemetry_adapter": {"contract": "codex-runtime-telemetry/v1", "sha256": HASH},
        "app_server_telemetry": {
            "contract": "codex-app-server-telemetry/v1", "checked_codex_cli": "0.147.0",
            "runner": {"path": "benchmarks/runtime/app-server-runner.mjs", "sha256": "4" * 64},
            "reducer": {"path": "benchmarks/runtime/app-server-telemetry.mjs", "sha256": "5" * 64},
            "live_probe": "synthetic-promotion-fixture",
        },
        "runtime_telemetry_capability": {
            "status": "available", "checked_at": "2026-08-16",
            "checked_codex_cli": "0.147.0", "blocker": None,
        },
    }
    manifest_bytes = write_json(repository / "benchmarks" / "manifest.json", benchmark_manifest)
    summarizer_path = repository / "benchmarks" / "summarize.mjs"
    summarizer = summarizer_path.read_text(encoding="utf-8")
    if version != "0.3.0":
        updated = summarizer.replace("stable-0.3.0", f"stable-{version}")
        if updated == summarizer:
            raise AssertionError("future fixture could not update the summarizer promotion target")
        summarizer_path.write_text(updated, encoding="utf-8", newline="\n")
    refreshed = refresh_payload_manifest(repository)
    payload_hash = refreshed["payload_hash"]
    git(repository, "add", "baseline/manifest.json", "benchmarks/manifest.json", "benchmarks/summarize.mjs")
    git(repository, "commit", "--amend", "--no-edit")
    revision = git(repository, "rev-parse", "HEAD")
    evidence.mkdir()
    (evidence / "benchmark-manifest.json").write_bytes(manifest_bytes)
    source_hash = "2" * 64
    run = {
        "schema": 2, "contract": "codex-baseline-benchmark/v2", "platform": "linux",
        "mode": "live-paired", "status": "completed", "isolation": "os-sandboxed-local-cgroup",
        "model_invoked": True, "verifiers_executed": True, "created": "2026-08-16T00:00:00Z",
        "codex": "fixture", "model": "test-model", "source_revision": revision,
        "source_dirty": False, "source_hash": source_hash, "manifest_hash": digest(manifest_bytes),
        "codex_binary_hash": HASH, "codex_identity": "caller-pinned-sha256", "node_binary_hash": node_hash,
        "auth": "dedicated-api-key-stdin-pipe", "account_service_tier": "standard",
        "runtime_telemetry_adapter_contract": "codex-runtime-telemetry/v1",
        "runtime_telemetry_adapter_hash": HASH,
        "resource_profile": "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs",
    }
    run_bytes = write_json(evidence / "run.json", run)
    results = []
    for task in tasks:
        for position, arm in enumerate(arms, 1):
            auto = arm.startswith("auto-")
            elapsed = 50 if auto and task["expected_lanes"] else 100
            guidance = None if arm == "vanilla" else digest(("solo" if arm == "baseline-solo" else "auto").encode())
            config_hash = digest(("vanilla" if arm == "vanilla" else "solo" if arm == "baseline-solo" else "auto").encode())
            results.append({
                "schema": 2, "task": task["id"], "class": task["class"],
                "parallelism_class": task["parallelism_class"], "expected_lanes": task["expected_lanes"],
                "arm": arm, "arm_order_position": position, "cache_state": "first", "repetition": 1,
                "pass": True, "first_pass": True, "first_pass_verification": "verified",
                "first_pass_provenance": "fixture-host", "user_interventions": 0,
                "user_interventions_verification": "verified", "user_interventions_provenance": "fixture-host",
                "safety_violation": False, "safety_verification": "verified", "safety_provenance": "fixture-host",
                "authority_violation": False, "authority_verification": "verified", "authority_provenance": "fixture-host",
                "scope_violation": False, "scope_verification": "verified", "scope_provenance": "fixture-host",
                "process_exit": 0, "verifier_exit": 0, "elapsed_ms": elapsed, "turns": 1,
                "commands": 1, "file_changes": 1, "changed_files": 1, "unnecessary_files": 0,
                "changed_paths": ["fixture"], "unnecessary_paths": [], "failed_command_events": 0,
                "raw_subagent_events": task["expected_lanes"] if auto else 0,
                "input_tokens": 10, "cached_input_tokens": 0, "output_tokens": 5,
                "reasoning_tokens": 5, "usage_scope": "aggregate", "cost_usd": 0.01,
                "baseline_layer_bytes": 0, "retry_count": 0, "review_findings": 0,
                "last_message_bytes": 10, "added_lines": 1, "added_code_lines": 1,
                "added_comment_lines": 0, "added_prose_lines": 0, "added_blank_lines": 0,
                "duplicate_added_lines": 0, "pure_comment_diff": False,
                "hygiene_verification": "verified", "hygiene_provenance": "host-git-diff-objective/v1",
                "release_version": version, "payload_hash": payload_hash,
                "evaluation_profile": arm, "evaluation_profile_hash": profile_hash(profiles[arm]),
                "auto_overlay_hash": HASH if auto else None, "agent_guidance_hash": guidance,
                "configured_agent_cap": None if arm == "vanilla" else 0 if arm == "baseline-solo" else 6,
                "orchestration": orchestration(arm, task["expected_lanes"]),
                "isolation": "os-sandboxed-local-cgroup", "source_hash": source_hash,
                "layer_hash": "vanilla" if arm == "vanilla" else guidance,
                "arm_config_hash": config_hash, "fixture_hash": HASH, "prompt_hash": HASH,
                "verifier_hash": HASH,
            })
    results_bytes = b"".join((json.dumps(item, separators=(",", ":")) + "\n").encode() for item in results)
    (evidence / "results.jsonl").write_bytes(results_bytes)
    summary_bytes = subprocess.run(
        [str(node_path), str(repository / "benchmarks" / "summarize.mjs"), str(evidence / "results.jsonl"),
         str(evidence / "run.json"), str(evidence / "benchmark-manifest.json")],
        check=True, stdout=subprocess.PIPE,
    ).stdout
    summary = json.loads(summary_bytes)
    assert summary["gates"]["promotion_allowed"] is True, summary["gates"]
    (evidence / "summary.json").write_bytes(summary_bytes)
    return {
        "revision": revision, "source_hash": source_hash, "manifest_hash": digest(manifest_bytes),
        "run_hash": digest(run_bytes), "results_hash": digest(results_bytes), "summary_hash": digest(summary_bytes),
        "payload_hash": payload_hash, "node_hash": node_hash,
    }


def write_runner_attestation(evidence: Path, benchmark: dict, revision: str) -> bytes:
    return write_json(evidence / "runner-attestation.json", {
        "schema": 1,
        "contract": "codex-baseline-runner-attestation/v1",
        "candidate_source_revision": revision,
        "candidate_source_hash": benchmark["source_hash"],
        "benchmark_summary_hash": benchmark["summary_hash"],
        "benchmark_run_hash": benchmark["run_hash"],
        "benchmark_results_hash": benchmark["results_hash"],
        "benchmark_manifest_hash": benchmark["manifest_hash"],
        "codex_binary_hash": HASH,
        "node_binary_hash": benchmark["node_hash"],
        "runtime_telemetry_adapter_contract": "codex-runtime-telemetry/v1",
        "runtime_telemetry_adapter_hash": HASH,
        "verifier_hashes": [HASH],
        "signing_key_id": "untrusted-fixture-self-assertion",
        "signature_algorithm": "fixture-none",
        "signature": "not-a-trusted-signature",
    })


def run_release(
    repository: Path,
    receipt: Path,
    output: Path,
    expected_success: bool,
    *,
    include_pins: bool = True,
    expected_error: str | None = None,
    git_pin: tuple[Path, str] | None = None,
    node_pin: tuple[Path, str] | None = None,
) -> subprocess.CompletedProcess:
    command = [
        sys.executable, str(RELEASE), "--source", str(repository), "--output", str(output),
        "--promotion-receipt", str(receipt),
    ]
    if include_pins:
        git_path, git_hash = git_pin or executable_pin("git")
        node_path, node_hash = node_pin or executable_pin("node")
        command.extend([
            "--git-binary", str(git_path), "--git-sha256", git_hash,
            "--node-binary", str(node_path), "--node-sha256", node_hash,
        ])
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if (completed.returncode == 0) != expected_success:
        status = git(repository, "status", "--porcelain=v1", "--untracked-files=all")
        raise AssertionError(f"unexpected release result {completed.returncode}: {completed.stdout}\n{completed.stderr}\nstatus={status!r}")
    if expected_error is not None and expected_error not in completed.stderr:
        raise AssertionError(f"expected error {expected_error!r}, got: {completed.stderr!r}")
    return completed


def build_synthetic_stable_artifacts(repository: Path, output: Path) -> None:
    """Build lifecycle-only stable fixtures without exercising production promotion."""
    module_name = "codex_baseline_release_fixture_module"
    spec = importlib.util.spec_from_file_location(module_name, RELEASE)
    if spec is None or spec.loader is None:
        raise AssertionError("cannot load release fixture helpers")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    version, release_status, _payload_hash, payload = module.load_payload(repository)
    if release_status != "stable":
        raise AssertionError("synthetic lifecycle fixture must be marked stable")
    output.mkdir(parents=True, exist_ok=True)
    prefix = f"codex-baseline-{version}"
    tar_path = output / f"{prefix}.tar.gz"
    zip_path = output / f"{prefix}.zip"
    module.build_tar(tar_path, prefix, payload)
    module.build_zip(zip_path, prefix, payload)
    descriptor = (
        "contract=codex-baseline-update/v1\n"
        f"version={version}\n"
        f"tag=v{version}\n"
        "trust=unsigned-github-release\n"
        f"tar_name={tar_path.name}\n"
        f"tar_bytes={tar_path.stat().st_size}\n"
        f"tar_sha256={digest(tar_path.read_bytes())}\n"
        f"zip_name={zip_path.name}\n"
        f"zip_bytes={zip_path.stat().st_size}\n"
        f"zip_sha256={digest(zip_path.read_bytes())}\n"
    )
    descriptor_path = output / "codex-baseline-update-v1.txt"
    descriptor_path.write_text(descriptor, encoding="ascii", newline="\n")
    for artifact in (tar_path, zip_path, descriptor_path):
        print(f"{artifact.name}\t{artifact.stat().st_size}\t{digest(artifact.read_bytes())}")


def build_update_fixture(source: Path, version: str, output: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="codex-baseline-synthetic-update-") as temporary:
        root = Path(temporary)
        repository = root / "repository"
        subprocess.run(
            [sys.executable, str(ROOT / "tests" / "make-update-fixture.py"), "--source", str(source),
             "--output", str(repository), "--version", version, "--release-status", "stable"],
            check=True,
        )
        build_synthetic_stable_artifacts(repository, output)


def self_test() -> None:
    if shutil.which("git") is None or shutil.which("node") is None:
        raise SystemExit("release promotion tests require git and node")
    with tempfile.TemporaryDirectory(prefix="codex-baseline-promotion-test-") as temporary:
        root = Path(temporary)
        repository = root / "repository"
        evidence = root / "evidence"
        (repository / "baseline").mkdir(parents=True)
        (repository / "benchmarks").mkdir()
        shutil.copy2(SUMMARIZER, repository / "benchmarks" / "summarize.mjs")
        version = "0.3.0"
        (repository / "VERSION").write_text(version + "\n", encoding="ascii")
        rc_status = write_release_status(repository / "baseline" / "release-status.json", "rc.1")
        rc_manifest = payload_manifest(version, rc_status)
        write_json(repository / "baseline" / "manifest.json", rc_manifest)
        git(repository, "init", "-q")
        git(repository, "config", "user.name", "Codex Baseline Test")
        git(repository, "config", "user.email", "test@invalid.example")
        git(repository, "config", "core.autocrlf", "false")
        git(repository, "add", ".")
        git(repository, "commit", "-qm", "candidate")
        benchmark = make_benchmark_evidence(repository, evidence, git(repository, "rev-parse", "HEAD"), version, rc_manifest["payload_hash"])
        candidate_revision = benchmark["revision"]

        stable_status = write_release_status(repository / "baseline" / "release-status.json", "stable")
        stable_manifest = payload_manifest(version, stable_status)
        write_json(repository / "baseline" / "manifest.json", stable_manifest)
        git(repository, "add", "baseline/manifest.json", "baseline/release-status.json")
        git(repository, "commit", "-qm", "promote")
        stable_revision = git(repository, "rev-parse", "HEAD")
        attestation_bytes = write_runner_attestation(evidence, benchmark, candidate_revision)
        receipt_value = {
            "schema": 2, "contract": "codex-baseline-promotion/v2", "version": version,
            "candidate_status": "rc.1", "promotion_allowed": True,
            "candidate_source_revision": candidate_revision, "candidate_source_dirty": False,
            "candidate_source_hash": benchmark["source_hash"], "candidate_payload_hash": rc_manifest["payload_hash"],
            "benchmark_summary_file": "summary.json", "benchmark_summary_hash": benchmark["summary_hash"],
            "benchmark_run_file": "run.json", "benchmark_run_hash": benchmark["run_hash"],
            "benchmark_results_file": "results.jsonl", "benchmark_results_hash": benchmark["results_hash"],
            "benchmark_manifest_file": "benchmark-manifest.json", "benchmark_manifest_hash": benchmark["manifest_hash"],
            "runner_attestation_file": "runner-attestation.json",
            "runner_attestation_hash": digest(attestation_bytes),
            "stable_source_revision": stable_revision, "stable_payload_hash": stable_manifest["payload_hash"],
        }
        receipt = evidence / "promotion.json"
        write_json(receipt, receipt_value)
        run_release(
            repository, receipt, root / "missing-pins", False, include_pins=False,
            expected_error="requires absolute --git-binary and --git-sha256 pins",
        )
        git_path, git_hash = executable_pin("git")
        run_release(
            repository, receipt, root / "wrong-git-hash", False,
            git_pin=(git_path, "0" * 64),
            expected_error="pinned git executable SHA-256 mismatch",
        )
        linked_git = root / "linked-git"
        try:
            os.symlink(git_path, linked_git)
        except OSError:
            linked_git = None
        if linked_git is not None:
            run_release(
                repository, receipt, root / "linked-git-output", False,
                git_pin=(linked_git, git_hash),
                expected_error="symbolic-link or reparse-point ancestor",
            )
        copied_git = root / ("copied-git.exe" if os.name == "nt" else "copied-git")
        copied_git_link = root / ("copied-git-link.exe" if os.name == "nt" else "copied-git-link")
        shutil.copy2(git_path, copied_git)
        os.link(copied_git, copied_git_link)
        run_release(
            repository, receipt, root / "hardlinked-git-output", False,
            git_pin=(copied_git, digest(copied_git.read_bytes())),
            expected_error="pinned git executable is missing, linked, or special",
        )
        run_release(
            repository, receipt, root / "untrusted-self-assertion", False,
            expected_error="stable artifact generation is unavailable in this RC",
        )

        original_run = (evidence / "run.json").read_bytes()
        original_attestation = (evidence / "runner-attestation.json").read_bytes()
        mismatched_run = json.loads(original_run)
        mismatched_run["node_binary_hash"] = "0" * 64
        mismatched_run_bytes = write_json(evidence / "run.json", mismatched_run)
        mismatched_attestation = json.loads(original_attestation)
        mismatched_attestation["benchmark_run_hash"] = digest(mismatched_run_bytes)
        mismatched_attestation["node_binary_hash"] = "0" * 64
        mismatched_attestation_bytes = write_json(
            evidence / "runner-attestation.json", mismatched_attestation,
        )
        node_mismatch = dict(receipt_value)
        node_mismatch["benchmark_run_hash"] = digest(mismatched_run_bytes)
        node_mismatch["runner_attestation_hash"] = digest(mismatched_attestation_bytes)
        node_mismatch_path = evidence / "node-mismatch.json"
        write_json(node_mismatch_path, node_mismatch)
        run_release(
            repository, node_mismatch_path, root / "node-mismatch-output", False,
            expected_error="benchmark run receipt is not completed and bound to the clean candidate",
        )
        (evidence / "run.json").write_bytes(original_run)
        (evidence / "runner-attestation.json").write_bytes(original_attestation)

        fake = dict(receipt_value)
        fake["candidate_source_revision"] = "a" * 40
        fake_path = evidence / "fake.json"
        write_json(fake_path, fake)
        run_release(repository, fake_path, root / "fake-output", False)

        original_results = (evidence / "results.jsonl").read_bytes()
        (evidence / "results.jsonl").write_bytes(original_results + b"{}\n")
        run_release(repository, receipt, root / "tampered-output", False)
        (evidence / "results.jsonl").write_bytes(original_results)

        dirty_path = repository / "DIRTY"
        dirty_path.write_text("untracked\n", encoding="ascii")
        run_release(repository, receipt, root / "dirty-output", False)
        dirty_path.unlink()

        linked = evidence / "linked.json"
        try:
            os.symlink(receipt.name, linked)
        except OSError:
            linked = None
        if linked is not None:
            run_release(repository, linked, root / "linked-output", False)

        hardlinked = evidence / "hardlinked.json"
        os.link(receipt, hardlinked)
        run_release(repository, hardlinked, root / "hardlinked-output", False)
        hardlinked.unlink()

        git(repository, "checkout", "-qb", "manifest-drift", candidate_revision)
        write_release_status(repository / "baseline" / "release-status.json", "stable")
        drifted_manifest = dict(stable_manifest)
        drifted_manifest["unrelated"] = "not a deterministic promotion change"
        write_json(repository / "baseline" / "manifest.json", drifted_manifest)
        git(repository, "add", "baseline/manifest.json", "baseline/release-status.json")
        git(repository, "commit", "-qm", "drift manifest")
        drifted = dict(receipt_value)
        drifted["stable_source_revision"] = git(repository, "rev-parse", "HEAD")
        drifted_path = evidence / "drifted.json"
        write_json(drifted_path, drifted)
        run_release(repository, drifted_path, root / "drifted-output", False)

        git(repository, "checkout", "-qb", "disallowed", candidate_revision)
        write_release_status(repository / "baseline" / "release-status.json", "stable")
        write_json(repository / "baseline" / "manifest.json", stable_manifest)
        (repository / "UNAUTHORIZED").write_text("not part of promotion\n", encoding="ascii")
        git(repository, "add", "baseline/manifest.json", "baseline/release-status.json", "UNAUTHORIZED")
        git(repository, "commit", "-qm", "unauthorized stable change")
        disallowed = dict(receipt_value)
        disallowed["stable_source_revision"] = git(repository, "rev-parse", "HEAD")
        disallowed_path = evidence / "disallowed.json"
        write_json(disallowed_path, disallowed)
        run_release(repository, disallowed_path, root / "disallowed-output", False)

    print("PASS: stable promotion fails closed without independent runner-attestation trust")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-update-fixture", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    if arguments.build_update_fixture:
        if arguments.source is None or arguments.version is None or arguments.output is None:
            parser.error("--build-update-fixture requires --source, --version, and --output")
        build_update_fixture(arguments.source.resolve(), arguments.version, arguments.output.resolve())
    elif any(value is not None for value in (arguments.source, arguments.version, arguments.output)):
        parser.error("fixture arguments require --build-update-fixture")
    else:
        self_test()
