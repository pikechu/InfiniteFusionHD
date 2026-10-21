# Portable Windows native source build

Status: **in progress**, 2026-10-20. This extends the actual libiconv result in
[native-windows-build-feasibility.md](native-windows-build-feasibility.md).
Current acceptance is:

- **Compiled and inspected:** twenty-one common-prefix dependency libraries plus Ruby
  with actual embedded OpenSSL/socket/zlib archives and initializer registration.
  The earlier libiconv proof is separate from this common prefix.
- **Ruby cleanup passed:** formal `--disable-rpath` reconfiguration, single-job
  build/install, mandatory-extension and ELF gates passed at 12:43:02 China time.
  Final Ruby SHA-256 is `aa4a6a26739d453a3b29b49b579cfa7a708eef9ed04f133467072cf93ba9610a`.
  The earlier output with host RUNPATH is retained as superseded history.
- **Independent probes actually passed on emulator:** mixed APK is 25,426,026
  bytes, SHA-256 `436e448104b30f3d44a7cab5bdc65572ab30764e916560d23f1799fddce11c3f`;
  full-source APK is 26,642,468 bytes, SHA-256
  `4185c549967455c5fdd1a531ecbbdfc7b71bcaed73dd80224d06b7329acf4952`.
  Both passed modules, strict dual Marshal contracts, JNI, fonts and 120 frames
  on Android 11/API30 x86_64 with ARM translation. No physical-device or full-game
  acceptance is claimed; historical diagnostic failures are retained.
- **Full mkxp core source rebuild:** compilation and packaging gates have passed;
  final core SHA-256 is `fab5f32f2642d7ac58d552a3e3dd1f75fabc16e22f274e7ff70364d2a3d3a96c`.
  Full-probe dependency closure and basic emulator execution have also passed;
  full KIF game acceptance on this runtime remains separate.

The build scripts do not change the working game APK's libraries or invoke an
emulator. Root's separate device runs are recorded in [native-device-report.md](native-device-report.md).
No WSL, system installation, global PATH change, proxy override or TLS bypass
is used.

## Fixed inputs and commands

The machine-readable inputs are in
`scripts/android/windows-native-lock.json`. These are new source-build inputs,
not a claim that the historical prebuilt APK used this complete dependency set.

| Input | Version / commit | Role |
| --- | --- | --- |
| Runtime | `68653811c3c396f2d4c12225c52c407746285a3d` | Selected Android runtime source |
| NDK | r25c, `25.2.9519653` | Existing portable Windows cross compiler |
| MSYS2 | Existing portable `temp/tools/msys64` | POSIX shell, Make, Perl |
| Perl | Official MSYS2 `5.42.3-2` | OpenSSL Configure and generators |
| OpenSSL | `c3cc0f1386b0544383a61244a4beeb762b67498f` | Runtime's 3.0.12 compatibility baseline |
| SDL2 | `d3ac4c3742a405e719071fc4f5a7ba8a125c76a1` | Runtime's mkxp-z SDL fork |
| Ruby | Official 3.4.10 release + fixed runtime patch | Generated Configure avoids Autoconf host bootstrap |
| Ogg | `be05b13e98b048f0b5a0f5fa8ce514d56db5f822` | Audio container |
| Vorbis | `0657aee69dec8508a0011f47f3b69d7538e9d262` | Three audio libraries |
| PNG | `2b978915d82377df13fcbb1fb56660195ded868a` | PNG loading/saving |
| PhysicsFS | `eb3383b532c5f74bfeb42ec306ba2cf80eed988c` | Asset filesystem |
| FreeType | `4d8db130ea4342317581bab65fc96365ce806b77` + dlg `d142e646e263c89f93663e027c2f0d03739ab42d` | Font rasterizer and fixed gitlink |
| CMake | Portable Windows 3.31.6 | Android CMake dependency configuration |
| Ninja | Portable Windows 1.12.1 | Native Windows build executor |

Run in the isolated verification checkout using PowerShell:

```powershell
& ./scripts/android/windows-native-build.ps1 -Dependency OpenSSL -Fetch -Jobs 4
& ./scripts/android/windows-native-cmake.ps1 -Dependency SDL2 -Fetch -Jobs 4
& ./scripts/android/windows-native-cmake.ps1 -Dependency libogg -Fetch -Jobs 4
& ./scripts/android/windows-native-cmake.ps1 -Dependency libvorbis -Fetch -Jobs 4
& ./scripts/android/windows-native-cmake.ps1 -Dependency libpng -Fetch -Jobs 4
& ./scripts/android/windows-native-cmake.ps1 -Dependency physfs -Fetch -Jobs 4
& ./scripts/android/windows-native-cmake.ps1 -Dependency freetype -Fetch -Jobs 4
& ./scripts/android/windows-native-ruby.ps1 -Stage Configure -Fetch
# Prepare/verify both patches without starting MSYS, NDK, Configure or make:
& ./scripts/android/windows-native-ruby.ps1 -Stage PrepareOnly
# Once OpenSSL's prefix exists, configure, compile and install Ruby:
& ./scripts/android/windows-native-ruby.ps1 -Stage Build -Jobs 1
& ./scripts/android/windows-native-verify.ps1
```

`-Fetch` only permits downloading missing locked inputs. Existing source checkouts
must match the locked commit and have no tracked/untracked modifications. Archive
hash mismatches stop the scripts before extraction. Downloads/builds/logs/install
prefixes stay under this checkout's `temp/windows-native`; portable host tools
stay under `temp/tools`. This checkout's tools junction to the primary checkout's
`temp/tools` is supported. The scripts respect the caller's proxy configuration.
On this sandboxed host, starting MSYS2 requires a scoped tool approval; the normal
developer command does not change any Windows security setting.
Native Ninja compiler probes also require scoped tool execution on this managed
host: the independent PhysicsFS control stalled over ten minutes after producing
its ABI object in the default sandbox, then completed the same configuration,
build and install in 6.871 seconds with scoped execution. No change to Ninja,
compiler flags, system configuration or emulator was needed.

