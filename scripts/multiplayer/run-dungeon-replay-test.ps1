[CmdletBinding()]
param(
    [int]$Port = 18782,
    [string]$GameRoot = '',
    [string]$PythonExecutable = '',
    [ValidateSet('Game.exe','Game-compatibility.exe')][string]$Executable = 'Game.exe',
    [int]$TimeoutSeconds = 1800,
    [switch]$FaultOnly,
    [switch]$GcProbe,
    [switch]$NoCapture,
    [switch]$Visible
)
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$gameRootPath = if ($GameRoot) { [IO.Path]::GetFullPath($GameRoot) } else { $rootPath }
if (-not $PythonExecutable) {
    $PythonExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
}
$runId = '{0}-p{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Port, ([Guid]::NewGuid().ToString('N').Substring(0,8))
$coordBase = Join-Path $rootPath "temp/multiplayer/dungeon-replay-$runId"
$database = $coordBase + '.sqlite3'
$scenario = Join-Path $rootPath 'tests/multiplayer/dungeon_replay_game.rb'
$url = "http://127.0.0.1:$Port"
$clientRuns = @{}
$serviceRuns = @()
$serverRun = $null
$restartDone = $false
$viewerStarted = $false
$lastStages = @{}
$generation = 0
$previousFaultMode = $env:KIF_DUNGEON_FAULT_ONLY
$previousGcMode = $env:KIF_DUNGEON_GC_PROBE
$previousCaptureMode = $env:KIF_DUNGEON_NO_CAPTURE
$env:KIF_DUNGEON_FAULT_ONLY = if ($FaultOnly) { '1' } else { '0' }
$env:KIF_DUNGEON_GC_PROBE = if ($GcProbe) { '1' } else { '0' }
$env:KIF_DUNGEON_NO_CAPTURE = if ($NoCapture) { '1' } else { '0' }

function Read-Role([string]$RoleName) {
    $filePath = $coordBase + ".$RoleName.json"
    if (-not (Test-Path -LiteralPath $filePath)) { return $null }
    try {
        # Permit the native test's atomic rename while this reader is open.
        $stream = [IO.File]::Open($filePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
            try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
            finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    }
    catch { return $null } # Atomic writer may have replaced the file during this read.
}

function Start-LocalService {
    $script:generation += 1
    $arguments = @((Join-Path $gameRootPath 'server/multiplayer/service.py'), '--host', '127.0.0.1', '--port', "$Port", '--database', $database, '--log-file', ($coordBase + '.service.log'))
    $script:serverRun = Start-Process -FilePath $PythonExecutable -ArgumentList $arguments -WorkingDirectory $rootPath -WindowStyle Hidden -PassThru -RedirectStandardOutput ($coordBase + ".service-$generation.stdout.log") -RedirectStandardError ($coordBase + ".service-$generation.stderr.log")
    $script:serviceRuns += $script:serverRun.Id
    $healthDeadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ($script:serverRun.HasExited) { throw "Owned test service exited: $($coordBase).service-$generation.stderr.log" }
        try {
            $health = Invoke-RestMethod -Uri ($url + '/v1/health') -TimeoutSec 2
            if ($health.ok -and $health.protocol -eq 2) { return }
        } catch { }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $healthDeadline)
    throw 'Owned test service did not become healthy'
}

function Start-TestClient([string]$RoleName) {
    $profileName = "dr-$RoleName-$runId" # Profile schema permits at most 48 characters.
    $launchArguments = @{Profile=$profileName; Server=$url; Scenario=$coordBase; CustomScript=$scenario; GameRoot=$gameRootPath; Executable=$Executable}
    if ($Visible) { $launchArguments.Visible = $true }
    $output = & (Join-Path $PSScriptRoot 'start-client.ps1') @launchArguments
    Write-Output $output
    $match = [regex]::Match(($output -join "`n"), 'Started pid=(\d+)')
    if (-not $match.Success) { throw "Could not identify the owned $RoleName Game.exe" }
    $gameProcessId = [int]$match.Groups[1].Value
    $gameProcess = Get-Process -Id $gameProcessId
    # Get-Process does not retain a native handle by default. Opening it while
    # this exact child is alive preserves its exit code after Windows removes
    # the PID; without it WaitForExit can succeed but ExitCode remains null.
    $null = $gameProcess.Handle
    $clientRuns[$RoleName] = [pscustomobject]@{process=$gameProcess; profile=$profileName; id=$gameProcessId}
}

