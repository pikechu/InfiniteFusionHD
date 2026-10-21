[CmdletBinding()]
param(
    [ValidateRange(1024,65535)][int]$Port = 18785,
    [string]$GameRoot = '',
    [string]$PythonExecutable = '',
    [ValidateSet('Game.exe','Game-compatibility.exe')][string]$Executable = 'Game.exe',
    [int]$TimeoutSeconds = 600,
    [switch]$Visible
)
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$gameRootPath = if ($GameRoot) { [IO.Path]::GetFullPath($GameRoot) } else { $rootPath }
if (-not $PythonExecutable) { $PythonExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' }
$runId = '{0}-p{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Port, ([Guid]::NewGuid().ToString('N').Substring(0,8))
$base = Join-Path $rootPath "temp/multiplayer/pool-restart-$runId"
[IO.Directory]::CreateDirectory((Split-Path -Parent $base)) | Out-Null
$database = $base + '.sqlite3'
$url = "http://127.0.0.1:$Port"
$clients = @{}
$allClients = @()
$service = $null
$restarted = $false
$previousMode = $env:KIF_POOL_GAME_TEST
$env:KIF_POOL_GAME_TEST = 'restart'

function Read-Role([string]$RoleName) {
    $path = $base + ".$RoleName.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
            try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch { return $null }
}

function Start-OwnedClient([string]$RoleName, [bool]$IsRestart = $false) {
    $profileName = "pr-$RoleName-$runId"
    $arguments = @{Profile=$profileName; Server=$url; Scenario=$base; CustomScript=(Join-Path $rootPath 'tests/multiplayer/pool_collections_game_runner.rb'); GameRoot=$gameRootPath; Executable=$Executable}
    if ($Visible) { $arguments.Visible = $true }
    $output = & (Join-Path $PSScriptRoot 'start-client.ps1') @arguments
    Write-Output $output
    $match = [regex]::Match(($output -join "`n"), 'Started pid=(\d+)')
    if (-not $match.Success) { throw "Could not identify owned $RoleName client" }
    $ownedId = [int]$match.Groups[1].Value
    $ownedProcess = Get-Process -Id $ownedId -ErrorAction Stop
    $null = $ownedProcess.Handle # Retain while alive; ExitCode remains available after PID removal.
    $entry = [pscustomobject]@{role=$RoleName; process=$ownedProcess; id=$ownedId; restarted=$IsRestart}
    $script:allClients += $entry
    $clients[$RoleName] = $entry
}

function Wait-OwnedExit($Entry, [int]$Expected) {
    if (-not $Entry.process.WaitForExit(10000)) { throw "Owned $($Entry.role) wrote terminal state without exiting" }
    if ($null -eq $Entry.process.ExitCode -or $Entry.process.ExitCode -ne $Expected) {
        throw "Owned $($Entry.role) pid=$($Entry.id) exit=$($Entry.process.ExitCode); expected $Expected"
    }
}

try {
    & $PythonExecutable (Join-Path $PSScriptRoot 'build.py') --root $gameRootPath --check
    if ($LASTEXITCODE -ne 0) { throw 'Multiplayer source manifest is stale' }
    $manifest = Get-Content -LiteralPath (Join-Path $gameRootPath 'Data/multiplayer-build.json') -Raw | ConvertFrom-Json
    # Do not attach to or stop a service belonging to another task.
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $probe.Start() } finally { $probe.Stop() }
    $serviceArguments = @(('"' + (Join-Path $gameRootPath 'server/multiplayer/service.py') + '"'), '--host', '127.0.0.1', '--port', "$Port", '--database', ('"' + $database + '"'), '--log-file', ('"' + $base + '.service.log"'))
    $service = Start-Process -FilePath $PythonExecutable -ArgumentList $serviceArguments -WorkingDirectory $rootPath -WindowStyle Hidden -PassThru -RedirectStandardOutput ($base + '.service.stdout.log') -RedirectStandardError ($base + '.service.stderr.log')
    $null = $service.Handle
    $healthy = $false
    $healthDeadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        if ($service.HasExited) { throw "Owned service exited; inspect $base.service.stderr.log" }
        try {
            $health = Invoke-RestMethod -Uri ($url + '/v1/health') -TimeoutSec 2
            if ($health.ok -and $health.protocol -eq 2 -and -not $service.HasExited) { $healthy = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $healthDeadline)
    if (-not $healthy) { throw 'Owned service did not become healthy' }
    Write-Output "POOL_RESTART_RUN id=$runId service=$url database=$database"
    Start-OwnedClient 'host'
    Start-OwnedClient 'guest'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $hostState = Read-Role 'host'
        $guestState = Read-Role 'guest'
        if (-not $restarted -and $guestState -and $guestState.crash_after_save -and $clients['guest'].process.HasExited) {
            Wait-OwnedExit $clients['guest'] 1
            Write-Output "EXPECTED_INTERRUPTION role=guest pid=$($clients['guest'].id) exit=1 tx=$($guestState.transaction_id)"
            Start-OwnedClient 'guest' $true
            $restarted = $true
        }
        foreach ($roleName in @('host','guest')) {
            $state = if ($roleName -eq 'host') { $hostState } else { $guestState }
            if ($clients[$roleName].process.HasExited -and (-not $state -or -not $state.finished)) {
                if ($roleName -eq 'guest' -and -not $restarted -and $state.crash_after_save) { continue }
                throw "Owned $roleName exited before final PASS, exit=$($clients[$roleName].process.ExitCode)"
            }
        }
        if ($restarted -and $hostState.finished -and $guestState.finished) {
            Wait-OwnedExit $clients['host'] 0
            Wait-OwnedExit $clients['guest'] 0
            if ($hostState.transaction_id -ne $guestState.transaction_id) { throw 'Clients disagree on transaction ID' }
            foreach ($state in @($hostState,$guestState)) {
                if ($state.party_count -ne 3 -or $state.marker_count -ne 1 -or $state.pending -or $state.escrow -or $state.backend -ne 'core_socket' -or $state.data_hash -ne $manifest.data_hash -or -not $state.saved_ui_options_preserved) { throw 'Native final inventory, journal, transport, source binding or saved settings is invalid' }
            }
            & $PythonExecutable (Join-Path $rootPath 'tests/multiplayer/pool_restart_audit.py') $database ($base + '.db-audit.json')
            if ($LASTEXITCODE -ne 0) { throw 'Read-only final database audit failed' }
            $audit = Get-Content -LiteralPath ($base + '.db-audit.json') -Raw | ConvertFrom-Json
            # Evidence is explicitly allowlisted: never copy tokens, account
            # configuration, recovery codes, full coordinator snapshots or saves.
            $safeClients = @(@($hostState,$guestState) | ForEach-Object { [ordered]@{role=if ($_.player_id -eq $hostState.player_id) {'host'} else {'guest'}; player_id=$_.player_id; party_count=$_.party_count; marker_count=$_.marker_count; pending=$_.pending; escrow=$_.escrow; backend=$_.backend; checks=$_.checks; transaction_id=$_.transaction_id; saved_ui_options_preserved=$_.saved_ui_options_preserved} })
            $processes = @($allClients | ForEach-Object { [ordered]@{role=$_.role; pid=$_.id; restarted=$_.restarted; expected_interruption=($_.role -eq 'guest' -and -not $_.restarted); exit_code=$_.process.ExitCode} })
            $evidence = [ordered]@{overall_pass=$true; run_id=$runId; local_only=$true; manual_ui=$false; cross_machine_lan=$false; executable=$Executable; manifest_data_hash=$manifest.data_hash; service_pid=$service.Id; transaction_id=$hostState.transaction_id; restarted_same_isolated_save=$true; clients=$safeClients; processes=$processes; db_audit=$audit}
            [IO.File]::WriteAllText(($base + '.evidence.json'), ($evidence | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $total = [int]$hostState.checks + [int]$guestState.checks + [int]$guestState.pre_crash_checks
            Write-Output "POOL_RESTART_NATIVE_ALL_PASS checks=$total evidence=$base.evidence.json"
            exit 0
        }
        Start-Sleep -Milliseconds 400
    }
    throw "Pool restart test exceeded $TimeoutSeconds seconds"
} catch {
    $failure = [ordered]@{overall_pass=$false; run_id=$runId; local_only=$true; failure=$_.Exception.Message; restarted=$restarted}
    [IO.File]::WriteAllText(($base + '.failure.json'), ($failure | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    throw
} finally {
    foreach ($entry in $allClients) {
        if (-not $entry.process.HasExited) { Stop-Process -Id $entry.id -Force -ErrorAction SilentlyContinue }
    }
    if ($service -and -not $service.HasExited) { Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue }
    $env:KIF_POOL_GAME_TEST = $previousMode
    Write-Output "POOL_RESTART_ARTIFACTS_PRESERVED $base"
}
