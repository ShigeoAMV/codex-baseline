[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Alias('dry-run')]
    [switch]$DryRun,

    [Alias('acknowledge-unverified-source')]
    [switch]$AcknowledgeUnverifiedSource,

    [switch]$Check,

    [switch]$Remote,

    [switch]$Local,

    [string]$Offline,

    [switch]$Json,

    [switch]$Apply,

    [switch]$Restore,

    [ValidateSet('keep', 'standard', 'fast', 'ultrafast')]
    [string]$Speed = 'keep',

    [Alias('acknowledge-existing-instructions')]
    [switch]$AcknowledgeExistingInstructions,

    [Alias('max-files')]
    [ValidateRange(1, 100000)]
    [int]$MaxFiles = 2000,

    [Alias('max-visited')]
    [ValidateRange(1, 500000)]
    [int]$MaxVisited = 10000,

    [Parameter(Position = 1)]
    [string]$Repository = '.',

    [switch]$Static,

    [switch]$Live,

    [string]$Tasks = 'small-js-bug,small-config-timeout,small-doc-port,risk-migration,medium-js-feature,medium-dedup-reproduction,medium-id-refactor,large-architecture,large-feature-flags,six-lane-packages'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Schema = 1
$script:BeginPattern = '(?m)^<!-- codex-baseline:begin version=[^>\r\n]* -->\r?$'
$script:EndPattern = '(?m)^<!-- codex-baseline:end -->\r?$'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:SourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:LockHeld = $false
$script:ActiveTransaction = $null
$script:ActiveComposite = $null
$script:MutationStarted = $false
$script:VerifiedAgentsConfigCapability = $false
$script:VerifiedFastConfigCapability = $false
$script:TrustedPrivateDirectorySids = @('S-1-5-18', 'S-1-5-32-544')
$script:UpdateMetadataUrl = 'https://github.com/ShigeoAMV/codex-baseline/releases/latest/download/codex-baseline-update-v1.txt'
$script:UpdateMaxArchiveBytes = 67108864
$script:UpdateMaxContentBytes = 134217728

function Write-CbError {
    param([string]$Message)
    [Console]::Error.WriteLine("codex-baseline: {0}" -f $Message)
}

function Get-CbFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A required path is empty.'
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Compare-CbSemVer {
    param([string]$Left, [string]$Right)
    $pattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    if ($Left -notmatch $pattern) { throw "Invalid stable version: $Left" }
    $leftParts = @($Left.Split('.') | ForEach-Object { [uint64]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
    if ($Right -notmatch $pattern) { throw "Invalid stable version: $Right" }
    $rightParts = @($Right.Split('.') | ForEach-Object { [uint64]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
    for ($index = 0; $index -lt 3; $index++) {
        if ($leftParts[$index] -gt $rightParts[$index]) { return 1 }
        if ($leftParts[$index] -lt $rightParts[$index]) { return -1 }
    }
    return 0
}

function Assert-CbRawLocalRootPath {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label must be set to a fully-qualified local path."
    }
    if ($Path.IndexOfAny([char[]](@(0..31) + @(127))) -ge 0) {
        throw "$Label contains control characters."
    }
    if ($Path -match '^[\\/]{2}[?.][\\/]' -or $Path -match '^(\\\\|//)') {
        throw "$Label cannot use a device or UNC path: $Path"
    }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "$Label must be fully-qualified before normalization: $Path"
    }
    if ($Path.Substring(2).Contains(':')) {
        throw "$Label cannot contain an alternate data stream: $Path"
    }
}

function Test-CbSamePath {
    param([string]$Left, [string]$Right)
    return [string]::Equals(
        (Get-CbFullPath $Left).TrimEnd('\', '/'),
        (Get-CbFullPath $Right).TrimEnd('\', '/'),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-CbItem {
    param([string]$Path)
    try {
        return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    }
    catch [System.IO.FileNotFoundException] {
        return $null
    }
    catch [System.IO.DirectoryNotFoundException] {
        return $null
    }
}

function Test-CbExists {
    param([string]$Path)
    return $null -ne (Get-CbItem $Path)
}

function Assert-CbOrdinaryItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [string]$ExpectedKind = 'any'
    )
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points are not allowed in managed paths: $($Item.FullName)"
    }
    if ($ExpectedKind -eq 'file' -and $Item.PSIsContainer) {
        throw "Expected a regular file: $($Item.FullName)"
    }
    if ($ExpectedKind -eq 'tree' -and -not $Item.PSIsContainer) {
        throw "Expected a directory: $($Item.FullName)"
    }
}

function Assert-CbSafeRoot {
    param([string]$Path, [string]$Label)
    Assert-CbRawLocalRootPath $Path $Label
    $full = Get-CbFullPath $Path
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root) -or (Test-CbSamePath $full $root)) {
        throw "$Label must be an absolute non-root path: $full"
    }
    $item = Get-CbItem $full
    if ($null -ne $item) {
        Assert-CbOrdinaryItem $item 'tree'
    }
    Assert-CbExistingAncestorsSafe $full
    return $full
}

function Ensure-CbSafeDirectory {
    param([string]$Path)
    $full = Get-CbFullPath $Path
    $item = Get-CbItem $full
    if ($null -ne $item) {
        Assert-CbOrdinaryItem $item 'tree'
        return $full
    }
    $parent = [System.IO.Directory]::GetParent($full)
    if ($null -eq $parent) {
        throw "Cannot create a filesystem root: $full"
    }
    Ensure-CbSafeDirectory $parent.FullName | Out-Null
    [System.IO.Directory]::CreateDirectory($full) | Out-Null
    $created = Get-Item -LiteralPath $full -Force
    Assert-CbOrdinaryItem $created 'tree'
    return $full
}

function Assert-CbExistingAncestorsSafe {
    param([string]$Path)
    $full = Get-CbFullPath $Path
    $cursor = $full
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-CbItem $cursor
        if ($null -ne $item) {
            Assert-CbOrdinaryItem $item 'tree'
        }
        $parent = [System.IO.Directory]::GetParent($cursor)
        if ($null -eq $parent -or (Test-CbSamePath $parent.FullName $cursor)) {
            break
        }
        $cursor = $parent.FullName
    }
}

function Assert-CbTreeSafe {
    param([string]$Path)
    $root = Get-CbItem $Path
    if ($null -eq $root) {
        throw "Directory is missing: $Path"
    }
    Assert-CbOrdinaryItem $root 'tree'
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force)) {
        Assert-CbOrdinaryItem $child 'any'
        if ($child.PSIsContainer) {
            Assert-CbTreeSafe $child.FullName
        }
    }
}

