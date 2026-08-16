[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
$script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:BaselineScript = Join-Path $script:RepositoryRoot 'scripts\codex-baseline.ps1'
$script:PowerShell = Join-Path $PSHOME 'powershell.exe'
$powerShellCoreCommands = @(Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
$script:PowerShellCore = if ($powerShellCoreCommands.Count -eq 1) { $powerShellCoreCommands[0].Path } else { $null }
$script:PrivateTestBase = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($env:SystemRoot))
$script:TestRoot = Join-Path $script:PrivateTestBase ('cbw-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
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

function Invoke-PowerShellScriptCapture {
    param([string]$Path, [string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String).Trim()
        $actualExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    return [pscustomobject]@{ Output = $output; ExitCode = $actualExit }
}

function Invoke-EngineScriptCapture {
    param([string]$Engine, [string]$Path, [string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $Engine -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String).Trim()
        $actualExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    return [pscustomobject]@{ Output = $output; ExitCode = $actualExit }
}

function Invoke-EngineBaseline {
    param([string]$Engine, [string[]]$Arguments, [int]$ExpectedExit = 0)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $Engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepositoryRoot 'scripts\codex-baseline.ps1') @Arguments 2>&1 | Out-String).Trim()
        $actualExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($actualExit -ne $ExpectedExit) {
        throw "Expected exit $ExpectedExit, got $actualExit for optimizer '$($Arguments -join ' ')' under ${Engine}:`n$output"
    }
    return $output
}

function Test-LifecycleProvenanceDoesNotInvokeGit {
    param([string]$Engine, [string]$Label)
    $root = Join-Path $script:TestRoot ("lifecycle-provenance-{0}" -f $Label)
    $source = Join-Path $root 'source'
    [System.IO.Directory]::CreateDirectory($source) | Out-Null
    foreach ($sourceName in @('VERSION', 'baseline', 'benchmarks', 'scripts')) {
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $sourceName) -Destination $source -Recurse
    }
    [System.IO.Directory]::CreateDirectory((Join-Path $source '.git')) | Out-Null
    $shimDirectory = Join-Path $root 'shim'
    [System.IO.Directory]::CreateDirectory($shimDirectory) | Out-Null
    $sentinel = Join-Path $root 'git-executed.txt'
    $shim = Join-Path $shimDirectory 'git.cmd'
    [System.IO.File]::WriteAllText(
        $shim,
        "@echo off`r`n> `"%CB_TEST_GIT_SENTINEL%`" echo invoked`r`nexit /b 99`r`n",
        [System.Text.Encoding]::ASCII
    )
    $savedPath = $env:PATH
    Set-TestEnvironment (Join-Path $root 'home') | Out-Null
    $env:PATH = $shimDirectory + ';' + $savedPath
    $env:CB_TEST_GIT_SENTINEL = $sentinel
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION = '1'
    try {
        $result = Invoke-EngineScriptCapture $Engine (Join-Path $source 'scripts\codex-baseline.ps1') @('install', '-DryRun', '-AcknowledgeUnverifiedSource')
        Assert-True ($result.ExitCode -eq 0) ("{0}: lifecycle provenance dry-run must succeed without Git: {1}" -f $Label, $result.Output)
        Assert-True (-not (Test-Path -LiteralPath $sentinel)) ("{0}: lifecycle provenance must not invoke checkout Git" -f $Label)
        Assert-True ($result.Output -match '(?m)^source-revision: unversioned\s*$') ("{0}: lifecycle revision must remain explicitly unavailable" -f $Label)
        Assert-True ($result.Output -match '(?m)^source-dirty: unknown\s*$') ("{0}: lifecycle dirty state must remain explicitly unavailable" -f $Label)
    }
    finally {
        $env:PATH = $savedPath
        Remove-Item Env:\CB_TEST_GIT_SENTINEL -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
}

function Write-TestJsonFile {
    param([string]$Path, $Value, [int]$Depth = 12)
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth $Depth) + "`n"), $script:Utf8NoBom)
}

function Test-ConfigPendingJournalAdversaries {
    param([string]$Engine, [string]$Label)
    $cases = @(
        [pscustomobject]@{ Name = 'target-outside'; Expected = 'target mismatch'; Mutate = { param($journal, $sentinel) $journal.Target = $sentinel } },
        [pscustomobject]@{ Name = 'stage-outside'; Expected = 'stage mismatch'; Mutate = { param($journal, $sentinel) $journal.Stage = $sentinel } },
        [pscustomobject]@{ Name = 'old-outside'; Expected = 'old-path mismatch'; Mutate = { param($journal, $sentinel) $journal.Old = $sentinel } },
        [pscustomobject]@{ Name = 'extra-property'; Expected = 'contains unexpected property'; Mutate = { param($journal, $sentinel) $journal | Add-Member -MemberType NoteProperty -Name Unexpected -Value $sentinel } },
        [pscustomobject]@{ Name = 'missing-property'; Expected = 'is missing property'; Mutate = { param($journal, $sentinel) $journal.PSObject.Properties.Remove('DesiredStructureHash') } },
        [pscustomobject]@{ Name = 'unknown-ownership'; Expected = 'Invalid or duplicate config ownership key'; Mutate = { param($journal, $sentinel) $journal.Ownership[0].Id = 'unknown_key' } },
        [pscustomobject]@{ Name = 'ownership-path'; Expected = 'ownership metadata mismatch'; Mutate = { param($journal, $sentinel) $journal.Ownership[0].Path = $sentinel } },
        [pscustomobject]@{ Name = 'prior-token'; Expected = 'Invalid boolean token'; Mutate = { param($journal, $sentinel) $journal.Ownership[0].PriorState = 'present'; $journal.Ownership[0].PriorToken = 'truthy' } },
        [pscustomobject]@{ Name = 'installed-token'; Expected = 'Invalid boolean token'; Mutate = { param($journal, $sentinel) $journal.Ownership[0].InstalledToken = 'truthy' } },
        [pscustomobject]@{ Name = 'desired-identity'; Expected = 'live desired metadata is unverifiable'; Mutate = { param($journal, $sentinel) $journal.DesiredIdentity = '00000000:00000000:00000000:1' } },
        [pscustomobject]@{ Name = 'desired-security'; Expected = 'Invalid config desired security descriptor'; Mutate = { param($journal, $sentinel) $journal.DesiredSecurity = 'not-an-sddl' } }
    )
    foreach ($case in $cases) {
        $root = Join-Path $script:TestRoot ("config-journal-{0}-{1}" -f $Label, $case.Name)
        Set-TestEnvironment $root | Out-Null
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
        $env:CODEX_BASELINE_TESTING = '1'
        $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION = '1'
        try {
            Invoke-EngineBaseline $Engine @('optimize', '-Apply') | Out-Null
            $configPath = Join-Path $env:CODEX_HOME 'config.toml'
            $configBefore = Get-TestSha256 ([System.IO.File]::ReadAllBytes($configPath))
            $stateRoot = Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
            $currentId = [System.IO.File]::ReadAllText((Join-Path $stateRoot 'current'), $script:Utf8NoBom).Trim()
            $journalPath = Join-Path $stateRoot ("transactions\{0}\transaction.json" -f $currentId)
            $journal = [System.IO.File]::ReadAllText($journalPath, $script:Utf8NoBom) | ConvertFrom-Json
            $journal.State = 'committing'
            $sentinelPath = Join-Path $root 'outside-sentinel.txt'
            $sentinelText = "OUTSIDE-SENTINEL-$($case.Name)"
            [System.IO.File]::WriteAllText($sentinelPath, $sentinelText, $script:Utf8NoBom)
            & $case.Mutate $journal $sentinelPath
            Write-TestJsonFile $journalPath $journal
            $pendingPath = Join-Path $stateRoot 'pending'
            [System.IO.File]::WriteAllText($pendingPath, ($currentId + "`n"), $script:Utf8NoBom)

            $output = Invoke-EngineBaseline $Engine @('optimize', '-Apply') 1
            $normalizedOutput = ($output -replace '\s+', ' ').Trim()
            Assert-True ($normalizedOutput -match [regex]::Escape([string]$case.Expected)) ("{0}/{1}: malformed config journal must fail at the expected validator: {2}" -f $Label, $case.Name, $output)
            Assert-True ([System.IO.File]::ReadAllText($sentinelPath, $script:Utf8NoBom) -eq $sentinelText) ("{0}/{1}: journal rejection must not mutate an outside sentinel" -f $Label, $case.Name)
            Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($configPath))) -eq $configBefore) ("{0}/{1}: journal rejection must not mutate config.toml" -f $Label, $case.Name)
            Assert-True (Test-Path -LiteralPath $pendingPath -PathType Leaf) ("{0}/{1}: rejected pending state must be retained for manual repair" -f $Label, $case.Name)
        }
        finally {
            Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
            Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
        }
    }
}

function Test-AutoCapPreflightEngine {
    param([string]$Engine, [string]$Label)
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION = '1'
    try {
        $dryRoot = Join-Path $script:TestRoot ("install-cap-dry-{0}" -f $Label)
        Set-TestEnvironment $dryRoot | Out-Null
        $dry = Invoke-EngineBaseline $Engine @('install', '-DryRun', '-AcknowledgeUnverifiedSource')
        Assert-True ($dry -match 'install-cap plan: agents\.max_concurrent_threads_per_session: absent -> 6') ("{0}: install dry-run must print the exact automatic-cap plan" -f $Label)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) ("{0}: automatic-cap dry-run must not create baseline state" -f $Label)

        $rejectRoot = Join-Path $script:TestRoot ("install-cap-rejected-candidate-{0}" -f $Label)
        Set-TestEnvironment $rejectRoot | Out-Null
        $env:CODEX_BASELINE_TEST_REJECT_CONFIG_CANDIDATE = '1'
        try {
            $rejected = Invoke-EngineBaseline $Engine @('install', '-AcknowledgeUnverifiedSource') 1
        }
        finally { Remove-Item Env:\CODEX_BASELINE_TEST_REJECT_CONFIG_CANDIDATE -ErrorAction SilentlyContinue }
        Assert-True ($rejected -match 'Injected isolated candidate validation rejection') ("{0}: complete auto-cap validation must run before core mutation: {1}" -f $Label, $rejected)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml'))) ("{0}: rejected candidate preflight must not create config.toml" -f $Label)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\current'))) ("{0}: rejected candidate preflight must not commit core state" -f $Label)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\config\composite-pending'))) ("{0}: rejected candidate preflight must not create composite intent" -f $Label)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:AGENTS_HOME 'skills'))) ("{0}: rejected candidate preflight must not install managed objects" -f $Label)

        foreach($quoted in @(
            [pscustomobject]@{Name='disable';Text="[agents]`r`n`"enabled`" = false`r`n"},
            [pscustomobject]@{Name='cap';Text="[agents]`r`n`"max_concurrent_threads_per_session`" = 2`r`n"},
            [pscustomobject]@{Name='agents-table';Text="[`"agents`"]`r`nenabled = false`r`n"},
            [pscustomobject]@{Name='feature-veto';Text="[features]`r`n`"multi_agent`" = false`r`n"},
            [pscustomobject]@{Name='fast-mode';Text="[features]`r`n`"fast_mode`" = true`r`n"},
            [pscustomobject]@{Name='service-tier';Text="`"service_tier`" = `"fast`"`r`n"}
        )){
            $root=Join-Path $script:TestRoot ("install-cap-quoted-{0}-{1}"-f$Label,$quoted.Name)
            Set-TestEnvironment $root|Out-Null
            [System.IO.Directory]::CreateDirectory($env:CODEX_HOME)|Out-Null
            $config=Join-Path $env:CODEX_HOME 'config.toml'
            [System.IO.File]::WriteAllText($config,[string]$quoted.Text,$script:Utf8NoBom)
            $before=Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))
            $output=Invoke-EngineBaseline $Engine @('install','-AcknowledgeUnverifiedSource') 1
            Assert-True ($output-match'quoted.*managed TOML (paths|table)') ("{0}/{1}: quoted agent override must fail closed during preflight: {2}"-f$Label,$quoted.Name,$output)
            Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config)))-eq$before) ("{0}/{1}: rejected preflight must preserve config bytes"-f$Label,$quoted.Name)
            Assert-True (-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\current'))) ("{0}/{1}: rejected preflight must not commit core state"-f$Label,$quoted.Name)
            Assert-True (-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\config\composite-pending'))) ("{0}/{1}: rejected preflight must not create composite intent"-f$Label,$quoted.Name)
            Assert-True (-not(Test-Path -LiteralPath (Join-Path $env:AGENTS_HOME 'skills'))) ("{0}/{1}: rejected preflight must not install managed objects"-f$Label,$quoted.Name)
        }

        $vetoRoot=Join-Path $script:TestRoot ("install-cap-feature-veto-{0}"-f$Label)
        Set-TestEnvironment $vetoRoot|Out-Null
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME)|Out-Null
        $vetoConfig=Join-Path $env:CODEX_HOME 'config.toml'
        $vetoText="[features]`r`nmulti_agent = false`r`n"
        [System.IO.File]::WriteAllText($vetoConfig,$vetoText,$script:Utf8NoBom)
        $vetoHash=Get-TestSha256 ([System.IO.File]::ReadAllBytes($vetoConfig))
        $vetoDry=Invoke-EngineBaseline $Engine @('install','-DryRun','-AcknowledgeUnverifiedSource')
        Assert-True ($vetoDry-match'install-cap plan: no change \(features\.multi_agent=false user override\)') ("{0}: feature veto dry-run must print the exact no-change plan: {1}"-f$Label,$vetoDry)
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) ("{0}: feature-veto dry-run must not create baseline state"-f$Label)
        $install=Invoke-EngineBaseline $Engine @('install','-AcknowledgeUnverifiedSource')
        Assert-True ($install-match'installed codex-baseline 0\.3\.0') ("{0}: features.multi_agent=false must remain a valid fresh-install veto"-f$Label)
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($vetoConfig)))-eq$vetoHash) ("{0}: feature veto must preserve exact user config bytes"-f$Label)
        Assert-True (-not([System.IO.File]::ReadAllText($vetoConfig,$script:Utf8NoBom)-match'max_concurrent_threads_per_session')) ("{0}: feature veto must suppress the fresh-install cap"-f$Label)
        Assert-True ($null-eq(Get-TestConfigCurrentJournal)) ("{0}: features.multi_agent is inspected but never baseline-owned"-f$Label)
    }
    finally{
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
}