The initial existing MSYS2 base and GNU Make are prerequisites; their original
download hashes and bootstrap are recorded in the earlier feasibility document.
The added Perl package is extracted into that portable tree, without pacman or
system installation. Only the Perl interpreter/core modules used by OpenSSL are
required by this step. Optional DB_File/GDBM modules have not been provisioned or
validated. CMake's published SHA-256 is verified; Ninja's SHA-256 is a locally
recorded hash of its official release asset, whose older GitHub metadata has no
upstream asset digest. Those trust distinctions are retained in the lock.

## Windows fixes actually exercised

- The child shell prepends `/usr/bin:/bin` before using `cygpath`; a raw
  `bash --noprofile --norc` did not inherit these paths on this host. The first
  failed attempt is retained as `logs/openssl-host-attempt1.log`.
- OpenSSL 3.0.12 reads `ANDROID_NDK_ROOT` / `ANDROID_NDK`, not
  `ANDROID_NDK_HOME`. Both aliases are set for this child process only.
- NDK source/build paths use `cygpath -u`; OpenSSL's NDK detection compares the
  path returned by `which(clang)` against its NDK root. Both now have the same
  POSIX spelling and Configure selected `aarch64-linux-android30-clang`.
- Native Windows CMake uses Ninja explicitly, with an absolute
  `CMAKE_MAKE_PROGRAM`. The upstream Unix Makefiles generator and automatic
  `uname` host selection are not used for this dependency.
- OpenSSL's installed `.pc` prefix is converted from MSYS `/d/...` to native
  `D:/...` before later native Windows pkg-config/Meson consumption. The shared
  libraries are not rewritten by that metadata fix.
- Shared-library links explicitly request 16 KiB segment alignment. This is a
  per-artifact inspection gate, not whole-app 16 KiB support: the selected old
  NDK's C++ runtime and the other runtime libraries still need replacement and
  end-to-end validation.

## Observed results and next gates

OpenSSL's actual Configure completed successfully and began native Windows NDK
ARM64 compilation (over 1,500 real object files produced). SDL2's actual CMake
configure identified Clang 14.0.7 and the Android target. Its first native Ninja
ABI probe was interrupted after waiting over four minutes after its object file
was written, and retried with scoped tool permission. No compiler error had been
reported; this observation does not establish the sandbox as the root cause.
`SDL2-configure-attempt1.log` is retained. The second configuration, all 261
compile/link steps, install, and ELF validation **completed with exit code 0**.
From 09:57:25 to 10:07:27 China time, the complete second invocation took
approximately 602.5 seconds (Configure 520.0 s, Generate 6.1 s).

Actual SDL2 artifact:

- `temp/windows-native/prefix/arm64-v8a/lib/libSDL2.so`, 5,522,632 bytes.
- SHA-256 `021898424c11e7ddb53e40914661cff77ea79e01ff088b812a1625c49bdfd76c`.
- ELF64 AArch64, SONAME `libSDL2.so`; all four LOAD segments align to `0x4000`.
- DT_NEEDED: Android `libm`, `libOpenSLES`, `libdl`, `liblog`, `libandroid`,
  `libGLESv1_CM`, `libGLESv2`, `libc`, plus NDK `libc++_shared.so`.
- Evidence: `SDL2-build-result.json`, `logs/SDL2-{configure,build,install}.log`,
  and `logs/SDL2-elf.txt`. This component-build record did not perform device
  validation; the same library later loaded in the full-source emulator probe.

OpenSSL Configure, 1,793 object files, shared-library link and `install_dev`
completed with exit code 0, from 09:47:41 to 10:18:15 (approximately 1,834.3 s).

The common prefix now contains these **22 source-built libraries**. This is a
component milestone; the full engine's separate build and probe are described below.

| Installed artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `libSDL2.so` | 5,522,632 | `021898424c11e7ddb53e40914661cff77ea79e01ff088b812a1625c49bdfd76c` |
| `libcrypto.so` | 4,535,656 | `de05aea08a9fc2ede789b95a1cdd668b17c94dad198cde3ea12d05d126aadd7c` |
| `libssl.so` | 700,032 | `343cf6b7ef6c95ec19a41950028198f339bc6655cea9e83e6d897d865b5d05b4` |
| `libogg.so` | 86,648 | `4b7daf0613b478001da168c6d6be70c1246f7a69aa6812400bb1a50ad7061af2` |
| `libvorbis.so` | 590,592 | `8fbeff22c70c163d2ac77c82f89508dba8dc07ce2491421875d9f180cb6a6581` |
| `libvorbisfile.so` | 122,432 | `3b89871bb5cfbd522f0ebb6c84d53e879d740e694981a4a24940f087a6ddb52d` |
| `libvorbisenc.so` | 1,018,096 | `5f21a5a7382d0f5d67011f7adde28c765757792d5163fcbc34718c4bb62c3e8d` |
| `libpng16.so` | 1,020,568 | `d95435aee0de7f6c58ffd619984ccc789ae8e41265b6c75a98bc8ad448022f84` |
| `libphysfs.so` | 754,712 | `8f2002e7b58ae23761768d312f3a9859f0484dcb568553622cacfd69ccf38318` |
| `libfreetype.so` | 3,948,816 | `0b8e90ea534fb861edcbc9ba2ebb6655ad5303bb690cf3b2a36b586b6d5c94bf` |
| `libruby.so` | 16,709,096 | `aa4a6a26739d453a3b29b49b579cfa7a708eef9ed04f133467072cf93ba9610a` |
| `libopenal.so` | 15,684,528 | `92d27ebe6079bc5ab22ed59c8817c66dbbe2ba72c4a53c723fba690878c125ff` |
| `libSDL2_ttf.so` | 291,824 | `514be022ac7612224f72a5c4323927a90444de54d7f86ed3fb4fc982503012cf` |
| `libSDL2_sound.so` | 1,962,360 | `60cf008bdc91bf6b42858779761e78323d9010f3a986f76f622868f9d607e836` |
| `libSDL2_image.so` | 872,432 | `9cbe397144abd6714037d1c20d5478535e727196e4c340dbab8e121c2339b75f` |
| `libuchardet.so` | 479,800 | `0290c1c140a2293f5a68f5a1a7f8202b1dd502c91007fa28e3aee0b3e9ae8633` |
| `libpixman-1.so` | 493,960 | `bef895aaa2094b17fb38a404a6b55fbd7f8eb9ac23b38669cd80c19a5b6ca488` |
| `libtheora.so` | 200,472 | `a568ee5186bca9a29776699edba85e2b13fd09b66b8306455039d6a093d3e64d` |
| `libtheoradec.so` | 66,832 | `52f7919ee88e9b306192d81cc66bcd3b47da3905df2cccd4481f900c523a0f2c` |
| `libtheoraenc.so` | 174,784 | `ea6d4cecb1ca0a4535ff0a5465d56b52af604be764e64668a132052adef8bae8` |
| `libiconv.so` | 977,872 | `66d500c2a58be062e9fa01c43569b6c41c2f7ecb64a075b6823ec2efaf397f01` |
| `libcharset.so` | 5,584 | `f16c393787e5571339f8971164302c6275bed4dd8c3fd44bb66681980e3d567e` |