function Remove-CbSafeItem {
    param([string]$Path)
    $item = Get-CbItem $Path
    if ($null -eq $item) {
        return
    }
    Assert-CbOrdinaryItem $item 'any'
    if ($item.PSIsContainer) {
        Assert-CbTreeSafe $item.FullName
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
    else {
        Remove-Item -LiteralPath $item.FullName -Force
    }
}

function Read-CbUtf8Text {
    param([string]$Path)
    $item = Get-CbItem $Path
    if ($null -eq $item) {
        throw "File is missing: $Path"
    }
    Assert-CbOrdinaryItem $item 'file'
    $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
    return $script:Utf8Strict.GetString($bytes)
}

function Write-CbUtf8File {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    $parent = [System.IO.Path]::GetDirectoryName((Get-CbFullPath $Path))
    Ensure-CbSafeDirectory $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Write-CbUtf8Atomic {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    $full = Get-CbFullPath $Path
    $parent = [System.IO.Path]::GetDirectoryName($full)
    Ensure-CbSafeDirectory $parent | Out-Null
    $temporary = Join-Path $parent ('.cbw-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 12))
    $replaceBackup = Join-Path $parent ('.cbb-{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 12))
    try {
        $bytes = $script:Utf8NoBom.GetBytes($Text)
        $stream = New-Object System.IO.FileStream(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        $existing = Get-CbItem $full
        if ($null -ne $existing) {
            Assert-CbOrdinaryItem $existing 'file'
            [System.IO.File]::Replace($temporary, $full, $replaceBackup, $true)
            Remove-CbSafeItem $replaceBackup
        }
        else {
            [System.IO.File]::Move($temporary, $full)
        }
    }
    finally {
        if (Test-CbExists $temporary) {
            Remove-CbSafeItem $temporary
        }
        if (Test-CbExists $replaceBackup) {
            Remove-CbSafeItem $replaceBackup
        }
    }
}

function Get-CbSha256Bytes {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-CbStringHash {
    param([AllowEmptyString()][string]$Text)
    return Get-CbSha256Bytes $script:Utf8NoBom.GetBytes($Text)
}

function Get-CbFileHash {
    param([string]$Path)
    $item = Get-CbItem $Path
    if ($null -eq $item) {
        throw "File is missing: $Path"
    }
    Assert-CbOrdinaryItem $item 'file'
    $stream = [System.IO.File]::Open(
        $item.FullName,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Add-CbOrdinaryFilePaths {
    param(
        [string]$Root,
        [string]$Current,
        [string]$Prefix,
        [System.Collections.Generic.List[string]]$Paths,
        [string]$ExcludedPath = ''
    )
    $rootFull = (Get-CbFullPath $Root).TrimEnd('\', '/')
    $currentItem = Get-CbItem $Current
    if ($null -eq $currentItem) {
        throw "Payload directory is missing: $Current"
    }
    Assert-CbOrdinaryItem $currentItem 'tree'
    foreach ($child in @(Get-ChildItem -LiteralPath $currentItem.FullName -Force)) {
        Assert-CbOrdinaryItem $child 'any'
        if ($child.PSIsContainer) {
            Add-CbOrdinaryFilePaths $rootFull $child.FullName $Prefix $Paths $ExcludedPath
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($ExcludedPath) -and
            (Test-CbSamePath $child.FullName $ExcludedPath)) {
            continue
        }
        $relative = $child.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        $Paths.Add(("{0}/{1}" -f $Prefix, $relative)) | Out-Null
    }
}

function Add-CbTreeHashEntries {
    param(
        [string]$Root,
        [string]$Current,
        [System.Collections.Generic.List[string]]$Entries
    )
    foreach ($child in @(Get-ChildItem -LiteralPath $Current -Force)) {
        Assert-CbOrdinaryItem $child 'any'
        $relative = $child.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($child.PSIsContainer) {
            $Entries.Add("D`t$relative") | Out-Null
            Add-CbTreeHashEntries $Root $child.FullName $Entries
        }
        else {
            $Entries.Add(("F`t{0}`t{1}" -f $relative, (Get-CbFileHash $child.FullName))) | Out-Null
        }
    }
}

function Get-CbTreeHash {
    param([string]$Path)
    $full = (Get-CbFullPath $Path).TrimEnd('\', '/')
    Assert-CbTreeSafe $full
    $entries = New-Object 'System.Collections.Generic.List[string]'
    Add-CbTreeHashEntries $full $full $entries
    $array = [string[]]$entries.ToArray()
    [System.Array]::Sort($array, [System.StringComparer]::Ordinal)
    return Get-CbStringHash (([string]::Join("`n", $array)) + "`n")
}

function Get-CbKind {
    param([string]$Path)
    $item = Get-CbItem $Path
    if ($null -eq $item) {
        return 'absent'
    }
    Assert-CbOrdinaryItem $item 'any'
    if ($item.PSIsContainer) {
        return 'tree'
    }
    return 'file'
}

function Get-CbBlockInfo {
    param([AllowEmptyString()][string]$Text)
    $begin = [regex]::Matches($Text, $script:BeginPattern)
    $end = [regex]::Matches($Text, $script:EndPattern)
    if ($begin.Count -gt 1 -or $end.Count -gt 1 -or $begin.Count -ne $end.Count) {
        throw 'Malformed or duplicate codex-baseline markers.'
    }
    if ($begin.Count -eq 0) {
        return [pscustomobject]@{ Present = $false; Block = ''; Start = -1; Length = 0 }
    }
    if ($end[0].Index -lt $begin[0].Index) {
        throw 'The codex-baseline marker order is invalid.'
    }
    $finish = $end[0].Index + $end[0].Length
    return [pscustomobject]@{
        Present = $true
        Block = $Text.Substring($begin[0].Index, $finish - $begin[0].Index)
        Start = $begin[0].Index
        Length = $finish - $begin[0].Index
    }
}

function Get-CbManagedBlockHash {
    param([string]$Path)
    $item = Get-CbItem $Path
    if ($null -eq $item) {
        return 'absent'
    }
    Assert-CbOrdinaryItem $item 'file'
    $info = Get-CbBlockInfo (Read-CbUtf8Text $item.FullName)
    if (-not $info.Present) {
        return 'absent'
    }
    return Get-CbStringHash $info.Block
}

function Get-CbPhysicalHash {
    param([string]$Path)
    $kind = Get-CbKind $Path
    switch ($kind) {
        'absent' { return 'absent' }
        'file' { return Get-CbFileHash $Path }
        'tree' { return Get-CbTreeHash $Path }
        default { throw "Unsupported filesystem object at $Path" }
    }
}

function Get-CbLiveHash {
    param([string]$Kind, [string]$Path)
    if ($Kind -eq 'block') {
        return Get-CbManagedBlockHash $Path
    }
    $actual = Get-CbKind $Path
    if ($actual -eq 'absent') {
        return 'absent'
    }
    if ($actual -ne $Kind) {
        throw "Managed object kind conflict at $Path"
    }
    if ($Kind -eq 'file') {
        return Get-CbFileHash $Path
    }
    if ($Kind -eq 'tree') {
        return Get-CbTreeHash $Path
    }
    throw "Unsupported managed object kind: $Kind"
}

function New-CbRenderedBlock {
    param([string]$SourcePath, [string]$Version)
    $body = (Read-CbUtf8Text $SourcePath).TrimEnd([char[]]"`r`n")
    return "<!-- codex-baseline:begin version=$Version -->`n$body`n<!-- codex-baseline:end -->"
}

function Set-CbBlockText {
    param(
        [AllowEmptyString()][string]$LiveText,
        [AllowEmptyString()][string]$DesiredBlock
    )
    $info = Get-CbBlockInfo $LiveText
    if ($info.Present) {
        return $LiveText.Substring(0, $info.Start) + $DesiredBlock + $LiveText.Substring($info.Start + $info.Length)
    }
    if ($LiveText.Length -eq 0) {
        return $DesiredBlock
    }
    $separator = "`n`n"
    if ($LiveText.EndsWith("`n")) {
        $separator = "`n"
    }
    return $LiveText + $separator + $DesiredBlock
}

function Remove-CbBlockText {
    param([AllowEmptyString()][string]$LiveText)
    $info = Get-CbBlockInfo $LiveText
    if (-not $info.Present) {
        return $LiveText
    }
    return $LiveText.Substring(0, $info.Start) + $LiveText.Substring($info.Start + $info.Length)
}

function Copy-CbFileSafe {
    param([string]$Source, [string]$Destination)
    $item = Get-CbItem $Source
    if ($null -eq $item) {
        throw "Source file is missing: $Source"
    }
    Assert-CbOrdinaryItem $item 'file'
    $parent = [System.IO.Path]::GetDirectoryName((Get-CbFullPath $Destination))
    Ensure-CbSafeDirectory $parent | Out-Null
    [System.IO.File]::Copy($item.FullName, $Destination, $false)
}

function Copy-CbTreeSafe {
    param([string]$Source, [string]$Destination)
    $sourceItem = Get-CbItem $Source
    if ($null -eq $sourceItem) {
        throw "Source directory is missing: $Source"
    }
    Assert-CbOrdinaryItem $sourceItem 'tree'
    if (Test-CbExists $Destination) {
        throw "Copy destination already exists: $Destination"
    }
    Ensure-CbSafeDirectory $Destination | Out-Null
    foreach ($child in @(Get-ChildItem -LiteralPath $sourceItem.FullName -Force)) {
        Assert-CbOrdinaryItem $child 'any'
        $target = Join-Path $Destination $child.Name
        if ($child.PSIsContainer) {
            Copy-CbTreeSafe $child.FullName $target
        }
        else {
            Copy-CbFileSafe $child.FullName $target
        }
    }
}

function Initialize-CbPaths {
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        $resolvedHome = $env:HOME
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $resolvedHome = $env:USERPROFILE
    }
    else {
        throw 'HOME or USERPROFILE must be set.'
    }
    $script:HomePath = Assert-CbSafeRoot $resolvedHome 'HOME'
    $codex = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $script:HomePath '.codex' } else { $env:CODEX_HOME }
    $agents = if ([string]::IsNullOrWhiteSpace($env:AGENTS_HOME)) { Join-Path $script:HomePath '.agents' } else { $env:AGENTS_HOME }
    $script:CodexHome = Assert-CbSafeRoot $codex 'CODEX_HOME'
    $script:AgentsHome = Assert-CbSafeRoot $agents 'AGENTS_HOME'
    $script:BaselineRoot = Join-Path $script:CodexHome 'codex-baseline'
    $script:StateRoot = Join-Path $script:BaselineRoot 'state'
    $script:RuntimePath = Join-Path $script:BaselineRoot 'runtime'
    $script:TransactionsPath = Join-Path $script:StateRoot 'transactions'
    $script:CurrentPath = Join-Path $script:StateRoot 'current'
    $script:PendingPath = Join-Path $script:StateRoot 'pending'
    $script:LockPath = Join-Path $script:StateRoot 'lock'
    $script:ConfigStateRoot = Join-Path $script:StateRoot 'config'
    $script:ConfigTransactionsPath = Join-Path $script:ConfigStateRoot 'transactions'
    $script:ConfigCurrentPath = Join-Path $script:ConfigStateRoot 'current'
    $script:ConfigPendingPath = Join-Path $script:ConfigStateRoot 'pending'
    $script:CompositeTransactionsPath = Join-Path $script:ConfigStateRoot 'composite'
    $script:CompositePendingPath = Join-Path $script:ConfigStateRoot 'composite-pending'
    $script:ConfigPath = Join-Path $script:CodexHome 'config.toml'
}

function Read-CbReleaseStatus {
    param([string]$Root)
    $releaseStatusPath = Join-Path $Root 'baseline\release-status.json'
    try { $releaseStatus = (Read-CbUtf8Text $releaseStatusPath) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Release status contract is invalid JSON: $($_.Exception.Message)" }
    Assert-CbExactProperties $releaseStatus @('schema', 'contract', 'status') 'Release status contract'
    if ([int]$releaseStatus.schema -ne 1 -or
        [string]$releaseStatus.contract -ne 'codex-baseline-release-status/v1' -or
        ([string]$releaseStatus.status -ne 'stable' -and [string]$releaseStatus.status -notmatch '^rc\.[1-9][0-9]*$')) {
        throw 'Release status contract identity or status is unsupported.'
    }
    return [string]$releaseStatus.status
}

function Get-CbGlobalGuidancePath {
    param([string]$Root)
    $status = Read-CbReleaseStatus $Root
    $relative = if ($status -eq 'stable') {
        'baseline\global\AGENTS.stable.block.md'
    }
    else {
        'baseline\global\AGENTS.block.md'
    }
    $path = Join-Path $Root $relative
    $item = Get-CbItem $path
    if ($null -eq $item) { throw 'Release-specific global guidance is missing.' }
    Assert-CbOrdinaryItem $item 'file'
    return $item.FullName
}

function Read-CbManifest {
    param([string]$Root = $script:SourceRoot)
    $manifestPath = Join-Path $Root 'baseline\manifest.json'
    $manifestItem = Get-CbItem $manifestPath
    if ($null -eq $manifestItem) {
        throw "Source manifest is missing: $manifestPath"
    }
    Assert-CbOrdinaryItem $manifestItem 'file'
    try {
        $manifest = (Read-CbUtf8Text $manifestPath) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Source manifest is invalid JSON: $($_.Exception.Message)"
    }
    Assert-CbExactProperties $manifest @(
        'schema', 'version', 'minimum_codex', 'tested_codex', 'research_checked',
        'research_review_by', 'encoding', 'line_endings', 'global_block',
        'source_trust', 'payload_hash', 'payload'
    ) 'Source manifest'
    if ([int]$manifest.schema -ne $script:Schema) {
        throw "Unsupported source manifest schema: $($manifest.schema)"
    }
    $versionPath = Join-Path $Root 'VERSION'
    $version = (Read-CbUtf8Text $versionPath).Trim()
    if ($version -notmatch '^\d+(\.\d+)+$' -or $version -ne [string]$manifest.version) {
        throw 'VERSION and source manifest disagree.'
    }
    if ([string]$manifest.encoding -ne 'utf-8-no-bom') {
        throw 'The Windows installer requires the utf-8-no-bom source contract.'
    }
    if ([string]$manifest.line_endings -ne 'lf' -or
        [string]$manifest.global_block -ne 'baseline/global/AGENTS.block.md') {
        throw 'The source line-ending or global-guidance contract is unsupported.'
    }
    if ([string]$manifest.source_trust -ne 'unsigned-local-source') {
        throw 'The source trust label is missing or unsupported.'
    }
    $declaredPayloadHash = [string]$manifest.payload_hash
    if ($declaredPayloadHash -notmatch '^[0-9a-f]{64}$') {
        throw 'The aggregate source payload hash is missing or malformed.'
    }

    $actualPaths = New-Object 'System.Collections.Generic.List[string]'
    $canonicalEntries = New-Object 'System.Collections.Generic.List[string]'
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($manifest.payload)) {
        Assert-CbExactProperties $entry @('path', 'bytes', 'sha256') 'Source payload entry'
        $entryPath = [string]$entry.path
        $entryHash = [string]$entry.sha256
        if ($entryPath -notmatch '^(VERSION|baseline/[A-Za-z0-9._/-]+|scripts/[A-Za-z0-9._/-]+|benchmarks/[A-Za-z0-9._/-]+)$' -or
            $entryPath.Contains('..')) {
            throw "Unsafe payload entry: $entryPath"
        }
        if (-not $seenPaths.Add($entryPath)) {
            throw "Duplicate payload entry: $entryPath"
        }
        if (($entry.bytes -isnot [int]) -and ($entry.bytes -isnot [long])) {
            throw "Payload byte length is not an integer: $entryPath"
        }
        $entryBytes = [long]$entry.bytes
        if ($entryBytes -lt 0 -or $entryHash -notmatch '^[0-9a-f]{64}$') {
            throw "Malformed payload metadata: $entryPath"
        }
        $payloadPath = Join-Path $Root ($entryPath.Replace('/', '\'))
        $payloadItem = Get-CbItem $payloadPath
        if ($null -eq $payloadItem) {
            throw "Payload file is missing: $entryPath"
        }
        Assert-CbOrdinaryItem $payloadItem 'file'
        if ([long]$payloadItem.Length -ne $entryBytes) {
            throw "Payload byte length mismatch: $entryPath"
        }
        if ((Get-CbFileHash $payloadItem.FullName) -ne $entryHash) {
            throw "Payload hash mismatch: $entryPath"
        }
        $actualPaths.Add($entryPath) | Out-Null
        $canonicalEntries.Add(("{0}`t{1}`t{2}" -f $entryPath, $entryBytes, $entryHash)) | Out-Null
    }

    $expectedPaths = New-Object 'System.Collections.Generic.List[string]'
    $expectedPaths.Add('VERSION') | Out-Null
    Add-CbOrdinaryFilePaths (Join-Path $Root 'baseline') (Join-Path $Root 'baseline') 'baseline' $expectedPaths $manifestPath
    foreach ($scriptPath in @(
        'scripts/codex-baseline.sh', 'scripts/codex-baseline.ps1',
        'scripts/onboard.sh', 'scripts/onboard.ps1',
        'scripts/benchmark.sh', 'scripts/benchmark.ps1', 'scripts/lib/common.sh', 'scripts/lib/evaluation.sh'
    )) {
        $expectedPaths.Add($scriptPath) | Out-Null
    }
    Add-CbOrdinaryFilePaths (Join-Path $Root 'benchmarks') (Join-Path $Root 'benchmarks') 'benchmarks' $expectedPaths
    $expectedArray = [string[]]$expectedPaths.ToArray()
    $actualArray = [string[]]$actualPaths.ToArray()
    [System.Array]::Sort($expectedArray, [System.StringComparer]::Ordinal)
    [System.Array]::Sort($actualArray, [System.StringComparer]::Ordinal)
    if (($expectedArray -join "`n") -ne ($actualArray -join "`n")) {
        throw 'Source payload inventory differs from the manifest.'
    }
    $canonicalArray = [string[]]$canonicalEntries.ToArray()
    [System.Array]::Sort($canonicalArray, [System.StringComparer]::Ordinal)
    $actualPayloadHash = Get-CbStringHash (([string]::Join("`n", $canonicalArray)) + "`n")
    if ($actualPayloadHash -ne $declaredPayloadHash) {
        throw 'Aggregate source payload hash mismatch.'
    }
    Read-CbReleaseStatus $Root | Out-Null
    $operationsPath = Join-Path $Root 'baseline\operations.json'
    try { $operations = (Read-CbUtf8Text $operationsPath) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Operations contract is invalid JSON: $($_.Exception.Message)" }
    Assert-CbExactProperties $operations @(
        'schema', 'contract', 'owned_text_encoding', 'owned_line_endings',
        'transaction_states', 'object_states', 'operations', 'objects', 'reports'
    ) 'Operations contract'
    if ([int]$operations.schema -ne 1 -or [string]$operations.contract -ne 'codex-baseline-operations/v1' -or
        [string]$operations.owned_text_encoding -ne 'utf-8-no-bom' -or [string]$operations.owned_line_endings -ne 'lf') {
        throw 'Operations contract identity or encoding is unsupported.'
    }
    $expectedOperations = @('install', 'update', 'rollback', 'uninstall')
    $expectedTransactionStates = @('planned', 'prepared', 'committing', 'recovering', 'committed', 'rolled-back')
    $expectedObjectStates = @('planned', 'prepared', 'moving-old', 'old-moved', 'new-moved', 'committed', 'unchanged', 'rolled-back')
    if ((@($operations.transaction_states) -join ',') -ne ($expectedTransactionStates -join ',')) {
        throw 'Operations contract transaction-state inventory is invalid.'
    }
    if ((@($operations.object_states) -join ',') -ne ($expectedObjectStates -join ',')) {
        throw 'Operations contract object-state inventory is invalid.'
    }
    if ((@($operations.operations) -join ',') -ne ($expectedOperations -join ',')) {
        throw 'Operations contract command inventory is invalid.'
    }
    Assert-CbExactProperties $operations.reports @('doctor', 'onboarding', 'benchmark') 'Operations reports'
    if ([string]$operations.reports.doctor -ne 'codex-baseline-doctor/v1' -or
        [string]$operations.reports.onboarding -ne 'codex-baseline-onboarding/v1' -or
        [string]$operations.reports.benchmark -ne 'codex-baseline-benchmark/v1') {
        throw 'Operations contract report inventory is invalid.'
    }
    $expectedObjects = @{
        '00' = @('block', 'codex_home', 'AGENTS.active.md', 'baseline/global/AGENTS.block.md')
        '10' = @('tree', 'agents_home', 'skills/codex-baseline-repo-onboarding', 'baseline/skills/codex-baseline-repo-onboarding')
        '11' = @('tree', 'agents_home', 'skills/codex-baseline-deep-work', 'baseline/skills/codex-baseline-deep-work')
        '12' = @('tree', 'agents_home', 'skills/codex-baseline-conformance-review', 'baseline/skills/codex-baseline-conformance-review')
        '13' = @('tree', 'agents_home', 'skills/codex-baseline-retrospective', 'baseline/skills/codex-baseline-retrospective')
        '20' = @('file', 'codex_home', 'agents/codex-baseline-reviewer.toml', 'baseline/agents/codex-baseline-reviewer.toml')
        '30' = @('tree', 'codex_home', 'codex-baseline/runtime', 'generated/runtime')
        '31' = @('file', 'home', '.local/bin/codex-baseline{platform-extension}', 'generated/wrapper')
    }
    if (@($operations.objects).Count -ne $expectedObjects.Count) { throw 'Operations contract object count is invalid.' }
    $seenOperationObjectIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($object in @($operations.objects)) {
        Assert-CbExactProperties $object @('id', 'kind', 'root', 'destination', 'source') 'Operations object'
        $id = [string]$object.id
        if (-not $expectedObjects.ContainsKey($id)) { throw "Operations contract object id is invalid: $id" }
        if (-not $seenOperationObjectIds.Add($id)) { throw "Operations contract object id is duplicated: $id" }
        $actual = @([string]$object.kind, [string]$object.root, [string]$object.destination, [string]$object.source)
        if (($actual -join "`n") -ne (@($expectedObjects[$id]) -join "`n")) {
            throw "Operations contract object differs from the native implementation: $id"
        }
    }
    if ($seenOperationObjectIds.Count -ne $expectedObjects.Count) { throw 'Operations contract object inventory is incomplete.' }
    $configOperationsPath = Join-Path $Root 'baseline\config-operations.json'
    try { $configOperations = (Read-CbUtf8Text $configOperationsPath) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Config operations contract is invalid JSON: $($_.Exception.Message)" }
    if ([int]$configOperations.schema -ne 2 -or [string]$configOperations.contract -ne 'codex-baseline-config-operations/v2' -or
        [string]$configOperations.core_operations_compat -ne 'codex-baseline-operations/v1' -or
        [string]$configOperations.object_type -ne 'toml-keys' -or [string]$configOperations.native_validation -ne 'isolated-sanitized-CODEX_HOME' -or
        (@($configOperations.operations) -join ',') -ne 'install-cap,optimize,restore,rollback,uninstall' -or
        [string]$configOperations.reports.doctor -ne 'codex-baseline-doctor/v2' -or
        [string]$configOperations.reports.onboarding -ne 'codex-baseline-onboarding/v2' -or
        [string]$configOperations.reports.benchmark -ne 'codex-baseline-benchmark/v2' -or
        [string]$configOperations.reports.optimize -ne 'codex-baseline-optimize/v1') {
        throw 'Config operations contract identity or inventory is unsupported.'
    }
    return $manifest
}

function Write-CbSourceProvenance {
    param($Manifest, [string]$SourceRoot = $script:SourceRoot, [string]$Acquisition = 'local-checkout')
    # Lifecycle provenance is payload-manifest based. Never ask checkout-owned
    # Git metadata for informational revision/dirty fields: status/content
    # conversion may execute repository-local filters before acknowledgement.
    Write-Output ("source-origin: {0}" -f $SourceRoot)
    Write-Output 'source-revision: unversioned'
    Write-Output 'source-dirty: unknown'
    Write-Output 'source-trust: unverified-source (unsigned-local-source)'
    Write-Output ("source-acquisition: {0}" -f $Acquisition)
    Write-Output ("source-payload-sha256: {0}" -f [string]$Manifest.payload_hash)
}

function Get-CbTransactionPath {
    param([string]$Id)
    if ($Id -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{32}$') {
        throw "Invalid transaction identifier: $Id"
    }
    return Join-Path $script:TransactionsPath $Id
}

function Write-CbTransaction {
    param($Transaction)
    $path = Join-Path (Get-CbTransactionPath ([string]$Transaction.Id)) 'transaction.json'
    $text = $Transaction | ConvertTo-Json -Depth 12
    Write-CbUtf8Atomic $path ($text + "`n")
}

function Read-CbTransaction {
    param([string]$Id)
    $path = Join-Path (Get-CbTransactionPath $Id) 'transaction.json'
    if (-not (Test-CbExists $path)) {
        throw "Transaction journal is missing: $Id"
    }
    try {
        $transaction = (Read-CbUtf8Text $path) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Transaction journal is invalid: $Id"
    }
    if ([int]$transaction.Schema -ne $script:Schema -or [string]$transaction.Id -ne $Id) {
        throw "Transaction journal identity mismatch: $Id"
    }
    return $transaction
}

function Read-CbPointer {
    param([string]$Path)
    if (-not (Test-CbExists $Path)) {
        return $null
    }
    $value = (Read-CbUtf8Text $Path).Trim()
    if ($value -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{32}$') {
        throw "Invalid state pointer in $Path"
    }
    return $value
}

function Write-CbPointer {
    param([string]$Path, [string]$Id)
    Write-CbUtf8Atomic $Path ($Id + "`n")
}

function Get-CbCurrentTransaction {
    $id = Read-CbPointer $script:CurrentPath
    if ($null -eq $id) {
        return $null
    }
    $transaction = Read-CbTransaction $id
    Assert-CbTransactionShape $transaction $true
    if ([string]$transaction.State -ne 'committed') {
        throw "The current transaction is not committed: $id"
    }
    return $transaction
}

function Assert-CbExactProperties {
    param($Value, [string[]]$Expected, [string]$Label)
    if ($null -eq $Value -or $null -eq $Value.PSObject) {
        throw "$Label is not an object."
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $Expected) {
        if ($name -notin $actual) { throw "$Label is missing property $name."
        }
    }
    foreach ($name in $actual) {
        if ($name -notin $Expected) { throw "$Label contains unexpected property $name."
        }
    }
}

function Assert-CbBooleanProperty {
    param($Object, [string]$Name, [string]$Label)
    if (-not ($Object.$Name -is [bool])) { throw "$Label property $Name must be a JSON boolean." }
}

function Assert-CbHashValue {
    param([AllowNull()]$Value, [string]$Label, [bool]$AllowNull)
    if ($null -eq $Value) {
        if ($AllowNull) { return }
        throw "$Label cannot be null."
    }
    if (-not ($Value -is [string]) -or ($Value -ne 'absent' -and $Value -notmatch '^[0-9a-f]{64}$')) {
        throw "$Label is not a valid SHA-256 or absent marker."
    }
}

function Assert-CbTransactionShape {
    param($Transaction, [bool]$RequireComplete)
    Assert-CbExactProperties $Transaction @(
        'Schema', 'Id', 'Operation', 'Version', 'CreatedUtc', 'ParentTransaction',
        'ResultCurrent', 'State', 'Objects'
    ) 'Transaction'
    if ((-not ($Transaction.Schema -is [int])) -and (-not ($Transaction.Schema -is [long]))) {
        throw 'Transaction schema must be the supported JSON integer.'
    }
    if ([int64]$Transaction.Schema -ne [int64]$script:Schema) {
        throw 'Transaction schema must be the supported JSON integer.'
    }
    if (-not ($Transaction.Id -is [string]) -or [string]$Transaction.Id -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{32}$') {
        throw 'Transaction id is invalid.'
    }
    if (-not ($Transaction.Operation -is [string]) -or [string]$Transaction.Operation -notin @('install', 'update', 'rollback', 'uninstall')) {
        throw 'Transaction operation is invalid.'
    }
    if (-not ($Transaction.Version -is [string]) -or [string]$Transaction.Version -notmatch '^\d+(\.\d+)+$') {
        throw 'Transaction version is invalid.'
    }
    $created = [DateTime]::MinValue
    if($Transaction.CreatedUtc-is[DateTime]){$created=$Transaction.CreatedUtc}
    elseif(-not($Transaction.CreatedUtc-is[string])-or-not[DateTime]::TryParse([string]$Transaction.CreatedUtc,[ref]$created)){throw 'Transaction CreatedUtc is invalid.'}
    foreach ($pointerName in @('ParentTransaction', 'ResultCurrent')) {
        $pointer = $Transaction.$pointerName
        if ($null -ne $pointer -and (-not ($pointer -is [string]) -or $pointer -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{32}$' -and $pointer -ne '__SELF__')) {
            throw "Transaction $pointerName is invalid."
        }
    }
    if (-not ($Transaction.State -is [string]) -or [string]$Transaction.State -notin @('planned', 'prepared', 'committing', 'committed', 'recovering', 'rolled-back')) {
        throw 'Transaction state is invalid.'
    }
    $agentsTarget = Get-CbAgentsFile
    $expected = @{
        '00' = @('block', $agentsTarget)
        '10' = @('tree', (Join-Path $script:AgentsHome 'skills\codex-baseline-repo-onboarding'))
        '11' = @('tree', (Join-Path $script:AgentsHome 'skills\codex-baseline-deep-work'))
        '12' = @('tree', (Join-Path $script:AgentsHome 'skills\codex-baseline-conformance-review'))
        '13' = @('tree', (Join-Path $script:AgentsHome 'skills\codex-baseline-retrospective'))
        '20' = @('file', (Join-Path $script:CodexHome 'agents\codex-baseline-reviewer.toml'))
        '30' = @('tree', $script:RuntimePath)
        '31' = @('file', (Join-Path $script:HomePath '.local\bin\codex-baseline.ps1'))
    }
    $objects = @($Transaction.Objects)
    if ($RequireComplete -and $objects.Count -ne $expected.Count) {
        throw "The current transaction has an invalid object count: $($objects.Count)"
    }
    $seen = @{}
    foreach ($object in $objects) {
        Assert-CbExactProperties $object @(
            'Id', 'Kind', 'Target', 'Source', 'SourcePath', 'DesiredHash',
            'DesiredPhysicalHash', 'DesiredPresent', 'PreviousHash',
            'PreviousPhysicalHash', 'PreviousKind', 'PreviousExisted',
            'PreviousManagedExisted', 'Change', 'Status', 'Stage', 'Old',
            'Backup', 'BackupHash', 'PhysicalBackup', 'PhysicalBackupHash',
            'BlockWholeFileSource', 'InstalledHash', 'InstalledPhysicalHash'
        ) 'Transaction object'
        $id = [string]$object.Id
        if (-not $expected.ContainsKey($id) -or $seen.ContainsKey($id)) {
            throw "Transaction contains an unknown or duplicate object id: $id"
        }
        $seen[$id] = $true
        if ([string]$object.Kind -ne [string]$expected[$id][0] -or
            -not (Test-CbSamePath ([string]$object.Target) ([string]$expected[$id][1]))) {
            throw "Transaction object ownership is invalid: $id"
        }
        if (-not ($object.Id -is [string]) -or -not ($object.Kind -is [string]) -or
            -not ($object.Target -is [string]) -or -not ($object.Source -is [string]) -or
            $object.Source.Length -gt 256) {
            throw "Transaction object has invalid string fields: $id"
        }
        if ($null -ne $object.SourcePath -and -not ($object.SourcePath -is [string])) {
            throw "Transaction object SourcePath must be a string or null: $id"
        }
        foreach ($booleanName in @('DesiredPresent', 'PreviousExisted', 'PreviousManagedExisted', 'Change', 'BlockWholeFileSource')) {
            Assert-CbBooleanProperty $object $booleanName "Transaction object $id"
        }
        if (-not ($object.Status -is [string]) -or [string]$object.Status -notin @('planned', 'prepared', 'moving-old', 'old-moved', 'new-moved', 'committed', 'unchanged', 'rolled-back')) {
            throw "Transaction object has invalid status: $id"
        }
        if (-not ($object.PreviousKind -is [string]) -or [string]$object.PreviousKind -notin @('absent', 'file', 'tree', 'block')) {
            throw "Transaction object has invalid PreviousKind: $id"
        }
        if ($object.Kind -eq 'block' -and $object.PreviousKind -ne 'block') {
            throw "Block object has an invalid PreviousKind: $id"
        }
        foreach ($hashName in @('DesiredHash', 'PreviousHash', 'PreviousPhysicalHash')) {
            Assert-CbHashValue $object.$hashName "Transaction object $id $hashName" $false
        }
        foreach ($hashName in @('DesiredPhysicalHash', 'BackupHash', 'PhysicalBackupHash', 'InstalledHash', 'InstalledPhysicalHash')) {
            Assert-CbHashValue $object.$hashName "Transaction object $id $hashName" $true
        }
        $objectDirectory = Join-Path (Join-Path (Get-CbTransactionPath ([string]$Transaction.Id)) 'objects') $id
        Assert-CbExistingAncestorsSafe $objectDirectory
        $expectedStage = Join-Path ([System.IO.Path]::GetDirectoryName([string]$object.Target)) ('.codex-baseline-stage-{0}-{1}' -f $Transaction.Id, $id)
        $expectedOld = Join-Path ([System.IO.Path]::GetDirectoryName([string]$object.Target)) ('.codex-baseline-old-{0}-{1}' -f $Transaction.Id, $id)
        foreach ($pathName in @('Stage', 'Old')) {
            $pathValue = $object.$pathName
            if ($null -ne $pathValue -and -not ($pathValue -is [string])) {
                throw "Transaction object $pathName must be a string or null: $id"
            }
        }
        if ($null -ne $object.Stage -and -not (Test-CbSamePath ([string]$object.Stage) $expectedStage)) {
            throw "Transaction stage path is not exactly derived: $id"
        }
        if ($null -ne $object.Old -and -not (Test-CbSamePath ([string]$object.Old) $expectedOld)) {
            throw "Transaction old path is not exactly derived: $id"
        }
        if ($object.Status -in @('prepared', 'moving-old', 'old-moved', 'new-moved', 'committed', 'rolled-back') -and
            ($null -eq $object.Stage -or $null -eq $object.Old)) {
            throw "Transaction stage/old paths are missing for status $($object.Status): $id"
        }
        foreach ($pathName in @('Backup', 'PhysicalBackup')) {
            $pathValue = $object.$pathName
            if ($null -ne $pathValue -and -not ($pathValue -is [string])) {
                throw "Transaction object $pathName must be a string or null: $id"
            }
        }
        if ($null -ne $object.Backup -and -not (Test-CbSamePath ([string]$object.Backup) (Join-Path $objectDirectory 'backup'))) {
            throw "Transaction backup path escaped its journal: $id"
        }
        if ($null -ne $object.PhysicalBackup -and -not (Test-CbSamePath ([string]$object.PhysicalBackup) (Join-Path $objectDirectory 'backup-full'))) {
            throw "Transaction physical backup path escaped its journal: $id"
        }
        foreach ($managedPath in @($object.Target, $object.Stage, $object.Old, $object.Backup, $object.PhysicalBackup)) {
            if ($null -eq $managedPath) { continue }
            Assert-CbExistingAncestorsSafe ([System.IO.Path]::GetDirectoryName([string]$managedPath))
            $managedItem = Get-CbItem ([string]$managedPath)
            if ($null -ne $managedItem) { Assert-CbOrdinaryItem $managedItem 'any' }
        }
        if ($RequireComplete -and $object.Status -notin @('committed', 'unchanged')) {
            throw "Current transaction object is not complete: $id"
        }
        if ($RequireComplete) {
            if ([bool]$object.Change -and [string]$object.Status -ne 'committed') {
                throw "Current transaction change/status mismatch: $id"
            }
            if (-not [bool]$object.Change -and [string]$object.Status -ne 'unchanged') {
                throw "Current transaction change/status mismatch: $id"
            }
        }
    }
}

function Assert-CbExactObjectIds {
    param($Transaction, [string[]]$ExpectedIds, [string]$Label)
    $actualIds = @($Transaction.Objects | ForEach-Object { [string]$_.Id } | Sort-Object)
    $expected = @($ExpectedIds | Sort-Object)
    if ($actualIds.Count -ne $expected.Count -or
        ($actualIds -join ',') -ne ($expected -join ',')) {
        throw "$Label has an incomplete object inventory."
    }
}

function Find-CbObjectByTarget {
    param($Transaction, [string]$Target)
    if ($null -eq $Transaction) {
        return $null
    }
    foreach ($object in @($Transaction.Objects)) {
        if (Test-CbSamePath ([string]$object.Target) $Target) {
            return $object
        }
    }
    return $null
}

function New-CbId {
    return ('{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N'))
}

function New-CbTransaction {
    param([string]$Operation, [string]$Version, [AllowNull()][string]$ParentTransaction)
    $id = New-CbId
    $directory = Get-CbTransactionPath $id
    Ensure-CbSafeDirectory (Join-Path $directory 'objects') | Out-Null
    $transaction = [pscustomobject]@{
        Schema = $script:Schema
        Id = $id
        Operation = $Operation
        Version = $Version
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        ParentTransaction = $(if ([string]::IsNullOrWhiteSpace($ParentTransaction)) { $null } else { $ParentTransaction })
        ResultCurrent = $id
        State = 'planned'
        Objects = @()
    }
    Write-CbTransaction $transaction
    return $transaction
}

function New-CbObject {
    param(
        [string]$Id,
        [string]$Kind,
        [string]$Target,
        [string]$DesiredHash,
        [bool]$DesiredPresent,
        [AllowNull()][string]$SourcePath,
        [string]$SourceLabel,
        $CurrentTransaction
    )
    $targetFull = Get-CbFullPath $Target
    Assert-CbExistingAncestorsSafe ([System.IO.Path]::GetDirectoryName($targetFull))
    $live = Get-CbLiveHash $Kind $targetFull
    $physical = Get-CbPhysicalHash $targetFull
    $actualKind = Get-CbKind $targetFull
    $owner = Find-CbObjectByTarget $CurrentTransaction $targetFull
    if ($null -ne $owner) {
        if ($live -ne [string]$owner.InstalledHash) {
            throw "Managed content drifted; refusing to overwrite: $targetFull"
        }
    }
    elseif ($Kind -eq 'block') {
        if ($live -ne 'absent') {
            throw "An unowned codex-baseline marker exists: $targetFull"
        }
    }
    elseif ($live -ne 'absent') {
        throw "An unowned target exists: $targetFull"
    }
    return [pscustomobject]@{
        Id = $Id
        Kind = $Kind
        Target = $targetFull
        Source = $SourceLabel
        SourcePath = $SourcePath
        DesiredHash = $DesiredHash
        DesiredPhysicalHash = $null
        DesiredPresent = $DesiredPresent
        PreviousHash = $live
        PreviousPhysicalHash = $physical
        PreviousKind = $(if ($Kind -eq 'block') { 'block' } else { $actualKind })
        PreviousExisted = ($actualKind -ne 'absent')
        PreviousManagedExisted = ($Kind -eq 'block' -and $live -ne 'absent')
        Change = ($live -ne $DesiredHash -or (($actualKind -ne 'absent') -ne $DesiredPresent))
        Status = 'planned'
        Stage = $null
        Old = $null
        Backup = $null
        BackupHash = $null
        PhysicalBackup = $null
        PhysicalBackupHash = $null
        BlockWholeFileSource = $false
        InstalledHash = $null
        InstalledPhysicalHash = $null
    }
}

function Get-CbAgentsFile {
    $override = Join-Path $script:CodexHome 'AGENTS.override.md'
    $normal = Join-Path $script:CodexHome 'AGENTS.md'
    $overrideItem = Get-CbItem $override
    $normalItem = Get-CbItem $normal
    if ($null -ne $overrideItem) { Assert-CbOrdinaryItem $overrideItem 'file' }
    if ($null -ne $normalItem) { Assert-CbOrdinaryItem $normalItem 'file' }
    $overrideNonEmpty = $null -ne $overrideItem -and $overrideItem.Length -gt 0
    $normalNonEmpty = $null -ne $normalItem -and $normalItem.Length -gt 0
    if ($overrideNonEmpty -and $normalNonEmpty) {
        throw 'Both global AGENTS.override.md and AGENTS.md are non-empty; select the intended active file first.'
    }
    if ($overrideNonEmpty) {
        return $override
    }
    return $normal
}

function Initialize-CbNativeDirectoryIdentity {
    if ($null -ne ('CodexBaseline.InstallerNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexBaseline {
    public static class InstallerNative {
        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME { public uint Low; public uint High; }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public FILETIME CreationTime;
            public FILETIME LastAccessTime;
            public FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string path, uint access, uint share, IntPtr security,
            uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION information);

        public static string GetDirectoryIdentity(string path) {
            const uint OPEN_EXISTING = 3;
            const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
            const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
            using (SafeFileHandle handle = CreateFileW(
                path, 0, 7, IntPtr.Zero, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero)) {
                if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                BY_HANDLE_FILE_INFORMATION information;
                if (!GetFileInformationByHandle(handle, out information)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return String.Format("{0:X8}:{1:X8}:{2:X8}",
                    information.VolumeSerialNumber,
                    information.FileIndexHigh,
                    information.FileIndexLow);
            }
        }
    }
}
'@
}

function Get-CbDirectoryIdentity {
    param([string]$Path)
    Initialize-CbNativeDirectoryIdentity
    return [CodexBaseline.InstallerNative]::GetDirectoryIdentity((Get-CbFullPath $Path))
}

function New-CbPrivateDirectorySecurity {
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $currentSid) { throw 'Cannot determine the current Windows user SID.' }
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($currentSid)
    foreach ($sidText in @($currentSid.Value) + $script:TrustedPrivateDirectorySids) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule) | Out-Null
    }
    return $security
}

function New-CbPrivateDirectory {
    param([string]$Path, [System.Security.AccessControl.DirectorySecurity]$Security)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return [System.IO.FileSystemAclExtensions]::CreateDirectory($Security, $Path)
    }
    return [System.IO.Directory]::CreateDirectory($Path, $Security)
}

function Get-CbAclRuleSid {
    param($Rule)
    try {
        if ($Rule.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
            return $Rule.IdentityReference.Value
        }
        return $Rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw "Cannot resolve an ACL identity for a private temporary path: $($Rule.IdentityReference)"
    }
}

function Get-CbDirectorySecurity {
    param([System.IO.DirectoryInfo]$Directory)
    $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor
        [System.Security.AccessControl.AccessControlSections]::Owner
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return [System.IO.FileSystemAclExtensions]::GetAccessControl($Directory, $sections)
    }
    return $Directory.GetAccessControl($sections)
}

function Assert-CbPrivatePathComponent {
    param(
        [string]$Path,
        [string[]]$TrustedOwnerSids,
        [string[]]$TrustedAccessSids,
        [System.Security.AccessControl.FileSystemRights]$UntrustedRights,
        [switch]$RequireProtected,
        [switch]$RequireCurrentUserOwner,
        [switch]$RequireCurrentUserFullControl
    )
    $item = Get-CbItem $Path
    if ($null -eq $item) { throw "Private temporary path is missing: $Path" }
    Assert-CbOrdinaryItem $item 'tree'
    $acl = Get-CbDirectorySecurity ([System.IO.DirectoryInfo]$item)
    $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($ownerSid -notin $TrustedOwnerSids) {
        throw "Private temporary path has an untrusted owner: $($item.FullName) ($ownerSid)"
    }
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($RequireCurrentUserOwner -and $ownerSid -ne $currentSid) {
        throw "Private temporary directory owner changed: $($item.FullName) ($ownerSid)"
    }
    if ($RequireProtected -and -not $acl.AreAccessRulesProtected) {
        throw "Private temporary directory inherits access rules: $($item.FullName)"
    }
    $currentHasFullControl = $false
    $accessRules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    foreach ($rule in @($accessRules)) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        $sid = Get-CbAclRuleSid $rule
        if ($sid -notin $TrustedAccessSids -and ($rule.FileSystemRights -band $UntrustedRights) -ne 0) {
            throw "Private temporary path grants mutation rights to an untrusted SID: $($item.FullName) ($sid)"
        }
        if ($sid -eq $currentSid -and
            ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
                [System.Security.AccessControl.FileSystemRights]::FullControl) {
            $currentHasFullControl = $true
        }
    }
    if ($RequireCurrentUserFullControl -and -not $currentHasFullControl) {
        throw "Private temporary directory does not grant the current user full control: $($item.FullName)"
    }
}

function Assert-CbPrivateDirectory {
    param([string]$Path)
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trustedSids = @($currentSid) + $script:TrustedPrivateDirectorySids
    $mutationRights = [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    Assert-CbExistingAncestorsSafe $Path
    Assert-CbPrivatePathComponent $Path $trustedSids $trustedSids $mutationRights -RequireProtected -RequireCurrentUserOwner -RequireCurrentUserFullControl
}

function Assert-CbPrivateTemporaryRoot {
    param([string]$Path)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $trustedAccessSids = @($identity.User.Value) + $script:TrustedPrivateDirectorySids
    $trustedOwnerSids = @(
        $identity.User.Value,
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    $escalationRights = [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    Assert-CbExistingAncestorsSafe $Path
    $cursor = Get-CbFullPath $Path
    while ($true) {
        Assert-CbPrivatePathComponent $cursor $trustedOwnerSids $trustedAccessSids (
            [System.Security.AccessControl.FileSystemRights]::Delete -bor
                [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
                $escalationRights
        )
        $parent = [System.IO.Directory]::GetParent($cursor)
        if ($null -eq $parent -or (Test-CbSamePath $parent.FullName $cursor)) { break }
        Assert-CbPrivatePathComponent $parent.FullName $trustedOwnerSids $trustedAccessSids (
            [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor $escalationRights
        )
        $cursor = $parent.FullName
    }
}

function New-CbTemporaryDirectory {
    $temporaryRoot = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } else { $env:USERPROFILE }
    Assert-CbRawLocalRootPath $temporaryRoot 'Windows private staging root'
    $temporaryRoot = Get-CbFullPath $temporaryRoot
    $temporaryRootItem = Get-CbItem $temporaryRoot
    if ($null -eq $temporaryRootItem) { throw "Windows private staging root is missing: $temporaryRoot" }
    Assert-CbOrdinaryItem $temporaryRootItem 'tree'
    Assert-CbPrivateTemporaryRoot $temporaryRoot
    $path = Join-Path $temporaryRoot ('codex-baseline-{0}' -f [guid]::NewGuid().ToString('N'))
    New-CbPrivateDirectory $path (New-CbPrivateDirectorySecurity) | Out-Null
    Assert-CbPrivateDirectory $path
    return $path
}

function Test-CbUpdateUriAllowed {
    param([uri]$Uri)
    if ($Uri.Scheme -ne 'https' -or -not $Uri.IsDefaultPort) { return $false }
    return @('github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com') -contains $Uri.DnsSafeHost.ToLowerInvariant()
}

function Copy-CbUpdateInput {
    param([string]$Source, [string]$Destination, [long]$MaximumBytes)
    $item = Get-CbItem $Source
    if ($null -eq $item) { throw "Update input is missing: $Source" }
    Assert-CbOrdinaryItem $item 'file'
    if ($env:CODEX_BASELINE_TESTING -eq '1' -and $env:CODEX_BASELINE_TEST_GROW_UPDATE_INPUT -eq '1') {
        $grow = New-Object System.IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $grow.SetLength($MaximumBytes + 1) } finally { $grow.Dispose() }
    }
    $input = New-Object System.IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($env:CODEX_BASELINE_TESTING -eq '1' -and $env:CODEX_BASELINE_TEST_SUBSTITUTE_UPDATE_INPUT -eq '1') {
            $moved = $item.FullName + '.replacement-race'
            try {
                [System.IO.File]::Move($item.FullName, $moved)
                [System.IO.File]::Move($moved, $item.FullName)
                throw 'Update input replacement unexpectedly succeeded while the source handle was frozen.'
            }
            catch [System.IO.IOException] {
                throw 'Update input replacement was blocked while the source handle was frozen.'
            }
        }
        $openedItem = Get-CbItem $Source
        if ($null -eq $openedItem) { throw 'Update input changed before it could be frozen.' }
        Assert-CbOrdinaryItem $openedItem 'file'
        if ([long]$input.Length -ne [long]$openedItem.Length) { throw 'Update input identity or length changed before it could be frozen.' }
        if ([long]$input.Length -gt $MaximumBytes) { throw 'Update input exceeded its byte limit while it was frozen.' }
        $output = New-Object System.IO.FileStream($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
        $buffer = New-Object byte[] 65536
        [long]$total = 0
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaximumBytes) { throw 'Update input exceeded its byte limit while it was frozen.' }
            $output.Write($buffer, 0, $read)
        }
        $output.Flush($true)
        }
        finally { $output.Dispose() }
    }
    finally { $input.Dispose() }
}

function Receive-CbUpdateUrl {
    param([uri]$Uri, [string]$Destination, [long]$MaximumBytes)
    $current = $Uri
    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        for ($redirects = 0; $redirects -le 3; $redirects++) {
            if (-not (Test-CbUpdateUriAllowed $current)) {
                throw "Update redirect host or scheme is not allowed: $current"
            }
            $requestClock = [Diagnostics.Stopwatch]::StartNew()
            $request = [System.Net.HttpWebRequest]::CreateHttp($current)
            $request.Method = 'GET'
            $request.AllowAutoRedirect = $false
            $request.Timeout = 10000
            $request.ReadWriteTimeout = 60000
            $request.UserAgent = 'codex-baseline-update/1'
            $request.PreAuthenticate = $false
            $request.UseDefaultCredentials = $false
            $request.Credentials = $null
            $pendingResponse = $null
            try {
                $pendingResponse = $request.BeginGetResponse($null, $null)
                if (-not $pendingResponse.AsyncWaitHandle.WaitOne(10000)) {
                    $request.Abort()
                    throw "Update connection/response-header timeout for $current"
                }
                $response = [System.Net.HttpWebResponse]$request.EndGetResponse($pendingResponse)
            }
            catch [System.Net.WebException] {
                if ($null -eq $_.Exception.Response) { throw "Update download failed for $current`: $($_.Exception.Message)" }
                $response = [System.Net.HttpWebResponse]$_.Exception.Response
            }
            finally {
                if ($null -ne $pendingResponse) { $pendingResponse.AsyncWaitHandle.Close() }
            }
            try {
                $status = [int]$response.StatusCode
                if ($status -eq 200) {
                    if ($response.ContentLength -gt $MaximumBytes) { throw 'Update response exceeded its byte limit.' }
                    $input = $response.GetResponseStream()
                    $output = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $buffer = New-Object byte[] 65536
                        [long]$total = 0
                        while ($true) {
                            $remaining = 60000 - [long]$requestClock.ElapsedMilliseconds
                            if ($remaining -le 0) {
                                $request.Abort()
                                throw "Update request exceeded 60 seconds for $current"
                            }
                            $readTask = $input.ReadAsync($buffer, 0, $buffer.Length)
                            if (-not $readTask.Wait([int]$remaining)) {
                                $request.Abort()
                                throw "Update request exceeded 60 seconds for $current"
                            }
                            $read = $readTask.Result
                            if ($read -le 0) { break }
                            $total += $read
                            if ($total -gt $MaximumBytes) { throw 'Update response exceeded its byte limit.' }
                            $output.Write($buffer, 0, $read)
                        }
                        $output.Flush($true)
                    }
                    finally {
                        $output.Dispose()
                        $input.Dispose()
                    }
                    return
                }
                if ($status -notin @(301, 302, 303, 307, 308)) { throw "Update download returned HTTP $status for $current" }
                if ($redirects -ge 3) { throw 'Update download exceeded three redirects.' }
                $location = $response.Headers['Location']
                if ([string]::IsNullOrWhiteSpace($location)) { throw 'Update redirect has no Location header.' }
                $next = $null
                if (-not [uri]::TryCreate($location, [UriKind]::Absolute, [ref]$next) -or -not (Test-CbUpdateUriAllowed $next)) {
                    throw "Update redirect host or scheme is not allowed: $location"
                }
                $current = $next
            }
            finally { $response.Dispose() }
        }
        throw 'Update download exceeded three redirects.'
    }
    finally { [Net.ServicePointManager]::SecurityProtocol = $oldProtocol }
}

function Read-CbUpdateDescriptor {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 1 -or $bytes.Length -gt 16384 -or $bytes[$bytes.Length - 1] -ne 10) {
        throw 'Update descriptor size or LF termination is invalid.'
    }
    foreach ($byte in $bytes) {
        if ($byte -ne 10 -and ($byte -lt 32 -or $byte -gt 126)) {
            throw 'Update descriptor contains non-ASCII or control bytes.'
        }
    }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $lines = @($text.Substring(0, $text.Length - 1).Split("`n"))
    if ($lines.Count -ne 10 -or $lines[0] -ne 'contract=codex-baseline-update/v1') {
        throw 'Update descriptor contract or line count is invalid.'
    }
    $values = @()
    $names = @('version', 'tag', 'trust', 'tar_name', 'tar_bytes', 'tar_sha256', 'zip_name', 'zip_bytes', 'zip_sha256')
    for ($index = 0; $index -lt $names.Count; $index++) {
        $prefix = $names[$index] + '='
        if (-not $lines[$index + 1].StartsWith($prefix, [StringComparison]::Ordinal)) {
            throw 'Update descriptor field order or names are invalid.'
        }
        $values += $lines[$index + 1].Substring($prefix.Length)
    }
    $version = [string]$values[0]
    if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        [string]$values[1] -ne "v$version" -or [string]$values[2] -ne 'unsigned-github-release') {
        throw 'Update descriptor version/tag/trust binding is invalid.'
    }
    if ([string]$values[3] -ne "codex-baseline-$version.tar.gz" -or
        [string]$values[6] -ne "codex-baseline-$version.zip") {
        throw 'Update descriptor asset name is invalid.'
    }
    [long]$tarBytes = 0
    [long]$zipBytes = 0
    if (-not [long]::TryParse([string]$values[4], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$tarBytes) -or
        -not [long]::TryParse([string]$values[7], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$zipBytes) -or
        $tarBytes -lt 1 -or $zipBytes -lt 1 -or $tarBytes -gt $script:UpdateMaxArchiveBytes -or $zipBytes -gt $script:UpdateMaxArchiveBytes) {
        throw 'Update descriptor asset size is invalid.'
    }
    if ([string]$values[5] -notmatch '^[0-9a-f]{64}$' -or [string]$values[8] -notmatch '^[0-9a-f]{64}$') {
        throw 'Update descriptor asset SHA-256 is invalid.'
    }
    return [pscustomobject]@{
        Version = $version; Tag = [string]$values[1]; Trust = [string]$values[2]
        TarName = [string]$values[3]; TarBytes = $tarBytes; TarSha256 = [string]$values[5]
        ZipName = [string]$values[6]; ZipBytes = $zipBytes; ZipSha256 = [string]$values[8]
    }
}

function Assert-CbUpdateMemberName {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9._/-]+$' -or $Name.StartsWith('/') -or $Name.Contains('//') -or
        [Text.Encoding]::ASCII.GetByteCount($Name) -gt 240) {
        throw "Unsafe update archive path: $Name"
    }
    $trimmed = $Name.TrimEnd('/')
    $segments = @($trimmed.Split('/'))
    if ($segments.Count -gt 8) { throw "Update archive path is too deep: $Name" }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or
            $segment.Contains(':') -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment.Equals('.git', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe update archive path segment: $Name"
        }
        $base = $segment.Split('.')[0].ToUpperInvariant()
        if ($base -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "Windows device name is forbidden in update archive: $Name"
        }
    }
}

