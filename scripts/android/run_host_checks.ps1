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
    foreach ($testName in @('bitmap_path_contract_test', 'http_adapter_test', 'download_write_test', 'input_bridge_test', 'display_mode_test', 'text_input_bridge_test', 'keybinding_bootstrap_test', 'intro_notice_test', 'title_input_test', 'font_probe_loader_test', 'loaded_slot_test')) {
        & $RubyPath --disable-gems "android/tests/$testName.rb"
        if ($LASTEXITCODE -ne 0) { throw "Failed: $testName" }
    }
    foreach ($test in @('wearable', 'door_events', 'outfit_cache', 'startup_downloads')) {
        & $RubyPath --disable-gems "tests/gameplay/${test}_test.rb"
        if ($LASTEXITCODE -ne 0) { throw "Local gameplay regression failed: $test" }
    }
    & $RubyPath --disable-gems -e 'files = Dir.glob("Data/Scripts/**/*.rb") + Dir.glob("android/ruby/*.rb"); files.each { |f| RubyVM::InstructionSequence.compile_file(f) }; puts "PASS: #{files.length} Ruby files compile (no game execution)"'
    if ($LASTEXITCODE -ne 0) { throw 'Ruby syntax checks failed' }
    $classes = Join-Path $output 'save-transfer-classes'
    [IO.Directory]::CreateDirectory($classes) | Out-Null
    $sources = @(Get-ChildItem -LiteralPath android/tests/java -Recurse -File -Filter '*.java' | ForEach-Object FullName)
    $sources += Join-Path $repository 'android/app/src/main/java/org/kuray/kif/SaveTransfer.java'
    $sources += Join-Path $repository 'android/app/src/main/java/org/kuray/kif/AnalyticsProtocol.java'
    $sources += Join-Path $repository 'android/app/src/main/java/org/kuray/kif/AsyncHttpQueue.java'
    & (Join-Path $jdk 'bin/javac.exe') '-J-Duser.language=en' '-J-Xms16m' '-J-Xmx128m' --release 8 -encoding UTF-8 -d $classes $sources
    if ($LASTEXITCODE -ne 0) { throw 'Save transfer host test compilation failed' }
    & (Join-Path $jdk 'bin/java.exe') -Xms16m -Xmx128m -cp $classes SaveTransferHostTest $output
    if ($LASTEXITCODE -ne 0) { throw 'Save transfer filesystem checks failed' }
    & (Join-Path $jdk 'bin/java.exe') -Xms16m -Xmx128m -cp $classes org.kuray.kif.AnalyticsProtocolHostTest
    if ($LASTEXITCODE -ne 0) { throw 'Analytics protocol host checks failed' }
    & (Join-Path $jdk 'bin/java.exe') -Xms16m -Xmx128m -cp $classes org.kuray.kif.AsyncHttpQueueHostTest
    if ($LASTEXITCODE -ne 0) { throw 'Asynchronous HTTP lifecycle checks failed' }
    $payloadClasses = Join-Path $output 'payload-classes'
    [IO.Directory]::CreateDirectory($payloadClasses) | Out-Null
    & (Join-Path $jdk 'bin/javac.exe') --release 8 -d $payloadClasses android/app/src/main/java/org/kuray/kif/PayloadArchive.java android/tests/payload-java/PayloadArchiveHostTest.java
    if ($LASTEXITCODE -ne 0) { throw 'Payload host test compilation failed' }
    & (Join-Path $jdk 'bin/java.exe') -Xms16m -Xmx128m -cp $payloadClasses org.kuray.kif.PayloadArchiveHostTest $output
    if ($LASTEXITCODE -ne 0) { throw 'Payload checksum/alias/streaming checks failed' }
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'Git whitespace checks failed' }
} finally { Pop-Location }
