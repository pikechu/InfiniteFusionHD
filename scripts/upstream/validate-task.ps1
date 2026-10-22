[CmdletBinding()]
param([ValidatePattern('^U0[2-9]$')][string]$Task, [switch]$RefreshCatalog)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$python = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
if (-not (Test-Path -LiteralPath $python)) { $python = 'D:/others/kurayshinyrevamp/temp/tools/android-ndk-r25c/toolchains/llvm/prebuilt/windows-x86_64/python3/python.exe' }
$oldSave, $oldProfile, $oldTask = $env:KIF_MULTIPLAYER_SAVE_DIR, $env:KIF_MULTIPLAYER_PROFILE, $env:KIF_UPSTREAM_TASK
Push-Location $repo
try {
  & $python scripts/multiplayer/build.py
  if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
  $runs = @(@{Profile=($Task.ToLower() + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'));Script='tests/upstream/native_task.rb';Log='feature-smoke.log'})
  if ($RefreshCatalog) { $runs += @{Profile=('catalog-' + (Get-Date -Format 'yyyyMMdd-HHmmss'));Script='tests/multiplayer/rental_catalog_game.rb';Log='rental-catalog.log'} }
  foreach ($run in $runs) {
    $stage = & scripts/multiplayer/prepare-runtime.ps1 -Profile $run.Profile -CustomScript $run.Script
    $env:KIF_MULTIPLAYER_SAVE_DIR = Join-Path $stage 'saves'
    $env:KIF_MULTIPLAYER_PROFILE = $run.Profile
    $env:KIF_UPSTREAM_TASK = $Task
    $process = Start-Process -FilePath (Join-Path $stage 'Game.exe') -WorkingDirectory $stage -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stage 'stdout.log') -RedirectStandardError (Join-Path $stage 'stderr.log')
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    while (-not $process.WaitForExit(1000)) {
      if ([DateTime]::UtcNow -gt $deadline) { Stop-Process -Id $process.Id; throw 'Native check timed out' }
    }
    Get-Content (Join-Path $stage ('saves/' + $run.Log)) -Tail 28 -Encoding UTF8
    Write-Output "NATIVE_EXIT=$($process.ExitCode) profile=$($run.Profile)"
    if ($process.ExitCode -ne 0) { throw "Native validation failed: $($run.Profile)" }
  }
} finally {
  Pop-Location
  $env:KIF_MULTIPLAYER_SAVE_DIR, $env:KIF_MULTIPLAYER_PROFILE, $env:KIF_UPSTREAM_TASK = $oldSave, $oldProfile, $oldTask
}