function Expand-CbUpdateZip {
    param([string]$Archive, [string]$ExtractRoot, [string]$ExpectedVersion = '')
    Add-Type -AssemblyName System.IO.Compression
    $stream = New-Object System.IO.FileStream($Archive, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try { $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false) }
    catch { $stream.Dispose(); throw }
    try {
        if ($zip.Entries.Count -lt 1 -or $zip.Entries.Count -gt 512) { throw 'Update archive entry count is invalid.' }
        $ordinal = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $folded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$total = 0
        $root = $null
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName
            Assert-CbUpdateMemberName $name
            if (-not $ordinal.Add($name) -or -not $folded.Add($name)) { throw "Duplicate or case-colliding update archive member: $name" }
            $memberRoot = $name.TrimEnd('/').Split('/')[0]
            if ($null -eq $root) { $root = $memberRoot }
            if ($memberRoot -ne $root) { throw 'Update archive must contain one top-level source root.' }
            $isDirectory = $name.EndsWith('/')
            $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
            $unixType = ($attributes -shr 16) -band 0xF000
            if (($isDirectory -and $unixType -notin @(0, 0x4000)) -or
                (-not $isDirectory -and $unixType -notin @(0, 0x8000))) {
                throw "Linked or special update archive member is forbidden: $name"
            }
            if (-not $isDirectory) {
                $total += [long]$entry.Length
                if ($total -gt $script:UpdateMaxContentBytes) { throw 'Update archive uncompressed content exceeds 128 MiB.' }
            }
        }
        if ($root -notmatch '^codex-baseline-((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$') {
            throw 'Update archive root has an invalid version.'
        }
        $archiveVersion = [string]$Matches[1]
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $archiveVersion -ne $ExpectedVersion) {
            throw 'Update descriptor and archive root version disagree.'
        }
        Ensure-CbSafeDirectory $ExtractRoot | Out-Null
        $prefix = (Get-CbFullPath $ExtractRoot).TrimEnd('\') + '\'
        [long]$writtenTotal = 0
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName
            $destination = Get-CbFullPath (Join-Path $ExtractRoot ($name.Replace('/', '\')))
            if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Update archive escaped extraction root: $name" }
            if ($name.EndsWith('/')) {
                Ensure-CbSafeDirectory $destination | Out-Null
                continue
            }
            Ensure-CbSafeDirectory ([IO.Path]::GetDirectoryName($destination)) | Out-Null
            $input = $entry.Open()
            $output = New-Object System.IO.FileStream($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] 65536
                [long]$writtenEntry = 0
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $writtenEntry += $read
                    $writtenTotal += $read
                    if ($writtenEntry -gt [long]$entry.Length -or $writtenTotal -gt $script:UpdateMaxContentBytes) {
                        throw "Update archive member exceeded its declared or total content limit: $name"
                    }
                    $output.Write($buffer, 0, $read)
                }
                if ($writtenEntry -ne [long]$entry.Length) { throw "Extracted update member length mismatch: $name" }
                $output.Flush($true)
            }
            finally { $output.Dispose(); $input.Dispose() }
            if ((Get-Item -LiteralPath $destination).Length -ne $writtenEntry) { throw "Extracted update member length mismatch: $name" }
        }
        $sourceRoot = Join-Path $ExtractRoot $root
        Assert-CbTreeSafe $sourceRoot
        return [pscustomobject]@{ Root = $sourceRoot; Version = $archiveVersion }
    }
    finally { $zip.Dispose(); $stream.Dispose() }
}

function Assert-CbUpdateSourceInventory {
    param([string]$Root)
    $manifest = Read-CbManifest $Root
    $expected = New-Object 'System.Collections.Generic.List[string]'
    $expected.Add('baseline/manifest.json') | Out-Null
    foreach ($entry in @($manifest.payload)) { $expected.Add([string]$entry.path) | Out-Null }
    $actual = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File)) {
        Assert-CbOrdinaryItem $file 'file'
        $relative = $file.FullName.Substring((Get-CbFullPath $Root).TrimEnd('\').Length + 1).Replace('\', '/')
        $actual.Add($relative) | Out-Null
    }
    $expectedArray = [string[]]$expected.ToArray()
    $actualArray = [string[]]$actual.ToArray()
    [Array]::Sort($expectedArray, [StringComparer]::Ordinal)
    [Array]::Sort($actualArray, [StringComparer]::Ordinal)
    if (($expectedArray -join "`n") -ne ($actualArray -join "`n")) {
        throw 'Update archive file inventory differs from manifest payload plus manifest.'
    }
    return $manifest
}

function Get-CbPreparedUpdateSource {
    param([string]$ArchiveInput, [string]$ExpectedVersion = '', $Descriptor = $null, [bool]$RemoteSource = $false)
    $temporary = New-CbTemporaryDirectory
    try {
        $archive = Join-Path $temporary 'release.zip'
        if ($RemoteSource -and $env:CODEX_BASELINE_TESTING -ne '1') {
            Receive-CbUpdateUrl ([uri]$ArchiveInput) $archive $script:UpdateMaxArchiveBytes
        }
        else { Copy-CbUpdateInput $ArchiveInput $archive $script:UpdateMaxArchiveBytes }
        if ($null -ne $Descriptor) {
            $item = Get-Item -LiteralPath $archive
            if ([long]$item.Length -ne [long]$Descriptor.ZipBytes) { throw 'Update archive byte length mismatch.' }
            if ((Get-CbFileHash $archive) -ne [string]$Descriptor.ZipSha256) { throw 'Update archive SHA-256 mismatch.' }
        }
        $extract = Join-Path $temporary 'source'
        $expanded = Expand-CbUpdateZip $archive $extract $ExpectedVersion
        $manifest = Assert-CbUpdateSourceInventory ([string]$expanded.Root)
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and [string]$manifest.version -ne $ExpectedVersion) {
            throw 'Update descriptor and source manifest version disagree.'
        }
        return [pscustomobject]@{ Temporary = $temporary; Root = [string]$expanded.Root; Manifest = $manifest }
    }
    catch {
        if (Test-CbExists $temporary) { Remove-CbSafeItem $temporary }
        throw
    }
}

function New-CbVerifiedSourceSnapshot {
    param($OriginalManifest, [string]$SourceRoot = $script:SourceRoot)
    $sourceManifestPath = Join-Path $SourceRoot 'baseline\manifest.json'
    $expectedManifestHash = Get-CbFileHash $sourceManifestPath
    $expectedPayloadHash = [string]$OriginalManifest.payload_hash
    $expectedVersion = [string]$OriginalManifest.version
    $snapshot = New-CbTemporaryDirectory
    try {
        if ($env:CODEX_BASELINE_TESTING -eq '1' -and
            $env:CODEX_BASELINE_TEST_MUTATE_SOURCE_AFTER_VERIFY -eq '1') {
            [System.IO.File]::AppendAllText(
                (Join-Path $SourceRoot 'baseline\global\AGENTS.block.md'),
                "`nsource-race-test`n",
                $script:Utf8NoBom
            )
        }

        Ensure-CbSafeDirectory (Join-Path $snapshot 'scripts\lib') | Out-Null
        Copy-CbFileSafe (Join-Path $SourceRoot 'VERSION') (Join-Path $snapshot 'VERSION')
        Copy-CbTreeSafe (Join-Path $SourceRoot 'baseline') (Join-Path $snapshot 'baseline')
        foreach ($scriptName in @('codex-baseline.sh', 'codex-baseline.ps1', 'onboard.sh', 'onboard.ps1', 'benchmark.sh', 'benchmark.ps1')) {
            Copy-CbFileSafe (Join-Path $SourceRoot ("scripts\{0}" -f $scriptName)) (Join-Path $snapshot ("scripts\{0}" -f $scriptName))
        }
        Copy-CbFileSafe (Join-Path $SourceRoot 'scripts\lib\common.sh') (Join-Path $snapshot 'scripts\lib\common.sh')
        Copy-CbFileSafe (Join-Path $SourceRoot 'scripts\lib\evaluation.sh') (Join-Path $snapshot 'scripts\lib\evaluation.sh')
        Copy-CbTreeSafe (Join-Path $SourceRoot 'benchmarks') (Join-Path $snapshot 'benchmarks')

        $snapshotManifest = Read-CbManifest $snapshot
        if ((Get-CbFileHash (Join-Path $snapshot 'baseline\manifest.json')) -ne $expectedManifestHash) {
            throw 'Source manifest changed while creating the verified snapshot.'
        }
        if ([string]$snapshotManifest.payload_hash -ne $expectedPayloadHash) {
            throw 'Source payload changed while creating the verified snapshot.'
        }
        if ([string]$snapshotManifest.version -ne $expectedVersion) {
            throw 'Source version changed while creating the verified snapshot.'
        }
        return [pscustomobject]@{
            Root = $snapshot
            Manifest = $snapshotManifest
            DirectoryIdentity = Get-CbDirectoryIdentity $snapshot
            ManifestHash = $expectedManifestHash
            PayloadHash = $expectedPayloadHash
            Version = $expectedVersion
        }
    }
    catch {
        if (Test-CbExists $snapshot) { Remove-CbSafeItem $snapshot }
        throw
    }
}

function Assert-CbVerifiedSourceSnapshot {
    param($Snapshot)
    if ($env:CODEX_BASELINE_TESTING -eq '1' -and
        $env:CODEX_BASELINE_TEST_WEAKEN_SNAPSHOT_ACL_AFTER_VERIFY -eq '1') {
        $snapshotDirectory = New-Object System.IO.DirectoryInfo([string]$Snapshot.Root)
        $acl = Get-CbDirectorySecurity $snapshotDirectory
        $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $users,
            [System.Security.AccessControl.FileSystemRights]::Modify,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule) | Out-Null
        if ($PSVersionTable.PSEdition -eq 'Core') {
            [System.IO.FileSystemAclExtensions]::SetAccessControl($snapshotDirectory, $acl)
        }
        else { $snapshotDirectory.SetAccessControl($acl) }
    }
    if ($env:CODEX_BASELINE_TESTING -eq '1' -and
        $env:CODEX_BASELINE_TEST_MUTATE_SNAPSHOT_AFTER_VERIFY -eq '1') {
        [System.IO.File]::AppendAllText(
            (Join-Path ([string]$Snapshot.Root) 'baseline\global\AGENTS.block.md'),
            "`nsnapshot-race-test`n",
            $script:Utf8NoBom
        )
    }
    Assert-CbPrivateDirectory ([string]$Snapshot.Root)
    if ((Get-CbDirectoryIdentity ([string]$Snapshot.Root)) -ne [string]$Snapshot.DirectoryIdentity) {
        throw 'Verified source snapshot directory identity changed before use.'
    }
    $manifest = Read-CbManifest ([string]$Snapshot.Root)
    if ((Get-CbFileHash (Join-Path ([string]$Snapshot.Root) 'baseline\manifest.json')) -ne [string]$Snapshot.ManifestHash -or
        [string]$manifest.payload_hash -ne [string]$Snapshot.PayloadHash -or
        [string]$manifest.version -ne [string]$Snapshot.Version) {
        throw 'Verified source snapshot changed before use.'
    }
    return $manifest
}

function New-CbRuntimeCandidate {
    param([string]$Destination, [string]$SourceRoot)
    Ensure-CbSafeDirectory $Destination | Out-Null
    Ensure-CbSafeDirectory (Join-Path $Destination 'scripts') | Out-Null
    Ensure-CbSafeDirectory (Join-Path $Destination 'scripts\lib') | Out-Null
    Copy-CbFileSafe (Join-Path $SourceRoot 'VERSION') (Join-Path $Destination 'VERSION')
    Copy-CbTreeSafe (Join-Path $SourceRoot 'baseline') (Join-Path $Destination 'baseline')
    foreach ($scriptName in @('codex-baseline.sh', 'codex-baseline.ps1', 'onboard.sh', 'onboard.ps1', 'benchmark.sh', 'benchmark.ps1')) {
        Copy-CbFileSafe (Join-Path $SourceRoot ("scripts\{0}" -f $scriptName)) (Join-Path $Destination ("scripts\{0}" -f $scriptName))
    }
    Copy-CbFileSafe (Join-Path $SourceRoot 'scripts\lib\common.sh') (Join-Path $Destination 'scripts\lib\common.sh')
    Copy-CbFileSafe (Join-Path $SourceRoot 'scripts\lib\evaluation.sh') (Join-Path $Destination 'scripts\lib\evaluation.sh')
    $benchmarks = Join-Path $SourceRoot 'benchmarks'
    if (Test-CbExists $benchmarks) {
        Copy-CbTreeSafe $benchmarks (Join-Path $Destination 'benchmarks')
    }
}

function New-CbWrapperText {
    return @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',
    [Alias('dry-run')]
    [switch]$DryRun,
    [Alias('acknowledge-unverified-source')]
    [switch]$AcknowledgeUnverifiedSource,
    [switch]$Check,
    [switch]$Remote,
    [switch]$Local,
    [string]$Offline,
    [switch]$Json,
    [switch]$Apply,
    [switch]$Restore,
    [ValidateSet('keep', 'standard', 'fast', 'ultrafast')]
    [string]$Speed = 'keep',
    [Alias('acknowledge-existing-instructions')]
    [switch]$AcknowledgeExistingInstructions,
    [Alias('max-files')]
    [int]$MaxFiles = 2000,
    [Alias('max-visited')]
    [int]$MaxVisited = 10000,
    [Parameter(Position = 1)]
    [string]$Repository = '.',
    [switch]$Static,
    [switch]$Live,
    [string]$Tasks = 'small-js-bug,small-config-timeout,small-doc-port,risk-migration,medium-js-feature,medium-dedup-reproduction,medium-id-refactor,large-architecture,large-feature-flags,six-lane-packages'
)
$ErrorActionPreference = 'Stop'
$homePath = if ([string]::IsNullOrWhiteSpace($env:HOME)) { $env:USERPROFILE } else { $env:HOME }
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $homePath '.codex' } else { $env:CODEX_HOME }
$entryPoint = Join-Path $codexHome 'codex-baseline\runtime\scripts\codex-baseline.ps1'
$parameters = @{
    Command = $Command
    DryRun = [bool]$DryRun
    AcknowledgeUnverifiedSource = [bool]$AcknowledgeUnverifiedSource
    Check = [bool]$Check
    Remote = [bool]$Remote
    Local = [bool]$Local
    Offline = $Offline
    Json = [bool]$Json
    Apply = [bool]$Apply
    Restore = [bool]$Restore
    Speed = $Speed
    AcknowledgeExistingInstructions = [bool]$AcknowledgeExistingInstructions
    MaxFiles = $MaxFiles
    MaxVisited = $MaxVisited
    Repository = $Repository
    Static = [bool]$Static
    Live = [bool]$Live
    Tasks = $Tasks
}
& $entryPoint @parameters
exit $LASTEXITCODE
'@
}

