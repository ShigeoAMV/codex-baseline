[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Verify')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$Workspace
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$workspacePath = [System.IO.Path]::GetFullPath($Workspace)
$fixturePath = Join-Path $PSScriptRoot 'workspace'

if ($Mode -eq 'Prepare') {
    if (Test-Path -LiteralPath $workspacePath) {
        throw "Destination already exists: $workspacePath"
    }
    [System.IO.Directory]::CreateDirectory($workspacePath) | Out-Null
    $appPath = Join-Path $workspacePath 'app\(main)'
    $dataPath = Join-Path $workspacePath 'data'
    [System.IO.Directory]::CreateDirectory($appPath) | Out-Null
    [System.IO.Directory]::CreateDirectory($dataPath) | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixturePath 'page.tsx') -Destination (Join-Path $appPath 'page.tsx')
    Copy-Item -LiteralPath (Join-Path $fixturePath 'value.txt') -Destination (Join-Path $dataPath "O'Brien `$value [draft].txt")
    [Console]::Out.WriteLine("prepared native PowerShell evaluation workspace: $workspacePath")
    exit 0
}

& (Join-Path $PSScriptRoot 'verifier.ps1') -Workspace $workspacePath
