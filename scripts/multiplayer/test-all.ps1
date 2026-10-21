[CmdletBinding()]
param(
    [string]$PythonExecutable = '',
    [string]$RubyExecutable = '',
    [switch]$SkipService
)
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $PythonExecutable) {
    $PythonExecutable = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
}
if (-not $RubyExecutable) {
    $RubyExecutable = Join-Path $rootPath 'temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe'
}
if (-not $SkipService -and -not (Test-Path -LiteralPath $PythonExecutable)) { throw 'Pass -PythonExecutable with your Python 3 executable.' }
if (-not (Test-Path -LiteralPath $RubyExecutable)) { throw 'Pass -RubyExecutable with your standalone Ruby executable.' }
Push-Location $rootPath
try {
    if (-not $SkipService) {
        & $PythonExecutable -m unittest discover -s server/multiplayer -p 'test_*.py' -q
        if ($LASTEXITCODE -ne 0) { throw 'Multiplayer service tests failed.' }
    }
    foreach ($suite in @('client', 'identity_recovery', 'reconnect_journal', 'snapshot_rules', 'scene_restore', 'battle', 'battle_confirmation', 'boss', 'authority_session', 'guest_scene', 'guest_visual_divergence', 'battle_board', 'gym_dungeon_replay', 'gym_orphan_recovery', 'trade', 'transaction_recovery', 'rental', 'hall', 'hall_invite_recovery', 'pool', 'collections', 'cards', 'transport', 'cross_platform', 'online', 'android_network')) {
        $testPath = Join-Path $rootPath "tests/multiplayer/${suite}_test.rb"
        & $RubyExecutable --disable-gems $testPath
        if ($LASTEXITCODE -ne 0) { throw "Multiplayer Ruby suite failed: $suite" }
    }
    if ($SkipService) { Write-Output 'MULTIPLAYER_RUBY_TESTS_PASS (service and real Game.exe acceptance are separate runs)' }
    else { Write-Output 'MULTIPLAYER_UNIT_TESTS_PASS (real Game.exe acceptance is a separate run)' }
} finally {
    Pop-Location
}
