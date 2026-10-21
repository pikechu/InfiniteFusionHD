[CmdletBinding()]
param(
    [string]$Server = 'http://127.0.0.1:8765',
    [int]$TimeoutSeconds = 900,
    [switch]$Faults,
    [switch]$DifferentSpeed,
    [switch]$ExpectRestart,
    [switch]$RestartService,
    [string]$PythonExecutable = ''
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $PythonExecutable) {
    $PythonExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
    if (-not (Test-Path -LiteralPath $PythonExecutable)) { $PythonExecutable = 'python' }
}
Push-Location $repository
$previousFaults = $env:KIF_MULTIPLAYER_FAULTS
$previousSpeed = $env:KIF_MULTIPLAYER_DIFFERENT_SPEED
$previousRestart = $env:KIF_MULTIPLAYER_EXPECT_RESTART
$ownedService = $null
try {
    if ($RestartService) { $ExpectRestart = $true }
    if ($Faults) { $env:KIF_MULTIPLAYER_FAULTS = '1' } else { $env:KIF_MULTIPLAYER_FAULTS = '0' }
    if ($DifferentSpeed) { $env:KIF_MULTIPLAYER_DIFFERENT_SPEED = '1' } else { $env:KIF_MULTIPLAYER_DIFFERENT_SPEED = '0' }
    if ($ExpectRestart) { $env:KIF_MULTIPLAYER_EXPECT_RESTART = '1' } else { $env:KIF_MULTIPLAYER_EXPECT_RESTART = '0' }
    & $PythonExecutable (Join-Path $PSScriptRoot 'build.py')
    if ($LASTEXITCODE -ne 0) { throw 'Multiplayer manifest build failed' }
    $runId = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($RestartService) {
        $serviceScript = Join-Path $repository 'server/multiplayer/service.py'
        $testDatabase = Join-Path $repository "temp/multiplayer/restart-$runId.sqlite3"
        $serviceArguments = @('-u', ('"' + $serviceScript + '"'), '--host', '127.0.0.1', '--port', '18768', '--database', ('"' + $testDatabase + '"'))
        $serviceOutput = Join-Path $repository "temp/multiplayer/restart-$runId-service.log"
        $serviceError = Join-Path $repository "temp/multiplayer/restart-$runId-service-error.log"
        $ownedService = Start-Process -FilePath $PythonExecutable -ArgumentList $serviceArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $serviceOutput -RedirectStandardError $serviceError
        $Server = 'http://127.0.0.1:18768'
        $healthDeadline = [DateTime]::UtcNow.AddSeconds(45)
        while ($true) {
            $ownedService.Refresh()
            if ($ownedService.HasExited) { throw "Test service exited; inspect $serviceError" }
            try { $null = Invoke-RestMethod "$Server/v1/health" -NoProxy -TimeoutSec 2; break }
            catch { if ([DateTime]::UtcNow -gt $healthDeadline) { throw }; Start-Sleep -Milliseconds 200 }
        }
    }
    $coordination = Join-Path $repository "temp/multiplayer/scenario-$runId.json"
    $hostProfile = "verify-host-$runId"
    $guestProfile = "verify-guest-$runId"
    & (Join-Path $PSScriptRoot 'start-client.ps1') -Profile $hostProfile -Server $Server -Scenario $coordination -CustomScript (Join-Path $PSScriptRoot 'game-smoke.rb')
    & (Join-Path $PSScriptRoot 'start-client.ps1') -Profile $guestProfile -Server $Server -Scenario $coordination -CustomScript (Join-Path $PSScriptRoot 'game-smoke.rb')
    $logs = @($hostProfile, $guestProfile) | ForEach-Object { Join-Path $repository "temp/multiplayer/$_/saves/game-smoke.log" }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $restarted = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($RestartService -and -not $restarted -and (Test-Path -LiteralPath $logs[0])) {
            $hostContents = Get-Content -LiteralPath $logs[0] -Raw
            if ($hostContents -match '(?s)BATTLE_BEGIN match=2.*EVENT engine_started') {
                Start-Sleep -Seconds 1
                $oldServiceId = $ownedService.Id
                Stop-Process -Id $oldServiceId
                $ownedService.WaitForExit()
                $ownedService = Start-Process -FilePath $PythonExecutable -ArgumentList $serviceArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput ($serviceOutput + '.restarted') -RedirectStandardError ($serviceError + '.restarted')
                Write-Output "SERVICE_RESTART old_pid=$oldServiceId new_pid=$($ownedService.Id) trigger=second_battle_engine_started"
                $restarted = $true
            }
        }
        $passed = 0
        foreach ($log in $logs) {
            if (-not (Test-Path -LiteralPath $log)) { continue }
            $contents = Get-Content -LiteralPath $log -Raw
            if ($contents -match 'GAME_SMOKE_FAIL') { throw "Game integration failed; inspect $log" }
            if ($contents -match 'GAME_SMOKE_PASS') { $passed++ }
        }
        if ($passed -eq 2) {
            Write-Output 'TWO_GAME_PROCESS_PASS (automated game input; manual UI and cross-machine acceptance remain separate)'
            $logs | ForEach-Object { Write-Output $_ }
            if (-not $ExpectRestart) {
                & $PythonExecutable (Join-Path $repository 'tests/multiplayer/verify_game_evidence.py') --host $logs[0] --guest $logs[1] --output (Join-Path $repository "temp/multiplayer/verify-evidence-$runId.json")
                if ($LASTEXITCODE -ne 0) { throw 'Two-game public state or settlement evidence did not match' }
            } else {
                Write-Output 'Expected-restart run: inspect BATTLE_ABORT_PASS and identical official service_restart result in both logs.'
            }
            exit 0
        }
        Start-Sleep -Seconds 2
    }
    throw "Game integration timed out; inspect $($logs -join ', ')"
} finally {
    if ($ownedService -and -not $ownedService.HasExited) { Stop-Process -Id $ownedService.Id }
    $env:KIF_MULTIPLAYER_FAULTS = $previousFaults
    $env:KIF_MULTIPLAYER_DIFFERENT_SPEED = $previousSpeed
    $env:KIF_MULTIPLAYER_EXPECT_RESTART = $previousRestart
    Pop-Location
}