function Test-ReleaseGuidanceSelectionEngine {
    param([string]$Engine,[string]$Label)
    $env:CODEX_BASELINE_TESTING='1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION='1'
    try{
        $rcRoot=Join-Path $script:TestRoot ("guidance-rc-{0}"-f$Label)
        Set-TestEnvironment $rcRoot|Out-Null
        $rc=Invoke-EngineBaseline $Engine @('install','-AcknowledgeUnverifiedSource')
        $rcGuidance=[IO.File]::ReadAllText((Join-Path $env:CODEX_HOME 'AGENTS.md'),$script:Utf8NoBom)
        Assert-True ($rc-match'installed codex-baseline 0\.3\.0'-and$rcGuidance-match'Release-candidate execution is SOLO'-and$rcGuidance-notmatch'Stable execution autonomously chooses SOLO, TEAM, or SWARM') ("{0}: rc.N must deterministically install only model-visible SOLO guidance"-f$Label)

        $stableSource=Join-Path $script:TestRoot ("guidance-stable-source-{0}"-f$Label)
        [IO.Directory]::CreateDirectory($stableSource)|Out-Null
        foreach($sourceName in @('VERSION','baseline','benchmarks','scripts')){Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $sourceName) -Destination $stableSource -Recurse}
        $releasePath=Join-Path $stableSource 'baseline\release-status.json'
        $release=[IO.File]::ReadAllText($releasePath,$script:Utf8NoBom)|ConvertFrom-Json
        $release.status='stable'
        [IO.File]::WriteAllText($releasePath,(($release|ConvertTo-Json -Depth 4)+"`n"),$script:Utf8NoBom)
        Update-TestSourceManifest $stableSource
        Set-TestEnvironment (Join-Path $script:TestRoot ("guidance-stable-{0}"-f$Label))|Out-Null
        $capture=Invoke-EngineScriptCapture $Engine (Join-Path $stableSource 'scripts\codex-baseline.ps1') @('install','-AcknowledgeUnverifiedSource')
        Assert-True ($capture.ExitCode-eq0) ("{0}: stable guidance fixture must install: {1}"-f$Label,$capture.Output)
        $stableGuidance=[IO.File]::ReadAllText((Join-Path $env:CODEX_HOME 'AGENTS.md'),$script:Utf8NoBom)
        Assert-True ($stableGuidance-match'Stable execution autonomously chooses SOLO, TEAM, or SWARM'-and$stableGuidance-notmatch'Release-candidate execution is SOLO') ("{0}: stable status must deterministically install autonomous SOLO/TEAM/SWARM guidance"-f$Label)
    }
    finally{
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
}

function Test-ConfigIntegerGrammarEngine {
    param([string]$Engine,[string]$Label)
    $env:CODEX_BASELINE_TESTING='1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION='1'
    try{
        foreach($key in @('max_concurrent_threads_per_session','max_threads')){
            foreach($token in @('1000000','01')){
                $root=Join-Path $script:TestRoot ("config-integer-{0}-{1}-{2}"-f$Label,$key,$token)
                Set-TestEnvironment $root|Out-Null
                [IO.Directory]::CreateDirectory($env:CODEX_HOME)|Out-Null
                $config=Join-Path $env:CODEX_HOME 'config.toml'
                [IO.File]::WriteAllText($config,("[agents]`r`n{0} = {1}`r`n"-f$key,$token),$script:Utf8NoBom)
                $before=Get-TestSha256 ([IO.File]::ReadAllBytes($config))
                $rejected=Invoke-EngineBaseline $Engine @('optimize','-Apply') 1
                Assert-True ($rejected-match'unsupported scalar type') ("{0}/{1}={2}: unsafe integer must be rejected by the scanner"-f$Label,$key,$token)
                Assert-True ((Get-TestSha256 ([IO.File]::ReadAllBytes($config)))-eq$before-and-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) ("{0}/{1}={2}: rejected apply must preserve exact bytes and create no state"-f$Label,$key,$token)
                $restore=Invoke-EngineBaseline $Engine @('optimize','-Restore','-Apply') 1
                Assert-True ($restore-match'unsupported scalar type'-and(Get-TestSha256 ([IO.File]::ReadAllBytes($config)))-eq$before-and-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) ("{0}/{1}={2}: rejected restore must remain byte/state non-mutating"-f$Label,$key,$token)
            }
        }
    }
    finally{
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
}

function Test-ConfigStageConfidentialityEngine {
    param([string]$Engine,[string]$Label)
    $root=Join-Path $script:TestRoot ("config-stage-confidentiality-{0}"-f$Label)
    Set-TestEnvironment $root|Out-Null
    [IO.Directory]::CreateDirectory($env:CODEX_HOME)|Out-Null
    $users=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $directory=New-Object IO.DirectoryInfo($env:CODEX_HOME)
    $directoryAcl=$directory.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    $directoryAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,[Security.AccessControl.FileSystemRights]::ReadAndExecute,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))|Out-Null
    $directory.SetAccessControl($directoryAcl)
    $config=Join-Path $env:CODEX_HOME 'config.toml'
    [IO.File]::WriteAllText($config,"foreign_secret = `"CONFIDENTIAL-STAGE-CANARY`"`r`n",$script:Utf8NoBom)
    $file=New-Object IO.FileInfo($config)
    $fileAcl=$file.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    $fileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow)))|Out-Null
    $file.SetAccessControl($fileAcl)
    $securityBefore=Get-TestConfigSecurity $config
    $marker=Join-Path $root 'confidentiality.marker'
    $env:CODEX_BASELINE_TESTING='1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION='1'
    $env:CODEX_BASELINE_TEST_CONFIG_STAGE_CONFIDENTIALITY_MARKER=$marker
    try{Invoke-EngineBaseline $Engine @('optimize','-Apply')|Out-Null}
    finally{
        Remove-Item Env:\CODEX_BASELINE_TEST_CONFIG_STAGE_CONFIDENTIALITY_MARKER -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
    Assert-True ((Test-Path -LiteralPath $marker -PathType Leaf)-and[IO.File]::ReadAllText($marker,$script:Utf8NoBom)-eq"protected-empty-before-write;exclusive-through-flush`n") ("{0}: restrictive protected stage and exclusive write/flush proof must execute"-f$Label)
    $securityAfter=Get-TestConfigSecurity $config
    Assert-True ($securityAfter.Sddl-eq$securityBefore.Sddl-and$securityAfter.Protected-eq$securityBefore.Protected) ("{0}: exact target Owner/DACL must be applied and verified after confidential staging"-f$Label)
}

