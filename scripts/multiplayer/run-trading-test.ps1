[CmdletBinding()]
param([int]$Port = 18812, [int]$TimeoutSeconds = 240, [string]$PythonExecutable = '')
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $PythonExecutable) { $PythonExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' }
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$runDirectory = Join-Path $rootPath "temp/multiplayer/trading-$runId"
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$processes = @()
$serverProcess = $null
Push-Location $rootPath
try {
    & $PythonExecutable scripts/multiplayer/build.py
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
    function Start-ClientProcess([string]$Profile, [string]$Script, [string]$Scenario = '') {
        $launch = & scripts/multiplayer/start-client.ps1 -Profile $Profile -Server "http://127.0.0.1:$Port" -Scenario $Scenario -CustomScript $Script
        Write-Host ($launch -join "`n")
        $nativePid = [int]([regex]::Match(($launch -join "`n"), 'pid=(\d+)').Groups[1].Value)
        $nativeProcess = Get-Process -Id $nativePid
        $null = $nativeProcess.Handle
        return $nativeProcess
    }
    function Wait-Native([Diagnostics.Process]$NativeProcess, [int]$Expected = 0) {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $NativeProcess.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250; $NativeProcess.Refresh() }
        if (-not $NativeProcess.HasExited -or $NativeProcess.ExitCode -ne $Expected) { throw "Native process failed pid=$($NativeProcess.Id) expected=$Expected actual=$($NativeProcess.ExitCode); evidence=$runDirectory" }
    }
    $catalog = Start-ClientProcess "trading-catalog-$runId" 'tests/multiplayer/rental_catalog_game.rb'
    $processes += $catalog
    Wait-Native $catalog
    & $PythonExecutable tests/multiplayer/trading_native_fixture.py $rootPath $runDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Fixture setup failed' }
    $serverProcess = Start-Process -FilePath $PythonExecutable -ArgumentList @('server/multiplayer/service.py', '--port', "$Port", '--database', (Join-Path $runDirectory 'service.sqlite3')) -WorkingDirectory $rootPath -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runDirectory 'server.stdout.log') -RedirectStandardError (Join-Path $runDirectory 'server.stderr.log')
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
    do { try { $health = Invoke-RestMethod "http://127.0.0.1:$Port/v1/health"; break } catch { Start-Sleep -Milliseconds 150 } } while ([DateTime]::UtcNow -lt $readyDeadline -and -not $serverProcess.HasExited)
    if (-not $health.ok) { throw 'Isolated service did not start' }
    $scenario = Join-Path $runDirectory 'scenario.json'
    $hostProcess = Start-ClientProcess "trading-host-$runId" 'tests/multiplayer/trading_game.rb' $scenario
    $guestProcess = Start-ClientProcess "trading-guest-$runId" 'tests/multiplayer/trading_game.rb' $scenario
    $processes += @($hostProcess, $guestProcess)
    Wait-Native $guestProcess 23
    if (-not (Test-Path -LiteralPath (Join-Path $runDirectory 'guest-restart-required.json'))) { throw 'Missing real crash marker' }
    $restoredProcess = Start-ClientProcess "trading-guest-$runId" 'tests/multiplayer/trading_game.rb' $scenario
    $processes += $restoredProcess
    Wait-Native $restoredProcess
    Wait-Native $hostProcess
    foreach ($name in @('host-pass','guest-pass')) { if (-not (Test-Path -LiteralPath (Join-Path $runDirectory "$name.json"))) { throw "Missing $name" } }
    Write-Output "TRADING_NATIVE_PASS evidence=$runDirectory"
} finally {
    foreach ($nativeProcess in $processes) { if ($nativeProcess -and -not $nativeProcess.HasExited) { Stop-Process -Id $nativeProcess.Id -Force } }
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force }
    Pop-Location
}
