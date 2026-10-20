import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('native_core', root / 'scripts/android/windows_native_core.py')
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
args = SimpleNamespace(source=root / 'temp/windows-native/sources/mkxp-z',
    ndk=root / 'temp/tools/android-ndk-r25c', prefix=root / 'temp/windows-native/prefix/arm64-v8a',
    output=root / 'temp/windows-native-core')
_, output, _, _, tools, env, record = core.prepare(args)
source = output / 'toolchain-probe-source'
build = output / 'toolchain-probe-build'
source.mkdir(exist_ok=True)
(source / 'meson.build').write_text('''project('kif-windows-meson-toolchain-probe', 'cpp')
assert(host_machine.system() == 'android')
assert(host_machine.cpu_family() == 'aarch64')
generator = find_program('xxd-include.sh', native: true)
embedded = custom_target('fixture', input: 'fixture.txt', output: 'fixture.xxd', command: [generator, '___fixture', '@INPUT@'], capture: true)
shared_library('kif_meson_toolchain_probe', ['probe.cpp', embedded], include_directories: include_directories('.'), install: false)
''', encoding='utf-8')
(source / 'fixture.txt').write_bytes(b'Windows portable Meson / Android ARM64\x00\x01\xff')
(source / 'probe.cpp').write_text('''#include <string>
#include "fixture.xxd"
#ifndef __aarch64__
#error Expected Android ARM64 target
#endif
static_assert(__ANDROID_API__ == 30, "Expected API 30");
extern "C" int kif_meson_toolchain_probe(const char* value) {
  std::string text(value);
  text.append(reinterpret_cast<const char*>(___fixture), ___fixture_len);
  return static_cast<int>(text.size());
}
''', encoding='utf-8')
command = [tools['python'], '-B', tools['mesonEntry']]
setup = command + ['setup', str(build), str(source), '--native-file', record['nativeFile'], '--cross-file', record['crossFile'], '--wrap-mode=nofallback']
if (build / 'meson-private/coredata.dat').exists():
    setup.append('--reconfigure')
core.run(setup, output / 'toolchain-probe-configure.log', env=env, cwd=source)
core.run(command + ['compile', '-C', str(build), '-j', '1'], output / 'toolchain-probe-compile.log', env=env, cwd=source)
artifact = build / 'libkif_meson_toolchain_probe.so'
readelf = args.ndk / 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe'
metadata = subprocess.check_output([str(readelf), '-h', '-lW', '-d', str(artifact)], text=True)
(output / 'toolchain-probe-elf.txt').write_text(metadata, encoding='utf-8')
loads = [line for line in metadata.splitlines() if line.strip().startswith('LOAD')]
assert 'AArch64' in metadata and loads and all(line.rstrip().endswith('0x4000') for line in loads)
assert 'Shared library: [libc++_shared.so]' in metadata
assert '(RUNPATH)' not in metadata and '(RPATH)' not in metadata
result = dict(status='pass; toolchain only, no engine or Android execution',
    bytes=artifact.stat().st_size, sha256=core.sha(artifact), arm64=True, api=30, loadAlignment=16384,
    usesNdkSharedCxx=True, nativePythonCodegen=True, targetExecuted=False)
core.write_json(output / 'toolchain-probe-result.json', result)
print(json.dumps(result, indent=2), flush=True)
