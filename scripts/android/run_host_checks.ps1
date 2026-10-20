[CmdletBinding()]
param([string]$RubyPath)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$environmentFile = Join-Path $repository 'temp/tools/android-environment.json'
$tools = Get-Content -LiteralPath $environmentFile -Raw | ConvertFrom-Json
$jdk = $tools.JAVA_HOME
$output = Join-Path $repository 'temp/host-checks'
[IO.Directory]::CreateDirectory($output) | Out-Null
if (!$RubyPath) { $RubyPath = Join-Path $repository 'temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe' }
if (!(Test-Path -LiteralPath $RubyPath)) { throw 'Pass -RubyPath with a portable Ruby 3.2+ executable; see docs/android/platform-test-strategy.md' }

Push-Location -LiteralPath $repository
try {
    & $RubyPath --disable-gems android/tests/platform_contract_test.rb
    if ($LASTEXITCODE -ne 0) { throw 'Ruby platform contract checks failed' }
    foreach ($testName in @('bitmap_path_contract_test', 'http_adapter_test', 'download_write_test', 'input_bridge_test', 'keybinding_bootstrap_test', 'intro_notice_test', 'title_input_test')) {
        & $RubyPath --disable-gems "android/tests/$testName.rb"
        if ($LASTEXITCODE -ne 0) { throw "Failed: $testName" }
    }
    & $RubyPath --disable-gems -e 'files = Dir.glob("Data/Scripts/**/*.rb") + Dir.glob("android/ruby/*.rb"); files.each { |f| RubyVM::InstructionSequence.compile_file(f) }; puts "PASS: #{files.length} Ruby files compile (no game execution)"'
    if ($LASTEXITCODE -ne 0) { throw 'Ruby syntax checks failed' }
    $classes = Join-Path $output 'save-transfer-classes'
    [IO.Directory]::CreateDirectory($classes) | Out-Null
    $sources = @(Get-ChildItem -LiteralPath android/tests/java -Recurse -File -Filter '*.java' | ForEach-Object FullName)
    $sources += Join-Path $repository 'android/app/src/main/java/org/kuray/kif/SaveTransfer.java'
    & (Join-Path $jdk 'bin/javac.exe') '-J-Duser.language=en' --release 8 -encoding UTF-8 -d $classes $sources
    if ($LASTEXITCODE -ne 0) { throw 'Save transfer host test compilation failed' }
    & (Join-Path $jdk 'bin/java.exe') -cp $classes SaveTransferHostTest $output
    if ($LASTEXITCODE -ne 0) { throw 'Save transfer filesystem checks failed' }
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'Git whitespace checks failed' }
} finally { Pop-Location }
