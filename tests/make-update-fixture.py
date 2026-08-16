#!/usr/bin/env python3
"""Create a synthetic, internally consistent next-version source for lifecycle tests."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--release-status", default="stable", choices=("stable", "rc.1"))
    parser.add_argument(
        "--promote-from-rc", action="store_true",
        help="copy an existing RC fixture and change only release-status.json plus deterministic manifest.json",
    )
    arguments = parser.parse_args()
    source = arguments.source.resolve()
    output = arguments.output.resolve()
    if not VERSION_RE.fullmatch(arguments.version):
        raise SystemExit("fixture version must be stable MAJOR.MINOR.PATCH")
    if output.exists():
        raise SystemExit(f"fixture output already exists: {output}")
    output.mkdir(parents=True)
    for name in ("baseline", "benchmarks", "scripts"):
        shutil.copytree(source / name, output / name, symlinks=True)
    if arguments.promote_from_rc:
        if arguments.release_status != "stable":
            raise SystemExit("--promote-from-rc requires --release-status stable")
        source_version = (source / "VERSION").read_text(encoding="ascii").strip()
        if source_version != arguments.version:
            raise SystemExit("promotion fixture version must equal the RC VERSION")
        source_status = json.loads((source / "baseline" / "release-status.json").read_text(encoding="utf-8"))
        if source_status.get("status") != "rc.1":
            raise SystemExit("--promote-from-rc source must have release status rc.1")
        shutil.copy2(source / "VERSION", output / "VERSION")
    else:
        (output / "VERSION").write_text(arguments.version + "\n", encoding="ascii", newline="\n")
        block = output / "baseline" / "global" / "AGENTS.block.md"
        block.write_text(block.read_text(encoding="utf-8") + f"\n<!-- update-fixture {arguments.version} -->\n", encoding="utf-8", newline="\n")
        bash_entry = output / "scripts" / "codex-baseline.sh"
        bash_text = bash_entry.read_text(encoding="utf-8")
        bash_canary = (
            'if [ -n "${CODEX_BASELINE_TEST_DOWNLOADED_EXECUTION_CANARY-}" ]; then\n'
            '  printf "%s\\n" executed >"$CODEX_BASELINE_TEST_DOWNLOADED_EXECUTION_CANARY"\n'
            'fi\n'
        )
        bash_entry.write_text(bash_text.replace("#!/bin/sh\n", "#!/bin/sh\n" + bash_canary, 1), encoding="utf-8", newline="\n")
        powershell_entry = output / "scripts" / "codex-baseline.ps1"
        powershell_text = powershell_entry.read_text(encoding="utf-8")
        powershell_canary = (
            "if (-not [string]::IsNullOrWhiteSpace($env:CODEX_BASELINE_TEST_DOWNLOADED_EXECUTION_CANARY)) {\n"
            "    [System.IO.File]::WriteAllText($env:CODEX_BASELINE_TEST_DOWNLOADED_EXECUTION_CANARY, \"executed`n\")\n"
            "}\n\n"
        )
        powershell_entry.write_text(
            powershell_text.replace("Set-StrictMode -Version 2.0\n", powershell_canary + "Set-StrictMode -Version 2.0\n", 1),
            encoding="utf-8",
            newline="\n",
        )

    manifest_path = output / "baseline" / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["version"] = arguments.version
    release_status_path = output / "baseline" / "release-status.json"
    release_status_path.write_text(
        json.dumps(
            {"schema": 1, "contract": "codex-baseline-release-status/v1", "status": arguments.release_status},
            indent=2,
        ) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    payload = []
    canonical = []
    for original in manifest["payload"]:
        relative = original["path"]
        data = (output / relative).read_bytes()
        entry = {"path": relative, "bytes": len(data), "sha256": digest(data)}
        payload.append(entry)
        canonical.append(f"{relative}\t{len(data)}\t{entry['sha256']}\n")
    manifest["payload"] = payload
    manifest["payload_hash"] = digest("".join(sorted(canonical)).encode("utf-8"))

    scalar_order = (
        "schema", "version", "minimum_codex", "tested_codex", "research_checked",
        "research_review_by", "encoding", "line_endings", "global_block",
        "source_trust", "payload_hash",
    )
    lines = ["{"]
    for key in scalar_order:
        value = json.dumps(manifest[key], ensure_ascii=True, separators=(",", ":"))
        lines.append(f'  "{key}": {value},')
    lines.append('  "payload": [')
    for index, entry in enumerate(payload):
        comma = "," if index + 1 < len(payload) else ""
        lines.append(
            f'    {{"path": {json.dumps(entry["path"])}, "bytes": {entry["bytes"]}, '
            f'"sha256": {json.dumps(entry["sha256"])}}}{comma}'
        )
    lines.extend(("  ]", "}"))
    manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