Ogg's first full invocation took 56.1 s. Vorbis's first 25-step build/install
took 29.5 s; an artifact-manifest pipeline fix was then checked with a cached
rerun. Its original Ninja compile history is retained in
`logs/libvorbis-first-compile-ninja.log` and the first result in
`libvorbis-build-result-before-schema-fix.json`. PNG's first 19-step build/install
took 19.4 s. Its generated `.pc` files were missing after install because upstream
suppresses their installation on a Windows host; the script now installs these
already-generated files and a cached rerun verified that repair. Prior PNG logs
and result are automatically archived under `logs/previous`. NDK r25c's actual
zlib header declares **1.2.12**, so `zlib.pc` is derived from that header rather
than using upstream's hard-coded 1.2.13. PNG uses that NDK system ABI; no host zlib
is linked.

`windows-native-verify.ps1` has actually passed hash, AArch64, matching SONAME,
all-LOAD `0x4000`, and required dynamic-export checks for **8** shared libraries
(SDL2, Ogg, three Vorbis libraries, PNG, two OpenSSL libraries).
Evidence is `component-verification.json` and `logs/verified-*`.
This is component validation, with **no device execution**, and does not certify
the full APK or bundled C++ runtime for 16 KiB devices. These experiments target
API 30; Android versions below that are outside this source-build validation.

The independent PhysicsFS build also completed its 22 compile/link steps,
installation, 5 required exports, AArch64/SONAME/4 LOAD alignment checks. Its
separate output is `temp/windows-native-physfs/prefix/lib/libphysfs.so`, hash
`caa9ebd1d3108a00d3011129ae764681c2144da7fb4b8016d31fe69fc185cc40`,
with result/ELF/exports logs in that output directory. Its native Windows
pkg-config prefix and relocatable CMake metadata were inspected. It has not been
used on a device. It was subsequently rebuilt through the checked-in common
pipeline in 9.34 s: common-prefix `libphysfs.so` hash is
`8f2002e7b58ae23761768d312f3a9859f0484dcb568553622cacfd69ccf38318`.
The changed hash reflects a separate build directory/debug paths, not an
assertion of bit-for-bit reproducibility across build locations.

FreeType 2.13.0 and its exact dlg gitlink also passed an independent native
CMake 43-step build, install, ABI/SONAME/3 LOAD checks and seven required exports
in 28.371 s. PNG/zlib feature macros and `.pc` metadata were inspected; bzip2,
HarfBuzz and Brotli were explicitly disabled, matching dependencies absent from
this baseline prefix. Independent artifact:
`temp/windows-native-freetype/prefix/lib/libfreetype.so`, hash
`ba5e5519911004b48501b89d1b5c7e51999c68a097822f8c41e20ed50da70d48`.
The checked-in common pipeline then rebuilt and installed it in 24.30 s, hash
`0b8e90ea534fb861edcbc9ba2ebb6655ad5303bb690cf3b2a36b586b6d5c94bf`.
The common pipeline checks the dlg gitlink/commit, copies only the same dlg
sources as upstream autogen.sh, and uses native CMake instead of Autoconf.
Its source may be reused with `-SourceDirectory` when it is inside task temp;
the exact commit and clean working tree are still required.

Ruby's selected target build/install and complete mandatory-extension component
gate passed at **2026-10-20 12:10:32 China time**, after the host repairs below.
The final successful single-job invocation ran from 12:06:58 to 12:10:32
(approximately 213.2 s), using cached objects from the earlier actual compilation.
Other dependency make/Ninja starts were initially paused for the emulator GUI
loop, then resumed at one job after authorization. OpenAL 1.24.3 source at
`dc7d7054a5b4f3bec1dc23a42fd616a0847af948` under
`temp/windows-native-openal/source` has no gitlinks. Its later 98-step CMake
build/install completed from 12:43:39 to 12:47:08, with required OpenSL enabled,
Oboe disabled, al/alc exports and ELF gates passed. SDL_ttf, SDL_sound, SDL_image,
uchardet and Pixman subsequently passed their own actual builds and gates.
The host has noticeable process-start and file/page-in delays: MSYS2 startup and
OpenSSL's generated Makefile step take minutes here. Compiler thread snapshots
showed `PageIn` waits with little CPU, so wall time is not a useful extrapolation
from Linux build rates.

