[CmdletBinding()]
param([int]$MaximumModule = 999, [string]$Name = '')
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $Name) { $Name = 'snapshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid snapshot name' }
$snapshot = Join-Path $repository "temp/multiplayer/$Name"
if (Test-Path -LiteralPath $snapshot) { throw 'Snapshot already exists; choose a new name' }
[IO.Directory]::CreateDirectory((Join-Path $snapshot 'Data/Scripts')) | Out-Null
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $repository 'Data/Scripts') -File -Recurse)) {
    $relative = [IO.Path]::GetRelativePath((Join-Path $repository 'Data/Scripts'), $file.FullName)
    if ($relative -match '^054_Multiplayer[\\/]([0-9]{3})_' -and [int]$Matches[1] -gt $MaximumModule) { continue }
    $target = Join-Path $snapshot "Data/Scripts/$relative"
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
    [IO.File]::Copy($file.FullName, $target, $false)
}
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $repository 'Data') -File)) {
    if ($file.Name -eq 'multiplayer-build.json') { continue }
    New-Item -ItemType HardLink -Path (Join-Path $snapshot "Data/$($file.Name)") -Value $file.FullName | Out-Null
}
foreach ($folder in (Get-ChildItem -LiteralPath (Join-Path $repository 'Data') -Directory)) {
    if ($folder.Name -eq 'Scripts') { continue }
    New-Item -ItemType Junction -Path (Join-Path $snapshot "Data/$($folder.Name)") -Value $folder.FullName | Out-Null
}
foreach ($folder in @('Graphics','Audio','Fonts','scripts','tests')) {
    New-Item -ItemType Junction -Path (Join-Path $snapshot $folder) -Value (Join-Path $repository $folder) | Out-Null
}
[IO.Directory]::CreateDirectory((Join-Path $snapshot 'Mods')) | Out-Null
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $repository 'Mods') -File)) {
    [IO.File]::Copy($file.FullName, (Join-Path $snapshot "Mods/$($file.Name)"), $false)
}
[IO.File]::Copy((Join-Path $repository 'Game.ini'), (Join-Path $snapshot 'Game.ini'), $false)
Write-Output $snapshot
