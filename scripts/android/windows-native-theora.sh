#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:$PATH"
source_directory="$(cygpath -u "$1")"
output_directory="$(cygpath -u "$2")"
ndk="$(cygpath -m "$3")"
pkgconf="$(cygpath -m "$4")"
stage="$5"
jobs="$6"
export AUTOCONF=autoconf-2.72 AUTOHEADER=autoheader-2.72 AUTOM4TE=autom4te-2.72
export ACLOCAL=aclocal-1.18 AUTOMAKE=automake-1.18 LIBTOOLIZE=libtoolize
export ACLOCAL_PATH="$(cygpath -u "$(dirname "$pkgconf")/../share/aclocal")"
prefix="$output_directory/prefix/arm64-v8a"
prefix_native="$(cygpath -m "$prefix")"
compiler_directory="$ndk/toolchains/llvm/prebuilt/windows-x86_64/bin"
export CC="$compiler_directory/clang.exe --target=aarch64-linux-android30"
export CXX="$compiler_directory/clang++.exe --target=aarch64-linux-android30"
export AR="$compiler_directory/llvm-ar.exe" NM="$compiler_directory/llvm-nm.exe"
export RANLIB="$compiler_directory/llvm-ranlib.exe" STRIP="$compiler_directory/llvm-strip.exe"
export CFLAGS='-O2 -fPIC'
export CPPFLAGS="-I$prefix_native/include"
export LDFLAGS="-L$prefix_native/lib -Wl,-z,max-page-size=16384"
export PKG_CONFIG="$pkgconf" PKG_CONFIG_LIBDIR="$prefix_native/lib/pkgconfig" PKG_CONFIG_PATH=''
mkdir -p "$output_directory/logs" "$output_directory/build/libtheora"
if [[ "$stage" != ResumeBuild ]]; then
  (cd "$source_directory" && autoreconf-2.72 -isf) > "$output_directory/logs/libtheora-bootstrap.log" 2>&1
  printf 'Theora official Autotools bootstrap completed.\n'
fi
if [[ "$stage" == Prepare ]]; then exit 0; fi
cd "$output_directory/build/libtheora"
if [[ "$stage" != ResumeBuild ]]; then
  "$source_directory/configure" --host=aarch64-linux-android --prefix="$prefix" \
    --enable-shared --disable-static --disable-examples --disable-doc --disable-spec --disable-asm \
    > "$output_directory/logs/libtheora-configure.log" 2>&1
fi
make -j"$jobs" > "$output_directory/logs/libtheora-build.log" 2>&1
make -j"$jobs" install > "$output_directory/logs/libtheora-install.log" 2>&1
printf 'Theora make/install completed.\n'
