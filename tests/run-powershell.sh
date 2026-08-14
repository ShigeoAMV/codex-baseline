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
command -v tr >/dev/null 2>&1 || {
  printf '%s\n' 'tr is required to normalize native PowerShell output' >&2
  exit 1
}

windows_root=$(wslpath -w "$test_root")
# PowerShell 7 paths inherited through WSL can make Windows PowerShell 5.1 load
# duplicate type data. Resolve and pass only native Windows PowerShell paths.
# The single-quoted expression below is PowerShell code, not a Bash expansion.
# shellcheck disable=SC2016
native_module_path=$(
  powershell.exe -NoProfile -Command \
    '$paths = @((Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsPowerShell\Modules"), (Join-Path ([Environment]::GetFolderPath("ProgramFiles")) "WindowsPowerShell\Modules"), (Join-Path $PSHOME "Modules")); [string]::Join(";", $paths)' |
    tr -d '\r'
)
[[ -n $native_module_path ]] || {
  printf '%s\n' 'failed to resolve the native Windows PowerShell module path' >&2
  exit 1
}
bridge_wslenv=${WSLENV:+$WSLENV:}PSModulePath
WSLENV=$bridge_wslenv PSModulePath=$native_module_path powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_root\\tests\\windows\\lifecycle.ps1"
WSLENV=$bridge_wslenv PSModulePath=$native_module_path powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_root\\tests\\windows\\onboard-benchmark.ps1"
