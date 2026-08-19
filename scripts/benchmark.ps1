[CmdletBinding()]
param(
    [switch]$Static,
    [switch]$Live,
    [switch]$Json,
    [string]$Tasks = 'small-js-bug,small-config-timeout,small-doc-port,risk-migration,medium-js-feature,medium-dedup-reproduction,medium-id-refactor,large-architecture,large-feature-flags,six-lane-packages'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:SourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:BenchmarkRoot = Join-Path $script:SourceRoot 'benchmarks'

function Write-BenchError {
    param([string]$Message)
    [Console]::Error.WriteLine("codex-baseline benchmark: {0}" -f $Message)
}

function Get-BenchItem {
    param([string]$Path)
    try { return Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
    catch [System.IO.FileNotFoundException] { return $null }
    catch [System.IO.DirectoryNotFoundException] { return $null }
}

function Assert-BenchOrdinary {
    param($Item, [string]$Kind = 'any')
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Benchmark inputs cannot contain reparse points: $($Item.FullName)"
    }
    if ($Kind -eq 'file' -and $Item.PSIsContainer) { throw "Expected benchmark file: $($Item.FullName)" }
    if ($Kind -eq 'tree' -and -not $Item.PSIsContainer) { throw "Expected benchmark directory: $($Item.FullName)" }
}

function Get-BenchRegularItem {
    param([string]$Path, [string]$Kind)
    $item = Get-BenchItem $Path
    if ($null -eq $item) { throw "Benchmark input is missing: $Path" }
    Assert-BenchOrdinary $item $Kind
    return $item
}

function Read-BenchText {
    param([string]$Path)
    $item = Get-BenchRegularItem $Path 'file'
    return $script:Utf8Strict.GetString([System.IO.File]::ReadAllBytes($item.FullName))
}

function Assert-BenchTree {
    param([string]$Path)
    $root = Get-BenchRegularItem $Path 'tree'
    $fileCount = 0
    foreach ($child in @(Get-ChildItem -LiteralPath $root.FullName -Force -ErrorAction Stop)) {
        Assert-BenchOrdinary $child 'any'
        if ($child.PSIsContainer) { $fileCount += Assert-BenchTree $child.FullName }
        else { $fileCount++ }
    }
    return $fileCount
}

function Read-BenchManifest {
    $path = Join-Path $script:BenchmarkRoot 'manifest.json'
    try { $manifest = (Read-BenchText $path) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Benchmark manifest is invalid JSON: $($_.Exception.Message)" }
    if ([int]$manifest.schema -ne 2) { throw "Unsupported benchmark manifest schema: $($manifest.schema)" }
    if ([string]$manifest.suite -ne 'codex-baseline-autonomous-execution') { throw 'Unexpected benchmark suite identity.' }
    if ([int]$manifest.default_repetitions -lt 1) { throw 'Benchmark repetitions must be positive.' }
    if ([string]$manifest.isolation.local_label -ne 'os-sandboxed-local-cgroup') { throw 'Benchmark local isolation label is invalid.' }
    $requiredMetrics = @('task_pass', 'first_pass', 'user_interventions', 'safety_violation', 'authority_violation', 'scope_violation', 'verifier_exit', 'process_exit', 'elapsed_ms', 'turns', 'commands', 'file_changes', 'raw_subagent_events', 'input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_tokens', 'cost_usd', 'planned_fanout', 'actual_fanout', 'peak_concurrency')
    foreach ($metric in $requiredMetrics) {
        if ($metric -notin @($manifest.metrics)) { throw "Benchmark metric is missing: $metric" }
    }
    $classes = @($manifest.tasks | ForEach-Object { [string]$_.class })
    foreach ($requiredClass in @('small', 'medium', 'large', 'risk-sensitive')) {
        if ($requiredClass -notin $classes) { throw "Benchmark task class is missing: $requiredClass" }
    }
    $native = $manifest.native_powershell_evaluation
    if ([string]$native.status -ne 'manual-no-key' -or
        [string]$native.platform -ne 'native-windows' -or
        (@($native.engines) -join ',') -ne 'powershell-5.1,powershell-7' -or
        (@($native.arms) -join ',') -ne 'vanilla,baseline-solo' -or
        [int]$native.default_repetitions -lt 1 -or
        (@($native.metrics) -join ',') -ne 'task_pass,failed_command_events,parser_error_events') {
        throw 'Native PowerShell evaluation contract is invalid.'
    }
    foreach ($relativePath in @($native.task, $native.runner, $native.verifier)) {
        if ([string]$relativePath -notmatch '^benchmarks/native-powershell/[a-z0-9.-]+$') {
            throw "Unsafe native PowerShell evaluation path: $relativePath"
        }
        Get-BenchRegularItem (Join-Path $script:SourceRoot ([string]$relativePath)) 'file' | Out-Null
    }
    return $manifest
}

function Assert-BenchVerifierContract {
    param([string]$TaskId, [string]$VerifierPath)
    $verifier = Read-BenchText $VerifierPath
    if (-not $verifier.StartsWith('#!/usr/bin/env bash', [StringComparison]::Ordinal)) {
        throw "Verifier does not declare its Bash runtime: $TaskId"
    }
    if ($verifier -notmatch '(?m)^set -Eeuo pipefail\r?$') {
        throw "Verifier does not enable strict shell mode: $TaskId"
    }
    if ($verifier -notmatch 'root=\$\{1:\?workspace required\}') {
        throw "Verifier does not require an explicit workspace argument: $TaskId"
    }
    if ($verifier -match '(?m)^\s*(sudo|ssh|scp|git\s+push|rm\s+-rf\s+[/~])\b') {
        throw "Verifier contains a forbidden privileged, remote, or broad destructive command: $TaskId"
    }
    return [pscustomobject]@{
        runtime = 'bash-declared-not-executed'
        strict_mode = $true
        workspace_argument = $true
        forbidden_command_scan = 'passed-static-pattern-check'
    }
}

function Validate-BenchTask {
    param($Task)
    $id = [string]$Task.id
    if ($id -notmatch '^[a-z0-9-]+$') { throw "Unsafe benchmark task id: $id" }
    $fixture = Join-Path (Join-Path $script:BenchmarkRoot 'fixtures') $id
    $taskFile = Join-Path $fixture 'task.md'
    $workspace = Join-Path $fixture 'workspace'
    $verifier = Join-Path (Join-Path $script:BenchmarkRoot 'verifiers') ($id + '.sh')
    Get-BenchRegularItem $fixture 'tree' | Out-Null
    $taskItem = Get-BenchRegularItem $taskFile 'file'
    if ($taskItem.Length -eq 0 -or $taskItem.Length -gt 1048576) { throw "Task prompt size is invalid: $id" }
    $workspaceFiles = Assert-BenchTree $workspace
    if ($workspaceFiles -lt 1 -or $workspaceFiles -gt 1000) { throw "Starter workspace file count is invalid: $id" }
    $verifierItem = Get-BenchRegularItem $verifier 'file'
    if ($verifierItem.Length -eq 0 -or $verifierItem.Length -gt 1048576) { throw "Verifier size is invalid: $id" }
    $contract = Assert-BenchVerifierContract $id $verifier
    return [pscustomobject]@{
        id = $id
        class = [string]$Task.class
        visibility = [string]$Task.visibility
        workspace_files = $workspaceFiles
        fixture_contract = 'valid-static'
        verifier_contract = 'valid-static'
        verifier_runtime = $contract.runtime
        starter_verifier_result = 'not-executed-native-static'
        model_invoked = $false
    }
}

function Show-BenchUsage {
    [Console]::Out.WriteLine(@'
Usage: powershell -File benchmark.ps1 [-Static] [-Json] [-Tasks CSV]

Native Windows static mode validates the manifest, task classes, fixture bounds,
reparse-point safety, and Bash verifier contracts. It runs no verifier and no
model. Live native-Windows benchmarking is not implemented; use the Unix runner
or add a reviewed native verifier implementation before making live claims.
'@)
}

$exitCode = 0
try {
    if ($Live) {
        throw 'Native Windows live benchmark is not implemented. No model, auth file, or verifier was invoked.'
    }
    $manifest = Read-BenchManifest
    $selected = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in $Tasks.Split(',')) {
        $id = $candidate.Trim()
        if ($id -notmatch '^[a-z0-9-]+$') { throw "Unsafe requested task id: $id" }
        if (-not $selected.Contains($id)) { $selected.Add($id) | Out-Null }
    }
    if ($selected.Count -eq 0) { throw 'At least one benchmark task is required.' }
    $byId = @{}
    foreach ($task in @($manifest.tasks)) {
        $id = [string]$task.id
        if ($byId.ContainsKey($id)) { throw "Duplicate task in benchmark manifest: $id" }
        $byId[$id] = $task
    }
    $results = @()
    foreach ($id in $selected) {
        if (-not $byId.ContainsKey($id)) { throw "Requested task is not in the benchmark manifest: $id" }
        $result = Validate-BenchTask $byId[$id]
        $results += $result
        if (-not $Json) {
            [Console]::Out.WriteLine(("static: {0} fixture/verifier contract valid; starter not executed" -f $id))
        }
    }
    $report = [pscustomobject]@{
        schema = 2
        contract = 'codex-baseline-benchmark/v2'
        platform = 'native-windows'
        mode = 'static-contract-only'
        status = 'completed'
        isolation = 'not-applicable-no-worker'
        model_invoked = $false
        verifiers_executed = $false
        tasks = @($results)
        limitations = @(
            'Bash verifiers were parsed but not executed.',
            'Starter failure is not proven by native static mode.',
            'No model comparison or performance metric was collected.'
        )
    }
    if ($Json) {
        [Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 7 -Compress))
    }
    else {
        [Console]::Out.WriteLine(("static benchmark contract validation passed ({0} tasks, no verifier or model invoked)" -f $results.Count))
    }
}
catch {
    Write-BenchError $_.Exception.Message
    $exitCode = 1
}

exit $exitCode
