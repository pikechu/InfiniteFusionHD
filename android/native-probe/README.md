# Native Ruby Probe

Actual emulator execution passed on 2026-10-20 for APK SHA-256
`436e448104b30f3d44a7cab5bdc65572ab30764e916560d23f1799fddce11c3f`
(25,426,026 bytes): modules, strict native-binary and public-RGSS-UTF8 Marshal
contracts, JNI, fonts and 120 frames. This is Android 11/API30 x86_64 with ARM
translation, not a physical-device or game acceptance result. See the separate
[device report](../../docs/android/native-device-report.md), which retains
historical diagnostic failures and exact evidence. The builder's original
static result is not retrospectively changed to claim execution.

This fixture builds a separate, deliberately small Android application. Its
application ID is **`org.kuray.kif.nativeprobe`**, label **Native Ruby Probe**.
The Java package `org.kuray.kif` and fixed SDL Java are retained for JNI
compatibility. Fully qualified manifest Activity names keep application identity
independent from Java package names. It cannot update the installed
`org.kuray.kif` package.

This is a component integration probe: only `libruby.so`, `libssl.so` and
`libcrypto.so` are selected from the local source build. The engine, SDL and
remaining dependencies are the existing SHA-pinned prebuilt runtime; the input
JNI helper is the existing separately source-built helper. **It is not a full
runtime rebuild or a playable game APK.** The old prebuilt dependencies retain
their 4 KiB limitations even though the three overrides have 16 KiB LOADs.

The builder never installs, starts, stops or queries a device/emulator and never
invokes a native compiler. All generated files go under `temp/native-probe`.
It reads no Windows game save. The only existing game asset used is the fixed
18,648-byte Power Green font (SHA-256
`ee009e30695cc6d365c1fb835a8a4a30c9f69c1e84eef30ab496540b77b1f799`).
Ruby standard library wrappers come only from this build's Ruby 3.4.10 prefix,
with every source path/hash in the build record. No `Data`, `Graphics`, `Audio`
or `PBS` content is packaged.

## Build

Use the existing portable JDK 17, SDK platform 35/build-tools 35.0.0, matching
SDL Java/native preparation, and local development signing key. No signing key
or signing password is written into a build record. The source component build
must already have passed `windows-native-verify-ruby.ps1`; its validation record
must match the explicitly selected Ruby hash. An override with a host RUNPATH,
incorrect SONAME, insufficient LOAD alignment, missing original ABI exports, or
a missing non-system dynamic dependency fails the build.

```powershell
# Stage the 29-file fixture and compile Java/Dex; no APK or native override selection.
& $python ./scripts/android/build_native_probe.py --prepare-only --emulator-compatible

# Host-only safety regression; deliberately rejects 11 unsafe application manifests.
& $python ./android/native-probe/test_isolation.py
& ./temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe `
  --disable-gems ./android/native-probe/test_storage_guard.rb
& ./temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe `
  --disable-gems ./android/native-probe/test_marshal_diagnostics.rb

# Final packaging requires deliberately supplied hashes for all three overrides.
# These are the final verified no-RUNPATH source component hashes for this probe.
& $python ./scripts/android/build_native_probe.py --emulator-compatible `
  --override-sha256 libruby.so=aa4a6a26739d453a3b29b49b579cfa7a708eef9ed04f133467072cf93ba9610a `
  --override-sha256 libssl.so=343cf6b7ef6c95ec19a41950028198f339bc6655cea9e83e6d897d865b5d05b4 `
  --override-sha256 libcrypto.so=de05aea08a9fc2ede789b95a1cdd668b17c94dad198cde3ea12d05d126aadd7c