function Get-CbInstallObjects {
    param($Manifest, [string]$SourceRoot, [string]$TemporaryRoot, $CurrentTransaction)
    $blockPath = Join-Path $TemporaryRoot 'AGENTS.block.md'
    $block = New-CbRenderedBlock (Get-CbGlobalGuidancePath $SourceRoot) ([string]$Manifest.version)
    Write-CbUtf8File $blockPath $block
    $runtime = Join-Path $TemporaryRoot 'runtime'
    New-CbRuntimeCandidate $runtime $SourceRoot
    $wrapperPath = Join-Path $TemporaryRoot 'codex-baseline.ps1'
    Write-CbUtf8File $wrapperPath (New-CbWrapperText)
    $definitions = @(
        @('00', 'block', (Get-CbAgentsFile), (Get-CbStringHash $block), $blockPath, 'baseline/global/AGENTS.block.md'),
        @('10', 'tree', (Join-Path $script:AgentsHome 'skills\codex-baseline-repo-onboarding'), (Get-CbTreeHash (Join-Path $SourceRoot 'baseline\skills\codex-baseline-repo-onboarding')), (Join-Path $SourceRoot 'baseline\skills\codex-baseline-repo-onboarding'), 'baseline/skills/codex-baseline-repo-onboarding'),
        @('11', 'tree', (Join-Path $script:AgentsHome 'skills\codex-baseline-deep-work'), (Get-CbTreeHash (Join-Path $SourceRoot 'baseline\skills\codex-baseline-deep-work')), (Join-Path $SourceRoot 'baseline\skills\codex-baseline-deep-work'), 'baseline/skills/codex-baseline-deep-work'),
        @('12', 'tree', (Join-Path $script:AgentsHome 'skills\codex-baseline-conformance-review'), (Get-CbTreeHash (Join-Path $SourceRoot 'baseline\skills\codex-baseline-conformance-review')), (Join-Path $SourceRoot 'baseline\skills\codex-baseline-conformance-review'), 'baseline/skills/codex-baseline-conformance-review'),
        @('13', 'tree', (Join-Path $script:AgentsHome 'skills\codex-baseline-retrospective'), (Get-CbTreeHash (Join-Path $SourceRoot 'baseline\skills\codex-baseline-retrospective')), (Join-Path $SourceRoot 'baseline\skills\codex-baseline-retrospective'), 'baseline/skills/codex-baseline-retrospective'),
        @('20', 'file', (Join-Path $script:CodexHome 'agents\codex-baseline-reviewer.toml'), (Get-CbFileHash (Join-Path $SourceRoot 'baseline\agents\codex-baseline-reviewer.toml')), (Join-Path $SourceRoot 'baseline\agents\codex-baseline-reviewer.toml'), 'baseline/agents/codex-baseline-reviewer.toml'),
        @('30', 'tree', $script:RuntimePath, (Get-CbTreeHash $runtime), $runtime, 'runtime'),
        @('31', 'file', (Join-Path $script:HomePath '.local\bin\codex-baseline.ps1'), (Get-CbFileHash $wrapperPath), $wrapperPath, 'generated-wrapper')
    )
    $objects = @()
    foreach ($definition in $definitions) {
        $objects += New-CbObject $definition[0] $definition[1] $definition[2] $definition[3] $true $definition[4] $definition[5] $CurrentTransaction
    }
    return $objects
}

function Save-CbBackup {
    param($Transaction, $Object)
    $objectDirectory = Join-Path (Join-Path (Get-CbTransactionPath $Transaction.Id) 'objects') $Object.Id
    Ensure-CbSafeDirectory $objectDirectory | Out-Null
    if (-not $Object.PreviousExisted) {
        return
    }
    $backup = Join-Path $objectDirectory 'backup'
    if ($Object.Kind -eq 'block') {
        $physicalBackup = Join-Path $objectDirectory 'backup-full'
        Copy-CbFileSafe $Object.Target $physicalBackup
        $Object.PhysicalBackup = $physicalBackup
        $Object.PhysicalBackupHash = Get-CbFileHash $physicalBackup
        if (-not $Object.PreviousManagedExisted) {
            $Object.BackupHash = 'absent'
            return
        }
        $text = Read-CbUtf8Text $Object.Target
        $info = Get-CbBlockInfo $text
        Write-CbUtf8File $backup $info.Block
        $Object.Backup = $backup
        $Object.BackupHash = Get-CbStringHash $info.Block
    }
    elseif ($Object.Kind -eq 'file') {
        Copy-CbFileSafe $Object.Target $backup
        $Object.Backup = $backup
        $Object.BackupHash = Get-CbFileHash $backup
    }
    elseif ($Object.Kind -eq 'tree') {
        Copy-CbTreeSafe $Object.Target $backup
        $Object.Backup = $backup
        $Object.BackupHash = Get-CbTreeHash $backup
    }
}

function Prepare-CbObject {
    param($Transaction, $Object)
    $targetParent = [System.IO.Path]::GetDirectoryName($Object.Target)
    Ensure-CbSafeDirectory $targetParent | Out-Null
    $stage = Join-Path $targetParent ('.codex-baseline-stage-{0}-{1}' -f $Transaction.Id, $Object.Id)
    $old = Join-Path $targetParent ('.codex-baseline-old-{0}-{1}' -f $Transaction.Id, $Object.Id)
    if (Test-CbExists $stage) { throw "Staging collision: $stage" }
    if (Test-CbExists $old) { throw "Staging collision: $old" }
    $Object.Stage = $stage
    $Object.Old = $old
    Write-CbTransaction $Transaction
    Save-CbBackup $Transaction $Object
    if ($Object.DesiredPresent) {
        if ($Object.Kind -eq 'block') {
            if ($Object.BlockWholeFileSource) {
                Copy-CbFileSafe $Object.SourcePath $stage
            }
            else {
                $liveText = if (Test-CbExists $Object.Target) { Read-CbUtf8Text $Object.Target } else { '' }
                if ($Object.DesiredHash -eq 'absent') {
                    $desiredText = Remove-CbBlockText $liveText
                }
                else {
                    $desiredBlock = Read-CbUtf8Text $Object.SourcePath
                    $desiredText = Set-CbBlockText $liveText $desiredBlock
                }
                Write-CbUtf8File $stage $desiredText
            }
        }
        elseif ($Object.Kind -eq 'file') {
            Copy-CbFileSafe $Object.SourcePath $stage
        }
        elseif ($Object.Kind -eq 'tree') {
            Copy-CbTreeSafe $Object.SourcePath $stage
        }
    }
    if ($Object.DesiredPresent) {
        $stagedHash = Get-CbLiveHash $Object.Kind $stage
        if ($stagedHash -ne $Object.DesiredHash) {
            throw "Staged hash mismatch for $($Object.Target)"
        }
        $Object.DesiredPhysicalHash = Get-CbPhysicalHash $stage
    }
    elseif (Test-CbExists $stage) {
        throw "An absent desired object unexpectedly has staging content: $($Object.Target)"
    }
    else {
        $Object.DesiredPhysicalHash = 'absent'
    }
    $Object.Status = 'prepared'
    Write-CbTransaction $Transaction
}

function Commit-CbObject {
    param($Transaction, $Object)
    $live = Get-CbLiveHash $Object.Kind $Object.Target
    $physical = Get-CbPhysicalHash $Object.Target
    if ($live -ne $Object.PreviousHash -or $physical -ne $Object.PreviousPhysicalHash) {
        throw "Target changed during transaction: $($Object.Target)"
    }
    $Object.Status = 'moving-old'
    Write-CbTransaction $Transaction
    if ($Object.PreviousExisted) {
        Move-CbPath $Object.Target $Object.Old
        Assert-CbPhysicalHashAt ([string]$Object.Old) ([string]$Object.PreviousPhysicalHash) 'Moved commit preimage'
    }
    $Object.Status = 'old-moved'
    Write-CbTransaction $Transaction
    if ($Object.DesiredPresent) {
        if ((Get-CbPhysicalHash $Object.Stage) -ne [string]$Object.DesiredPhysicalHash) {
            throw "Staged physical content changed before commit: $($Object.Target)"
        }
        if ($Object.Kind -eq 'tree') {
            [System.IO.Directory]::Move($Object.Stage, $Object.Target)
        }
        else {
            [System.IO.File]::Move($Object.Stage, $Object.Target)
        }
    }
    $Object.Status = 'new-moved'
    Write-CbTransaction $Transaction
    $installed = Get-CbLiveHash $Object.Kind $Object.Target
    if ($installed -ne $Object.DesiredHash) {
        throw "Committed hash mismatch for $($Object.Target)"
    }
    if ((Test-CbExists $Object.Target) -ne [bool]$Object.DesiredPresent) {
        throw "Committed presence mismatch for $($Object.Target)"
    }
    if ((Get-CbPhysicalHash $Object.Target) -ne [string]$Object.DesiredPhysicalHash) {
        throw "Committed physical hash mismatch for $($Object.Target)"
    }
    $Object.InstalledHash = $Object.DesiredHash
    $Object.InstalledPhysicalHash = Get-CbPhysicalHash $Object.Target
    $Object.Status = 'committed'
    Write-CbTransaction $Transaction
}

function Move-CbPath {
    param([string]$Source, [string]$Destination)
    $item = Get-CbItem $Source
    if ($null -eq $item) {
        throw "Move source is missing: $Source"
    }
    Assert-CbOrdinaryItem $item 'any'
    if ($item.PSIsContainer) {
        [System.IO.Directory]::Move($item.FullName, $Destination)
    }
    else {
        [System.IO.File]::Move($item.FullName, $Destination)
    }
}

function Complete-CbTransaction {
    param($Transaction, [AllowNull()][string]$ResultCurrent)
    $effectiveResult = if ([string]::IsNullOrWhiteSpace($ResultCurrent)) { $null } else { [string]$ResultCurrent }
    foreach ($object in @($Transaction.Objects)) {
        if ($object.Change -and $object.PreviousExisted) {
            if ($null -eq $object.Old -or -not (Test-CbExists ([string]$object.Old))) {
                throw "Commit preimage is missing before completion: $($object.Target)"
            }
            Assert-CbPhysicalHashAt ([string]$object.Old) ([string]$object.PreviousPhysicalHash) 'Commit preimage before completion'
        }
    }
    $Transaction.ResultCurrent = $effectiveResult
    if ($null -eq $effectiveResult) {
        if (Test-CbExists $script:CurrentPath) {
            Remove-CbSafeItem $script:CurrentPath
        }
    }
    else {
        Write-CbPointer $script:CurrentPath $effectiveResult
    }
    $Transaction.State = 'committed'
    Write-CbTransaction $Transaction
    Remove-CbSafeItem $script:PendingPath
    foreach ($object in @($Transaction.Objects)) {
        if ($object.Change -and $null -ne $object.Old -and (Test-CbExists $object.Old)) {
            Assert-CbPhysicalHashAt ([string]$object.Old) ([string]$object.PreviousPhysicalHash) 'Commit preimage before cleanup'
            Remove-CbSafeItem $object.Old
        }
    }
    $script:ActiveTransaction = $null
}

function Assert-CbPhysicalHashAt {
    param([string]$Path, [string]$Expected, [string]$Label)
    $actual = Get-CbPhysicalHash $Path
    if ($actual -ne $Expected) { throw "$Label physical hash mismatch: $Path" }
}

function Assert-CbRecoveryPreimage {
    param($Transaction, $Object)
    if (-not $Object.Change) { return }
    $status = [string]$Object.Status
    $targetExists = Test-CbExists ([string]$Object.Target)
    $stageExists = $null -ne $Object.Stage -and (Test-CbExists ([string]$Object.Stage))
    $oldExists = $null -ne $Object.Old -and (Test-CbExists ([string]$Object.Old))

    if ($stageExists) {
        if ($null -eq $Object.DesiredPhysicalHash) {
            throw "Recovery cannot verify a partially staged object: $($Object.Target)"
        }
        Assert-CbPhysicalHashAt ([string]$Object.Stage) ([string]$Object.DesiredPhysicalHash) 'Staged recovery object'
    }
    if ($null -ne $Object.Backup) {
        if (-not (Test-CbExists ([string]$Object.Backup))) { throw "Recovery backup is missing: $($Object.Target)" }
        $backupHash = if ($Object.Kind -eq 'block') {
            Get-CbStringHash (Read-CbUtf8Text ([string]$Object.Backup))
        }
        else { Get-CbLiveHash ([string]$Object.Kind) ([string]$Object.Backup) }
        if ($backupHash -ne [string]$Object.BackupHash) { throw "Recovery backup is corrupt: $($Object.Target)" }
    }
    if ($null -ne $Object.PhysicalBackup) {
        if (-not (Test-CbExists ([string]$Object.PhysicalBackup))) { throw "Recovery physical backup is missing: $($Object.Target)" }
        if ((Get-CbFileHash ([string]$Object.PhysicalBackup)) -ne [string]$Object.PhysicalBackupHash) {
            throw "Recovery physical backup is corrupt: $($Object.Target)"
        }
    }

    switch ($status) {
        'planned' {
            Assert-CbPhysicalHashAt ([string]$Object.Target) ([string]$Object.PreviousPhysicalHash) 'Planned recovery target'
            if ($oldExists) { throw "Planned recovery unexpectedly has an old object: $($Object.Target)" }
        }
        'prepared' {
            Assert-CbPhysicalHashAt ([string]$Object.Target) ([string]$Object.PreviousPhysicalHash) 'Prepared recovery target'
            if ($oldExists) { throw "Prepared recovery unexpectedly has an old object: $($Object.Target)" }
            if ($Object.DesiredPresent -and -not $stageExists) { throw "Prepared recovery stage is missing: $($Object.Target)" }
        }
        'moving-old' {
            if ($Object.PreviousExisted) {
                if ($targetExists -eq $oldExists) { throw "Ambiguous moving-old recovery state: $($Object.Target)" }
                if ($targetExists) { Assert-CbPhysicalHashAt ([string]$Object.Target) ([string]$Object.PreviousPhysicalHash) 'Moving-old target' }
                else { Assert-CbPhysicalHashAt ([string]$Object.Old) ([string]$Object.PreviousPhysicalHash) 'Moving-old preimage' }
            }
            elseif ($targetExists -or $oldExists) { throw "Moving-old recovery has unexpected content: $($Object.Target)" }
        }
        'old-moved' {
            if ($targetExists) { throw "Old-moved recovery target unexpectedly exists: $($Object.Target)" }
            if ($Object.PreviousExisted) {
                if (-not $oldExists) { throw "Old-moved recovery preimage is missing: $($Object.Target)" }
                Assert-CbPhysicalHashAt ([string]$Object.Old) ([string]$Object.PreviousPhysicalHash) 'Old-moved preimage'
            }
            elseif ($oldExists) { throw "Old-moved recovery has an unexpected preimage: $($Object.Target)" }
            if ($Object.DesiredPresent -and -not $stageExists) { throw "Old-moved recovery stage is missing: $($Object.Target)" }
        }
        { $_ -eq 'new-moved' -or $_ -eq 'committed' } {
            Assert-CbPhysicalHashAt ([string]$Object.Target) ([string]$Object.DesiredPhysicalHash) 'Committed recovery target'
            if ($Object.PreviousExisted) {
                if (-not $oldExists) { throw "Committed recovery preimage is missing: $($Object.Target)" }
                Assert-CbPhysicalHashAt ([string]$Object.Old) ([string]$Object.PreviousPhysicalHash) 'Committed recovery preimage'
            }
            elseif ($oldExists) { throw "Committed recovery has an unexpected preimage: $($Object.Target)" }
        }
        'rolled-back' {
            Assert-CbPhysicalHashAt ([string]$Object.Target) ([string]$Object.PreviousPhysicalHash) 'Rolled-back recovery target'
            if ($stageExists -or $oldExists) { throw "Rolled-back recovery still has staging content: $($Object.Target)" }
        }
        'unchanged' {
            Assert-CbPhysicalHashAt ([string]$Object.Target) ([string]$Object.DesiredPhysicalHash) 'Unchanged recovery target'
            if ($stageExists -or $oldExists) { throw "Unchanged recovery has staging content: $($Object.Target)" }
        }
        default { throw "Unknown object journal state: $status" }
    }
}

function Restore-CbPendingObject {
    param($Transaction, $Object)
    if (-not $Object.Change) {
        return
    }
    $targetExists = Test-CbExists $Object.Target
    $oldExists = $null -ne $Object.Old -and (Test-CbExists $Object.Old)
    switch ([string]$Object.Status) {
        'planned' { }
        'prepared' { }
        'moving-old' {
            if ($oldExists -and $targetExists) {
                throw "Ambiguous interrupted move at $($Object.Target)"
            }
            if ($oldExists -and -not $targetExists) {
                Assert-CbPhysicalHashAt ([string]$Object.Old) ([string]$Object.PreviousPhysicalHash) 'Moving-old restore source'
                Move-CbPath $Object.Old $Object.Target
            }
        }
        { $_ -eq 'old-moved' -or $_ -eq 'new-moved' -or $_ -eq 'committed' } {
            if ($targetExists) {
                $live = Get-CbLiveHash $Object.Kind $Object.Target
                $physical = Get-CbPhysicalHash $Object.Target
                if ($live -ne $Object.DesiredHash -or $physical -ne $Object.DesiredPhysicalHash) {
                    throw "Interrupted target drifted; manual recovery required: $($Object.Target)"
                }
            }
            if ($Object.PreviousExisted) {
                if (-not $oldExists) {
                    throw "Interrupted transaction lost its preimage: $($Object.Target)"
                }
                Assert-CbPhysicalHashAt ([string]$Object.Old) ([string]$Object.PreviousPhysicalHash) 'Recovery restore source'
            }
            if ($targetExists) {
                Remove-CbSafeItem $Object.Target
            }
            if ($Object.PreviousExisted) {
                Move-CbPath $Object.Old $Object.Target
            }
        }
        'rolled-back' { return }
        default { throw "Unknown object journal state: $($Object.Status)" }
    }
    if ($null -ne $Object.Stage -and (Test-CbExists $Object.Stage)) {
        Remove-CbSafeItem $Object.Stage
    }
    if ($null -ne $Object.Old -and (Test-CbExists $Object.Old)) {
        Remove-CbSafeItem $Object.Old
    }
    $Object.Status = 'rolled-back'
    Write-CbTransaction $Transaction
}

function Recover-CbPending {
    $pending = Read-CbPointer $script:PendingPath
    if ($null -eq $pending) {
        return
    }
    Write-CbError "recovering incomplete transaction $pending"
    $transaction = Read-CbTransaction $pending
    Assert-CbTransactionShape $transaction $false
    $parent = $null
    if ($null -ne $transaction.ParentTransaction) {
        $parent = Read-CbTransaction ([string]$transaction.ParentTransaction)
        Assert-CbTransactionShape $parent $true
        if ([string]$parent.State -ne 'committed') { throw 'Pending transaction parent is not committed.' }
    }
    $allObjectIds = @('00', '10', '11', '12', '13', '20', '30', '31')
    switch ([string]$transaction.Operation) {
        { $_ -eq 'install' -or $_ -eq 'update' } {
            Assert-CbExactObjectIds $transaction $allObjectIds 'Pending install/update transaction'
        }
        'uninstall' {
            if ($null -eq $parent) { throw 'Pending uninstall transaction has no validated parent.' }
            Assert-CbExactObjectIds $transaction $allObjectIds 'Pending uninstall transaction'
        }
        'rollback' {
            if ($null -eq $parent) { throw 'Pending rollback transaction has no validated parent.' }
            $expectedRollbackIds = @($parent.Objects | Where-Object { [string]$_.Status -eq 'committed' } | ForEach-Object { [string]$_.Id })
            if ($expectedRollbackIds.Count -eq 0) { throw 'Pending rollback transaction has no derived object inventory.' }
            Assert-CbExactObjectIds $transaction $expectedRollbackIds 'Pending rollback transaction'
        }
    }
    foreach ($object in @($transaction.Objects)) {
        Assert-CbRecoveryPreimage $transaction $object
    }
    $transaction.State = 'recovering'
    Write-CbTransaction $transaction
    $objects = @($transaction.Objects)
    [array]::Reverse($objects)
    foreach ($object in $objects) {
        Restore-CbPendingObject $transaction $object
    }
    if ($null -eq $transaction.ParentTransaction) {
        if (Test-CbExists $script:CurrentPath) { Remove-CbSafeItem $script:CurrentPath }
    }
    else {
        Write-CbPointer $script:CurrentPath ([string]$transaction.ParentTransaction)
    }
    $transaction.State = 'rolled-back'
    Write-CbTransaction $transaction
    Remove-CbSafeItem $script:PendingPath
    $script:ActiveTransaction = $null
}