Logs and ELF/hashes are under `temp/windows-native/logs`,
`*-build-result.json` and `prefix/arm64-v8a`. They are now packaged only in the
separate full-source probe; the normal game's libraries remain a separate
integration and game-regression decision.

Common-prefix libiconv, native engine link, full-probe export/DT_NEEDED closure
and basic Android load/function/rendering checks have since passed. Full-game
and physical-device regression remain separate.
An OpenSSL compatibility-baseline
build does not approve 3.0.12 for product TLS; Android's Java TLS bridge remains
the chosen verified trust-provider route.

The official Ruby 3.4.10 release tarball passed its published SHA-256. The first
patch attempt returned success from the outer KIF repository while silently
skipping the tarball's files. Independent review caught this before any Ruby
library was built. Patch verification now uses an explicit external temporary
Git directory and Ruby work tree; the fixed
runtime patch's CRLF is converted to LF (both byte hashes are locked), and
`git apply --check`, actual application, and `git apply --reverse --check` all
pass against that root. The expected `class.c`, `sprintf.c` and
`vm_insnhelper.c` changes were also inspected directly. Its generated
Configure is being exercised with host Ruby 3.2.9 (satisfies the documented
Ruby >= 3.0 bootstrap requirement), Android ARM64/API 30, and YJIT/RJIT disabled.
The patch's only `configure.ac` edit is in the MinGW target branch; using the
release's generated Configure is valid for this Android target. Its timestamp
is updated after patching to avoid an unnecessary Autoconf regeneration.
The Ruby install step also clears `DLDFLAGS` in `ruby-3.4.pc`, matching the
runtime's existing recipe, so `-soname,libruby.so` cannot contaminate the later
engine link through pkg-config.

Independent host-Ruby inspection also confirmed that MSYS `/d/...` is interpreted
as Windows `D:/d/...` by Ruby `File.expand_path`. The script therefore keeps
POSIX paths for shell `cd`/`mkdir` and uses `cygpath -m` for installation-prefix
metadata, OpenSSL directory, and include/library flags consumed by native Ruby.
The initial POSIX-prefix configure was interrupted before make, retained as
`ruby-configure-posix-prefix-attempt1.log`, and restarted with these corrected
values. Essential `openssl`, `socket`, and `zlib` extensions are mandatory;
successful make without them cannot pass the build gate. Ruby artifact validation
requires AArch64, `libruby.so` SONAME, aligned LOAD segments, and all three module
initializers in the unstripped library symbol table. Runtime `require` tests
remain a separate Android device gate.

Ruby Configure completed with exit code 0 and generated Makefile/config.h;
`logs/ruby-config-success.log` preserves its configuration. An early wrapper
attempt was interrupted by editing a shell script while Bash was waiting on
Configure; Bash resumed from the wrong byte offset. Wrappers now execute an
immutable snapshot under `temp/windows-native/scripts` so live edits cannot
change a running script. Snapshots use UTF-8 without BOM and LF endings even
when the Windows checkout has CRLF. `ResumeBuild` verifies the existing compiler, native
prefix and mandatory-extension configuration before continuing make.
The first actual make then failed in `file2lastrev.rb` because the initially
in-source empty patch repository had no HEAD. Git metadata is now preserved
outside the source, and patch verification uses explicit `--git-dir` and
`--work-tree`, keeping the official release tarball's revision generation route.
The generated Makefile's `LIBRUBY_SONAME` is also set to `libruby.so`: Ruby appends
its own SONAME flag after user `DLDFLAGS`, so the user flag alone is insufficient.

An earlier resumed make passed that revision step and linked only a core
`build/ruby/libruby.so.3.4.10`. That intermediate library was not accepted:
the necessary OpenSSL/socket/zlib `mkmf` link probes were rejected and their
extension Makefiles were marked DUMMY. The logs contain native `D:/...`
compiler/header/library paths, but no Clang diagnostic. Evidence:
`build/ruby/ext/{openssl,socket,zlib}/mkmf.log`, `logs/ruby-build.log`.
Mandatory-extension and final-symbol gates remain in place, so this incomplete
core library could not pass the script's final acceptance.

At 10:32:43 China time, the root agent authorized stopping only the three
identified non-compiling Ruby/make waiters after the failed mandatory probes.
Their IDs, creation times, command lines and empty compiler-descendant list are
retained in `logs/ruby-manual-stop.json`. Failed mkmf logs and the build log are
copied to `logs/ruby-{openssl,socket,zlib}-mkmf-failed.log` and
`ruby-build-mandatory-fail-manual-stop.log`. This is failed extension validation
followed by manual termination at a safe point, not natural whole-build success.

The host-only diagnostic isolated a definite rejection condition in mkmf's
`try_link0`: it requires a successful compiler command **and**
`File.executable?(conftest)`. Android's configuration has `EXEEXT=''`. The same
4,912-byte ARM ELF data was checked as `conftest` and `conftest.exe`: Windows Ruby
reported the former non-executable and the latter executable. Host Ruby `exit(0)`
commands succeeded using both string and argv forms, before and after loading
target `fake.rb`. No compiler or target executable was run. Evidence:
`temp/windows-native/mkmf-host-probe/{README.md,result.json}`.

The fix is the separate tracked
`scripts/android/patches/ruby-3.4.10-mkmf-windows-cross.patch`. It still requires
the link command to succeed. Only an original Windows host **string** saved in
`CROSS_COMPILING` permits a regular output file when the host's executable
predicate rejects it. Native builds, non-Windows hosts, false/nil values, missing
outputs and failed commands retain their checks. The code uses the original host
saved by `fake.rb`, rather than the faked `RUBY_PLATFORM`, and does not alter
Android `EXEEXT` or skip development/feature/mandatory-extension probes.

