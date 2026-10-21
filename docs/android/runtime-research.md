# Android runtime investigation

Investigation date: 2026-10-16 (Asia/Shanghai). This document records source inspection and downloaded artifact inspection. It does **not** claim a KIF Android play test, a successful native source build, or measured mobile performance.

## Decision for the first runnable experiment

Use the Android target in [warmwinter/mkxp-z](https://codeberg.org/warmwinter/mkxp-z), pinned to release tag `uranium-android@0.4.1`, commit **`68653811c3c396f2d4c12225c52c407746285a3d`**. It uses the current mkxp-z source tree, has ARM64 and x86_64 cross files, an SDL Java wrapper, virtual controls, game archive import with progress, and save import/export through Android's Storage Access Framework. Its app-specific storage model is a better starting point than the older forks' broad shared-storage access.

For the earliest ARM64 experiment only, its official release APK contains reusable native libraries. Repackaging these with a KIF-specific application wrapper is technically possible; it is a separately identified prebuilt-runtime experiment, **not** evidence of a reproduced source build. The x86_64 emulator route requires building native dependencies because that APK contains ARM64 libraries only. An ARM translation capable emulator can be used as an additional compatibility experiment, with its limitations recorded.

Fallback 1: `vrcxz/mkxp-z-android-packager`, pinned to `6fb455d813cf9a293eafbac5b336496742968f05`, provides an explicit standalone APK pipeline that bundles game assets. It uses an older snapshot of the Android port and requires fixes to extraction, timing units, storage boundaries, TLS and x86_64 build support. Its packaging scripts must **not** be run with the KIF repository as their input: the generic recursive staging does not exclude `temp`, repository internals, or saves.

Fallback 2: the simpler `thehatkid`/`BookerRues9` Android port can isolate a regression in the newer runtime, but is less suitable for a new maintained product. JoiPlay is useful for comparative tests, but installing a game into JoiPlay does not satisfy the standalone APK goal.

## Candidates and evidence

| Candidate | Fixed source inspected | Android build and Ruby | Assessment |
| --- | --- | --- | --- |
| [mkxp-z upstream](https://github.com/mkxp-z/mkxp-z) | Upstream repository documentation, not selected as an Android pin | MRI; desktop source supports Linux ARM/x86, Windows, macOS | Source of the extensions KIF uses. Main README does not list an official Android product; an Android fork/wrapper is required. |
| [warmwinter/mkxp-z](https://codeberg.org/warmwinter/mkxp-z) | Master `17a5ec6cb3e8d2de05a82451bc4910f36517d322` (2026-09-19), then release `68653811c3c396f2d4c12225c52c407746285a3d` (2026-10-15 local date) | Meson native cross-build; Gradle wrapper; `arm64-v8a`, `armeabi-v7a`, `x86_64`; release uses upstream MRI **3.4.10 plus a checked-in mkxp-z patch** (older master uses patched 3.1.3) | Preferred. Recent actual Android release exists. Native source pipeline is POSIX-oriented and still requires execution and dependency locking. |
| [thehatkid/mkxp-z-android](https://github.com/thehatkid/mkxp-z-android) | `468fe8128a40cc7d2cba4ac7fbe21a82787de255` | Android NDK/Gradle; MRI fork; standalone native app | README explicitly calls it experimental; default game folder is shared `/storage/emulated/0/mkxp-z`; old external-storage limitations. |
| [BookerRues9/mkxp-z-android-reworked](https://github.com/BookerRues9/mkxp-z-android-reworked) | `b668e08cb58edf661d56fd4d396036ac31cd8332` (2026-05-25) | NDK `23.2.8568313`; API 23 minimum, target/compile 33; AGP 7.3.1, Gradle 8.1; patched Ruby branch `mkxp-z-3.1` | ARM64/v7 configured; Makefile describes x86/x86_64, but checked-out repository has no prebuilt `.so`. 16 KB support is only an experimental README claim. |
| [vrcxz/mkxp-z-android-packager](https://github.com/vrcxz/mkxp-z-android-packager) | `6fb455d813cf9a293eafbac5b336496742968f05` | Ubuntu/apt setup; NDK `23.2.8568313`; assets extracted to private files; defaults to ARM64 | Explicit standalone game packaging. Gradle rejects ABIs other than ARM64/v7. Extraction deletes the entire old game tree and starts native execution even on extraction failure, so it needs product hardening. |
| [JoiPlay mkxp](https://github.com/joiplay/mkxp) | Public source and README, no binary selected | Different fork, Android.mk, MRI/mruby bindings | A player/plugin ecosystem and comparison baseline. Its extensions are not interchangeable with mkxp-z by assumption. No inspected reproducible KIF standalone wrapper was established. |

The candidate SHAs above were resolved from the repositories, not inferred from version names. Source was downloaded only beneath `temp/runtime-research`. No original KIF installer/updater was run.

## Actual API compatibility findings

KIF scripts live in `Data/Scripts`. `Game.ini` points to `Data\\Scripts.rxdata`. A recursive source search found these genuine runtime calls (excluding similarly named `$PokemonSystem` fields): `System.data_directory`, `delta`, `game_title`, `platform`, `power_state`, `reload_cache`, `set_window_title`, `user_language`, `user_name`, plus `System.open` in a save-backup folder action. `System.mount` appears in filesystem comments. Later loaded script overrides remain important when changing any behavior.

| Interface | Evidence and consequence |
| --- | --- |
| MRI and Marshal | Both selected Android families use CRuby/MRI rather than mruby. warmwinter statically links native Ruby extensions, but does not bundle pure Ruby standard-library files automatically. Its `android/README.md` explicitly requires games to bundle any needed pure Ruby stdlib and configure `rubyLoadpath`. Ruby's Marshal version is independent of the Ruby language version; same major and compatible minor can be read, but game classes and custom `_load` methods must also exist. This makes Windows save compatibility plausible, not proven. |
| `System` | Reworked's `binding/binding-mri.cpp` exposes all core KIF calls above, plus `is_android?`. New warmwinter provides the same family. Folder opening needs an Android product interface; do not shell out to Explorer or Linux `xdg-open`. Save routing must use the actual Android data directory and preserve backups. |
| `HTTPLite` | Both source trees define `get`, `post`, `post_body`, `JSON.parse` and `JSON.stringify`. KIF calls `get` and `post_body`. JoiPlay's `download` callback API is a distinct extension and is not present merely because `HTTPLite` exists. |
| TLS | **Both inspected mkxp-z Android source trees disable server certificate verification** in all three request methods (`src/net/net.cpp`, `enable_server_certificate_verification(false)`). This is unacceptable for the final download path. Use verified TLS via Android's networking stack or a correctly provisioned OpenSSL trust store, with explicit timeout/error/retry behavior. |
| `Graphics.delta_s` | KIF already adds this Ruby method in `001_Technical/001_MKXP_Compatibility.rb:527`. It divides `Graphics.delta` by 1,000,000 only if `System::VERSION == "MKXPZ_VERSION"`. Reworked sets version `2.4` and returns integer microseconds, so KIF's else path produces incorrect timing. warmwinter returns a native Float delta in seconds; KIF's existing else path matches. This is a concrete reason to prefer the newer runtime. |
| `System.delta` units | warmwinter also returns seconds for `System.delta`. Two KIF error/debug wait loops expect 500,000 microseconds and must use a monotonic seconds clock instead. Do not globally multiply runtime delta values, because that would break the correct `Graphics.delta_s` path. |
| `Bitmap.max_size` | Defined in both source families. KIF's tileset wrapper/autotile expander derives texture limits from it, so the runtime/GLES2 capability matters. Native `get_pixel`, `set_pixel`, `raw_data`, `raw_data=`, `blt`, `stretch_blt` exist. Presence does not establish mobile speed of Ruby per-pixel shiny transformations. |
| `Input` | Native bindings include RGSS directions/buttons, extended key states, text-input mode and `gets`, clipboard and controller support. Java virtual buttons feed SDL key events. Need a KIF mapping, soft keyboard test and back-key policy, including simultaneous direction/action presses. |
| Rendering/fonts/audio | SDL/OpenGL ES 2 plus mkxp-z bitmaps, tilemaps, sprite/animation and font implementations are present. warmwinter includes direct FreeType/libpng integration and SDL audio/OpenAL dependencies. Actual KIF map, font, transition, sound and shiny rendering tests are still required. MIDI/FluidSynth is a separately documented caveat; inspect actual KIF asset formats before deciding whether it matters. |
| Lifecycle | SDL wrapper pauses/resumes native work. Both families retain a `System.exit(0)` process-exit workaround when the Java activity is destroyed because reinitializing the MRI VM in one process can segfault. This needs process-kill/restart, screen lock and background audio testing; do not assume Android activity recreation equals a supported save checkpoint. |

The [Ruby 3.1 Marshal documentation](https://docs.ruby-lang.org/en/3.1/Marshal.html) supports only the format compatibility statement above; it does not establish that a specific KIF save has been tested. [SDL's Android source documentation](https://github.com/libsdl-org/SDL/blob/SDL2/docs/README-android.md) is the reference for the Java/native bootstrap and input/lifecycle mechanisms.

## Prebuilt artifact that was actually inspected

- Official release: [warmwinter uranium-android@0.4.1](https://codeberg.org/warmwinter/mkxp-z/releases/tag/uranium-android%400.4.1).
- Download: [uranium.apk](https://codeberg.org/warmwinter/mkxp-z/releases/download/uranium-android@0.4.1/uranium.apk).
- Local experiment file: `temp/runtime-research/uranium-0.4.1.apk`.
- Published: 2026-10-15 10:29:40 +08:00 (official release API).
- Size: 26,294,753 bytes.
- SHA-256: `35b8cd4e8b6b18fe6364c6af72ccd1801399c62590a093c6d0ffa98b5754b591`.
- Native ABI actually present: **arm64-v8a only**. x86_64 is not present.
- Actual `libruby.so` embedded version string: `ruby 3.4.10 (2026-06-30 revision 2b0b7728dc) [aarch64-linux-android-android]`. This is binary inspection, not yet execution of `RUBY_VERSION`.
- Native libraries actually present: SDL2, SDL2_image, SDL2_sound, SDL2_ttf, libc++_shared, crypto, freetype, iconv, mkxp-z, ogg, openal, physfs, pixman-1, png, ruby, ssl, theora, theoradec, uchardet, vorbis, vorbisfile.

This official release's name and application code are Uranium-specific. No claim is made that it is already a KIF APK. Any borrowed native libraries require corresponding source/license distribution and a recorded provenance manifest.

Actual ELF64 program-header inspection found machine 183 (AArch64) in all 21 libraries. Nineteen have minimum `PT_LOAD.p_align=4096`; only `libc++_shared.so` and `libopenal.so` have 16384. Therefore this prebuilt experiment is restricted to 4 KB-page environments and **does not establish 16 KB compatibility**.

`scripts/android/prepare-runtime.ps1` has been executed successfully in offline mode. It verifies the APK SHA-256, verifies the exact Git source commit and objects, exports that source under `temp/android-runtime`, and generates matching SDL Java, ARM64 native libraries, license copies and a per-file SHA/ELF provenance manifest under `temp/android-generated`. It supports online retrieval when the cache is missing. No native libraries are committed. A forge-generated source ZIP download failed with an unexpected EOF; it was not used or trusted. The script exports from the content-addressed Git commit instead. The exported source archive SHA-256 for the tested Git installation is `e62628e10bdd30397a1fd3fb29fb35590d759d36b8ae4c9a31c3fe7681cbe113`.

The native JNI wrapper must expose static `String GAME_PATH`, static `boolean fpsOverlayEnabled`, `void updateFPSText(int)`, `String getSystemLanguage()`, `boolean hasVibrator()`, `void vibrate(int)`, `void vibrateStop()`, and `boolean inMultiWindow(android.app.Activity)`. Native code looks these up on the actual SDL activity class; its package need not remain `com.mkxpz`. SDL's matching default load order is `SDL2`, `SDL2_image`, `SDL2_ttf`, `SDL2_sound`, `openal`, `ruby`, `mkxp-z`. The remaining libraries are dynamic linker dependencies and must all be packaged.

## Reproducible source build requirements

Preferred source pipeline, after pinning every dependency and validating a POSIX build host:

```sh
# From a checkout fixed to 68653811c3c396f2d4c12225c52c407746285a3d
cd android
ABIS=x86_64 ANDROID_NDK_HOME=/absolute/path/to/ndk ./build.sh
./gradlew assembleDebug
# Repeat native build for arm64-v8a; package both when needed.
```

This command is a source-supported recipe, **not a successful build record**. The pipeline needs Meson, Ninja, CMake, autoconf, automake, libtool, pkg-config, make, host Ruby, Java and Android SDK/NDK. It uses autotools configuration and shell scripts, so native Windows PowerShell alone is insufficient. WSL, a Linux VM/container, or a carefully prepared portable MSYS2 environment must be verified. The older port explicitly documents trouble building Ruby extensions on Windows MSYS2.

warmwinter's **pinned release** dependency script selects upstream Ruby tag `v3_4_10` plus `patches/ruby-3.4.10-mkxp-z.patch` (SHA-256 `f0d01a48c3135e8840aac242b766f485dde179d3db52340ef5efec4ee890639d`), OpenSSL `openssl-3.0.12`, SDL `mkxp-z-2.28.1`, OpenAL `1.24.3`, libogg `v1.3.6`, vorbis `v1.3.7`, physfs `release-3.2.0`, pixman `pixman-0.42.2`, uchardet `v0.0.8`, SDL_ttf `release-2.20.2`, libpng `v1.6.50`, and iconv 1.18. The older master source uses a different Ruby dependency; do not mix its build inputs into the selected release. Several other sources are branch/default-head clones (`theora`, SDL_image, SDL_sound, freetype), and SDL_image runs its own codec download script. The original script is **not fully reproducible**. Record immutable commit IDs for all Git dependencies and SHA-256 for every downloaded archive, including nested downloads, before accepting the source build as reproducible.

The companion `native-dependency-lock-candidates.json` records 15 successfully resolved official Git commits and the downloaded iconv archive SHA-256 verified against [GNU's release announcement](https://lists.gnu.org/archive/html/info-gnu/2024-12/msg00004.html). These are proposed inputs for the next source build, not proven inputs to the prebuilt APK. Ruby resolves to `2b0b7728dc7f0561c35c3d8c4489945c94b783ad`, matching the binary's embedded revision. Remaining lock work: SDL_image's `external/download.sh` clones the **current branch heads**, ignoring immutable gitlink commits, for JPEG, libpng, WebP, TIFF, zlib, JXL, AVIF and dav1d, each recursively; FreeType also has the `dlg` submodule. Pin the required nested sources and disable unused codecs, rather than accepting an apparently pinned top-level build. JXL is already disabled in the selected Makefile, but its generic download script still fetches it. A Linux/POSIX build environment remains required by the current scripts; the inspected Windows host has no WSL build environment. No native source build is claimed.

For modern Android, evaluate NDK r28+ and AGP 8.5.1+ or explicitly align every native library. The [Android 16 KB page-size guide](https://developer.android.com/guide/practices/page-sizes) says r28+ emits 16 KB alignment by default; older toolchains require link flags and all prebuilt shared libraries must also be compatible. The reworked workflow's one `LDFLAGS` environment variable does not prove every `.so` or bundled `libc++_shared.so` is aligned. Run ELF and APK alignment checks and a 16 KB emulator test.

## Product changes required around the runtime

1. Use KIF-specific app identity `org.kuray.kif` (confirmed by the user to the main task), landscape and 512×384 fixed-aspect content; reserve safe button areas and handle display cutouts.
2. Stage only approved game roots (Audio/Data/Graphics/Fonts, Game.ini, Android config and bootstrap scripts). Never stage the whole working tree or Windows saves. Put all build/download work under `temp`.
3. Split versioned bundled assets from persistent downloads, saves, backup and shiny cache. Extract into a new staging directory, verify a content manifest, then activate atomically. Preserve the previous valid assets and all persistent data on failure/upgrade.
4. Use app-specific storage without broad storage permissions, and SAF for user save import/export. [Android's storage documentation](https://developer.android.com/training/data-storage/app-specific) confirms no storage permission is needed for these directories, and that uninstall removes them; explain backup/export to users.
5. Put platform behavior in one Ruby/Java interface. Disable BAT updater, Windows EXE launching, Explorer calls and desktop-only Shiny Finder entry points on Android. Keep Windows behavior working.
6. Add actual runtime/API diagnostics and measured frame-time, startup/load time, RSS/PSS memory evidence. First measure the shiny cache cold/warm paths; optimize only observed bottlenecks.
7. Test save/import/backup before any destructive app upgrade. Keep the Windows save source intact and import copies.

## Validation gate and estimate policy

No trustworthy labor estimate is available before the native build and first KIF boot. Update the estimate after these gates: (1) reproduce or identify a pinned runtime binary, (2) install and render KIF title/map, (3) input/new game/save/restart, (4) battle/capture/fusion/storage/shiny flow, (5) release-quality storage/network/lifecycle/performance and device coverage. Failure at a gate should switch to the alternate runtime or a narrower compatibility probe, not stop at a static failure report.

## License and release constraints

mkxp-z is GPL-2.0-or-later. Upstream explicitly states that enabling modern OpenSSL (Apache-2.0) makes the combined binary a GPLv3 distribution in practice. Deliver the complete corresponding runtime source, modifications, build scripts, notices and dependency licenses alongside any distributed APK. Retain licenses for SDL, Ruby, OpenAL, FreeType, codecs and bundled fonts as applicable. The runtime license does not grant redistribution rights for KIF/Pokémon game assets; public release channel and authority remain separate product/release decisions. The user has authorized engineering and test APK delivery, not an unrequested public upload.
