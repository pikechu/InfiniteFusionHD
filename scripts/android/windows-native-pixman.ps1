[CmdletBinding()]
param([string]$OutputDirectory,[string]$NdkRoot,[ValidateRange(1,16)][int]$Jobs=1)
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary=Join-Path $repository 'temp'
if (!$OutputDirectory) { $OutputDirectory=Join-Path $temporary 'windows-native' }
if (!$NdkRoot) { $NdkRoot=Join-Path $temporary 'tools/android-ndk-r25c' }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$NdkRoot=[IO.Path]::GetFullPath($NdkRoot)
if (!$OutputDirectory.StartsWith($temporary+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Pixman output must remain within this checkout temp.' }
$lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
if ((Get-Content -LiteralPath (Join-Path $NdkRoot 'source.properties') -Raw) -notmatch ('Pkg.Revision\s*=\s*'+[regex]::Escape($lock.ndkRevision))) { throw 'NDK revision differs from lock.' }
$environment=Get-Content -LiteralPath (Join-Path $temporary 'core-tools/environment.json') -Raw | ConvertFrom-Json
& (Join-Path $PSScriptRoot 'windows-native-meson.ps1') -PythonPath $environment.python
if ($LASTEXITCODE -ne 0) { throw 'Locked Meson/pkgconf verification failed.' }
$source=Join-Path $OutputDirectory 'sources/pixman'
if ((& git -C $source rev-parse HEAD).Trim() -ne $lock.dependencies.pixman.commit -or (& git -C $source status --porcelain).Count) { throw 'Pixman source differs from locked clean checkout.' }
$build=Join-Path $OutputDirectory 'build/pixman'
$prefix=Join-Path $OutputDirectory 'prefix/arm64-v8a'
$logs=Join-Path $OutputDirectory 'logs'
$scripts=Join-Path $OutputDirectory 'scripts'
foreach ($path in @($logs,$scripts)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
$bin=(Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin').Replace('\','/')
$nativePrefix=$prefix.Replace('\','/')
$cross=Join-Path $scripts 'pixman-arm64-windows.txt'
$text=@"
[binaries]
c = ['$bin/clang.exe', '--target=aarch64-linux-android30']
ar = '$bin/llvm-ar.exe'
strip = '$bin/llvm-strip.exe'
pkg-config = '$($environment.pkgconf.Replace('\','/'))'
[built-in options]
c_args = ['-O2', '-fPIC']
c_link_args = ['-Wl,-z,max-page-size=16384']
[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$nativePrefix/lib/pkgconfig']
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
"@
[IO.File]::WriteAllText($cross,$text.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
function Invoke-Meson([string[]]$Arguments,[string]$Log) {
    & $environment.python -B $environment.mesonEntry @Arguments *>&1 | Tee-Object -FilePath $Log
    if ($LASTEXITCODE -ne 0) { throw "Pixman Meson failed: $Log" }
}
$started=Get-Date
$previous=Join-Path $logs ('previous/pixman-'+$started.ToString('yyyyMMdd-HHmmss-fff'))
foreach ($log in (Get-ChildItem -LiteralPath $logs -Filter 'pixman-*' -File)) { [IO.Directory]::CreateDirectory($previous) | Out-Null; Copy-Item -LiteralPath $log.FullName -Destination $previous }
$oldPath=$env:PATH; $oldPkgPath=$env:PKG_CONFIG_PATH; $oldPkgLib=$env:PKG_CONFIG_LIBDIR; $oldBytecode=$env:PYTHONDONTWRITEBYTECODE
try {
    $env:PATH=(Split-Path -Parent $environment.ninja)+';'+$oldPath
    $env:PKG_CONFIG_PATH=''; $env:PKG_CONFIG_LIBDIR=Join-Path $prefix 'lib/pkgconfig'
    $env:PYTHONDONTWRITEBYTECODE='1'
    $setup=@('setup',$build,$source,'--cross-file',$cross,'--prefix',$prefix,'--libdir=lib','--buildtype=release','--default-library=shared','--wrap-mode=nodownload','-Darm-simd=disabled','-Dneon=disabled','-Da64-neon=disabled','-Dtests=disabled','-Dgtk=disabled','-Dlibpng=disabled')
    if (Test-Path -LiteralPath (Join-Path $build 'meson-private/coredata.dat')) { $setup += '--reconfigure' }
    Invoke-Meson $setup (Join-Path $logs 'pixman-configure.log')
    Invoke-Meson @('compile','-C',$build,'-j',"$Jobs") (Join-Path $logs 'pixman-build.log')
    Invoke-Meson @('install','-C',$build,'--no-rebuild') (Join-Path $logs 'pixman-install.log')
} finally { $env:PATH=$oldPath; $env:PKG_CONFIG_PATH=$oldPkgPath; $env:PKG_CONFIG_LIBDIR=$oldPkgLib; $env:PYTHONDONTWRITEBYTECODE=$oldBytecode }
$library=Join-Path $prefix 'lib/libpixman-1.so'
$elf=& "$bin/llvm-readelf.exe" -h -l -d $library
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Pixman ELF.' }
$elf | Set-Content -LiteralPath (Join-Path $logs 'pixman-elf.txt')
$elfText=$elf -join "`n"; $loads=@($elf | Where-Object { $_ -match '^\s+LOAD\s' })
if ($elfText -notmatch 'Machine:\s+AArch64' -or $elfText -notmatch 'Library soname: \[libpixman-1.so\]' -or $elfText -match '\((?:RPATH|RUNPATH)\)' -or !$loads.Count -or @($loads | Where-Object { $_ -notmatch '0x4000\s*$' }).Count) { throw 'Pixman ABI/SONAME/alignment/search-path gate failed.' }
$symbols=& "$bin/llvm-nm.exe" --dynamic --defined-only $library
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Pixman exports.' }
$symbols | Set-Content -LiteralPath (Join-Path $logs 'pixman-exports.txt')
foreach ($symbol in @('pixman_image_create_bits','pixman_image_composite32','pixman_image_unref','pixman_version')) {
    if (($symbols -join "`n") -notmatch ('(?m)\b'+$symbol+'\s*$')) { throw "Pixman required export missing: $symbol" }
}
@{dependency='pixman';sourceCommit=$lock.dependencies.pixman.commit;started=$started.ToString('o');finished=(Get-Date).ToString('o');artifact=$library;bytes=(Get-Item -LiteralPath $library).Length;sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant();abi='arm64-v8a';api=30;ndkRevision=$lock.ndkRevision;deviceValidated=$false;targetExecuted=$false} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'pixman-build-result.json') -Encoding utf8
Write-Host 'Pixman ARM64 build/install and ELF/export gates passed.'
