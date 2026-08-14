#!/usr/bin/env python3
"""Build malicious update archives for fail-closed lifecycle tests."""

from __future__ import annotations

import argparse
import gzip
from pathlib import Path
import stat
import struct
import tarfile
import zipfile


def copy_tar_with_extra(source: Path, destination: Path) -> None:
    with tarfile.open(source, "r:gz") as original:
        members = original.getmembers()
        root = members[0].name.rstrip("/")
        with destination.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as output:
                    for member in members:
                        stream = original.extractfile(member) if member.isfile() else None
                        output.addfile(member, stream)
                    extra = tarfile.TarInfo(f"{root}/unexpected.txt")
                    extra.size = 1
                    extra.mode = 0o644
                    output.addfile(extra, __import__("io").BytesIO(b"x"))


def copy_tar_with_case_collision(source: Path, destination: Path) -> None:
    with tarfile.open(source, "r:gz") as original:
        members = original.getmembers()
        root = members[0].name.rstrip("/")
        with destination.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as output:
                    for member in members:
                        stream = original.extractfile(member) if member.isfile() else None
                        output.addfile(member, stream)
                    collision = tarfile.TarInfo(f"{root}/version")
                    collision.size = 6
                    collision.mode = 0o644
                    output.addfile(collision, __import__("io").BytesIO(b"0.2.0\n"))


def simple_tar(destination: Path, kind: str) -> None:
    with destination.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as output:
                if kind == "traversal":
                    entry = tarfile.TarInfo("../escape")
                    entry.size = 1
                    output.addfile(entry, __import__("io").BytesIO(b"x"))
                else:
                    root = tarfile.TarInfo("codex-baseline-0.2.0")
                    root.type = tarfile.DIRTYPE
                    output.addfile(root)
                    entry = tarfile.TarInfo("codex-baseline-0.2.0/link")
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = "../../escape"
                    output.addfile(entry)


def pax_tar(destination: Path) -> None:
    with destination.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT, pax_headers={"comment": "forbidden"}) as output:
                root = tarfile.TarInfo("codex-baseline-0.2.0")
                root.type = tarfile.DIRTYPE
                output.addfile(root)


def raw_tar_bomb(destination: Path) -> None:
    with destination.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
            block = b"\0" * (1024 * 1024)
            for _ in range(133):
                compressed.write(block)


def copy_zip_with_collision(source: Path, destination: Path) -> None:
    with zipfile.ZipFile(source, "r") as original, zipfile.ZipFile(destination, "w") as output:
        for entry in original.infolist():
            output.writestr(entry, original.read(entry))
        root = original.infolist()[0].filename.rstrip("/")
        entry = zipfile.ZipInfo(f"{root}/version", (1980, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.external_attr = (stat.S_IFREG | 0o644) << 16
        output.writestr(entry, b"0.2.0\n")


def simple_zip(destination: Path, kind: str) -> None:
    with zipfile.ZipFile(destination, "w") as output:
        if kind == "traversal":
            output.writestr("../escape", b"x")
        else:
            root = zipfile.ZipInfo("codex-baseline-0.2.0/", (1980, 1, 1, 0, 0, 0))
            root.create_system = 3
            root.external_attr = (stat.S_IFDIR | 0o755) << 16
            output.writestr(root, b"")
            link = zipfile.ZipInfo("codex-baseline-0.2.0/link", (1980, 1, 1, 0, 0, 0))
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(link, b"../../escape")


def forged_length_zip(destination: Path) -> None:
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        output.writestr("codex-baseline-0.2.0/bomb", b"x" * (1024 * 1024))
    data = bytearray(destination.read_bytes())
    central = data.find(b"PK\x01\x02")
    if central < 0:
        raise RuntimeError("cannot locate ZIP central directory")
    data[central + 24 : central + 28] = struct.pack("<I", 1)
    destination.write_bytes(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tar", required=True, type=Path)
    parser.add_argument("--zip", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    simple_tar(args.output / "traversal.tar.gz", "traversal")
    simple_tar(args.output / "symlink.tar.gz", "symlink")
    pax_tar(args.output / "pax.tar.gz")
    raw_tar_bomb(args.output / "raw-bomb.tar.gz")
    copy_tar_with_case_collision(args.tar, args.output / "case-collision.tar.gz")
    copy_tar_with_extra(args.tar, args.output / "extra.tar.gz")
    simple_zip(args.output / "traversal.zip", "traversal")
    simple_zip(args.output / "symlink.zip", "symlink")
    forged_length_zip(args.output / "forged-length.zip")
    copy_zip_with_collision(args.zip, args.output / "case-collision.zip")


if __name__ == "__main__":
    main()