function Get-TestConfigSecurity {
    param([string]$Path)
    $sections=[System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
    $security=(New-Object System.IO.FileInfo($Path)).GetAccessControl($sections)
    return [pscustomobject]@{Sddl=$security.GetSecurityDescriptorSddlForm($sections);Protected=[bool]$security.AreAccessRulesProtected}
}

function Set-TestConfigProtection {
    param([string]$Path,[bool]$Protected)
    $file=New-Object System.IO.FileInfo($Path)
    $sections=[System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
    $security=$file.GetAccessControl($sections)
    $sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule=New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid,[System.Security.AccessControl.FileSystemRights]::ReadAttributes,
        [System.Security.AccessControl.InheritanceFlags]::None,[System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $security.AddAccessRule($rule)|Out-Null
    $security.SetAccessRuleProtection($Protected,$true)
    $file.SetAccessControl($security)
}

function Get-TestDifferentConfigSddl {
    param([string]$Sddl)
    $sections=[System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
    $security=New-Object System.Security.AccessControl.FileSecurity
    $security.SetSecurityDescriptorSddlForm($Sddl,$sections)
    $security.SetAccessRuleProtection((-not [bool]$security.AreAccessRulesProtected),$true)
    $changed=$security.GetSecurityDescriptorSddlForm($sections)
    if($changed-eq$Sddl){throw 'Test fixture failed to produce a distinct valid Owner/DACL descriptor.'}
    return $changed
}

function Test-ConfigDaclRecoveryEngine {
    param([string]$Engine,[string]$Label)
    foreach($protected in @($false,$true)){
        $case=if($protected){'protected'}else{'unprotected'}
        $root=Join-Path $script:TestRoot ("config-dacl-{0}-{1}"-f$Label,$case)
        Set-TestEnvironment $root|Out-Null
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME)|Out-Null
        $config=Join-Path $env:CODEX_HOME 'config.toml'
        $original="foreign = `"preserved`"`r`n"
        [System.IO.File]::WriteAllText($config,$original,$script:Utf8NoBom)
        Set-TestConfigProtection $config $protected
        $securityBefore=Get-TestConfigSecurity $config
        $bytesBefore=Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))
        Assert-True ($securityBefore.Protected-eq$protected) ("{0}/{1}: test fixture must establish requested DACL protection"-f$Label,$case)
        $env:CODEX_BASELINE_TESTING='1'
        $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION='1'
        $env:CODEX_BASELINE_TEST_FAULT_AFTER_CONFIG_REPLACE='1'
        try{
            $apply=Invoke-EngineBaseline $Engine @('optimize','-Apply') 1
            Assert-True ($apply-match'Injected test fault after config replace') ("{0}/{1}: optimizer must exercise post-replace recovery: {2}"-f$Label,$case,$apply)
            $securityAfter=Get-TestConfigSecurity $config
            Assert-True ($securityAfter.Sddl-eq$securityBefore.Sddl-and$securityAfter.Protected-eq$protected) ("{0}/{1}: recovery must preserve exact Owner/DACL and protection after apply"-f$Label,$case)
            $journal=Get-TestConfigCurrentJournal
            Assert-True (-not[string]::IsNullOrWhiteSpace([string]$journal.DesiredIdentity)-and[string]$journal.DesiredSecurity-eq$securityBefore.Sddl) ("{0}/{1}: committed recovery journal must bind desired identity and SDDL"-f$Label,$case)
            $restore=Invoke-EngineBaseline $Engine @('optimize','-Restore','-Apply') 1
            Assert-True ($restore-match'Injected test fault after config replace') ("{0}/{1}: restore must exercise post-replace recovery: {2}"-f$Label,$case,$restore)
            $securityRestored=Get-TestConfigSecurity $config
            Assert-True ($securityRestored.Sddl-eq$securityBefore.Sddl-and$securityRestored.Protected-eq$protected) ("{0}/{1}: restore recovery must retain exact Owner/DACL and protection"-f$Label,$case)
            Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config)))-eq$bytesBefore) ("{0}/{1}: restore recovery must restore exact config bytes"-f$Label,$case)
            Assert-True (-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\config\pending'))) ("{0}/{1}: successful automatic recovery must clear its pending pointer"-f$Label,$case)
        }
        finally{
            Remove-Item Env:\CODEX_BASELINE_TEST_FAULT_AFTER_CONFIG_REPLACE -ErrorAction SilentlyContinue
            Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
            Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
        }
    }
}

function Test-ConfigPreSecurityCrashRecoveryEngine {
    param([string]$Engine,[string]$Label)
    $root=Join-Path $script:TestRoot ("config-pre-security-crash-{0}"-f$Label)
    Set-TestEnvironment $root|Out-Null
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME)|Out-Null
    $config=Join-Path $env:CODEX_HOME 'config.toml'
    [System.IO.File]::WriteAllText($config,"foreign = `"preserved`"`r`n",$script:Utf8NoBom)
    $securityBefore=Get-TestConfigSecurity $config
    $env:CODEX_BASELINE_TESTING='1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION='1'
    $env:CODEX_BASELINE_TEST_HALT_AFTER_CONFIG_REPLACE_BEFORE_SECURITY='1'
    try{
        Invoke-EngineBaseline $Engine @('optimize','-Apply') 97|Out-Null
    }
    finally{Remove-Item Env:\CODEX_BASELINE_TEST_HALT_AFTER_CONFIG_REPLACE_BEFORE_SECURITY -ErrorAction SilentlyContinue}
    try{
        $stateRoot=Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
        $pendingPath=Join-Path $stateRoot 'pending'
        Assert-True (Test-Path -LiteralPath $pendingPath -PathType Leaf) ("{0}: crash before security repair must retain the config pending pointer"-f$Label)
        $pendingId=[System.IO.File]::ReadAllText($pendingPath,$script:Utf8NoBom).Trim()
        $journalPath=Join-Path $stateRoot ("transactions\{0}\transaction.json"-f$pendingId)
        $journal=[System.IO.File]::ReadAllText($journalPath,$script:Utf8NoBom)|ConvertFrom-Json
        Assert-True ([string]$journal.State-eq'replaced-before-security') ("{0}: the replace-before-DACL window must be explicitly journalled"-f$Label)
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config)))-eq[string]$journal.DesiredPhysicalHash) ("{0}: crash fixture must contain the journal-bound desired bytes"-f$Label)

        Set-TestConfigProtection $config (-not[bool]$securityBefore.Protected)
        $securityDuringWindow=Get-TestConfigSecurity $config
        Assert-True ($securityDuringWindow.Sddl-ne$securityBefore.Sddl) ("{0}: crash fixture must simulate replacement metadata requiring repair"-f$Label)
        Invoke-EngineBaseline $Engine @('optimize','-Apply')|Out-Null
        $securityAfter=Get-TestConfigSecurity $config
        Assert-True ($securityAfter.Sddl-eq$securityBefore.Sddl-and$securityAfter.Protected-eq$securityBefore.Protected) ("{0}: recovery must repair and verify the exact Owner/DACL before commit"-f$Label)
        Assert-True (-not(Test-Path -LiteralPath $pendingPath)) ("{0}: successful pre-security recovery must clear its pending pointer"-f$Label)
        $current=Get-TestConfigCurrentJournal
        Assert-True ([string]$current.State-eq'committed') ("{0}: repaired config transaction must finish committed"-f$Label)
    }
    finally{
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
}

function Test-ConfigRecoveryMetadataTamperEngine {
    param([string]$Engine,[string]$Label)
    $cases=@(
        [pscustomobject]@{Name='previous-identity';Expected='recovery preimage metadata is unverifiable';Mutate={param($journal)$journal.PreviousIdentity='00000000:00000000:00000000:1'}},
        [pscustomobject]@{Name='previous-sddl';Expected='recovery preimage metadata is unverifiable';Mutate={param($journal)$journal.PreviousSecurity=Get-TestDifferentConfigSddl ([string]$journal.PreviousSecurity)}},
        [pscustomobject]@{Name='desired-identity';Expected='recovery live desired metadata is unverifiable';Mutate={param($journal)$journal.DesiredIdentity='00000000:00000000:00000000:1'}},
        [pscustomobject]@{Name='desired-sddl';Expected='recovery live desired metadata is unverifiable';Mutate={param($journal)$journal.DesiredSecurity=Get-TestDifferentConfigSddl ([string]$journal.DesiredSecurity)}}
    )
    foreach($case in $cases){
        $root=Join-Path $script:TestRoot ("config-recovery-metadata-{0}-{1}"-f$Label,$case.Name)
        Set-TestEnvironment $root|Out-Null
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME)|Out-Null
        $config=Join-Path $env:CODEX_HOME 'config.toml'
        [System.IO.File]::WriteAllText($config,"foreign = `"preserved`"`r`n",$script:Utf8NoBom)
        $env:CODEX_BASELINE_TESTING='1'
        $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION='1'
        $env:CODEX_BASELINE_TEST_HALT_AFTER_CONFIG_REPLACE='1'
        try{
            Invoke-EngineBaseline $Engine @('optimize','-Apply') 97|Out-Null
        }
        finally{Remove-Item Env:\CODEX_BASELINE_TEST_HALT_AFTER_CONFIG_REPLACE -ErrorAction SilentlyContinue}
        try{
            $stateRoot=Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
            $pendingPath=Join-Path $stateRoot 'pending'
            Assert-True (Test-Path -LiteralPath $pendingPath -PathType Leaf) ("{0}/{1}: abrupt halt must retain a config recovery pointer"-f$Label,$case.Name)
            $id=[System.IO.File]::ReadAllText($pendingPath,$script:Utf8NoBom).Trim()
            $journalPath=Join-Path $stateRoot ("transactions\{0}\transaction.json"-f$id)
            $journal=[System.IO.File]::ReadAllText($journalPath,$script:Utf8NoBom)|ConvertFrom-Json
            Assert-True ([bool]$journal.PreviousExisted-and[string]$journal.State-eq'replaced-before-security') ("{0}/{1}: recovery fixture must retain the journal-bound preimage"-f$Label,$case.Name)
            Assert-True (-not[string]::IsNullOrWhiteSpace([string]$journal.PreviousIdentity)-and-not[string]::IsNullOrWhiteSpace([string]$journal.PreviousSecurity)-and-not[string]::IsNullOrWhiteSpace([string]$journal.DesiredIdentity)-and-not[string]::IsNullOrWhiteSpace([string]$journal.DesiredSecurity)) ("{0}/{1}: recovery journal must bind both identities and Owner/DACL descriptors"-f$Label,$case.Name)
            & $case.Mutate $journal
            Write-TestJsonFile $journalPath $journal
            $liveHash=Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))
            $liveSecurity=(Get-TestConfigSecurity $config).Sddl
            $recovery=Invoke-EngineBaseline $Engine @('optimize','-Apply') 1
            Assert-True (($recovery-replace'\s+',' ')-match[regex]::Escape([string]$case.Expected)) ("{0}/{1}: recovery must reject journal metadata tampering at the expected check: {2}"-f$Label,$case.Name,$recovery)
            Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config)))-eq$liveHash-and(Get-TestConfigSecurity $config).Sddl-eq$liveSecurity) ("{0}/{1}: rejected recovery must preserve live bytes and Owner/DACL"-f$Label,$case.Name)
            Assert-True (Test-Path -LiteralPath $pendingPath -PathType Leaf) ("{0}/{1}: rejected recovery must retain pending state for manual repair"-f$Label,$case.Name)
        }
        finally{
            Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
            Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
        }
    }
}

function Test-ConfigPrefixAndStandardValues {
    param([string]$Engine, [string]$Label)
    $root = Join-Path $script:TestRoot ("optimizer-neighbors-{0}" -f $Label)
    Set-TestEnvironment $root | Out-Null
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
    $configPath = Join-Path $env:CODEX_HOME 'config.toml'
    $original = @'
service_tiers = "fast"
service_tier = "flex"

[agents]
enabled_shadow = false
max_concurrent_threads_per_session_shadow = 9

[features]
fast_mode_shadow = true
fast_mode = false
'@
    [System.IO.File]::WriteAllText($configPath, $original, $script:Utf8NoBom)
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION = '1'
    try {
        $result = Invoke-EngineBaseline $Engine @('optimize', '-Apply', '-Speed', 'standard', '-Json') | ConvertFrom-Json
        $after = [System.IO.File]::ReadAllText($configPath, $script:Utf8NoBom)
        Assert-True ($result.status -eq 'applied' -and $result.speed -eq 'standard') ("{0}: standard optimizer must accept non-Fast unowned values" -f $Label)
        foreach ($line in @('service_tiers = "fast"', 'service_tier = "flex"', 'enabled_shadow = false', 'max_concurrent_threads_per_session_shadow = 9', 'fast_mode_shadow = true', 'fast_mode = false')) {
            Assert-True ($after.IndexOf($line, [System.StringComparison]::Ordinal) -ge 0) ("{0}: optimizer must preserve exact prefix-neighbor line: {1}" -f $Label, $line)
        }
        Assert-True ($after -match '(?m)^enabled = true$' -and $after -match '(?m)^max_concurrent_threads_per_session = 6$') ("{0}: optimizer must still add the exact managed agent keys" -f $Label)
    }
    finally {
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
}

function New-TestCompositePending {
    param(
        [string]$Operation,
        [AllowNull()][string]$SourceCore,
        [AllowNull()][string]$DesiredCore
    )
    $id = "{0}-{1}" -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N')
    $stateRoot = Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
    $directory = Join-Path $stateRoot ("composite\{0}" -f $id)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $journal = [ordered]@{
        Schema = 2
        Contract = 'codex-baseline-composite-transaction/v2'
        Id = $id
        Operation = $Operation
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        SourceCore = $SourceCore
        DesiredCore = $DesiredCore
        State = 'planned'
    }
    Write-TestJsonFile (Join-Path $directory 'transaction.json') $journal 4
    [System.IO.File]::WriteAllText((Join-Path $stateRoot 'composite-pending'), ($id + "`n"), $script:Utf8NoBom)
    return [pscustomobject]@{ Id = $id; Directory = $directory; Pending = (Join-Path $stateRoot 'composite-pending') }
}

function Get-TestCoreCurrentId {
    $path = Join-Path $env:CODEX_HOME 'codex-baseline\state\current'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return [System.IO.File]::ReadAllText($path, $script:Utf8NoBom).Trim()
}

function Get-TestConfigCurrentJournal {
    $stateRoot = Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
    $currentPath = Join-Path $stateRoot 'current'
    if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { return $null }
    $id = [System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim()
    return [System.IO.File]::ReadAllText((Join-Path $stateRoot ("transactions\{0}\transaction.json" -f $id)), $script:Utf8NoBom) | ConvertFrom-Json
}

function Assert-TestNoPendingCompositeState {
    param([string]$Label)
    $stateRoot = Join-Path $env:CODEX_HOME 'codex-baseline\state'
    foreach ($path in @(
        (Join-Path $stateRoot 'pending'),
        (Join-Path $stateRoot 'config\pending'),
        (Join-Path $stateRoot 'config\composite-pending')
    )) {
        Assert-True (-not (Test-Path -LiteralPath $path)) ("{0}: coherent recovery must clear pending pointer {1}" -f $Label, $path)
    }
}

function Test-CompositeRecoveryPhases {
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION = '1'
    try {
        # Simulate a durable install intent after the core committed but before
        # the automatic cap transaction ran.
        $installRoot = Join-Path $script:TestRoot 'composite-install-after-core'
        Set-TestEnvironment $installRoot | Out-Null
        Invoke-Baseline @('install') | Out-Null
        $installCore = Get-TestCoreCurrentId
        Invoke-Baseline @('optimize', '-Restore', '-Apply') | Out-Null
        $installConfig = Join-Path $env:CODEX_HOME 'config.toml'
        Assert-True (-not (Test-Path -LiteralPath $installConfig)) 'install split fixture must begin with committed core and absent auto-cap config'
        $installComposite = New-TestCompositePending 'install' $null $installCore
        Invoke-Baseline @('update') | Out-Null
        $installConfigJournal = Get-TestConfigCurrentJournal
        Assert-True ((Get-TestCoreCurrentId) -eq $installCore) 'install composite recovery must preserve the committed desired core'
        Assert-True ([System.IO.File]::ReadAllText($installConfig, $script:Utf8NoBom) -match '(?m)^max_concurrent_threads_per_session = 6$') 'install composite recovery must finish the missing automatic cap'
        Assert-True ([string]$installConfigJournal.CoreTransaction -eq $installCore) 'install composite recovery must bind optimizer ownership to the committed core transaction'
        Assert-True (([System.IO.File]::ReadAllText((Join-Path $installComposite.Directory 'transaction.json'), $script:Utf8NoBom) | ConvertFrom-Json).State -eq 'committed') 'install composite recovery must durably commit its intent'
        Assert-TestNoPendingCompositeState 'install-after-core'

        # Hide only config state, complete the core rollback, then restore the
        # pre-crash config journal and pending composite intent.
        $rollbackRoot = Join-Path $script:TestRoot 'composite-rollback-after-core'
        Set-TestEnvironment $rollbackRoot | Out-Null
        Invoke-Baseline @('install') | Out-Null
        $rollbackSource = Get-TestCoreCurrentId
        $rollbackConfigState = Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
        $rollbackSavedState = Join-Path $rollbackRoot 'saved-config-state'
        Move-Item -LiteralPath $rollbackConfigState -Destination $rollbackSavedState
        Invoke-Baseline @('rollback') | Out-Null
        if (Test-Path -LiteralPath $rollbackConfigState) { Remove-Item -LiteralPath $rollbackConfigState -Recurse -Force }
        Move-Item -LiteralPath $rollbackSavedState -Destination $rollbackConfigState
        Assert-True ($null -eq (Get-TestCoreCurrentId)) 'rollback split fixture must have reached the desired absent core state'
        $rollbackComposite = New-TestCompositePending 'rollback' $rollbackSource $null
        Invoke-Baseline @('rollback') | Out-Null
        Assert-True ($null -eq (Get-TestCoreCurrentId)) 'rollback composite recovery must keep the desired absent core state'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml'))) 'rollback composite recovery must remove the baseline-owned automatic cap'
        Assert-True (([System.IO.File]::ReadAllText((Join-Path $rollbackComposite.Directory 'transaction.json'), $script:Utf8NoBom) | ConvertFrom-Json).State -eq 'committed') 'rollback composite recovery must durably commit its intent'
        Assert-TestNoPendingCompositeState 'rollback-after-core'

        # Uninstall commits a terminal core transaction on Windows. Restore a
        # pre-uninstall config journal and verify recovery converges to it.
        $uninstallRoot = Join-Path $script:TestRoot 'composite-uninstall-after-core'
        Set-TestEnvironment $uninstallRoot | Out-Null
        Invoke-Baseline @('install') | Out-Null
        $uninstallSource = Get-TestCoreCurrentId
        $uninstallConfigState = Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
        $uninstallSavedState = Join-Path $uninstallRoot 'saved-config-state'
        Move-Item -LiteralPath $uninstallConfigState -Destination $uninstallSavedState
        Invoke-Baseline @('uninstall') | Out-Null
        $uninstallDesired = Get-TestCoreCurrentId
        Assert-True (-not [string]::IsNullOrWhiteSpace($uninstallDesired)) 'uninstall split fixture must retain its terminal core transaction'
        if (Test-Path -LiteralPath $uninstallConfigState) { Remove-Item -LiteralPath $uninstallConfigState -Recurse -Force }
        Move-Item -LiteralPath $uninstallSavedState -Destination $uninstallConfigState
        $uninstallComposite = New-TestCompositePending 'uninstall' $uninstallSource $uninstallDesired
        Invoke-Baseline @('uninstall') | Out-Null
        Assert-True ((Get-TestCoreCurrentId) -eq $uninstallDesired) 'uninstall composite recovery must preserve its terminal desired core state'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml'))) 'uninstall composite recovery must remove the baseline-owned automatic cap'
        Assert-True (([System.IO.File]::ReadAllText((Join-Path $uninstallComposite.Directory 'transaction.json'), $script:Utf8NoBom) | ConvertFrom-Json).State -eq 'committed') 'uninstall composite recovery must durably commit its intent'
        Assert-TestNoPendingCompositeState 'uninstall-after-core'
    }
    finally {
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
}

function Test-OptimizerEngine {
    param([string]$Engine, [string]$Label)
    $root = Join-Path $script:TestRoot ("optimizer-{0}" -f $Label)
    $optimizerHome = Set-TestEnvironment $root
    [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
    $config = Join-Path $env:CODEX_HOME 'config.toml'
    [byte[]]$original = [byte[]](0xEF,0xBB,0xBF) + $script:Utf8NoBom.GetBytes("# OPTIMIZER-SECRET sentinel`r`n[foreign]`r`nunicode = `"Grüezi`"")
    [System.IO.File]::WriteAllBytes($config, $original)
    $beforeHash = Get-TestSha256 $original
    $securityBefore = (New-Object System.IO.FileInfo($config)).GetAccessControl(
        [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
    ).GetSecurityDescriptorSddlForm(
        [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
    )
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION = '1'
    try {
        $check = Invoke-EngineBaseline $Engine @('optimize', '-Json') | ConvertFrom-Json
        Assert-True ($check.contract -eq 'codex-baseline-optimize/v1' -and $check.mode -eq 'check' -and -not $check.apply -and @($check.managed_keys).Count -eq 0) ("{0}: check must be read-only and schema-valid" -f $Label)
        Assert-True ($check.capabilities.agents-eq'unverified'-and$check.capabilities.fast-eq'unverified'-and$check.capabilities.ultrafast-eq'unavailable') ("{0}: bypassed or absent native validation must never be reported as capability availability"-f$Label)
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))) -eq $beforeHash) ("{0}: check must preserve exact config bytes" -f $Label)

        $plan = Invoke-EngineBaseline $Engine @('optimize', '-Speed', 'fast', '-Json') | ConvertFrom-Json
        Assert-True ($plan.status -eq 'planned' -and -not $plan.apply -and $plan.bytes_changed -eq 0) ("{0}: optimize without Apply must only plan" -f $Label)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline'))) ("{0}: a plan must not create state or target files" -f $Label)
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))) -eq $beforeHash) ("{0}: a plan must preserve exact config bytes" -f $Label)

        $fast = Invoke-EngineBaseline $Engine @('optimize', '-Apply', '-Speed', 'fast', '-Json') | ConvertFrom-Json
        Assert-True ($fast.status -eq 'applied' -and $fast.apply -and $fast.speed -eq 'fast' -and @($fast.managed_keys).Count -eq 4) ("{0}: fast apply must own the four allowlisted keys" -f $Label)
        Assert-True ($fast.capabilities.agents-eq'unverified'-and$fast.capabilities.fast-eq'unverified') ("{0}: test-bypassed strict-config validation must remain explicitly unverified"-f$Label)
        $bytes = [System.IO.File]::ReadAllBytes($config)
        Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) ("{0}: BOM must be preserved" -f $Label)
        $text = $script:Utf8NoBom.GetString($bytes, 3, $bytes.Length - 3)
        Assert-True ($text -match '# OPTIMIZER-SECRET sentinel' -and $text -match 'unicode = "Grüezi"') ("{0}: comments and Unicode must be preserved" -f $Label)
        Assert-True (-not $text.EndsWith("`n", [StringComparison]::Ordinal) -and -not ($text.Replace("`r`n", '') -match "`n")) ("{0}: CRLF and no-final-newline must be preserved" -f $Label)
        $securityAfter = (New-Object System.IO.FileInfo($config)).GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
        ).GetSecurityDescriptorSddlForm(
            [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
        )
        Assert-True ($securityAfter -eq $securityBefore) ("{0}: atomic replacement must preserve Owner and DACL/protection" -f $Label)
        $journalRoot = Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
        $journalText = (@(Get-ChildItem -LiteralPath $journalRoot -Recurse -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, $script:Utf8NoBom) }) -join "`n")
        Assert-True ($journalText -notmatch 'OPTIMIZER-SECRET|Grüezi') ("{0}: config journals must not contain foreign config or secrets" -f $Label)

        [System.IO.File]::AppendAllText($config, "`r`nuser_independent = true", $script:Utf8NoBom)
        $restore = Invoke-EngineBaseline $Engine @('optimize', '-Restore', '-Apply', '-Json') | ConvertFrom-Json
        Assert-True ($restore.status -eq 'restored' -and @($restore.managed_keys).Count -eq 0) ("{0}: restore must release all managed keys" -f $Label)
        $restoredText = [System.IO.File]::ReadAllText($config, $script:Utf8NoBom)
        Assert-True ($restoredText -match 'user_independent = true' -and $restoredText -notmatch 'max_concurrent_threads_per_session|fast_mode|service_tier') ("{0}: restore must preserve independent edits and remove only owned keys" -f $Label)

        Invoke-EngineBaseline $Engine @('optimize', '-Apply') | Out-Null
        $driftText = [System.IO.File]::ReadAllText($config, $script:Utf8NoBom).Replace('max_concurrent_threads_per_session = 6', 'max_concurrent_threads_per_session = 5')
        [System.IO.File]::WriteAllText($config, $driftText, $script:Utf8NoBom)
        $drift = Invoke-EngineBaseline $Engine @('optimize', '-Json') 4 | ConvertFrom-Json
        Assert-True ($drift.status -eq 'conflict' -and $drift.drift) ("{0}: managed-key drift must fail closed" -f $Label)
        $driftHash = Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))
        $ultrafast = Invoke-EngineBaseline $Engine @('optimize', '-Apply', '-Speed', 'ultrafast', '-Json') 3 | ConvertFrom-Json
        Assert-True ($ultrafast.status -eq 'unavailable' -and -not $ultrafast.apply -and $ultrafast.bytes_changed -eq 0) ("{0}: Ultrafast must be unavailable and non-mutating" -f $Label)
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))) -eq $driftHash) ("{0}: unavailable Ultrafast must preserve config bytes" -f $Label)

        Set-Content -LiteralPath $config -Stream sentinel -Value 'alternate stream' -Encoding Ascii
        $ads = Invoke-EngineBaseline $Engine @('optimize', '-Apply') 1
        Assert-True ($ads -match 'alternate data stream') ("{0}: config ADS must fail closed" -f $Label)
        Remove-Item -LiteralPath $config -Stream sentinel

        $hardlink = Join-Path $root 'config-hardlink.toml'
        New-Item -ItemType HardLink -Path $hardlink -Target $config | Out-Null
        $hardlinkOutput = Invoke-EngineBaseline $Engine @('optimize', '-Apply') 1
        Assert-True ($hardlinkOutput -match 'hard links are not supported') ("{0}: config hard links must fail closed" -f $Label)
        Remove-Item -LiteralPath $hardlink -Force
    }
    finally {
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }

    $reparseRoot = Join-Path $script:TestRoot ("optimizer-reparse-{0}" -f $Label)
    $reparseHome = Join-Path $reparseRoot 'home'
    $target = Join-Path $reparseRoot 'codex-target'
    [System.IO.Directory]::CreateDirectory($reparseHome) | Out-Null
    [System.IO.Directory]::CreateDirectory($target) | Out-Null
    $env:HOME = $reparseHome
    $env:CODEX_HOME = Join-Path $reparseHome 'codex-link'
    $env:AGENTS_HOME = Join-Path $reparseHome 'agents'
    New-Item -ItemType Junction -Path $env:CODEX_HOME -Target $target | Out-Null
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION = '1'
    try {
        $reparse = Invoke-EngineBaseline $Engine @('optimize', '-Apply') 1
        Assert-True ($reparse -match 'Reparse points are not allowed') ("{0}: reparse-point config ancestry must fail closed" -f $Label)
        Assert-True (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) ("{0}: reparse rejection must not write through the junction" -f $Label)
    }
    finally {
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $env:CODEX_HOME) { [System.IO.Directory]::Delete($env:CODEX_HOME) }
    }

    Test-ConfigPrefixAndStandardValues $Engine $Label
    Test-ConfigPendingJournalAdversaries $Engine $Label
}