try {
    & $PythonExecutable (Join-Path $PSScriptRoot 'build.py') --root $gameRootPath --check
    if ($LASTEXITCODE -ne 0) { throw 'Source build is stale; do not run against an old manifest' }
    $manifest = Get-Content -LiteralPath (Join-Path $gameRootPath 'Data/multiplayer-build.json') -Raw | ConvertFrom-Json
    $catalogPath = Join-Path $gameRootPath 'server/multiplayer/catalog-rental-v1.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    if ($manifest.data_hash -ne $catalog.compatibility.data_hash -or $manifest.mods_hash -ne $catalog.compatibility.mods_hash) {
        throw 'Game manifest and installed trusted catalog differ; rerun native catalog export first'
    }
    Write-Output "DUNGEON_REPLAY_RUN id=$runId service=$url database=$database"
    Start-LocalService
    Start-TestClient 'host'
    Start-TestClient 'guest'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $hostState = Read-Role 'host'
        $guestState = Read-Role 'guest'
        foreach ($roleName in @($clientRuns.Keys)) {
            $state = Read-Role $roleName
            if ($state -and $state.stage -ne $lastStages[$roleName]) {
                Write-Output "STAGE role=$roleName stage=$($state.stage) checks=$($state.checks)"
                $lastStages[$roleName] = $state.stage
            }
            if ($state -and $state.stage -eq 'failed') { throw "Native $roleName failed: $($state.error)" }
            if ($clientRuns[$roleName].process.HasExited -and (-not $state -or -not $state.finished)) {
                throw "Native $roleName exited code=$($clientRuns[$roleName].process.ExitCode) before PASS; see temp/multiplayer/$($clientRuns[$roleName].profile)/saves/feature-smoke.log"
            }
        }
        if (-not $FaultOnly -and -not $viewerStarted -and $hostState -and $hostState.replay_published) {
            Start-TestClient 'viewer'
            $viewerStarted = $true
        }
        if (-not $restartDone -and $hostState -and $hostState.stage -eq 'fault_wait_restart' -and $guestState.fault_guest_paused) {
            $oldServerId = $serverRun.Id
            Stop-Process -Id $oldServerId -Force # Only the exact service created above.
            $serverRun.WaitForExit()
            Start-LocalService
            $restartReceipt = [ordered]@{old_pid=$oldServerId; new_pid=$serverRun.Id; database=$database; restarted_at=[DateTime]::UtcNow.ToString('o')}
            $restartPath = $coordBase + '.service-restarted.json'
            [IO.File]::WriteAllText($restartPath + '.pending', ($restartReceipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($restartPath + '.pending', $restartPath)
            $restartDone = $true
            Write-Output "SERVICE_RESTARTED old_pid=$oldServerId new_pid=$($serverRun.Id)"
        }
        $viewerState = if ($viewerStarted) { Read-Role 'viewer' } else { $null }
        if ($restartDone -and $hostState.finished -and $guestState.finished -and ($FaultOnly -or $viewerState.finished)) {
            foreach ($entry in $clientRuns.Values) {
                if (-not $entry.process.WaitForExit(10000)) { throw "Native process $($entry.id) wrote finished but did not exit" }
                if ($null -eq $entry.process.ExitCode) { throw "Native process $($entry.id) exit code is unavailable despite its retained handle" }
                if ($entry.process.ExitCode -ne 0) { throw "Native process $($entry.id) wrote finished but exited code=$($entry.process.ExitCode)" }
            }
            $clientEvidence = @($hostState,$guestState)
            if ($viewerState) { $clientEvidence += $viewerState }
            $clientProcesses = @($clientRuns.GetEnumerator() | ForEach-Object { [ordered]@{role=$_.Key; pid=$_.Value.id; exit_code=$_.Value.process.ExitCode} })
            $evidence = [ordered]@{run_id=$runId; overall_pass=$true; executable=$Executable; capture_images=(-not [bool]$NoCapture); fault_only=[bool]$FaultOnly; gc_probe=[bool]$GcProbe; local_only=$true; manual_ui=$false; cross_machine_lan=$false; source_root=$gameRootPath; checkout_root=$rootPath; manifest_data_hash=$manifest.data_hash; catalog_sha256=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLower(); service_pids=$serviceRuns; database=$database; client_processes=$clientProcesses; clients=$clientEvidence}
            $evidencePath = $coordBase + '.evidence.json'
            [IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 80), [Text.UTF8Encoding]::new($false))
            $total = [int]$hostState.checks + [int]$guestState.checks
            if ($viewerState) { $total += [int]$viewerState.checks }
            $passLabel = if ($FaultOnly) { 'DUNGEON_RECOVERY_NATIVE_ALL_PASS' } else { 'DUNGEON_REPLAY_NATIVE_ALL_PASS' }
            Write-Output "$passLabel checks=$total evidence=$evidencePath"
            exit 0
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Native Dungeon/Replay verification timed out after $TimeoutSeconds seconds"
} catch {
    $failureMessage = $_.Exception.Message
    $states = @($clientRuns.Keys | ForEach-Object { Read-Role $_ })
    $partialEvidence = [ordered]@{run_id=$runId; overall_pass=$false; executable=$Executable; capture_images=(-not [bool]$NoCapture); failure=$failureMessage; fault_only=[bool]$FaultOnly; gc_probe=[bool]$GcProbe; local_only=$true; manual_ui=$false; cross_machine_lan=$false; source_root=$gameRootPath; checkout_root=$rootPath; manifest_data_hash=$manifest.data_hash; service_pids=$serviceRuns; database=$database; clients=$states}
    [IO.File]::WriteAllText(($coordBase + '.partial-evidence.json'), ($partialEvidence | ConvertTo-Json -Depth 80), [Text.UTF8Encoding]::new($false))
    throw
} finally {
    foreach ($entry in $clientRuns.Values) {
        if (-not $entry.process.HasExited) { Stop-Process -Id $entry.id -Force -ErrorAction SilentlyContinue }
    }
    if ($serverRun -and -not $serverRun.HasExited) { Stop-Process -Id $serverRun.Id -Force -ErrorAction SilentlyContinue }
    $env:KIF_DUNGEON_FAULT_ONLY = $previousFaultMode
    $env:KIF_DUNGEON_GC_PROBE = $previousGcMode
    $env:KIF_DUNGEON_NO_CAPTURE = $previousCaptureMode
    Write-Output "TEST_ARTIFACTS_PRESERVED $coordBase"
}