```

`$python` is an existing Python 3.11+ interpreter. On this host the bundled
interpreter is at
`D:/Users/meikun.zhang/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe`.
Optional `--jdk`, `--sdk`, `--prefix`, and `--font` select their existing local
paths. There is no automatic network dependency resolution or key generation.

`--emulator-compatible` explicitly selects the existing 16-byte mkxp workaround
for the old Android 11 ARM translator. It is never silently applied and is not
phone validation. Both original/patched hashes, source patch/provenance hashes
and `nativeRuntimeRebuiltFromSource=false` are recorded. Omitting the switch
uses the unchanged original mkxp binary and a separate build/output name.

The signed output is
`temp/native-probe/Native-Ruby-Probe-arm64-emulator-test.apk`, with an adjacent
SHA-256 file and full build record. The build performs actual apksigner
verification and aapt2 badging/manifest inspection. It verifies application ID,
label, launch Activity, absence of INTERNET/storage permissions, exact library
inventory/hashes, and nested payload hashes. These are build/static results,
not Android execution results.

## Runtime scope and evidence

The private launcher verifies the fixed payload, installs it only below its own
`getFilesDir()/native-probe/content/<id>`, and starts its non-exported Activity
in `:probe`. There are no external file intents, import/export UI, save migration
paths, shared UID, providers, or game launcher classes. Probe outputs use only
`getFilesDir()/native-probe/output`. MRI process cleanup ends this probe's
separate process.

The probe requires OpenSSL, socket, zlib, Digest and SHA256; verifies SHA256
known-answer vectors through Digest and OpenSSL; parses a numeric loopback
address without network I/O; round-trips binary/unicode bytes through Zlib;
writes fresh `probe.dat` before reading that same file with Marshal; and calls
the existing JNI helper's `input_poll` through the new Ruby ABI. The graphics
fixture checks the bundled font exists and produces nontransparent text pixels,
creates a bitmap/sprite, then renders 120 frames at a requested 40 FPS.

Runtime evidence is `KIF_NATIVE_PROBE_*` log messages and the probe-private
`native-probe/output/probe-result.json`. Success remains visible until the
separately controlled process is ended. Failures include the last stage and
backtrace. Each native Activity startup first replaces any old result with
`native_start_pending` before loading libraries, so a loader failure cannot reuse
a previous successful result. A successful build does not set `deviceExecuted`, `installed`,
`gameplayValidated` or `fullRuntimeSourceBuild` to true. Device execution and
inspection must be performed separately against this exact application ID by
the agent/user responsible for the device.

The final device-tested builder sources are retained by SHA under
`temp/native-full-probe/history/tested-builders`. A subsequent build-IO hardening
change rejects junctions/reparse points at the dedicated output root, ancestors,
work directories and reset subtrees before any write or removal. Eleven host
regressions with eleven actual Windows junctions passed; neither tested APK nor
its build record was regenerated or changed. This is a host build-safety fix,
with no game/runtime/payload change. Run `python -B android/native-probe/test_output_guard.py`
for the host check; a managed host may need scoped process execution for junction
fixture creation/cleanup.

The first mixed probe (`da1ff4909f7fe7fb571809e8777fe0220d64fb645cf342f298a4bea729178775`)
actually reached Ruby on the root agent's device run (PID 18300), then failed
the private path guard before module tests. Android used `/data/data` and
`/data/user/0` aliases; `File.expand_path` did not resolve the alias. The guard
now compares `File.realpath` for both paths and still requires output strictly
below this application's `files/native-probe/` boundary. It logs canonical and
expanded paths for the rerun. The original APK/build record and reported failure
are retained under `temp/native-probe/history/<original-sha>/`. Host guard
regressions model Android alias resolution and reject cross-app escapes;
Android validation of this fix subsequently passed in the final device runs;
their logs retain both expanded and canonical paths.

The next mixed (`686a8a3ab1d1ccfcfb7eb83a705845b8f3e86047a2dbdf2f738c72e2acf44239`)
and full-source (`de264e77e95c079abcfd77206c03e9d44bcebaf9d70f33ddd3238d0bc080e62a`)
device runs passed module/function checks but failed strict public Marshal
comparison of the binary string. The root agent independently decoded its own
829-byte probe file with host Ruby, obtaining strict equality. The fixed
engine's `binding/filesystem-binding.cpp` replaces public `Marshal.load` with a
callback that changes ASCII-8BIT strings to UTF-8 without changing their bytes.
Both observed failing APKs and records are preserved under their SHA history
directories; the runtime is unchanged.

The diagnostic now retains the original public-load mismatch as explicit
evidence, including every hash key/value type, array item, equality result,
string encoding/validity/byte count/SHA/hex prefix, and dump header/SHA. It then
requires two separate strict contracts: `_mkxp_load_alias` must reproduce the
original binary object exactly; public `load` must equal a separately constructed
expected UTF-8 object and preserve all value types and string bytes. The alias
must exist; no test is skipped and byte-only equality never replaces either
strict assertion. Host tests reproduce the exact source callback and reject
wrong native results, wrong public encoding and byte corruption. There are 561
passed host-only assertions; both final APKs then actually passed the two
contracts on Android. This does not change the runtime's Marshal implementation
or establish arbitrary game-save compatibility.
