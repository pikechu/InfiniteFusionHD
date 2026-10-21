[CmdletBinding()]
param(
    [switch]$Offline
)

# This prepares a pinned PREBUILT runtime for compatibility experiments. It does
# not reproduce the native source build. All downloads/generated files stay in temp.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tempRoot = Join-Path $repoRoot 'temp'
$cacheRoot = Join-Path $tempRoot 'android-runtime'
$generatedRoot = Join-Path $tempRoot 'android-generated'
$runtimeCommit = '68653811c3c396f2d4c12225c52c407746285a3d'
$runtimeTag = 'uranium-android@0.4.1'
$apkUrl = 'https://codeberg.org/warmwinter/mkxp-z/releases/download/uranium-android@0.4.1/uranium.apk'
$apkSha256 = '35b8cd4e8b6b18fe6364c6af72ccd1801399c62590a093c6d0ffa98b5754b591'
$sourceUrl = 'https://codeberg.org/warmwinter/mkxp-z.git'

function Assert-TempPath([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated path must stay beneath the repository temp directory: $absolute"
    }
    return $absolute
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-VerifiedDownload([string]$Url, [string]$Destination, [string]$ExpectedHash, [string]$ExistingCandidate) {
    $Destination = Assert-TempPath $Destination
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        if ((Get-Sha256 $Destination) -ne $ExpectedHash) {
            throw "Cached runtime checksum mismatch: $Destination. No file has been executed or extracted."
        }
        return
    }
    if ($ExistingCandidate -and (Test-Path -LiteralPath $ExistingCandidate -PathType Leaf)) {
        if ((Get-Sha256 $ExistingCandidate) -eq $ExpectedHash) {
            Copy-Item -LiteralPath $ExistingCandidate -Destination $Destination
            return
        }
    }
    if ($Offline) { throw "Offline cache missing: $Destination" }
    $partial = Assert-TempPath ($Destination + '.part')
    Write-Host "Downloading pinned runtime artifact: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $partial -TimeoutSec 600 -UseBasicParsing
    $actualHash = Get-Sha256 $partial
    if ($actualHash -ne $ExpectedHash) {
        throw "Downloaded runtime checksum mismatch: expected $ExpectedHash, received $actualHash. Partial download remains at $partial."
    }
    Move-Item -LiteralPath $partial -Destination $Destination
}

function Export-PinnedSource([string]$Destination) {
    # Git's content-addressed commit/tree verifies the corresponding source even
    # when forge-generated ZIP compression changes. No branch name is trusted.
    $gitExecutable = (Get-Command git -ErrorAction Stop).Source
    $candidateRoots = @((Join-Path $tempRoot 'runtime-research/warmwinter'),
        (Join-Path $cacheRoot 'source-git'))
    $selected = $null
    foreach ($candidate in $candidateRoots) {
        if (-not (Test-Path -LiteralPath (Join-Path $candidate '.git'))) { continue }
        $resolved = & $gitExecutable -C $candidate rev-parse --verify "$runtimeCommit^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $resolved -eq $runtimeCommit) { $selected = $candidate; break }
    }
    if ($null -eq $selected) {
        if ($Offline) { throw "Offline source commit missing: $runtimeCommit" }
        $selected = Assert-TempPath (Join-Path $cacheRoot 'source-git')
        [IO.Directory]::CreateDirectory($selected) | Out-Null
        & $gitExecutable -C $selected init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize isolated runtime source cache.' }
        & $gitExecutable -C $selected fetch --quiet --depth 1 $sourceUrl $runtimeCommit
        if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the pinned runtime source commit.' }
    }
    & $gitExecutable -C $selected fsck --full --strict --no-reflogs $runtimeCommit 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Runtime source object validation failed.' }
    & $gitExecutable -C $selected archive --format=zip "--output=$Destination" $runtimeCommit
    if ($LASTEXITCODE -ne 0) { throw 'Could not export the verified runtime source commit.' }
    return (Get-Sha256 $Destination)
}

