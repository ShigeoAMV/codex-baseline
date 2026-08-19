[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:BaselineScript = Join-Path $script:RepositoryRoot 'scripts\codex-baseline.ps1'
$script:PowerShell = Join-Path $PSHOME 'powershell.exe'
$script:PrivateTestBase = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($env:SystemRoot))
$script:TestRoot = Join-Path $script:PrivateTestBase ('cbw-ob-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:Assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Baseline {
    param([string[]]$Arguments, [int]$ExpectedExit = 0)
    $effectiveArguments = @($Arguments)
    if ($effectiveArguments.Count -gt 0 -and
        @('install', 'update') -contains $effectiveArguments[0] -and
        -not ($effectiveArguments -contains '-AcknowledgeUnverifiedSource')) {
        $effectiveArguments += '-AcknowledgeUnverifiedSource'
    }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $script:BaselineScript @effectiveArguments 2>&1 | Out-String).Trim()
        $actualExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($actualExit -ne $ExpectedExit) {
        throw "Expected exit $ExpectedExit, got $actualExit for '$($Arguments -join ' ')':`n$output"
    }
    return $output
}

function Invoke-ScriptCapture {
    param([string]$Engine, [string]$Path, [string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $Engine -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String).Trim()
        $actualExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    return [pscustomobject]@{ ExitCode = $actualExit; Output = $output }
}

function Remove-TestRoot {
    $full = [System.IO.Path]::GetFullPath($script:TestRoot)
    $base = [System.IO.Path]::GetFullPath($script:PrivateTestBase).TrimEnd('\') + '\'
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([System.IO.Path]::GetFileName($full)).StartsWith('cbw-ob-', [StringComparison]::Ordinal)) {
        throw "Refusing unsafe test cleanup: $full"
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

function New-PrivateTestRoot {
    param([string]$Path)
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $trustedSids = @(
        $currentSid,
        (New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)),
        (New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null))
    )
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($currentSid)
    foreach ($sid in $trustedSids) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule) | Out-Null
    }
    [System.IO.Directory]::CreateDirectory($Path, $security) | Out-Null
    $effective = Get-Acl -LiteralPath $Path
    if (-not $effective.AreAccessRulesProtected -or
        $effective.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $currentSid.Value) {
        throw "Failed to create a private native test root: $Path"
    }
}