function Test-CreatedTableRestorePreservationEngine {
    param([string]$Engine, [string]$Label)
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION = '1'
    try {
        $commentRoot = Join-Path $script:TestRoot ("optimizer-created-comment-{0}" -f $Label)
        Set-TestEnvironment $commentRoot | Out-Null
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
        $commentConfig = Join-Path $env:CODEX_HOME 'config.toml'
        [byte[]]$commentOriginal = [byte[]](0xEF,0xBB,0xBF) + $script:Utf8NoBom.GetBytes('foreign = "Grüezi"')
        [System.IO.File]::WriteAllBytes($commentConfig, $commentOriginal)
        Invoke-EngineBaseline $Engine @('optimize', '-Apply') | Out-Null
        [System.IO.File]::AppendAllText($commentConfig, "`r`n# user-owned agents comment", $script:Utf8NoBom)
        Invoke-EngineBaseline $Engine @('optimize', '-Restore', '-Apply') | Out-Null
        [byte[]]$commentExpected = [byte[]](0xEF,0xBB,0xBF) + $script:Utf8NoBom.GetBytes("foreign = `"Grüezi`"`r`n`r`n[agents]`r`n# user-owned agents comment")
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($commentExpected, [System.IO.File]::ReadAllBytes($commentConfig))) ("{0}: restore must retain a user comment in a Baseline-created table with exact BOM/CRLF/final-newline bytes" -f $Label)

        $addFinalRoot = Join-Path $script:TestRoot ("optimizer-current-final-add-{0}" -f $Label)
        Set-TestEnvironment $addFinalRoot | Out-Null
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
        $addFinalConfig = Join-Path $env:CODEX_HOME 'config.toml'
        [byte[]]$addFinalOriginal = [byte[]](0xEF,0xBB,0xBF) + $script:Utf8NoBom.GetBytes('foreign = "preserved"')
        [System.IO.File]::WriteAllBytes($addFinalConfig, $addFinalOriginal)
        Invoke-EngineBaseline $Engine @('optimize', '-Apply') | Out-Null
        [System.IO.File]::AppendAllText($addFinalConfig, "`r`n", $script:Utf8NoBom)
        Invoke-EngineBaseline $Engine @('optimize', '-Restore', '-Apply') | Out-Null
        [byte[]]$addFinalExpected = [byte[]](0xEF,0xBB,0xBF) + $script:Utf8NoBom.GetBytes("foreign = `"preserved`"`r`n")
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($addFinalExpected, [System.IO.File]::ReadAllBytes($addFinalConfig))) ("{0}: restore must retain a user-added current final newline instead of forcing the pre-install state" -f $Label)

        $removeFinalRoot = Join-Path $script:TestRoot ("optimizer-current-final-remove-{0}" -f $Label)
        Set-TestEnvironment $removeFinalRoot | Out-Null
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
        $removeFinalConfig = Join-Path $env:CODEX_HOME 'config.toml'
        [System.IO.File]::WriteAllText($removeFinalConfig, "foreign = `"preserved`"`r`n", $script:Utf8NoBom)
        Invoke-EngineBaseline $Engine @('optimize', '-Apply') | Out-Null
        [byte[]]$withFinal = [System.IO.File]::ReadAllBytes($removeFinalConfig)
        Assert-True ($withFinal.Length -ge 2 -and $withFinal[$withFinal.Length-2] -eq 13 -and $withFinal[$withFinal.Length-1] -eq 10) ("{0}: final-newline removal fixture must begin with CRLF" -f $Label)
        [byte[]]$withoutFinal = New-Object byte[] ($withFinal.Length - 2)
        [Array]::Copy($withFinal, $withoutFinal, $withoutFinal.Length)
        [System.IO.File]::WriteAllBytes($removeFinalConfig, $withoutFinal)
        Invoke-EngineBaseline $Engine @('optimize', '-Restore', '-Apply') | Out-Null
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($script:Utf8NoBom.GetBytes('foreign = "preserved"'), [System.IO.File]::ReadAllBytes($removeFinalConfig))) ("{0}: restore must retain a user-removed current final newline" -f $Label)
    }
    finally {
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
}

function Test-NoBom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return $bytes.Length -lt 3 -or -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Get-TestSha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Update-TestSourceManifest {
    param([string]$Root)
    $manifestPath = Join-Path $Root 'baseline\manifest.json'
    $manifest = [System.IO.File]::ReadAllText($manifestPath, $script:Utf8NoBom) | ConvertFrom-Json
    foreach ($entry in @($manifest.payload)) {
        $path = Join-Path $Root (([string]$entry.path).Replace('/', '\'))
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $entry.bytes = [long]$bytes.Length
        $entry.sha256 = Get-TestSha256 $bytes
    }
    [string[]]$canonical = @($manifest.payload | ForEach-Object {
        "{0}`t{1}`t{2}" -f [string]$_.path, [long]$_.bytes, [string]$_.sha256
    })
    [System.Array]::Sort($canonical, [System.StringComparer]::Ordinal)
    $manifest.payload_hash = Get-TestSha256 ($script:Utf8NoBom.GetBytes(([string]::Join("`n", $canonical)) + "`n"))
    [System.IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 10) + "`n"), $script:Utf8NoBom)
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
    $base = [System.IO.Path]::GetFullPath($script:PrivateTestBase).TrimEnd('\') + '\'
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([System.IO.Path]::GetFileName($full)).StartsWith('cbw-', [System.StringComparison]::Ordinal)) {
        throw "Refusing unsafe test cleanup: $full"
    }
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
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

function Test-CrossVersionV02 {
    param([string]$CurrentArchive)

    $oldCommit = '3341f1c227094a16f9f427a6e7e1c22d29fb8317'
    $oldZip = Join-Path $script:TestRoot 'codex-baseline-0.2.0-source.zip'
    $oldSource = Join-Path $script:TestRoot 'update-source-0.2.0'
    $git = @(Get-Command git.exe -CommandType Application -ErrorAction Stop)[0]
    # Materialize the historical Git blobs exactly. A caller's Windows
    # core.autocrlf setting must not rewrite the v0.2 manifest-bound fixture.
    $gitOutput = (& $git.Path -c core.autocrlf=false -c core.eol=lf -C $script:RepositoryRoot archive --format=zip --output=$oldZip $oldCommit 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $oldZip -PathType Leaf)) ("v0.2 source archive must be created: {0}" -f $gitOutput)
    Expand-Archive -LiteralPath $oldZip -DestinationPath $oldSource
    $oldScript = Join-Path $oldSource 'scripts\codex-baseline.ps1'
    Assert-True (Test-Path -LiteralPath $oldScript -PathType Leaf) 'v0.2 PowerShell installer fixture must exist'

    $savedHome = $env:HOME
    $savedCodexHome = $env:CODEX_HOME
    $savedAgentsHome = $env:AGENTS_HOME
    try {
        $root = Join-Path $script:TestRoot 'cross-version-0.2'
        $crossVersionHome = Set-TestEnvironment $root
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
        $config = Join-Path $env:CODEX_HOME 'config.toml'
        [System.IO.File]::WriteAllText($config, "user_setting = `"preserved`"`r`n", $script:Utf8NoBom)
        $configHash = Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))

        $oldInstall = Invoke-PowerShellScriptCapture $oldScript @('install', '-AcknowledgeUnverifiedSource')
        Assert-True ($oldInstall.ExitCode -eq 0 -and $oldInstall.Output -match 'installed codex-baseline 0\.2\.0') ("v0.2 installer must establish the old runtime: {0}" -f $oldInstall.Output)
        $wrapper = Join-Path $crossVersionHome '.local\bin\codex-baseline.ps1'
        $oldUpdate = Invoke-PowerShellScriptCapture $wrapper @('update', '-Offline', $CurrentArchive, '-AcknowledgeUnverifiedSource')
        Assert-True ($oldUpdate.ExitCode -eq 0 -and $oldUpdate.Output -match 'installed codex-baseline 0\.3\.0') ("installed v0.2 updater must apply v0.3: {0}" -f $oldUpdate.Output)
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $env:CODEX_HOME 'codex-baseline\runtime\VERSION'), $script:Utf8NoBom).Trim() -eq '0.3.0') 'cross-version update must install the v0.3 runtime'
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))) -eq $configHash) 'v0.2 to v0.3 update must preserve pre-existing config bytes'

        $oldRollback = Invoke-PowerShellScriptCapture $wrapper @('rollback')
        Assert-True ($oldRollback.ExitCode -eq 0 -and $oldRollback.Output -match 'rolled back transaction') ("cross-version rollback must succeed: {0}" -f $oldRollback.Output)
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $env:CODEX_HOME 'codex-baseline\runtime\VERSION'), $script:Utf8NoBom).Trim() -eq '0.2.0') 'cross-version rollback must restore the v0.2 runtime'
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))) -eq $configHash) 'cross-version rollback must preserve pre-existing config bytes'

        $oldUpdate = Invoke-PowerShellScriptCapture $wrapper @('update', '-Offline', $CurrentArchive, '-AcknowledgeUnverifiedSource')
        Assert-True ($oldUpdate.ExitCode -eq 0) ("second cross-version update must succeed before uninstall: {0}" -f $oldUpdate.Output)
        $oldUninstall = Invoke-PowerShellScriptCapture $wrapper @('uninstall')
        Assert-True ($oldUninstall.ExitCode -eq 0 -and $oldUninstall.Output -match 'uninstalled codex-baseline') ("cross-version uninstall must succeed: {0}" -f $oldUninstall.Output)
        Assert-True (-not (Test-Path -LiteralPath $wrapper)) 'cross-version uninstall must remove the installed wrapper'
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($config))) -eq $configHash) 'cross-version uninstall must preserve pre-existing config bytes'

        $crashRoot = Join-Path $script:TestRoot 'cross-version-0.2-crash'
        $crashHome = Set-TestEnvironment $crashRoot
        [System.IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
        $crashConfig = Join-Path $env:CODEX_HOME 'config.toml'
        [System.IO.File]::WriteAllText($crashConfig, "user_setting = `"crash-preserved`"`r`n", $script:Utf8NoBom)
        $crashConfigHash = Get-TestSha256 ([System.IO.File]::ReadAllBytes($crashConfig))
        $crashInstall = Invoke-PowerShellScriptCapture $oldScript @('install', '-AcknowledgeUnverifiedSource')
        Assert-True ($crashInstall.ExitCode -eq 0) ("v0.2 crash fixture install must succeed: {0}" -f $crashInstall.Output)
        $crashWrapper = Join-Path $crashHome '.local\bin\codex-baseline.ps1'
        $env:CODEX_BASELINE_TESTING = '1'
        $env:CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT = '2'
        $faultedUpdate = Invoke-PowerShellScriptCapture $crashWrapper @('update', '-Offline', $CurrentArchive, '-AcknowledgeUnverifiedSource')
        Remove-Item Env:\CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT
        Assert-True ($faultedUpdate.ExitCode -ne 0 -and $faultedUpdate.Output -match 'recovering incomplete transaction' -and -not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'codex-baseline\state\pending'))) ("faulted v0.2 updater must recover its incomplete transaction before exiting (exit {0}): {1}" -f $faultedUpdate.ExitCode, $faultedUpdate.Output)
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $env:CODEX_HOME 'codex-baseline\runtime\VERSION'), $script:Utf8NoBom).Trim() -eq '0.2.0') 'fault recovery must restore the v0.2 runtime before retry'
        $recoveredUpdate = Invoke-PowerShellScriptCapture $crashWrapper @('update', '-Offline', $CurrentArchive, '-AcknowledgeUnverifiedSource')
        Assert-True ($recoveredUpdate.ExitCode -eq 0 -and $recoveredUpdate.Output -match 'installed codex-baseline 0\.3\.0') ("v0.2 updater must complete v0.3 after fault recovery: {0}" -f $recoveredUpdate.Output)
        Assert-True ((Get-TestSha256 ([System.IO.File]::ReadAllBytes($crashConfig))) -eq $crashConfigHash) 'cross-version recovery must preserve pre-existing config bytes'
    }
    finally {
        Remove-Item Env:\CODEX_BASELINE_TEST_FAULT_AFTER_OBJECT -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
        $env:HOME = $savedHome
        $env:CODEX_HOME = $savedCodexHome
        $env:AGENTS_HOME = $savedAgentsHome
    }
}

