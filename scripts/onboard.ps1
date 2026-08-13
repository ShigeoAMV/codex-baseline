[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Repository = '.',

    [switch]$Apply,

    [Alias('acknowledge-existing-instructions')]
    [switch]$AcknowledgeExistingInstructions,

    [Alias('dry-run')]
    [switch]$DryRun,

    [switch]$Json,

    [Alias('max-files')]
    [ValidateRange(1, 100000)]
    [int]$MaxFiles = 2000,

    [Alias('max-visited')]
    [ValidateRange(1, 500000)]
    [int]$MaxVisited = 10000,

    [ValidateRange(1, 64)]
    [int]$MaxDepth = 7,

    [ValidateRange(1, 16777216)]
    [long]$MaxFileBytes = 1048576,

    [ValidateRange(1, 134217728)]
    [long]$MaxTotalBytes = 8388608
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:BeginPattern = '(?m)^<!-- codex-baseline:onboarding:begin version=[^>\r\n]* -->\r?$'
$script:EndPattern = '(?m)^<!-- codex-baseline:onboarding:end -->\r?$'
$script:SourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Files = New-Object 'System.Collections.Generic.List[string]'
$script:Manifests = New-Object 'System.Collections.Generic.List[string]'
$script:AiInstructions = New-Object 'System.Collections.Generic.List[string]'
$script:CiDescriptors = New-Object 'System.Collections.Generic.List[string]'
$script:ProjectDocs = New-Object 'System.Collections.Generic.List[string]'
$script:QualitySignals = New-Object 'System.Collections.Generic.List[string]'
$script:TestSignals = New-Object 'System.Collections.Generic.List[string]'
$script:DeploymentSignals = New-Object 'System.Collections.Generic.List[string]'
$script:GeneratedSignals = New-Object 'System.Collections.Generic.List[string]'
$script:SourceRoots = New-Object 'System.Collections.Generic.List[string]'
$script:SensitiveAreas = New-Object 'System.Collections.Generic.List[string]'
$script:Commands = New-Object 'System.Collections.Generic.List[string]'
$script:Warnings = New-Object 'System.Collections.Generic.List[string]'
$script:FileCount = 0
$script:VisitedCount = 0
$script:TotalBytes = [long]0
$script:LinksSkipped = 0
$script:SensitiveSkipped = 0
$script:LargeSkipped = 0

function Write-ObError {
    param([string]$Message)
    [Console]::Error.WriteLine("codex-baseline onboard: {0}" -f $Message)
}

function Get-ObItem {
    param([string]$Path)
    try {
        return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
    catch [System.IO.FileNotFoundException] { return $null }
    catch [System.IO.DirectoryNotFoundException] { return $null }
}

function Test-ObExists {
    param([string]$Path)
    return $null -ne (Get-ObItem $Path)
}

function Assert-ObOrdinary {
    param($Item, [string]$Kind = 'any')
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points are not allowed for onboarding mutation targets: $($Item.FullName)"
    }
    if ($Kind -eq 'file' -and $Item.PSIsContainer) { throw "Expected a regular file: $($Item.FullName)" }
    if ($Kind -eq 'tree' -and -not $Item.PSIsContainer) { throw "Expected a directory: $($Item.FullName)" }
}

function Assert-ObRepositoryPathSyntax {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Repository path cannot be empty.' }
    if ($Path.IndexOfAny([char[]](@(0..31) + @(127))) -ge 0) { throw 'Repository path contains control characters.' }
    if ($Path -match '^[\\/]{2}[?.][\\/]') { throw "Repository path cannot use a device namespace: $Path" }
    if ($Path -match '^(\\\\|//)') { throw "Repository path cannot use an unexpected UNC path: $Path" }
    if ($Path -match '^[A-Za-z]:' -and $Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "Repository drive path must be fully-qualified: $Path"
    }
    if ($Path -match '^[A-Za-z]:[\\/]' -and $Path.Substring(2).Contains(':')) {
        throw "Repository path cannot contain an alternate data stream: $Path"
    }
}

function Assert-ObAncestorsOrdinary {
    param([string]$Path)
    $cursor = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-ObItem $cursor
        if ($null -ne $item) { Assert-ObOrdinary $item 'tree' }
        $parent = [System.IO.Directory]::GetParent($cursor)
        if ($null -eq $parent -or [string]::Equals($parent.FullName, $cursor, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = $parent.FullName
    }
}

function Initialize-ObNativeIdentity {
    if ($null -ne ('CodexBaseline.OnboardNative' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexBaseline {
    public static class OnboardNative {
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

function Get-ObDirectoryIdentity {
    param([string]$Path)
    Initialize-ObNativeIdentity
    return [CodexBaseline.OnboardNative]::GetDirectoryIdentity([System.IO.Path]::GetFullPath($Path))
}

function Get-ObRuleSid {
    param($Rule)
    try {
        if ($Rule.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
            return $Rule.IdentityReference.Value
        }
        return $Rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw "Cannot resolve an ACL identity for safe onboarding apply: $($Rule.IdentityReference)"
    }
}

function Get-ObOwnerSid {
    param($Acl, [string]$Path)
    try {
        return $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw "Cannot resolve the ACL owner for safe onboarding apply: $Path"
    }
}

function Assert-ObPrivateApplyPath {
    param([string]$Path)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $trustedAccessSids = @($identity.User.Value, 'S-1-5-18', 'S-1-5-32-544')
    $trustedOwnerSids = @(
        $identity.User.Value,
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    $cursor = [System.IO.Path]::GetFullPath($Path)
    while ($true) {
        $parent = [System.IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        foreach ($check in @(
            [pscustomobject]@{ Path = $cursor; Right = [System.Security.AccessControl.FileSystemRights]::Delete },
            [pscustomobject]@{ Path = $parent.FullName; Right = [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles }
        )) {
            $acl = Get-Acl -LiteralPath $check.Path -ErrorAction Stop
            $ownerSid = Get-ObOwnerSid $acl $check.Path
            if ($ownerSid -notin $trustedOwnerSids) {
                throw "Onboarding apply is disabled for an untrusted path owner: $($check.Path) ($ownerSid)"
            }
            foreach ($rule in @($acl.Access)) {
                if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                if (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
                $sid = Get-ObRuleSid $rule
                if ($sid -in $trustedAccessSids) { continue }
                if (($rule.FileSystemRights -band $check.Right) -ne 0) {
                    throw "Onboarding apply is disabled for a shared/untrusted parent ACL: $($check.Path) ($sid)"
                }
            }
        }
        if ([string]::Equals($parent.FullName, $cursor, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = $parent.FullName
    }
}

function Assert-ObRootIdentity {
    $rootNow = Get-ObItem $script:RepositoryRoot
    if ($null -eq $rootNow) { throw "Repository disappeared during apply: $script:RepositoryRoot" }
    Assert-ObOrdinary $rootNow 'tree'
    Assert-ObAncestorsOrdinary $script:RepositoryRoot
    Assert-ObPrivateApplyPath $script:RepositoryRoot
    $identity = Get-ObDirectoryIdentity $script:RepositoryRoot
    if (-not [string]::Equals($identity, $script:RepositoryIdentity, [StringComparison]::Ordinal)) {
        throw "Repository root identity changed during onboarding apply: $script:RepositoryRoot"
    }
}

function Read-ObText {
    param([string]$Path)
    $item = Get-ObItem $Path
    if ($null -eq $item) { throw "File is missing: $Path" }
    Assert-ObOrdinary $item 'file'
    return $script:Utf8Strict.GetString([System.IO.File]::ReadAllBytes($item.FullName))
}

function Get-ObSha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ObFileHash {
    param([string]$Path)
    return Get-ObSha256 ([System.IO.File]::ReadAllBytes($Path))
}

function Test-ObSensitivePath {
    param([string]$RelativePath)
    $normalized = $RelativePath.Replace('\', '/')
    $base = [System.IO.Path]::GetFileName($normalized)
    if ($normalized -match '(^|/)(\.git|node_modules|vendor|dist|build|\.venv)(/|$)') { return $true }
    if ($base -match '^(?:\.env(?:\..*)?|.*\.(?:pem|p12|pfx|key|kdbx)|id_rsa|id_ed25519|credentials.*|auth\.json|session.*)$') { return $true }
    return $false
}

function Test-ObPrunedDirectory {
    param([string]$Name)
    return $Name -in @('.git', 'node_modules', 'vendor', 'dist', 'build', '.venv')
}

function Add-ObFile {
    param($Item, [string]$RelativePath)
    $controlCharacters = [char[]](@(0..31) + @(127))
    if ($RelativePath.IndexOfAny($controlCharacters) -ge 0) {
        $script:Warnings.Add('A path containing control characters was skipped.') | Out-Null
        return
    }
    if (Test-ObSensitivePath $RelativePath) {
        $script:SensitiveSkipped++
        return
    }
    $length = [long]$Item.Length
    if ($length -gt $MaxFileBytes -or ($script:TotalBytes + $length) -gt $MaxTotalBytes) {
        $script:LargeSkipped++
        return
    }
    $script:FileCount++
    if ($script:FileCount -gt $MaxFiles) {
        throw "File limit exceeded ($MaxFiles); narrow the repository or raise -MaxFiles deliberately."
    }
    $script:TotalBytes += $length
    $normalized = $RelativePath.Replace('\', '/')
    $script:Files.Add($normalized) | Out-Null
    $base = [System.IO.Path]::GetFileName($normalized)
    if ($base -in @(
        'package.json', 'pnpm-lock.yaml', 'yarn.lock', 'package-lock.json',
        'Cargo.toml', 'Cargo.lock', 'go.mod', 'go.sum', 'pyproject.toml',
        'poetry.lock', 'uv.lock', 'requirements.txt', 'Gemfile', 'composer.json',
        'pom.xml', 'build.gradle', 'build.gradle.kts', 'Makefile',
        'CMakeLists.txt', 'Dockerfile', 'docker-compose.yml', 'compose.yml'
    )) { $script:Manifests.Add($normalized) | Out-Null }
    if ($base -in @('AGENTS.md', 'AGENTS.override.md', 'CLAUDE.md', 'GEMINI.md', 'copilot-instructions.md')) {
        $script:AiInstructions.Add($normalized) | Out-Null
    }
    if ($normalized -match '(^|/)(\.codex|\.agents)/') { $script:AiInstructions.Add($normalized) | Out-Null }
    if ($normalized -match '^(\.github/workflows/|\.gitlab-ci\.yml$|\.gitlab-ci/|Jenkinsfile$|azure-pipelines\.yml$|\.circleci/)') {
        $script:CiDescriptors.Add($normalized) | Out-Null
    }
    if ($base -match '^(?i:README(?:\..*)?|CONTRIBUTING(?:\..*)?|SECURITY\.md|ARCHITECTURE\.md|ADR\.md)$' -or
        $normalized -match '^(?i:docs/(?:architecture|decisions|adr)/|doc/architecture/)') {
        $script:ProjectDocs.Add($normalized) | Out-Null
    }
    if ($base -match '^(?i:\.eslintrc(?:\..*)?|eslint\.config\..*|\.prettierrc(?:\..*)?|prettier\.config\..*|tsconfig.*\.json|jsconfig.*\.json|ruff\.toml|mypy\.ini|pytest\.ini|tox\.ini|\.golangci\..*|rustfmt\.toml|clippy\.toml|\.editorconfig)$') {
        $script:QualitySignals.Add($normalized) | Out-Null
    }
    if ($normalized -match '^(?i:(?:test|tests|spec|specs|__tests__)/)|(?i:/(?:test|tests|__tests__)/)') {
        $script:TestSignals.Add($normalized) | Out-Null
    }
    if ($base -in @('Dockerfile', 'docker-compose.yml', 'compose.yml', 'azure-pipelines.yml', 'Jenkinsfile') -or
        $normalized -match '^(?i:\.github/workflows/|\.gitlab-ci\.yml$|\.gitlab-ci/|\.circleci/|deploy/|deployment/|infra/|terraform/|k8s/|kubernetes/|helm/)') {
        $script:DeploymentSignals.Add($normalized) | Out-Null
    }
    if ($base -match '(?i:\.generated\.|\.g\.|\.pb\.)' -or
        $base -in @('package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'Cargo.lock', 'go.sum')) {
        $script:GeneratedSignals.Add($normalized) | Out-Null
    }
    if ($normalized.Contains('/')) {
        $top = $normalized.Substring(0, $normalized.IndexOf('/'))
        if ($top -in @('src', 'app', 'apps', 'lib', 'libs', 'packages', 'services', 'cmd', 'internal', 'server', 'client', 'frontend', 'backend', 'web', 'api') -and
            -not $script:SourceRoots.Contains($top)) { $script:SourceRoots.Add($top) | Out-Null }
    }
    if ($normalized -match '(?i)(auth|security|secret|crypto|migration|deploy|terraform|infra)') {
        $script:SensitiveAreas.Add($normalized) | Out-Null
    }
}

function Visit-ObDirectory {
    param([string]$Directory, [string]$RelativePrefix, [int]$Depth)
    if ($Depth -gt $MaxDepth) { return }
    foreach ($childPath in [System.IO.Directory]::EnumerateFileSystemEntries($Directory)) {
        $script:VisitedCount++
        if ($script:VisitedCount -gt $MaxVisited) {
            throw "Visited entry limit exceeded ($MaxVisited); narrow the repository or raise -MaxVisited deliberately."
        }
        $child = Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $script:LinksSkipped++
            continue
        }
        $relative = if ([string]::IsNullOrEmpty($RelativePrefix)) { $child.Name } else { "$RelativePrefix/$($child.Name)" }
        if ($child.PSIsContainer) {
            if (-not (Test-ObPrunedDirectory $child.Name)) {
                Visit-ObDirectory $child.FullName $relative ($Depth + 1)
            }
        }
        else {
            Add-ObFile $child $relative
        }
    }
}

function Restore-ObVerifiedPreimage {
    param([string]$Target, [byte[]]$BeforeBytes, [string]$BeforeHash)
    if ((Get-ObSha256 $BeforeBytes) -ne $BeforeHash) { throw 'In-memory onboarding preimage failed verification.' }
    $targetItem = Get-ObItem $Target
    if ($null -eq $targetItem) { throw 'Cannot restore onboarding preimage because AGENTS.md disappeared.' }
    Assert-ObOrdinary $targetItem 'file'
    $restore = Join-Path $script:RepositoryRoot ('.codex-baseline-restore-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $quarantine = Join-Path $script:RepositoryRoot ('.codex-baseline-failed-new-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        $stream = New-Object System.IO.FileStream($restore, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($BeforeBytes, 0, $BeforeBytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        if ((Get-ObFileHash $restore) -ne $BeforeHash) { throw 'Onboarding restore staging verification failed.' }
        [System.IO.File]::Replace($restore, $Target, $quarantine, $true)
        if ((Get-ObFileHash $Target) -ne $BeforeHash) { throw 'Onboarding preimage restore verification failed.' }
    }
    finally {
        foreach ($temporary in @($restore, $quarantine)) {
            $temporaryItem = Get-ObItem $temporary
            if ($null -ne $temporaryItem) { Assert-ObOrdinary $temporaryItem 'file'; Remove-Item -LiteralPath $temporary -Force }
        }
    }
}

function Add-ObCommand {
    param([string]$Value)
    if ($Value -match '^[A-Za-z0-9][A-Za-z0-9._:/@+*-]*( [A-Za-z0-9][A-Za-z0-9._:/@+*-]*)*$' -and
        -not $script:Commands.Contains($Value)) {
        $script:Commands.Add($Value) | Out-Null
    }
}

function Test-ObSafeRegularFile {
    param([string]$Path)
    $item = Get-ObItem $Path
    return $null -ne $item -and -not $item.PSIsContainer -and
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
}

function Infer-ObCommands {
    $packagePath = Join-Path $script:RepositoryRoot 'package.json'
    $packageItem = Get-ObItem $packagePath
    if ($null -ne $packageItem -and
        ($packageItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
        $packageItem.Length -le $MaxFileBytes -and
        -not (Test-ObSensitivePath 'package.json')) {
        try {
            $package = (Read-ObText $packagePath) | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $package.scripts) {
                foreach ($property in @($package.scripts.PSObject.Properties)) {
                    if ($property.Name -match '^[A-Za-z0-9:_-]{1,64}$') { Add-ObCommand ("npm run {0}" -f $property.Name) }
                }
            }
        }
        catch {
            $script:Warnings.Add('package.json is malformed; command inference skipped.') | Out-Null
        }
    }
    if (Test-ObSafeRegularFile (Join-Path $script:RepositoryRoot 'Cargo.toml')) {
        Add-ObCommand 'cargo check'; Add-ObCommand 'cargo test'; Add-ObCommand 'cargo fmt --check'
    }
    if (Test-ObSafeRegularFile (Join-Path $script:RepositoryRoot 'go.mod')) {
        Add-ObCommand 'go test ./...'; Add-ObCommand 'go vet ./...'
    }
    if (Test-ObSafeRegularFile (Join-Path $script:RepositoryRoot 'pyproject.toml')) {
        Add-ObCommand 'pytest'; Add-ObCommand 'ruff check .'
    }
    if (Test-ObSafeRegularFile (Join-Path $script:RepositoryRoot 'Makefile')) { Add-ObCommand 'make test' }
    $array = [string[]]$script:Commands.ToArray()
    [Array]::Sort($array, [StringComparer]::Ordinal)
    $script:Commands.Clear()
    foreach ($commandValue in $array) { $script:Commands.Add($commandValue) | Out-Null }
}

function Sort-ObList {
    param([System.Collections.Generic.List[string]]$List)
    $values = [string[]]$List.ToArray()
    [Array]::Sort($values, [StringComparer]::Ordinal)
    $List.Clear()
    $previous = $null
    $first = $true
    foreach ($value in $values) {
        if ($first -or -not [string]::Equals($value, $previous, [StringComparison]::Ordinal)) {
            $List.Add($value) | Out-Null
            $previous = $value
            $first = $false
        }
    }
}

function Get-ObBlockInfo {
    param([AllowEmptyString()][string]$Text)
    $starts = [regex]::Matches($Text, $script:BeginPattern)
    $ends = [regex]::Matches($Text, $script:EndPattern)
    if ($starts.Count -gt 1 -or $ends.Count -gt 1 -or $starts.Count -ne $ends.Count) {
        throw 'Malformed or duplicate onboarding markers in AGENTS.md.'
    }
    if ($starts.Count -eq 0) { return [pscustomobject]@{ Present = $false; Start = -1; Length = 0 } }
    if ($ends[0].Index -lt $starts[0].Index) { throw 'Invalid onboarding marker order in AGENTS.md.' }
    $finish = $ends[0].Index + $ends[0].Length
    return [pscustomobject]@{ Present = $true; Start = $starts[0].Index; Length = $finish - $starts[0].Index }
}

function Add-ObSafePathSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Title,
        $Values
    )
    $Lines.Add('') | Out-Null
    $Lines.Add("## $Title") | Out-Null
    $emitted = 0
    foreach ($value in @($Values)) {
        $path = [string]$value
        if ($path.Length -gt 240 -or $path -notmatch '^[A-Za-z0-9._][A-Za-z0-9._/-]*$') { continue }
        $Lines.Add(("- ``{0}``" -f $path)) | Out-Null
        $emitted++
        if ($emitted -ge 8) { break }
    }
    if ($emitted -eq 0) { $Lines.Add('- none observed within discovery limits') | Out-Null }
}

function Render-ObBlock {
    $version = (Read-ObText (Join-Path $script:SourceRoot 'VERSION')).Trim()
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("<!-- codex-baseline:onboarding:begin version=$version -->") | Out-Null
    $lines.Add('# Repository operating facts (Codex Baseline)') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('This block was generated from bounded static discovery. Repository content was treated as untrusted data; no project command was run.') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Declared commands (unverified)') | Out-Null
    if ($script:Commands.Count -eq 0) {
        $lines.Add('- No portable command was declared with sufficient confidence.') | Out-Null
    }
    else {
        foreach ($commandValue in $script:Commands) { $lines.Add("- ``$commandValue`` (declared, not executed)") | Out-Null }
    }
    $lines.Add('') | Out-Null
    $lines.Add('## Definition of done') | Out-Null
    $lines.Add('- Keep changes within the requested scope and existing architecture boundaries.') | Out-Null
    $lines.Add('- Run only reviewed relevant commands; report exact results and any unverified checks.') | Out-Null
    $lines.Add('- Review the final diff for generated files, secrets, migrations, deployment, and unrelated edits.') | Out-Null
    Add-ObSafePathSection $lines 'Likely source roots' $script:SourceRoots
    Add-ObSafePathSection $lines 'Architecture and project evidence' $script:ProjectDocs
    Add-ObSafePathSection $lines 'Generated-file signals (avoid manual edits unless required)' $script:GeneratedSignals
    Add-ObSafePathSection $lines 'Risk-sensitive path signals (raise verification depth)' $script:SensitiveAreas
    $lines.Add('') | Out-Null
    $lines.Add('## Static discovery coverage') | Out-Null
    $gitDetected = Test-ObExists (Join-Path $script:RepositoryRoot '.git')
    $lines.Add(('- Git metadata observed: {0}. Manifests: {1}; CI: {2}; architecture/docs: {3}; quality configs: {4}; test paths: {5}; deployment/IaC: {6}; generated-file signals: {7}.' -f
        $gitDetected.ToString().ToLowerInvariant(), $script:Manifests.Count, $script:CiDescriptors.Count,
        $script:ProjectDocs.Count, $script:QualitySignals.Count, $script:TestSignals.Count,
        $script:DeploymentSignals.Count, $script:GeneratedSignals.Count)) | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('Existing repository instructions and CI/manifests remain authoritative project evidence and must be reconciled when they conflict.') | Out-Null
    $lines.Add('<!-- codex-baseline:onboarding:end -->') | Out-Null
    return [string]::Join("`n", [string[]]$lines.ToArray())
}

function Apply-ObBlock {
    param([string]$Block)
    Assert-ObRootIdentity
    $target = Join-Path $script:RepositoryRoot 'AGENTS.md'
    $item = Get-ObItem $target
    if ($null -ne $item) { Assert-ObOrdinary $item 'file' }
    $beforeBytes = if ($null -eq $item) { $null } else { [System.IO.File]::ReadAllBytes($target) }
    $beforeHash = if ($null -eq $beforeBytes) { 'absent' } else { Get-ObSha256 $beforeBytes }
    Assert-ObRootIdentity
    $liveText = if ($null -eq $beforeBytes) { '' } else { $script:Utf8Strict.GetString($beforeBytes) }
    $info = Get-ObBlockInfo $liveText
    if ($info.Present) {
        $desired = $liveText.Substring(0, $info.Start) + $Block + $liveText.Substring($info.Start + $info.Length)
    }
    elseif ($liveText.Length -eq 0) {
        $desired = $Block
    }
    else {
        $separator = if ($liveText.EndsWith("`n")) { "`n" } else { "`n`n" }
        $desired = $liveText + $separator + $Block
    }
    $desiredBytes = $script:Utf8NoBom.GetBytes($desired)
    if ($beforeHash -ne 'absent' -and (Get-ObSha256 $desiredBytes) -eq $beforeHash) {
        [Console]::Out.WriteLine("onboarding block is already current: $target")
        return
    }
    $stage = Join-Path $script:RepositoryRoot ('.codex-baseline-onboard-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $backup = $null
    $rootIdentityIntact = $false
    try {
        $stream = New-Object System.IO.FileStream($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($desiredBytes, 0, $desiredBytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        Assert-ObRootIdentity
        if ($env:CODEX_BASELINE_TESTING -eq '1' -and $env:CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP -eq '1') {
            $outsidePath = [string]$env:CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP_TARGET
            $outsideItem = Get-ObItem $outsidePath
            if ($null -eq $outsideItem) { throw 'Root-swap test target does not exist.' }
            Assert-ObOrdinary $outsideItem 'tree'
            $movedRoot = '{0}.codex-baseline-test-original' -f $script:RepositoryRoot
            if (Test-ObExists $movedRoot) { throw "Root-swap test collision: $movedRoot" }
            [System.IO.Directory]::Move($script:RepositoryRoot, $movedRoot)
            New-Item -ItemType Junction -Path $script:RepositoryRoot -Target $outsideItem.FullName | Out-Null
        }
        Assert-ObRootIdentity
        $now = Get-ObItem $target
        if ($beforeHash -eq 'absent') {
            if ($null -ne $now) { throw "AGENTS.md appeared during apply: $target" }
            Assert-ObRootIdentity
            [System.IO.File]::Move($stage, $target)
            Assert-ObRootIdentity
        }
        else {
            if ($null -eq $now) { throw "AGENTS.md disappeared during apply: $target" }
            Assert-ObOrdinary $now 'file'
            if (-not [string]::IsNullOrWhiteSpace($env:CODEX_BASELINE_TEST_ONBOARD_CONCURRENT_TEXT)) {
                [System.IO.File]::WriteAllText($target, $env:CODEX_BASELINE_TEST_ONBOARD_CONCURRENT_TEXT, $script:Utf8NoBom)
            }
            if ((Get-ObFileHash $target) -ne $beforeHash) { throw "AGENTS.md changed during apply: $target" }
            Assert-ObRootIdentity
            $backup = '{0}.codex-baseline-backup.{1}.{2}' -f $target, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), $PID
            if (Test-ObExists $backup) { throw "Backup collision: $backup" }
            Assert-ObRootIdentity
            [System.IO.File]::Replace($stage, $target, $backup, $true)
            Assert-ObRootIdentity
            if ($env:CODEX_BASELINE_TEST_ONBOARD_CORRUPT_BACKUP_AFTER_REPLACE -eq '1') {
                [System.IO.File]::WriteAllText($backup, 'injected corrupt backup', $script:Utf8NoBom)
            }
            if ((Get-ObFileHash $backup) -ne $beforeHash) {
                try { Restore-ObVerifiedPreimage $target $beforeBytes $beforeHash }
                catch { throw "AGENTS.md backup verification failed and automatic restore failed: $($_.Exception.Message)" }
                Remove-Item -LiteralPath $backup -Force
                throw 'AGENTS.md backup verification failed; previous verified state was restored.'
            }
        }
        Assert-ObRootIdentity
        [Console]::Out.WriteLine("onboarding block applied: $target")
        if ($null -ne $backup) { [Console]::Out.WriteLine("backup: $backup") }
    }
    finally {
        try { Assert-ObRootIdentity; $rootIdentityIntact = $true } catch { $rootIdentityIntact = $false }
        if ($rootIdentityIntact -and (Test-ObExists $stage)) {
            $stageItem = Get-ObItem $stage
            Assert-ObOrdinary $stageItem 'file'
            Remove-Item -LiteralPath $stage -Force
        }
    }
}

function Write-ObList {
    param([string]$Title, $Values)
    [Console]::Out.WriteLine($Title)
    if ($Values.Count -eq 0) { [Console]::Out.WriteLine('- none observed within limits'); return }
    $emitted = 0
    $omitted = 0
    foreach ($value in $Values) {
        $path = [string]$value
        if ($path.Length -le 240 -and $path -match '^[A-Za-z0-9._][A-Za-z0-9._/-]*$') {
            [Console]::Out.WriteLine(("- ``{0}``" -f $path))
            $emitted++
        }
        else { $omitted++ }
    }
    if ($emitted -eq 0) { [Console]::Out.WriteLine('- no safely renderable path observed') }
    if ($omitted -gt 0) { [Console]::Out.WriteLine("- $omitted unsafe path name(s) omitted from the text view; use -Json for structured data") }
}

function Show-ObUsage {
    [Console]::Out.WriteLine(@'
Usage: powershell -File onboard.ps1 [-Apply] [-AcknowledgeExistingInstructions]
                                     [-Json] [-MaxFiles N] [-MaxVisited N] [repo]

Default is a bounded static dry-run. Repository files are untrusted data. This
script does not run project, package-manager, build, test, hook, or network
commands. Apply owns only a marker-delimited block in the root AGENTS.md. If
existing AI instructions are discovered, Apply requires explicit acknowledgement
after their reported paths have been reviewed for conflicts.
'@)
}

$exitCode = 0
try {
    if ($Apply -and $DryRun) { throw '-Apply and -DryRun cannot be combined.' }
    if ($Apply -and $Json) { throw '-Json and -Apply cannot be combined.' }
    Assert-ObRepositoryPathSyntax $Repository
    $rootItem = Get-ObItem $Repository
    if ($null -eq $rootItem) { throw "Repository does not exist: $Repository" }
    Assert-ObOrdinary $rootItem 'tree'
    $script:RepositoryRoot = [System.IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\', '/')
    Assert-ObAncestorsOrdinary $script:RepositoryRoot
    $filesystemRoot = [System.IO.Path]::GetPathRoot($script:RepositoryRoot).TrimEnd('\', '/')
    if ([string]::Equals($script:RepositoryRoot, $filesystemRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to onboard a filesystem root.'
    }
    if ($Apply) {
        Assert-ObPrivateApplyPath $script:RepositoryRoot
        $script:RepositoryIdentity = Get-ObDirectoryIdentity $script:RepositoryRoot
        Assert-ObRootIdentity
    }
    Visit-ObDirectory $script:RepositoryRoot '' 1
    Infer-ObCommands
    foreach ($inventoryList in @(
        $script:Files, $script:Manifests, $script:AiInstructions,
        $script:CiDescriptors, $script:ProjectDocs, $script:QualitySignals,
        $script:TestSignals, $script:DeploymentSignals, $script:GeneratedSignals,
        $script:SourceRoots, $script:SensitiveAreas, $script:Warnings
    )) { Sort-ObList $inventoryList }
    $block = Render-ObBlock
    $rootAgents = if (Test-ObExists (Join-Path $script:RepositoryRoot 'AGENTS.md')) { 'present' } else { 'absent' }
    $existingInstructionsRequireAck = $script:AiInstructions.Count -gt 0
    if ($existingInstructionsRequireAck -and $script:AiInstructions.Count -eq 1 -and
        $script:AiInstructions[0] -eq 'AGENTS.md' -and $rootAgents -eq 'present') {
        $existingInstructionsRequireAck = (Read-ObText (Join-Path $script:RepositoryRoot 'AGENTS.md')) -ne $block
    }
    if ($Json) {
        $report = [pscustomobject]@{
            schema = 1
            contract = 'codex-baseline-onboarding/v1'
            platform = 'native-windows'
            mode = 'dry-run'
            repository = $script:RepositoryRoot
            files = $script:FileCount
            entries_visited = $script:VisitedCount
            bytes = $script:TotalBytes
            links_skipped = $script:LinksSkipped
            sensitive_skipped = $script:SensitiveSkipped
            large_skipped = $script:LargeSkipped
            root_agents = $rootAgents
            existing_instructions = ($script:AiInstructions.Count -gt 0)
            existing_instructions_require_ack = [bool]$existingInstructionsRequireAck
            existing_instructions_acknowledged = [bool]$AcknowledgeExistingInstructions
            git_detected = (Test-ObExists (Join-Path $script:RepositoryRoot '.git'))
            project_commands_executed = $false
            commands = @($script:Commands)
            manifests = @($script:Manifests)
            ai = @($script:AiInstructions)
            ci = @($script:CiDescriptors)
            docs = @($script:ProjectDocs)
            quality = @($script:QualitySignals)
            tests = @($script:TestSignals)
            deployment = @($script:DeploymentSignals)
            generated = @($script:GeneratedSignals)
            source_roots = @($script:SourceRoots)
            sensitive_areas = @($script:SensitiveAreas)
            warnings = @($script:Warnings)
        }
        [Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 5 -Compress))
    }
    else {
        $mode = if ($Apply) { 'apply' } else { 'dry-run' }
        [Console]::Out.WriteLine("Repository: $script:RepositoryRoot")
        [Console]::Out.WriteLine("Mode: $mode")
        [Console]::Out.WriteLine(("Static files inspected: {0} ({1} bytes)" -f $script:FileCount, $script:TotalBytes))
        [Console]::Out.WriteLine(("Skipped: {0} links, {1} sensitive paths, {2} oversized/budgeted files" -f $script:LinksSkipped, $script:SensitiveSkipped, $script:LargeSkipped))
        [Console]::Out.WriteLine('Project commands executed: none')
        [Console]::Out.WriteLine('')
        Write-ObList 'Manifests and build descriptors:' $script:Manifests
        [Console]::Out.WriteLine('')
        Write-ObList 'Existing AI instructions (review for conflicts):' $script:AiInstructions
        [Console]::Out.WriteLine(("Existing-instruction acknowledgement: {0}" -f $(if ($AcknowledgeExistingInstructions) { 'supplied' } else { 'not-supplied' })))
        [Console]::Out.WriteLine('')
        Write-ObList 'CI descriptors:' $script:CiDescriptors
        [Console]::Out.WriteLine('')
        Write-ObList 'Architecture and project documentation:' $script:ProjectDocs
        [Console]::Out.WriteLine('')
        Write-ObList 'Test signals:' $script:TestSignals
        [Console]::Out.WriteLine('')
        Write-ObList 'Lint, format, and type-check signals:' $script:QualitySignals
        [Console]::Out.WriteLine('')
        Write-ObList 'Deployment, container, and infrastructure signals:' $script:DeploymentSignals
        [Console]::Out.WriteLine('')
        Write-ObList 'Likely source roots:' $script:SourceRoots
        [Console]::Out.WriteLine('')
        Write-ObList 'Generated-file signals:' $script:GeneratedSignals
        [Console]::Out.WriteLine('')
        Write-ObList 'Sensitive/risk areas by path name:' $script:SensitiveAreas
        [Console]::Out.WriteLine("`nProposed managed block:`n")
        [Console]::Out.WriteLine($block)
    }
    if ($Apply) {
        if ($existingInstructionsRequireAck -and -not $AcknowledgeExistingInstructions) {
            throw 'Existing AI instructions require -AcknowledgeExistingInstructions after conflict review; no repository file was changed.'
        }
        Apply-ObBlock $block
    }
    elseif (-not $Json) { [Console]::Out.WriteLine("`ndry-run: no repository files changed") }
}
catch {
    Write-ObError $_.Exception.Message
    $exitCode = 1
}

exit $exitCode