The lock records patch SHA-256
`35bbbd7d8ba347bc4d6c9dc4887f8f5eba4c1bbc9ebe5caa679b9e8794e67877`,
unpatched `mkmf.rb` hash
`e67c3ef2f1f1cafd596aba005625e7b6f75c756ffe1b6ba79b1fe10ce84ee55e`,
and patched hash
`21cb127b857296a49eae1d550d5e11ca2152496f3163009ddd73fae2eb75d11e`.
Patch files use LF via scoped `.gitattributes`. Preparation checks original
bytes and forward hunks, applies once, then verifies reverse hunks and resulting
bytes on every invocation; altered sources/patches fail closed. `PrepareOnly`
has actually passed twice against the real temporary source tree, including the
already-applied case, with no MSYS/NDK/make process started.
`ruby-source-preparation.json` records both independent patches and
`compiled=false`. Ruby build defaults to one job. The later target rebuild and
component checks passed as described below; later basic Android execution passed
in the separately recorded probe, while game acceptance remains separate.

## Ruby target completion and host installation repairs

The fixed mkmf gate allowed actual NDK probes to complete. OpenSSL, socket and
zlib all generated non-DUMMY Makefiles and real ARM64 archives. The next make
failed linking an internal Ruby test module because `libruby.so` was absent:
Ruby's Makefile hard-codes `File.symlink` for build aliases and ignores its
permission failure, even though Configure had selected `LN_S=cp -pR` on this
host. An initial existing versioned core alias is copied before make; subsequent
build/install aliases use an opt-in host helper loaded by `MINIRUBYOPT`.

`windows-native-ruby-host-links.rb` keeps ordinary symlinks when permitted.
On Windows permission failure, its copy fallback accepts only regular files
whose resolved source and destination parent are inside this task's explicit
build output root. It refuses directories, escaped paths and replacement of
existing files, and logs copies in `logs/ruby-host-link-copies.log`. It is loaded
only by host build tools and is never part of game payloads. Immutable snapshots
also prevent edits from affecting an active helper. The initial successful helper
hash was `d08b84c4629900c6bb54be1bed4d26ad904d871fc6cfbacd16374b4436566d7b`.
The later host error-preservation repair described below has final normalized
snapshot hash `348ff47fdfe7c5b7e680f2a29185c0888886f50086f134ebbe594fe8f631a853`.

The next installation attempt exposed RubyInstaller's Windows-specific
`rubygems/defaults/operating_system.rb` on the host load path; it rejected the
faked Android platform. The same opt-in helper isolates that host OS integration
feature while leaving target RubyGems and rbinstall active. No system privilege
or installed host file was changed. The initial **12 host assertions passed**, including
copy permission fallback, root boundaries, existing-file preservation and this
OS-feature isolation:

```powershell
& ./temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe `
  --disable-gems ./android/tests/windows_native_host_links_test.rb
