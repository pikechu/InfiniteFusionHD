# Android toolchain

Updated 2026-10-16. All downloaded archives, extracted development tools, AVD data,
and build intermediates belong under `temp/`; none are source dependencies to commit.
The bootstrap does not install Android Studio, change `PATH` permanently, change
Windows features, or run the game's updater.

## Pinned portable Windows tools

| Component | Fixed version | Local path under `temp/tools` |
| --- | --- | --- |
| Eclipse Temurin JDK | 17.0.20.1+1, Windows x64 HotSpot | `jdk-17.0.20.1+1` |
| Android command-line tools | 22.0, archive build 15859902 | `android-sdk/cmdline-tools/15859902` |
| Android platform-tools | 37.0.1 | `android-sdk/platform-tools` |
| Android build-tools | 35.0.0 | `android-sdk/build-tools/35.0.0` |
| Android compile platform | API 35, revision 2 | `android-sdk/platforms/android-35` |
| Android Emulator | 37.2.12, stable archive build 16428233 | `android-sdk/emulator` |
| First AVD system image | Android 11/API 30, Google APIs, x86_64, revision 16 | `android-sdk/system-images/android-30/google_apis/x86_64` |

Run from the repository root in PowerShell:

```powershell
& ./scripts/android/bootstrap-tools.ps1
# Include the larger emulator and system image downloads:
& ./scripts/android/bootstrap-tools.ps1 -WithEmulator
# Check and extract archives already downloaded without network access:
& ./scripts/android/bootstrap-tools.ps1 -WithEmulator -SkipDownload
# Create the isolated landscape AVD after downloading its image:
& ./scripts/android/bootstrap-tools.ps1 -CreateAvd -SkipDownload
```

The script checks the pinned archive digest before extraction and writes
`temp/tools/android-environment.json`. SHA-256 values come from the JDK GitHub
release and Google's command-line tools page; build-tools/platform/platform-tools
archives were first checked against Google's repository SHA-1 and then recorded
with SHA-256. The emulator and system-image archives were likewise checked
against Google's published SHA-1, then pinned with SHA-256 in the bootstrap.
The bootstrap preserves the caller's proxy configuration. If the development
sandbox blocks an official download, request scoped approval for that download;
do not change global proxy settings or sandbox protections.

For a process that needs the tools, read the environment file and set only its
process environment. For example:

```powershell
$toolEnv = Get-Content ./temp/tools/android-environment.json -Raw | ConvertFrom-Json
$env:JAVA_HOME = $toolEnv.JAVA_HOME
$env:ANDROID_HOME = $toolEnv.ANDROID_HOME
$env:ANDROID_SDK_ROOT = $toolEnv.ANDROID_SDK_ROOT
$env:ANDROID_USER_HOME = $toolEnv.ANDROID_USER_HOME
$env:ANDROID_AVD_HOME = $toolEnv.ANDROID_AVD_HOME
$env:GRADLE_USER_HOME = $toolEnv.GRADLE_USER_HOME
& "$env:JAVA_HOME/bin/java.exe" -version
& "$env:ANDROID_HOME/platform-tools/adb.exe" version
```

SDK components remain subject to their publisher licenses. To inspect and accept
the licenses needed for development, run the pinned `sdkmanager.bat --licenses`
with `--sdk_root` pointing to `temp/tools/android-sdk`.
The initial development run accepted these SDK licenses into this project-local
SDK. `temp/logs/sdk-licenses.log` records the operation. `sdkmanager
--list_installed` recognized build-tools 35.0.0, platform-tools 37.0.1, and
platform 35 revision 2; `temp/logs/sdk-installed.log` records that output.

Windows `adb` uses the Windows user profile for `.android` authentication files
even when `ANDROID_USER_HOME` is set. The first `adb version` failed in the
workspace sandbox because this directory did not exist. A scoped execution of
`adb version` and `adb devices -l` created the standard config directory and
started the daemon at localhost:5037; subsequent sandboxed `adb version` worked.
This is tool configuration, not a game save or build output. No device was
connected during the initial inventory.

## Host and emulator verification

Initial host inventory: Windows 10 build 19045, Intel Core i7-10700, 32 GiB RAM.
`Win32_ComputerSystem.HypervisorPresent` and `systeminfo` report an active
hypervisor. The CPU's firmware virtualization and SLAT flags report false while
the hypervisor is active; these flags alone do not prove the emulator cannot
accelerate. `Get-WindowsOptionalFeature` requires an administrator token and was
not used to change Windows features. The pinned emulator's `-accel-check`
completed successfully with exit code 0: `WHPX(10.0.19045) is installed and usable.`
The raw result is in `temp/logs/emulator-accel-check.log`; no BIOS or Windows
feature changes were needed.

