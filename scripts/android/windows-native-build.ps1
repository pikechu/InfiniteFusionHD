[CmdletBinding()]
param(
    [ValidateSet('OpenSSL')][string]$Dependency = 'OpenSSL',
    [string]$MsysRoot,
    [string]$NdkRoot,
    [string]$OutputDirectory,
    [ValidateRange(1,16)][int]$Jobs = 4,
    [switch]$Fetch
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = Join-Path $repository 'temp'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $temporary 'windows-native' }
if (!$MsysRoot) { $MsysRoot = Join-Path $temporary 'tools/msys64' }
if (!$NdkRoot) { $NdkRoot = Join-Path $temporary 'tools/android-ndk-r25c' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$MsysRoot = [IO.Path]::GetFullPath($MsysRoot)
$NdkRoot = [IO.Path]::GetFullPath($NdkRoot)
if (!$OutputDirectory.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Build outputs must stay inside this checkout temp directory.'
}
# A tools junction into the primary checkout temp is supported; arbitrary system
# MSYS installations are not mutated by this script.
if (!$MsysRoot.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Use the portable MSYS2 tree below this checkout temp/tools.'
}
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
$properties = Get-Content -LiteralPath (Join-Path $NdkRoot 'source.properties') -Raw
if ($properties -notmatch ('Pkg.Revision\s*=\s*' + [regex]::Escape($lock.ndkRevision))) { throw 'NDK revision differs from the dependency lock.' }
foreach ($directory in @($OutputDirectory,(Join-Path $OutputDirectory 'sources'),(Join-Path $OutputDirectory 'logs'))) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
function Invoke-Checked([string]$Program,[string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed: $LASTEXITCODE" }
}
$bash = Join-Path $MsysRoot 'usr/bin/bash.exe'
$perl = Join-Path $MsysRoot 'usr/bin/perl.exe'
if (!(Test-Path -LiteralPath $bash) -or !(Test-Path -LiteralPath (Join-Path $MsysRoot 'usr/bin/make.exe'))) {
    throw 'Portable MSYS2 plus GNU Make are required; see windows-native-build.md.'
}
if (!(Test-Path -LiteralPath $perl)) {
    $package = $lock.hostPackages | Where-Object name -eq 'perl'
    $archive = Join-Path $OutputDirectory ([IO.Path]::GetFileName($package.url))
    if (!(Test-Path -LiteralPath $archive)) {
        if (!$Fetch) { throw 'Pinned Perl archive missing; rerun with -Fetch to download.' }
        # No proxy/TLS overrides: preserve caller and corporate network policy.
        Invoke-Checked 'curl.exe' @('--fail','--location','--retry','2','--output',$archive,$package.url)
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $package.sha256) { throw 'Perl archive checksum mismatch.' }
    Invoke-Checked (Join-Path $MsysRoot 'usr/bin/bsdtar.exe') @('-xf',$archive,'-C',$MsysRoot)
}
$source = Join-Path $OutputDirectory 'sources/openssl'
if (!(Test-Path -LiteralPath (Join-Path $source '.git'))) {
    if (!$Fetch) { throw 'Pinned OpenSSL checkout missing; rerun with -Fetch to clone.' }
    Invoke-Checked 'git' @('init',$source)
    Invoke-Checked 'git' @('-C',$source,'remote','add','origin',$lock.dependencies.openssl.url)
    Invoke-Checked 'git' @('-C',$source,'-c','http.sslBackend=openssl','fetch','--depth','1','origin',$lock.dependencies.openssl.commit)
    Invoke-Checked 'git' @('-C',$source,'checkout','--detach','FETCH_HEAD')
}
$head = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $lock.dependencies.openssl.commit) { throw 'OpenSSL source commit differs from the lock.' }
if ((& git -C $source status --porcelain).Count -gt 0) { throw 'OpenSSL source checkout has modifications; use a fresh temp output directory.' }
$shell = Join-Path $PSScriptRoot 'windows-native-openssl.sh'
$started = Get-Date
$snapshotDirectory = Join-Path $OutputDirectory 'scripts'
[IO.Directory]::CreateDirectory($snapshotDirectory) | Out-Null
$snapshot = Join-Path $snapshotDirectory ("openssl-" + [Guid]::NewGuid().ToString('N') + '.sh')
[IO.File]::WriteAllText($snapshot,[IO.File]::ReadAllText($shell).Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
& $bash --noprofile --norc $snapshot.Replace('\','/') $source.Replace('\','/') $NdkRoot.Replace('\','/') $OutputDirectory.Replace('\','/') $Jobs *>&1 | Tee-Object -FilePath (Join-Path $OutputDirectory 'logs/openssl-host.log')
if ($LASTEXITCODE -ne 0) { throw "OpenSSL build failed; see $OutputDirectory/logs and build/openssl." }
# Configure/install runs under MSYS, while future Meson/pkg-config consumers
# are native Windows programs. Normalize only the installed metadata prefix;
# native consumers would otherwise interpret /d/... as D:/d/....
$nativePrefix = (Join-Path $OutputDirectory 'prefix/arm64-v8a').Replace('\','/')
$posixPrefix = '/' + $nativePrefix.Substring(0,1).ToLowerInvariant() + $nativePrefix.Substring(2)
foreach ($pc in (Get-ChildItem -LiteralPath (Join-Path $OutputDirectory 'prefix/arm64-v8a/lib/pkgconfig') -Filter '*.pc' -File)) {
    $metadata = [IO.File]::ReadAllText($pc.FullName)
    [IO.File]::WriteAllText($pc.FullName,$metadata.Replace($posixPrefix,$nativePrefix),[Text.UTF8Encoding]::new($false))
}
$readelf = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
$artifacts = foreach ($name in @('libcrypto.so','libssl.so')) {
    $library = Join-Path $OutputDirectory "prefix/arm64-v8a/lib/$name"
    if (!(Test-Path -LiteralPath $library)) { throw "Expected artifact missing: $library" }
    $elf = & $readelf -h -l -d $library
    if ($LASTEXITCODE -ne 0) { throw 'ELF inspection failed.' }
    $elf | Set-Content -LiteralPath (Join-Path $OutputDirectory "logs/$name.elf.txt")
    if (($elf -join "`n") -notmatch 'Machine:\s+AArch64') { throw 'Built library is not AArch64.' }
    $loads = @($elf | Where-Object { $_ -match '^\s+LOAD\s' })
    if (!$loads.Count -or @($loads | Where-Object { $_ -notmatch '0x4000\s*$' }).Count) { throw 'Expected 16 KiB PT_LOAD alignment on every segment.' }
    if (($elf -join "`n") -notmatch ('Library soname: \[' + [regex]::Escape($name) + '\]')) { throw 'Unexpected OpenSSL SONAME.' }
    @{path=$library;sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant()}
}
@{dependency='openssl';sourceCommit=$head;ndkRevision=$lock.ndkRevision;abi='arm64-v8a';api=30;started=$started.ToString('o');finished=(Get-Date).ToString('o');artifacts=@($artifacts);deviceValidated=$false} |
  ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'openssl-build-result.json') -Encoding utf8
Write-Host "OpenSSL ARM64 libraries built and inspected: $OutputDirectory/prefix/arm64-v8a/lib"
