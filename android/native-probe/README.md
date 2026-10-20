# Native Ruby Probe

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
