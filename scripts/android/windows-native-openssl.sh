#!/usr/bin/env bash
set -euo pipefail
# Called from windows-native-build.ps1; all mutations stay below its temp root.
export PATH="/usr/bin:/bin:$PATH"
source_directory="$(cygpath -u "$1")"
ndk="$(cygpath -u "$2")"
output_directory="$(cygpath -u "$3")"
jobs="$4"
compiler_directory="$ndk/toolchains/llvm/prebuilt/windows-x86_64/bin"
export PATH="$compiler_directory:/usr/bin:/bin:$PATH"
# OpenSSL 3.0 does not read ANDROID_NDK_HOME. Consistent POSIX paths are also
# required by its which(clang) comparison against ANDROID_NDK_ROOT.
export ANDROID_NDK_ROOT="$ndk"
export ANDROID_NDK="$ndk"
export CC=clang
export AR=llvm-ar
export RANLIB=llvm-ranlib
mkdir -p "$output_directory/build/openssl" "$output_directory/prefix/arm64-v8a" "$output_directory/logs"
cd "$output_directory/build/openssl"
printf 'Host: '; uname -a
printf 'Perl: '; perl -e 'printf "%vd\n", $^V'
printf 'Compiler: '; command -v clang
perl "$source_directory/Configure" android-arm64 shared no-tests \
  -D__ANDROID_API__=30 -O2 -fPIC -Wl,-z,max-page-size=16384 \
  --prefix="$output_directory/prefix/arm64-v8a" \
  --openssldir="$output_directory/prefix/arm64-v8a/ssl" \
  > "$output_directory/logs/openssl-configure.log" 2>&1
make -j"$jobs" build_libs > "$output_directory/logs/openssl-build.log" 2>&1
make install_dev > "$output_directory/logs/openssl-install.log" 2>&1
printf 'OpenSSL configure/build_libs/install_dev completed.\n'
