[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Profile = 'player-a',
    [ValidateSet('Game.exe','Game-compatibility.exe')][string]$Executable = 'Game.exe',
    [string]$CustomScript = '',
    [string]$GameRoot = ''
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $GameRoot) { $GameRoot = $repository }
$stage = Join-Path $repository "temp/multiplayer/$Profile"
[IO.Directory]::CreateDirectory($stage) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $stage 'saves')) | Out-Null
function Copy-RuntimeFile([string]$Source, [string]$Destination) {
    if ((Test-Path -LiteralPath $Destination) -and
        ((Get-Item -LiteralPath $Source).Length -eq (Get-Item -LiteralPath $Destination).Length) -and
        ((Get-Item -LiteralPath $Source).LastWriteTimeUtc -eq (Get-Item -LiteralPath $Destination).LastWriteTimeUtc)) { return }
    # Replace this profile's link, never overwrite it: writing into a hard link
    # would also overwrite the repository executable when switching runtimes.
    $absoluteDestination = [IO.Path]::GetFullPath($Destination)
    $stagePrefix = [IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
    if (-not $absoluteDestination.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime destination is outside this test profile'
    }
    if (Test-Path -LiteralPath $absoluteDestination) {
        Remove-Item -LiteralPath $absoluteDestination
    }
    try {
        # Immutable bundled executables/DLLs, same-volume NTFS link: avoid
        # copying tens of MB for each isolated test profile. No source edit.
        New-Item -ItemType HardLink -Path $absoluteDestination -Value $Source -ErrorAction Stop | Out-Null
        return
    } catch { }
    Copy-Item -LiteralPath $Source -Destination $Destination
}
Copy-RuntimeFile (Join-Path $repository $Executable) (Join-Path $stage 'Game.exe')
foreach ($dll in (Get-ChildItem -LiteralPath $repository -Filter '*.dll' -File)) {
    Copy-RuntimeFile $dll.FullName (Join-Path $stage $dll.Name)
}
Copy-RuntimeFile (Join-Path $repository 'Game.ini') (Join-Path $stage 'Game.ini')
$configuration = [ordered]@{
    gameFolder = ([IO.Path]::GetFullPath($GameRoot)).Replace('\','/')
    rgssVersion = 1
    windowTitle = "KIF Multiplayer [$Profile]"
    defScreenW = 512
    defScreenH = 384
    pathCache = $false
    dataPathOrg = 'KIFMultiplayerTest'
    dataPathApp = $Profile
    preloadScript = @((Join-Path $PSScriptRoot 'runtime-preload.rb').Replace('\','/'))
}
if ($CustomScript) {
    $resolvedScript = (Resolve-Path -LiteralPath $CustomScript).Path
    $configuration.customScript = $resolvedScript.Replace('\','/')
}
$configuration | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'mkxp.json') -Encoding utf8
Write-Output $stage