function Test-UninstallRestoresAncestorConfigEngine {
    param([string]$Engine,[string]$Label,[string]$UpdateArchive)
    $savedHome=$env:HOME
    $savedCodexHome=$env:CODEX_HOME
    $savedAgentsHome=$env:AGENTS_HOME
    $env:CODEX_BASELINE_TESTING='1'
    $env:CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION='1'
    try{
        $normalRoot=Join-Path $script:TestRoot ("uninstall-ancestor-{0}"-f$Label)
        $normalHome=Set-TestEnvironment $normalRoot
        Invoke-EngineBaseline $Engine @('install','-AcknowledgeUnverifiedSource')|Out-Null
        $installCore=Get-TestCoreCurrentId
        $wrapper=Join-Path $normalHome '.local\bin\codex-baseline.ps1'
        $update=Invoke-EngineScriptCapture $Engine $wrapper @('update','-Offline',$UpdateArchive,'-AcknowledgeUnverifiedSource')
        Assert-True ($update.ExitCode-eq0) ("{0}: changed offline update must succeed before the ancestor-config uninstall test: {1}"-f$Label,$update.Output)
        $updateCore=Get-TestCoreCurrentId
        $boundConfig=Get-TestConfigCurrentJournal
        Assert-True ($updateCore-ne$installCore-and[string]$boundConfig.CoreTransaction-eq$installCore) ("{0}: changed update must leave automatic-cap ownership validly bound to its install ancestor"-f$Label)
        $uninstall=Invoke-EngineScriptCapture $Engine $wrapper @('uninstall')
        Assert-True ($uninstall.ExitCode-eq0-and$uninstall.Output-match'uninstalled codex-baseline') ("{0}: one uninstall after a changed update must succeed: {1}"-f$Label,$uninstall.Output)
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml'))) ("{0}: one uninstall must remove the ancestor-bound automatic cap"-f$Label)
        Assert-True (@((Get-TestConfigCurrentJournal).Ownership).Count-eq0) ("{0}: uninstall must release all ancestor-bound config ownership"-f$Label)
        Assert-TestNoPendingCompositeState ("uninstall-ancestor-{0}"-f$Label)

        $crashRoot=Join-Path $script:TestRoot ("uninstall-ancestor-crash-{0}"-f$Label)
        $crashHome=Set-TestEnvironment $crashRoot
        Invoke-EngineBaseline $Engine @('install','-AcknowledgeUnverifiedSource')|Out-Null
        $crashInstallCore=Get-TestCoreCurrentId
        $crashWrapper=Join-Path $crashHome '.local\bin\codex-baseline.ps1'
        $crashUpdate=Invoke-EngineScriptCapture $Engine $crashWrapper @('update','-Offline',$UpdateArchive,'-AcknowledgeUnverifiedSource')
        Assert-True ($crashUpdate.ExitCode-eq0) ("{0}: changed update must succeed before crash recovery: {1}"-f$Label,$crashUpdate.Output)
        $crashSource=Get-TestCoreCurrentId
        Assert-True ($crashSource-ne$crashInstallCore-and[string](Get-TestConfigCurrentJournal).CoreTransaction-eq$crashInstallCore) ("{0}: crash fixture config must remain bound to an ancestor core"-f$Label)
        $configState=Join-Path $env:CODEX_HOME 'codex-baseline\state\config'
        $savedConfigState=Join-Path $crashRoot 'saved-config-state'
        Move-Item -LiteralPath $configState -Destination $savedConfigState
        $splitUninstall=Invoke-EngineScriptCapture $Engine $crashWrapper @('uninstall')
        Assert-True ($splitUninstall.ExitCode-eq0) ("{0}: split fixture must commit its uninstall core: {1}"-f$Label,$splitUninstall.Output)
        $crashDesired=Get-TestCoreCurrentId
        if(Test-Path -LiteralPath $configState){Remove-Item -LiteralPath $configState -Recurse -Force}
        Move-Item -LiteralPath $savedConfigState -Destination $configState
        $composite=New-TestCompositePending 'uninstall' $crashSource $crashDesired
        $recovery=Invoke-EngineScriptCapture $Engine (Join-Path $script:RepositoryRoot 'scripts\codex-baseline.ps1') @('uninstall')
        Assert-True ($recovery.ExitCode-eq0) ("{0}: crash-after-core-commit recovery must succeed for ancestor-bound config: {1}"-f$Label,$recovery.Output)
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml'))) ("{0}: crash recovery must remove the ancestor-bound automatic cap"-f$Label)
        Assert-True (([System.IO.File]::ReadAllText((Join-Path $composite.Directory 'transaction.json'),$script:Utf8NoBom)|ConvertFrom-Json).State-eq'committed') ("{0}: recovered ancestor-bound uninstall composite must commit"-f$Label)
        Assert-TestNoPendingCompositeState ("uninstall-ancestor-crash-{0}"-f$Label)

        $preOptimizeRoot=Join-Path $script:TestRoot ("uninstall-pre-optimize-{0}"-f$Label)
        Set-TestEnvironment $preOptimizeRoot|Out-Null
        Invoke-EngineBaseline $Engine @('optimize','-Apply')|Out-Null
        Assert-True ($null-eq(Get-TestConfigCurrentJournal).CoreTransaction) ("{0}: optimize-before-install fixture must have no core binding"-f$Label)
        Invoke-EngineBaseline $Engine @('install','-AcknowledgeUnverifiedSource')|Out-Null
        $preOptimizeUninstall=Invoke-EngineBaseline $Engine @('uninstall')
        Assert-True ($preOptimizeUninstall-match'uninstalled codex-baseline') ("{0}: one uninstall must accept valid optimize-before-install ownership"-f$Label)
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $env:CODEX_HOME 'config.toml'))) ("{0}: uninstall must restore the absent config from optimize-before-install ownership"-f$Label)
        Assert-True (@((Get-TestConfigCurrentJournal).Ownership).Count-eq0) ("{0}: uninstall must release optimize-before-install ownership"-f$Label)
        Assert-TestNoPendingCompositeState ("uninstall-pre-optimize-{0}"-f$Label)
    }
    finally{
        Remove-Item Env:\CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
        $env:HOME=$savedHome
        $env:CODEX_HOME=$savedCodexHome
        $env:AGENTS_HOME=$savedAgentsHome
    }
}

