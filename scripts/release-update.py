#!/usr/bin/env python3
"""Build deterministic, payload-only codex-baseline self-update assets."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import tempfile
import zipfile


CONTRACT = "codex-baseline-update/v1"
REPOSITORY = "ShigeoAMV/codex-baseline"
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_CONTENT_BYTES = 128 * 1024 * 1024
MAX_ENTRIES = 512
MAX_DEPTH = 8
MAX_PATH_BYTES = 240
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
WINDOWS_DEVICE_RE = re.compile(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$", re.IGNORECASE)


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"release-update: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def load_payload(source: Path) -> tuple[str, dict[str, bytes]]:
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

    if len(captured) > MAX_ENTRIES:
        fail(f"payload exceeds {MAX_ENTRIES} files")
    if total > MAX_CONTENT_BYTES:
        fail(f"payload exceeds {MAX_CONTENT_BYTES} uncompressed bytes")
    return version, {path: captured[path] for path in sorted(captured)}


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


def atomic_build(source: Path, output: Path) -> list[Path]:
    version, payload = load_payload(source)
    paths = list(payload)
    prefix = f"codex-baseline-{version}"
    if len(directory_members(prefix, paths)) + len(paths) > MAX_ENTRIES:
        fail(f"release archive exceeds {MAX_ENTRIES} total entries")
    tar_name = f"{prefix}.tar.gz"
    zip_name = f"{prefix}.zip"
    descriptor_name = "codex-baseline-update-v1.txt"
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
            f"contract={CONTRACT}\n"
            f"version={version}\n"
            f"tag=v{version}\n"
            "trust=unsigned-github-release\n"
            f"tar_name={tar_name}\n"
            f"tar_bytes={tar_path.stat().st_size}\n"
            f"tar_sha256={sha256(tar_path)}\n"
            f"zip_name={zip_name}\n"
            f"zip_bytes={zip_path.stat().st_size}\n"
            f"zip_sha256={sha256(zip_path)}\n"
        )
        descriptor_path = stage / descriptor_name
        descriptor_path.write_bytes(descriptor.encode("ascii"))
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
    arguments = parser.parse_args()
    source = (arguments.source or Path(__file__).resolve().parent.parent).resolve()
    output = arguments.output.resolve()
    for artifact in atomic_build(source, output):
        print(f"{artifact.name}\t{artifact.stat().st_size}\t{sha256(artifact)}")


if __name__ == "__main__":
    main()
