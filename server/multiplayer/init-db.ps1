param(
  [string]$Database = (Join-Path $PSScriptRoot 'data\multiplayer-test.sqlite3'),
  [string]$PythonExecutable = ''
)
$ErrorActionPreference = 'Stop'
if (-not $PythonExecutable) {
  $bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
  if (Test-Path -LiteralPath $bundledPython) { $PythonExecutable = $bundledPython }
  else { $PythonExecutable = 'python' }
}
# Store initializes its schema; using an existing DB also marks any interrupted
# engine battle abnormal. Run while the service is stopped, never against a live DB.
$env:KURAY_TEST_DB = [System.IO.Path]::GetFullPath($Database)
$env:KURAY_SERVICE_DIR = $PSScriptRoot
try {
  $initialize = @'
import os,sys
sys.path.insert(0,os.environ["KURAY_SERVICE_DIR"])
from service import Store, database_instance_lock
with database_instance_lock(os.environ["KURAY_TEST_DB"]):
    store = Store(os.environ["KURAY_TEST_DB"])
    store.close()
    print("Database initialized:", os.environ["KURAY_TEST_DB"])
'@
  # Feed source on stdin: Windows PowerShell's legacy native argument quoting
  # otherwise strips Python's embedded quotes in a multi-line -c argument.
  $initialize | & $PythonExecutable -
} finally {
  Remove-Item Env:\KURAY_TEST_DB -ErrorAction SilentlyContinue
  Remove-Item Env:\KURAY_SERVICE_DIR -ErrorAction SilentlyContinue
}
exit $LASTEXITCODE
