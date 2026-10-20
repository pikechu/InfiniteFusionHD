# Full source runtime probe

Actual emulator execution passed on 2026-10-20 for APK SHA-256
`4185c549967455c5fdd1a531ecbbdfc7b71bcaed73dd80224d06b7329acf4952`
(26,642,468 bytes). The source core/dependencies loaded, all module and strict
dual Marshal checks passed, JNI worked, and the visible font probe completed
120 frames in 3.09922 seconds. This was Android 11/API30 x86_64 with ARM
translation, not a physical ARM device or KIF gameplay result. The old engine
binary translation patch was not used. Exact evidence and earlier failures are
in [native-device-report.md](../../docs/android/native-device-report.md).

After these device runs the output guards were hardened against Windows
junction/reparse-point redirection, including roots/ancestors and reset
subtrees, with eleven real-junction host regression cases. The tested APK and
its build record remain byte-identical. Their exact pre-hardening builder
sources are retained by SHA in `temp/native-full-probe/history/tested-builders`;
the later change only controls host output paths and does not change packaged
runtime or fixture behavior.

`scripts/android/build_native_full_probe.py` packages the same small diagnostic
application using the locally built mkxp-z core and source-built dependencies.
It never compiles native code, installs an APK, invokes adb, or controls an AVD.
Output is separate from the earlier mixed-component APK:
`temp/native-full-probe/Native-Full-Runtime-Probe-arm64-test.apk`.

The application ID remains `org.kuray.kif.nativeprobe`, with label Native Ruby
Probe and fully qualified JNI-compatible Java classes. It can replace the
mixed diagnostic application when deliberately installed by the device owner;
it cannot update `org.kuray.kif`. No game scripts, maps, sprites, music or
player saves are included. The shared fixture's canonical private storage
guard is retained, including the `/data/data` versus `/data/user/0` fix.
It also shares the explicit native-binary and public-RGSS-UTF8 Marshal contracts
and detailed per-field encoding/byte diagnostics described in the probe README.

## Reproduce

All inputs must already exist: completed fixed component builds, the completed
core build result, portable JDK17/SDK35/build-tools35, and the existing local
test key. The builder does not download tools or create signing keys.

```powershell
& $python ./scripts/android/build_native_full_probe.py --prepare-only --full-runtime-metadata

& $python ./scripts/android/build_native_full_probe.py --full-runtime-metadata `
  --core-sha256 fab5f32f2642d7ac58d552a3e3dd1f75fabc16e22f274e7ff70364d2a3d3a96c
```

The explicit hash identifies the separate
`temp/windows-native-core/packaged/libmkxp-z.so`. The raw Meson build artifact
has a host RUNPATH and is rejected. The packaged artifact uses fixed official
Meson 1.9.1 depfixer cleanup. The builder independently checks raw and packaged
hashes, confirms all bytes outside the actual ELF `.dynamic` section are
identical, verifies the depfixer hash, and compares SONAME/DT_NEEDED/LOAD
alignment. It does not apply the earlier 16-byte ARM translator workaround.

## Provenance and gates

Every `.so` in the common source prefix must match an explicitly allowlisted
component result and fixed source commit/archive/patch identity. The identical
PNG compatibility alias is recorded explicitly. All 19 native input hashes and
pkg-config/helper hashes recorded by the completed core build are rechecked,
including libraries discarded by the linker's `--as-needed` behavior.

Only the recursive DT_NEEDED closure of SDL2, the source core and the existing
source-built JNI helper is packaged. Unused encoders, legacy Theora, charset
and the PNG alias are omitted. Every strong import must resolve within that
library's reachable dependencies. GNU symbol versions and requested provider
names are checked through ELF versym/verneed/verdef tables; unresolved weak
imports are recorded separately. Android system providers are accepted only
when named in DT_NEEDED, explicitly whitelisted, and present in the fixed NDK's
API30 AArch64 stubs. The entire sysroot is never used as an export fallback.

The nine SDL Java files come directly from the same fixed SDL2 checkout used
to build the native library. Each file is checked against its Git blob,
allowing only Git's CRLF checkout conversion and recording raw/blob/normalized
hashes. C and Java versions must both be 2.28.1. The existing GameActivity is
copied only into this build's temp directory, where an explicit SDL2/core
library list is added. Committed game and probe Activities are unchanged.

The full-source status fields are changed only in the temporary copied Ruby
payload: `fullRuntimeSourceBuild=true`,
`allNonToolchainLibrariesSourceBuilt=true`, the NDK C++ runtime exception,
`wholeApk16KiBCompatible=false`, and no emulator binary patch. The committed
mixed fixture retains its own provenance. Source license files for selected
components are appended to this variant's payload and recorded by hash.

`libc++_shared.so` is the sole toolchain runtime exception: the exact NDK r25c
file, SHA-256 `33f661fc80c90913fe365a2bb6ee0bb7ed4c01b9c797fcecf1e60070e00019d6`.
It has 4 KiB LOAD alignment. The source-built core/dependencies and JNI helper
have 16 KiB LOADs, but **the whole APK is not 16 KiB compatible**.

The final build record includes exact source/library hashes, source/result
records, system stub providers, per-library symbol resolution, payload
transformations, licenses, signing verification, aapt2 package inspection and
ZIP inventory/hash audits. A successful build leaves `installed=false`,
`deviceExecuted=false` and `gameplayValidated=false`. Android loading, rendering,
module tests and the 120-frame probe have subsequently passed in the separate
device evidence above. Build-time flags and device observations stay in their
own records; neither implies complete KIF game acceptance or 16 KiB support.