New-PrivateTestRoot $script:TestRoot
$junction = $null
try {
    $testHome = Join-Path $script:TestRoot 'home'
    [System.IO.Directory]::CreateDirectory($testHome) | Out-Null
    $env:HOME = $testHome
    $env:CODEX_HOME = Join-Path $testHome '.codex-test'
    $env:AGENTS_HOME = Join-Path $testHome '.agents-test'
    $installOutput = Invoke-Baseline @('install')
    Assert-True ($installOutput -match 'installed codex-baseline') 'test runtime install must succeed'
    $installedWrapper = Join-Path $testHome '.local\bin\codex-baseline.ps1'
    Assert-True (Test-Path -LiteralPath $installedWrapper -PathType Leaf) 'installed native wrapper must exist'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\runtime\scripts\onboard.ps1') -PathType Leaf) 'installed runtime must contain native onboarding'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\runtime\scripts\benchmark.ps1') -PathType Leaf) 'installed runtime must contain native benchmark validation'
    $script:BaselineScript = $installedWrapper

    $fixture = Join-Path $script:TestRoot 'repository'
    [System.IO.Directory]::CreateDirectory((Join-Path $fixture '.github\workflows')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $fixture 'src')) | Out-Null
    $sentinel = Join-Path $fixture 'PROJECT-COMMAND-RAN'
    $sentinelJson = $sentinel.Replace('\', '/')
    $package = @"
{
  "scripts": {
    "test": "powershell -NoProfile -Command Set-Content -LiteralPath '$sentinelJson' -Value ran",
    "lint": "exit 91"
  }
}
"@
    [System.IO.File]::WriteAllText((Join-Path $fixture 'package.json'), $package, $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $fixture 'package-lock.json'), '{}', $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $fixture 'ARCHITECTURE.md'), '# Architecture', $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $fixture '.env.local'), 'SECRET_DO_NOT_READ=needle', $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $fixture '.github\workflows\ci.yml'), 'jobs: {}', $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $fixture 'src\security-review.md'), 'ordinary risk area', $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $fixture 'src\auth-](bad).md'), 'untrusted name', $script:Utf8NoBom)
    $existing = "user instruction`r`n"
    $agentsPath = Join-Path $fixture 'AGENTS.md'
    [System.IO.File]::WriteAllText($agentsPath, $existing, $script:Utf8NoBom)
    $existingBytes = [System.IO.File]::ReadAllBytes($agentsPath)
    $outside = Join-Path $script:TestRoot 'outside'
    [System.IO.Directory]::CreateDirectory($outside) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $outside 'must-not-read.txt'), 'outside needle', $script:Utf8NoBom)
    $junction = Join-Path $fixture 'linked-outside'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null

    $dryReport = Invoke-Baseline @('onboard', '-Json', '-Repository', $fixture) | ConvertFrom-Json
    $onboardGolden = [System.IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'contracts\golden\onboarding-windows.json'), $script:Utf8NoBom) | ConvertFrom-Json
    Assert-True ($dryReport.platform -eq 'native-windows') 'onboarding JSON must label native Windows'
    Assert-True ($dryReport.schema -eq 2 -and $dryReport.contract -eq 'codex-baseline-onboarding/v2') 'onboarding must emit the shared v2 report contract'
    Assert-True ($dryReport.entries_visited -ge $dryReport.files) 'shared onboarding shape must report every visited entry'
    Assert-True (((@($dryReport.PSObject.Properties.Name) | Sort-Object) -join ',') -eq ((@($onboardGolden.PSObject.Properties.Name) | Sort-Object) -join ',')) 'native onboarding keys must match the cross-platform golden contract'
    Assert-True ($dryReport.mode -eq 'dry-run') 'onboarding JSON must identify dry-run mode'
    Assert-True ($dryReport.existing_instructions -and $dryReport.existing_instructions_require_ack -and -not $dryReport.existing_instructions_acknowledged) 'dry-run must expose an unacknowledged existing-instruction conflict'
    Assert-True (-not $dryReport.project_commands_executed) 'onboarding must report that project commands were not executed'
    Assert-True (-not (Test-Path -LiteralPath $sentinel)) 'package scripts must never execute during onboarding'
    Assert-True ($dryReport.sensitive_skipped -ge 1) 'sensitive .env input must be skipped'
    Assert-True ($dryReport.links_skipped -ge 1) 'junction input must be counted and skipped'
    Assert-True ('npm run test' -in @($dryReport.commands)) ("safe command inference must expose package script names only; commands={0}" -f (@($dryReport.commands) -join ','))
    Assert-True (-not (($dryReport | ConvertTo-Json -Depth 8) -match 'SECRET_DO_NOT_READ|outside needle')) 'sensitive and junction-target content must not leak into output'
    Assert-True (@($dryReport.parallelism_map.statements).Count -ge 12 -and @($dryReport.parallelism_map.statements).Count -le 64) 'onboarding must emit every bounded parallelism-map category'
    Assert-True (@($dryReport.parallelism_map.statements | ForEach-Object { $_.kind } | Select-Object -Unique).Count -ge 12) 'parallelism-map categories must be unique'
    Assert-True (@($dryReport.parallelism_map.statements | Where-Object { $_.kind -eq 'source_root' -and $_.status -eq 'inferred' }).Count -gt 0) 'source roots must not be mislabeled as package boundaries'
    Assert-True (@($dryReport.parallelism_map.statements | Where-Object { @('declared', 'inferred', 'unknown') -notcontains $_.status }).Count -eq 0) 'parallelism-map evidence status must be explicit'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($existingBytes, [System.IO.File]::ReadAllBytes($agentsPath))) 'dry-run must preserve AGENTS bytes'

    $floodFixture = Join-Path $script:TestRoot 'generated-flood'
    [System.IO.Directory]::CreateDirectory((Join-Path $floodFixture 'src')) | Out-Null
    foreach ($index in 1..80) {
        $generated = Join-Path $floodFixture ("generated-{0}" -f $index)
        [System.IO.Directory]::CreateDirectory($generated) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $generated 'package-lock.json'), '{}', $script:Utf8NoBom)
    }
    $floodReport = Invoke-Baseline @('onboard', '-Json', '-Repository', $floodFixture) | ConvertFrom-Json
    $requiredKinds = @('api_boundary','generated_ownership','package_boundary','shared_build_output','shared_cache','shared_database','shared_fixture','shared_port','source_root','test_shard','write_conflict','write_safe')
    $actualKinds = @($floodReport.parallelism_map.statements | ForEach-Object { [string]$_.kind } | Sort-Object -Unique)
    Assert-True (@($floodReport.parallelism_map.statements).Count -le 64) 'generated-signal flood must preserve the public 64-statement bound'
    Assert-True (($actualKinds -join ',') -eq ($requiredKinds -join ',')) 'generated-signal flood must retain every required parallelism-map category'

    $unacknowledgedApply = Invoke-Baseline @('onboard', '-Apply', '-Repository', $fixture) 1
    Assert-True ($unacknowledgedApply -match 'AcknowledgeExistingInstructions') 'apply must require explicit acknowledgement of reported existing instructions'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($existingBytes, [System.IO.File]::ReadAllBytes($agentsPath))) 'unacknowledged conflict must not mutate AGENTS bytes'

    $applyOutput = Invoke-Baseline @('onboard', '-Apply', '-AcknowledgeExistingInstructions', '-Repository', $fixture)
    Assert-True ($applyOutput -match 'onboarding block applied') 'apply must report a managed block write'
    Assert-True (-not (Test-Path -LiteralPath $sentinel)) 'apply must not execute inferred project commands'
    $appliedText = [System.IO.File]::ReadAllText($agentsPath, $script:Utf8NoBom)
    Assert-True ($appliedText.StartsWith($existing, [StringComparison]::Ordinal)) 'apply must preserve existing AGENTS prefix'
    Assert-True ([regex]::Matches($appliedText, '(?m)^<!-- codex-baseline:onboarding:begin').Count -eq 1) 'apply must create exactly one managed marker block'
    Assert-True ($appliedText -match '`src`' -and $appliedText -match '`ARCHITECTURE\.md`') 'applied block must carry discovered source and architecture boundaries'
    Assert-True ($appliedText -match '`package-lock\.json`' -and $appliedText -match '`src/security-review\.md`') 'applied block must carry generated and risk-sensitive signals'
    Assert-True ($appliedText -match 'Parallel execution map \(static evidence only\)' -and $appliedText -match 'one parent writer') 'applied block must carry bounded parallelism guidance'
    Assert-True ($appliedText -notmatch 'auth-\]\(bad\)') 'unsafe untrusted path names must not enter executable guidance'
    $backups = @(Get-ChildItem -LiteralPath $fixture -Filter 'AGENTS.md.codex-baseline-backup.*' -File)
    Assert-True ($backups.Count -eq 1) 'first apply must create one exact backup'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($existingBytes, [System.IO.File]::ReadAllBytes($backups[0].FullName))) 'apply backup must preserve exact prior bytes'

    $idempotentOutput = Invoke-Baseline @('onboard', '-Apply', '-AcknowledgeExistingInstructions', '-Repository', $fixture)
    Assert-True ($idempotentOutput -match 'already current') 'second apply must be idempotent'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture -Filter 'AGENTS.md.codex-baseline-backup.*' -File).Count -eq 1) 'idempotent apply must not create another backup'
    Assert-True (-not (Test-Path -LiteralPath $sentinel)) 'idempotent apply must remain no-exec'

    $junctionRootOutput = Invoke-Baseline @('onboard', '-Repository', $junction) 1
    Assert-True ($junctionRootOutput -match 'Reparse points are not allowed') 'a repository-root junction must fail closed'

    $limitOutput = Invoke-Baseline @('onboard', '-Repository', $fixture, '-MaxFiles', '1') 1
    Assert-True ($limitOutput -match 'File limit exceeded') 'bounded scanner must enforce MaxFiles'

    $visitedFixture = Join-Path $script:TestRoot 'visited-limit'
    [System.IO.Directory]::CreateDirectory($visitedFixture) | Out-Null
    1..6 | ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $visitedFixture (".env.{0}" -f $_)), 'ignored', $script:Utf8NoBom) }
    $visitedOutput = Invoke-Baseline @('onboard', '-Repository', $visitedFixture, '-MaxFiles', '100', '-MaxVisited', '3') 1
    Assert-True ($visitedOutput -match 'Visited entry limit exceeded') 'scanner must bound visited entries independently of accepted files'

    $linkedAgentsFixture = Join-Path $script:TestRoot 'linked-agents'
    [System.IO.Directory]::CreateDirectory($linkedAgentsFixture) | Out-Null
    $linkedAgentsTarget = Join-Path $script:TestRoot 'linked-agents-target'
    [System.IO.Directory]::CreateDirectory($linkedAgentsTarget) | Out-Null
    $linkedAgentsPath = Join-Path $linkedAgentsFixture 'AGENTS.md'
    New-Item -ItemType Junction -Path $linkedAgentsPath -Target $linkedAgentsTarget | Out-Null
    $linkedAgentsOutput = Invoke-Baseline @('onboard', '-Apply', '-Repository', $linkedAgentsFixture) 1
    Assert-True ($linkedAgentsOutput -match 'Reparse points are not allowed') 'apply must reject a linked AGENTS target'
    Assert-True (@(Get-ChildItem -LiteralPath $linkedAgentsTarget -Force).Count -eq 0) 'linked AGENTS rejection must not write through the junction'
    [System.IO.Directory]::Delete($linkedAgentsPath)

    $concurrentFixture = Join-Path $script:TestRoot 'concurrent-apply'
    [System.IO.Directory]::CreateDirectory($concurrentFixture) | Out-Null
    $concurrentAgents = Join-Path $concurrentFixture 'AGENTS.md'
    [System.IO.File]::WriteAllText($concurrentAgents, 'initial user text', $script:Utf8NoBom)
    $env:CODEX_BASELINE_TEST_ONBOARD_CONCURRENT_TEXT = 'concurrent writer wins'
    $concurrentOutput = Invoke-Baseline @('onboard', '-Apply', '-AcknowledgeExistingInstructions', '-Repository', $concurrentFixture) 1
    Remove-Item Env:\CODEX_BASELINE_TEST_ONBOARD_CONCURRENT_TEXT
    Assert-True ($concurrentOutput -match 'changed during apply') 'onboarding CAS must reject a concurrent writer'
    Assert-True ([System.IO.File]::ReadAllText($concurrentAgents, $script:Utf8NoBom) -eq 'concurrent writer wins') 'CAS rejection must preserve the concurrent writer content'
    Assert-True (-not ([System.IO.File]::ReadAllText($concurrentAgents, $script:Utf8NoBom) -match 'onboarding:begin')) 'CAS rejection must not add a managed block'

    $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    foreach ($rightCase in @(
        [pscustomobject]@{ Name = 'delete'; Right = [System.Security.AccessControl.FileSystemRights]::Delete },
        [pscustomobject]@{ Name = 'change-permissions'; Right = [System.Security.AccessControl.FileSystemRights]::ChangePermissions },
        [pscustomobject]@{ Name = 'take-ownership'; Right = [System.Security.AccessControl.FileSystemRights]::TakeOwnership }
    )) {
        $sharedAclFixture = Join-Path $script:TestRoot ("shared-acl-{0}" -f $rightCase.Name)
        [System.IO.Directory]::CreateDirectory($sharedAclFixture) | Out-Null
        $sharedAclAgents = Join-Path $sharedAclFixture 'AGENTS.md'
        $sharedAclBytes = $script:Utf8NoBom.GetBytes(("shared ACL {0} original" -f $rightCase.Name))
        [System.IO.File]::WriteAllBytes($sharedAclAgents, $sharedAclBytes)
        $sharedAclDirectory = New-Object System.IO.DirectoryInfo($sharedAclFixture)
        $sharedAcl = $sharedAclDirectory.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $sharedRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $usersSid,
            $rightCase.Right,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $sharedAcl.AddAccessRule($sharedRule) | Out-Null
        $sharedAclDirectory.SetAccessControl($sharedAcl)
        $sharedAclOutput = Invoke-Baseline @('onboard', '-Apply', '-AcknowledgeExistingInstructions', '-Repository', $sharedAclFixture) 1
        Assert-True ($sharedAclOutput -match 'shared/untrusted parent ACL') ("onboarding apply must reject broad group {0} rights before mutation" -f $rightCase.Name)
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($sharedAclBytes, [System.IO.File]::ReadAllBytes($sharedAclAgents))) ("shared {0} ACL rejection must preserve exact AGENTS bytes" -f $rightCase.Name)
        Assert-True (-not ([System.IO.File]::ReadAllText($sharedAclAgents, $script:Utf8NoBom) -match 'onboarding:begin')) ("shared {0} ACL rejection must not add a managed block" -f $rightCase.Name)
    }

    $untrustedOwnerFixture = Join-Path $script:TestRoot 'untrusted-owner-apply'
    [System.IO.Directory]::CreateDirectory($untrustedOwnerFixture) | Out-Null
    $untrustedOwnerAgents = Join-Path $untrustedOwnerFixture 'AGENTS.md'
    $untrustedOwnerBytes = $script:Utf8NoBom.GetBytes('untrusted owner original')
    [System.IO.File]::WriteAllBytes($untrustedOwnerAgents, $untrustedOwnerBytes)
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_ONBOARD_UNTRUSTED_OWNER_PATH = $untrustedOwnerFixture
    $untrustedOwnerOutput = Invoke-Baseline @('onboard', '-Apply', '-AcknowledgeExistingInstructions', '-Repository', $untrustedOwnerFixture) 1
    Remove-Item Env:\CODEX_BASELINE_TEST_ONBOARD_UNTRUSTED_OWNER_PATH
    Remove-Item Env:\CODEX_BASELINE_TESTING
    Assert-True ($untrustedOwnerOutput -match 'untrusted path owner') 'onboarding apply must reject an untrusted repository owner before mutation'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($untrustedOwnerBytes, [System.IO.File]::ReadAllBytes($untrustedOwnerAgents))) 'untrusted-owner rejection must preserve exact AGENTS bytes'

    $rootSwapFixture = Join-Path $script:TestRoot 'root-swap-apply'
    $rootSwapOutside = Join-Path $script:TestRoot 'root-swap-outside'
    $rootSwapOriginal = '{0}.codex-baseline-test-original' -f $rootSwapFixture
    [System.IO.Directory]::CreateDirectory($rootSwapFixture) | Out-Null
    [System.IO.Directory]::CreateDirectory($rootSwapOutside) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $rootSwapFixture 'AGENTS.md'), 'root swap original', $script:Utf8NoBom)
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP = '1'
    $env:CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP_TARGET = $rootSwapOutside
    $rootSwapOutput = Invoke-Baseline @('onboard', '-Apply', '-AcknowledgeExistingInstructions', '-Repository', $rootSwapFixture) 1
    Remove-Item Env:\CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP_TARGET
    Remove-Item Env:\CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP
    Remove-Item Env:\CODEX_BASELINE_TESTING
    Assert-True ($rootSwapOutput -match 'Reparse points are not allowed|identity changed') 'root-swap apply must fail before writing through the replacement junction'
    Assert-True ((Get-Item -LiteralPath $rootSwapFixture -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) 'root-swap test must replace the original path with a junction'
    Assert-True (@(Get-ChildItem -LiteralPath $rootSwapOutside -Force).Count -eq 0) 'root-swap rejection must not write into the replacement target'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $rootSwapOriginal 'AGENTS.md'), $script:Utf8NoBom) -eq 'root swap original') 'root-swap rejection must preserve the original AGENTS file'
    [System.IO.Directory]::Delete($rootSwapFixture)

    $backupFaultFixture = Join-Path $script:TestRoot 'backup-fault'
    [System.IO.Directory]::CreateDirectory($backupFaultFixture) | Out-Null
    $backupFaultAgents = Join-Path $backupFaultFixture 'AGENTS.md'
    $backupFaultBytes = $script:Utf8NoBom.GetBytes("verified user bytes`r`n")
    [System.IO.File]::WriteAllBytes($backupFaultAgents, $backupFaultBytes)
    $env:CODEX_BASELINE_TEST_ONBOARD_CORRUPT_BACKUP_AFTER_REPLACE = '1'
    $backupFaultOutput = Invoke-Baseline @('onboard', '-Apply', '-AcknowledgeExistingInstructions', '-Repository', $backupFaultFixture) 1
    Remove-Item Env:\CODEX_BASELINE_TEST_ONBOARD_CORRUPT_BACKUP_AFTER_REPLACE
    Assert-True ($backupFaultOutput -match 'previous verified state was restored') 'post-replace backup CAS mismatch must report automatic restore'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($backupFaultBytes, [System.IO.File]::ReadAllBytes($backupFaultAgents))) 'backup CAS mismatch must restore exact verified preimage bytes'
    Assert-True (@(Get-ChildItem -LiteralPath $backupFaultFixture -Filter '.codex-baseline-*.tmp' -Force).Count -eq 0) 'backup recovery must remove staging and quarantine files'
    Assert-True (@(Get-ChildItem -LiteralPath $backupFaultFixture -Filter 'AGENTS.md.codex-baseline-backup.*' -Force).Count -eq 0) 'corrupt backup artifact must not be retained as a valid backup'

    $benchmarkReport = Invoke-Baseline @('benchmark', '-Static', '-Json') | ConvertFrom-Json
    $benchmarkManifest = (Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'benchmarks\manifest.json') -Raw | ConvertFrom-Json)
    Assert-True ($benchmarkReport.schema -eq 2 -and $benchmarkReport.contract -eq 'codex-baseline-benchmark/v2' -and $benchmarkReport.status -eq 'completed') 'benchmark JSON must emit the shared completed v2 report envelope'
    Assert-True ($benchmarkReport.platform -eq 'native-windows') 'benchmark JSON must label native Windows'
    Assert-True ($benchmarkReport.mode -eq 'static-contract-only') 'benchmark must label static-only evidence'
    Assert-True (-not $benchmarkReport.model_invoked -and -not $benchmarkReport.verifiers_executed) 'static benchmark must invoke neither model nor verifier'
    Assert-True (@($benchmarkReport.tasks).Count -eq @($benchmarkManifest.tasks).Count) 'static benchmark must validate every registered task by default'
    Assert-True (@($benchmarkReport.tasks).Count -eq 10) 'static benchmark must cover six parallel-positive and four serial-negative tasks'
    Assert-True (@($benchmarkManifest.tasks | Where-Object { $_.parallelism_class -eq 'parallel-positive' }).Count -eq 6 -and @($benchmarkManifest.tasks | Where-Object { $_.parallelism_class -eq 'serial-negative' }).Count -eq 4) 'benchmark manifest must encode the required positive/negative balance'
    Assert-True (@($benchmarkManifest.tasks | Where-Object { $_.expected_lanes -eq 6 }).Count -ge 1) 'benchmark manifest must contain a real six-lane case'
    Assert-True ((@($benchmarkReport.tasks | ForEach-Object { $_.class }) -join ',') -match 'small' -and
        'medium' -in @($benchmarkReport.tasks | ForEach-Object { $_.class }) -and
        'large' -in @($benchmarkReport.tasks | ForEach-Object { $_.class }) -and
        'risk-sensitive' -in @($benchmarkReport.tasks | ForEach-Object { $_.class })) 'static benchmark must cover all four task classes'
    Assert-True (@($benchmarkReport.tasks | Where-Object { $_.fixture_contract -ne 'valid-static' -or $_.verifier_contract -ne 'valid-static' }).Count -eq 0) 'every fixture and verifier contract must validate'
    Assert-True (@($benchmarkReport.tasks | Where-Object { $_.starter_verifier_result -ne 'not-executed-native-static' }).Count -eq 0) 'starter verification limitation must be explicit per task'

    $nativeEvaluation = $benchmarkManifest.native_powershell_evaluation
    Assert-True ($nativeEvaluation.status -eq 'manual-no-key' -and $nativeEvaluation.platform -eq 'native-windows') 'native PowerShell evaluation must be explicitly manual and no-key'
    Assert-True ((@($nativeEvaluation.engines) -join ',') -eq 'powershell-5.1,powershell-7' -and (@($nativeEvaluation.arms) -join ',') -eq 'vanilla,baseline-solo') 'native PowerShell evaluation must define both engines and paired arms'
    Assert-True ((@($nativeEvaluation.metrics) -join ',') -eq 'task_pass,failed_command_events,parser_error_events') 'native PowerShell evaluation must measure command and parser failures'
    $nativeRunner = Join-Path $script:RepositoryRoot ([string]$nativeEvaluation.runner).Replace('/', '\')
    $nativeTask = Join-Path $script:RepositoryRoot ([string]$nativeEvaluation.task).Replace('/', '\')
    $nativeVerifier = Join-Path $script:RepositoryRoot ([string]$nativeEvaluation.verifier).Replace('/', '\')
    Assert-True ((Test-Path -LiteralPath $nativeRunner -PathType Leaf) -and (Test-Path -LiteralPath $nativeTask -PathType Leaf) -and (Test-Path -LiteralPath $nativeVerifier -PathType Leaf)) 'native PowerShell evaluation inputs must exist'
    $nativeEngines = @([pscustomobject]@{ Path = $script:PowerShell; Label = 'ps51' })
    $powerShellCore = @(Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($powerShellCore.Count -eq 1) { $nativeEngines += [pscustomobject]@{ Path = $powerShellCore[0].Path; Label = 'ps7' } }
    foreach ($engine in $nativeEngines) {
        $nativeWorkspace = Join-Path $script:TestRoot ("native evaluation ({0})" -f $engine.Label)
        $prepared = Invoke-ScriptCapture $engine.Path $nativeRunner @('-Mode', 'Prepare', '-Workspace', $nativeWorkspace)
        Assert-True ($prepared.ExitCode -eq 0 -and $prepared.Output -match 'prepared native PowerShell evaluation workspace') ("{0}: native evaluation prepare must succeed" -f $engine.Label)
        $starter = Invoke-ScriptCapture $engine.Path $nativeRunner @('-Mode', 'Verify', '-Workspace', $nativeWorkspace)
        Assert-True ($starter.ExitCode -ne 0 -and $starter.Output -match 'result.json') ("{0}: native evaluation starter must fail verification" -f $engine.Label)
        $resultJson = '{"route":"app/(main)/page.tsx","port":4317,"filename":"O''Brien $value [draft].txt","literal":"a|b $HOME \"quoted\""}'
        [System.IO.File]::WriteAllText((Join-Path $nativeWorkspace 'result.json'), $resultJson + "`n", $script:Utf8NoBom)
        $verified = Invoke-ScriptCapture $engine.Path $nativeRunner @('-Mode', 'Verify', '-Workspace', $nativeWorkspace)
        Assert-True ($verified.ExitCode -eq 0 -and $verified.Output -match 'PASS: native PowerShell command-generation evaluation') ("{0}: native evaluation verifier must accept the exact result" -f $engine.Label)
    }

    $subsetReport = Invoke-Baseline @('benchmark', '-Json', '-Tasks', 'small-js-bug,risk-migration') | ConvertFrom-Json
    Assert-True (@($subsetReport.tasks).Count -eq 2) 'benchmark task selection must be bounded to requested IDs'
    $unsafeTaskOutput = Invoke-Baseline @('benchmark', '-Tasks', '..\escape') 1
    Assert-True ($unsafeTaskOutput -match 'Unsafe requested task id') 'unsafe benchmark task IDs must fail closed'
    $liveOutput = Invoke-Baseline @('benchmark', '-Live') 1
    Assert-True ($liveOutput -match 'not implemented.*No model') 'native live benchmark must fail clearly before auth/model access'

    [Console]::Out.WriteLine(("PASS: Windows onboarding/benchmark ({0} assertions, PowerShell {1})" -f $script:Assertions, $PSVersionTable.PSVersion))
}
finally {
    foreach ($faultVariable in @(
        'CODEX_BASELINE_TEST_ONBOARD_CONCURRENT_TEXT',
        'CODEX_BASELINE_TEST_ONBOARD_CORRUPT_BACKUP_AFTER_REPLACE',
        'CODEX_BASELINE_TESTING',
        'CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP',
        'CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP_TARGET',
        'CODEX_BASELINE_TEST_ONBOARD_UNTRUSTED_OWNER_PATH'
    )) {
        if (Test-Path -LiteralPath ("Env:\{0}" -f $faultVariable)) { Remove-Item -LiteralPath ("Env:\{0}" -f $faultVariable) }
    }
    if ($null -ne $junction -and (Test-Path -LiteralPath $junction)) { [System.IO.Directory]::Delete($junction) }
    Remove-TestRoot
}