$productionScript = [System.IO.File]::ReadAllText($script:BaselineScript, $script:Utf8NoBom)
Assert-True ($productionScript -match '\$request\.AllowAutoRedirect\s*=\s*\$false') 'remote update must disable automatic redirects'
Assert-True ($productionScript -notmatch '\$request\.MaximumAutomaticRedirections\s*=\s*0') 'remote update must not assign the invalid zero automatic-redirect limit'
Assert-True ($productionScript -notmatch '(?i)\bGet-Acl\b') 'production ACL validation must not depend on Get-Acl module autoloading'
Assert-True ($productionScript -match 'FileSystemAclExtensions\]::GetAccessControl' -and
    $productionScript -match '\.GetAccessRules\(\$true,\s*\$true,\s*\[System\.Security\.Principal\.SecurityIdentifier\]\)') 'production ACL validation must use native runtime ACL APIs and explicit SID rules'
Assert-True ($productionScript -match 'PROTECTED_DACL_SECURITY_INFORMATION=0x80000000' -and
    $productionScript -match 'UNPROTECTED_DACL_SECURITY_INFORMATION=0x20000000' -and
    $productionScript -match 'SetDacl\(\$Path,\$desired\.GetSecurityDescriptorBinaryForm\(\),\[bool\]\$desired\.AreAccessRulesProtected\)') 'config ACL writes must set the native protected or unprotected DACL control flag explicitly'

