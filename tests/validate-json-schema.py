#!/usr/bin/env python3
"""Validate one JSON document against a local Draft 2020-12 schema."""

from __future__ import annotations

import json
import pathlib
import sys

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError as exc:  # pragma: no cover - exercised by the shell preflight
    raise SystemExit("tests require the Python jsonschema package") from exc


def load_json(path: str) -> object:
    with pathlib.Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate-json-schema.py SCHEMA INSTANCE", file=sys.stderr)
        return 64
    schema = load_json(sys.argv[1])
    instance = load_json(sys.argv[2])
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(instance), key=lambda item: list(item.path))
    if not errors:
        return 0
    for error in errors:
        location = "/".join(str(part) for part in error.absolute_path) or "."
        print(f"{location}: {error.message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
