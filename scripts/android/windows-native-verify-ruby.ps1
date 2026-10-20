[CmdletBinding()]
param([string]$OutputDirectory,[string]$NdkRoot)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = Join-Path $repository 'temp'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $temporary 'windows-native' }
if (!$NdkRoot) { $NdkRoot = Join-Path $temporary 'tools/android-ndk-r25c' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (!$OutputDirectory.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Ruby verification output must stay inside this checkout temp.' }
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
if ((Get-Content -LiteralPath (Join-Path $NdkRoot 'source.properties') -Raw) -notmatch ('Pkg.Revision\s*=\s*' + [regex]::Escape($lock.ndkRevision))) { throw 'NDK revision differs from lock.' }
$source = Join-Path $OutputDirectory 'sources/ruby-3.4.10'
$mkmfHash = (Get-FileHash -LiteralPath (Join-Path $source 'lib/mkmf.rb') -Algorithm SHA256).Hash.ToLowerInvariant()
if ($mkmfHash -ne $lock.dependencies.ruby.hostPatch.afterSha256) { throw 'Ruby mkmf source no longer matches the accepted host patch.' }
$build = Join-Path $OutputDirectory 'build/ruby'
$logs = Join-Path $OutputDirectory 'logs'
$bin = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$readelf = Join-Path $bin 'llvm-readelf.exe'
$nm = Join-Path $bin 'llvm-nm.exe'
$exts = Get-Content -LiteralPath (Join-Path $build 'exts.mk') -Raw
$registration = Get-Content -LiteralPath (Join-Path $build 'ext/extinit.c') -Raw
$makefile = Get-Content -LiteralPath (Join-Path $build 'Makefile') -Raw
if ($makefile -notmatch '(?m)^EXTSTATIC\s*=\s*static\s*$' -or $makefile -notmatch '(?m)^ENABLE_SHARED\s*=\s*yes\s*$') { throw 'Expected shared Ruby with static-linked extensions.' }
if (!$makefile.Contains('--disable-rpath')) { throw 'Ruby was not configured with --disable-rpath.' }
$rubyPc = Get-Content -LiteralPath (Join-Path $OutputDirectory 'prefix/arm64-v8a/lib/pkgconfig/ruby-3.4.pc') -Raw
if ($rubyPc -match '-rpath') { throw 'Ruby pkg-config metadata contains a runtime search path.' }
$logicalExts = $exts -replace '\\\r?\n[ \t]*', ' '
$initLine = [regex]::Match($logicalExts,'(?m)^EXTINITS\s*=([^\r\n]*)').Groups[1].Value
$archives = foreach ($extension in @('openssl','socket','zlib')) {
    $extensionDirectory = Join-Path $build "ext/$extension"
    if ((Get-Content -LiteralPath (Join-Path $extensionDirectory 'Makefile') -TotalCount 1) -match 'DUMMY') { throw "Extension is still a dummy: $extension" }
    if ($initLine -notmatch ('\b' + [regex]::Escape($extension) + '\b') -or $exts.Replace('\','/') -notmatch [regex]::Escape("ext/$extension/$extension.a")) { throw "Static extension absent from EXTOBJS/EXTINITS: $extension" }
    if ($registration -notmatch ('init\(\s*Init_' + $extension + '\s*,\s*"' + $extension + '"\s*\)')) { throw "Missing embedded module registration: $extension" }
    $archive = Join-Path $extensionDirectory "$extension.a"
    if (!(Test-Path -LiteralPath $archive)) { throw "Static archive missing: $archive" }
    $headers = & $readelf -h $archive
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect $extension archive." }
    $headers | Set-Content -LiteralPath (Join-Path $logs "ruby-$extension-archive.elf.txt")
    $machines = @($headers | Where-Object { $_ -match '^\s*Machine:' })
    if (!$machines.Count -or @($machines | Where-Object { $_ -notmatch 'AArch64\s*$' }).Count) { throw "Archive contains non-ARM64 or missing ELF members: $extension" }
    $symbols = & $nm --defined-only $archive
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect $extension symbols." }
    $symbols | Set-Content -LiteralPath (Join-Path $logs "ruby-$extension-archive.symbols.txt")
    if (($symbols -join "`n") -notmatch ('(?m)\bInit_' + $extension + '\s*$')) { throw "Archive lacks Init_$extension." }
    @{name=$extension;path=$archive;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant();elfMembers=$machines.Count;registered=$true}
}
$library = Join-Path $OutputDirectory 'prefix/arm64-v8a/lib/libruby.so'
$elf = & $readelf -h -l -d -n $library
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect installed Ruby ELF.' }
$elf | Set-Content -LiteralPath (Join-Path $logs 'ruby-complete.elf.txt')
$elfText = $elf -join "`n"
if ($elfText -notmatch 'Machine:\s+AArch64' -or $elfText -notmatch 'Library soname: \[libruby.so\]') { throw 'Ruby ABI/SONAME mismatch.' }
if ($elfText -match '\((?:RPATH|RUNPATH)\)') { throw 'Installed Ruby ELF contains RPATH/RUNPATH.' }
$loads = @($elf | Where-Object { $_ -match '^\s+LOAD\s' })
if (!$loads.Count -or @($loads | Where-Object { $_ -notmatch '0x4000\s*$' }).Count) { throw 'Ruby LOAD segment alignment differs from 16 KiB.' }
foreach ($dependency in @('libssl.so','libcrypto.so','libz.so')) {
    if ($elfText -notmatch ('\(NEEDED\).*Shared library: \[' + [regex]::Escape($dependency) + '\]')) { throw "Ruby dynamic dependency missing: $dependency" }
}
$symbols = & $nm --defined-only $library
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect complete Ruby symbols.' }
$symbols | Set-Content -LiteralPath (Join-Path $logs 'ruby-complete.symbols.txt')
foreach ($symbol in @('ruby_init','Init_ext','Init_openssl','Init_socket','Init_zlib')) {
    if (($symbols -join "`n") -notmatch ('(?m)\b' + $symbol + '\s*$')) { throw "Complete Ruby library lacks $symbol." }
}
@{verifiedAt=(Get-Date).ToString('o');artifact=$library;sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $library).Length;abi='arm64-v8a';api=30;soname='libruby.so';loadAlignment=16384;runtimeSearchPath='none';extensionModel='static modules embedded in shared libruby';archives=@($archives);mkmfSha256=$mkmfHash;deviceValidated=$false;targetExecuted=$false} |
 ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'ruby-module-validation.json') -Encoding utf8
Write-Host 'PASS: installed ARM64 libruby plus actual openssl/socket/zlib archives, registrations, Init symbols, dependencies, 16 KiB LOAD alignment and no RPATH/RUNPATH.'