```

The successful build follows the original `--with-static-linked-ext` model:
`openssl.a`, `socket.a` and `zlib.a` are embedded into the installed shared
`libruby.so`; separate extension `.so` files are not required for these three.
`windows-native-verify-ruby.ps1` actually checked:

- Real, non-DUMMY extension Makefiles; 34/15/1 ARM64 ELF archive members for
  OpenSSL/socket/zlib; their initializer definitions.
- All three archives in `EXTOBJS`, names in `EXTINITS`, and `init(...)`
  registration calls in `ext/extinit.c`.
- Installed `libruby.so`: AArch64, SONAME `libruby.so`, four LOAD segments all
  aligned to `0x4000`; full symbol table definitions of `ruby_init`, `Init_ext`,
  `Init_openssl`, `Init_socket` and `Init_zlib`.
- Dynamic dependencies include `libssl.so`, `libcrypto.so`, `libz.so`, `libdl.so`,
  `libm.so` and Bionic `libc.so`. Ruby's `.pc` has a native host prefix and empty
  `DLDFLAGS`, preserving the later engine's own SONAME.
- Runtime compatibility/host patch hashes were rechecked before every retry;
  final mkmf bytes still match the locked patched hash.

Evidence: `ruby-build-result.json`, `ruby-module-validation.json`,
`logs/ruby-complete.{elf,symbols}.txt`, each `ruby-*-archive.*` log, the actual
make/install logs and archived failed attempts under `logs/previous`.
The optional Psych extension was skipped because this dependency baseline has
no `yaml.h`; no extra dependency was built to conceal that limitation.

This is a successful selected Ruby component build, not whole-runtime or Android
execution acceptance. `deviceValidated=false` and `targetExecuted=false` remain
in the evidence. No game APK library was replaced and no AVD was operated. The
first complete Ruby ELF recorded upstream's host-prefix RUNPATH. That output's
hash and ELF/symbol evidence are retained under
`temp/windows-native/history/ruby-with-host-runpath`; it is not an accepted APK
override. Android library search/loading, including the three embedded module
`require` calls and functions, still needs execution validation. The full engine
and remaining dependencies are outstanding.

### Remove host RUNPATH through Configure

The pinned official Ruby source's `configure.ac:661` defines `enable_rpath` with
`AC_ARG_ENABLE`, so `--disable-rpath` is a supported Configure option.
`configure.ac:666` controls `RPATHFLAG`; lines 3702–3712 add
`LIBRUBY_RPATHFLAGS` to shared/static link arguments only when the option is
enabled. The Windows recipe now passes `--disable-rpath` at configuration time,
and `ResumeBuild` refuses a Makefile without that exact option. This does not
edit ELF bytes or substitute a different source version.

An actual single-job `-Stage Build -Jobs 1` reconfiguration passed on
2026-10-20. `windows-native-verify-ruby.ps1` rejects any `DT_RPATH` or
`DT_RUNPATH` in the installed ELF and any `-rpath` in installed Ruby pkg-config
metadata, as well as requiring the Configure option. Its existing ARM64,
16 KiB alignment, SONAME and mandatory-module gates remain active. Final accepted
`ResumeBuild -Jobs 1` ran from 12:39:09 to 12:43:02 (233.4 seconds after prior
configuration/link work). Installed Ruby is 16,709,096 bytes, SHA-256
`aa4a6a26739d453a3b29b49b579cfa7a708eef9ed04f133467072cf93ba9610a`.
Both shared/static `.pc` arguments now have no rpath; all three mandatory
archives retained their hashes and initializer registrations. The installed
ELF passed the complete gates, with `runtimeSearchPath=none` and target/device
execution still false in `ruby-module-validation.json`.

The clean reconfiguration exposed one additional host-only bundled-gem issue:
Android `fake.rb` makes FileUtils classify a native `D:/...` source argument as
relative in `tool/ln_sr.rb`. After the expected Windows symlink denial, the host
helper's `realpath` raised `EINVAL`, which blocked the tool's own `cp_r` fallback.
The helper now preserves the original permission exception when path resolution
fails with EINVAL/ENOENT/ENOTDIR; it still does not copy directories itself.
**14 host assertions now pass**, including this actual malformed drive-path case
and original-error identity. No target source or installed host interpreter was
patched. The subsequent first Resume attempt was still using a cached old
immutable helper path in generated extension Makefiles and failed again; this
failure is retained as history, not reported as new-helper success.

Helpers are now named by their normalized content SHA-256. Before make starts,
the wrapper refreshes only the old helper path with this task's exact temporary
prefix in generated `build/ruby/**/Makefile` files. It refuses file reparse points,
does not alter source/compiler arguments or old helper snapshots, and records
the refreshed files in `logs/ruby-host-helper-refresh.json`. The final successful
make/install actually loaded the new helper and passed bundled-gem copies.

### Independent component integration probe

`scripts/android/build_native_probe.py` builds a separate minimal diagnostic
application. Reproduction and exact three override hashes are in
`android/native-probe/README.md`. Its actual signed output is
`temp/native-probe/Native-Ruby-Probe-arm64-emulator-test.apk` (25,426,026 bytes),
latest SHA-256 `436e448104b30f3d44a7cab5bdc65572ab30764e916560d23f1799fddce11c3f`.
The adjacent build-record JSON records every library/payload hash and origin.

Actual host checks passed: javac/Dex, apksigner v3 verification, final aapt2
package/label/activity/permission audit, exact ZIP content/hashes for 22 native
libraries and 29 payload files, and Ruby/SSL/crypto overrides with no missing
consumer-import symbols (133/104/1044 imports respectively). Each override has
the required ARM64 ABI, SONAME, all-LOAD `0x4000` and no RPATH/RUNPATH.
Eleven manifest-isolation negative cases were also actually rejected by
`android/native-probe/test_isolation.py` on the host.

The package is `org.kuray.kif.nativeprobe`, visibly labelled `Native Ruby Probe`.
It retains fully qualified `org.kuray.kif.*` Java classes for the pinned JNI
contract, but has its own Android UID and private files. Its GameActivity is
non-exported in a separate `:probe` process. Only VIBRATE permission is present;
no network, shared UID, provider or external-storage permission is included.
The tiny dedicated installer contains no game save-management code. Payload
allowlists exclude game Data/Graphics/Audio/PBS and saves. The probe creates and
then reads only its own freshly written private `probe.dat`.

On authorized launch the fixture requires OpenSSL/socket/zlib/Digest,
exercise SHA-256, Addrinfo, Zlib and Marshal roundtrips, invoke the existing JNI
input helper, render bundled-font pixels and run 120 frames. It writes a private
JSON result, first clearing any old PASS to `native_start_pending` before native
library loading. These steps have now actually passed in both final packages;
the evidence and scope are in [native-device-report.md](native-device-report.md).
The initial mixed package (`da1ff490...`) was earlier launched by
the root device task (PID 18300) and failed before these module steps: Java had
canonicalized its output to one Android private-path alias while Ruby compared
`File.expand_path` against the other `/data/data` versus `/data/user/0` spelling.
The guard now compares `File.realpath` on both paths and retains the strict
dedicated `files/native-probe/` child boundary. It logs canonical and expanded
paths. Eight host-only regression checks passed, modeling both alias directions
and rejecting cross-app, boundary and prefix-spoofing cases; actual Android
resolution was confirmed by the final successful device logs. The original APK/record/hash and
failure description remain under `temp/native-probe/history/da1ff...`.
The native-build subtask itself did not install/start/stop an AVD.

Only Ruby and OpenSSL are source-built overrides in the mixed APK; the engine/SDL and
other libraries remain pinned historical prebuilts. The explicit emulator build
also applies the already-documented 16-byte translation workaround, with original
and changed engine hashes recorded. This APK does not establish full-engine
source-build success or whole-APK 16 KiB-device support.

The separate `build_native_full_probe.py` uses the completed source core,
dependencies and matching source SDL Java. Every component/core input SHA and
3,727 strong imports, including GNU versions/providers, must match each actual
reachable dependency closure. Its 21 selected libraries and 43 payload entries
were independently audited, then actually ran on the emulator without the old
16-byte engine translation patch. The sole standard toolchain exception is
fixed NDK r25c `libc++_shared.so`, still 4 KiB; full APK 16 KiB compatibility is
explicitly false. See [full reproduction](../../android/native-probe/full-runtime-README.md)
and [actual device results](native-device-report.md).

Host regression command (no NDK, make, Ninja, emulator or target execution):

```powershell
& ./temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe `
  --disable-gems ./android/tests/windows_native_mkmf_test.rb
```

