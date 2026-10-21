[CmdletBinding()]
param([string]$SourceArchive, [ValidateRange(1,16)][int]$Jobs=1, [switch]$Fetch)
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary=Join-Path $repository 'temp'
$lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-core.lock.json') -Raw | ConvertFrom-Json
$ndk=Join-Path $temporary 'tools/android-ndk-r25c'
$msys=Join-Path $temporary 'tools/msys64'
if((Get-Content -LiteralPath (Join-Path $ndk 'source.properties') -Raw) -notmatch 'Pkg.Revision\s*=\s*25\.2\.9519653') { throw 'Expected fixed NDK r25c.' }
$cache=Join-Path $temporary 'windows-native/cache'
[IO.Directory]::CreateDirectory($cache) | Out-Null
if(!$SourceArchive){$SourceArchive=Join-Path $cache 'libiconv-1.18.tar.gz'}
$SourceArchive=[IO.Path]::GetFullPath($SourceArchive)
if(!(Test-Path -LiteralPath $SourceArchive)){
    if(!$Fetch){throw 'Pass the existing official libiconv archive, or use -Fetch.'}
    if(!$SourceArchive.StartsWith($temporary+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'New downloads must stay below this worktree temp.'}
    & curl.exe --fail --location --retry 2 --output $SourceArchive $lock.libiconv.url
    if($LASTEXITCODE -ne 0){throw 'libiconv archive download failed.'}
}
if((Get-FileHash -LiteralPath $SourceArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $lock.libiconv.sha256){throw 'libiconv official archive checksum mismatch.'}
# A fresh run/source/build/install preserves previous evidence and avoids stale API21 objects.
$run=Join-Path $temporary ('windows-native-iconv/runs/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$run=[IO.Path]::GetFullPath($run)
if(!$run.StartsWith($temporary+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Run output escaped temp.'}
if(Test-Path -LiteralPath $run){throw 'Run directory already exists.'}
$sourceDirectory=Join-Path $run 'source'
[IO.Directory]::CreateDirectory($sourceDirectory) | Out-Null
& (Join-Path $msys 'usr/bin/bsdtar.exe') -xf $SourceArchive -C $sourceDirectory
if($LASTEXITCODE -ne 0){throw 'Fixed libiconv source extraction failed.'}
$sourceDirectory=Join-Path $sourceDirectory 'libiconv-1.18'
$buildOutput=Join-Path $run 'probe'
$started=Get-Date
& (Join-Path $PSScriptRoot 'probe-windows-native.ps1') -NdkRoot $ndk -MsysRoot $msys -LibiconvSource $sourceDirectory -OutputDirectory $buildOutput -Api 30 -Jobs $Jobs
if($LASTEXITCODE -ne 0){throw 'libiconv API30 build failed.'}
$bin=Join-Path $ndk 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$install=Join-Path $buildOutput 'libiconv-install'
$artifacts=@()
foreach($name in @('libiconv.so','libcharset.so')){
    $library=Join-Path $install "lib/$name"
    $elf=& (Join-Path $bin 'llvm-readelf.exe') -h -lW -d $library
    if($LASTEXITCODE -ne 0){throw "Cannot inspect $name."}
    $elf | Set-Content -LiteralPath (Join-Path $run "$name.elf.txt")
    $metadata=$elf -join "`n"
    $loads=@($elf | Where-Object {$_ -match '^\s*LOAD\s'})
    if($metadata -notmatch 'Machine:\s+AArch64' -or $metadata -notmatch ('Library soname: \['+[regex]::Escape($name)+'\]') -or !$loads.Count -or @($loads | Where-Object {$_ -notmatch '0x4000\s*$'}).Count -or $metadata -match '\((?:RPATH|RUNPATH)\)'){throw "$name ABI/SONAME/alignment/runtime-path validation failed."}
    $artifacts+=@{name=$name;sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $library).Length;source=$library}
}
$symbols=& (Join-Path $bin 'llvm-nm.exe') --dynamic --defined-only (Join-Path $install 'lib/libiconv.so')
if($LASTEXITCODE -ne 0){throw 'Cannot inspect libiconv exports.'}
foreach($symbol in @('libiconv','libiconv_open','libiconv_close')){if(($symbols -join "`n") -notmatch ('(?m)\b'+$symbol+'\s*$')){throw "Missing libiconv export $symbol."}}
$prefix=Join-Path $temporary 'windows-native/prefix/arm64-v8a'
foreach($directory in @('lib','include')){[IO.Directory]::CreateDirectory((Join-Path $prefix $directory)) | Out-Null}
foreach($artifact in $artifacts){Copy-Item -LiteralPath $artifact.source -Destination (Join-Path $prefix ('lib/'+$artifact.name))}
foreach($header in @('iconv.h','libcharset.h','localcharset.h')){Copy-Item -LiteralPath (Join-Path $install ('include/'+$header)) -Destination (Join-Path $prefix ('include/'+$header))}
@{dependency='libiconv';version=$lock.libiconv.version;archiveSha256=$lock.libiconv.sha256;abi='arm64-v8a';api=30;ndkRevision='25.2.9519653';started=$started.ToString('o');finished=(Get-Date).ToString('o');run=$run;prefix=$prefix;artifacts=$artifacts;deviceValidated=$false;targetExecuted=$false} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temporary 'windows-native/libiconv-build-result.json') -Encoding utf8
Write-Output "PASS: fixed libiconv API30 source build, ELF/exports and staging; evidence $run"
