[CmdletBinding()]
param([string]$PythonExecutable = '', [int]$TimeoutSeconds = 180)
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $PythonExecutable) { $PythonExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' }
Push-Location $rootPath
$nativeProcess = $null
try {
    & $PythonExecutable scripts/multiplayer/build.py
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
    $profileName = 'catalog-' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
    $launch = & scripts/multiplayer/start-client.ps1 -Profile $profileName -CustomScript tests/multiplayer/rental_catalog_game.rb
    Write-Output $launch
    $nativeProcessId = [int]([regex]::Match(($launch -join "`n"), 'pid=(\d+)').Groups[1].Value)
    $nativeProcess = Get-Process -Id $nativeProcessId
    $null = $nativeProcess.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $nativeProcess.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200; $nativeProcess.Refresh() }
    if (-not $nativeProcess.HasExited -or $nativeProcess.ExitCode -ne 0) { throw "Native catalog export failed: $profileName" }
    & $PythonExecutable scripts/multiplayer/build.py --check
    if ($LASTEXITCODE -ne 0) { throw 'Catalog source changed during export' }
    Write-Output "NATIVE_CATALOG_REBUILD_PASS profile=$profileName"
} finally {
    if ($nativeProcess -and -not $nativeProcess.HasExited) { Stop-Process -Id $nativeProcess.Id -Force }
    Pop-Location
}