This test has actually passed **245 assertions** using both the pinned original
and already-patched input states. Each run loads the complete real old/new
`mkmf.rb` in separate host Ruby workers, covering 17 cases per version. Only the
link command is replaced with a host Ruby helper writing 64-byte ELF data, and
the cached preliminary development-tool result is fixed in the test fixture.
The real `try_link0`, `try_do`, `xsystem`, host process call, public `try_link` and
cleanup paths execute. Old logic rejects the extensionless ELF; new logic accepts
it only for Windows host strings. Failed/missing commands, missing output,
native/non-Windows contexts, type/boundary spoofing, warning-as-error, and legacy
`.exe` checks retain their behavior. The fixture checks and actually applies
both patch directions, verifies exact old/new hashes, and leaves the input source
unchanged. Latest evidence: `temp/host-checks/windows-native-mkmf/latest.json`;
both state-specific runs are retained in its timestamped sibling directories.
On this managed host, the host Ruby/Git test needs scoped tool execution because
default-sandbox Open3 pipe creation returns `EACCES`; no system setting changes
are needed. This establishes the host gate regression. Actual ARM64 extension
compilation has since passed the separate component checks above; Android
module loading has since passed in the separate final diagnostic APK runs.

A portable fallback host interpreter was found in official MSYS2 metadata:
`ruby-3.4.10-1-x86_64.pkg.tar.zst`, SHA-256
`eb46af8e6d1485e8ac5beb72d5131d2e8584b79445a6e48adcf89c540f1bc703`.
It provides an MSYS/Cygwin Ruby, potentially avoiding the native MinGW host's
process/path boundary. This is **research only**, neither downloaded nor tested.
Its missing host dependencies `libgdbm` and `libyaml` would also need fixed
official package hashes; the remaining listed dependencies are in the portable
MSYS2 base. Do not conflate this host interpreter with the target ARM64 Ruby.

## Next native dependencies and engine route

`windows-native-sources.ps1` is an executable preparation stage, independent of
compilation. On 2026-10-20 it actually fetched/verified SDL_ttf, SDL_sound,
SDL_image, uchardet, Pixman and Theora at the exact commits in
`windows-native-lock.json`; OpenAL reused its already-verified dedicated source
checkout. Each `<dependency>-source-preparation.json` records the exact commit,
all gitlinks and `.gitmodules`, with `compiled=false`. It refuses a modified
checkout, an unexpected commit, and a pre-existing source directory without its
own Git metadata. No recursive floating submodule download is performed.

```powershell
& ./scripts/android/windows-native-sources.ps1 -Dependency SDL2_image -Fetch
& ./scripts/android/windows-native-sources.ps1 -Dependency openal `
  -SourceDirectory ./temp/windows-native-openal/source
# Once the Ruby/probe build has finished, keep actual compiles at one job:
& ./scripts/android/windows-native-cmake.ps1 -Dependency openal `
  -SourceDirectory ./temp/windows-native-openal/source -Jobs 1
& ./scripts/android/windows-native-cmake.ps1 -Dependency SDL2_ttf -Jobs 1
& ./scripts/android/windows-native-cmake.ps1 -Dependency SDL2_sound -Jobs 1
& ./scripts/android/windows-native-cmake.ps1 -Dependency SDL2_image -Jobs 1
& ./scripts/android/windows-native-cmake.ps1 -Dependency uchardet -Jobs 1
& ./scripts/android/windows-native-pixman.ps1 -Jobs 1
& ./scripts/android/windows-native-autotools.ps1 -Fetch
& ./scripts/android/windows-native-theora.ps1 -Stage Prepare
& ./scripts/android/windows-native-theora.ps1 -Stage Build -Jobs 1
```

The common CMake script's five new recipes have all actually passed. They check
ARM64, SONAME, all LOAD alignment, absence of runtime search paths and
necessary exported interfaces. OpenAL requires its OpenSL ES backend and disables
unprovided Oboe. SDL_ttf uses the common-prefix FreeType, with vendoring and
HarfBuzz disabled; its two unused external gitlinks remain recorded in evidence.
SDL_sound explicitly retains Android's no-versioned-SONAME setting. SDL_image
uses its committed STB PNG/JPEG backend and committed GIF/BMP/etc loaders; optional
AVIF/JXL/TIFF/WebP codecs are disabled. Its eight unused codec gitlink revisions
are locked and checked, without downloading or building unused codec projects.
This matches the fork's default enabled format choices; functionality still
needs runtime tests.

Pixman 0.42.2 passed an actual 31-step Meson/Ninja build/install in 26.7 seconds.
`windows-native-pixman.ps1` reuses the fixed portable Meson/pkgconf bootstrap,
explicit native Windows Clang argv and a generated Android cross definition.
Its fixed recipe disables ARM/NEON assembler backends and tests/demos, sets
`needs_exe_wrapper=true` and `--wrap-mode=nodownload`, and verifies four exports,
ARM64/SONAME/all-LOAD `0x4000`/no runtime search path. Only its selected target
library was built; no Android code or Pixman tests were executed on Windows.
The selected Theora Git source has only `configure.ac`/`autogen.sh`, not a
generated Configure or CMake project; its `autogen.sh` calls `autoreconf -isf`.
The initially missing Autoconf, Automake, libtool and m4 are now provided by
`windows-native-autotools.ps1`. Five official MSYS2 package archives have fixed
published hashes in the lock and were actually downloaded/verified/extracted
under portable MSYS2; no pacman, install hooks or system package installation was
used. Existing base GCC/iconv runtime DLLs and Perl satisfy their host needs.
Actual `--version` checks passed for m4 1.4.21, Autoconf/autoreconf 2.72,
Automake 1.18.1 and libtoolize 2.6.2. Wrapper packages requiring many unused tool
versions were avoided by explicit versioned environment commands.