function Expand-SafeZip([string]$ArchivePath, [string]$Destination) {
    $Destination = Assert-TempPath $Destination
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $prefix = $Destination.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $output = [IO.Path]::GetFullPath((Join-Path $Destination $name))
            if (-not $output.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes extraction directory: $($entry.FullName)"
            }
            # Refuse Unix symbolic links; no extracted file may redirect writes.
            if ((([int64]$entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw "Unexpected symbolic link in runtime source archive: $($entry.FullName)"
            }
            if ($entry.FullName.EndsWith('/')) {
                [IO.Directory]::CreateDirectory($output) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $output, $true)
        }
    } finally { $archive.Dispose() }
}

function Get-ElfMetadata([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or
        $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46 -or $bytes[4] -ne 2 -or $bytes[5] -ne 1) {
        throw "Expected a little-endian ELF64 shared library: $Path"
    }
    $machine = [BitConverter]::ToUInt16($bytes, 18)
    if ($machine -ne 183) { throw "Expected AArch64 ELF machine 183, received $machine in $Path" }
    $programHeaderOffset = [BitConverter]::ToUInt64($bytes, 32)
    $programHeaderSize = [BitConverter]::ToUInt16($bytes, 54)
    $programHeaderCount = [BitConverter]::ToUInt16($bytes, 56)
    $alignments = @()
    for ($index = 0; $index -lt $programHeaderCount; $index++) {
        $offset = [int]($programHeaderOffset + $index * $programHeaderSize)
        if ($offset + 56 -gt $bytes.Length) { throw "Invalid ELF program header in $Path" }
        if ([BitConverter]::ToUInt32($bytes, $offset) -eq 1) {
            $alignments += [BitConverter]::ToUInt64($bytes, $offset + 48)
        }
    }
    if ($alignments.Count -eq 0) { throw "No ELF LOAD segments in $Path" }
    return [ordered]@{
        machine = $machine
        minimumLoadAlignment = [uint64](($alignments | Measure-Object -Minimum).Minimum)
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Directory]::CreateDirectory((Assert-TempPath $cacheRoot)) | Out-Null
[IO.Directory]::CreateDirectory((Assert-TempPath $generatedRoot)) | Out-Null
$apkPath = Join-Path $cacheRoot 'warmwinter-uranium-0.4.1.apk'
$sourcePath = Join-Path $cacheRoot "warmwinter-$runtimeCommit-source.zip"
Get-VerifiedDownload $apkUrl $apkPath $apkSha256 (Join-Path $tempRoot 'runtime-research/uranium-0.4.1.apk')
$sourceSha256 = Export-PinnedSource $sourcePath

$sourceExport = Join-Path $cacheRoot "source-$runtimeCommit"
Expand-SafeZip $sourcePath $sourceExport
$sdlRoots = @(Get-ChildItem -LiteralPath $sourceExport -Filter SDLActivity.java -File -Recurse |
    Where-Object { $_.FullName -match '[\\/]android[\\/]app[\\/]src[\\/]main[\\/]java[\\/]org[\\/]libsdl[\\/]app[\\/]SDLActivity\.java$' })
if ($sdlRoots.Count -ne 1) { throw 'Pinned source archive must contain exactly one Android SDLActivity.java.' }
$sdlSource = $sdlRoots[0].Directory.FullName
$javaDestination = Assert-TempPath (Join-Path $generatedRoot 'java/org/libsdl/app')
[IO.Directory]::CreateDirectory($javaDestination) | Out-Null
$javaRecords = @()
foreach ($javaFile in (Get-ChildItem -LiteralPath $sdlSource -Filter '*.java' -File)) {
    $target = Join-Path $javaDestination $javaFile.Name
    Copy-Item -LiteralPath $javaFile.FullName -Destination $target -Force
    $javaRecords += [ordered]@{ path = "java/org/libsdl/app/$($javaFile.Name)"; sha256 = Get-Sha256 $target }
}

$libraryNames = @('libSDL2.so', 'libSDL2_image.so', 'libSDL2_sound.so', 'libSDL2_ttf.so',
    'libc++_shared.so', 'libcrypto.so', 'libfreetype.so', 'libiconv.so', 'libmkxp-z.so',
    'libogg.so', 'libopenal.so', 'libphysfs.so', 'libpixman-1.so', 'libpng.so', 'libruby.so',
    'libssl.so', 'libtheora.so', 'libtheoradec.so', 'libuchardet.so', 'libvorbis.so', 'libvorbisfile.so')
$libraryDestination = Assert-TempPath (Join-Path $generatedRoot 'jniLibs/arm64-v8a')
[IO.Directory]::CreateDirectory($libraryDestination) | Out-Null
$libraryRecords = @()
$apkArchive = [IO.Compression.ZipFile]::OpenRead($apkPath)
try {
    $nativeEntries = @($apkArchive.Entries | Where-Object { $_.FullName -match '^lib/.+\.so$' })
    if ($nativeEntries.Count -ne $libraryNames.Count) { throw 'Pinned APK has an unexpected native library count.' }
    foreach ($name in $libraryNames) {
        $entryName = "lib/arm64-v8a/$name"
        $entry = $apkArchive.GetEntry($entryName)
        if ($null -eq $entry) { throw "Missing pinned native library: $entryName" }
        $target = Join-Path $libraryDestination $name
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        $elf = Get-ElfMetadata $target
        $libraryRecords += [ordered]@{
            path = "jniLibs/arm64-v8a/$name"
            bytes = $entry.Length
            sha256 = Get-Sha256 $target
            elf = $elf
        }
    }
} finally { $apkArchive.Dispose() }

$runtimeSourceRoot = [IO.Path]::GetFullPath((Join-Path $sdlSource '../../../../../../../..'))
$licenseSource = Join-Path $runtimeSourceRoot 'COPYING'
if (-not (Test-Path -LiteralPath $licenseSource -PathType Leaf)) {
    # Derive from the exact Android project path, rather than picking a dependency license.
    $runtimeSourceRoot = $sdlRoots[0].FullName.Substring(0, $sdlRoots[0].FullName.IndexOf(
        ([IO.Path]::DirectorySeparatorChar + 'android' + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase))
    $licenseSource = Join-Path $runtimeSourceRoot 'COPYING'
}
$licenseDestination = Assert-TempPath (Join-Path $generatedRoot 'licenses')
[IO.Directory]::CreateDirectory($licenseDestination) | Out-Null
$rubyPatchHash = Get-Sha256 (Join-Path $runtimeSourceRoot 'patches/ruby-3.4.10-mkxp-z.patch')
if ($rubyPatchHash -ne 'f0d01a48c3135e8840aac242b766f485dde179d3db52340ef5efec4ee890639d') {
    throw 'The Ruby compatibility patch does not match the pinned runtime source.'
}
Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $licenseDestination 'mkxp-z-COPYING.txt') -Force
Copy-Item -LiteralPath (Join-Path $runtimeSourceRoot 'README.md') -Destination (Join-Path $licenseDestination 'mkxp-z-README.md') -Force

$provenance = [ordered]@{
    schemaVersion = 1
    runtime = 'warmwinter/mkxp-z'
    sourceCommit = $runtimeCommit
    releaseTag = $runtimeTag
    binaryOrigin = $apkUrl
    binarySha256 = $apkSha256
    sourceOrigin = $sourceUrl
    sourceArchiveSha256 = $sourceSha256
    rubyBinaryVersion = 'ruby 3.4.10 (2026-06-30 revision 2b0b7728dc) [aarch64-linux-android-android]'
    rubyPatchSha256 = $rubyPatchHash
    buildStatus = 'official-prebuilt-runtime; native-source-build-not-reproduced'
    abis = @('arm64-v8a')
    compatibility = '4KB page-size validation only; 19 native libraries have 4096-byte LOAD alignment'
    knownNetworkLimitation = 'Native HTTPLite disables TLS certificate verification; KIF wrapper must replace network requests with verified TLS'
    loadOrder = @('SDL2', 'SDL2_image', 'SDL2_ttf', 'SDL2_sound', 'openal', 'ruby', 'mkxp-z')
    libraries = $libraryRecords
    sdlJava = $javaRecords
}
$manifestPath = Join-Path $generatedRoot 'runtime-provenance.json'
$provenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "Prepared pinned ARM64 runtime libraries and matching SDL Java under $generatedRoot"
Write-Host 'This uses official prebuilt libraries. It is not a reproduced native source build and is not 16 KB-page compatible.'
Write-Host "Provenance: $manifestPath"