function Acquire-CbLock {
    Ensure-CbSafeDirectory $script:StateRoot | Out-Null
    $candidate = Join-Path $script:StateRoot ('.lock-{0}' -f [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
    $ownerRecord = [pscustomobject]@{
        Pid = $PID
        StartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    }
    Write-CbUtf8File (Join-Path $candidate 'owner.json') (($ownerRecord | ConvertTo-Json) + "`n")
    try {
        [System.IO.Directory]::Move($candidate, $script:LockPath)
        $script:LockHeld = $true
        return
    }
    catch [System.IO.IOException] {
        if (Test-CbExists $candidate) { Remove-CbSafeItem $candidate }
    }
    $lock = Get-CbItem $script:LockPath
    if ($null -eq $lock) {
        throw 'The operation lock disappeared during acquisition; retry the command.'
    }
    Assert-CbOrdinaryItem $lock 'tree'
    $ownerPath = Join-Path $script:LockPath 'owner.json'
    $active = $false
    if (Test-CbExists $ownerPath) {
        try {
            $owner = (Read-CbUtf8Text $ownerPath) | ConvertFrom-Json
            $process = Get-Process -Id ([int]$owner.Pid) -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                $recorded = [DateTime]::Parse([string]$owner.StartUtc).ToUniversalTime()
                $active = [Math]::Abs(($process.StartTime.ToUniversalTime() - $recorded).TotalSeconds) -lt 1
            }
        }
        catch {
            $active = $false
        }
    }
    if ($active) {
        throw "Another baseline operation holds the lock: $script:LockPath"
    }
    Remove-CbSafeItem $script:LockPath
    $candidate = Join-Path $script:StateRoot ('.lock-{0}' -f [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
    Write-CbUtf8File (Join-Path $candidate 'owner.json') (($ownerRecord | ConvertTo-Json) + "`n")
    try {
        [System.IO.Directory]::Move($candidate, $script:LockPath)
        $script:LockHeld = $true
    }
    catch {
        if (Test-CbExists $candidate) { Remove-CbSafeItem $candidate }
        throw 'Could not acquire the recovered operation lock; another process may have won the race.'
    }
}

function Release-CbLock {
    if ($script:LockHeld -and (Test-CbExists $script:LockPath)) {
        Remove-CbSafeItem $script:LockPath
    }
    $script:LockHeld = $false
}

function Invoke-CbTransaction {
    param(
        [string]$Operation,
        [string]$Version,
        [AllowNull()][string]$ParentTransaction,
        [object[]]$Objects,
        [AllowNull()][string]$ResultCurrent,
        [AllowNull()]$ReservedTransaction=$null
    )
    $transaction = if($null-eq$ReservedTransaction){New-CbTransaction $Operation $Version $ParentTransaction}else{$ReservedTransaction}
    if([string]$transaction.Operation-ne$Operation-or[string]$transaction.Version-ne$Version-or[string]$transaction.State-ne'planned'){
        throw 'Reserved core transaction does not match the requested operation.'
    }
    $reservedParent=if($null-eq$transaction.ParentTransaction){''}else{[string]$transaction.ParentTransaction}
    $requestedParent=if([string]::IsNullOrWhiteSpace($ParentTransaction)){''}else{$ParentTransaction}
    if($reservedParent-ne$requestedParent-or@($transaction.Objects).Count-ne0){throw 'Reserved core transaction has an invalid parent or object inventory.'}
    $transaction.ResultCurrent = $(if ([string]::IsNullOrWhiteSpace($ResultCurrent)) { $null } else { $ResultCurrent })
    $transaction.Objects = @($Objects)
    Write-CbTransaction $transaction
    Write-CbPointer $script:PendingPath ([string]$transaction.Id)
    $script:ActiveTransaction = [string]$transaction.Id
    foreach ($object in @($transaction.Objects)) {
        if (-not $object.Change) {
            $object.Status = 'unchanged'
            $object.InstalledHash = $object.DesiredHash
            $object.DesiredPhysicalHash = Get-CbPhysicalHash $object.Target
            $object.InstalledPhysicalHash = $object.DesiredPhysicalHash
            Write-CbTransaction $transaction
            continue
        }
        Prepare-CbObject $transaction $object
    }
    $transaction.State = 'prepared'
    Write-CbTransaction $transaction
    $transaction.State = 'committing'
    Write-CbTransaction $transaction
    $committedCount = 0
    foreach ($object in @($transaction.Objects)) {
        if (-not $object.Change) { continue }
        Commit-CbObject $transaction $object
        $committedCount++
        if ($committedCount -eq 1 -and -not [string]::IsNullOrWhiteSpace($env:CODEX_BASELINE_TEST_APPEND_AGENTS_AFTER_OBJECT)) {
            [System.IO.File]::AppendAllText([string]$object.Target, $env:CODEX_BASELINE_TEST_APPEND_AGENTS_AFTER_OBJECT, $script:Utf8NoBom)
        }
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT)) {
            $faultAfter = 0
            if ([int]::TryParse($env:CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT, [ref]$faultAfter) -and $faultAfter -eq $committedCount) {
                throw "Injected test fault after object $committedCount"
            }
        }
    }
    $effectiveResult = if ($ResultCurrent -eq '__SELF__') { [string]$transaction.Id } else { $ResultCurrent }
    Complete-CbTransaction $transaction $effectiveResult
    return $transaction
}

function Get-CbConfigKeyMetadata {
    param([string]$Id)
    switch ($Id) {
        'agents_enabled' { return [pscustomobject]@{ Id=$Id; Path='agents.enabled'; Table='agents'; Key='enabled'; Type='boolean' } }
        'agents_max' { return [pscustomobject]@{ Id=$Id; Path='agents.max_concurrent_threads_per_session'; Table='agents'; Key='max_concurrent_threads_per_session'; Type='integer' } }
        'service_tier' { return [pscustomobject]@{ Id=$Id; Path='service_tier'; Table=''; Key='service_tier'; Type='enum' } }
        'features_fast_mode' { return [pscustomobject]@{ Id=$Id; Path='features.fast_mode'; Table='features'; Key='fast_mode'; Type='boolean' } }
        default { throw "Unknown managed config key: $Id" }
    }
}

function Read-CbConfigDocumentBytes {
    param([byte[]]$Bytes)
    if ($Bytes.Length -gt 1048576) { throw 'config.toml exceeds the 1 MiB optimizer limit.' }
    $bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
    $offset = if ($bom) { 3 } else { 0 }
    try { $text = $script:Utf8Strict.GetString($Bytes, $offset, $Bytes.Length - $offset) }
    catch { throw 'config.toml is not valid UTF-8.' }
    if ($text.IndexOf([char]0) -ge 0) { throw 'config.toml contains a NUL byte.' }
    if([regex]::IsMatch($text,"`r(?!`n)")){throw 'config.toml contains an unsupported lone-CR line ending.'}
    $lineList = New-Object 'System.Collections.Generic.List[object]'
    if ($text.Length -gt 0) {
        foreach ($match in [regex]::Matches($text, '[^\n]*(?:\n|$)')) {
            if ($match.Length -eq 0) { continue }
            $chunk = $match.Value
            $ending = ''
            $body = $chunk
            if ($chunk.EndsWith("`n")) {
                if ($chunk.EndsWith("`r`n")) { $ending = "`r`n"; $body = $chunk.Substring(0, $chunk.Length - 2) }
                else { $ending = "`n"; $body = $chunk.Substring(0, $chunk.Length - 1) }
            }
            $lineList.Add([pscustomobject]@{ Body = $body; Ending = $ending }) | Out-Null
        }
    }
    $tables = @{}
    $keys = @{}
    $lineTables = New-Object 'System.Collections.Generic.List[string]'
    $table = ''
    for ($index = 0; $index -lt $lineList.Count; $index++) {
        $body = [string]$lineList[$index].Body
        if ($body.Contains("'''" ) -or $body.Contains('"""')) { throw 'Multiline TOML strings are unsupported for safe key patching.' }
        $trimmed = $body.TrimStart(' ', "`t")
        $lineTables.Add($table) | Out-Null
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $header = [regex]::Match($trimmed, '^\[([A-Za-z0-9_-]+)\][ \t]*(?:#.*)?$')
        if ($header.Success) {
            $table = $header.Groups[1].Value
            $lineTables[$index] = $table
            if ($table -in @('agents','features')) {
                if ($tables.ContainsKey($table)) { throw "Duplicate [$table] table in config.toml." }
                $tables[$table] = $index
            }
            continue
        }
        if ($trimmed.StartsWith('[')) {
            if ($trimmed -match '(agents|features)') { throw 'Ambiguous quoted, dotted, array, or malformed managed TOML table.' }
            $table = 'other'; $lineTables[$index] = $table; continue
        }
        if ($trimmed -match '^(agents|features)[ \t]*(\.|=)' -or
            $trimmed -match '^["''](agents|features)["'']' -or
            ($table -eq '' -and $trimmed -match '^["'']service_tier["''][ \t]*=') -or
            ($table -eq 'agents' -and $trimmed -match '^["''](enabled|max_concurrent_threads_per_session|max_threads)["''][ \t]*=') -or
            ($table -eq 'features' -and $trimmed -match '^["''](fast_mode|multi_agent)["''][ \t]*=')) {
            throw 'Dotted, quoted, or inline definitions of managed TOML paths are unsupported.'
        }
        $id = $null; $key = $null
        if ($table -eq '' -and $trimmed -match '^service_tier[ \t]*=') { $id='service_tier'; $key='service_tier' }
        elseif ($table -eq 'agents' -and $trimmed -match '^enabled[ \t]*=') { $id='agents_enabled'; $key='enabled' }
        elseif ($table -eq 'agents' -and $trimmed -match '^max_concurrent_threads_per_session[ \t]*=') { $id='agents_max'; $key='max_concurrent_threads_per_session' }
        elseif ($table -eq 'agents' -and $trimmed -match '^max_threads[ \t]*=') { $id='agents_legacy_max'; $key='max_threads' }
        elseif ($table -eq 'features' -and $trimmed -match '^fast_mode[ \t]*=') { $id='features_fast_mode'; $key='fast_mode' }
        elseif ($table -eq 'features' -and $trimmed -match '^multi_agent[ \t]*=') { $id='features_multi_agent'; $key='multi_agent' }
        if ($null -eq $id) { continue }
        $pattern = '^(?<indent>[ \t]*)' + [regex]::Escape($key) + '(?<eq>[ \t]*=[ \t]*)(?<token>true|false|[0-9]+|"[A-Za-z0-9_-]+")(?<suffix>[ \t]*(?:#.*)?)$'
        $scalar = [regex]::Match($body, $pattern)
        if (-not $scalar.Success) { throw "Managed key uses ambiguous or unsupported TOML syntax: $id" }
        if ($keys.ContainsKey($id)) { throw "Duplicate managed key: $id" }
        $token = $scalar.Groups['token'].Value
        if (($id -in @('agents_enabled','features_fast_mode','features_multi_agent') -and $token -notin @('true','false')) -or
            ($id -in @('agents_max','agents_legacy_max') -and $token -notmatch '^(0|[1-9][0-9]{0,5})$')) {
            throw "Managed key has an unsupported scalar type: $id"
        }
        $keys[$id] = [pscustomobject]@{ Index=$index; Token=$token }
    }
    return [pscustomobject]@{ Bom=$bom; Lines=$lineList; Tables=$tables; Keys=$keys; LineTables=$lineTables }
}

function Read-CbConfigDocument {
    if (-not (Test-CbExists $script:ConfigPath)) { return Read-CbConfigDocumentBytes ([byte[]]@()) }
    return Read-CbConfigDocumentBytes ([System.IO.File]::ReadAllBytes($script:ConfigPath))
}

function ConvertTo-CbConfigBytes {
    param($Document)
    $builder = New-Object System.Text.StringBuilder
    foreach ($line in $Document.Lines) { [void]$builder.Append([string]$line.Body); [void]$builder.Append([string]$line.Ending) }
    $payload = $script:Utf8NoBom.GetBytes($builder.ToString())
    if (-not [bool]$Document.Bom) { return ,$payload }
    $bytes = New-Object byte[] ($payload.Length + 3)
    $bytes[0]=0xEF; $bytes[1]=0xBB; $bytes[2]=0xBF
    [Array]::Copy($payload, 0, $bytes, 3, $payload.Length)
    return ,$bytes
}

function Update-CbConfigDocumentKey {
    param($Document, [string]$Id, [string]$Desired)
    $meta = Get-CbConfigKeyMetadata $Id
    $lines = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $Document.Lines) { $lines.Add([pscustomobject]@{Body=[string]$line.Body;Ending=[string]$line.Ending}) | Out-Null }
    if ($Document.Keys.ContainsKey($Id)) {
        $index = [int]$Document.Keys[$Id].Index
        if ($Desired -eq '__ABSENT__') { $lines.RemoveAt($index) }
        else {
            $body = [string]$lines[$index].Body
            $pattern = '^(?<indent>[ \t]*)' + [regex]::Escape([string]$meta.Key) + '(?<eq>[ \t]*=[ \t]*)(?<token>true|false|[0-9]+|"[A-Za-z0-9_-]+")(?<suffix>[ \t]*(?:#.*)?)$'
            $match = [regex]::Match($body, $pattern)
            if (-not $match.Success) { throw "Cannot safely rewrite managed key: $Id" }
            $lines[$index].Body = $match.Groups['indent'].Value + $meta.Key + $match.Groups['eq'].Value + $Desired + $match.Groups['suffix'].Value
        }
        return Read-CbConfigDocumentBytes (ConvertTo-CbConfigBytes ([pscustomobject]@{Bom=$Document.Bom;Lines=$lines}))
    }
    if ($Desired -eq '__ABSENT__') { return $Document }
    $eol = "`r`n"
    foreach ($existing in $lines) { if ([string]$existing.Ending -ne '') { $eol=[string]$existing.Ending; break } }
    $newLine = [pscustomobject]@{ Body=("{0} = {1}" -f $meta.Key,$Desired); Ending='' }
    if ([string]::IsNullOrEmpty([string]$meta.Table)) {
        $insert = $lines.Count
        for ($index=0; $index -lt $lines.Count; $index++) { if ([string]$lines[$index].Body -match '^[ \t]*\[') { $insert=$index; break } }
        if ($insert -lt $lines.Count) { $newLine.Ending=$eol }
        $lines.Insert($insert,$newLine)
    }
    elseif ($Document.Tables.ContainsKey([string]$meta.Table)) {
        $header=[int]$Document.Tables[[string]$meta.Table]; $insert=$lines.Count
        for ($index=$header+1; $index -lt $lines.Count; $index++) { if ([string]$Document.LineTables[$index] -ne [string]$meta.Table) { $insert=$index; break } }
        if ($insert -lt $lines.Count) { $newLine.Ending=$eol }
        elseif ($lines.Count -gt 0 -and [string]$lines[$lines.Count-1].Ending -ne '') { $newLine.Ending=$eol }
        elseif ($lines.Count -gt 0) { $lines[$lines.Count-1].Ending=$eol }
        $lines.Insert($insert,$newLine)
    }
    else {
        $hadFinal = $lines.Count -gt 0 -and [string]$lines[$lines.Count-1].Ending -ne ''
        if ($lines.Count -gt 0 -and [string]$lines[$lines.Count-1].Ending -eq '') { $lines[$lines.Count-1].Ending=$eol }
        if ($lines.Count -gt 0 -and [string]$lines[$lines.Count-1].Body -ne '') { $lines.Add([pscustomobject]@{Body='';Ending=$eol}) | Out-Null }
        $lines.Add([pscustomobject]@{Body=("[{0}]" -f $meta.Table);Ending=$eol}) | Out-Null
        $newLine.Ending = if ($hadFinal) { $eol } else { '' }
        $lines.Add($newLine) | Out-Null
    }
    return Read-CbConfigDocumentBytes (ConvertTo-CbConfigBytes ([pscustomobject]@{Bom=$Document.Bom;Lines=$lines}))
}

function Remove-CbEmptyCreatedConfigTable {
    param($Document, [string]$Table, [bool]$SeparatorAdded, [string]$CurrentFinalEnding)
    if (-not $Document.Tables.ContainsKey($Table)) { return $Document }
    $header=[int]$Document.Tables[$Table]; $end=$Document.Lines.Count; $meaningful=$false
    for ($index=$header+1; $index -lt $Document.Lines.Count; $index++) {
        if ([string]$Document.LineTables[$index] -ne $Table) { $end=$index; break }
        $trimmed=([string]$Document.Lines[$index].Body).TrimStart(' ',"`t")
        if ($trimmed.Length -gt 0) { $meaningful=$true }
    }
    if ($meaningful) { return $Document }
    $lines=New-Object 'System.Collections.Generic.List[object]'
    for ($index=0; $index -lt $Document.Lines.Count; $index++) {
        if ($index -ge $header -and $index -lt $end) { continue }
        if ($SeparatorAdded -and $index -eq ($header-1) -and [string]$Document.Lines[$index].Body -eq '') { continue }
        $lines.Add([pscustomobject]@{Body=[string]$Document.Lines[$index].Body;Ending=[string]$Document.Lines[$index].Ending}) | Out-Null
    }
    if ($lines.Count -gt 0) { $lines[$lines.Count-1].Ending = $CurrentFinalEnding }
    return Read-CbConfigDocumentBytes (ConvertTo-CbConfigBytes ([pscustomobject]@{Bom=$Document.Bom;Lines=$lines}))
}

