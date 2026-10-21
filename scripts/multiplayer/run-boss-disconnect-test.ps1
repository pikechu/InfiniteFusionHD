[CmdletBinding()]
param([string]$GameRoot = '', [int]$Port = 18783, [int]$TimeoutSeconds = 420)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bossPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$run = 'boss-disconnect-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$database = Join-Path $repository "temp/multiplayer/$run.sqlite3"
$outLog = Join-Path $repository "temp/multiplayer/$run-service.log"
$errLog = Join-Path $repository "temp/multiplayer/$run-service-error.log"
$service = Start-Process -FilePath $bossPython -ArgumentList @('-u', 'server/multiplayer/service.py', '--host', '127.0.0.1', '--port', $Port, '--database', $database) -WorkingDirectory $repository -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
try {
    $server = "http://127.0.0.1:$Port"
    $until = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
        try { $null = Invoke-RestMethod "$server/v1/health" -NoProxy -TimeoutSec 2; break }
        catch { if ([DateTime]::UtcNow -gt $until) { throw }; Start-Sleep -Milliseconds 200 }
    }
    $coordination = Join-Path $repository "temp/multiplayer/$run.json"
    $profiles = @("$run-host", "$run-guest")
    foreach ($profile in $profiles) {
        & (Join-Path $PSScriptRoot 'start-client.ps1') -Profile $profile -Server $server -GameRoot $GameRoot -Scenario $coordination -CustomScript (Join-Path $repository 'tests/multiplayer/boss_disconnect_game.rb')
    }
    $logs = @($profiles | ForEach-Object { Join-Path $repository "temp/multiplayer/$_/saves/boss-disconnect.log" })
    Write-Output "DEFAULT_60_SECOND_BUDGET_TEST run=$run database=$database"
    $until = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $until) {
        $passed = 0
        foreach ($log in $logs) {
            if (-not (Test-Path -LiteralPath $log)) { continue }
            $contents = Get-Content -LiteralPath $log -Raw
            if ($contents -match 'BOSS_DISCONNECT_GAME_FAIL') { throw "Boss recovery game failed: $log" }
            if ($contents -match 'BOSS_DISCONNECT_GAME_PASS') { $passed++ }
        }
        if ($passed -eq 2) {
            Write-Output 'BOSS_DEFAULT_BUDGET_TWO_GAME_PASS'
            $logs | ForEach-Object { Write-Output $_ }
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Boss recovery game timed out: $($logs -join ', ')"
} finally {
    $service.Refresh()
    if (-not $service.HasExited) { Stop-Process -Id $service.Id }
}
