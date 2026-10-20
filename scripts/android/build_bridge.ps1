[CmdletBinding()]
param(
    [string]$NdkRoot,
    [string]$RuntimeDirectory,
    [string]$BuildDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = [IO.Path]::GetFullPath((Join-Path $repository 'temp'))
if (!$NdkRoot) { $NdkRoot = Join-Path $temporary 'tools/android-ndk-r25c' }
if (!$RuntimeDirectory) { $RuntimeDirectory = Join-Path $temporary 'android-generated/jniLibs/arm64-v8a' }
if (!$BuildDirectory) { $BuildDirectory = Join-Path $temporary 'android-bridge-build/arm64-v8a-api30' }
$NdkRoot = [IO.Path]::GetFullPath($NdkRoot)
$RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
foreach ($directory in @($RuntimeDirectory, $BuildDirectory)) {
    if (!$directory.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Bridge artifacts must stay below this checkout temp directory: $directory"
    }
}
$properties = Get-Content -LiteralPath (Join-Path $NdkRoot 'source.properties') -Raw
if ($properties -notmatch '(?m)^Pkg\.Revision\s*=\s*25\.2\.9519653\s*$') {
    throw 'This bridge build is pinned to Windows Android NDK r25c (25.2.9519653).'
}
$binaryDirectory = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$clang = Join-Path $binaryDirectory 'clang.exe'
$nm = Join-Path $binaryDirectory 'llvm-nm.exe'
$readelf = Join-Path $binaryDirectory 'llvm-readelf.exe'
$ruby = Join-Path $RuntimeDirectory 'libruby.so'
$source = Join-Path $repository 'android/native/kif_android_bridge.c'
foreach ($file in @($clang, $nm, $readelf, $ruby, $source)) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing bridge build input: $file" }
}
[IO.Directory]::CreateDirectory($BuildDirectory) | Out-Null

function Invoke-Checked([string]$program, [string[]]$toolArguments) {
    $output = @(& $program @toolArguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$program failed with exit code $LASTEXITCODE`n$($output -join "`n")" }
    return $output
}
function Get-Sha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$rubyExports = (Invoke-Checked $nm @('-D','--defined-only',$ruby)) -join "`n"
$requiredRuby = @('rb_define_module','rb_define_module_function','rb_string_value_cstr','rb_ary_new_from_args','rb_ull2inum',
    'rb_utf8_str_new','rb_protect','rb_jump_tag','rb_raise','rb_eRuntimeError')
foreach ($symbol in $requiredRuby) {
    if ($rubyExports -notmatch ('(?m)\s' + [regex]::Escape($symbol) + '$')) {
        throw "The supplied Ruby runtime does not export $symbol. No bridge was installed."
    }
}
$rubyExports | Set-Content -LiteralPath (Join-Path $BuildDirectory 'ruby-exports.log') -Encoding utf8
$compilerVersion = (Invoke-Checked $clang @('--version')) -join "`n"
$name = 'libkif_android_bridge.so'
$builtLibrary = Join-Path $BuildDirectory $name
$arguments = @('--target=aarch64-linux-android30','-std=c11','-O2','-fPIC',
    '-fvisibility=hidden','-Wall','-Wextra','-Werror','-Wstrict-prototypes','-Wformat=2',
    '-Wconversion','-Wsign-conversion','-pthread','-shared',
    '-Wl,--no-undefined',"-Wl,-soname,$name",'-Wl,-z,max-page-size=16384',
    '-Wl,--build-id=sha1',('-Wl,-rpath-link,' + $RuntimeDirectory),$source,$ruby,
    '-o',$builtLibrary)
