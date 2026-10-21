[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('openal','SDL2_ttf','SDL2_sound','SDL2_image','uchardet','pixman','libtheora')][string]$Dependency,
    [string]$SourceDirectory,
    [string]$OutputDirectory,
    [switch]$Fetch
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = Join-Path $repository 'temp'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $temporary 'windows-native' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (!$OutputDirectory.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Preparation output must stay below this checkout temp.' }
$source = if ($SourceDirectory) { [IO.Path]::GetFullPath($SourceDirectory) } else { Join-Path $OutputDirectory "sources/$Dependency" }
if (!$source.StartsWith($temporary + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Source must stay below this checkout temp.' }
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-native-lock.json') -Raw | ConvertFrom-Json
$pin = $lock.dependencies.$Dependency
if (!$pin -or $pin.commit -notmatch '^[a-f0-9]{40}$') { throw 'Dependency has no exact commit lock.' }
function Invoke-Git([string[]]$Arguments) {
    $value = & git @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git failed while preparing $Dependency (exit $LASTEXITCODE)." }
    return $value
}
if (!(Test-Path -LiteralPath (Join-Path $source '.git'))) {
    if (Test-Path -LiteralPath $source) { throw 'Existing source without its own Git metadata will not be altered.' }
    if (!$Fetch) { throw 'Locked source missing; use -Fetch.' }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $source)) | Out-Null
    Invoke-Git @('init',$source) | Out-Host
    Invoke-Git @('-C',$source,'remote','add','origin',$pin.url) | Out-Host
    Invoke-Git @('-C',$source,'-c','http.sslBackend=openssl','fetch','--depth','1','origin',$pin.commit) | Out-Host
    Invoke-Git @('-C',$source,'checkout','--detach','FETCH_HEAD') | Out-Host
}
$head = (Invoke-Git @('-C',$source,'rev-parse','HEAD')).Trim()
if ($head -ne $pin.commit) { throw 'Source HEAD differs from exact lock; refusing to change checkout.' }
$status = @(Invoke-Git @('-C',$source,'status','--porcelain'))
if ($status.Count) { throw 'Source checkout has modifications; refusing to overwrite them.' }
$links = @(Invoke-Git @('-C',$source,'ls-tree','-r','HEAD') | Where-Object { $_ -match '^160000 commit ' })
foreach ($unused in $pin.unusedGitlinks) {
    if (@($links | Where-Object { $_ -eq ("160000 commit " + $unused.commit + "`t" + $unused.path) }).Count -ne 1) { throw 'Unused codec gitlink differs from exact lock.' }
}
$modulesFile = Join-Path $source '.gitmodules'
$modules = if (Test-Path -LiteralPath $modulesFile) { [IO.File]::ReadAllText($modulesFile) } else { '' }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$result = @{dependency=$Dependency;source=$source;url=$pin.url;commit=$head;gitlinks=$links;gitmodules=$modules;preparedAt=(Get-Date).ToString('o');compiled=$false;targetExecuted=$false;nestedDependenciesPrepared=$false}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory "$Dependency-source-preparation.json") -Encoding utf8
Write-Host "Prepared and inspected $Dependency at $head; $($links.Count) gitlinks; no compiler/build system started."