New-PrivateTestRoot $script:TestRoot
if ($env:CODEX_BASELINE_WINDOWS_TEST_GROUP -eq 'lifecycle-provenance') {
    try {
        Test-LifecycleProvenanceDoesNotInvokeGit $script:PowerShell 'ps51'
        if ($null -ne $script:PowerShellCore) { Test-LifecycleProvenanceDoesNotInvokeGit $script:PowerShellCore 'ps7' }
        Write-Output ("PASS: Windows lifecycle provenance ({0} assertions)" -f $script:Assertions)
    }
    finally {
        Remove-Item Env:\CODEX_BASELINE_WINDOWS_TEST_GROUP -ErrorAction SilentlyContinue
        Remove-TestRoot $script:TestRoot
    }
    exit 0
}
try {
    Test-LifecycleProvenanceDoesNotInvokeGit $script:PowerShell 'ps51'
    if ($null -ne $script:PowerShellCore) { Test-LifecycleProvenanceDoesNotInvokeGit $script:PowerShellCore 'ps7' }
    Test-ReleaseGuidanceSelectionEngine $script:PowerShell 'ps51'
    Test-OptimizerEngine $script:PowerShell 'ps51'
    Test-ConfigIntegerGrammarEngine $script:PowerShell 'ps51'
    Test-ConfigStageConfidentialityEngine $script:PowerShell 'ps51'
    Test-CreatedTableRestorePreservationEngine $script:PowerShell 'ps51'
    Test-ConfigDaclRecoveryEngine $script:PowerShell 'ps51'
    Test-ConfigPreSecurityCrashRecoveryEngine $script:PowerShell 'ps51'
    Test-ConfigRecoveryMetadataTamperEngine $script:PowerShell 'ps51'
    if ($null -ne $script:PowerShellCore) {
        Test-ReleaseGuidanceSelectionEngine $script:PowerShellCore 'ps7'
        Test-OptimizerEngine $script:PowerShellCore 'ps7'
        Test-ConfigIntegerGrammarEngine $script:PowerShellCore 'ps7'
        Test-ConfigStageConfidentialityEngine $script:PowerShellCore 'ps7'
        Test-CreatedTableRestorePreservationEngine $script:PowerShellCore 'ps7'
        Test-ConfigDaclRecoveryEngine $script:PowerShellCore 'ps7'
        Test-ConfigPreSecurityCrashRecoveryEngine $script:PowerShellCore 'ps7'
        Test-ConfigRecoveryMetadataTamperEngine $script:PowerShellCore 'ps7'
    }
    Test-AutoCapPreflightEngine $script:PowerShell 'ps51'
    if ($null -ne $script:PowerShellCore) { Test-AutoCapPreflightEngine $script:PowerShellCore 'ps7' }
    Test-CompositeRecoveryPhases

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
    Assert-True ($unacknowledgedOutput -match 'AcknowledgeUnverifiedSource') ("acknowledgement failure must be actionable; output: {0}" -f $unacknowledgedOutput)
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
    Assert-True ($racyExit -eq 1 -and $racyOutput -match 'Payload byte length mismatch|changed while creating the verified snapshot') ("source mutation between verification and snapshot must fail closed; output: {0}" -f $racyOutput)
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

    $sharedStagingHome = Set-TestEnvironment (Join-Path $script:TestRoot 'shared-staging-root')
    $sharedStagingDirectory = New-Object System.IO.DirectoryInfo($sharedStagingHome)
    $sharedStagingAcl = $sharedStagingDirectory.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $sharedStagingRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $usersSid,
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions,
        [System.Security.AccessControl.InheritanceFlags]::None,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $sharedStagingAcl.AddAccessRule($sharedStagingRule) | Out-Null
    $sharedStagingDirectory.SetAccessControl($sharedStagingAcl)
    $sharedStagingOutput = Invoke-Baseline @('install') 1
    Assert-True ($sharedStagingOutput -match 'mutation rights\s+to an untrusted SID') ("installer must reject an ACL-escalatable private staging parent before snapshot creation; output: {0}" -f $sharedStagingOutput)
    Assert-True (-not (Test-Path -LiteralPath $env:AGENTS_HOME)) 'shared staging-parent rejection must precede managed-home mutation'
    if ($null -ne $script:PowerShellCore) {
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $coreSharedStagingOutput = (& $script:PowerShellCore -NoProfile -ExecutionPolicy Bypass -File $script:BaselineScript install -DryRun -AcknowledgeUnverifiedSource 2>&1 | Out-String).Trim()
            $coreSharedStagingExit = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedPreference }
        Assert-True ($coreSharedStagingExit -eq 1 -and $coreSharedStagingOutput -match 'mutation rights\s+to an untrusted SID') ("PowerShell 7 must reject an ACL-escalatable private staging parent: {0}" -f $coreSharedStagingOutput)
    }

    $deleteChildStagingHome = Set-TestEnvironment (Join-Path $script:TestRoot 'delete-child-staging-root')
    $deleteChildStagingDirectory = New-Object System.IO.DirectoryInfo($deleteChildStagingHome)
    $deleteChildStagingAcl = $deleteChildStagingDirectory.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    $deleteChildStagingRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $usersSid,
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
        [System.Security.AccessControl.InheritanceFlags]::None,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $deleteChildStagingAcl.AddAccessRule($deleteChildStagingRule) | Out-Null
    $deleteChildStagingDirectory.SetAccessControl($deleteChildStagingAcl)
    $deleteChildStagingOutput = Invoke-Baseline @('install') 1
    Assert-True ($deleteChildStagingOutput -match 'mutation rights\s+to an untrusted SID') ("installer must reject untrusted DeleteChild rights directly on the private staging root; output: {0}" -f $deleteChildStagingOutput)
    Assert-True (-not (Test-Path -LiteralPath $env:AGENTS_HOME)) 'staging-root DeleteChild rejection must precede managed-home mutation'

    $duplicateOperationsSource = Join-Path $script:TestRoot 'duplicate-operation-source'
    [System.IO.Directory]::CreateDirectory($duplicateOperationsSource) | Out-Null
    foreach ($sourceName in @('VERSION', 'baseline', 'benchmarks', 'scripts')) {
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $sourceName) -Destination $duplicateOperationsSource -Recurse
    }
    $duplicateOperationsPath = Join-Path $duplicateOperationsSource 'baseline\operations.json'
    $duplicateOperations = [System.IO.File]::ReadAllText($duplicateOperationsPath, $script:Utf8NoBom) | ConvertFrom-Json
    $duplicateOperations.objects[1] = $duplicateOperations.objects[0]
    [System.IO.File]::WriteAllText($duplicateOperationsPath, (($duplicateOperations | ConvertTo-Json -Depth 10) + "`n"), $script:Utf8NoBom)
    Update-TestSourceManifest $duplicateOperationsSource
    Set-TestEnvironment (Join-Path $script:TestRoot 'duplicate-operation-home') | Out-Null
    $originalBaselineScript = $script:BaselineScript
    try {
        $script:BaselineScript = Join-Path $duplicateOperationsSource 'scripts\codex-baseline.ps1'
        $duplicateOperationsOutput = Invoke-Baseline @('install', '-DryRun') 1
    }
    finally { $script:BaselineScript = $originalBaselineScript }
    Assert-True ($duplicateOperationsOutput -match 'object id is duplicated') ("PowerShell source validation must reject duplicate operations object IDs; output: {0}" -f $duplicateOperationsOutput)
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
        Assert-True ($nativeDoctor.optimizer.agents-eq'available'-and$nativeDoctor.optimizer.fast-eq'unverified') 'doctor must separate verified Agents support from unverified Fast config support'

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
    Assert-True ($installOutput -match 'installed codex-baseline 0\.3\.0') 'clean install must report version'
    $agentsText = [System.IO.File]::ReadAllText($agentsFile, $script:Utf8NoBom)
    Assert-True ($agentsText.StartsWith($originalText, [System.StringComparison]::Ordinal)) 'install must preserve existing guidance prefix'
    Assert-True ($agentsText -match '<!-- codex-baseline:begin version=0\.3\.0 -->') 'managed block must be installed'
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
    $updateArtifacts = Join-Path $script:TestRoot 'update-artifacts'
    $futureArtifacts = Join-Path $script:TestRoot 'update-artifacts-0.3.1'
    $newerArtifacts = Join-Path $script:TestRoot 'update-artifacts-0.3.2'
    $adversarialArtifacts = Join-Path $script:TestRoot 'update-adversaries'
    [System.IO.Directory]::CreateDirectory($updateArtifacts) | Out-Null
    [System.IO.Directory]::CreateDirectory($futureArtifacts) | Out-Null
    [System.IO.Directory]::CreateDirectory($newerArtifacts) | Out-Null
    $python = @(Get-Command python.exe -CommandType Application -ErrorAction Stop)[0]
    $artifactOutput = (& $python.Path (Join-Path $script:RepositoryRoot 'scripts\release-update.py') '--output' $updateArtifacts 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $artifactOutput -match 'codex-baseline-update-preview-v1\.txt' -and $artifactOutput -match 'codex-baseline-0\.3\.0-rc\.1\.zip') ("RC release artifact builder must emit preview-only assets: {0}" -f $artifactOutput)
    $currentArchive = Join-Path $updateArtifacts ("codex-baseline-{0}-rc.1.zip" -f ([System.IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'VERSION'), $script:Utf8NoBom).Trim()))
    Test-CrossVersionV02 $currentArchive
    $futureArtifactOutput = (& $python.Path (Join-Path $script:RepositoryRoot 'tests\release-promotion.py') '--build-update-fixture' '--source' $script:RepositoryRoot '--version' '0.3.1' '--output' $futureArtifacts 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $futureArtifactOutput -match 'codex-baseline-0\.3\.1\.zip') ("future release artifact builder must succeed: {0}" -f $futureArtifactOutput)
    $futureArchive = Join-Path $futureArtifacts 'codex-baseline-0.3.1.zip'
    Test-UninstallRestoresAncestorConfigEngine $script:PowerShell 'ps51' $futureArchive
    if ($null -ne $script:PowerShellCore) { Test-UninstallRestoresAncestorConfigEngine $script:PowerShellCore 'ps7' $futureArchive }
    $newerArtifactOutput = (& $python.Path (Join-Path $script:RepositoryRoot 'tests\release-promotion.py') '--build-update-fixture' '--source' $script:RepositoryRoot '--version' '0.3.2' '--output' $newerArtifacts 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $newerArtifactOutput -match 'codex-baseline-0\.3\.2\.zip') ("newer release artifact builder must succeed: {0}" -f $newerArtifactOutput)
    $updateDescriptor = Join-Path $futureArtifacts 'codex-baseline-update-v1.txt'
    $updateArchive = Join-Path $futureArtifacts 'codex-baseline-0.3.1.zip'
    $sameVersionStableDescriptor=Join-Path $script:TestRoot 'same-version-stable-update-v1.txt'
    $sameVersionStableText=[System.IO.File]::ReadAllText($updateDescriptor,$script:Utf8NoBom).Replace('0.3.1','0.3.0')
    [System.IO.File]::WriteAllText($sameVersionStableDescriptor,$sameVersionStableText,$script:Utf8NoBom)
    $env:CODEX_BASELINE_TESTING='1'
    $env:CODEX_BASELINE_TEST_UPDATE_METADATA_PATH=$sameVersionStableDescriptor
    try{
        $sameVersionCheck=Invoke-EngineScriptCapture $script:PowerShell $wrapper @('update','-Check')
        Assert-True ($sameVersionCheck.ExitCode-eq0-and$sameVersionCheck.Output-match'update available: 0\.3\.0 \(rc\.1\) -> 0\.3\.0 \(stable\)') ("PowerShell 5.1 update check must promote equal-SemVer RC to stable: {0}"-f$sameVersionCheck.Output)
        if($null-ne$script:PowerShellCore){
            $sameVersionCoreCheck=Invoke-EngineScriptCapture $script:PowerShellCore $wrapper @('update','-Check')
            Assert-True ($sameVersionCoreCheck.ExitCode-eq0-and$sameVersionCoreCheck.Output-match'update available: 0\.3\.0 \(rc\.1\) -> 0\.3\.0 \(stable\)') ("PowerShell 7 update check must promote equal-SemVer RC to stable: {0}"-f$sameVersionCoreCheck.Output)
        }
    }
    finally{
        Remove-Item Env:\CODEX_BASELINE_TEST_UPDATE_METADATA_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
    $adversaryOutput = (& $python.Path (Join-Path $script:RepositoryRoot 'tests\make-update-adversaries.py') '--tar' (Join-Path $updateArtifacts 'codex-baseline-0.3.0-rc.1.tar.gz') '--zip' $currentArchive '--output' $adversarialArtifacts 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0) ("adversarial update archive builder must succeed: {0}" -f $adversaryOutput)
    $env:CODEX_BASELINE_TESTING = '1'
    $env:CODEX_BASELINE_TEST_UPDATE_METADATA_PATH = $updateDescriptor
    $env:CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH = $updateArchive
    $pausedProcess = $null
    try {
        $wrapperCheck = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper update -Check 2>&1 | Out-String).Trim()
        Assert-True ($LASTEXITCODE -eq 0 -and $wrapperCheck -match 'update available: 0\.3\.0 -> 0\.3\.1') ("installed wrapper update check must succeed: {0}" -f $wrapperCheck)
        Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'update check must preserve current transaction'
        if ($null -ne $script:PowerShellCore) {
            $savedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $coreCheck = (& $script:PowerShellCore -NoProfile -ExecutionPolicy Bypass -File $wrapper update -Check 2>&1 | Out-String).Trim()
                $coreCheckExit = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $savedPreference }
            Assert-True ($coreCheckExit -eq 0 -and $coreCheck -match 'update available: 0\.3\.0 -> 0\.3\.1') ("PowerShell 7 installed wrapper update check must succeed: {0}" -f $coreCheck)
            Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'PowerShell 7 update check must preserve current transaction'
        }
        $wrapperDry = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper update -DryRun 2>&1 | Out-String).Trim()
        Assert-True ($LASTEXITCODE -eq 0 -and $wrapperDry -match 'dry-run: no files changed') ("installed wrapper remote update dry-run must succeed: {0}" -f $wrapperDry)
        Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'remote update dry-run must preserve current transaction'
        $wrapperOffline = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper update -Offline $currentArchive -DryRun 2>&1 | Out-String).Trim()
        Assert-True ($LASTEXITCODE -eq 0 -and $wrapperOffline -match 'already installed; no changes') ("installed wrapper offline update dry-run must succeed: {0}" -f $wrapperOffline)

        $growingArchive = Join-Path $script:TestRoot 'growing-offline.zip'
        [System.IO.File]::Copy($currentArchive, $growingArchive)
        $env:CODEX_BASELINE_TEST_GROW_UPDATE_INPUT = '1'
        $growingResult = Invoke-PowerShellScriptCapture $wrapper @('update', '-Offline', $growingArchive, '-DryRun')
        $growingUpdate = $growingResult.Output
        Remove-Item Env:\CODEX_BASELINE_TEST_GROW_UPDATE_INPUT
        Assert-True ($growingResult.ExitCode -ne 0 -and $growingUpdate -match 'exceeded its byte limit while it was frozen') ("growing offline archive must fail at the bounded copy: {0}" -f $growingUpdate)
        Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'growing offline archive rejection must preserve current transaction'

        $substitutedArchive = Join-Path $script:TestRoot 'substituted-offline.zip'
        [System.IO.File]::Copy($currentArchive, $substitutedArchive)
        $env:CODEX_BASELINE_TEST_SUBSTITUTE_UPDATE_INPUT = '1'
        $substitutedResult = Invoke-PowerShellScriptCapture $wrapper @('update', '-Offline', $substitutedArchive, '-DryRun')
        $substitutedUpdate = $substitutedResult.Output
        Remove-Item Env:\CODEX_BASELINE_TEST_SUBSTITUTE_UPDATE_INPUT
        Assert-True ($substitutedResult.ExitCode -ne 0 -and $substitutedUpdate -match 'replacement was blocked while the source handle was frozen') ("offline archive substitution must be blocked by the frozen handle: {0}" -f $substitutedUpdate)
        Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'offline substitution rejection must preserve current transaction'

        $corruptDescriptor = Join-Path $script:TestRoot 'corrupt-update.txt'
        $corruptText = [System.IO.File]::ReadAllText($updateDescriptor, $script:Utf8NoBom) -replace '(?m)^zip_sha256=.*$', ('zip_sha256=' + ('0' * 64))
        [System.IO.File]::WriteAllText($corruptDescriptor, $corruptText, $script:Utf8NoBom)
        $env:CODEX_BASELINE_TEST_UPDATE_METADATA_PATH = $corruptDescriptor
        $corruptResult = Invoke-PowerShellScriptCapture $wrapper @('update', '-DryRun')
        $corruptUpdate = $corruptResult.Output
        Assert-True ($corruptResult.ExitCode -ne 0 -and $corruptUpdate -match 'archive SHA-256 mismatch') ("remote update must reject descriptor/archive hash mismatch: {0}" -f $corruptUpdate)
        Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'failed remote update must preserve current transaction'

        foreach ($adversary in @('traversal.zip', 'symlink.zip', 'case-collision.zip', 'forged-length.zip')) {
            $adversarialResult = Invoke-PowerShellScriptCapture $wrapper @('update', '-Offline', (Join-Path $adversarialArtifacts $adversary), '-DryRun')
            $adversarialUpdate = $adversarialResult.Output
            Assert-True ($adversarialResult.ExitCode -ne 0 -and $adversarialUpdate -match 'Unsafe update archive path|Linked or special update archive member|Duplicate or case-colliding|declared or total content limit|length mismatch') ("adversarial archive must fail before mutation ({0}): {1}" -f $adversary, $adversarialUpdate)
            Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'adversarial archive rejection must preserve current transaction'
        }

        $pauseDirectory = Join-Path $script:TestRoot 'concurrent-update-pause'
        [System.IO.Directory]::CreateDirectory($pauseDirectory) | Out-Null
        $pausedStdout = Join-Path $script:TestRoot 'paused-update.stdout'
        $pausedStderr = Join-Path $script:TestRoot 'paused-update.stderr'
        $env:CODEX_BASELINE_TEST_UPDATE_METADATA_PATH = $updateDescriptor
        $env:CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK = $pauseDirectory
        $pausedProcess = Start-Process -FilePath $script:PowerShell -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
            'update', '-AcknowledgeUnverifiedSource'
        ) -PassThru -RedirectStandardOutput $pausedStdout -RedirectStandardError $pausedStderr -WindowStyle Hidden
        for ($pauseAttempt = 0; $pauseAttempt -lt 200 -and -not (Test-Path -LiteralPath (Join-Path $pauseDirectory 'ready')); $pauseAttempt++) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath (Join-Path $pauseDirectory 'ready')) 'remote update must reach the deterministic pre-lock concurrency point'
        Remove-Item Env:\CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK
        $newerApply = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper update -Offline (Join-Path $newerArtifacts 'codex-baseline-0.3.2.zip') -AcknowledgeUnverifiedSource 2>&1 | Out-String).Trim()
        Assert-True ($LASTEXITCODE -eq 0 -and $newerApply -match 'installed codex-baseline 0\.3\.2') ("concurrent newer update must succeed: {0}" -f $newerApply)
        [System.IO.File]::WriteAllText((Join-Path $pauseDirectory 'continue'), "continue`n", $script:Utf8NoBom)
        Assert-True ($pausedProcess.WaitForExit(15000)) 'paused remote update must exit after the concurrency fixture continues'
        $pausedOutput = ([System.IO.File]::ReadAllText($pausedStdout, $script:Utf8NoBom) + [System.IO.File]::ReadAllText($pausedStderr, $script:Utf8NoBom))
        Assert-True ($pausedProcess.ExitCode -ne 0 -and $pausedOutput -match 'Remote update would downgrade installed 0\.3\.2 to 0\.3\.1') ("locked anti-downgrade must reject the stale acquisition: {0}" -f $pausedOutput)
        $newerRollback = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper rollback 2>&1 | Out-String).Trim()
        Assert-True ($LASTEXITCODE -eq 0 -and $newerRollback -match 'rolled back transaction') 'newer concurrency fixture must roll back cleanly'
        Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'concurrency fixture rollback must restore the first transaction'

        $env:CODEX_BASELINE_TEST_UPDATE_METADATA_PATH = $updateDescriptor
        $executionCanary = Join-Path $script:TestRoot 'downloaded-code-executed'
        $env:CODEX_BASELINE_TEST_DOWNLOADED_EXECUTION_CANARY = $executionCanary
        $wrapperApply = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper update -AcknowledgeUnverifiedSource 2>&1 | Out-String).Trim()
        Remove-Item Env:\CODEX_BASELINE_TEST_DOWNLOADED_EXECUTION_CANARY
        Assert-True ($LASTEXITCODE -eq 0 -and $wrapperApply -match 'installed codex-baseline 0\.3\.1') ("installed wrapper remote update apply must succeed: {0}" -f $wrapperApply)
        Assert-True (-not (Test-Path -LiteralPath $executionCanary)) 'trusted updater must not execute downloaded release code before apply'
        $updatedTransaction = [System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim()
        Assert-True ($updatedTransaction -ne $firstTransaction) 'remote update apply must commit a new transaction'
        $updatedDoctorOutput = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper doctor -Json 2>&1 | Out-String).Trim()
        $updatedDoctor = $updatedDoctorOutput | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $updatedDoctor.baseline_version -eq '0.3.1' -and @($updatedDoctor.failures).Count -eq 0) 'doctor must report the remotely updated version'
        $updateRollback = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper rollback 2>&1 | Out-String).Trim()
        Assert-True ($LASTEXITCODE -eq 0 -and $updateRollback -match 'rolled back transaction') ("remote update rollback must succeed: {0}" -f $updateRollback)
        Assert-True ([System.IO.File]::ReadAllText($currentPath, $script:Utf8NoBom).Trim() -eq $firstTransaction) 'remote update rollback must restore the prior current transaction'
        $rollbackDoctorOutput = (& $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $wrapper doctor -Json 2>&1 | Out-String).Trim()
        $rollbackDoctor = $rollbackDoctorOutput | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $rollbackDoctor.baseline_version -eq '0.3.0' -and @($rollbackDoctor.failures).Count -eq 0) 'doctor must verify the exact prior managed state after update rollback'
    }
    finally {
        if ($null -ne $pausedProcess -and -not $pausedProcess.HasExited) {
            $pausedProcess.Kill()
            $pausedProcess.WaitForExit()
        }
        Remove-Item Env:\CODEX_BASELINE_TEST_UPDATE_METADATA_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TEST_DOWNLOADED_EXECUTION_CANARY -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TEST_GROW_UPDATE_INPUT -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TEST_SUBSTITUTE_UPDATE_INPUT -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_BASELINE_TESTING -ErrorAction SilentlyContinue
    }
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
    Assert-True ($doctorJson.schema -eq 2 -and $doctorJson.contract -eq 'codex-baseline-doctor/v2') 'doctor must emit the shared v2 report contract'
    Assert-True ($doctorJson.baseline_version -eq '0.3.0') 'doctor must report the installed baseline version'
    Assert-True ($doctorJson.source_provenance.scope -eq 'local-source' -and $doctorJson.source_provenance.trust -eq 'unsigned-local-source') 'source invocation must report explicit local-source trust provenance'
    if ($doctorJson.codex_verification -eq 'executed-native-windows') {
        Assert-True ($doctorJson.native_capabilities -eq 'verified') 'available native Codex must have its required stable capabilities verified'
        Assert-True ($doctorJson.active_config.status -eq 'accepted-by-strict-config') 'available native Codex must execute strict-config validation'
    }
    else {
        Assert-True ($doctorJson.codex_verification -eq 'unverified-native-codex-not-installed') 'missing native Codex must be labelled unverified'
        Assert-True ($doctorJson.active_config.status -eq 'unverified-native-codex-not-installed') 'missing native Codex must keep config verification explicitly unverified'
    }
    Assert-True ($doctorJson.managed_objects.ok -eq 8 -and $doctorJson.managed_objects.total -eq 8) 'doctor must report all managed objects through the shared shape'
    Assert-True ($doctorJson.skills.ok -eq 4 -and $doctorJson.skills.total -eq 4) 'doctor must report all skills through the shared shape'
    Assert-True ($doctorJson.runtime_dependencies.status -eq 'verified' -and @($doctorJson.runtime_dependencies.missing).Count -eq 0) 'doctor must report native runtime dependency health'
    Assert-True ($doctorJson.hook_state.baseline_owned -eq 0) 'doctor must report zero baseline-owned hooks independently of native Codex availability'
    Assert-True ($doctorJson.owned_config_keys -eq 1) 'fresh install must own only the previously absent agent cap'
    Assert-True ($doctorJson.optimizer.contract -eq 'codex-baseline-config-operations/v2' -and @($doctorJson.optimizer.managed_keys).Count -eq 1 -and @($doctorJson.optimizer.managed_keys)[0] -eq 'agents.max_concurrent_threads_per_session') 'doctor must report key-scoped optimizer ownership'
    $expectedAgentCapability=if($doctorJson.native_capabilities-eq'verified'-and$doctorJson.active_config.status-eq'accepted-by-strict-config'){'available'}else{'unverified'}
    Assert-True (-not $doctorJson.optimizer.drift -and $doctorJson.optimizer.agents -eq $expectedAgentCapability -and $doctorJson.optimizer.fast -eq 'unverified' -and $doctorJson.optimizer.ultrafast -eq 'unavailable') 'doctor must report only invocation-verified optimizer capabilities and keep absent Fast config evidence unverified'
    Assert-True ($doctorJson.paths.codex_home -eq $env:CODEX_HOME -and $doctorJson.paths.agents_home -eq $env:AGENTS_HOME) 'doctor must report effective native managed paths'
    Assert-True (((@($doctorJson.PSObject.Properties.Name) | Sort-Object) -join ',') -eq ((@($doctorGolden.PSObject.Properties.Name) | Sort-Object) -join ',')) 'native doctor keys must match the cross-platform golden contract'
    Assert-True (@($doctorJson.failures).Count -eq 0) 'native Codex availability must not create an installation-corruption failure'

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
    if (Test-Path Env:\CODEX_BASELINE_TEST_HALT_AFTER_CONFIG_REPLACE_BEFORE_SECURITY) {
        Remove-Item Env:\CODEX_BASELINE_TEST_HALT_AFTER_CONFIG_REPLACE_BEFORE_SECURITY
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
    if (Test-Path Env:\CODEX_BASELINE_TEST_UPDATE_METADATA_PATH) {
        Remove-Item Env:\CODEX_BASELINE_TEST_UPDATE_METADATA_PATH
    }
    if (Test-Path Env:\CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH) {
        Remove-Item Env:\CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH
    }
    if (Test-Path Env:\CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK) {
        Remove-Item Env:\CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK
    }
    Remove-TestRoot $script:TestRoot
}
