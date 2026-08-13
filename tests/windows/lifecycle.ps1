[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:BaselineScript = Join-Path $script:RepositoryRoot 'scripts\codex-baseline.ps1'
$script:PowerShell = Join-Path $PSHOME 'powershell.exe'
$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cbw-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:Assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Invoke-Baseline {
    param(
        [string[]]$Arguments,
        [int]$ExpectedExit = 0
    )
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
    finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($actualExit -ne $ExpectedExit) {
        throw "Expected exit $ExpectedExit, got $actualExit for '$($Arguments -join ' ')':`n$output"
    }
    return $output
}

function Test-NoBom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return $bytes.Length -lt 3 -or -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Set-TestEnvironment {
    param([string]$Root)
    $testHome = Join-Path $Root 'home'
    [System.IO.Directory]::CreateDirectory($testHome) | Out-Null
    $env:HOME = $testHome
    $env:CODEX_HOME = Join-Path $testHome 'custom-codex'
    $env:AGENTS_HOME = Join-Path $testHome 'custom-agents'
    return $testHome
}

function Remove-TestRoot {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $full.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([System.IO.Path]::GetFileName($full)).StartsWith('cbw-', [System.StringComparison]::Ordinal)) {
        throw "Refusing unsafe test cleanup: $full"
    }
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

[System.IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
try {
    $testHome = Set-TestEnvironment (Join-Path $script:TestRoot 'main')
    $originalText = "user guidance`r`n"
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
    $agentsFile = Join-Path $env:CODEX_HOME 'AGENTS.md'
    [System.IO.File]::WriteAllText($agentsFile, $originalText, $script:Utf8NoBom)
    $originalBytes = [System.IO.File]::ReadAllBytes($agentsFile)

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $unacknowledgedOutput = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $script:BaselineScript install 2>&1 | Out-String).Trim()
        $unacknowledgedExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    Assert-True ($unacknowledgedExit -eq 1) 'unsigned source install must require explicit acknowledgement'
    Assert-True ($unacknowledgedOutput -match 'AcknowledgeUnverifiedSource') 'acknowledgement failure must be actionable'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) 'unacknowledged source must not mutate state'

    $tamperedSource = Join-Path $script:TestRoot 'tampered-source'
    [System.IO.Directory]::CreateDirectory($tamperedSource) | Out-Null
    foreach ($sourceName in @('VERSION', 'baseline', 'benchmarks', 'scripts')) {
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $sourceName) -Destination $tamperedSource -Recurse
    }
    [System.IO.File]::AppendAllText((Join-Path $tamperedSource 'baseline\global\AGENTS.block.md'), "`ntampered`n", $script:Utf8NoBom)
    Set-TestEnvironment (Join-Path $script:TestRoot 'tampered-home') | Out-Null
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $tamperedOutput = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tamperedSource 'scripts\codex-baseline.ps1') install -AcknowledgeUnverifiedSource 2>&1 | Out-String).Trim()
        $tamperedExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    Assert-True ($tamperedExit -eq 1 -and $tamperedOutput -match 'Payload byte length mismatch') 'tampered source payload must fail before planning'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) 'tampered source payload must not mutate state'

    $racySource = Join-Path $script:TestRoot 'racy-source'
    [System.IO.Directory]::CreateDirectory($racySource) | Out-Null
    foreach ($sourceName in @('VERSION', 'baseline', 'benchmarks', 'scripts')) {
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $sourceName) -Destination $racySource -Recurse
    }
    Set-TestEnvironment (Join-Path $script:TestRoot 'racy-home') | Out-Null
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_MUTATE_SOURCE_AFTER_VERIFY = '1'
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $racyOutput = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $racySource 'scripts\codex-baseline.ps1') install -AcknowledgeUnverifiedSource 2>&1 | Out-String).Trim()
        $racyExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
        Remove-Item Env:\CODEX_BASELINE_TEST_MUTATE_SOURCE_AFTER_VERIFY
        Remove-Item Env:\CODEX_BASELINE_TESTING
    }
    Assert-True ($racyExit -eq 1 -and $racyOutput -match 'Payload byte length mismatch|changed while creating the verified snapshot') 'source mutation between verification and snapshot must fail closed'
    Assert-True (-not (Test-Path -LiteralPath $env:AGENTS_HOME)) 'source-race rejection must not create AGENTS_HOME'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) 'source-race rejection must not mutate state'

    Set-TestEnvironment (Join-Path $script:TestRoot 'snapshot-acl-home') | Out-Null
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_WEAKEN_SNAPSHOT_ACL_AFTER_VERIFY = '1'
    $snapshotAclOutput = Invoke-Baseline @('install') 1
    Remove-Item Env:\CODEX_BASELINE_TEST_WEAKEN_SNAPSHOT_ACL_AFTER_VERIFY
    Remove-Item Env:\CODEX_BASELINE_TESTING
    Assert-True ($snapshotAclOutput -match 'untrusted SID') ("verified source snapshot must reject a broadened DACL before mutation; output: {0}" -f $snapshotAclOutput)
    Assert-True (-not (Test-Path -LiteralPath $env:AGENTS_HOME)) 'snapshot ACL rejection must not create AGENTS_HOME'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) 'snapshot ACL rejection must not create baseline state'

    Set-TestEnvironment (Join-Path $script:TestRoot 'snapshot-content-home') | Out-Null
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_MUTATE_SNAPSHOT_AFTER_VERIFY = '1'
    $snapshotContentOutput = Invoke-Baseline @('install') 1
    Remove-Item Env:\CODEX_BASELINE_TEST_MUTATE_SNAPSHOT_AFTER_VERIFY
    Remove-Item Env:\CODEX_BASELINE_TESTING
    Assert-True ($snapshotContentOutput -match 'Payload byte length mismatch|Payload hash mismatch') 'verified source snapshot must be rehashed immediately before use'
    Assert-True (-not (Test-Path -LiteralPath $env:AGENTS_HOME)) 'snapshot content rejection must occur before managed-home mutation'
    $testHome = Set-TestEnvironment (Join-Path $script:TestRoot 'main')

    $codexStubDirectory = Join-Path $script:TestRoot 'codex-stub'
    [System.IO.Directory]::CreateDirectory($codexStubDirectory) | Out-Null
    $codexStub = Join-Path $codexStubDirectory 'codex.ps1'
    $savedPath = $env:Path
    try {
        $env:Path = "${codexStubDirectory};${savedPath}"
        $currentStub = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
if ($Arguments[0] -eq '--version' -or $Arguments[0] -eq '--strict-config') {
    Write-Output 'codex-cli 0.147.0'
    exit 0
}
if ($Arguments[0] -eq 'features' -and $Arguments[1] -eq 'list') {
    Write-Output 'goals stable true'
    Write-Output 'multi_agent stable true'
    Write-Output 'skill_search stable true'
    exit 0
}
exit 1
'@
        [System.IO.File]::WriteAllText($codexStub, $currentStub, $script:Utf8NoBom)
        $nativeDoctor = Invoke-Baseline @('doctor', '-Json') | ConvertFrom-Json
        Assert-True ($nativeDoctor.codex_verification -eq 'executed-native-windows') 'doctor must execute an available native Windows Codex'
        Assert-True ($nativeDoctor.native_capabilities -eq 'verified') 'doctor must verify required stable native capabilities'
        Assert-True ($nativeDoctor.active_config.status -eq 'accepted-by-strict-config') 'doctor must execute strict-config validation'

        $oldStub = $currentStub.Replace('0.147.0', '0.146.0')
        [System.IO.File]::WriteAllText($codexStub, $oldStub, $script:Utf8NoBom)
        $oldDoctor = Invoke-Baseline -Arguments @('doctor', '-Json') -ExpectedExit 1 | ConvertFrom-Json
        Assert-True ((@($oldDoctor.failures) -join "`n") -match 'older than the supported minimum version 0\.147\.0') 'doctor must enforce the manifest-declared native Codex minimum'

        $futureStub = $currentStub.Replace('0.147.0', '0.148.0')
        [System.IO.File]::WriteAllText($codexStub, $futureStub, $script:Utf8NoBom)
        $futureDoctor = Invoke-Baseline @('doctor', '-Json') | ConvertFrom-Json
        Assert-True ($futureDoctor.native_capabilities -eq 'unverified-future-version') 'doctor must not claim volatile capabilities verified on an untested future Codex version'
        Assert-True ((@($futureDoctor.warnings) -join "`n") -match 'newer than the tested version 0\.147\.0') 'doctor must explain future-version uncertainty'
    }
    finally {
        $env:Path = $savedPath
    }

    $dryOutput = Invoke-Baseline @('install', '-DryRun')
    Assert-True ($dryOutput -match 'dry-run: no files changed') 'install dry-run must report non-mutation'
    Assert-True (-not (Test-Path -LiteralPath $env:AGENTS_HOME)) 'dry-run must not create AGENTS_HOME'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) 'dry-run must not create baseline state'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($originalBytes, [System.IO.File]::ReadAllBytes($agentsFile))) 'dry-run must preserve AGENTS bytes'

    $installOutput = Invoke-Baseline @('install')
    Assert-True ($installOutput -match 'installed codex-baseline 0\.1\.0') 'clean install must report version'
    $agentsText = [System.IO.File]::ReadAllText($agentsFile, $script:Utf8NoBom)
    Assert-True ($agentsText.StartsWith($originalText, [System.StringComparison]::Ordinal)) 'install must preserve existing guidance prefix'
    Assert-True ($agentsText -match '<!-- codex-baseline:begin version=0\.1\.0 -->') 'managed block must be installed'
    Assert-True ((Get-ChildItem -LiteralPath (Join-Path $env:AGENTS_HOME 'skills') -Directory).Count -eq 4) 'exactly four baseline skills must be installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'agents\codex-baseline-reviewer.toml') -PathType Leaf) 'reviewer must be installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\runtime\scripts\codex-baseline.ps1') -PathType Leaf) 'Windows runtime entry point must be installed'
    $wrapper = Join-Path $testHome '.local\bin\codex-baseline.ps1'
    Assert-True (Test-Path -LiteralPath $wrapper -PathType Leaf) 'Windows wrapper must be installed'
    Assert-True (Test-NoBom $wrapper) 'generated wrapper must be UTF-8 without BOM'
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $wrapperOutput = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper doctor -Json 2>&1 | Out-String).Trim()
        $wrapperExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    Assert-True ($wrapperExit -eq 0) ("installed wrapper doctor must succeed; output: {0}" -f $wrapperOutput)
    $wrapperDoctor = $wrapperOutput | ConvertFrom-Json
    Assert-True ($wrapperDoctor.platform -eq 'native-windows') 'installed wrapper must dispatch to the native Windows runtime'
    Assert-True ($wrapperDoctor.source_provenance.scope -eq 'installed-runtime') 'installed wrapper must report installed-runtime provenance'
    Assert-True ($wrapperDoctor.source_provenance.payload_sha256 -eq ((Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'baseline\manifest.json') -Raw | ConvertFrom-Json).payload_hash)) 'installed runtime must retain the verified payload hash'

    $currentPath = Join-Path $env:CODEX_HOME 'codex-baseline\state\current'
    $firstTransaction = [System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim()
    $journalPath = Join-Path $env:CODEX_HOME ("codex-baseline\state\transactions\{0}\transaction.json" -f $firstTransaction)
    Assert-True (Test-NoBom $journalPath) 'transaction journal must be UTF-8 without BOM'
    $journal = [System.IO.File]::ReadAllText($journalPath, $script:Utf8NoBom) | ConvertFrom-Json
    Assert-True ($journal.State -eq 'committed' -and @($journal.Objects).Count -eq 8) 'journal must record eight committed objects'

    $reinstallOutput = Invoke-Baseline @('install')
    Assert-True ($reinstallOutput -match 'already installed; no changes') ("reinstall must be idempotent; output: {0}" -f $reinstallOutput)
    Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'idempotent reinstall must not replace current transaction'

    $updateOutput = Invoke-Baseline @('update', '-DryRun')
    Assert-True ($updateOutput -match 'already installed; no changes') ("update dry-run must accept an already-current payload; output: {0}" -f $updateOutput)
    Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'update dry-run must preserve current transaction'

    $rollbackDryOutput = Invoke-Baseline @('rollback', '-DryRun')
    Assert-True ($rollbackDryOutput -match 'dry-run: no files changed') 'rollback dry-run must report non-mutation'
    Assert-True (Test-Path -LiteralPath $wrapper -PathType Leaf) 'rollback dry-run must preserve installed wrapper'

    $uninstallDryOutput = Invoke-Baseline @('uninstall', '-DryRun')
    Assert-True ($uninstallDryOutput -match 'dry-run: no files changed') 'uninstall dry-run must report non-mutation'
    Assert-True (Test-Path -LiteralPath $wrapper -PathType Leaf) 'uninstall dry-run must preserve installed wrapper'

    $doctorJson = Invoke-Baseline @('doctor', '-Json') | ConvertFrom-Json
    $doctorGolden = [System.IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'contracts\golden\doctor-windows.json'), $script:Utf8NoBom) | ConvertFrom-Json
    Assert-True ($doctorJson.platform -eq 'native-windows') 'doctor must label native Windows explicitly'
    Assert-True ($doctorJson.contract -eq 'codex-baseline-doctor/v1') 'doctor must emit the shared v1 report contract'
    Assert-True ($doctorJson.baseline_version -eq '0.1.0') 'doctor must report the installed baseline version'
    Assert-True ($doctorJson.source_provenance.scope -eq 'local-source' -and $doctorJson.source_provenance.trust -eq 'unsigned-local-source') 'source invocation must report explicit local-source trust provenance'
    Assert-True ($doctorJson.codex_verification -eq 'unverified-native-codex-not-installed') 'missing native Codex must be labelled unverified'
    Assert-True ($doctorJson.managed_objects.ok -eq 8 -and $doctorJson.managed_objects.total -eq 8) 'doctor must report all managed objects through the shared shape'
    Assert-True ($doctorJson.skills.ok -eq 4 -and $doctorJson.skills.total -eq 4) 'doctor must report all skills through the shared shape'
    Assert-True ($doctorJson.runtime_dependencies.status -eq 'verified' -and @($doctorJson.runtime_dependencies.missing).Count -eq 0) 'doctor must report native runtime dependency health'
    Assert-True ($doctorJson.active_config.status -eq 'unverified-native-codex-not-installed' -and $doctorJson.hook_state.baseline_owned -eq 0) 'doctor must distinguish unavailable native config verification from zero baseline-owned hooks'
    Assert-True ($doctorJson.paths.codex_home -eq $env:CODEX_HOME -and $doctorJson.paths.agents_home -eq $env:AGENTS_HOME) 'doctor must report effective native managed paths'
    Assert-True (((@($doctorJson.PSObject.Properties.Name) | Sort-Object) -join ',') -eq ((@($doctorGolden.PSObject.Properties.Name) | Sort-Object) -join ',')) 'native doctor keys must match the cross-platform golden contract'
    Assert-True (@($doctorJson.failures).Count -eq 0) 'missing native Codex is a platform limitation, not installation corruption'

    $skillFile = Join-Path $env:AGENTS_HOME 'skills\codex-baseline-deep-work\SKILL.md'
    $skillBytes = [System.IO.File]::ReadAllBytes($skillFile)
    [System.IO.File]::AppendAllText($skillFile, "`nlocal drift", $script:Utf8NoBom)
    $driftOutput = Invoke-Baseline @('update') 1
    Assert-True ($driftOutput -match 'drifted') 'three-way update must reject managed drift'
    [System.IO.File]::WriteAllBytes($skillFile, $skillBytes)

    $uninstallOutput = Invoke-Baseline @('uninstall')
    Assert-True ($uninstallOutput -match 'uninstalled codex-baseline') 'uninstall must complete transactionally'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:AGENTS_HOME 'skills\codex-baseline-deep-work'))) 'uninstall must remove managed skills'
    Assert-True (-not (Test-Path -LiteralPath $wrapper)) 'uninstall must remove managed wrapper'
    Assert-True (-not ([System.IO.File]::ReadAllText($agentsFile, $script:Utf8NoBom) -match 'codex-baseline:begin')) 'uninstall must remove only the managed block'

    $rollbackUninstall = Invoke-Baseline @('rollback')
    Assert-True ($rollbackUninstall -match 'rolled back transaction') 'rollback must restore an uninstall'
    Assert-True (Test-Path -LiteralPath $wrapper -PathType Leaf) 'rollback of uninstall must restore wrapper'

    $rollbackInstall = Invoke-Baseline @('rollback')
    Assert-True ($rollbackInstall -match 'rolled back transaction') 'second rollback must restore pre-install state'
    Assert-True (-not (Test-Path -LiteralPath $wrapper)) 'rollback of initial install must remove wrapper'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:AGENTS_HOME 'skills\codex-baseline-deep-work'))) 'rollback of initial install must remove skills'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($originalBytes, [System.IO.File]::ReadAllBytes($agentsFile))) 'rollback must restore exact previous AGENTS bytes'

    $faultHome = Set-TestEnvironment (Join-Path $script:TestRoot 'fault')
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
    $faultAgents = Join-Path $env:CODEX_HOME 'AGENTS.md'
    [System.IO.File]::WriteAllText($faultAgents, $originalText, $script:Utf8NoBom)
    $env:CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT = '2'
    $faultOutput = Invoke-Baseline @('install') 1
    Remove-Item Env:\CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT
    Assert-True ($faultOutput -match 'Injected test fault') 'fault injection must exercise recovery'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\pending'))) 'automatic recovery must clear pending state'
    Assert-True ([System.IO.File]::ReadAllText($faultAgents, $script:Utf8NoBom) -eq $originalText) 'automatic recovery must restore AGENTS content'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:AGENTS_HOME 'skills\codex-baseline-deep-work'))) 'automatic recovery must remove partial managed trees'

    $reparseHome = Set-TestEnvironment (Join-Path $script:TestRoot 'reparse')
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
    $junctionTarget = Join-Path $reparseHome 'junction-target'
    [System.IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
    New-Item -ItemType Junction -Path $env:AGENTS_HOME -Target $junctionTarget | Out-Null
    $reparseOutput = Invoke-Baseline @('install', '-DryRun') 1
    Assert-True ($reparseOutput -match 'Reparse points are not allowed') 'dry-run must fail closed on a junction ancestor'
    [System.IO.Directory]::Delete($env:AGENTS_HOME)

    $wholeFileHome = Set-TestEnvironment (Join-Path $script:TestRoot 'whole-file-recovery')
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
    $wholeFileAgents = Join-Path $env:CODEX_HOME 'AGENTS.md'
    [System.IO.File]::WriteAllText($wholeFileAgents, $originalText, $script:Utf8NoBom)
    $env:CODEX_BASELINE_TEST_APPEND_AGENTS_AFTER_OBJECT = "`nconcurrent user text"
    $env:CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT = '1'
    $wholeFileOutput = Invoke-Baseline @('install') 1
    Remove-Item Env:\CODEX_BASELINE_TEST_APPEND_AGENTS_AFTER_OBJECT
    Remove-Item Env:\CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT
    Assert-True ($wholeFileOutput -match 'automatic recovery failed') 'whole-file drift must stop automatic recovery'
    Assert-True ([System.IO.File]::ReadAllText($wholeFileAgents, $script:Utf8NoBom) -match 'concurrent user text') 'recovery must not discard user text outside the managed block'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\pending')) 'failed closed recovery must retain its pending journal'

    $journalHome = Set-TestEnvironment (Join-Path $script:TestRoot 'journal-shape')
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
    $journalAgents = Join-Path $env:CODEX_HOME 'AGENTS.md'
    [System.IO.File]::WriteAllText($journalAgents, $originalText, $script:Utf8NoBom)
    Invoke-Baseline @('install') | Out-Null
    $journalBefore = [System.IO.File]::ReadAllBytes($journalAgents)
    $journalCurrentPath = Join-Path $env:CODEX_HOME 'codex-baseline\state\current'
    $journalId = [System.IO.File]::ReadAllText($journalCurrentPath, $script:Utf8NoBom).Trim()
    $tamperedJournalPath = Join-Path $env:CODEX_HOME ("codex-baseline\state\transactions\{0}\transaction.json" -f $journalId)
    $validJournalText = [System.IO.File]::ReadAllText($tamperedJournalPath, $script:Utf8NoBom)
    $tamperedJournal = $validJournalText | ConvertFrom-Json
    $tamperedJournal.State = 'committing'
    $tamperedJournal.Objects[0].Stage = Join-Path $journalHome 'escaped-stage'
    [System.IO.File]::WriteAllText($tamperedJournalPath, (($tamperedJournal | ConvertTo-Json -Depth 12) + "`n"), $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'codex-baseline\state\pending'), ($journalId + "`n"), $script:Utf8NoBom)
    $journalOutput = Invoke-Baseline @('update') 1
    Assert-True ($journalOutput -match 'stage path is not exactly derived') 'recovery must reject an escaped journal stage path'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($journalBefore, [System.IO.File]::ReadAllBytes($journalAgents))) 'malformed journal recovery must not mutate AGENTS'
    $typedJournal = $validJournalText | ConvertFrom-Json
    $typedJournal.State = 'committing'
    $typedJournal.Objects[0].PSObject.Properties.Remove('Change')
    $typedJournal.Objects[0] | Add-Member -MemberType NoteProperty -Name Change -Value 'true'
    [System.IO.File]::WriteAllText($tamperedJournalPath, (($typedJournal | ConvertTo-Json -Depth 12) + "`n"), $script:Utf8NoBom)
    $typedJournalOutput = Invoke-Baseline @('update') 1
    Assert-True ($typedJournalOutput -match 'must be a JSON boolean') 'recovery must reject stringly typed journal booleans'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($journalBefore, [System.IO.File]::ReadAllBytes($journalAgents))) 'typed journal rejection must not mutate AGENTS'

    $truncatedJournal = $validJournalText | ConvertFrom-Json
    $truncatedJournal.State = 'committing'
    $truncatedJournal.Objects = @($truncatedJournal.Objects | Where-Object { $_.Id -ne '31' })
    [System.IO.File]::WriteAllText($tamperedJournalPath, (($truncatedJournal | ConvertTo-Json -Depth 12) + "`n"), $script:Utf8NoBom)
    $truncatedJournalOutput = Invoke-Baseline @('update') 1
    Assert-True ($truncatedJournalOutput -match 'incomplete object inventory') 'recovery must reject a truncated pending object set before restoration'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($journalBefore, [System.IO.File]::ReadAllBytes($journalAgents))) 'truncated journal rejection must not mutate AGENTS'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\pending')) 'truncated journal rejection must retain pending state for manual repair'

    $preflightHome = Set-TestEnvironment (Join-Path $script:TestRoot 'journal-preflight')
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
    $preflightAgents = Join-Path $env:CODEX_HOME 'AGENTS.md'
    [System.IO.File]::WriteAllText($preflightAgents, $originalText, $script:Utf8NoBom)
    Invoke-Baseline @('install') | Out-Null
    $preflightBefore = [System.IO.File]::ReadAllBytes($preflightAgents)
    $preflightCurrentPath = Join-Path $env:CODEX_HOME 'codex-baseline\state\current'
    $preflightId = [System.IO.File]::ReadAllText($preflightCurrentPath, $script:Utf8NoBom).Trim()
    $preflightJournalPath = Join-Path $env:CODEX_HOME ("codex-baseline\state\transactions\{0}\transaction.json" -f $preflightId)
    $preflightJournal = [System.IO.File]::ReadAllText($preflightJournalPath, $script:Utf8NoBom) | ConvertFrom-Json
    $preflightJournal.State = 'committing'
    $blockObject = @($preflightJournal.Objects | Where-Object { $_.Id -eq '00' })[0]
    [System.IO.File]::Copy([string]$blockObject.PhysicalBackup, [string]$blockObject.Old, $false)
    $wrapperObject = @($preflightJournal.Objects | Where-Object { $_.Id -eq '31' })[0]
    $wrapperObject.DesiredPhysicalHash = ('0' * 64)
    [System.IO.File]::WriteAllText($preflightJournalPath, (($preflightJournal | ConvertTo-Json -Depth 12) + "`n"), $script:Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'codex-baseline\state\pending'), ($preflightId + "`n"), $script:Utf8NoBom)
    $preflightOutput = Invoke-Baseline @('update') 1
    Assert-True ($preflightOutput -match 'physical hash mismatch') ("recovery must reject a later object mismatch during global preflight; output: {0}" -f $preflightOutput)
    Assert-True ([System.Linq.Enumerable]::SequenceEqual($preflightBefore, [System.IO.File]::ReadAllBytes($preflightAgents))) 'global preflight must validate all objects before restoring the first object'
    Assert-True (Test-Path -LiteralPath ([string]$blockObject.Old) -PathType Leaf) 'global preflight must leave a verified restore source untouched on later failure'

    $validHome = Join-Path $script:TestRoot 'path-validation\home'
    [System.IO.Directory]::CreateDirectory($validHome) | Out-Null
    $env:CODEX_HOME = Join-Path $validHome 'codex'
    $env:AGENTS_HOME = Join-Path $validHome 'agents'
    $env:HOME = 'relative-home'
    Assert-True ((Invoke-Baseline @('install', '-DryRun') 1) -match 'fully-qualified before normalization') 'relative HOME must fail before normalization'
    $env:HOME = '\\?\C:\unsafe-device-home'
    Assert-True ((Invoke-Baseline @('install', '-DryRun') 1) -match 'device or UNC') 'device HOME must fail closed'
    $env:HOME = '\\localhost\unexpected-home'
    Assert-True ((Invoke-Baseline @('install', '-DryRun') 1) -match 'device or UNC') 'unexpected UNC HOME must fail closed'
    $env:HOME = $validHome
    $env:CODEX_HOME = Join-Path $validHome 'codex:ads'
    Assert-True ((Invoke-Baseline @('install', '-DryRun') 1) -match 'alternate data stream') 'ADS CODEX_HOME must fail closed'

    Write-Output ("PASS: Windows lifecycle ({0} assertions, PowerShell {1})" -f $script:Assertions, $PSVersionTable.PSVersion)
}
finally {
    if (Test-Path Env:\CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT) {
        Remove-Item Env:\CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT
    }
    if (Test-Path Env:\CODEX_BASELINE_TEST_APPEND_AGENTS_AFTER_OBJECT) {
        Remove-Item Env:\CODEX_BASELINE_TEST_APPEND_AGENTS_AFTER_OBJECT
    }
    if (Test-Path Env:\CODEX_BASELINE_TEST_MUTATE_SOURCE_AFTER_VERIFY) {
        Remove-Item Env:\CODEX_BASELINE_TEST_MUTATE_SOURCE_AFTER_VERIFY
    }
    if (Test-Path Env:\CODEX_BASELINE_TEST_WEAKEN_SNAPSHOT_ACL_AFTER_VERIFY) {
        Remove-Item Env:\CODEX_BASELINE_TEST_WEAKEN_SNAPSHOT_ACL_AFTER_VERIFY
    }
    if (Test-Path Env:\CODEX_BASELINE_TEST_MUTATE_SNAPSHOT_AFTER_VERIFY) {
        Remove-Item Env:\CODEX_BASELINE_TEST_MUTATE_SNAPSHOT_AFTER_VERIFY
    }
    if (Test-Path Env:\CODEX_BASELINE_TESTING) {
        Remove-Item Env:\CODEX_BASELINE_TESTING
    }
    Remove-TestRoot $script:TestRoot
}
