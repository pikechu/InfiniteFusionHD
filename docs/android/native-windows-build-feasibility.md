# Native Android runtime builds on this Windows host

Investigation date: 2026-10-16, Asia/Shanghai. Runtime source pin:
`warmwinter/mkxp-z` commit `68653811c3c396f2d4c12225c52c407746285a3d`
(`uranium-android@0.4.1`). The user currently has no Linux build resource and
prefers portable Windows tools. No WSL installation, driver installation,
Windows feature change, or global environment change is part of this work.

The existing Android runtime probe uses the publisher's native libraries. It is
**not a native source rebuild**. This investigation tests the Windows compiler
and a representative dependency separately; it does not replace those libraries.

## Source-supported conclusion

Windows NDK compilers can produce Android binaries, and the Windows/MSYS2
libiconv dependency build has now completed successfully. The original dependency
pipeline is POSIX-oriented and does not run unchanged under Git Bash or MSYS2.
Portable MSYS2 supplies missing build programs, but its presence alone does not
prove that Ruby, OpenSSL, every SDL codec, Meson, and the final engine will build.

Google's [NDK guide for other build systems](https://developer.android.com/ndk/guides/other_build_systems)
supports the `windows-x86_64` host toolchain and recommends direct Clang plus
`--target`. It also explicitly cautions that Autoconf projects generally cannot
be built on Windows, and recommends a Linux VM for that workflow. The Windows
path is therefore an engineering port requiring actual dependency builds,
rather than an officially validated substitute for the Linux recipe.

## Confirmed findings in the pinned source

| Area | Evidence | Consequence |
| --- | --- | --- |
| NDK host detection | `android/deps/vars.sh:20` and `android/deps/Makefile:22` derive the host from `uname`. An actual Git Bash probe returned `MSYS_NT-10.0-19045` and computed `msys_nt-10.0-19045-x86_64`. | This directory does not identify the Windows NDK host. Set and validate `HOST_PLATFORM=windows-x86_64`; distinguish this build host from Android's target triple. |
| Compiler commands | `Makefile:62` and `meson-arm64-v8a.txt:2` use the API-prefixed Clang entry points. | Validate the Windows entry points and argument forwarding; use `clang.exe --target=aarch64-linux-android21` where possible, with matching C++ and LLVM tools. |
| CMake generator | `android/deps/Makefile:127` chooses `Unix Makefiles` and then invokes `$(MAKE)`. | A Windows CMake installation needs a compatible generator/build tool pairing. CMake documents `MSYS Makefiles` for MSYS make and `/bin/sh`; MSYS2 recommends explicitly choosing a generator. Changing to Ninja also requires changing the subsequent build invocation. |
| POSIX prerequisites | Existing Git Bash has coreutils and Perl, but the actual inventory found no Make, Autoconf, Automake, CMake, Ninja, Meson, pkg-config, GCC, or wget on its adjusted shell PATH. | Git for Windows alone is insufficient. Its `bash.exe` is also distinct from `C:\Windows\System32\bash.exe`, which is a WSL entry point. |
| Ruby bootstrap | `get_deps.sh:118` selects upstream Ruby `v3_4_10` plus the checked-in compatibility patch. `Makefile:326` runs `autoreconf -i`. | A Git checkout needs Autoconf and an executable build-host Ruby; downloading the Android NDK does not supply them. |
| Source archive context | `get_deps.sh:119` locates the Ruby patch using `git rev-parse --show-toplevel`. The current verified source export has no `.git`; an actual invocation from its `android/deps` returned the enclosing KIF repository root, whose expected patch path does not exist. The patch does exist in the export. | Use a genuine runtime checkout or resolve the patch relative to the script location when building a source archive. Do not run the unmodified downloader from this export and assume the correct patch was applied. |
| OpenSSL environment | `Makefile:306` invokes OpenSSL's Android `Configure`. OpenSSL 3.0.12 checks `ANDROID_NDK_ROOT` or `ANDROID_NDK`; it does not check `ANDROID_NDK_HOME` in that code. | The documented `ANDROID_NDK_HOME=...` command alone is insufficient for this dependency unless an additional variable is inherited. Set a consistent alias within the build process. |
| Path boundaries | Make builds prefixes from POSIX `PWD`, while native Windows Clang, CMake, Python/Meson and pkg-config can use Windows paths. | Keep explicit POSIX and Windows spellings where required and inspect generated `.pc`/CMake files; prevent host libraries from entering target link flags. |
| Reproducibility | Several top-level and nested dependency fetches use mutable heads, already recorded in `runtime-research.md`. | Lock every source and helper download before accepting a complete source build. A successful Windows compiler probe does not repair this. |

