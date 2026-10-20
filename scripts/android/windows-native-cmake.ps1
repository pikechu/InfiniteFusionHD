[CmdletBinding()]
param(
    [ValidateSet('SDL2','libogg','libvorbis','libpng','physfs','freetype')][string]$Dependency = 'SDL2',
    [string]$NdkRoot,
    [string]$SourceDirectory,
    [string]$OutputDirectory,
    [ValidateRange(1,16)][int]$Jobs = 4,
    [switch]$Fetch
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = Join-Path $repository 'temp'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $temporary 'windows-native' }
if (!$NdkRoot) { $NdkRoot = Join-Path $temporary 'tools/android-ndk-r25c' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$NdkRoot = [IO.Path]::GetFullPath($NdkRoot)
if (!$OutputDirectory.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Outputs must stay below this checkout temp.' }
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
if ((Get-Content -LiteralPath (Join-Path $NdkRoot 'source.properties') -Raw) -notmatch ('Pkg.Revision\s*=\s*' + [regex]::Escape($lock.ndkRevision))) { throw 'NDK revision differs from lock.' }
$logs = Join-Path $OutputDirectory 'logs'
$tools = Join-Path $temporary 'tools'
foreach ($path in @($OutputDirectory,$logs,$tools,(Join-Path $OutputDirectory 'sources'))) { [IO.Directory]::CreateDirectory($path) | Out-Null }
function Invoke-Checked([string]$Program,[string[]]$Arguments,[string]$Log) {
    if ($Log) { & $Program @Arguments *>&1 | Tee-Object -FilePath $Log } else { & $Program @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "$Program failed: $LASTEXITCODE (log: $Log)" }
}
foreach ($name in @('cmake','ninja')) {
    $tool = $lock.hostTools.$name
    $program = if ($name -eq 'cmake') { Join-Path $tools "$($tool.directory)/bin/cmake.exe" } else { Join-Path $tools "$($tool.directory)/ninja.exe" }
    if (!(Test-Path -LiteralPath $program)) {
        if (!$Fetch) { throw "Portable $name missing; use -Fetch." }
        $archive = Join-Path $OutputDirectory "$name-$($tool.version)-windows.zip"
        if (!(Test-Path -LiteralPath $archive)) { Invoke-Checked 'curl.exe' @('--fail','--location','--retry','2','--output',$archive,$tool.url) '' }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $tool.sha256) { throw "$name archive checksum mismatch." }
        $destination = if ($name -eq 'cmake') { $tools } else { Join-Path $tools $tool.directory }
        Expand-Archive -LiteralPath $archive -DestinationPath $destination
    }
}
$cmake = Join-Path $tools "$($lock.hostTools.cmake.directory)/bin/cmake.exe"
$ninja = Join-Path $tools "$($lock.hostTools.ninja.directory)/ninja.exe"
$dependencyLock = $lock.dependencies.$Dependency
$source = if ($SourceDirectory) { [IO.Path]::GetFullPath($SourceDirectory) } else { Join-Path $OutputDirectory "sources/$Dependency" }
if (!$source.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Dependency source must be a dedicated checkout below this task temp.' }
if (!(Test-Path -LiteralPath (Join-Path $source '.git'))) {
    if (!$Fetch) { throw "$Dependency sources missing; use -Fetch." }
    Invoke-Checked 'git' @('init',$source) ''
    Invoke-Checked 'git' @('-C',$source,'remote','add','origin',$dependencyLock.url) ''
    Invoke-Checked 'git' @('-C',$source,'-c','http.sslBackend=openssl','fetch','--depth','1','origin',$dependencyLock.commit) ''
    Invoke-Checked 'git' @('-C',$source,'checkout','--detach','FETCH_HEAD') ''
}
$head = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $dependencyLock.commit) { throw "$Dependency source commit differs from lock." }
foreach ($nested in $dependencyLock.nestedDependencies) {
    $gitlink = (& git -C $source ls-tree HEAD $nested.path) -join ''
    if ($LASTEXITCODE -ne 0 -or $gitlink -notmatch ('^160000 commit ' + [regex]::Escape($nested.commit) + '\s')) { throw 'Nested dependency gitlink differs from lock.' }
    $nestedSource = Join-Path $source $nested.path
    if (!(Test-Path -LiteralPath (Join-Path $nestedSource '.git'))) {
        if (!$Fetch) { throw 'Locked nested dependency missing; use -Fetch.' }
        Invoke-Checked 'git' @('init',$nestedSource) ''
        Invoke-Checked 'git' @('-C',$nestedSource,'remote','add','origin',$nested.url) ''
        Invoke-Checked 'git' @('-C',$nestedSource,'-c','http.sslBackend=openssl','fetch','--depth','1','origin',$nested.commit) ''
        Invoke-Checked 'git' @('-C',$nestedSource,'checkout','--detach','FETCH_HEAD') ''
    }
    if ((& git -C $nestedSource rev-parse HEAD).Trim() -ne $nested.commit -or (& git -C $nestedSource status --porcelain).Count -gt 0) { throw 'Nested dependency source differs from lock.' }
}
if ((& git -C $source status --porcelain).Count -gt 0) { throw "$Dependency source checkout has modifications." }
$build = Join-Path $OutputDirectory "build/$Dependency"
$prefix = Join-Path $OutputDirectory 'prefix/arm64-v8a'
$started = Get-Date
# Keep prior attempts reviewable, including real compilation logs when a later
# invocation only rechecks an already-built target.
$attemptArchive = Join-Path $logs ("previous/$Dependency-" + $started.ToString('yyyyMMdd-HHmmss-fff'))
foreach ($previousLog in (Get-ChildItem -LiteralPath $logs -Filter "$Dependency-*" -File)) {
    [IO.Directory]::CreateDirectory($attemptArchive) | Out-Null
    Copy-Item -LiteralPath $previousLog.FullName -Destination $attemptArchive
}
$previousResult = Join-Path $OutputDirectory "$Dependency-build-result.json"
if (Test-Path -LiteralPath $previousResult) {
    [IO.Directory]::CreateDirectory($attemptArchive) | Out-Null
    Copy-Item -LiteralPath $previousResult -Destination $attemptArchive
}
$arguments = @('-Wno-deprecated','-S',$source,'-B',$build,'-G','Ninja',"-DCMAKE_MAKE_PROGRAM=$ninja", "-DCMAKE_TOOLCHAIN_FILE=$NdkRoot/build/cmake/android.toolchain.cmake",'-DANDROID_ABI=arm64-v8a','-DANDROID_PLATFORM=android-30','-DANDROID_STL=c++_shared','-DCMAKE_BUILD_TYPE=Release',"-DCMAKE_INSTALL_PREFIX=$prefix", "-DCMAKE_FIND_ROOT_PATH=$prefix", "-DCMAKE_PREFIX_PATH=$prefix",'-DCMAKE_INSTALL_LIBDIR=lib','-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384')
switch ($Dependency) {
    'SDL2' { $arguments += @('-DSDL_SHARED=ON','-DSDL_STATIC=OFF','-DSDL_TEST=OFF'); $libraryNames=@('libSDL2.so') }
    'libogg' { $arguments += @('-DBUILD_SHARED_LIBS=ON','-DBUILD_TESTING=OFF','-DINSTALL_DOCS=OFF'); $libraryNames=@('libogg.so') }
    'libvorbis' {
        if (!(Test-Path -LiteralPath (Join-Path $prefix 'lib/libogg.so'))) { throw 'Build libogg first in this output prefix.' }
        $arguments += @('-DBUILD_SHARED_LIBS=ON','-DBUILD_TESTING=OFF'); $libraryNames=@('libvorbis.so','libvorbisfile.so','libvorbisenc.so')
    }
    'libpng' {
        $arguments += @('-DPNG_SHARED=ON','-DPNG_STATIC=OFF','-DPNG_TESTS=OFF','-DPNG_TOOLS=OFF'); $libraryNames=@('libpng16.so')
        # NDK ships the zlib ABI/header, but not zlib.pc. Derive the header's
        # declared version instead of copying another NDK release's version.
        $zlibHeader = Get-Content -LiteralPath (Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/include/zlib.h') -Raw
        if ($zlibHeader -notmatch '#define ZLIB_VERSION\s+"([^"]+)"') { throw 'Cannot determine NDK zlib header version.' }
        $zlibVersion = $Matches[1]
        $pkgConfig = Join-Path $prefix 'lib/pkgconfig'
        [IO.Directory]::CreateDirectory($pkgConfig) | Out-Null
        [IO.File]::WriteAllText((Join-Path $pkgConfig 'zlib.pc'),"Name: zlib`nDescription: Android NDK system zlib ABI`nVersion: $zlibVersion`nLibs: -lz`nCflags:`n",[Text.UTF8Encoding]::new($false))
    }
    'physfs' { $arguments += @('-DPHYSFS_BUILD_SHARED=ON','-DPHYSFS_BUILD_STATIC=OFF','-DPHYSFS_BUILD_TEST=OFF','-DPHYSFS_BUILD_DOCS=OFF'); $libraryNames=@('libphysfs.so') }
    'freetype' {
        if (!(Test-Path -LiteralPath (Join-Path $prefix 'lib/libpng16.so'))) { throw 'Build locked libpng first in this output prefix.' }
        $arguments += @('-DBUILD_SHARED_LIBS=ON','-DFT_REQUIRE_ZLIB=ON','-DFT_REQUIRE_PNG=ON','-DFT_DISABLE_BZIP2=ON','-DFT_DISABLE_HARFBUZZ=ON','-DFT_DISABLE_BROTLI=ON')
        $libraryNames=@('libfreetype.so')
        # The pinned fork expects the same vendored dlg copy as autogen.sh;
        # CMake needs no Autoconf regeneration.
        $dlgSource = Join-Path $source 'subprojects/dlg'
        [IO.Directory]::CreateDirectory((Join-Path $source 'include/dlg')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $source 'src/dlg')) | Out-Null
        foreach ($header in @('output.h','dlg.h')) { Copy-Item -LiteralPath (Join-Path $dlgSource "include/dlg/$header") -Destination (Join-Path $source "include/dlg/$header") }
        Get-ChildItem -LiteralPath (Join-Path $dlgSource 'src/dlg') -File | Copy-Item -Destination (Join-Path $source 'src/dlg')
    }
}
Invoke-Checked $cmake $arguments (Join-Path $logs "$Dependency-configure.log")
Invoke-Checked $cmake @('--build',$build,'--parallel',"$Jobs") (Join-Path $logs "$Dependency-build.log")
Invoke-Checked $cmake @('--install',$build) (Join-Path $logs "$Dependency-install.log")
if ($Dependency -eq 'libpng') {
    # Upstream generates Android .pc files but suppresses their installation
    # solely because CMAKE_HOST_WIN32 is true. Install the generated metadata
    # for the later native Windows Meson/pkg-config consumer.
    $pkgConfig = Join-Path $prefix 'lib/pkgconfig'
    [IO.Directory]::CreateDirectory($pkgConfig) | Out-Null
    foreach ($pcName in @('libpng.pc','libpng16.pc')) {
        $generatedPc = Join-Path $build $pcName
        if (!(Test-Path -LiteralPath $generatedPc)) { throw "Generated libpng metadata missing: $pcName" }
        Copy-Item -LiteralPath $generatedPc -Destination $pkgConfig
    }
}
$readelf = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
$artifacts = foreach ($libraryName in $libraryNames) {
    $library = Join-Path $prefix "lib/$libraryName"
    if (!(Test-Path -LiteralPath $library)) { throw "Expected $Dependency shared library is missing: $libraryName" }
    $elfLog = if ($libraryNames.Count -eq 1) { Join-Path $logs "$Dependency-elf.txt" } else { Join-Path $logs "$Dependency-$libraryName.elf.txt" }
    Invoke-Checked $readelf @('-h','-l','-d',$library) $elfLog | Out-Null
    $elf = Get-Content -LiteralPath $elfLog
    if (($elf -join "`n") -notmatch 'Machine:\s+AArch64') { throw 'Built library is not AArch64.' }
    $loads = @($elf | Where-Object { $_ -match '^\s+LOAD\s' })
    if (!$loads.Count -or @($loads | Where-Object { $_ -notmatch '0x4000\s*$' }).Count) { throw 'Expected 16 KiB PT_LOAD alignment on every segment.' }
    if (($elf -join "`n") -notmatch ('Library soname: \[' + [regex]::Escape($libraryName) + '\]')) { throw "Unexpected $Dependency SONAME." }
    @{path=$library;sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant()}
}
@{dependency=$Dependency;sourceCommit=$head;ndkRevision=$lock.ndkRevision;abi='arm64-v8a';api=30;started=$started.ToString('o');finished=(Get-Date).ToString('o');artifacts=@($artifacts);deviceValidated=$false} |
 ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory "$Dependency-build-result.json") -Encoding utf8
Write-Host "Built and inspected $Dependency libraries in $prefix/lib"