function Initialize-CbConfigNative {
    if ($null -ne ('CodexBaseline.ConfigNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace CodexBaseline {
  public static class ConfigNative {
    [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] struct INFO { public uint Attr; public FILETIME C,A,W; public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr q,uint c,uint f,IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out INFO i);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetFileSecurityW(string p,uint i,byte[] d);
    public static string FileIdentity(string p) { using(var h=CreateFileW(p,0,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)){ if(h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error()); INFO i; if(!GetFileInformationByHandle(h,out i)) throw new Win32Exception(Marshal.GetLastWin32Error()); return String.Format("{0:X8}:{1:X8}:{2:X8}:{3}",i.Volume,i.IndexHigh,i.IndexLow,i.Links); } }
    public static void SetDacl(string p,byte[] d,bool isProtected) {
      const uint DACL_SECURITY_INFORMATION=0x00000004;
      const uint PROTECTED_DACL_SECURITY_INFORMATION=0x80000000;
      const uint UNPROTECTED_DACL_SECURITY_INFORMATION=0x20000000;
      uint information=DACL_SECURITY_INFORMATION|(isProtected?PROTECTED_DACL_SECURITY_INFORMATION:UNPROTECTED_DACL_SECURITY_INFORMATION);
      if(!SetFileSecurityW(p,information,d)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
  }
}
'@
}

function Get-CbConfigSecurity {
    param([string]$Path)
    $sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner
    $file=New-Object System.IO.FileInfo($Path)
    $security = if ($PSVersionTable.PSEdition -eq 'Core') { [System.IO.FileSystemAclExtensions]::GetAccessControl($file,$sections) } else { $file.GetAccessControl($sections) }
    return [pscustomobject]@{
        Owner=$security.GetOwner([Security.Principal.SecurityIdentifier]).Value
        Sddl=$security.GetSecurityDescriptorSddlForm($sections)
        Protected=[bool]$security.AreAccessRulesProtected
    }
}

function Set-CbConfigSecurity {
    param([string]$Path,[string]$Sddl)
    $sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner
    $current=Get-CbConfigSecurity $Path
    if($current.Sddl-eq$Sddl){return}
    $desired=New-Object System.Security.AccessControl.FileSecurity
    $desired.SetSecurityDescriptorSddlForm($Sddl,$sections)
    $desiredOwner=$desired.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if($current.Owner-ne$desiredOwner){throw 'config.toml Owner cannot be restored without changing ownership.'}
    # Managed SetAccessControl normalizes inherited DACL control bits and
    # setting an unchanged owner still requires WRITE_OWNER. Apply the exact
    # DACL descriptor natively after proving the owner already matches.
    Initialize-CbConfigNative
    [CodexBaseline.ConfigNative]::SetDacl($Path,$desired.GetSecurityDescriptorBinaryForm(),[bool]$desired.AreAccessRulesProtected)
    $verified=Get-CbConfigSecurity $Path
    if($verified.Sddl-ne$Sddl){
        # SetFileSecurity applies the requested protection state but can omit
        # the AUTO_INHERITED control bit on an otherwise exact DACL. A
        # DACL-only managed write restores that bit without requesting owner
        # rights; the exact postcondition below remains authoritative.
        $accessOnly=New-Object System.Security.AccessControl.FileSecurity
        $accessOnly.SetSecurityDescriptorSddlForm($Sddl,[Security.AccessControl.AccessControlSections]::Access)
        $file=New-Object System.IO.FileInfo($Path)
        if($PSVersionTable.PSEdition-eq'Core'){[System.IO.FileSystemAclExtensions]::SetAccessControl($file,$accessOnly)}else{$file.SetAccessControl($accessOnly)}
        $verified=Get-CbConfigSecurity $Path
    }
    if($verified.Sddl-ne$Sddl){throw 'config.toml Owner/DACL could not be restored exactly.'}
}

function New-CbRestrictedConfigStageSddl {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $security=New-Object System.Security.AccessControl.FileSecurity
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true,$false)
    $rule=New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]::None,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $security.AddAccessRule($rule)|Out-Null
    $sections=[Security.AccessControl.AccessControlSections]::Access-bor[Security.AccessControl.AccessControlSections]::Owner
    return $security.GetSecurityDescriptorSddlForm($sections)
}

function Assert-CbConfigPath {
    Assert-CbExistingAncestorsSafe ([IO.Path]::GetDirectoryName($script:ConfigPath))
    $item=Get-CbItem $script:ConfigPath
    if ($null -eq $item) { return $null }
    Assert-CbOrdinaryItem $item 'file'
    if ($item.Length -gt 1048576) { throw 'config.toml exceeds the 1 MiB optimizer limit.' }
    Initialize-CbConfigNative
    $identity=[CodexBaseline.ConfigNative]::FileIdentity($item.FullName)
    if ($identity -notmatch ':1$') { throw 'config.toml hard links are not supported.' }
    $security=Get-CbConfigSecurity $item.FullName
    $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($security.Owner -ne $currentSid) { throw 'config.toml must be owned by the current user.' }
    $streams=@(Get-Item -LiteralPath $item.FullName -Stream * -ErrorAction Stop)
    if (@($streams | Where-Object { $_.Stream -ne ':$DATA' }).Count -gt 0) { throw 'config.toml alternate data streams are unsupported.' }
    return [pscustomobject]@{Identity=$identity;Security=$security;Hash=(Get-CbFileHash $item.FullName);Length=$item.Length}
}

function Test-CbConfigCandidate {
    param([byte[]]$Bytes)
    if ($env:CODEX_BASELINE_TESTING -eq '1' -and
        $env:CODEX_BASELINE_TEST_REJECT_CONFIG_CANDIDATE -eq '1') {
        throw 'Injected isolated candidate validation rejection.'
    }
    if ($env:CODEX_BASELINE_TESTING -eq '1' -and $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -eq '1') { return }
    $command=Get-Command codex -ErrorAction Stop
    if ($command.CommandType -notin @('Application','ExternalScript')) { throw 'Config validation requires an ordinary Codex executable.' }
    $temporary=New-CbTemporaryDirectory
    try {
        $config=Join-Path $temporary 'config.toml'; [IO.File]::WriteAllBytes($config,$Bytes)
        $sqlite=Join-Path $temporary 'sqlite'; Ensure-CbSafeDirectory $sqlite | Out-Null
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$command.Source; $psi.Arguments='--strict-config --version'; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
        $psi.EnvironmentVariables.Clear(); $psi.EnvironmentVariables['HOME']=$temporary; $psi.EnvironmentVariables['CODEX_HOME']=$temporary; $psi.EnvironmentVariables['CODEX_SQLITE_HOME']=$sqlite; $psi.EnvironmentVariables['PATH']=[IO.Path]::GetDirectoryName($command.Source)
        $process=[Diagnostics.Process]::Start($psi); $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Codex rejected the isolated candidate config.' }
    }
    finally { if (Test-CbExists $temporary) { Remove-CbSafeItem $temporary } }
}

function Get-CbConfigTransactionPath {
    param([string]$Id)
    if ($Id -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{32}$') { throw "Invalid config transaction identifier: $Id" }
    return Join-Path $script:ConfigTransactionsPath $Id
}

function Write-CbConfigTransaction {
    param($Transaction)
    $path=Join-Path (Get-CbConfigTransactionPath ([string]$Transaction.Id)) 'transaction.json'
    Write-CbUtf8Atomic $path (($Transaction | ConvertTo-Json -Depth 10) + "`n")
}

function Assert-CbConfigArtifact {
    param([string]$Path,[string]$Label)
    $item=Get-CbItem $Path
    if($null-eq$item){return $null}
    Assert-CbOrdinaryItem $item 'file'
    if($item.Length-gt1048576){throw "$Label exceeds the 1 MiB config artifact limit."}
    Initialize-CbConfigNative
    $identity=[CodexBaseline.ConfigNative]::FileIdentity($item.FullName)
    if($identity-notmatch':1$'){throw "$Label has an unsafe hard-link count."}
    $security=Get-CbConfigSecurity $item.FullName
    $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($security.Owner-ne$currentSid){throw "$Label must be owned by the current user."}
    $streams=@(Get-Item -LiteralPath $item.FullName -Stream * -ErrorAction Stop)
    if(@($streams|Where-Object{$_.Stream-ne':$DATA'}).Count-gt0){throw "$Label has unsupported alternate data streams."}
    return [pscustomobject]@{Item=$item;Identity=$identity;Security=$security;Hash=(Get-CbFileHash $item.FullName)}
}

function Read-CbConfigTransactionRaw {
    param([string]$Id)
    $directory=Get-CbConfigTransactionPath $Id
    $directoryItem=Get-CbItem $directory
    if($null-eq$directoryItem){throw "Config transaction is missing: $Id"}
    Assert-CbOrdinaryItem $directoryItem 'tree'
    $children=@(Get-ChildItem -LiteralPath $directoryItem.FullName -Force)
    if($children.Count-ne1-or$children[0].Name-ne'transaction.json'){throw "Config transaction has an invalid file inventory: $Id"}
    Assert-CbOrdinaryItem $children[0] 'file'
    $path=$children[0].FullName
    if (-not (Test-CbExists $path)) { throw "Config transaction is missing: $Id" }
    try{return (Read-CbUtf8Text $path)|ConvertFrom-Json -ErrorAction Stop}
    catch{throw "Config transaction journal is invalid: $Id"}
}

function Assert-CbConfigToken {
    param([string]$Id,[string]$Token,[string]$Label)
    switch($Id){
      {$_-in@('agents_enabled','features_fast_mode')}{if($Token-notin@('true','false')){throw "Invalid boolean token in $Label"};break}
      'agents_max'{if($Token-notmatch'^(0|[1-9][0-9]{0,5})$'){throw "Invalid integer token in $Label"};break}
      'service_tier'{if($Token-notmatch'^"[a-z][a-z0-9_-]{0,31}"$'){throw "Invalid enum token in $Label"};break}
      default{throw "Unknown managed config key in $Label"}
    }
}

function Assert-CbConfigTransaction {
    param($Transaction,[string]$Id,[AllowNull()][string]$ExpectedState)
    $properties=@('Schema','Contract','Id','Operation','Version','CreatedUtc','Parent','CoreTransaction','State','Target','Stage','Old','PreviousExisted','PreviousPhysicalHash','DesiredPhysicalHash','PreviousProjectionHash','DesiredProjectionHash','PreviousStructureHash','DesiredStructureHash','PreviousIdentity','PreviousSecurity','DesiredIdentity','DesiredSecurity','Ownership')
    Assert-CbExactProperties $Transaction $properties "Config transaction $Id"
    if(((-not($Transaction.Schema-is[int]))-and(-not($Transaction.Schema-is[long])))-or[int64]$Transaction.Schema-ne2-or[string]$Transaction.Id-ne$Id-or[string]$Transaction.Contract-ne'codex-baseline-config-transaction/v2'){throw "Config transaction identity mismatch: $Id"}
    if([string]$Transaction.Operation-notin@('install-cap','optimize','restore','rollback','uninstall')){throw "Invalid config transaction operation: $Id"}
    if([string]$Transaction.State-notin@('planned','prepared','committing','replaced-before-security','committed','rolled-back')){throw "Invalid config transaction state: $Id"}
    if(-not[string]::IsNullOrEmpty($ExpectedState)-and[string]$Transaction.State-ne$ExpectedState){throw "Config transaction $Id is not $ExpectedState"}
    if([string]$Transaction.Version-notmatch'^\d+\.\d+\.\d+$'){throw "Invalid config transaction version: $Id"}
    $created=[DateTimeOffset]::MinValue
    $createdText=if($Transaction.CreatedUtc-is[DateTime]){$Transaction.CreatedUtc.ToUniversalTime().ToString('o')}else{[string]$Transaction.CreatedUtc}
    if($createdText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$' -or -not [DateTimeOffset]::TryParse($createdText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$created)){throw "Invalid config transaction timestamp: $Id"}
    $expectedStage=Join-Path $script:CodexHome ('.codex-baseline-config-stage-{0}'-f$Id)
    $expectedOld=Join-Path $script:CodexHome ('.codex-baseline-config-old-{0}'-f$Id)
    if(-not(Test-CbSamePath ([string]$Transaction.Target) $script:ConfigPath)){throw "Config transaction target mismatch: $Id"}
    if(-not(Test-CbSamePath ([string]$Transaction.Stage) $expectedStage)){throw "Config transaction stage mismatch: $Id"}
    if(-not(Test-CbSamePath ([string]$Transaction.Old) $expectedOld)){throw "Config transaction old-path mismatch: $Id"}
    Assert-CbConfigArtifact $expectedStage 'Config transaction stage'|Out-Null
    Assert-CbConfigArtifact $expectedOld 'Config transaction old preimage'|Out-Null
    if($Transaction.PreviousExisted-isnot[bool]){throw "Invalid config previous-existed flag: $Id"}
    foreach($name in @('PreviousPhysicalHash','DesiredPhysicalHash')){$value=[string]$Transaction.$name;if($value-ne'absent'-and$value-notmatch'^[0-9a-f]{64}$'){throw "Invalid config hash $name`: $Id"}}
    if(-not[bool]$Transaction.PreviousExisted-and[string]$Transaction.PreviousPhysicalHash-ne'absent'){throw "Config previous hash/existence mismatch: $Id"}
    foreach($name in @('PreviousProjectionHash','DesiredProjectionHash','PreviousStructureHash','DesiredStructureHash')){if([string]$Transaction.$name-notmatch'^[0-9a-f]{64}$'){throw "Invalid config hash $name`: $Id"}}
    if([bool]$Transaction.PreviousExisted){
      if([string]$Transaction.PreviousIdentity-notmatch'^[0-9A-F]{8}:[0-9A-F]{8}:[0-9A-F]{8}:1$'-or[string]::IsNullOrWhiteSpace([string]$Transaction.PreviousSecurity)){throw "Invalid config preimage metadata: $Id"}
      try{$descriptor=New-Object Security.AccessControl.FileSecurity;$sections=[Security.AccessControl.AccessControlSections]::Access-bor[Security.AccessControl.AccessControlSections]::Owner;$descriptor.SetSecurityDescriptorSddlForm([string]$Transaction.PreviousSecurity,$sections)}catch{throw "Invalid config security descriptor: $Id"}
    }elseif($null-ne$Transaction.PreviousIdentity-or$null-ne$Transaction.PreviousSecurity){throw "Absent config transaction contains preimage metadata: $Id"}
    $hasDesiredMetadata=$null-ne$Transaction.DesiredIdentity-or$null-ne$Transaction.DesiredSecurity
    if($hasDesiredMetadata){
      if([string]$Transaction.DesiredIdentity-notmatch'^[0-9A-F]{8}:[0-9A-F]{8}:[0-9A-F]{8}:1$'-or[string]::IsNullOrWhiteSpace([string]$Transaction.DesiredSecurity)){throw "Invalid config desired metadata: $Id"}
      try{$descriptor=New-Object Security.AccessControl.FileSecurity;$sections=[Security.AccessControl.AccessControlSections]::Access-bor[Security.AccessControl.AccessControlSections]::Owner;$descriptor.SetSecurityDescriptorSddlForm([string]$Transaction.DesiredSecurity,$sections)}catch{throw "Invalid config desired security descriptor: $Id"}
    }
    elseif([string]$Transaction.State-in@('prepared','committing','replaced-before-security','committed')){throw "Config desired metadata is missing: $Id"}
    $seen=@{$Id=$true};$cursor=if($null-eq$Transaction.Parent){''}else{[string]$Transaction.Parent}
    while(-not[string]::IsNullOrWhiteSpace($cursor)){
      if($cursor-notmatch'^\d{8}T\d{6}Z-[0-9a-f]{32}$'-or$seen.ContainsKey($cursor)){throw "Config transaction parent cycle or identifier mismatch: $Id"}
      $seen[$cursor]=$true;$parent=Read-CbConfigTransactionRaw $cursor
      Assert-CbExactProperties $parent $properties "Config transaction parent $cursor"
      if([string]$parent.Id-ne$cursor-or[string]$parent.State-ne'committed'){throw "Config transaction parent is not committed: $cursor"}
      $cursor=if($null-eq$parent.Parent){''}else{[string]$parent.Parent}
    }
    if($null-ne$Transaction.CoreTransaction){
      if([string]::IsNullOrWhiteSpace([string]$Transaction.CoreTransaction)){throw "Config transaction has an empty core binding: $Id"}
      $core=Read-CbTransaction ([string]$Transaction.CoreTransaction);Assert-CbTransactionShape $core $false
    }
    $allowed=@('agents_enabled','agents_max','service_tier','features_fast_mode');$ids=@{}
    foreach($owned in @($Transaction.Ownership)){
      Assert-CbExactProperties $owned @('Id','Path','Table','Type','PriorState','PriorToken','PriorFileExisted','InstalledToken','CreatedTable','SeparatorAdded','PriorFinalNewline') "Config ownership entry"
      $ownedId=[string]$owned.Id
      if($ownedId-notin$allowed-or$ids.ContainsKey($ownedId)){throw "Invalid or duplicate config ownership key: $ownedId"};$ids[$ownedId]=$true
      $meta=Get-CbConfigKeyMetadata $ownedId
      if([string]$owned.Path-ne[string]$meta.Path-or[string]$owned.Table-ne[string]$meta.Table-or[string]$owned.Type-ne[string]$meta.Type){throw "Config ownership metadata mismatch: $ownedId"}
      foreach($flag in @('PriorFileExisted','CreatedTable','SeparatorAdded','PriorFinalNewline')){if($owned.$flag-isnot[bool]){throw "Invalid config ownership flag $flag`: $ownedId"}}
      if([string]$owned.PriorState-eq'present'){Assert-CbConfigToken $ownedId ([string]$owned.PriorToken) "$ownedId/PriorToken"}
      elseif([string]$owned.PriorState-eq'absent'){if(-not[string]::IsNullOrEmpty([string]$owned.PriorToken)){throw "Absent config ownership has a prior token: $ownedId"}}
      else{throw "Invalid config ownership prior state: $ownedId"}
      Assert-CbConfigToken $ownedId ([string]$owned.InstalledToken) "$ownedId/InstalledToken"
    }
}

function Read-CbConfigTransaction {
    param([string]$Id,[AllowNull()][string]$ExpectedState=$null)
    $transaction=Read-CbConfigTransactionRaw $Id
    Assert-CbConfigTransaction $transaction $Id $ExpectedState
    return $transaction
}

function Get-CbCurrentConfigTransaction {
    $id=Read-CbPointer $script:ConfigCurrentPath
    if ($null -eq $id) { return $null }
    $transaction=Read-CbConfigTransaction $id 'committed'
    return $transaction
}

function Assert-CbConfigOwnershipClean {
    param($Current, $Document)
    if ($null -eq $Current) { return }
    foreach ($owned in @($Current.Ownership)) {
        $live = if ($Document.Keys.ContainsKey([string]$owned.Id)) { [string]$Document.Keys[[string]$owned.Id].Token } else { '__ABSENT__' }
        if ($live -ne [string]$owned.InstalledToken) { throw "Managed config key drifted: $($owned.Path)" }
    }
}

function Get-CbConfigProjectionHash {
    param($Document)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach($id in @('agents_enabled','agents_max','service_tier','features_fast_mode')){
        $token=if($Document.Keys.ContainsKey($id)){[string]$Document.Keys[$id].Token}else{'__ABSENT__'}
        $lines.Add(('{0}`t{1}'-f(Get-CbConfigKeyMetadata $id).Path,$token))|Out-Null
    }
    return Get-CbStringHash (([string]::Join("`n",$lines))+"`n")
}

function Get-CbConfigStructureHash {
    param($Document)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add(('bom={0}'-f$(if($Document.Bom){1}else{0})))|Out-Null
    $lines.Add(('final-newline={0}'-f$(if($Document.Lines.Count-gt0-and[string]$Document.Lines[$Document.Lines.Count-1].Ending-ne''){1}else{0})))|Out-Null
    foreach($id in @('agents_enabled','agents_max','service_tier','features_fast_mode')){$lines.Add(('{0}`t{1}'-f(Get-CbConfigKeyMetadata $id).Path,$(if($Document.Keys.ContainsKey($id)){[int]$Document.Keys[$id].Index}else{'absent'})))|Out-Null}
    foreach($table in @('agents','features')){$lines.Add(('table-{0}={1}'-f$table,$(if($Document.Tables.ContainsKey($table)){[int]$Document.Tables[$table]}else{'absent'})))|Out-Null}
    return Get-CbStringHash (([string]::Join("`n",$lines))+"`n")
}

function Recover-CbConfigPending {
    $id=Read-CbPointer $script:ConfigPendingPath
    if ($null -eq $id) { return }
    $tx=Read-CbConfigTransaction $id
    $targetPre=Assert-CbConfigPath
    $target=Get-CbItem $script:ConfigPath; $live=if($null -eq $target){'absent'}else{Get-CbFileHash $target.FullName}
    if ($live -eq [string]$tx.DesiredPhysicalHash) {
        $oldArtifact=$null
        if([bool]$tx.PreviousExisted){
            $oldArtifact=Assert-CbConfigArtifact ([string]$tx.Old) 'Config recovery preimage'
            if($null-eq$oldArtifact-or[string]$oldArtifact.Hash-ne[string]$tx.PreviousPhysicalHash-or[string]$oldArtifact.Identity-ne[string]$tx.PreviousIdentity-or[string]$oldArtifact.Security.Sddl-ne[string]$tx.PreviousSecurity){throw 'Config recovery preimage metadata is unverifiable.'}
            if([string]$tx.DesiredSecurity-ne[string]$oldArtifact.Security.Sddl){throw 'Config recovery live desired metadata is unverifiable.'}
        }
        if($live-ne'absent'){
            if($null-eq$targetPre-or$targetPre.Identity-ne[string]$tx.DesiredIdentity){throw 'Config recovery live desired metadata is unverifiable.'}
            if($targetPre.Security.Sddl-ne[string]$tx.DesiredSecurity){
                if([string]$tx.State-notin@('committing','replaced-before-security')-or$null-eq$oldArtifact){throw 'Config recovery live desired metadata is unverifiable.'}
                Set-CbConfigSecurity $script:ConfigPath ([string]$oldArtifact.Security.Sddl)
                $targetPre=Assert-CbConfigPath
                if($null-eq$targetPre-or$targetPre.Identity-ne[string]$tx.DesiredIdentity-or$targetPre.Security.Sddl-ne[string]$tx.DesiredSecurity){throw 'Config recovery could not restore desired Owner/DACL metadata.'}
            }
        }
        Write-CbPointer $script:ConfigCurrentPath $id; $tx.State='committed'; Write-CbConfigTransaction $tx
        foreach($path in @([string]$tx.Stage,[string]$tx.Old)){if(Test-CbExists $path){Remove-Item -LiteralPath $path -Force}}
    }
    elseif ($live -eq [string]$tx.PreviousPhysicalHash -or (-not [bool]$tx.PreviousExisted -and $live -eq 'absent')) {
        if([bool]$tx.PreviousExisted-and($null-eq$targetPre-or$targetPre.Identity-ne[string]$tx.PreviousIdentity-or$targetPre.Security.Sddl-ne[string]$tx.PreviousSecurity)){throw 'Config recovery live preimage metadata is unverifiable.'}
        foreach($path in @([string]$tx.Stage,[string]$tx.Old)){if(Test-CbExists $path){Remove-Item -LiteralPath $path -Force}}
        $tx.State='rolled-back'; Write-CbConfigTransaction $tx
    }
    elseif ($live -eq 'absent' -and [bool]$tx.PreviousExisted -and (Test-CbExists ([string]$tx.Old))) {
        $oldArtifact=Assert-CbConfigArtifact ([string]$tx.Old) 'Config recovery restore preimage'
        if($null-eq$oldArtifact-or$oldArtifact.Hash-ne[string]$tx.PreviousPhysicalHash-or$oldArtifact.Identity-ne[string]$tx.PreviousIdentity-or$oldArtifact.Security.Sddl-ne[string]$tx.PreviousSecurity){throw 'Config recovery restore preimage metadata is unverifiable.'}
        [IO.File]::Move([string]$tx.Old,$script:ConfigPath)
        $restored=Assert-CbConfigPath
        if($null-eq$restored-or$restored.Hash-ne[string]$tx.PreviousPhysicalHash-or$restored.Identity-ne[string]$tx.PreviousIdentity-or$restored.Security.Sddl-ne[string]$tx.PreviousSecurity){throw 'Config recovery restored target metadata is unverifiable.'}
        $tx.State='rolled-back'; Write-CbConfigTransaction $tx
    }
    else { throw 'Config transaction recovery found an unverifiable target state.' }
    Remove-Item -LiteralPath $script:ConfigPendingPath -Force
}

function Invoke-CbConfigActions {
    param([string]$Operation, [hashtable]$Actions, [hashtable]$NextOwnership, [AllowNull()][string]$CoreTransaction, [bool]$ApplyChanges)
    $pre=Assert-CbConfigPath
    $document=Read-CbConfigDocument
    $current=Get-CbCurrentConfigTransaction
    $coreBinding=if(-not[string]::IsNullOrWhiteSpace([string]$CoreTransaction)){[string]$CoreTransaction}elseif($null-ne$current-and$null-ne$current.CoreTransaction-and-not[string]::IsNullOrWhiteSpace([string]$current.CoreTransaction)){[string]$current.CoreTransaction}else{$null}
    Assert-CbConfigOwnershipClean $current $document
    $original=$document; $candidate=$document
    $currentFinalEnding=if($original.Lines.Count-gt0){[string]$original.Lines[$original.Lines.Count-1].Ending}else{''}
    $order=@('agents_enabled','agents_max','service_tier','features_fast_mode')
    foreach($id in $order){if($Actions.ContainsKey($id)){$candidate=Update-CbConfigDocumentKey $candidate $id ([string]$Actions[$id])}}
    if($null -ne $current){
        foreach($table in @('agents','features')){
            $owned=@($current.Ownership|Where-Object{$_.Table -eq $table -and [bool]$_.CreatedTable})|Select-Object -First 1
            if($null -ne $owned){$candidate=Remove-CbEmptyCreatedConfigTable $candidate $table ([bool]$owned.SeparatorAdded) $currentFinalEnding}
        }
    }
    $beforeBytes=ConvertTo-CbConfigBytes $original; $candidateBytes=ConvertTo-CbConfigBytes $candidate
    $beforeHash=if($null -eq $pre){'absent'}else{Get-CbSha256Bytes $beforeBytes}; $desiredHash=Get-CbSha256Bytes $candidateBytes
    if($beforeHash -eq $desiredHash){$script:LastConfigTransaction=$null;return $null}
    Test-CbConfigCandidate $candidateBytes
    if($env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION-ne'1'){
        if($candidate.Keys.ContainsKey('agents_enabled')-or$candidate.Keys.ContainsKey('agents_max')){$script:VerifiedAgentsConfigCapability=$true}
        if($candidate.Keys.ContainsKey('service_tier')-and[string]$candidate.Keys['service_tier'].Token-eq'"fast"'-and$candidate.Keys.ContainsKey('features_fast_mode')-and[string]$candidate.Keys['features_fast_mode'].Token-eq'true'){$script:VerifiedFastConfigCapability=$true}
    }
    if(-not $ApplyChanges){$script:LastConfigTransaction=$null;return $null}
    Ensure-CbSafeDirectory $script:ConfigTransactionsPath|Out-Null
    $id=New-CbId; $directory=Get-CbConfigTransactionPath $id; Ensure-CbSafeDirectory $directory|Out-Null
    $ownership=New-Object 'System.Collections.Generic.List[object]'
    if($null -ne $current){foreach($entry in @($current.Ownership)){$ownership.Add([pscustomobject]@{Id=[string]$entry.Id;Path=[string]$entry.Path;Table=[string]$entry.Table;Type=[string]$entry.Type;PriorState=[string]$entry.PriorState;PriorToken=[string]$entry.PriorToken;PriorFileExisted=$(if($null-ne$entry.PSObject.Properties['PriorFileExisted']){[bool]$entry.PriorFileExisted}else{$true});InstalledToken=[string]$entry.InstalledToken;CreatedTable=[bool]$entry.CreatedTable;SeparatorAdded=[bool]$entry.SeparatorAdded;PriorFinalNewline=[bool]$entry.PriorFinalNewline})|Out-Null}}
    foreach($keyId in $order){
        if(-not $Actions.ContainsKey($keyId)){continue}
        $existing=@($ownership|Where-Object{$_.Id -eq $keyId})|Select-Object -First 1
        if(-not [bool]$NextOwnership[$keyId]){if($null -ne $existing){$ownership.Remove($existing)|Out-Null};continue}
        if($null -eq $existing){
            $meta=Get-CbConfigKeyMetadata $keyId; $priorPresent=$original.Keys.ContainsKey($keyId); $priorFinal=$original.Lines.Count -gt 0 -and [string]$original.Lines[$original.Lines.Count-1].Ending -ne ''
            $created=-not [string]::IsNullOrEmpty([string]$meta.Table) -and -not $original.Tables.ContainsKey([string]$meta.Table)
            $separator=$created -and $original.Lines.Count -gt 0 -and [string]$original.Lines[$original.Lines.Count-1].Body -ne ''
            $existing=[pscustomobject]@{Id=$keyId;Path=$meta.Path;Table=$meta.Table;Type=$meta.Type;PriorState=$(if($priorPresent){'present'}else{'absent'});PriorToken=$(if($priorPresent){[string]$original.Keys[$keyId].Token}else{''});PriorFileExisted=($null-ne$pre);InstalledToken='';CreatedTable=$created;SeparatorAdded=$separator;PriorFinalNewline=$priorFinal}
            $ownership.Add($existing)|Out-Null
        }
        $existing.InstalledToken=[string]$Actions[$keyId]
    }
    $desiredPresent=$true
    if($Operation-in@('restore','rollback','uninstall')-and$candidateBytes.Length-eq 0-and$null-ne$current){
        $allReleased=$true;$originAbsent=$false
        foreach($entry in @($current.Ownership)){
            if(-not$NextOwnership.ContainsKey([string]$entry.Id)-or[bool]$NextOwnership[[string]$entry.Id]){$allReleased=$false}
            if($null-ne$entry.PSObject.Properties['PriorFileExisted']-and-not[bool]$entry.PriorFileExisted){$originAbsent=$true}
        }
        if($allReleased-and$originAbsent){$desiredPresent=$false;$desiredHash='absent'}
    }
    $stage=Join-Path $script:CodexHome ('.codex-baseline-config-stage-{0}' -f $id); $old=Join-Path $script:CodexHome ('.codex-baseline-config-old-{0}' -f $id)
    if((Test-CbExists $stage)-or(Test-CbExists $old)){throw 'Config staging collision.'}
    $versionPath=Join-Path $script:SourceRoot 'VERSION'
    if(Test-CbExists $versionPath){$transactionVersion=(Read-CbUtf8Text $versionPath).Trim()}
    elseif($null-ne$coreBinding){
        $versionCore=Read-CbTransaction $coreBinding;Assert-CbTransactionShape $versionCore $true
        if([string]$versionCore.State-ne'committed'){throw 'Config recovery version core is not committed.'}
        $transactionVersion=[string]$versionCore.Version
    }
    else{throw 'Config transaction version source is unavailable.'}
    $tx=[pscustomobject]@{Schema=2;Contract='codex-baseline-config-transaction/v2';Id=$id;Operation=$Operation;Version=$transactionVersion;CreatedUtc=[DateTime]::UtcNow.ToString('o');Parent=$(if($null -eq $current){$null}else{[string]$current.Id});CoreTransaction=$coreBinding;State='planned';Target=$script:ConfigPath;Stage=$stage;Old=$old;PreviousExisted=($null-ne$pre);PreviousPhysicalHash=$beforeHash;DesiredPhysicalHash=$desiredHash;PreviousProjectionHash=(Get-CbConfigProjectionHash $original);DesiredProjectionHash=(Get-CbConfigProjectionHash $candidate);PreviousStructureHash=(Get-CbConfigStructureHash $original);DesiredStructureHash=(Get-CbConfigStructureHash $candidate);PreviousIdentity=$(if($null-eq$pre){$null}else{[string]$pre.Identity});PreviousSecurity=$(if($null-eq$pre){$null}else{[string]$pre.Security.Sddl});DesiredIdentity=$null;DesiredSecurity=$null;Ownership=$ownership.ToArray()}
    Write-CbConfigTransaction $tx
    Write-CbPointer $script:ConfigPendingPath $id
    $stageStream=$null
    try{
        # Create an empty stage, protect it before the first candidate byte, and
        # deny data opens until the same handle has been flushed. The closed
        # stage remains owner-only until atomic replacement; the target ACL is
        # applied only at the target path.
        $stageStream=New-Object System.IO.FileStream(
            $stage,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Delete
        )
        $restrictedStageSddl=New-CbRestrictedConfigStageSddl
        Set-CbConfigSecurity $stage $restrictedStageSddl
        $restrictedStageSecurity=Get-CbConfigSecurity $stage
        if(-not$restrictedStageSecurity.Protected-or$restrictedStageSecurity.Sddl-ne$restrictedStageSddl-or$stageStream.Length-ne0){
            throw 'Config replacement stage was not restrictively protected before candidate bytes.'
        }
        if($candidateBytes.Length-gt0){$stageStream.Write($candidateBytes,0,$candidateBytes.Length)}
        $stageStream.Flush($true)
        if($env:CODEX_BASELINE_TESTING-eq'1'-and-not[string]::IsNullOrWhiteSpace($env:CODEX_BASELINE_TEST_CONFIG_STAGE_CONFIDENTIALITY_MARKER)){
            if($stageStream.Length-ne$candidateBytes.Length){throw 'Config replacement stage was not fully flushed under exclusive access.'}
            $readBlocked=$false
            try{[IO.File]::ReadAllBytes($stage)|Out-Null}
            catch [System.IO.IOException]{$readBlocked=$true}
            if(-not$readBlocked){throw 'Config replacement stage candidate bytes were readable before atomic replace.'}
            [IO.File]::WriteAllText($env:CODEX_BASELINE_TEST_CONFIG_STAGE_CONFIDENTIALITY_MARKER,"protected-empty-before-write;exclusive-through-flush`n",$script:Utf8NoBom)
        }
        Initialize-CbConfigNative
        $desiredIdentity=[CodexBaseline.ConfigNative]::FileIdentity($stage)
    }
    finally{if($null-ne$stageStream){$stageStream.Dispose()}}
    $restrictedStageSecurity=Get-CbConfigSecurity $stage
    if(-not$restrictedStageSecurity.Protected-or$restrictedStageSecurity.Sddl-ne$restrictedStageSddl){throw 'Config replacement stage protection changed before atomic replace.'}
    $targetSecurity=if($null-ne$pre){[string]$pre.Security.Sddl}else{$restrictedStageSddl}
    $tx.DesiredIdentity=$desiredIdentity
    $tx.DesiredSecurity=$targetSecurity
    $tx.State='prepared';Write-CbConfigTransaction $tx
    $tx.State='committing'; Write-CbConfigTransaction $tx
    $now=Assert-CbConfigPath
    if($null-ne$pre){
        if($null-eq$now -or $now.Hash-ne$beforeHash -or $now.Identity-ne$pre.Identity -or $now.Security.Sddl-ne$pre.Security.Sddl){throw 'config.toml changed before atomic replace.'}
        if($desiredPresent){[IO.File]::Replace($stage,$script:ConfigPath,$old,$false)}else{[IO.File]::Move($script:ConfigPath,$old);Remove-Item -LiteralPath $stage -Force}
    }
    else{if($null-ne$now){throw 'config.toml appeared before atomic create.'};if($desiredPresent){[IO.File]::Move($stage,$script:ConfigPath)}else{Remove-Item -LiteralPath $stage -Force}}
    $tx.State='replaced-before-security'; Write-CbConfigTransaction $tx
    if($env:CODEX_BASELINE_TESTING-eq'1'-and$env:CODEX_BASELINE_TEST_HALT_AFTER_CONFIG_REPLACE_BEFORE_SECURITY-eq'1'){
        [Environment]::Exit(97)
    }
    if($desiredPresent){
        $replacementSecurity=Get-CbConfigSecurity $script:ConfigPath
        if($replacementSecurity.Sddl-ne$targetSecurity){Set-CbConfigSecurity $script:ConfigPath $targetSecurity}
        $replacementSecurity=Get-CbConfigSecurity $script:ConfigPath
        if($replacementSecurity.Sddl-ne$targetSecurity){throw 'Config replacement target Owner/DACL was not verified exactly.'}
    }
    if($env:CODEX_BASELINE_TESTING-eq'1'-and$env:CODEX_BASELINE_TEST_HALT_AFTER_CONFIG_REPLACE-eq'1'){
        [Environment]::Exit(97)
    }
    if($env:CODEX_BASELINE_TESTING-eq'1'-and$env:CODEX_BASELINE_TEST_FAULT_AFTER_CONFIG_REPLACE-eq'1'){throw 'Injected test fault after config replace'}
    $after=Assert-CbConfigPath
    if($desiredPresent){if($null-eq$after-or$after.Hash-ne$desiredHash){throw 'config.toml post-commit hash mismatch.'}}
    elseif($null-ne$after){throw 'config.toml post-commit absence mismatch.'}
    if($desiredPresent-and($after.Identity-ne[string]$tx.DesiredIdentity-or$after.Security.Sddl-ne[string]$tx.DesiredSecurity)){throw 'config.toml identity or Owner/DACL changed during replace.'}
    if($null-ne$pre){
        $committedOld=Assert-CbConfigArtifact $old 'Config transaction committed preimage'
        if($null-eq$committedOld-or$committedOld.Hash-ne$beforeHash-or$committedOld.Identity-ne$pre.Identity-or$committedOld.Security.Sddl-ne$pre.Security.Sddl){throw 'config.toml committed preimage metadata is unverifiable.'}
    }
    Assert-CbConfigOwnershipClean $tx (Read-CbConfigDocument)
    Write-CbPointer $script:ConfigCurrentPath $id; $tx.State='committed'; Write-CbConfigTransaction $tx; Remove-Item -LiteralPath $script:ConfigPendingPath -Force
    if(Test-CbExists $old){Remove-Item -LiteralPath $old -Force}
    $script:LastConfigTransaction=$tx
    return $tx
}

function Get-CbConfigRestorePlan {
    $current=Get-CbCurrentConfigTransaction
    if($null-eq$current -or @($current.Ownership).Count-eq 0){return $null}
    $actions=@{};$next=@{}
    foreach($owned in @($current.Ownership)){$actions[[string]$owned.Id]=if([string]$owned.PriorState-eq'present'){[string]$owned.PriorToken}else{'__ABSENT__'};$next[[string]$owned.Id]=$false}
    return [pscustomobject]@{Actions=$actions;Next=$next;Current=$current}
}

function Invoke-CbConfigRestore {
    param([string]$Operation='restore',[AllowNull()][string]$CoreTransaction,[bool]$ApplyChanges=$true)
    $plan=Get-CbConfigRestorePlan
    if($null-eq$plan){return $null}
    return Invoke-CbConfigActions $Operation $plan.Actions $plan.Next $CoreTransaction $ApplyChanges
}

function Invoke-CbConfigAutoCap {
    param([string]$CoreTransaction,[bool]$ApplyChanges)
    $plan=Get-CbConfigAutoCapPlan
    if(-not[bool]$plan.Change){return $plan}
    if(-not$ApplyChanges){return $plan}
    return Invoke-CbConfigActions 'install-cap' @{agents_max='6'} @{agents_max=$true} $CoreTransaction $true
}

function Get-CbConfigAutoCapPlan {
    Assert-CbConfigPath|Out-Null
    $document=Read-CbConfigDocument
    if($document.Keys.ContainsKey('agents_enabled')-and[string]$document.Keys['agents_enabled'].Token-eq'false'){
        return [pscustomobject]@{Change=$false;Path='agents.max_concurrent_threads_per_session';Prior='absent';Desired=$null;Reason='agents.enabled=false user override'}
    }
    if($document.Keys.ContainsKey('features_multi_agent')-and[string]$document.Keys['features_multi_agent'].Token-eq'false'){
        return [pscustomobject]@{Change=$false;Path='agents.max_concurrent_threads_per_session';Prior='absent';Desired=$null;Reason='features.multi_agent=false user override'}
    }
    if($document.Keys.ContainsKey('agents_max')){
        return [pscustomobject]@{Change=$false;Path='agents.max_concurrent_threads_per_session';Prior=[string]$document.Keys['agents_max'].Token;Desired=$null;Reason='existing user cap'}
    }
    if($document.Keys.ContainsKey('agents_legacy_max')){
        return [pscustomobject]@{Change=$false;Path='agents.max_concurrent_threads_per_session';Prior=[string]$document.Keys['agents_legacy_max'].Token;Desired=$null;Reason='existing legacy user cap'}
    }
    # Exercise the complete candidate, ownership, isolated-Codex validation,
    # and byte-preservation path before any core/composite transaction exists.
    Invoke-CbConfigActions 'install-cap' @{agents_max='6'} @{agents_max=$true} $null $false|Out-Null
    return [pscustomobject]@{Change=$true;Path='agents.max_concurrent_threads_per_session';Prior='absent';Desired='6';Reason='previously absent'}
}

function Write-CbConfigAutoCapPlan {
    param($Plan)
    if([bool]$Plan.Change){Write-Output ("install-cap plan: {0}: {1} -> {2}"-f$Plan.Path,$Plan.Prior,$Plan.Desired)}
    else{Write-Output ("install-cap plan: no change ({0})"-f$Plan.Reason)}
}

function Get-CbCompositeTransactionPath {
    param([string]$Id)
    if($Id-notmatch'^\d{8}T\d{6}Z-[0-9a-f]{32}$'){throw "Invalid composite transaction identifier: $Id"}
    return Join-Path $script:CompositeTransactionsPath $Id
}

function Write-CbCompositeTransaction {
    param($Transaction)
    $path=Join-Path (Get-CbCompositeTransactionPath ([string]$Transaction.Id)) 'transaction.json'
    Write-CbUtf8Atomic $path (($Transaction|ConvertTo-Json -Depth 4)+"`n")
}

function Read-CbCompositeTransaction {
    param([string]$Id)
    $directory=Get-CbCompositeTransactionPath $Id;$item=Get-CbItem $directory
    if($null-eq$item){throw "Composite transaction is missing: $Id"};Assert-CbOrdinaryItem $item 'tree'
    $children=@(Get-ChildItem -LiteralPath $item.FullName -Force)
    if($children.Count-ne1-or$children[0].Name-ne'transaction.json'){throw "Composite transaction has an invalid file inventory: $Id"}
    Assert-CbOrdinaryItem $children[0] 'file'
    try{$tx=(Read-CbUtf8Text $children[0].FullName)|ConvertFrom-Json -ErrorAction Stop}catch{throw "Composite transaction journal is invalid: $Id"}
    Assert-CbExactProperties $tx @('Schema','Contract','Id','Operation','CreatedUtc','SourceCore','DesiredCore','State') "Composite transaction $Id"
    if(((-not($tx.Schema-is[int]))-and(-not($tx.Schema-is[long])))-or[int64]$tx.Schema-ne2-or[string]$tx.Contract-ne'codex-baseline-composite-transaction/v2'-or[string]$tx.Id-ne$Id){throw "Composite transaction identity mismatch: $Id"}
    if([string]$tx.Operation-notin@('install','rollback','uninstall')-or[string]$tx.State-notin@('planned','committed','rolled-back')){throw "Composite transaction operation or state is invalid: $Id"}
    $created=[DateTimeOffset]::MinValue
    $createdText=if($tx.CreatedUtc-is[DateTime]){$tx.CreatedUtc.ToUniversalTime().ToString('o')}else{[string]$tx.CreatedUtc}
    if($createdText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$' -or -not [DateTimeOffset]::TryParse($createdText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$created)){throw "Composite transaction timestamp is invalid: $Id"}
    $source=if($null-eq$tx.SourceCore){''}else{[string]$tx.SourceCore};$desired=if($null-eq$tx.DesiredCore){''}else{[string]$tx.DesiredCore}
    foreach($coreId in @($source,$desired)){if(-not[string]::IsNullOrWhiteSpace($coreId)){$core=Read-CbTransaction $coreId;Assert-CbTransactionShape $core $false}}
    switch([string]$tx.Operation){
      'install'{if(-not[string]::IsNullOrEmpty($source)-or[string]::IsNullOrEmpty($desired)){throw "Invalid install composite endpoints: $Id"}}
      'rollback'{if([string]::IsNullOrEmpty($source)-or$source-eq$desired){throw "Invalid rollback composite endpoints: $Id"}}
      'uninstall'{if([string]::IsNullOrEmpty($source)-or[string]::IsNullOrEmpty($desired)-or$source-eq$desired){throw "Invalid uninstall composite endpoints: $Id"}}
    }
    return $tx
}

function New-CbCompositeTransaction {
    param([string]$Operation,[AllowNull()][string]$SourceCore,[AllowNull()][string]$DesiredCore)
    if(Test-CbExists $script:CompositePendingPath){throw 'Another composite transaction is pending.'}
    Ensure-CbSafeDirectory $script:CompositeTransactionsPath|Out-Null
    $id=New-CbId;$directory=Get-CbCompositeTransactionPath $id;Ensure-CbSafeDirectory $directory|Out-Null
    $tx=[pscustomobject]@{Schema=2;Contract='codex-baseline-composite-transaction/v2';Id=$id;Operation=$Operation;CreatedUtc=[DateTime]::UtcNow.ToString('o');SourceCore=$SourceCore;DesiredCore=$DesiredCore;State='planned'}
    Write-CbCompositeTransaction $tx;Read-CbCompositeTransaction $id|Out-Null;Write-CbPointer $script:CompositePendingPath $id;$script:ActiveComposite=$id
    return $tx
}

function Complete-CbCompositeTransaction {
    param($Transaction,[string]$State)
    $Transaction.State=$State;Write-CbCompositeTransaction $Transaction
    if(Test-CbExists $script:CompositePendingPath){Remove-Item -LiteralPath $script:CompositePendingPath -Force}
    $script:ActiveComposite=$null
}

function Test-CbCoreTransactionInLineage {
    param([string]$Descendant,[string]$Ancestor)
    if([string]::IsNullOrWhiteSpace($Descendant)-or[string]::IsNullOrWhiteSpace($Ancestor)){return $false}
    $seen=@{};$cursor=$Descendant
    while(-not[string]::IsNullOrWhiteSpace($cursor)){
        if($seen.ContainsKey($cursor)){throw 'Core transaction lineage contains a cycle.'}
        $seen[$cursor]=$true
        $core=Read-CbTransaction $cursor;Assert-CbTransactionShape $core $false
        if([string]$core.Id-eq$Ancestor){return $true}
        $cursor=if($null-eq$core.ParentTransaction){''}else{[string]$core.ParentTransaction}
    }
    return $false
}

function Recover-CbCompositePending {
    $id=Read-CbPointer $script:CompositePendingPath
    if($null-eq$id){return}
    $tx=Read-CbCompositeTransaction $id
    if([string]$tx.State-in@('committed','rolled-back')){Remove-Item -LiteralPath $script:CompositePendingPath -Force;$script:ActiveComposite=$null;return}
    $source=if($null-eq$tx.SourceCore){''}else{[string]$tx.SourceCore};$desired=if($null-eq$tx.DesiredCore){''}else{[string]$tx.DesiredCore}
    $current=Get-CbCurrentTransaction;$currentId=if($null-eq$current){''}else{[string]$current.Id}
    if($currentId-eq$desired){
      switch([string]$tx.Operation){
        'install'{Invoke-CbConfigAutoCap $desired $true|Out-Null}
        'rollback'{ $config=Get-CbCurrentConfigTransaction;if($null-ne$config-and[string]$config.CoreTransaction-eq$source){Invoke-CbConfigRestore 'rollback' $source $true|Out-Null} }
        'uninstall'{
          $config=Get-CbCurrentConfigTransaction
          if($null-ne$config){
            $configCore=if($null-eq$config.CoreTransaction){''}else{[string]$config.CoreTransaction}
            if(-not[string]::IsNullOrWhiteSpace($configCore)-and-not(Test-CbCoreTransactionInLineage $source $configCore)){throw 'Baseline-owned config state is not bound to the uninstall core lineage.'}
            Invoke-CbConfigRestore 'uninstall' $source $true|Out-Null
          }
        }
      }
      Complete-CbCompositeTransaction $tx 'committed';return
    }
    if($currentId-eq$source){Complete-CbCompositeTransaction $tx 'rolled-back';return}
    throw 'Composite recovery found an unverifiable core state.'
}

function Write-CbOptimizeReport {
    param([string]$Mode,[string]$Status,[bool]$Applied,[string]$RequestedSpeed,[long]$BytesChanged,[bool]$Drift=$false)
    $document=Read-CbConfigDocument;$current=Get-CbCurrentConfigTransaction
    $enabled=if($document.Keys.ContainsKey('agents_enabled')){[string]$document.Keys['agents_enabled'].Token}else{$null}
    $featureEnabled=if($document.Keys.ContainsKey('features_multi_agent')){[string]$document.Keys['features_multi_agent'].Token}else{$null}
    $cap=if($document.Keys.ContainsKey('agents_max')){[int64]$document.Keys['agents_max'].Token}else{$null}
    $legacy=if($document.Keys.ContainsKey('agents_legacy_max')){[int64]$document.Keys['agents_legacy_max'].Token}else{$null}
    $report=[ordered]@{schema=1;contract='codex-baseline-optimize/v1';mode=$Mode;status=$Status;apply=$Applied;config=$script:ConfigPath;agents=[ordered]@{enabled=$(if($null-eq$enabled){$null}else{$enabled-eq'true'});cap=$cap;legacy_cap=$legacy;effective_override=($enabled-eq'false'-or$featureEnabled-eq'false'-or$null-ne$cap-or$null-ne$legacy)};speed=$RequestedSpeed;managed_keys=@($(if($null-ne$current){@($current.Ownership|ForEach-Object{[string]$_.Path})}));drift=$Drift;bytes_changed=$BytesChanged;capabilities=[ordered]@{agents=$(if($script:VerifiedAgentsConfigCapability){'available'}else{'unverified'});fast=$(if($script:VerifiedFastConfigCapability){'available'}else{'unverified'});ultrafast='unavailable'};limitations=@('runtime depth/model/concurrency telemetry may remain unverified','capability availability requires a successful native isolated strict-config validation in this invocation','cooperative CAS is not a hostile-writer or power-loss guarantee')}
    if($Json){[Console]::Out.WriteLine(($report|ConvertTo-Json -Depth 6 -Compress))}else{[Console]::Out.WriteLine(("Optimizer: {0} ({1})`nConfig: {2}`nAgents: enabled={3} cap={4} legacy-cap={5}`nSpeed: {6}`nManaged keys: {7}`nUltrafast: unavailable; bytes changed: {8}"-f$Status,$Mode,$script:ConfigPath,$report.agents.enabled,$cap,$legacy,$RequestedSpeed,(@($report.managed_keys)-join','),$BytesChanged))}
}

function Invoke-CbOptimize {
    Initialize-CbPaths
    if($DryRun-and$Apply){throw '-DryRun and -Apply are mutually exclusive.'}
    if($Check-and($Restore-or$Apply-or$DryRun-or$Speed-ne'keep')){throw '-Check cannot be combined with -Restore, -Speed, -DryRun, or -Apply.'}
    if($Restore-and$Speed-ne'keep'){throw '-Restore cannot be combined with -Speed.'}
    if($Speed-eq'ultrafast'){Write-CbOptimizeReport 'optimize' 'unavailable' $false 'ultrafast' 0;return 3}
    if(-not$Restore-and-not$Apply-and-not$DryRun-and$Speed-eq'keep'){
        Assert-CbConfigPath|Out-Null
        $document=Read-CbConfigDocument;$current=Get-CbCurrentConfigTransaction;$drift=$false
        if($null-ne$current){foreach($owned in @($current.Ownership)){$live=if($document.Keys.ContainsKey([string]$owned.Id)){[string]$document.Keys[[string]$owned.Id].Token}else{'__ABSENT__'};if($live-ne[string]$owned.InstalledToken){$drift=$true}}}
        Write-CbOptimizeReport 'check' $(if($drift){'conflict'}else{'available'}) $false 'unmanaged' 0 $drift
        if($drift){return 4};return 0
    }
    if($Apply-and-not(Test-CbExists $script:PendingPath)-and-not(Test-CbExists $script:ConfigPendingPath)-and-not(Test-CbExists $script:CompositePendingPath)){
        # Reject malformed managed paths before creating locks or state. A
        # pending transaction remains recovery-first and is validated there.
        Assert-CbConfigPath|Out-Null
        Read-CbConfigDocument|Out-Null
    }
    if($Apply){Ensure-CbSafeDirectory $script:CodexHome|Out-Null;Acquire-CbLock;$script:MutationStarted=$true;Recover-CbPending;Recover-CbConfigPending;Recover-CbCompositePending}
    $beforeHash=if(Test-CbExists $script:ConfigPath){Get-CbFileHash $script:ConfigPath}else{'absent'}
    if($Restore){$plan=Get-CbConfigRestorePlan;if($null-eq$plan){Write-CbOptimizeReport 'restore' 'not-managed' $false 'keep' 0;return 0};Invoke-CbConfigActions 'restore' $plan.Actions $plan.Next $null ([bool]$Apply)|Out-Null;$mode='restore'}
    else{$document=Read-CbConfigDocument;$actions=@{agents_enabled='true';agents_max='6'};$next=@{agents_enabled=$true;agents_max=$true}
      if($Speed-eq'fast'){
        $current=Get-CbCurrentConfigTransaction;$ownedTier=if($null-eq$current){$null}else{@($current.Ownership|Where-Object{$_.Id-eq'service_tier'})|Select-Object -First 1}
        if($document.Keys.ContainsKey('service_tier')-and$null-eq$ownedTier-and[string]$document.Keys['service_tier'].Token-ne'"fast"'){throw 'speed=fast refuses an unowned conflicting key: service_tier'}
        $actions.service_tier='"fast"';$actions.features_fast_mode='true';$next.service_tier=$true;$next.features_fast_mode=$true
      }
      elseif($Speed-eq'standard'){$current=Get-CbCurrentConfigTransaction;foreach($id in @('service_tier','features_fast_mode')){$owned=if($null-eq$current){$null}else{@($current.Ownership|Where-Object{$_.Id-eq$id})|Select-Object -First 1};if($null-ne$owned){$actions[$id]=if($owned.PriorState-eq'present'){$owned.PriorToken}else{'__ABSENT__'};$next[$id]=$false}elseif($document.Keys.ContainsKey($id)){$token=[string]$document.Keys[$id].Token;if(($id-eq'service_tier'-and$token-eq'"fast"')-or($id-eq'features_fast_mode'-and$token-eq'true')){throw "speed=standard refuses an unowned conflicting key: $((Get-CbConfigKeyMetadata $id).Path)"}}}}
      Invoke-CbConfigActions 'optimize' $actions $next $null ([bool]$Apply)|Out-Null;$mode='optimize'}
    $afterHash=if(Test-CbExists $script:ConfigPath){Get-CbFileHash $script:ConfigPath}else{'absent'};$status=if($Apply){if($mode-eq'restore'){'restored'}else{'applied'}}else{'planned'}
    $bytesChanged=if($beforeHash-ne$afterHash-and$afterHash-ne'absent'){[long](Get-CbItem $script:ConfigPath).Length}else{0}
    Write-CbOptimizeReport $mode $status ([bool]$Apply) $Speed $bytesChanged;return 0
}

function Invoke-CbInstallLike {
    param(
        [string]$Operation,
        [string]$SourceRoot = $script:SourceRoot,
        [string]$Acquisition = 'local-checkout'
    )
    $manifest = Read-CbManifest $SourceRoot
    Write-CbSourceProvenance $manifest $SourceRoot $Acquisition
    if (-not $DryRun -and -not $AcknowledgeUnverifiedSource) {
        throw 'Unsigned local source requires -AcknowledgeUnverifiedSource before mutation.'
    }
    $sourceSnapshot = New-CbVerifiedSourceSnapshot $manifest $SourceRoot
    $temporaryRoot = $null
    try {
        $manifest = Assert-CbVerifiedSourceSnapshot $sourceSnapshot
        Initialize-CbPaths
        if ($DryRun) {
            if (Test-CbExists $script:PendingPath) {
                throw 'An incomplete transaction requires recovery; dry-run made no changes.'
            }
            if (Test-CbExists $script:ConfigPendingPath) {
                throw 'An incomplete config transaction requires recovery; dry-run made no changes.'
            }
            if (Test-CbExists $script:CompositePendingPath) {
                throw 'An incomplete composite transaction requires recovery; dry-run made no changes.'
            }
        }
        else {
            Ensure-CbSafeDirectory $script:CodexHome | Out-Null
            Ensure-CbSafeDirectory $script:AgentsHome | Out-Null
            if ($Acquisition -eq 'unsigned-github-release' -and $env:CODEX_BASELINE_TESTING -eq '1' -and
                -not [string]::IsNullOrWhiteSpace($env:CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK)) {
                $pauseDirectory = Get-CbItem $env:CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK
                if ($null -eq $pauseDirectory) { throw 'Update pause fixture directory is missing.' }
                Assert-CbOrdinaryItem $pauseDirectory 'tree'
                [System.IO.File]::WriteAllText((Join-Path $pauseDirectory.FullName 'ready'), "ready`n", $script:Utf8NoBom)
                for ($pauseAttempt = 0; $pauseAttempt -lt 200; $pauseAttempt++) {
                    if (Test-CbExists (Join-Path $pauseDirectory.FullName 'continue')) { break }
                    Start-Sleep -Milliseconds 50
                }
                if (-not (Test-CbExists (Join-Path $pauseDirectory.FullName 'continue'))) {
                    throw 'Timed out waiting for concurrent update fixture.'
                }
            }
            Acquire-CbLock
            $script:MutationStarted = $true
            Recover-CbPending
            Recover-CbConfigPending
            Recover-CbCompositePending
            if ($Acquisition -eq 'unsigned-github-release') {
                $lockedCurrent = Get-CbCurrentTransaction
                if ($null -ne $lockedCurrent -and
                    (Compare-CbSemVer ([string]$manifest.version) ([string]$lockedCurrent.Version)) -lt 0) {
                    throw ("Remote update would downgrade installed {0} to {1}." -f $lockedCurrent.Version, $manifest.version)
                }
            }
        }
        $temporaryRoot = New-CbTemporaryDirectory
        $manifest = Assert-CbVerifiedSourceSnapshot $sourceSnapshot
        $current = Get-CbCurrentTransaction
        $objects = @(Get-CbInstallObjects $manifest $sourceSnapshot.Root $temporaryRoot $current)
        $changed = @($objects | Where-Object { $_.Change })
        foreach ($object in $changed) {
            Write-Output ("{0}: {1}" -f $Operation, $object.Target)
        }
        if ($changed.Count -eq 0) {
            Write-Output ("codex-baseline {0} is already installed; no changes" -f $manifest.version)
            return
        }
        $autoCapPlan=$null
        if($Operation-eq'install'-and$null-eq$current){
            # This target/config preflight is deliberately completed before a
            # core journal, composite intent, or managed object is created.
            $autoCapPlan=Invoke-CbConfigAutoCap $null $false
        }
        if ($DryRun) {
            if($null-ne$autoCapPlan){Write-CbConfigAutoCapPlan $autoCapPlan}
            Write-Output 'dry-run: no files changed'
            return
        }
        $parentId = if ($null -eq $current) { $null } else { [string]$current.Id }
        $reservedTransaction = $null
        if ($Operation -eq 'install' -and $null -eq $current) {
            $reservedTransaction=New-CbTransaction $Operation ([string]$manifest.version) $parentId
            New-CbCompositeTransaction 'install' $null ([string]$reservedTransaction.Id)|Out-Null
        }
        $transaction = Invoke-CbTransaction $Operation ([string]$manifest.version) $parentId $objects '__SELF__' $reservedTransaction
        Recover-CbCompositePending
        Write-Output ("installed codex-baseline {0} (transaction {1})" -f $manifest.version, $transaction.Id)
    }
    finally {
        if ($null -ne $temporaryRoot -and (Test-CbExists $temporaryRoot)) {
            Remove-CbSafeItem $temporaryRoot
        }
        if ($null -ne $sourceSnapshot -and (Test-CbExists ([string]$sourceSnapshot.Root))) {
            Remove-CbSafeItem ([string]$sourceSnapshot.Root)
        }
    }
}

function Invoke-CbUpdate {
    Initialize-CbPaths
    $modeCount = @(@($Check, $Remote, $Local) | Where-Object { $_ }).Count
    if (-not [string]::IsNullOrWhiteSpace($Offline)) { $modeCount++ }
    if ($modeCount -gt 1) { throw 'Choose only one of -Check, -Remote, -Local, or -Offline.' }
    if ($Check -and $DryRun) { throw '-Check and -DryRun are separate preview modes.' }
    if (-not [string]::IsNullOrWhiteSpace($Offline)) {
        $prepared = Get-CbPreparedUpdateSource $Offline
        try { Invoke-CbInstallLike 'update' ([string]$prepared.Root) 'offline-archive' }
        finally { if ($null -ne $prepared -and (Test-CbExists ([string]$prepared.Temporary))) { Remove-CbSafeItem ([string]$prepared.Temporary) } }
        return
    }
    $installedRuntime = Test-CbSamePath $script:SourceRoot $script:RuntimePath
    if ($Local -or (-not $Check -and -not $Remote -and -not $installedRuntime)) {
        Invoke-CbInstallLike 'update' $script:SourceRoot 'local-checkout'
        return
    }

    $temporary = New-CbTemporaryDirectory
    $prepared = $null
    try {
        $descriptorPath = Join-Path $temporary 'codex-baseline-update-v1.txt'
        if ($env:CODEX_BASELINE_TESTING -eq '1' -and
            -not [string]::IsNullOrWhiteSpace($env:CODEX_BASELINE_TEST_UPDATE_METADATA_PATH)) {
            Copy-CbUpdateInput $env:CODEX_BASELINE_TEST_UPDATE_METADATA_PATH $descriptorPath 16384
        }
        else { Receive-CbUpdateUrl ([uri]$script:UpdateMetadataUrl) $descriptorPath 16384 }
        $descriptor = Read-CbUpdateDescriptor $descriptorPath
        $currentVersion = (Read-CbUtf8Text (Join-Path $script:SourceRoot 'VERSION')).Trim()
        $currentReleaseStatus = Read-CbReleaseStatus $script:SourceRoot
        $comparison = Compare-CbSemVer ([string]$descriptor.Version) $currentVersion
        if ($comparison -lt 0) { throw "Latest release $($descriptor.Version) is older than installed $currentVersion." }
        if ($Check) {
            if ($comparison -eq 0 -and $currentReleaseStatus -eq 'stable') { Write-Output ("codex-baseline {0} is already current (latest stable {1})" -f $currentVersion, $descriptor.Version) }
            elseif($comparison-eq0){Write-Output ("codex-baseline update available: {0} ({1}) -> {2} (stable)"-f$currentVersion,$currentReleaseStatus,$descriptor.Version)}
            else { Write-Output ("codex-baseline update available: {0} -> {1}" -f $currentVersion, $descriptor.Version) }
            Write-Output 'source-acquisition: unsigned-github-release'
            Write-Output 'source-authentication: not-publisher-authenticated'
            return
        }
        $assetUri = "https://github.com/ShigeoAMV/codex-baseline/releases/download/{0}/{1}" -f $descriptor.Tag, $descriptor.ZipName
        if ($env:CODEX_BASELINE_TESTING -eq '1' -and
            -not [string]::IsNullOrWhiteSpace($env:CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH)) {
            $prepared = Get-CbPreparedUpdateSource $env:CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH ([string]$descriptor.Version) $descriptor $false
        }
        else { $prepared = Get-CbPreparedUpdateSource $assetUri ([string]$descriptor.Version) $descriptor $true }
        Invoke-CbInstallLike 'update' ([string]$prepared.Root) 'unsigned-github-release'
    }
    finally {
        if ($null -ne $prepared -and (Test-CbExists ([string]$prepared.Temporary))) { Remove-CbSafeItem ([string]$prepared.Temporary) }
        if (Test-CbExists $temporary) { Remove-CbSafeItem $temporary }
    }
}

function Assert-CbCurrentClean {
    param($Current)
    foreach ($object in @($Current.Objects)) {
        $live = Get-CbLiveHash ([string]$object.Kind) ([string]$object.Target)
        if ($live -ne [string]$object.InstalledHash) {
            throw "Managed content drifted: $($object.Target)"
        }
    }
}

function New-CbReverseObject {
    param($SourceObject, $CurrentTransaction, [string]$TemporaryRoot)
    $id = [string]$SourceObject.Id
    $kind = [string]$SourceObject.Kind
    $target = [string]$SourceObject.Target
    $desiredHash = [string]$SourceObject.PreviousHash
    $sourcePath = $null
    $desiredPresent = [bool]$SourceObject.PreviousExisted
    if ($kind -eq 'block') {
        $liveText = if (Test-CbExists $target) { Read-CbUtf8Text $target } else { '' }
        $physicalUnchanged = -not [string]::IsNullOrWhiteSpace([string]$SourceObject.InstalledPhysicalHash) -and
            (Get-CbPhysicalHash $target) -eq [string]$SourceObject.InstalledPhysicalHash
        if ($physicalUnchanged -and [bool]$SourceObject.PreviousExisted) {
            if ($null -eq $SourceObject.PhysicalBackup -or -not (Test-CbExists ([string]$SourceObject.PhysicalBackup))) {
                throw "Rollback physical block preimage is missing: $target"
            }
            if ((Get-CbFileHash ([string]$SourceObject.PhysicalBackup)) -ne [string]$SourceObject.PhysicalBackupHash) {
                throw "Rollback physical block preimage is corrupt: $target"
            }
            $sourcePath = [string]$SourceObject.PhysicalBackup
            $desiredPresent = $true
        }
        elseif ($physicalUnchanged -and -not [bool]$SourceObject.PreviousExisted) {
            $desiredPresent = $false
            $sourcePath = $null
        }
        elseif ($desiredHash -eq 'absent') {
            $candidate = Remove-CbBlockText $liveText
            $desiredPresent = [bool]$SourceObject.PreviousExisted -or $candidate.Length -gt 0
        }
        else {
            if ($null -eq $SourceObject.Backup -or -not (Test-CbExists ([string]$SourceObject.Backup))) {
                throw "Rollback block backup is missing: $target"
            }
            $sourcePath = [string]$SourceObject.Backup
            if ((Get-CbStringHash (Read-CbUtf8Text $sourcePath)) -ne [string]$SourceObject.BackupHash) {
                throw "Rollback block preimage is corrupt: $target"
            }
            $candidate = Set-CbBlockText $liveText (Read-CbUtf8Text $sourcePath)
            $desiredPresent = $true
        }
        $candidatePath = Join-Path $TemporaryRoot ("reverse-{0}.txt" -f $id)
        if (-not $physicalUnchanged) {
            Write-CbUtf8File $candidatePath $candidate
            $sourcePath = if ($desiredHash -eq 'absent') { $null } else { $sourcePath }
        }
    }
    elseif ($desiredPresent) {
        if ($null -eq $SourceObject.Backup -or -not (Test-CbExists ([string]$SourceObject.Backup))) {
            throw "Rollback backup is missing: $target"
        }
        $sourcePath = [string]$SourceObject.Backup
        $backupHash = Get-CbLiveHash $kind $sourcePath
        if ($backupHash -ne [string]$SourceObject.BackupHash -or $backupHash -ne $desiredHash) {
            throw "Rollback preimage is corrupt: $target"
        }
    }
    $object = New-CbObject $id $kind $target $desiredHash $desiredPresent $sourcePath 'rollback-preimage' $CurrentTransaction
    if ($kind -eq 'block' -and $physicalUnchanged -and $desiredPresent) {
        $object.BlockWholeFileSource = $true
    }
    return $object
}

function Invoke-CbRollback {
    Initialize-CbPaths
    if($DryRun){
      if(Test-CbExists $script:PendingPath){throw 'An incomplete transaction requires recovery; dry-run made no changes.'}
      if(Test-CbExists $script:ConfigPendingPath){throw 'An incomplete config transaction requires recovery; dry-run made no changes.'}
      if(Test-CbExists $script:CompositePendingPath){throw 'An incomplete composite transaction requires recovery; dry-run made no changes.'}
    }else{
      Ensure-CbSafeDirectory $script:CodexHome|Out-Null;Acquire-CbLock;$script:MutationStarted=$true
      Recover-CbPending;Recover-CbConfigPending;Recover-CbCompositePending
    }
    $current = Get-CbCurrentTransaction
    if ($null -eq $current) {
        Write-Output 'codex-baseline is not installed; nothing to roll back'
        return
    }
    Assert-CbCurrentClean $current
    $temporaryRoot = New-CbTemporaryDirectory
    try {
        $objects = @()
        foreach ($sourceObject in @($current.Objects)) {
            if ($sourceObject.Change) {
                $objects += New-CbReverseObject $sourceObject $current $temporaryRoot
            }
        }
        foreach ($object in @($objects | Where-Object { $_.Change })) {
            Write-Output ("rollback: {0}" -f $object.Target)
        }
        if ($DryRun) {
            $configCurrent = Get-CbCurrentConfigTransaction
            if ($null -ne $configCurrent -and [string]$configCurrent.CoreTransaction -eq [string]$current.Id) {
                Invoke-CbConfigRestore 'rollback' ([string]$current.Id) $false | Out-Null
            }
            Write-Output 'dry-run: no files changed'
            return
        }
        $current = Get-CbCurrentTransaction
        Assert-CbCurrentClean $current
        $objects = @()
        foreach ($sourceObject in @($current.Objects)) {
            if ($sourceObject.Change) {
                $objects += New-CbReverseObject $sourceObject $current $temporaryRoot
            }
        }
        $resultCurrent = if ($null -eq $current.ParentTransaction) { $null } else { [string]$current.ParentTransaction }
        New-CbCompositeTransaction 'rollback' ([string]$current.Id) $resultCurrent|Out-Null
        $transaction = Invoke-CbTransaction 'rollback' ([string]$current.Version) ([string]$current.Id) $objects $resultCurrent
        Recover-CbCompositePending
        Write-Output ("rolled back transaction {0} (journal {1})" -f $current.Id, $transaction.Id)
    }
    finally {
        if (Test-CbExists $temporaryRoot) { Remove-CbSafeItem $temporaryRoot }
    }
}

function New-CbUninstallObjects {
    param($Current, [string]$TemporaryRoot)
    $objects = @()
    foreach ($sourceObject in @($Current.Objects)) {
        $kind = [string]$sourceObject.Kind
        $target = [string]$sourceObject.Target
        if ($kind -eq 'block') {
            $liveText = if (Test-CbExists $target) { Read-CbUtf8Text $target } else { '' }
            $candidate = Remove-CbBlockText $liveText
            $candidatePath = Join-Path $TemporaryRoot 'uninstall-agents.txt'
            Write-CbUtf8File $candidatePath $candidate
            $desiredPresent = $candidate.Length -gt 0
            $objects += New-CbObject ([string]$sourceObject.Id) 'block' $target 'absent' $desiredPresent $null 'uninstall-managed-block' $Current
        }
        else {
            $objects += New-CbObject ([string]$sourceObject.Id) $kind $target 'absent' $false $null 'uninstall-managed-object' $Current
        }
    }
    return $objects
}

function Invoke-CbUninstall {
    Initialize-CbPaths
    if($DryRun){
      if(Test-CbExists $script:PendingPath){throw 'An incomplete transaction requires recovery; dry-run made no changes.'}
      if(Test-CbExists $script:ConfigPendingPath){throw 'An incomplete config transaction requires recovery; dry-run made no changes.'}
      if(Test-CbExists $script:CompositePendingPath){throw 'An incomplete composite transaction requires recovery; dry-run made no changes.'}
    }else{
      Ensure-CbSafeDirectory $script:CodexHome|Out-Null;Acquire-CbLock;$script:MutationStarted=$true
      Recover-CbPending;Recover-CbConfigPending;Recover-CbCompositePending
    }
    $current = Get-CbCurrentTransaction
    if ($null -eq $current -or [string]$current.Operation -eq 'uninstall') {
        if($null-ne(Get-CbCurrentConfigTransaction)){Invoke-CbConfigRestore 'uninstall' $(if($null-eq$current){$null}else{[string]$current.Id}) (-not[bool]$DryRun)|Out-Null}
        Write-Output $(if($DryRun){'dry-run: baseline is already uninstalled; no files changed'}else{'codex-baseline is already uninstalled; baseline-owned config state was restored where present'})
        return
    }
    Assert-CbCurrentClean $current
    $temporaryRoot = New-CbTemporaryDirectory
    try {
        $objects = @(New-CbUninstallObjects $current $temporaryRoot)
        foreach ($object in @($objects | Where-Object { $_.Change })) {
            Write-Output ("uninstall: {0}" -f $object.Target)
        }
        if ($DryRun) {
            Invoke-CbConfigRestore 'uninstall' ([string]$current.Id) $false | Out-Null
            Write-Output 'dry-run: no files changed'
            return
        }
        $current = Get-CbCurrentTransaction
        Assert-CbCurrentClean $current
        $objects = @(New-CbUninstallObjects $current $temporaryRoot)
        $reserved=New-CbTransaction 'uninstall' ([string]$current.Version) ([string]$current.Id)
        New-CbCompositeTransaction 'uninstall' ([string]$current.Id) ([string]$reserved.Id)|Out-Null
        $transaction = Invoke-CbTransaction 'uninstall' ([string]$current.Version) ([string]$current.Id) $objects '__SELF__' $reserved
        Recover-CbCompositePending
        Write-Output ("uninstalled codex-baseline (transaction {0})" -f $transaction.Id)
    }
    finally {
        if (Test-CbExists $temporaryRoot) { Remove-CbSafeItem $temporaryRoot }
    }
}

function Invoke-CbDoctor {
    Initialize-CbPaths
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $codexVersion = 'not-found'
    $codexVerification = 'unverified-native-codex-not-installed'
    $nativeCapabilities = 'unverified-native-codex-not-installed'
    $configState = 'unverified-native-codex-not-installed'
    $deprecatedState = 'unverified-native-codex-not-installed'
    $requiredDependencies = @('Windows PowerShell 5.1+')
    $missingDependencies = @()
    $managedOk = 0
    $managedTotal = 0
    $baselineVersion = $null
    $researchChecked = $null
    $researchReviewBy = $null
    $researchState = 'invalid'
    $configOwned = 0
    $configDrift = $false
    $configManagedPaths = @()
    $configDocument = $null
    $optimizerAgents = 'unverified'
    $optimizerFast = 'unverified'
    $sourceManifest = $null
    $minimumCodex = $null
    $testedCodex = $null
    $sourceProvenance = [pscustomobject]@{
        scope = 'unavailable'
        version = $null
        trust = $null
        payload_sha256 = $null
    }
    try {
        $sourceManifest = Read-CbManifest
        $sourceProvenance = [pscustomobject]@{
            scope = $(if (Test-CbSamePath $script:SourceRoot $script:RuntimePath) { 'installed-runtime' } else { 'local-source' })
            version = [string]$sourceManifest.version
            trust = [string]$sourceManifest.source_trust
            payload_sha256 = [string]$sourceManifest.payload_hash
        }
        $minimumText = [string]$sourceManifest.minimum_codex
        if ($minimumText -notmatch '^\d+\.\d+\.\d+$') {
            throw 'Source manifest minimum_codex is malformed.'
        }
        $minimumCodex = [version]$minimumText
        $testedText = [string]$sourceManifest.tested_codex
        if ($testedText -notmatch '^\d+\.\d+\.\d+$') {
            throw 'Source manifest tested_codex is malformed.'
        }
        $testedCodex = [version]$testedText
        $researchChecked = [string]$sourceManifest.research_checked
        $researchReviewBy = [string]$sourceManifest.research_review_by
    }
    catch {
        $failures.Add("Source/research manifest check failed: $($_.Exception.Message)") | Out-Null
    }
    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -ne $codexCommand) {
        try {
            $codexVersion = (& codex --version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                $codexVerification = 'executed-native-windows'
                $versionMatch = [regex]::Match($codexVersion, '(?<!\d)(\d+\.\d+\.\d+)(?!\d)')
                if (-not $versionMatch.Success) {
                    $failures.Add('Native Codex version output does not contain a semantic version.') | Out-Null
                }
                else {
                    $detectedCodex = [version]$versionMatch.Groups[1].Value
                    if ($null -ne $minimumCodex -and $detectedCodex -lt $minimumCodex) {
                        $failures.Add("Native Codex is older than the supported minimum version $minimumCodex.") | Out-Null
                    }
                }
                & codex --strict-config --version *> $null
                if ($LASTEXITCODE -eq 0) {
                    $configState = 'accepted-by-strict-config'
                    $deprecatedState = 'none-reported-by-strict-config'
                }
                else {
                    $configState = 'rejected-by-strict-config'
                    $deprecatedState = 'unverified-config-rejected'
                    $failures.Add('Native Codex strict-config version probe failed.') | Out-Null
                }
                $featuresOutput = (& codex features list 2>&1 | Out-String)
                $featuresExit = $LASTEXITCODE
                $stableFeatures = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
                foreach ($featureMatch in [regex]::Matches($featuresOutput, '(?m)^\s*(goals|multi_agent|skill_search)\s+stable\s+true(?:\s|$)')) {
                    $stableFeatures.Add($featureMatch.Groups[1].Value) | Out-Null
                }
                if ($featuresExit -eq 0 -and $stableFeatures.Count -eq 3) {
                    $nativeCapabilities = 'verified'
                }
                else {
                    $nativeCapabilities = 'degraded'
                    $warnings.Add('Native Codex capability probe is degraded.') | Out-Null
                }
                if ($versionMatch.Success -and $null -ne $testedCodex -and
                    ([version]$versionMatch.Groups[1].Value) -gt $testedCodex) {
                    $nativeCapabilities = 'unverified-future-version'
                    $warnings.Add(("Native Codex {0} is newer than the tested version {1}; volatile capabilities remain unverified." -f
                        $versionMatch.Groups[1].Value, $testedCodex)) | Out-Null
                }
            }
            else {
                $failures.Add('Native Codex version probe failed.') | Out-Null
            }
        }
        catch {
            $failures.Add("Native Codex probe failed: $($_.Exception.Message)") | Out-Null
        }
    }
    else {
        $warnings.Add('Native Windows Codex is not installed; Codex behavior is unverified on this host.') | Out-Null
    }
    $state = 'not-installed'
    $currentId = $null
    try {
        if (Test-CbExists $script:PendingPath) {
            $failures.Add('An incomplete transaction is pending recovery.') | Out-Null
        }
        if (Test-CbExists $script:LockPath) {
            $warnings.Add('An operation lock exists.') | Out-Null
        }
        $current = Get-CbCurrentTransaction
        if ($null -ne $current) {
            $currentId = [string]$current.Id
            $baselineVersion = [string]$current.Version
            $state = if ([string]$current.Operation -eq 'uninstall') { 'uninstalled' } else { [string]$current.State }
            foreach ($object in @($current.Objects)) {
                $managedTotal++
                try {
                    $live = Get-CbLiveHash ([string]$object.Kind) ([string]$object.Target)
                    if ($live -ne [string]$object.InstalledHash) {
                        $failures.Add("Managed content drifted: $($object.Target)") | Out-Null
                    }
                    else { $managedOk++ }
                }
                catch {
                    $failures.Add($_.Exception.Message) | Out-Null
                }
            }
        }
    }
    catch {
        $failures.Add($_.Exception.Message) | Out-Null
    }
    try {
        if (Test-CbExists $script:ConfigPendingPath) { $failures.Add('An incomplete config transaction is pending recovery.') | Out-Null }
        if (Test-CbExists $script:CompositePendingPath) { $failures.Add('An incomplete composite transaction is pending recovery.') | Out-Null }
        $configCurrent = Get-CbCurrentConfigTransaction
        Assert-CbConfigPath | Out-Null
        $configDocument = Read-CbConfigDocument
        if ($null -ne $configCurrent) {
            $configOwned = @($configCurrent.Ownership).Count
            $configManagedPaths = @($configCurrent.Ownership | ForEach-Object { [string]$_.Path })
            Assert-CbConfigOwnershipClean $configCurrent $configDocument
        }
    }
    catch {
        $configDrift = $true
        $failures.Add("Managed config projection drifted or became unsafe: $($_.Exception.Message)") | Out-Null
    }
    if($nativeCapabilities-eq'verified'-and$configState-eq'accepted-by-strict-config'-and-not$configDrift){
        $optimizerAgents='available'
        if($null-ne$configDocument-and$configDocument.Keys.ContainsKey('service_tier')-and[string]$configDocument.Keys['service_tier'].Token-eq'"fast"'-and$configDocument.Keys.ContainsKey('features_fast_mode')-and[string]$configDocument.Keys['features_fast_mode'].Token-eq'true'){$optimizerFast='available'}
    }
    $agentsFile = Join-Path $script:CodexHome 'AGENTS.md'
    if (Test-CbExists (Join-Path $script:CodexHome 'AGENTS.override.md')) {
        $agentsFile = Join-Path $script:CodexHome 'AGENTS.override.md'
    }
    $markerBegin = 0
    $markerEnd = 0
    try {
        if (Test-CbExists $agentsFile) {
            $text = Read-CbUtf8Text $agentsFile
            $markerBegin = [regex]::Matches($text, $script:BeginPattern).Count
            $markerEnd = [regex]::Matches($text, $script:EndPattern).Count
            Get-CbBlockInfo $text | Out-Null
        }
    }
    catch {
        $failures.Add($_.Exception.Message) | Out-Null
    }
    $skillCount = 0
    foreach ($skillName in @(
        'codex-baseline-repo-onboarding', 'codex-baseline-deep-work',
        'codex-baseline-conformance-review', 'codex-baseline-retrospective'
    )) {
        $skillPath = Join-Path $script:AgentsHome ("skills\{0}\SKILL.md" -f $skillName)
        if (Test-CbExists $skillPath) { $skillCount++ }
    }
    if ($state -ne 'not-installed' -and $skillCount -ne 4) {
        $failures.Add('One or more baseline skills are missing.') | Out-Null
    }
    if ($null -ne $sourceManifest) {
        $reviewDate = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($researchReviewBy, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$reviewDate)) {
            if ([DateTime]::UtcNow.Date -le $reviewDate.Date) { $researchState = 'current' }
            else {
                $researchState = 'stale'
                $warnings.Add('Research evidence is past its review-by date.') | Out-Null
            }
        }
        else { $warnings.Add('Research freshness metadata is invalid.') | Out-Null }
    }
    $report = [pscustomobject]@{
        schema = 2
        contract = 'codex-baseline-doctor/v2'
        platform = 'native-windows'
        powershell = $PSVersionTable.PSVersion.ToString()
        codex = $codexVersion
        codex_verification = $codexVerification
        state = $state
        transaction = $currentId
        baseline_version = $baselineVersion
        source_provenance = $sourceProvenance
        global_guidance = $agentsFile
        marker_counts = [pscustomobject]@{ begin = $markerBegin; end = $markerEnd }
        managed_objects = [pscustomobject]@{ ok = $managedOk; total = $managedTotal }
        skills = [pscustomobject]@{ ok = $skillCount; total = 4 }
        native_capabilities = $nativeCapabilities
        runtime_dependencies = [pscustomobject]@{ status = 'verified'; required = $requiredDependencies; missing = $missingDependencies }
        active_config = [pscustomobject]@{ status = $configState; verification = 'codex --strict-config --version' }
        hook_state = [pscustomobject]@{ baseline_owned = 0; user_owned = 'preserved-not-enumerated' }
        deprecated_settings = [pscustomobject]@{ status = $deprecatedState }
        paths = [pscustomobject]@{ home = $script:HomePath; codex_home = $script:CodexHome; agents_home = $script:AgentsHome; state_root = $script:StateRoot }
        owned_config_keys = $configOwned
        owned_hooks = 0
        optimizer = [pscustomobject]@{ contract = 'codex-baseline-config-operations/v2'; managed_keys = $configManagedPaths; drift = $configDrift; agents = $optimizerAgents; fast = $optimizerFast; ultrafast = 'unavailable' }
        research = [pscustomobject]@{ checked = $researchChecked; review_by = $researchReviewBy; state = $researchState }
        warnings = @($warnings)
        failures = @($failures)
        warning_count = $warnings.Count
        failure_count = $failures.Count
    }
    if ($Json) {
        [Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 5 -Compress))
    }
    else {
        [Console]::Out.WriteLine(("Platform: native-windows (PowerShell {0})" -f $report.powershell))
        [Console]::Out.WriteLine(("Codex: {0} ({1})" -f $codexVersion, $codexVerification))
        [Console]::Out.WriteLine(("Installation: {0}" -f $state))
        [Console]::Out.WriteLine(("Transaction: {0}" -f $(if ($null -eq $currentId) { 'none' } else { $currentId })))
        [Console]::Out.WriteLine(("Baseline version: {0}" -f $(if ($null -eq $baselineVersion) { 'none' } else { $baselineVersion })))
        [Console]::Out.WriteLine(("Source provenance: {0} version={1} trust={2} payload={3}" -f $sourceProvenance.scope, $sourceProvenance.version, $sourceProvenance.trust, $sourceProvenance.payload_sha256))
        [Console]::Out.WriteLine(("Global guidance: {0} (markers {1} {2})" -f $agentsFile, $markerBegin, $markerEnd))
        [Console]::Out.WriteLine(("Runtime dependencies: verified ({0} required, {1} missing)" -f $requiredDependencies.Count, $missingDependencies.Count))
        [Console]::Out.WriteLine(("Active config: {0}; deprecated settings: {1}" -f $configState, $deprecatedState))
        [Console]::Out.WriteLine(("Paths: HOME={0} CODEX_HOME={1} AGENTS_HOME={2} state={3}" -f $script:HomePath, $script:CodexHome, $script:AgentsHome, $script:StateRoot))
        [Console]::Out.WriteLine(("Owned config keys: {0}; drift={1}; Agents={2}; Fast={3}; Ultrafast=unavailable" -f $configOwned, $configDrift, $optimizerAgents, $optimizerFast))
        foreach ($warning in $warnings) { [Console]::Out.WriteLine(("WARNING: {0}" -f $warning)) }
        foreach ($failure in $failures) { [Console]::Out.WriteLine(("FAIL: {0}" -f $failure)) }
    }
    if ($failures.Count -gt 0) {
        return 1
    }
    return 0
}

function Show-CbUsage {
    Write-Output @'
Usage: powershell -File codex-baseline.ps1 <command> [-DryRun] [-Json]
       install [-AcknowledgeUnverifiedSource]
       update [-Check|-Remote|-Local|-Offline ARCHIVE] [-DryRun]
              [-AcknowledgeUnverifiedSource]
       optimize [-Check|-Restore] [-Speed keep|standard|fast|ultrafast]
                [-DryRun|-Apply] [-Json]
       onboard [-Apply] [-AcknowledgeExistingInstructions] [repository]

Commands:
  install     Install from this reviewed local source tree
  update      Check/apply latest stable release; checkout remains local by default
  doctor      Inspect native-Windows paths, state, drift, and Codex availability
  optimize    Inspect or apply allowlisted agent-cap and speed config keys
  rollback    Restore the state before the current transaction
  uninstall   Remove only baseline-owned content; rollback can restore it
  onboard     Run bounded native static discovery; add -Apply to write its block
  benchmark   Validate native static fixtures/contracts; live is unsupported
  help        Show this help

Only installed-runtime update/-Remote performs a bounded public release fetch;
no command inspects authentication/session files. Dry-run writes no target or state files. Existing unowned targets,
managed drift, malformed markers, symlinks, junctions, and other reparse points
fail closed. This unsigned local source requires explicit acknowledgement before
install or update mutation.
'@
}

$exitCode = 0
try {
    switch ($Command.ToLowerInvariant()) {
        'install' { Invoke-CbInstallLike 'install' }
        'update' { Invoke-CbUpdate }
        'doctor' { $exitCode = Invoke-CbDoctor }
        'optimize' { $exitCode = Invoke-CbOptimize }
        'rollback' { Invoke-CbRollback }
        'uninstall' { Invoke-CbUninstall }
        'onboard' {
            $onboardParameters = @{
                Repository = $Repository
                Apply = [bool]$Apply
                AcknowledgeExistingInstructions = [bool]$AcknowledgeExistingInstructions
                DryRun = [bool]$DryRun
                Json = [bool]$Json
                MaxFiles = $MaxFiles
                MaxVisited = $MaxVisited
            }
            & (Join-Path $PSScriptRoot 'onboard.ps1') @onboardParameters
            $exitCode = $LASTEXITCODE
        }
        'benchmark' {
            $benchmarkParameters = @{
                Static = [bool]$Static
                Live = [bool]$Live
                Json = [bool]$Json
                Tasks = $Tasks
            }
            & (Join-Path $PSScriptRoot 'benchmark.ps1') @benchmarkParameters
            $exitCode = $LASTEXITCODE
        }
        'help' { Show-CbUsage }
        '-h' { Show-CbUsage }
        '--help' { Show-CbUsage }
        default {
            Show-CbUsage
            throw "Unknown command: $Command"
        }
    }
}
catch {
    Write-CbError $_.Exception.Message
    if ($env:CODEX_BASELINE_TESTING -eq '1' -and $env:CODEX_BASELINE_TEST_DEBUG_ERRORS -eq '1') {
        Write-CbError $_.ScriptStackTrace
    }
    $exitCode = 1
    if ($script:MutationStarted) {
        try {
            if($null-ne$script:ActiveTransaction){Recover-CbPending}
            Recover-CbConfigPending
            Recover-CbCompositePending
        }
        catch {
            Write-CbError ("automatic recovery failed: {0}" -f $_.Exception.Message)
        }
    }
}
finally {
    try { Release-CbLock } catch { Write-CbError $_.Exception.Message; $exitCode = 1 }
}

exit $exitCode
