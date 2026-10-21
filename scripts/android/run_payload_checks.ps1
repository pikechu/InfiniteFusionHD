[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PythonPath)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$environmentFile = Join-Path $repository 'temp/tools/android-environment.json'
$tools = Get-Content -LiteralPath $environmentFile -Raw | ConvertFrom-Json
$classes = Join-Path $repository 'temp/host-checks/payload-classes'
[IO.Directory]::CreateDirectory($classes) | Out-Null
Push-Location -LiteralPath $repository
try {
    & $PythonPath -B android/tests/payload_package_test.py
    if ($LASTEXITCODE -ne 0) { throw 'Payload packaging/refresh checks failed' }
    & (Join-Path $tools.JAVA_HOME 'bin/javac.exe') '-J-Duser.language=en' --release 8 -encoding UTF-8 -d $classes android/app/src/main/java/org/kuray/kif/PayloadArchive.java android/tests/payload-java/PayloadArchiveHostTest.java
    if ($LASTEXITCODE -ne 0) { throw 'Payload restore test compilation failed' }
    & (Join-Path $tools.JAVA_HOME 'bin/java.exe') -cp $classes org.kuray.kif.PayloadArchiveHostTest (Join-Path $repository 'temp/host-checks')
    if ($LASTEXITCODE -ne 0) { throw 'Payload restore filesystem checks failed' }
} finally { Pop-Location }
