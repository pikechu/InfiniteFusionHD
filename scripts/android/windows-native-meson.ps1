[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PythonPath,
    [switch]$Fetch
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $repository 'temp/core-tools'
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-core.lock.json') -Raw | ConvertFrom-Json
$PythonPath = (Get-Item -LiteralPath $PythonPath).FullName
[IO.Directory]::CreateDirectory($output) | Out-Null
foreach ($name in @('meson','pkgconf')) {
    $item = $lock.$name
    $archive = Join-Path $output $item.filename
    if (!(Test-Path -LiteralPath $archive)) {
        if (!$Fetch) { throw "Fixed $name archive missing; use -Fetch." }
        & curl.exe --fail --location --retry 2 --output $archive $item.url
        if ($LASTEXITCODE -ne 0) { throw "$name download failed." }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha256) { throw "$name archive differs from lock." }
}
$mesonDirectory = Join-Path $output "meson-$($lock.meson.version)"
$mesonModule = Join-Path $mesonDirectory 'mesonbuild/mesonmain.py'
if (!(Test-Path -LiteralPath $mesonModule)) {
    [IO.Directory]::CreateDirectory($mesonDirectory) | Out-Null
    & $PythonPath -B -m zipfile -e (Join-Path $output $lock.meson.filename) $mesonDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Meson wheel extraction failed.' }
}
$mesonEntry = Join-Path $mesonDirectory 'meson.py'
[IO.File]::WriteAllText($mesonEntry, "from mesonbuild.mesonmain import main`nraise SystemExit(main())`n", [Text.UTF8Encoding]::new($false))
$bytecodeQuarantine = Join-Path $output ('bytecode-quarantine/' + [Guid]::NewGuid().ToString('N'))
& $PythonPath -B (Join-Path $PSScriptRoot 'windows_native_tool_cache.py') (Join-Path $output $lock.meson.filename) $mesonDirectory $lock.meson.sha256 --quarantine-bytecode $bytecodeQuarantine
if ($LASTEXITCODE -ne 0) { throw 'Executed Meson cache does not match the fixed wheel.' }
$pkgconfDirectory = Join-Path $output 'pkgconf'
$pkgconf = Join-Path $pkgconfDirectory 'ucrt64/bin/pkgconf.exe'
if (!(Test-Path -LiteralPath $pkgconf)) {
    [IO.Directory]::CreateDirectory($pkgconfDirectory) | Out-Null
    # The exact official archive is verified above; no pacman/system installation.
    $tar = Join-Path $repository 'temp/tools/msys64/usr/bin/bsdtar.exe'
    if (!(Test-Path -LiteralPath $tar)) { throw 'Portable MSYS2 bsdtar missing.' }
    & $tar -xf (Join-Path $output $lock.pkgconf.filename) -C $pkgconfDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Portable pkgconf extraction failed.' }
}
foreach ($binary in $lock.pkgconf.executables.PSObject.Properties) {
    if ((Get-FileHash -LiteralPath (Join-Path $pkgconfDirectory $binary.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $binary.Value) { throw "pkgconf cache differs from verified package: $($binary.Name)" }
}
$mesonVersion = (& $PythonPath -B $mesonEntry --version) -join ''
if ($LASTEXITCODE -ne 0 -or $mesonVersion.Trim() -ne $lock.meson.version) { throw 'Meson version mismatch.' }
$pkgconfVersion = (& $pkgconf --version) -join ''
if ($LASTEXITCODE -ne 0 -or $pkgconfVersion.Trim() -ne $lock.pkgconf.reportedVersion) { throw 'pkgconf reported version differs from the fixed upstream version declaration.' }
$ninjaLock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
$ninja = Join-Path $repository "temp/tools/$($ninjaLock.hostTools.ninja.directory)/ninja.exe"
if (!(Test-Path -LiteralPath $ninja)) { throw 'Fixed portable Ninja missing; prepare windows-native-cmake.ps1 first.' }
$record = @{
    python=$PythonPath; mesonEntry=$mesonEntry; mesonVersion=$mesonVersion.Trim()
    pkgconf=$pkgconf; pkgconfVersion=$pkgconfVersion.Trim(); pkgconfPackageVersion=$lock.pkgconf.version; ninja=$ninja
    mesonArchiveSha256=$lock.meson.sha256; pkgconfArchiveSha256=$lock.pkgconf.sha256
    pkgconfExecutableSha256=(Get-FileHash -LiteralPath $pkgconf -Algorithm SHA256).Hash.ToLowerInvariant()
    generated=(Get-Date).ToString('o'); globalInstallation=$false
}
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding utf8
Write-Output "Portable Meson $mesonVersion / pkgconf $pkgconfVersion ready below $output"
