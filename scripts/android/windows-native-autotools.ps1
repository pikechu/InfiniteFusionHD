[CmdletBinding()]
param([string]$MsysRoot,[string]$OutputDirectory,[switch]$Fetch)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = Join-Path $repository 'temp'
if (!$MsysRoot) { $MsysRoot = Join-Path $temporary 'tools/msys64' }
if (!$OutputDirectory) { $OutputDirectory = Join-Path $temporary 'windows-native' }
$MsysRoot = [IO.Path]::GetFullPath($MsysRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
foreach ($path in @($MsysRoot,$OutputDirectory)) {
    if (!$path.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Portable tool paths must remain inside this checkout temp (existing tools junction supported).' }
}
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
$tar = Join-Path $MsysRoot 'usr/bin/bsdtar.exe'
if (!(Test-Path -LiteralPath $tar)) { throw 'Existing portable MSYS2 bsdtar (with zstd support) is required.' }
$archiveDirectory = Join-Path $OutputDirectory 'host-packages'
$logs = Join-Path $OutputDirectory 'logs'
foreach ($path in @($archiveDirectory,$logs)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
function Invoke-Checked([string]$Program,[string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit $LASTEXITCODE." }
}
$records = foreach ($name in @('m4','autoconf2.72','automake1.18','libltdl','libtool')) {
    $pin = @($lock.hostPackages | Where-Object { $_.name -eq $name })
    if ($pin.Count -ne 1) { throw "Missing or duplicated host package lock: $name" }
    $pin = $pin[0]
    $archive = Join-Path $archiveDirectory ([IO.Path]::GetFileName(([Uri]$pin.url).AbsolutePath))
    if (!(Test-Path -LiteralPath $archive)) {
        if (!$Fetch) { throw "Portable $name archive missing; use -Fetch." }
        Invoke-Checked 'curl.exe' @('--fail','--location','--retry','2','--output',$archive,$pin.url)
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.sha256) { throw "Host package checksum mismatch: $name" }
    $entries = & $tar -tf $archive
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect host package $name." }
    foreach ($entry in $entries) {
        if ($entry -match '^(?:/|[A-Za-z]:)|(?:^|[/\\])\.\.(?:[/\\]|$)' -or $entry.Contains('\')) { throw 'Unsafe host package archive path.' }
    }
    # Extract only package /usr data; never pacman metadata or install hooks.
    Invoke-Checked $tar @('-xf',$archive,'-C',$MsysRoot,'usr')
    @{name=$name;version=$pin.version;archive=$archive;sha256=$pin.sha256;source=$pin.source}
}
$bash = Join-Path $MsysRoot 'usr/bin/bash.exe'
$probe = 'export PATH=/usr/bin:/bin:$PATH; m4 --version | head -1; autoconf-2.72 --version | head -1; autoreconf-2.72 --version | head -1; automake-1.18 --version | head -1; libtoolize --version | head -1'
& $bash --noprofile --norc -e -o pipefail -c $probe *>&1 | Tee-Object -FilePath (Join-Path $logs 'autotools-host-versions.log')
if ($LASTEXITCODE -ne 0) { throw 'Portable Autotools interpreter/version check failed.' }
@{preparedAt=(Get-Date).ToString('o');packages=@($records);msysRoot=$MsysRoot;systemInstallation=$false;compiled=$false;targetExecuted=$false} |
 ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'autotools-host-preparation.json') -Encoding utf8
Write-Host 'Portable Autotools packages verified and host tools executed; no compiler or target execution.'
