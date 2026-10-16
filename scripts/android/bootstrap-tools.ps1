[CmdletBinding()]
param(
    [switch]$WithEmulator,
    [switch]$CreateAvd,
    [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'
if ($CreateAvd) { $WithEmulator = $true }
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temporary = Join-Path $repository 'temp'
$downloads = Join-Path $temporary 'downloads'
$tools = Join-Path $temporary 'tools'
$sdk = Join-Path $tools 'android-sdk'
foreach ($directory in @($downloads, $tools, $sdk)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

# These immutable URLs are from the official publisher repositories. See docs/android/toolchain.md.
$packages = @(
    @{ Name='Temurin JDK 17.0.20.1+1'; File='OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip'; Url='https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip'; SHA256='e53a79c3c3d86865bd7e787903884331068e71321714ffd44f145785affc7cb0'; Inside='jdk-17.0.20.1+1'; Destination=(Join-Path $tools 'jdk-17.0.20.1+1') },
    @{ Name='Android command-line tools 22.0'; File='commandlinetools-win-15859902_latest.zip'; Url='https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip'; SHA256='90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'; Inside='cmdline-tools'; Destination=(Join-Path $sdk 'cmdline-tools/15859902') },
    @{ Name='Android platform-tools 37.0.1'; File='platform-tools_r37.0.1-win.zip'; Url='https://dl.google.com/android/repository/platform-tools_r37.0.1-win.zip'; SHA256='45f4d63113e895ebde0c90f194099a4676b6ac653bd28d54314a9e022bbc1a99'; Inside='platform-tools'; Destination=(Join-Path $sdk 'platform-tools') },
    @{ Name='Android build-tools 35.0.0'; File='build-tools_r35_windows.zip'; Url='https://dl.google.com/android/repository/build-tools_r35_windows.zip'; SHA256='5753c679a1b90bcf6fbc9945a2ce39dfb9e74f1df0831a1e1866ae5b594326f0'; Inside='android-15'; Destination=(Join-Path $sdk 'build-tools/35.0.0') },
    @{ Name='Android platform API 35 revision 2'; File='platform-35_r02.zip'; Url='https://dl.google.com/android/repository/platform-35_r02.zip'; SHA256='0988cacad01b38a18a47bac14a0695f246bc76c1b06c0eeb8eb0dc825ab0c8e0'; Inside='android-35'; Destination=(Join-Path $sdk 'platforms/android-35') }
)
if ($WithEmulator) {
    $packages += @(
        @{ Name='Android Emulator 37.2.12'; File='emulator-windows_x64-16428233.zip'; Url='https://dl.google.com/android/repository/emulator-windows_x64-16428233.zip'; SHA256='3b524b6e0f1f5506d3d81af62ec9ce15b2a6f80f467e99574e167514ca181401'; Inside='emulator'; Destination=(Join-Path $sdk 'emulator') },
        @{ Name='Android 11 Google APIs x86_64 revision 16'; File='x86_64-30_r16.zip'; Url='https://dl.google.com/android/repository/sys-img/google_apis/x86_64-30_r16.zip'; SHA256='daae27654be74ae83a484daea4db2c0c77b4f4ad661a645bd5f36d96ce03e4d5'; Inside='x86_64'; Destination=(Join-Path $sdk 'system-images/android-30/google_apis/x86_64') }
    )
}

foreach ($package in $packages) {
    $archive = Join-Path $downloads $package.File
    if (!(Test-Path -LiteralPath $archive)) {
        if ($SkipDownload) { throw "Missing archive: $archive" }
        Write-Host "Downloading $($package.Name)"
        # Preserve the caller's proxy and sandbox configuration.
        & curl.exe --fail --location --retry 2 --connect-timeout 20 --output $archive $package.Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $($package.Name)" }
    }
    $algorithm = if ($package.SHA256) { 'SHA256' } else { 'SHA1' }
    $expected = if ($package.SHA256) { $package.SHA256 } else { $package.SHA1 }
    if ((Get-FileHash -Algorithm $algorithm -LiteralPath $archive).Hash -ne $expected) {
        throw "Checksum mismatch for $archive. Move this incomplete archive aside and retry."
    }
    if (!(Test-Path -LiteralPath $package.Destination)) {
        $stage = Join-Path $tools ('extract-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $stage)
        [IO.Directory]::CreateDirectory((Split-Path $package.Destination -Parent)) | Out-Null
        Move-Item -LiteralPath (Join-Path $stage $package.Inside) -Destination $package.Destination
    }
    Write-Host "Verified: $($package.Name)"
}

$environment = [ordered]@{
    JAVA_HOME = Join-Path $tools 'jdk-17.0.20.1+1'
    ANDROID_HOME = $sdk
    ANDROID_SDK_ROOT = $sdk
    ANDROID_USER_HOME = Join-Path $temporary 'android-user'
    ANDROID_AVD_HOME = Join-Path $temporary 'android-avd'
    GRADLE_USER_HOME = Join-Path $temporary 'gradle-user'
}
foreach ($directory in @($environment.ANDROID_USER_HOME, $environment.ANDROID_AVD_HOME, $environment.GRADLE_USER_HOME)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
$environment | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tools 'android-environment.json') -Encoding utf8
Write-Host "Tool paths: $(Join-Path $tools 'android-environment.json')"
if ($CreateAvd) {
    $avdDirectory = Join-Path $environment.ANDROID_AVD_HOME 'kif-api30.avd'
    $config = Join-Path $avdDirectory 'config.ini'
    if (!(Test-Path -LiteralPath $config)) {
        # Keep AVD creation offline. avdmanager can wait for remote metadata even
        # when the pinned emulator and image have already been extracted.
        [IO.Directory]::CreateDirectory($avdDirectory) | Out-Null
        $settings = [ordered]@{
            'AvdId'='kif_api30'
            'PlayStore.enabled'='false'
            'abi.type'='x86_64'
            'avd.ini.displayname'='KIF API 30'
            'avd.ini.encoding'='UTF-8'
            'hw.cpu.arch'='x86_64'
            'hw.cpu.ncore'='4'
            'hw.device.name'='pixel_2'
            'hw.device.manufacturer'='Google'
            'hw.initialOrientation'='landscape'
            'hw.keyboard'='yes'
            'hw.mainKeys'='no'
            'hw.lcd.width'='720'
            'hw.lcd.height'='1280'
            'hw.lcd.density'='240'
            'hw.ramSize'='3072'
            'hw.sdCard'='no'
            'disk.dataPartition.size'='4G'
            'hw.gpu.enabled'='yes'
            'hw.gpu.mode'='swiftshader_indirect'
            'image.sysdir.1'=(Join-Path $sdk 'system-images/android-30/google_apis/x86_64').Replace('\','/')
            'fastboot.forceColdBoot'='yes'
            'fastboot.forceFastBoot'='no'
            'snapshot.present'='no'
            'runtime.network.latency'='none'
            'runtime.network.speed'='full'
            'showDeviceFrame'='no'
            'tag.display'='Google APIs'
            'tag.id'='google_apis'
            'vm.heapSize'='256'
        }
        ($settings.Keys | ForEach-Object { $_ + '=' + $settings[$_] }) | Set-Content -LiteralPath $config -Encoding ascii
        @('avd.ini.encoding=UTF-8', ('path=' + $avdDirectory), 'target=android-30') |
            Set-Content -LiteralPath (Join-Path $environment.ANDROID_AVD_HOME 'kif_api30.ini') -Encoding ascii
    }
    Write-Host "AVD: kif_api30 ($avdDirectory)"
}
Write-Host 'No persistent environment variables or machine configuration were changed.'
