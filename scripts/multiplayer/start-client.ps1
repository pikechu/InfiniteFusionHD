[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Profile = 'player-a',
    [string]$Server = '',
    [string]$Scenario = '',
    [string]$CustomScript = '',
    [string]$GameRoot = '',
    [switch]$Visible,
    [ValidateSet('Game.exe','Game-compatibility.exe')][string]$Executable = 'Game.exe'
)
$ErrorActionPreference = 'Stop'
$stage = & (Join-Path $PSScriptRoot 'prepare-runtime.ps1') -Profile $Profile -Executable $Executable -CustomScript $CustomScript -GameRoot $GameRoot
$previousSaveDirectory = $env:KIF_MULTIPLAYER_SAVE_DIR
$previousProfile = $env:KIF_MULTIPLAYER_PROFILE
$previousServer = $env:KIF_MULTIPLAYER_SERVER
$previousScenario = $env:KIF_MULTIPLAYER_SCENARIO
try {
    $env:KIF_MULTIPLAYER_SAVE_DIR = Join-Path $stage 'saves'
    $env:KIF_MULTIPLAYER_PROFILE = $Profile
    # An explicit command-line server overrides the profile. With no argument,
    # preserve the server selected in the game's settings across launches.
    if ($Server) { $env:KIF_MULTIPLAYER_SERVER = $Server }
    if ($Scenario) { $env:KIF_MULTIPLAYER_SCENARIO = [IO.Path]::GetFullPath($Scenario) }
    $windowStyle = if ($Visible) { 'Normal' } else { 'Hidden' }
    $process = Start-Process -FilePath (Join-Path $stage 'Game.exe') -WorkingDirectory $stage -PassThru -WindowStyle $windowStyle -RedirectStandardOutput (Join-Path $stage 'stdout.log') -RedirectStandardError (Join-Path $stage 'stderr.log')
    Write-Output "Started pid=$($process.Id) profile=$Profile log=$stage"
} finally {
    $env:KIF_MULTIPLAYER_SAVE_DIR = $previousSaveDirectory
    $env:KIF_MULTIPLAYER_PROFILE = $previousProfile
    $env:KIF_MULTIPLAYER_SERVER = $previousServer
    $env:KIF_MULTIPLAYER_SCENARIO = $previousScenario
}
