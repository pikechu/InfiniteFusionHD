[CmdletBinding()]
param([ValidateSet('Prepare','Build','ResumeBuild')][string]$Stage='Prepare',[string]$OutputDirectory,[string]$MsysRoot,[string]$NdkRoot,[ValidateRange(1,16)][int]$Jobs=1)
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary=Join-Path $repository 'temp'
if (!$OutputDirectory) { $OutputDirectory=Join-Path $temporary 'windows-native' }
if (!$MsysRoot) { $MsysRoot=Join-Path $temporary 'tools/msys64' }
if (!$NdkRoot) { $NdkRoot=Join-Path $temporary 'tools/android-ndk-r25c' }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if (!$OutputDirectory.StartsWith($temporary+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Theora output must stay within this checkout temp.' }
$lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
if ((Get-Content -LiteralPath (Join-Path $NdkRoot 'source.properties') -Raw) -notmatch ('Pkg.Revision\s*=\s*'+[regex]::Escape($lock.ndkRevision))) { throw 'NDK revision differs from lock.' }
$environment=Get-Content -LiteralPath (Join-Path $temporary 'core-tools/environment.json') -Raw | ConvertFrom-Json
$source=Join-Path $OutputDirectory 'sources/libtheora'
if ((& git -C $source rev-parse HEAD).Trim() -ne $lock.dependencies.libtheora.commit -or (& git -C $source status --porcelain).Count) { throw 'Locked original Theora Git checkout is missing or modified.' }
$generated=Join-Path $OutputDirectory 'generated-sources/libtheora'
$manifest=Join-Path $OutputDirectory 'libtheora-source-export.json'
if (!(Test-Path -LiteralPath $generated)) {
    [IO.Directory]::CreateDirectory($generated) | Out-Null
    $archive=Join-Path $OutputDirectory 'libtheora-git-export.tar'
    & git -c core.autocrlf=false -C $source archive --format=tar "--output=$archive" HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Theora Git export failed.' }
    & (Join-Path $MsysRoot 'usr/bin/bsdtar.exe') -xf $archive -C $generated
    if ($LASTEXITCODE -ne 0) { throw 'Theora Git export extraction failed.' }
    $files=@{}
    foreach ($relative in (& git -C $source ls-files)) { $files[$relative]=(Get-FileHash -LiteralPath (Join-Path $generated $relative) -Algorithm SHA256).Hash.ToLowerInvariant() }
    @{sourceCommit=$lock.dependencies.libtheora.commit;archiveSha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant();files=$files} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding utf8
}
$base=Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
if ($base.sourceCommit -ne $lock.dependencies.libtheora.commit) { throw 'Generated-source base differs from locked commit.' }
foreach ($entry in $base.files.PSObject.Properties) {
    if ((Get-FileHash -LiteralPath (Join-Path $generated $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value) { throw "Theora original source was modified after export: $($entry.Name)" }
}
$logs=Join-Path $OutputDirectory 'logs'
$snapshotDirectory=Join-Path $OutputDirectory 'scripts'
foreach ($path in @($logs,$snapshotDirectory)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
$started=Get-Date
$previous=Join-Path $logs ('previous/libtheora-'+$started.ToString('yyyyMMdd-HHmmss-fff'))
foreach ($log in (Get-ChildItem -LiteralPath $logs -Filter 'libtheora-*' -File)) { [IO.Directory]::CreateDirectory($previous) | Out-Null; Copy-Item -LiteralPath $log.FullName -Destination $previous }
$snapshot=Join-Path $snapshotDirectory ('theora-'+[Guid]::NewGuid().ToString('N')+'.sh')
[IO.File]::WriteAllText($snapshot,[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'windows-native-theora.sh')).Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
& (Join-Path $MsysRoot 'usr/bin/bash.exe') --noprofile --norc $snapshot.Replace('\','/') $generated.Replace('\','/') $OutputDirectory.Replace('\','/') ([IO.Path]::GetFullPath($NdkRoot)).Replace('\','/') $environment.pkgconf.Replace('\','/') $Stage $Jobs
if ($LASTEXITCODE -ne 0) { throw "Theora $Stage failed; inspect its logs." }
$artifacts=@()
if ($Stage -ne 'Prepare') {
    $prefix=Join-Path $OutputDirectory 'prefix/arm64-v8a'
    foreach ($name in @('theora','theoradec','theoraenc')) {
        $pc=Join-Path $prefix "lib/pkgconfig/$name.pc"
        $text=[IO.File]::ReadAllText($pc) -replace '(?m)^prefix=.*$',('prefix='+$prefix.Replace('\','/'))
        [IO.File]::WriteAllText($pc,$text,[Text.UTF8Encoding]::new($false))
    }
    $required=@{'libtheora.so'='theora_decode_init';'libtheoradec.so'='th_decode_alloc';'libtheoraenc.so'='th_encode_alloc'}
    $artifacts=foreach ($name in @('libtheora.so','libtheoradec.so','libtheoraenc.so')) {
        $library=Join-Path $prefix "lib/$name"
        $bin=Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin'
        $elf=& (Join-Path $bin 'llvm-readelf.exe') -h -l -d $library
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Theora ELF.' }
        $elf | Set-Content -LiteralPath (Join-Path $logs "libtheora-$name.elf.txt")
        $text=$elf -join "`n"
        $loads=@($elf | Where-Object { $_ -match '^\s+LOAD\s' })
        if ($text -notmatch 'Machine:\s+AArch64' -or $text -notmatch ('Library soname: \['+[regex]::Escape($name)+'\]') -or $text -match '\((?:RPATH|RUNPATH)\)' -or !$loads.Count -or @($loads | Where-Object { $_ -notmatch '0x4000\s*$' }).Count) { throw 'Theora ELF ABI/SONAME/alignment/search-path validation failed.' }
        $symbols=& (Join-Path $bin 'llvm-nm.exe') --dynamic --defined-only $library
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Theora dynamic exports.' }
        $symbols | Set-Content -LiteralPath (Join-Path $logs "libtheora-$name.symbols.txt")
        if (($symbols -join "`n") -notmatch ('(?m)\b'+$required[$name]+'(?:@@?[A-Za-z0-9_.-]+)?\s*$')) { throw "Theora required export missing: $($required[$name])" }
        @{name=$name;path=$library;bytes=(Get-Item -LiteralPath $library).Length;sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}
@{stage=$Stage;sourceCommit=$base.sourceCommit;exportArchiveSha256=$base.archiveSha256;started=$started.ToString('o');finished=(Get-Date).ToString('o');compiled=($Stage -ne 'Prepare');artifacts=@($artifacts);abi='arm64-v8a';api=30;deviceValidated=$false} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory "libtheora-$Stage-result.json") -Encoding utf8
Write-Host "Theora $Stage completed; logs in $logs"
