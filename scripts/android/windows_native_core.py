"""Prepare/build the fixed Android mkxp-z core using native Windows Meson.

No APK, emulator or game save is changed. Missing source-built dependencies are
reported together. Host codegen is overridden through a Meson native file;
upstream target sources remain untouched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TEMP = ROOT / 'temp'
SCRIPT = Path(__file__).resolve()
REQUIRED_PC = ('physfs', 'openal', 'theora', 'vorbisfile', 'vorbis', 'ogg', 'sdl2',
               'SDL2_ttf', 'freetype2', 'pixman-1', 'libpng', 'uchardet', 'SDL2_image', 'ruby-3.4')
REQUIRED_LIBS = ('libphysfs.so', 'libopenal.so', 'libtheora.so', 'libtheoradec.so',
                 'libvorbisfile.so', 'libvorbis.so', 'libogg.so', 'libSDL2.so',
                 'libSDL2_sound.so', 'libSDL2_ttf.so', 'libfreetype.so',
                 'libpixman-1.so', 'libpng16.so', 'libuchardet.so',
                 'libSDL2_image.so', 'libiconv.so', 'libruby.so', 'libssl.so', 'libcrypto.so')


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def quoted(value):
    # Machine-file strings use forward slashes; reject control characters.
    value = str(value).replace('\\', '/')
    if any(ord(char) < 32 for char in value):
        raise ValueError('Control character in machine-file value')
    return "'" + value.replace("'", "\\'") + "'"


def array(values):
    return '[' + ', '.join(quoted(value) for value in values) + ']'


def output_path(path):
    path = Path(path).resolve()
    if not path.is_relative_to(TEMP.resolve()) or path == TEMP.resolve():
        raise ValueError(f'Output must be below this worktree temp: {path}')
    path.mkdir(parents=True, exist_ok=True)
    return path


def run(command, log, *, env=None, cwd=None):
    with Path(log).open('w', encoding='utf-8', newline='\n') as stream:
        result = subprocess.run([str(value) for value in command], stdout=stream, stderr=subprocess.STDOUT,
                                env=env, cwd=cwd, text=True)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}); see {log}')


def prepare(args):
    lock = read_json(SCRIPT.with_name('windows-native-core.lock.json'))
    dependency_lock = read_json(SCRIPT.with_name('windows-native-lock.json'))
    tools = read_json(TEMP / 'core-tools/environment.json')
    source = args.source.resolve()
    if not (source / '.git').exists():
        raise ValueError('Use a dedicated Git checkout of the fixed runtime; archive exports can report the outer KIF commit')
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != lock['runtime']['commit']:
        raise ValueError(f'Runtime source commit differs from lock: {commit}')
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=all'], text=True).strip():
        raise ValueError('Dedicated runtime checkout must be clean')
    ndk = args.ndk.resolve()
    properties = (ndk / 'source.properties').read_text(encoding='utf-8')
    if not re.search(r'Pkg.Revision\s*=\s*' + re.escape(dependency_lock['ndkRevision']) + r'\s*$', properties, re.M):
        raise ValueError('NDK revision differs from lock')
    prefix = args.prefix.resolve()
    toolchain = ndk / 'toolchains/llvm/prebuilt/windows-x86_64'
    output = output_path(args.output)
    build = output / 'build'
    build.mkdir(exist_ok=True)
    native = output / 'native-windows.ini'
    cross = output / 'android-arm64-api30.ini'
    codegen = SCRIPT.with_name('windows_native_codegen.py')
    python = Path(tools['python'])
    cmake = TEMP / 'tools' / dependency_lock['hostTools']['cmake']['directory'] / 'bin/cmake.exe'
    pkgconf = Path(tools['pkgconf'])
    ninja = Path(tools['ninja'])
    for program in (python, Path(tools['mesonEntry']), pkgconf, ninja, cmake, toolchain / 'bin/clang.exe', toolchain / 'bin/clang++.exe'):
        if not program.is_file():
            raise ValueError(f'Missing portable tool: {program}')
    if sha(pkgconf) != tools['pkgconfExecutableSha256']:
        raise ValueError('pkgconf executable differs from prepared environment')
    native.write_text('[binaries]\n' +
                      'xxd = ' + array([python, '-B', codegen, '--xxd']) + '\n' +
                      'xxd-include.sh = ' + array([python, '-B', codegen, '--include']) + '\n' +
                      'cmake = ' + quoted(cmake) + '\n' +
                      'ninja = ' + quoted(ninja) + '\n', encoding='utf-8', newline='\n')
    compile_args = ['--sysroot=' + (toolchain / 'sysroot').as_posix(), '-I' + (prefix / 'include').as_posix()]
    link_args = ['-L' + (prefix / 'lib').as_posix(), '-Wl,-z,max-page-size=16384', '-Wl,-z,common-page-size=16384']
    contents = '[binaries]\n'
    for name, filename in (('c', 'clang.exe'), ('cpp', 'clang++.exe')):
        contents += name + ' = ' + array([toolchain / 'bin' / filename, '--target=aarch64-linux-android30']) + '\n'
    contents += 'ar = ' + quoted(toolchain / 'bin/llvm-ar.exe') + '\n'
    contents += 'strip = ' + quoted(toolchain / 'bin/llvm-strip.exe') + '\n'
    contents += 'pkg-config = ' + quoted(pkgconf) + '\n'
    contents += "\n[host_machine]\nsystem = 'android'\ncpu_family = 'aarch64'\ncpu = 'armv8-a'\nendian = 'little'\n"
    contents += '\n[properties]\nneeds_exe_wrapper = true\npkg_config_libdir = ' + array([prefix / 'lib/pkgconfig']) + '\n'
    contents += "\n[built-in options]\ncpp_std = 'c++14'\nbuildtype = 'release'\npkg_config_path = []\n"
    contents += 'c_args = ' + array(compile_args) + '\ncpp_args = ' + array(compile_args + ['-stdlib=libc++']) + '\n'
    contents += 'c_link_args = ' + array(link_args) + '\ncpp_link_args = ' + array(link_args + ['-stdlib=libc++', '-lc++_shared']) + '\n'
    contents += '\n[cmake]\nCMAKE_ANDROID_NDK = ' + quoted(ndk) + '\n'
    contents += "CMAKE_SYSTEM_VERSION = '30'\nCMAKE_ANDROID_ARCH_ABI = 'arm64-v8a'\nCMAKE_ANDROID_STL_TYPE = 'c++_shared'\n"
    contents += 'CMAKE_FIND_ROOT_PATH = ' + quoted(prefix) + '\nCMAKE_PREFIX_PATH = ' + quoted(prefix) + '\n'
    contents += "CMAKE_FIND_ROOT_PATH_MODE_LIBRARY = 'ONLY'\nCMAKE_FIND_ROOT_PATH_MODE_INCLUDE = 'ONLY'\nCMAKE_FIND_ROOT_PATH_MODE_PACKAGE = 'ONLY'\n"
    cross.write_text(contents, encoding='utf-8', newline='\n')
    env = dict(os.environ)
    for name in ('CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'PKG_CONFIG_SYSROOT_DIR', 'PKG_CONFIG_PATH'):
        env.pop(name, None)
    env.update(PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'), PKG_CONFIG_PATH='',
               PYTHONDONTWRITEBYTECODE='1', ANDROID_NDK_HOME=str(ndk), ANDROID_NDK_ROOT=str(ndk),
               PATH=os.pathsep.join([str(ninja.parent), str(cmake.parent), str(toolchain / 'bin'), env['PATH']]))
    missing = []
    packages = {}
    for name in REQUIRED_PC:
        result = subprocess.run([str(pkgconf), '--modversion', name], env=env, text=True, capture_output=True)
        if result.returncode:
            missing.append('pkg-config:' + name)
        else:
            packages[name] = result.stdout.strip()
    for name in REQUIRED_LIBS:
        if not (prefix / 'lib' / name).is_file():
            missing.append(name)
    fingerprint_data = dict(commit=commit, native=sha(native), cross=sha(cross), codegen=sha(codegen),
                            ndk=dependency_lock['ndkRevision'], meson=tools['mesonArchiveSha256'],
                            pkgconf=tools['pkgconfArchiveSha256'])
    fingerprint = hashlib.sha256(json.dumps(fingerprint_data, sort_keys=True).encode()).hexdigest()
    stamp = build / '.kif-core-machine.json'
    if stamp.exists() and read_json(stamp)['fingerprint'] != fingerprint:
        raise ValueError('Machine configuration changed; select a new --output below temp rather than reusing a different toolchain')
    write_json(stamp, dict(fingerprint=fingerprint, inputs=fingerprint_data))
    record = dict(status='prepared', source=str(source), runtimeCommit=commit, sourceClean=True,
                  buildDirectory=str(build), prefix=str(prefix), nativeFile=str(native), crossFile=str(cross),
                  fingerprint=fingerprint, packages=packages, missingDependencies=missing,
                  abi='arm64-v8a', api=30, targetExecuted=False, coreBuilt=False, fullRuntimeBuilt=False,
                  tools=tools, inputSources={str(path.relative_to(ROOT)): sha(path) for path in
                      (SCRIPT, codegen, SCRIPT.with_name('windows-native-core.lock.json'))})
    write_json(output / 'preparation.json', record)
    return source, output, build, prefix, tools, env, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=('prepare', 'configure', 'build'), default='prepare')
    parser.add_argument('--source', type=Path, default=TEMP / 'windows-native/sources/mkxp-z')
    parser.add_argument('--prefix', type=Path, default=TEMP / 'windows-native/prefix/arm64-v8a')
    parser.add_argument('--ndk', type=Path, default=TEMP / 'tools/android-ndk-r25c')
    parser.add_argument('--output', type=Path, default=TEMP / 'windows-native-core')
    parser.add_argument('--jobs', type=int, default=1, choices=range(1, 17))
    args = parser.parse_args()
    source, output, build, prefix, tools, env, record = prepare(args)
    print(json.dumps({key: record[key] for key in ('status', 'runtimeCommit', 'packages', 'missingDependencies')}, indent=2), flush=True)
    if args.stage == 'prepare':
        return
    if record['missingDependencies']:
        raise RuntimeError('Build the listed fixed Android dependencies before core configuration; no target binary was executed')
    ruby_validation = read_json(TEMP / 'windows-native/ruby-module-validation.json')
    if ruby_validation.get('runtimeSearchPath') != 'none' or ruby_validation.get('sha256') != sha(prefix / 'lib/libruby.so'):
        raise RuntimeError('Installed Ruby must match its completed, no-RUNPATH component validation')
    if '-rpath' in (prefix / 'lib/pkgconfig/ruby-3.4.pc').read_text(encoding='utf-8'):
        raise RuntimeError('Ruby pkg-config metadata still contains a build-host runtime path')
    record['nativeInputSha256'] = {name: sha(prefix / 'lib' / name) for name in REQUIRED_LIBS}
    record['pkgConfigSha256'] = {path.name: sha(path) for path in sorted((prefix / 'lib/pkgconfig').glob('*.pc'))}
    command = [tools['python'], '-B', tools['mesonEntry']]
    setup = command + ['setup', str(build), str(source), '--native-file', record['nativeFile'],
                       '--cross-file', record['crossFile'], '--wrap-mode=nofallback',
                       '-Dmri_version=3.4', '-Dshared_fluid=false', '-Dgfx_backend=gles',
                       '-Dstatic_executable=false', '-Duse_miniffi=true', '-Denable-https=true']
    if (build / 'meson-private/coredata.dat').exists():
        setup.append('--reconfigure')
    run(setup, output / 'configure.log', env=env, cwd=source)
    record['status'] = 'configured; core compilation pending'
    write_json(output / 'build-result.json', record)
    if args.stage == 'configure':
        return
    run(command + ['compile', '-C', str(build), '-j', str(args.jobs)], output / 'compile.log', env=env, cwd=source)
    core = build / 'libmkxp-z.so'
    if not core.is_file():
        raise RuntimeError('Meson completed without the expected core library')
    readelf = args.ndk.resolve() / 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
    metadata = subprocess.check_output([str(readelf), '-h', '-lW', '-d', str(core)], text=True)
    (output / 'core-elf.txt').write_text(metadata, encoding='utf-8')
    if 'AArch64' not in metadata or 'Library soname: [libmkxp-z.so]' not in metadata:
        raise RuntimeError('Unexpected core architecture/SONAME')
    loads = [line for line in metadata.splitlines() if line.strip().startswith('LOAD')]
    if not loads or any(not line.rstrip().endswith('0x4000') for line in loads):
        raise RuntimeError('Core PT_LOAD alignment is not 16 KiB')
    if '(RPATH)' in metadata or '(RUNPATH)' in metadata:
        raise RuntimeError('Core must not carry a build-host runtime search path')
    for name, digest in record['nativeInputSha256'].items():
        if sha(prefix / 'lib' / name) != digest:
            raise RuntimeError(f'Native dependency changed during core build: {name}')
    for name, digest in record['pkgConfigSha256'].items():
        if sha(prefix / 'lib/pkgconfig' / name) != digest:
            raise RuntimeError(f'pkg-config input changed during core build: {name}')
    if subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != record['runtimeCommit'] or subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=all'], text=True).strip():
        raise RuntimeError('Dedicated upstream source changed during core build')
    for relative, digest in record['inputSources'].items():
        if sha(ROOT / relative) != digest:
            raise RuntimeError(f'Core build helper changed during build: {relative}')
    record.update(status='core compiled; dependency-closure audit and Android execution pending', coreBuilt=True, fullRuntimeBuilt=False,
                  core=dict(path=str(core), bytes=core.stat().st_size, sha256=sha(core)),
                  allDependenciesFromSourceNotYetAudited=True, targetExecuted=False)
    write_json(output / 'build-result.json', record)
    print(f'Built {core}; device and full dependency-closure validation remain separate', flush=True)


if __name__ == '__main__':
    main()
