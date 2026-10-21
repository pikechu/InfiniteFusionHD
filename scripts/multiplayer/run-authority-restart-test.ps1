[CmdletBinding()]
param([string]$GameRoot = '', [int]$Port = 18786)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $GameRoot) { $GameRoot = $repository }
$reviewPython = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
$run = 'authority-restart-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID
$base = Join-Path $repository "temp/multiplayer/$run"
$database = "$base.sqlite3"
$server = "http://127.0.0.1:$Port"
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
$actors = @{}
& $reviewPython (Join-Path $repository 'scripts/multiplayer/build.py') --root $GameRoot --check
if ($LASTEXITCODE -ne 0) { throw 'Complete and verify the source snapshot before launching native actors' }
$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
try { $portProbe.Server.ExclusiveAddressUse = $true; $portProbe.Start() }
catch { throw "Port $Port is occupied or unavailable" }
finally { $portProbe.Stop() }
$service = Start-Process -FilePath $reviewPython -ArgumentList @('-u', 'server/multiplayer/service.py', '--host', '127.0.0.1', '--port', $Port, '--database', $database) -WorkingDirectory $repository -WindowStyle Hidden -PassThru -RedirectStandardOutput "$base-service.log" -RedirectStandardError "$base-service-error.log"
function Start-Actor([string]$Role) {
    $profile = "$run-$Role"
    $stage = & (Join-Path $PSScriptRoot 'prepare-runtime.ps1') -Profile $profile -GameRoot $GameRoot -CustomScript (Join-Path $repository 'tests/multiplayer/authority_restart_game.rb')
    $oldSave, $oldProfile, $oldServer, $oldScenario = $env:KIF_MULTIPLAYER_SAVE_DIR, $env:KIF_MULTIPLAYER_PROFILE, $env:KIF_MULTIPLAYER_SERVER, $env:KIF_MULTIPLAYER_SCENARIO
    try {
        $env:KIF_MULTIPLAYER_SAVE_DIR = Join-Path $stage 'saves'
        $env:KIF_MULTIPLAYER_PROFILE = $profile
        $env:KIF_MULTIPLAYER_SERVER = $server
        $env:KIF_MULTIPLAYER_SCENARIO = $base
        $actor = Start-Process -FilePath (Join-Path $stage 'Game.exe') -WorkingDirectory $stage -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stage 'stdout.log') -RedirectStandardError (Join-Path $stage 'stderr.log')
        $processes.Add($actor)
        $actors[$Role] = $actor
        Write-Host "AUTHORITY_ACTOR_STARTED role=$Role pid=$($actor.Id) profile=$profile"
        return $actor
    } finally {
        $env:KIF_MULTIPLAYER_SAVE_DIR, $env:KIF_MULTIPLAYER_PROFILE, $env:KIF_MULTIPLAYER_SERVER, $env:KIF_MULTIPLAYER_SCENARIO = $oldSave, $oldProfile, $oldServer, $oldScenario
    }
}
function Wait-Marker([string]$Role, [string]$Key, [int]$Seconds) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $until) {
        foreach ($peer in @('host','guest','impostor','reader')) {
            $path = "$base.$peer.json"
            if (Test-Path -LiteralPath $path) {
                $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($value.stage -eq 'failed') { throw "Native actor $peer failed: $($value.error)" }
                if ($peer -eq $Role -and $value.$Key) { return $value }
            }
        }
        if ($actors.ContainsKey($Role)) {
            $actors[$Role].Refresh()
            if ($actors[$Role].HasExited) { throw "Native actor $Role exited before marker $Key; inspect $run-$Role stderr/log" }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out waiting for $Role.$Key (see $base.*.json)"
}
try {
    $until = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
        $service.Refresh()
        if ($service.HasExited) { throw "Service exited before health: $base-service-error.log" }
        try { $health = Invoke-RestMethod "$server/v1/health" -NoProxy -TimeoutSec 2; break }
        catch { if ([DateTime]::UtcNow -gt $until) { throw }; Start-Sleep -Milliseconds 200 }
    }
    $source = Get-Content -LiteralPath (Join-Path $GameRoot 'Data/Scripts/054_Multiplayer/001_Client.rb') -Raw
    $protocol = [int]([regex]::Match($source, 'PROTOCOL = ([0-9]+)').Groups[1].Value)
    if ($health.protocol -ne $protocol) { throw "Protocol mismatch: service=$($health.protocol), source=$protocol" }
    $authority = Start-Actor 'host'
    $guest = Start-Actor 'guest'
    $hostState = Wait-Marker 'host' 'killable' 240
    $impostor = Start-Actor 'impostor'
    $conflictState = Wait-Marker 'impostor' 'passed' 120
    if (-not $impostor.WaitForExit(5000) -or $impostor.ExitCode -ne 0) { throw 'Conflicting native process did not exit successfully' }
    # Explicitly terminate only this runner's known test authority process.
    $authority.Refresh()
    if ($authority.HasExited) { throw 'Authority exited before the deliberate process-death fault' }
    Stop-Process -Id $authority.Id
    $killedAt = [DateTime]::UtcNow.ToString('o')
    Write-Host "REAL_AUTHORITY_PROCESS_TERMINATED pid=$($authority.Id)"
    $reader = Start-Actor 'reader'
    $readerState = Wait-Marker 'reader' 'passed' 160
    $guestState = Wait-Marker 'guest' 'passed' 30
    foreach ($actor in @($reader,$guest)) {
        if (-not $actor.WaitForExit(5000) -or $actor.ExitCode -ne 0) { throw "Native actor $($actor.Id) did not exit 0" }
    }
    $rewardCount = & $reviewPython -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("SELECT COUNT(*) FROM rewards").fetchone()[0])' $database
    if ([int]$rewardCount -ne 0) { throw 'Process-death fixture incorrectly awarded a medal' }
    $evidence = [ordered]@{ passed=$true; protocol=$protocol; database=$database; actualAuthorityPid=$authority.Id; terminatedAt=$killedAt; impostor=$conflictState; restartedReader=$readerState; guest=$guestState; rewardCount=[int]$rewardCount }
    $evidence | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath "$base-evidence.json" -Encoding utf8
    Write-Output "AUTHORITY_RESTART_NATIVE_PASS evidence=$base-evidence.json"
} finally {
    foreach ($actor in $processes) {
        $actor.Refresh()
        if (-not $actor.HasExited) { Stop-Process -Id $actor.Id -ErrorAction SilentlyContinue }
    }
    $service.Refresh()
    if (-not $service.HasExited) { Stop-Process -Id $service.Id -ErrorAction SilentlyContinue }
}
