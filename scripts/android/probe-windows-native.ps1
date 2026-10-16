[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$NdkRoot,
    [string]$MsysRoot,
    [string]$LibiconvSource,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = [IO.Path]::GetFullPath((Join-Path $repository 'temp'))
if (!$OutputDirectory) { $OutputDirectory = Join-Path $temporary 'native-windows-proof' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (!$OutputDirectory.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Native probe outputs must stay inside this checkout temp directory.'
}
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$NdkRoot = [IO.Path]::GetFullPath($NdkRoot)
$compilerDirectory = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$clang = Join-Path $compilerDirectory 'clang.exe'
$readelf = Join-Path $compilerDirectory 'llvm-readelf.exe'
if (!(Test-Path -LiteralPath $clang) -or !(Test-Path -LiteralPath $readelf)) { throw 'Expected a Windows NDK with clang.exe and llvm-readelf.exe.' }

function Invoke-Checked([string]$program, [string[]]$toolArguments, [string]$logName) {
    & $program @toolArguments *>&1 | Tee-Object -FilePath (Join-Path $OutputDirectory $logName)
    if ($LASTEXITCODE -ne 0) { throw "$program failed with exit code $LASTEXITCODE; see $logName" }
}

$source = Join-Path $OutputDirectory 'kif-native-probe.c'
@'
#include <stdint.h>
#include <stdlib.h>
int32_t kif_android_native_probe(int32_t value) { return value + (int32_t)sizeof(void *); }
'@ | Set-Content -LiteralPath $source -Encoding ascii
Invoke-Checked $clang @('--version') 'clang-version.log'
Invoke-Checked $clang @('--target=aarch64-linux-android21','-fPIC','-c',$source,'-o',(Join-Path $OutputDirectory 'probe-arm64.o')) 'clang-arm64-object.log'
Invoke-Checked $clang @('--target=x86_64-linux-android21','-fPIC','-c',$source,'-o',(Join-Path $OutputDirectory 'probe-x86_64.o')) 'clang-x86_64-object.log'
Invoke-Checked $clang @('--target=aarch64-linux-android21','-fPIC','-shared','-Wl,-z,max-page-size=16384',$source,'-o',(Join-Path $OutputDirectory 'libkif-native-probe.so')) 'clang-arm64-shared.log'
Invoke-Checked $readelf @('-h',(Join-Path $OutputDirectory 'probe-arm64.o')) 'elf-arm64-object.log'
Invoke-Checked $readelf @('-h',(Join-Path $OutputDirectory 'probe-x86_64.o')) 'elf-x86_64-object.log'
Invoke-Checked $readelf @('-h','-l','-n',(Join-Path $OutputDirectory 'libkif-native-probe.so')) 'elf-arm64-shared.log'

if ($LibiconvSource) {
    if (!$MsysRoot) { throw '-MsysRoot is required with -LibiconvSource.' }
    $MsysRoot = [IO.Path]::GetFullPath($MsysRoot)
    $LibiconvSource = [IO.Path]::GetFullPath($LibiconvSource)
    $bash = Join-Path $MsysRoot 'usr/bin/bash.exe'
    if (!(Test-Path -LiteralPath (Join-Path $MsysRoot 'usr/bin/make.exe'))) { throw 'GNU Make is not present in the portable MSYS2 root.' }
    $shellScript = Join-Path $OutputDirectory 'libiconv-probe.sh'
    $shellText = @'
set -euo pipefail
export PATH=/usr/bin:/bin:$PATH
ndk="$1"
source_directory="$(cygpath -u "$2")"
output_directory="$(cygpath -u "$3")"
compiler_directory="$ndk/toolchains/llvm/prebuilt/windows-x86_64/bin"
"$compiler_directory/aarch64-linux-android21-clang" -fPIC -c "$output_directory/kif-native-probe.c" -o "$output_directory/probe-arm64-wrapper.o"
export CC="$compiler_directory/clang.exe --target=aarch64-linux-android21"
export CXX="$compiler_directory/clang++.exe --target=aarch64-linux-android21"
export AR="$compiler_directory/llvm-ar.exe"
export NM="$compiler_directory/llvm-nm.exe"
export RANLIB="$compiler_directory/llvm-ranlib.exe"
export STRIP="$compiler_directory/llvm-strip.exe"
export LD="$compiler_directory/ld.lld.exe"
export CFLAGS='-O2 -fPIC'
export LDFLAGS='-Wl,-z,max-page-size=16384'
mkdir -p "$output_directory/libiconv-build" "$output_directory/libiconv-install"
cd "$output_directory/libiconv-build"
build_triple="$(sh "$source_directory/build-aux/config.guess")"
printf 'MSYS host: %s\nNDK compiler: %s\n' "$build_triple" "$CC"
"$source_directory/configure" --build="$build_triple" --host=aarch64-linux-android --prefix="$output_directory/libiconv-install" --enable-shared --disable-static --disable-nls > configure.stdout.log 2>&1
make -j2 > make.stdout.log 2>&1
make install > install.stdout.log 2>&1
printf 'libiconv configure, make and install completed.\n'
'@
    $shellText.Replace("`r`n","`n") | Set-Content -LiteralPath $shellScript -Encoding utf8 -NoNewline
    # Only this child invocation uses the portable shell. Caller and machine configuration stay intact.
    Invoke-Checked $bash @('--noprofile','--norc',$shellScript.Replace('\','/'),$NdkRoot.Replace('\','/'),$LibiconvSource.Replace('\','/'),$OutputDirectory.Replace('\','/')) 'libiconv-probe.log'
    $library = Join-Path $OutputDirectory 'libiconv-install/lib/libiconv.so'
    if (!(Test-Path -LiteralPath $library)) { throw 'libiconv build completed without the expected shared library.' }
    Invoke-Checked $readelf @('-h','-l','-d',$library) 'elf-libiconv.log'
}
Write-Host "Native probe evidence: $OutputDirectory"
Write-Host 'This probe does not build or replace the mkxp-z runtime.'
