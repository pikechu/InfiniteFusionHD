$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'Data/resource-download.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Resource downloader has a syntax error' }
$definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ResourceBodyLimit'}, $false)
if (!$definition) { throw 'Resource limit function missing' }
# Load the actual pure policy function without running network/file operations.
. ([ScriptBlock]::Create($definition.Extent.Text))
$cases = @(
    @('https://raw.githubusercontent.com/pikechu/InfiniteFusionHD/main/Data/pokedex/dex_zh.json',33554432),
    @('https://raw.githubusercontent.com/pikechu/InfiniteFusionHD/0123456789012345678901234567890123456789/Data/pokedex/dex.json',33554432),
    @('https://raw.githubusercontent.com/pikechu/InfiniteFusionHD/main/Graphics/Battlers/test.png',8388608),
    @('https://raw.githubusercontent.com/other/repository/main/Data/pokedex/dex_zh.json',8388608),
    @('https://infinitefusion.net/customsprites/spritesheets/spritesheets_base/1.png',8388608),
    @('https://raw.githubusercontent.com/pikechu/InfiniteFusionHD/main/Data/pokedex/dex_zh.json.gz',8388608)
)
foreach ($case in $cases) {
    if ((Get-ResourceBodyLimit ([Uri]$case[0])) -ne $case[1]) { throw ('Wrong resource limit: ' + $case[0]) }
}
'RESOURCE_DOWNLOAD_LIMIT_PASS checks=6 network=false temporary_files=false'
