param(
  [string]$BindAddress = '127.0.0.1',
  [int]$Port = 8765,
  [string]$Database = (Join-Path $PSScriptRoot 'data\multiplayer-test.sqlite3'),
  [string]$PythonExecutable = ''
)
$ErrorActionPreference = 'Stop'
if (-not $PythonExecutable) {
  $bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
  if (Test-Path -LiteralPath $bundledPython) { $PythonExecutable = $bundledPython }
  else { $PythonExecutable = 'python' }
}
$dataDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Database))
New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
& $PythonExecutable (Join-Path $PSScriptRoot 'service.py') --host $BindAddress --port $Port --database $Database --log-file (Join-Path $dataDirectory 'multiplayer.log')
exit $LASTEXITCODE
