[CmdletBinding()]
param([int]$Port = 18796, [int]$TimeoutSeconds = 180, [string]$PythonExecutable = '')
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $PythonExecutable) { $PythonExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' }
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$runDirectory = Join-Path $rootPath "temp/multiplayer/world-online-$runId"
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$configPath = Join-Path $runDirectory 'scenario.json'
@{ run_id = $runId; directory = $runDirectory.Replace('\', '/') } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
$serverProcess = $null
$gameProcesses = @()
Push-Location $rootPath
try {
    & $PythonExecutable (Join-Path $PSScriptRoot 'build.py')
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
    $serverArguments = @('server/multiplayer/service.py', '--host', '127.0.0.1', '--port', "$Port", '--database', (Join-Path $runDirectory 'service.sqlite3'))
    $serverProcess = Start-Process -FilePath $PythonExecutable -ArgumentList $serverArguments -WorkingDirectory $rootPath -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runDirectory 'service.stdout.log') -RedirectStandardError (Join-Path $runDirectory 'service.stderr.log')
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        try { $health = Invoke-RestMethod "http://127.0.0.1:$Port/v1/health"; break } catch { Start-Sleep -Milliseconds 200 }
    } while ([DateTime]::UtcNow -lt $readyDeadline -and -not $serverProcess.HasExited)
    if (-not $health.ok) { throw 'Isolated server did not start' }
    function Start-NativeClient([string]$Role) {
        $profileName = "world-$Role-$runId"
        $output = & (Join-Path $PSScriptRoot 'start-client.ps1') -Profile $profileName -Server "http://127.0.0.1:$Port" -Scenario $configPath -CustomScript tests/multiplayer/world_online_game.rb
        Write-Output $output
        $processId = [int]([regex]::Match(($output -join "`n"), 'pid=(\d+)').Groups[1].Value)
        $nativeProcess = Get-Process -Id $processId
        $null = $nativeProcess.Handle  # Retain a handle before exit so ExitCode remains available.
        return $nativeProcess
    }
    # Start-NativeClient prints the launch item, so select the Process object.
    $gameProcesses += Start-NativeClient 'host' | Where-Object { $_ -is [Diagnostics.Process] }
    $gameProcesses += Start-NativeClient 'guest' | Where-Object { $_ -is [Diagnostics.Process] }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    foreach ($process in $gameProcesses) {
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 300; $process.Refresh() }
        if (-not $process.HasExited) { throw "Native client timeout pid=$($process.Id)" }
        if ($process.ExitCode -ne 0) { throw "Native client failed pid=$($process.Id); inspect $runDirectory and profile feature-smoke.log" }
    }
    $restore = Start-NativeClient 'restore' | Where-Object { $_ -is [Diagnostics.Process] }
    $gameProcesses += $restore
    while (-not $restore.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 300; $restore.Refresh() }
    if (-not $restore.HasExited -or $restore.ExitCode -ne 0) { throw 'Fresh-device cloud restore failed' }
    foreach ($marker in @('host-pass', 'guest-pass', 'restore-pass', 'host-isolation', 'host-render', 'guest-render')) {
        if (-not (Test-Path -LiteralPath (Join-Path $runDirectory "$marker.json"))) { throw "Missing native proof: $marker" }
    }
    Write-Output "WORLD_ONLINE_NATIVE_PASS evidence=$runDirectory"
} finally {
    foreach ($process in $gameProcesses) { if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force } }
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force }
    Pop-Location
}