Invoke-Checked $clang $arguments | Set-Content -LiteralPath (Join-Path $BuildDirectory 'compiler.log') -Encoding utf8
$exportsText = (Invoke-Checked $nm @('-D','--defined-only',$builtLibrary)) -join "`n"
$elfText = (Invoke-Checked $readelf @('-h','-l','-d',$builtLibrary)) -join "`n"
$exportsText | Set-Content -LiteralPath (Join-Path $BuildDirectory 'bridge-exports.log') -Encoding utf8
$elfText | Set-Content -LiteralPath (Join-Path $BuildDirectory 'bridge-elf.log') -Encoding utf8
$requiredExports = @('Java_org_kuray_kif_NetworkBridge_configure',
    'Java_org_kuray_kif_NetworkBridge_setVirtualKey','Java_org_kuray_kif_NetworkBridge_clearVirtualKeys',
    'Java_org_kuray_kif_NetworkBridge_requestTextInput',
    'Init_libkif_android_bridge','Init_kif_android_bridge')
foreach ($symbol in $requiredExports) {
    if ($exportsText -notmatch ('(?m)\s' + [regex]::Escape($symbol) + '$')) {
        throw "Bridge export missing: $symbol. No bridge was installed."
    }
}
if ($elfText -notmatch 'Machine:\s+AArch64' -or $elfText -notmatch 'Type:\s+DYN') {
    throw 'Bridge output is not an AArch64 shared ELF. No bridge was installed.'
}
$alignments = @([regex]::Matches($elfText, '(?m)^\s*LOAD\s+[^\r\n]*\s+(0x[0-9a-fA-F]+)\s*$') | ForEach-Object {
    [Convert]::ToInt64($_.Groups[1].Value.Substring(2),16)
})
if ($alignments.Count -eq 0 -or @($alignments | Where-Object { $_ -lt 16384 }).Count -ne 0) {
    throw 'Bridge LOAD segments are not all aligned to at least 16 KiB. No bridge was installed.'
}
$needed = @([regex]::Matches($elfText, '\(NEEDED\)[^\r\n]*\[([^\]]+)\]') | ForEach-Object { $_.Groups[1].Value })
if ($needed -notcontains 'libruby.so') { throw 'Bridge did not link to libruby.so. No bridge was installed.' }

# This source-built bridge is distinct from the publisher's prebuilt runtime set.
$provenance = [ordered]@{
    schemaVersion=1
    artifactKind='kif-android-source-built-jni-bridge'
    inputBridge=$true
    virtualInput=[ordered]@{mask='1U << RGSS logical button code';poll='[pressed,triggered,released]';
        acceptedCodes=@(2,4,6,8,11,12,13,14,15,16,17,18);pause='clear all held and edge masks';
        sdlCallbacksUsed=$false;networkPermissionRequired=$false}
    textInputRequest=[ordered]@{poll='text_input_request_poll: 0 or 1; consume once';
        transport='separate flag; input_poll triple unchanged';pause='discard pending request'}
    abi='arm64-v8a'
    minimumApi=30
    ndkRevision='25.2.9519653'
    compilerVersion=$compilerVersion
    compilerSha256=(Get-Sha256 $clang)
    source='android/native/kif_android_bridge.c'
    sourceSha256=(Get-Sha256 $source)
    rubyRuntimeSha256=(Get-Sha256 $ruby)
    requiredRubyExports=$requiredRuby
    definedExports=$requiredExports
    neededLibraries=$needed
    loadSegmentAlignments=$alignments
    limits=[ordered]@{requestBytes=65536;responseBytes=12582912}
    outputSha256=(Get-Sha256 $builtLibrary)
    compilerArguments=$arguments
}
$provenance | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $BuildDirectory 'provenance.json') -Encoding utf8
[IO.Directory]::CreateDirectory($RuntimeDirectory) | Out-Null
$installed = Join-Path $RuntimeDirectory $name
Copy-Item -LiteralPath $builtLibrary -Destination $installed -Force
Write-Host "Built and verified: $installed"
Write-Host "Bridge provenance: $(Join-Path $BuildDirectory 'provenance.json')"
Write-Host 'This builds only the JNI bridge; the publisher runtime libraries are unchanged.'