The first image is deliberately Android 11 Google APIs x86_64: Google's official
Android 11 emulator supports ARM32 and ARM64 app native libraries through native
translation. This permits testing the runtime's existing ARM builds before an
x86_64 native build is available. Translation support and game performance still
require an actual install/run check; it is not equivalent to ARM64 device
validation. No physical Android device is currently available.

Raw host inventory is in `temp/logs/host-virtualization.json`. The AVD completed
its first boot in **328,622 ms** (the emulator's own reported duration):
`sys.boot_completed=1`, CE storage available, user 0 `RUNNING_UNLOCKED`. Its
measured configuration is recorded in `temp/logs/emulator-device.json`:
Android 11/API 30, 720×1280 at 240 dpi, 4096-byte pages, ABIs
`x86_64,x86,arm64-v8a,armeabi-v7a,armeabi`, native bridge
`libndk_translation.so`. Initial dex optimization and user storage unlock took
several minutes. Intermediate package/activity errors before boot completed
must not be attributed to the game. The test package installed and its launcher
resolved once boot completed. Game frame rate, rendering and playability remain
separate runtime tests.

The `-CreateAvd` option writes the offline `kif_api30` configuration under
`temp/android-avd`, with a 720×1280 display rotated to landscape, 3 GiB guest RAM
and a requested 4 GiB data partition (the image's own minimum may enlarge it).
It leaves an existing AVD and its test saves intact. `avdmanager` was avoided
after its local metadata scan stalled; direct emulator boot verified this
offline configuration. To start it in a
hidden background helper process, after applying the process environment above:

```powershell
$emulator = "$env:ANDROID_HOME/emulator/emulator.exe"
& $emulator -accel-check
$process = Start-Process -FilePath $emulator -ArgumentList @(
    '-avd', 'kif_api30', '-port', '5554', '-no-window', '-no-audio',
    '-no-snapshot', '-no-boot-anim', '-no-metrics', '-gpu', 'swiftshader_indirect'
) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput ./temp/logs/emulator.stdout.log `
    -RedirectStandardError ./temp/logs/emulator.stderr.log
& "$env:ANDROID_HOME/platform-tools/adb.exe" -s emulator-5554 wait-for-device
& "$env:ANDROID_HOME/platform-tools/adb.exe" -s emulator-5554 shell getprop sys.boot_completed
& "$env:ANDROID_HOME/platform-tools/adb.exe" -s emulator-5554 shell getprop ro.product.cpu.abilist
```

`wait-for-device` alone does not mean Android has completed booting: wait until
`sys.boot_completed` is `1` before installing or driving a test APK. Preserve
the AVD between upgrade and save-restart tests; create a separate AVD or use
explicitly authorized data cleanup for clean-install tests.

## Publisher references

- [Android command-line tools and published SHA-256](https://developer.android.com/studio#command-line-tools-only)
- [Google SDK package metadata](https://dl.google.com/android/repository/repository2-3.xml)
- [Google APIs system-image metadata](https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml)
- [Temurin fixed JDK release](https://github.com/adoptium/temurin17-binaries/releases/tag/jdk-17.0.20.1%2B1)
- [Emulator acceleration and Windows Hypervisor Platform](https://developer.android.com/studio/run/emulator-acceleration)
- [Official ARM app support in the Android 11 emulator](https://android-developers.googleblog.com/2020/03/run-arm-apps-on-android-emulator.html)
## Required small native helper

Every APK now includes the source-built virtual-input helper; its optional
HTTPS entry point does not enable networking without `--with-network`.
The portable bootstrap above does not currently download the NDK. Unpack the
official [Windows NDK r25c archive](https://dl.google.com/android/repository/android-ndk-r25c-windows.zip)
under `temp/tools/`, producing `temp/tools/android-ndk-r25c`.
The archive SHA-256 measured for this build is
`f70093964f6cbbe19268f9876a20f92d3a593db3ad2037baadd25fd8d71e84e2`;
the builder requires `Pkg.Revision = 25.2.9519653`.

```powershell
./scripts/android/build_bridge.ps1
```

This checks required Ruby exports, compiles ARM64/API 30 using the Windows
NDK Clang, checks the JNI/Ruby initialization exports and 16 KiB LOAD alignment,
and writes `temp/android-bridge-build/arm64-v8a-api30/provenance.json` before
copying only the helper into generated jniLibs. It does not rebuild or change
the publisher's Ruby, SDL, mkxp-z or codec libraries. The helper itself has no
SDL dependency. All temporary inputs and outputs remain under this checkout's
`temp/` directory; no system installation or global environment changes are
needed.
