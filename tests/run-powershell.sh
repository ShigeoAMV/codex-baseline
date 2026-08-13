#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

command -v powershell.exe >/dev/null 2>&1 || {
  printf '%s\n' 'native Windows PowerShell is not reachable as powershell.exe' >&2
  exit 1
}
command -v wslpath >/dev/null 2>&1 || {
  printf '%s\n' 'wslpath is required to launch the native Windows suites from WSL' >&2
  exit 1
}

windows_root=$(wslpath -w "$test_root")
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_root\\tests\\windows\\lifecycle.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_root\\tests\\windows\\onboard-benchmark.ps1"
