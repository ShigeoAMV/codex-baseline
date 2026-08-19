[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Workspace
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath($Workspace)
$page = Join-Path $root 'app\(main)\page.tsx'
$data = Join-Path $root "data\O'Brien `$value [draft].txt"
$result = Join-Path $root 'result.json'
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)

foreach ($path in @($page, $data, $result)) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Expected ordinary file: $path"
    }
}

if ($utf8.GetString([System.IO.File]::ReadAllBytes($page)) -ne "export const port = 4317;`n") {
    throw 'TypeScript fixture changed.'
}
if ($utf8.GetString([System.IO.File]::ReadAllBytes($data)) -ne "literal: a|b `$HOME `"quoted`"`n") {
    throw 'Text fixture changed.'
}

$actualFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
    $_.FullName.Substring($root.Length).TrimStart([char]'\').Replace('\', '/')
} | Sort-Object)
$expectedFiles = @(
    'app/(main)/page.tsx'
    "data/O'Brien `$value [draft].txt"
    'result.json'
)
if (($actualFiles -join "`n") -cne ($expectedFiles -join "`n")) {
    throw "Unexpected workspace files: $($actualFiles -join ', ')"
}

try {
    $report = $utf8.GetString([System.IO.File]::ReadAllBytes($result)) | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "result.json is invalid UTF-8 JSON: $($_.Exception.Message)"
}
$properties = @($report.PSObject.Properties.Name)
if (($properties -join ',') -cne 'route,port,filename,literal') {
    throw "result.json properties or order are invalid: $($properties -join ',')"
}
if ([string]$report.route -cne 'app/(main)/page.tsx' -or
    [int]$report.port -ne 4317 -or
    [string]$report.filename -cne "O'Brien `$value [draft].txt" -or
    [string]$report.literal -cne 'a|b $HOME "quoted"') {
    throw 'result.json values are invalid.'
}

[Console]::Out.WriteLine('PASS: native PowerShell command-generation evaluation')