`windows-native-theora.ps1 -Stage Prepare` has actually passed the official
`autoreconf -isf` flow in a dedicated export, preserving the clean original Git
checkout. Every original exported file has a retained SHA-256 and is checked
before reuse. An initial failure was diagnosed as 711 CRLF lines in exported
`configure.ac`, while the committed blob had zero CRLF lines: Git archive was
applying this host's checkout line-ending policy. The export now uses the scoped
`git -c core.autocrlf=false archive` option, leaving global Git settings intact.
The failed export/log/manifest are retained under
`history/theora-crlf-export-failure`; the successful LF export archive hash is
`877a1d6307abea54295959252f48fd39fb44d8f096212720bc46f0ef0692d7e5`.
Theora's actual single-job target configuration, compilation and install all
completed successfully. The first post-build gate incorrectly rejected valid
GNU versioned exports such as `th_decode_alloc@@libtheoradec_1.0`; its exact-name
check now accepts a conventional GNU symbol version suffix and retains the
full dynamic-symbol evidence. A cached `ResumeBuild -Jobs 1` passed the full
recipe and all three library gates at 12:56:43, taking 9.0 seconds after the
earlier actual compilation. The earlier compile/install logs are retained in
`logs/previous/libtheora-20261020-125634-210`; the final result is
`libtheora-ResumeBuild-result.json`. All three libraries have ARM64/API-30,
plain `.so` SONAMEs, all LOAD `0x4000`, no runtime search paths and their required
legacy decode/modern decode/modern encode exports. No `make check` or target
executable was run. Exported-source verification does not modify the clean Git
checkout; generated Autotools files stay in the separate temporary export.

The Pixman runner now consistently uses Python `-B` and a process-only
`PYTHONDONTWRITEBYTECODE=1`, restoring the caller's value afterward, so Ninja's
Meson helpers also leave the fixed portable Meson source cache intact. The
initial successful run's ordinary Python bytecode files were isolated by the
root tool-bootstrap guard; these files were not unexplained source changes.
The root agent completed fixed GNU libiconv into the common API-30 prefix at
12:57:49, preserving its earlier API-21 proof and fresh-build logs separately.
`libiconv-build-result.json` records both actual shared libraries, exact GNU
archive hash, exports and ABI/SONAME/all-LOAD/no-RPATH checks.

The engine is a **Meson shared-library project**, not a CMake project. Its
`src/meson.build` resolves these native dependencies; `binding/meson.build` uses
`ruby-3.4.pc`. The historical Android cross file uses extensionless NDK shell
wrappers. For native Windows Python/Meson, the reproducible cross file should
use explicit `clang.exe`/`clang++.exe` argv with Android API-30 targets, native
Windows pkg-config and only the selected prefix's `.pc` files. Generated asset
headers invoke `xxd-include.sh` plus xxd/sed; this is a concrete host shell-tool
boundary, separate from target C/C++ compilation. Meson itself supports Windows
and explicit cross definitions; this boundary is not proof that WSL is required.

The engine's source export at `temp/runtime-research/warmwinter-release` is safe
for reference, but a core build should use its own exact detached runtime Git
checkout. Top-level Meson runs `git rev-parse --short HEAD`; an export nested in
the KIF checkout could otherwise accidentally embed the outer repository's hash.
The root agent owns the separate [core/tool-bootstrap preparation](windows-native-core.md), while this
pipeline owns Ruby and dependency compilation. The root task subsequently
completed the 112-step real core compile/link. The raw core carried a Meson-added
host-prefix RUNPATH; a separate packaged copy uses fixed Meson 1.9.1's standard
`depfixer.fix_elf` installation cleanup. The proof retains the original raw hash
and confirms length, SONAME, dependencies, 16 KiB LOADs and every byte outside the
768-byte `.dynamic` section are unchanged. The accepted packaged core is
3,463,072 bytes, SHA-256
`fab5f32f2642d7ac58d552a3e3dd1f75fabc16e22f274e7ff70364d2a3d3a96c`,
under `temp/windows-native-core/packaged`. Its full build record still states
`fullRuntimeBuilt=false` and `targetExecuted=false`, preserving its build-time
status. The later full-probe build/closure audit and actual emulator run have
separate records; full-game regression remains an explicit later gate.

Primary references:

- [NDK with other build systems](https://developer.android.com/ndk/guides/other_build_systems)
- [OpenSSL fixed Android Configure source](https://github.com/openssl/openssl/blob/c3cc0f1386b0544383a61244a4beeb762b67498f/Configurations/15-android.conf)
- [Official MSYS2 Perl package](https://packages.msys2.org/packages/perl?repo=msys&variant=x86_64)
- [CMake 3.31 Ninja generator](https://cmake.org/cmake/help/v3.31/generator/Ninja.html)
- [CMake 3.31.6 checksums](https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-SHA-256.txt)
- [Ninja 1.12.1 release](https://github.com/ninja-build/ninja/releases/tag/v1.12.1)
- [Official MSYS2 Ruby package](https://packages.msys2.org/packages/ruby?variant=x86_64)
- [Ruby cross-extension configuration discussion](https://bugs.ruby-lang.org/issues/20345)
- [Meson cross definitions](https://mesonbuild.com/Cross-compilation.html)
- [Meson Windows installation and portable entry points](https://mesonbuild.com/Getting-meson.html)
- [Native Windows pkgconf portable package](https://packages.msys2.org/packages/mingw-w64-ucrt-x86_64-pkgconf)
