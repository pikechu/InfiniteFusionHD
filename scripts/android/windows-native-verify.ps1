[CmdletBinding()]
param([string]$OutputDirectory,[string]$NdkRoot)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = Join-Path $repository 'temp'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $temporary 'windows-native' }
if (!$NdkRoot) { $NdkRoot = Join-Path $temporary 'tools/android-ndk-r25c' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (!$OutputDirectory.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Verification output must stay inside this checkout temp.' }
$prefix = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'prefix/arm64-v8a'))
$bin = Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$readelf = Join-Path $bin 'llvm-readelf.exe'
$nm = Join-Path $bin 'llvm-nm.exe'
$logs = Join-Path $OutputDirectory 'logs'
[IO.Directory]::CreateDirectory($logs) | Out-Null
$requiredSymbols = @{
  'libSDL2.so'=@('SDL_Init','Java_org_libsdl_app_SDLActivity_nativeSetupJNI')
  'libcrypto.so'=@('OPENSSL_init_crypto')
  'libssl.so'=@('OPENSSL_init_ssl')
  'libogg.so'=@('ogg_sync_init')
  'libvorbis.so'=@('vorbis_synthesis_init')
  'libvorbisfile.so'=@('ov_open_callbacks')
  'libvorbisenc.so'=@('vorbis_encode_init')
  'libpng16.so'=@('png_create_read_struct')
  'libphysfs.so'=@('PHYSFS_init','PHYSFS_openRead')
  'libfreetype.so'=@('FT_Init_FreeType','FT_New_Face','FT_Load_Glyph','FT_Render_Glyph')
}
$verified = foreach ($manifestFile in (Get-ChildItem -LiteralPath $OutputDirectory -Filter '*-build-result.json' -File)) {
    $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
    $artifacts = if ($manifest.artifacts) { @($manifest.artifacts) } else { @(@{path=$manifest.artifact;sha256=$manifest.sha256}) }
    foreach ($artifact in $artifacts) {
        if (!$artifact.path -or !$artifact.sha256 -or $artifact.sha256.Length -ne 64) { throw "Malformed artifact manifest: $($manifestFile.Name)" }
        $library = [IO.Path]::GetFullPath($artifact.path)
        if (!$library.StartsWith($prefix + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Artifact escaped the expected install prefix.' }
        if ((Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant() -ne $artifact.sha256) { throw "Artifact hash changed: $library" }
        $name = [IO.Path]::GetFileName($library)
        $elf = & $readelf -h -l -d -n $library
        if ($LASTEXITCODE -ne 0) { throw "readelf failed: $name" }
        $elf | Set-Content -LiteralPath (Join-Path $logs "verified-$name.elf.txt")
        $elfText = $elf -join "`n"
        if ($elfText -notmatch 'Machine:\s+AArch64' -or $elfText -notmatch ('Library soname: \[' + [regex]::Escape($name) + '\]')) { throw "Unexpected ABI/SONAME: $name" }
        $loads = @($elf | Where-Object { $_ -match '^\s+LOAD\s' })
        if (!$loads.Count -or @($loads | Where-Object { $_ -notmatch '0x4000\s*$' }).Count) { throw "LOAD alignment mismatch: $name" }
        $symbols = & $nm --dynamic --defined-only $library
        if ($LASTEXITCODE -ne 0) { throw "Symbol inspection failed: $name" }
        $symbols | Set-Content -LiteralPath (Join-Path $logs "verified-$name.exports.txt")
        foreach ($symbol in $requiredSymbols[$name]) {
            if (($symbols -join "`n") -notmatch ('\b' + [regex]::Escape($symbol) + '(?:@@[^\s]+)?\s*(?:\r?\n|$)')) { throw "Required export missing: $name/$symbol" }
        }
        @{name=$name;sha256=$artifact.sha256;bytes=(Get-Item -LiteralPath $library).Length;loadSegmentCount=$loads.Count;requiredExports=@($requiredSymbols[$name]);deviceValidated=$false}
    }
}
if (!$verified.Count) { throw 'No build manifests found.' }
@{verifiedAt=(Get-Date).ToString('o');scope='rebuilt component ELF/hash/export checks; not device execution or whole-APK 16KiB validation';artifacts=@($verified)} |
 ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'component-verification.json') -Encoding utf8
Write-Host "Component ELF/hash/export checks passed for $($verified.Count) libraries."
