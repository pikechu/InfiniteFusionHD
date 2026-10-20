#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:$PATH"
source_directory="$(cygpath -u "$1")"
ndk="$(cygpath -m "$2")"
output_directory="$(cygpath -u "$3")"
host_ruby="$(cygpath -m "$4")"
stage="$5"
jobs="$6"
compiler_directory="$ndk/toolchains/llvm/prebuilt/windows-x86_64/bin"
export CC="$compiler_directory/clang.exe --target=aarch64-linux-android30"
export CXX="$compiler_directory/clang++.exe --target=aarch64-linux-android30"
export AR="$compiler_directory/llvm-ar.exe"
export NM="$compiler_directory/llvm-nm.exe"
export RANLIB="$compiler_directory/llvm-ranlib.exe"
export STRIP="$compiler_directory/llvm-strip.exe"
export OBJCOPY="$compiler_directory/llvm-objcopy.exe"
export OBJDUMP="$compiler_directory/llvm-objdump.exe"
export LD="$compiler_directory/ld.lld.exe"
prefix="$output_directory/prefix/arm64-v8a"
prefix_native="$(cygpath -m "$prefix")"
export CFLAGS='-O2 -fPIC'
# Native host Ruby later reads these values directly in mkmf/rbinstall; /d/...
# would resolve as D:/d/... there. Keep POSIX paths only for shell file commands.
export CPPFLAGS="-I$prefix_native/include"
export LDFLAGS="-L$prefix_native/lib -Wl,-z,max-page-size=16384"
export DLDFLAGS='-Wl,-soname,libruby.so -Wl,-z,max-page-size=16384'
export PKG_CONFIG_LIBDIR="$prefix_native/lib/pkgconfig"
mkdir -p "$output_directory/build/ruby" "$prefix" "$output_directory/logs"
cd "$output_directory/build/ruby"
build_triple="$(sh "$source_directory/tool/config.guess")"
printf 'Host Ruby: '; "$host_ruby" --disable-gems --version
printf 'Build triple: %s\n' "$build_triple"
if [[ "$stage" != ResumeBuild ]]; then
  "$source_directory/configure" --build="$build_triple" --host=aarch64-linux-android \
    --prefix="$prefix_native" --with-baseruby="$host_ruby" --enable-shared \
    --disable-install-doc --disable-rubygems --disable-yjit --disable-rjit \
    --without-gmp --with-static-linked-ext --with-ext=openssl,socket,zlib,+ \
    --with-out-ext=readline,dbm,gdbm,win32,win32ole,fiddle \
    --with-openssl-dir="$prefix_native" \
    > "$output_directory/logs/ruby-configure.log" 2>&1
  printf 'Ruby configure completed.\n'
fi
if [[ "$stage" == Build || "$stage" == ResumeBuild ]]; then
  # Ruby appends its own SONAME after user DLDFLAGS. Set the generated variable
  # too, so the final linker flag and RbConfig agree with Android's library name.
  sed -i 's/^LIBRUBY_SONAME[[:blank:]]*=.*/LIBRUBY_SONAME= libruby.so/' Makefile
  make -j"$jobs" > "$output_directory/logs/ruby-build.log" 2>&1
  make install > "$output_directory/logs/ruby-install.log" 2>&1
  # Match the fixed runtime's recipe: its SONAME override belongs to libruby,
  # and must not leak through pkg-config into libmkxp-z's own link command.
  ruby_pc="$prefix/lib/pkgconfig/ruby-3.4.pc"
  test -f "$ruby_pc"
  sed -i 's/^DLDFLAGS=.*/DLDFLAGS=/' "$ruby_pc"
  if grep -q -- '-soname' "$ruby_pc"; then
    printf 'Unexpected SONAME flag remains in Ruby pkg-config metadata.\n' >&2
    exit 1
  fi
  printf 'Ruby make/install completed.\n'
fi