The source references above are from the local export verified against the exact
Git commit. The publisher's [Android README at that commit](https://codeberg.org/warmwinter/mkxp-z/src/commit/68653811c3c396f2d4c12225c52c407746285a3d/android/README.md)
describes the POSIX shell/Make/Meson workflow and does not claim a Windows host
validation.

## Host Ruby is available

The already extracted portable Ruby is **3.2.9, x64-mingw-ucrt**. It was actually
run from Git Bash with `--disable=gems -rerb -rfileutils -rtempfile`; all three
libraries loaded successfully. Ruby 3.4.10's
[build instructions](https://github.com/ruby/ruby/blob/v3_4_10/doc/contributing/building_ruby.md)
require host Ruby 3.0 or later for a Git checkout. Its
[`configure.ac`](https://github.com/ruby/ruby/blob/v3_4_10/configure.ac)
requires an executable host Ruby for cross-compilation and accepts
`--with-baseruby`. Thus the available host Ruby meets the stated bootstrap
version requirement. That is not proof that all cross-generated files and
extensions work with it; an actual Ruby configure/build remains a separate gate.

## Portable inputs for the executable checks

| Input | Pin and integrity evidence |
| --- | --- |
| MSYS2 base | Official `2026-09-27` release, `msys2-base-x86_64-20260927.tar.xz`, SHA-256 `ea2f31a0b6ade63914ce441ffb022f0f6aa96982bfefa2326460a26d5fb01322`. Archive downloaded and verified, extracted beneath `temp/tools/msys64`. |
| GNU Make | Official MSYS2 `make-4.4.1-3-x86_64.pkg.tar.zst`, SHA-256 `af0bdba17f06fe037f0194069adaa31a8fe45f1a11381501896aea1fae37bd5d`. Downloaded from `repo.msys2.org`; the first official mirror had a certificate-revocation-server access failure. Certificate verification was not disabled. |
| GNU diffutils | Official MSYS2 `diffutils-3.12-1-x86_64.pkg.tar.zst`, SHA-256 `7902c8ce3d4dd69a0f5e98dc9d5c83c17b23314ba486169db57ef6e2835ce3b6`. The base archive lacked `cmp`; configure used a fallback and still completed, then this package was added and `cmp --version` verified. |
| Windows NDK | r25c (`25.2.9519653`), `android-ndk-r25c-windows.zip`. Official SHA-1 `18c4a3cd108916f553b1bedad2672f2c6cd85a10` verified; recorded SHA-256 `f70093964f6cbbe19268f9876a20f92d3a593db3ad2037baadd25fd8d71e84e2`. Extracted beneath `temp/tools/android-ndk-r25c`. This is a minimal compatibility investigation matching the runtime's r25+ requirement, not the final modern Android toolchain choice. |
| libiconv | GNU libiconv 1.18 archive SHA-256 `3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8`, verified in the dependency-lock investigation. A separate extracted copy is used under the verification checkout's `temp/native-windows`; source caches and the running app are untouched. |

MSYS2's [official CI instructions](https://www.msys2.org/docs/ci/) support
self-contained archive extraction. Its [symlink documentation](https://www.msys2.org/docs/symlinks/)
explains that the default mode copies existing targets for readability by native
Windows programs. No Developer Mode change is needed merely to obtain that
behavior; validate generated library names and copied targets after installation.

## Executable minimum gates

`scripts/android/probe-windows-native.ps1` provides the checks. From this
verification checkout, after the pinned tools have been extracted:

```powershell
& ./scripts/android/probe-windows-native.ps1 `
  -NdkRoot D:/others/kurayshinyrevamp/temp/tools/android-ndk-r25c `
  -MsysRoot D:/others/kurayshinyrevamp/temp/tools/msys64 `
  -LibiconvSource ./temp/native-windows/libiconv-1.18
```

The script writes exclusively beneath this checkout's `temp/native-windows-proof`
and performs these progressively stronger checks:

1. Compile a C translation unit, including NDK system headers, into ARM64 and
   x86_64 ELF objects with the Windows `clang.exe` and explicit Android targets.
2. Link an ARM64 shared object and inspect its ELF machine, Android note and load
   segment alignment using the same NDK's `llvm-readelf.exe`. The explicit 16 KiB
   linker flag tests flag propagation only; it does not establish whole-app
   16 KiB compatibility or repair the r25c C++ runtime.
3. Use portable MSYS2 and GNU Make to run libiconv's generated Autoconf script,
   cross-build and install the shared library, then inspect that library as ELF.
   This gate disables NLS to isolate the compiler/libtool path from gettext
   tooling; it is not the unchanged full dependency recipe.

Actual compiler results: Windows Clang 14.0.7 (NDK build 9352603) generated valid
ELF64 AArch64 and x86-64 relocatable objects. The ARM64 shared-library link also
completed, contains an Android API-21/NDK-r25c note, and all three `PT_LOAD`
segments have alignment `0x4000`. Logs and objects are beneath
`temp/native-windows-proof`.

The Windows r25c archive actually contains **both** extensionless POSIX shell
wrappers and `.cmd` wrappers. The actual extensionless
`aarch64-linux-android21-clang` wrapper was executed in portable MSYS2 and also
produced a valid AArch64 ELF object (`elf-arm64-wrapper.log`). Compiler wrapper
availability is therefore **not a demonstrated r25c/MSYS2 blocker**. Native
Clang with explicit `--target` remains the directly tested alternative.

The first libiconv configure attempt failed before invoking the compiler:
Autoconf treated `D:/.../build-aux` as a colon-separated candidate list and
reported all auxiliary files missing. Those files existed. Source/build paths
are now converted with `cygpath -u`, while the compiler uses its native Windows
path. The first failure logs are preserved as
`libiconv-configure-attempt1.log` and `libiconv-config-attempt1.log`.

The second libiconv attempt completed **configure, make and make install with
exit code 0**, including its nested libcharset configuration. The successful
whole probe ran from 17:28:19 to 17:34:59 China time, approximately **400.2 s**,
excluding tool download/extraction. The installed library is ELF64 AArch64,
SONAME `libiconv.so`, with `libdl.so` and `libc.so` dependencies and four
`PT_LOAD` segments aligned to `0x4000`. Its recorded SHA-256 is
`0668a64b71807ba7e9914f008f348aad44c397b75308064f220247465c3f8f1d`.
This is an actual cross-built dependency; it was not substituted into the APK
or claimed to have passed an Android load/function test.

Evidence under `temp/native-windows-proof` includes `run-attempt2.log`,
`libiconv-build/configure.stdout.log`, `make.stdout.log`, `install.stdout.log`,
`elf-libiconv.log`, and the installed `libiconv-install/lib/libiconv.so`.
The first configure logs are retained alongside the successful logs.
No complete `libmkxp-z.so`, Ruby, OpenSSL, SDL or full dependency source rebuild
has been performed here.

## Remaining source-build acceptance gates

After a successful minimum dependency check, configure and build the patched
Ruby source independently, then OpenSSL and the mixed CMake/Meson dependencies.
Only then attempt the engine, compare required exports/DT_NEEDED libraries,
package the rebuilt set and rerun the Android runtime probe and game checks.
Use a current, fixed NDK and check **every** shared library's alignment before
claiming modern 16 KiB-device support. Keep the working prebuilt-runtime APK
available while developing this source pipeline.

Additional primary references:

- [NDK build-system maintainer guide](https://android.googlesource.com/platform/ndk/+/ndk-r25-release/docs/BuildSystemMaintainers.md)
- [CMake MSYS Makefiles generator](https://cmake.org/cmake/help/latest/generator/MSYS%20Makefiles.html)
- [MSYS2 CMake generator guidance](https://www.msys2.org/docs/cmake/)
- [MSYS2 argument and environment path conversion](https://www.msys2.org/docs/filesystem-paths/)
- [OpenSSL 3.0.12 Android target configuration](https://github.com/openssl/openssl/blob/openssl-3.0.12/Configurations/15-android.conf)
