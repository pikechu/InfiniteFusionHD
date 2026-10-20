# Portable Windows native source build

Status: **in progress**, 2026-10-20. This extends the actual libiconv result in
[native-windows-build-feasibility.md](native-windows-build-feasibility.md).
It does not change the working APK's libraries or operate any emulator.
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
  and `logs/SDL2-elf.txt`. Device validation remains **not performed**.

OpenSSL Configure, 1,793 object files, shared-library link and `install_dev`
completed with exit code 0, from 09:47:41 to 10:18:15 (approximately 1,834.3 s).

The common prefix now contains these **10 source-built libraries**. This is a
component milestone; the full engine has not been rebuilt or replaced in the APK.

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

Ruby library build results remain pending.
At the root agent's request, further make/Ninja starts are paused while the
emulator GUI loop recovers; existing writes are allowed to finish naturally.
OpenAL 1.24.3 source is fetched at
`dc7d7054a5b4f3bec1dc23a42fd616a0847af948` under
`temp/windows-native-openal/source`, with no gitlinks, but no OpenAL CMake or
compilation has been started. Its next build must require OpenSL, disable the
unprovided optional Oboe dependency, and verify backend config and al/alc exports.
The host has noticeable process-start and file/page-in delays: MSYS2 startup and
OpenSSL's generated Makefile step take minutes here. Compiler thread snapshots
showed `PageIn` waits with little CPU, so wall time is not a useful extrapolation
from Linux build rates.

Logs and eventual ELF/hashes are under `temp/windows-native/logs`,
`*-build-result.json` and `prefix/arm64-v8a`. These libraries will remain separate
from the APK until the full set is linked and the runtime/game probes are rerun.

Still required: Ruby library, remaining media/font/pixman dependencies,
nested codec/submodule locks, native engine link, export/DT_NEEDED comparison,
and Android load/function/game regression. An OpenSSL compatibility-baseline
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

The resumed actual make passed that revision step and linked a core
`build/ruby/libruby.so.3.4.10`. It is **not an accepted complete Ruby artifact**:
the necessary OpenSSL/socket/zlib `mkmf` link probes were rejected and their
extension Makefiles are marked DUMMY. The logs contain native `D:/...`
compiler/header/library paths, but no Clang diagnostic. Evidence:
`build/ruby/ext/{openssl,socket,zlib}/mkmf.log`, `logs/ruby-build.log`.
Mandatory-extension and final-symbol gates remain in place, so this incomplete
core library cannot pass the script's final acceptance.

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
`compiled=false`. Ruby build now defaults to one job; target extension rebuild
and Android runtime checks remain pending while the IO hold is active.

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
are needed. This establishes the host gate regression, while actual ARM64
extension compilation and Android module loading remain pending.

A portable fallback host interpreter was found in official MSYS2 metadata:
`ruby-3.4.10-1-x86_64.pkg.tar.zst`, SHA-256
`eb46af8e6d1485e8ac5beb72d5131d2e8584b79445a6e48adcf89c540f1bc703`.
It provides an MSYS/Cygwin Ruby, potentially avoiding the native MinGW host's
process/path boundary. This is **research only**, neither downloaded nor tested.
Its missing host dependencies `libgdbm` and `libyaml` would also need fixed
official package hashes; the remaining listed dependencies are in the portable
MSYS2 base. Do not conflate this host interpreter with the target ARM64 Ruby.

Primary references:

- [NDK with other build systems](https://developer.android.com/ndk/guides/other_build_systems)
- [OpenSSL fixed Android Configure source](https://github.com/openssl/openssl/blob/c3cc0f1386b0544383a61244a4beeb762b67498f/Configurations/15-android.conf)
- [Official MSYS2 Perl package](https://packages.msys2.org/packages/perl?repo=msys&variant=x86_64)
- [CMake 3.31 Ninja generator](https://cmake.org/cmake/help/v3.31/generator/Ninja.html)
- [CMake 3.31.6 checksums](https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-SHA-256.txt)
- [Ninja 1.12.1 release](https://github.com/ninja-build/ninja/releases/tag/v1.12.1)
- [Official MSYS2 Ruby package](https://packages.msys2.org/packages/ruby?variant=x86_64)
- [Ruby cross-extension configuration discussion](https://bugs.ruby-lang.org/issues/20345)
