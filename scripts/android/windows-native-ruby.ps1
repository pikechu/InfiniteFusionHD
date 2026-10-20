[CmdletBinding()]
param(
    [ValidateSet('PrepareOnly','Configure','Build','ResumeBuild')][string]$Stage = 'Configure',
    [string]$MsysRoot,
    [string]$NdkRoot,
    [string]$HostRuby,
    [string]$RuntimeSource,
    [string]$OutputDirectory,
    [ValidateRange(1,16)][int]$Jobs = 1,
    [switch]$Fetch
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = Join-Path $repository 'temp'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $temporary 'windows-native' }
if (!$MsysRoot) { $MsysRoot = Join-Path $temporary 'tools/msys64' }
if (!$NdkRoot) { $NdkRoot = Join-Path $temporary 'tools/android-ndk-r25c' }
if (!$HostRuby) { $HostRuby = Join-Path $temporary 'tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe' }
if (!$RuntimeSource) {
    $RuntimeSource = Join-Path $temporary 'android-runtime/source-68653811c3c396f2d4c12225c52c407746285a3d'
    if (!(Test-Path -LiteralPath $RuntimeSource)) { $RuntimeSource = Join-Path $repository '../runtime-research/warmwinter-release' }
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (!$OutputDirectory.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Outputs must stay under this checkout temp.' }
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
$rubyLock = $lock.dependencies.ruby
if ((Get-Content -LiteralPath (Join-Path $NdkRoot 'source.properties') -Raw) -notmatch ('Pkg.Revision\s*=\s*' + [regex]::Escape($lock.ndkRevision))) { throw 'NDK revision differs from lock.' }
$patch = [IO.Path]::GetFullPath((Join-Path $RuntimeSource 'patches/ruby-3.4.10-mkxp-z.patch'))
if ((Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rubyLock.patchSha256) { throw 'Runtime Ruby patch checksum mismatch.' }
function Invoke-Checked([string]$Program,[string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed: $LASTEXITCODE" }
}
$sources = Join-Path $OutputDirectory 'sources'
$logs = Join-Path $OutputDirectory 'logs'
foreach ($directory in @($sources,$logs)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
$normalizedPatch = Join-Path $OutputDirectory 'ruby-3.4.10-mkxp-z-lf.patch'
# The fixed runtime patch uses CRLF while the official Ruby tarball uses LF.
# Normalize only line endings after checking the original bytes, then verify
# the derived bytes as well. Never alter the runtime checkout's patch file.
[IO.File]::WriteAllText($normalizedPatch,[IO.File]::ReadAllText($patch).Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
if ((Get-FileHash -LiteralPath $normalizedPatch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rubyLock.patchLfSha256) { throw 'Normalized Ruby patch checksum mismatch.' }
$archive = Join-Path $OutputDirectory 'ruby-3.4.10.tar.gz'
if (!(Test-Path -LiteralPath $archive)) {
    if (!$Fetch) { throw 'Ruby release tarball missing; use -Fetch.' }
    Invoke-Checked 'curl.exe' @('--fail','--location','--retry','2','--output',$archive,$rubyLock.url)
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rubyLock.sha256) { throw 'Ruby archive checksum mismatch.' }
$source = Join-Path $sources 'ruby-3.4.10'
$marker = Join-Path $source '.kif-mkxp-patch-applied'
if (!(Test-Path -LiteralPath $source)) { Invoke-Checked "$env:SystemRoot/System32/tar.exe" @('-xzf',$archive,'-C',$sources) }
# Give git apply an explicit independent repository/work tree. Keep .git out of
# the Ruby source: Ruby's revision generator interprets an empty in-source Git
# repository as a checkout and fails when HEAD does not exist.
$patchRepository = Join-Path $OutputDirectory 'patch-git/ruby'
$patchGit = Join-Path $patchRepository '.git'
$oldSourceGit = Join-Path $source '.git'
if (Test-Path -LiteralPath $oldSourceGit) {
    if (!(Get-Item -LiteralPath $oldSourceGit -Force).PSIsContainer) { throw 'Unexpected Git indirection in Ruby source; refusing to move it.' }
    $oldSourceGit = [IO.Path]::GetFullPath($oldSourceGit)
    $destinationGit = if (Test-Path -LiteralPath $patchGit) { Join-Path $OutputDirectory ("retired-ruby-source-git-" + [Guid]::NewGuid().ToString('N')) } else { $patchGit }
    $destinationGit = [IO.Path]::GetFullPath($destinationGit)
    foreach ($checkedPath in @($oldSourceGit,$destinationGit)) {
        if (!$checkedPath.StartsWith($OutputDirectory + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Git metadata move escaped this task output directory.' }
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinationGit)) | Out-Null
    Move-Item -LiteralPath $oldSourceGit -Destination $destinationGit -Force
}
if (!(Test-Path -LiteralPath $patchGit)) { Invoke-Checked 'git' @('init',$patchRepository) }
Invoke-Checked 'git' @("--git-dir=$patchGit","--work-tree=$source",'config','core.autocrlf','false')
if (!(Test-Path -LiteralPath $marker)) {
    Invoke-Checked 'git' @('-C',$source,"--git-dir=$patchGit","--work-tree=$source",'apply','--check',$normalizedPatch)
    Invoke-Checked 'git' @('-C',$source,"--git-dir=$patchGit","--work-tree=$source",'apply',$normalizedPatch)
    Invoke-Checked 'git' @('-C',$source,"--git-dir=$patchGit","--work-tree=$source",'apply','--reverse','--check',$normalizedPatch)
    # The only configure.ac change affects a MinGW *target*. Android uses the
    # official generated configure, avoiding unnecessary host autoreconf.
    (Get-Item -LiteralPath (Join-Path $source 'configure')).LastWriteTime = Get-Date
    Set-Content -LiteralPath $marker -Value $rubyLock.patchSha256 -Encoding ascii
}
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne $rubyLock.patchSha256) { throw 'Ruby source patch marker differs from lock.' }
Invoke-Checked 'git' @('-C',$source,"--git-dir=$patchGit","--work-tree=$source",'apply','--reverse','--check',$normalizedPatch)
$hostPatchLock = $rubyLock.hostPatch
$hostPatch = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $hostPatchLock.path))
if ((Get-FileHash -LiteralPath $hostPatch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hostPatchLock.sha256) { throw 'Ruby Windows-host patch checksum mismatch.' }
$hostSource = Join-Path $source $hostPatchLock.sourceFile
$hostSourceHash = (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hostSourceHash -eq $hostPatchLock.beforeSha256) {
    Invoke-Checked 'git' @('-C',$source,"--git-dir=$patchGit","--work-tree=$source",'apply','--check',$hostPatch)
    Invoke-Checked 'git' @('-C',$source,"--git-dir=$patchGit","--work-tree=$source",'apply',$hostPatch)
} elseif ($hostSourceHash -ne $hostPatchLock.afterSha256) {
    throw 'Ruby mkmf source differs from the locked original and patched versions; refusing to overwrite it.'
}
# A marker alone cannot prove application. Check the resulting bytes and all
# reverse hunks on every invocation, including PrepareOnly and ResumeBuild.
Invoke-Checked 'git' @('-C',$source,"--git-dir=$patchGit","--work-tree=$source",'apply','--reverse','--check',$hostPatch)
$hostSourceHash = (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hostSourceHash -ne $hostPatchLock.afterSha256) { throw 'Patched mkmf source checksum mismatch.' }
@{version=$rubyLock.version;archiveSha256=$rubyLock.sha256;runtimePatchSha256=$rubyLock.patchSha256;runtimePatchLfSha256=$rubyLock.patchLfSha256;hostPatchSha256=$hostPatchLock.sha256;mkmfSha256=$hostSourceHash;source=$source;compiled=$false;preparedAt=(Get-Date).ToString('o')} |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'ruby-source-preparation.json') -Encoding utf8
if ($Stage -eq 'PrepareOnly') {
    Write-Host "Ruby source and both locked patches verified; no compiler/build system started: $source"
    return
}
$shell = Join-Path $PSScriptRoot 'windows-native-ruby.sh'
$bash = Join-Path $MsysRoot 'usr/bin/bash.exe'
$started = Get-Date
$attemptArchive = Join-Path $logs ("previous/ruby-" + $started.ToString('yyyyMMdd-HHmmss-fff'))
foreach ($previousLog in (Get-ChildItem -LiteralPath $logs -Filter 'ruby-*' -File)) {
    [IO.Directory]::CreateDirectory($attemptArchive) | Out-Null
    Copy-Item -LiteralPath $previousLog.FullName -Destination $attemptArchive
}
if ($Stage -eq 'ResumeBuild') {
    $makefile = Get-Content -LiteralPath (Join-Path $OutputDirectory 'build/ruby/Makefile') -Raw
    $expectedPrefix = (Join-Path $OutputDirectory 'prefix/arm64-v8a').Replace('\','/')
    $expectedCompiler = ([IO.Path]::GetFullPath($NdkRoot)).Replace('\','/') + '/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe --target=aarch64-linux-android30'
    foreach ($expected in @("prefix = $expectedPrefix","CC = $expectedCompiler",'--with-ext=openssl,socket,zlib,+','--with-static-linked-ext','--disable-yjit','--disable-rjit')) {
        if (!$makefile.Contains($expected)) { throw "Existing Ruby configuration does not match the locked build: $expected" }
    }
}
$snapshotDirectory = Join-Path $OutputDirectory 'scripts'
[IO.Directory]::CreateDirectory($snapshotDirectory) | Out-Null
$snapshot = Join-Path $snapshotDirectory ("ruby-" + [Guid]::NewGuid().ToString('N') + '.sh')
[IO.File]::WriteAllText($snapshot,[IO.File]::ReadAllText($shell).Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
& $bash --noprofile --norc $snapshot.Replace('\','/') $source.Replace('\','/') ([IO.Path]::GetFullPath($NdkRoot)).Replace('\','/') $OutputDirectory.Replace('\','/') ([IO.Path]::GetFullPath($HostRuby)).Replace('\','/') $Stage $Jobs *>&1 | Tee-Object -FilePath (Join-Path $logs 'ruby-host.log')
if ($LASTEXITCODE -ne 0) { throw "Ruby $Stage failed; see $logs/ruby-configure.log and ruby-build.log." }
if ($Stage -in @('Build','ResumeBuild')) {
    $library = Join-Path $OutputDirectory 'prefix/arm64-v8a/lib/libruby.so'
    if (!(Test-Path -LiteralPath $library)) { throw 'Expected libruby.so artifact missing.' }
    $readelf = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
    $elf = & $readelf -h -l -d $library
    if ($LASTEXITCODE -ne 0) { throw 'Ruby ELF inspection failed.' }
    $elf | Set-Content -LiteralPath (Join-Path $logs 'ruby-elf.txt')
    $elfText = $elf -join "`n"
    if ($elfText -notmatch 'Machine:\s+AArch64' -or $elfText -notmatch 'Library soname: \[libruby.so\]') { throw 'Unexpected Ruby ABI or SONAME.' }
    $loads = @($elf | Where-Object { $_ -match '^\s+LOAD\s' })
    if (!$loads.Count -or @($loads | Where-Object { $_ -notmatch '0x4000\s*$' }).Count) { throw 'Expected 16 KiB PT_LOAD alignment on every Ruby segment.' }
    $nm = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-nm.exe'
    $symbols = & $nm --defined-only $library
    if ($LASTEXITCODE -ne 0) { throw 'Ruby symbol inspection failed.' }
    $symbols | Set-Content -LiteralPath (Join-Path $logs 'ruby-defined-symbols.txt')
    foreach ($symbol in @('ruby_init','Init_openssl','Init_socket','Init_zlib')) {
        if (($symbols -join "`n") -notmatch ('\b' + [regex]::Escape($symbol) + '\s*(?:\r?\n|$)')) { throw "Required Ruby symbol missing: $symbol" }
    }
    @{dependency='ruby';version=$rubyLock.version;sourceArchiveSha256=$rubyLock.sha256;patchSha256=$rubyLock.patchSha256;hostPatchSha256=$hostPatchLock.sha256;mkmfSha256=$hostSourceHash;mandatoryExtensions=@('openssl','socket','zlib');ndkRevision=$lock.ndkRevision;abi='arm64-v8a';api=30;started=$started.ToString('o');finished=(Get-Date).ToString('o');artifact=$library;sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant();deviceValidated=$false} |
      ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'ruby-build-result.json') -Encoding utf8
}
Write-Host "Ruby $Stage completed; evidence: $OutputDirectory"
