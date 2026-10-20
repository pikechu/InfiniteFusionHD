"""Host-only regressions for portable Meson caches and core build isolation.

All fixtures live below this worktree's temp directory. These tests never run
an Android binary, configure the engine, access an emulator, or use the network.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts/android'
sys.dont_write_bytecode = True
saved_import_path = sys.path[:]
try:
    sys.path.insert(0, str(SCRIPTS))
    spec = importlib.util.spec_from_file_location('core_guards_under_test', SCRIPTS / 'windows_native_core.py')
    core = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(core)
    from windows_native_tool_cache import MESON_ENTRY, verify_meson
finally:
    sys.path[:] = saved_import_path


class CoreGuardTests(unittest.TestCase):
    def setUp(self):
        parent = ROOT / 'temp/host-checks'
        parent.mkdir(parents=True, exist_ok=True)
        self.approved_parent = parent.resolve()
        self.base = self.approved_parent / ('windows-native-core-' + uuid.uuid4().hex)
        # Inherit the workspace ACL: TemporaryDirectory's mode=0700 can exclude
        # the restricted Windows process token used by this workspace.
        self.base.mkdir()
        self.junctions = []

    def tearDown(self):
        # Remove only test-owned junctions, without traversing their targets.
        for path in reversed(self.junctions):
            self.assertTrue(path.parent.resolve().is_relative_to(self.base.resolve()))
            self.assertTrue(getattr(path.lstat(), 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)
            path.rmdir()
        # Check the resolved absolute target before recursive cleanup.
        self.assertEqual(self.base.resolve().parent, self.approved_parent)
        self.assertTrue(self.base.name.startswith('windows-native-core-'))
        shutil.rmtree(self.base)

    def wheel_fixture(self):
        archive = self.base / 'meson-fixture.whl'
        directory = self.base / 'meson-cache'
        files = {
            'mesonbuild/__init__.py': b'',
            'mesonbuild/coredata.py': b"version = '1.9.1'\n",
            'mesonbuild/mesonmain.py': (
                b'import sys\nfrom .coredata import version\n\n'
                b'def main():\n'
                b"    if sys.argv[1:] == ['--version']:\n"
                b'        print(version)\n        return 0\n'
                b'    return 0\n'),
        }
        with zipfile.ZipFile(archive, 'w') as wheel:
            for name, content in files.items():
                wheel.writestr(name, content)
        with zipfile.ZipFile(archive) as wheel:
            wheel.extractall(directory)
        (directory / 'meson.py').write_bytes(MESON_ENTRY)
        return archive, directory, hashlib.sha256(archive.read_bytes()).hexdigest()

    def host_command(self, command, *, env=None):
        result = subprocess.run([str(item) for item in command], env=env, cwd=self.base,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def local_tools(self):
        environment = ROOT / 'temp/core-tools/environment.json'
        if not environment.is_file():
            self.skipTest('Prepare the fixed portable Windows Meson/pkgconf tools first')
        tools = json.loads(environment.read_text(encoding='utf-8-sig'))
        for name in ('python', 'mesonEntry', 'pkgconf', 'ninja'):
            if not Path(tools[name]).is_file():
                self.skipTest(f'Prepared portable host tool is unavailable: {name}')
        return tools

    def junction(self, path, target):
        if os.name != 'nt':
            self.skipTest('This regression requires an actual Windows directory junction')
        powershell = shutil.which('powershell.exe') or shutil.which('pwsh.exe')
        if not powershell:
            self.skipTest('PowerShell is unavailable for creating a Windows junction fixture')
        self.assertTrue(path.parent.resolve().is_relative_to(self.base.resolve()))
        self.assertTrue(target.resolve().is_relative_to(self.base.resolve()))
        env = dict(os.environ, KIF_CORE_TEST_LINK=str(path), KIF_CORE_TEST_TARGET=str(target))
        result = subprocess.run(
            [powershell, '-NoProfile', '-NonInteractive', '-Command',
             "New-Item -ItemType Junction -Path $env:KIF_CORE_TEST_LINK "
             "-Target $env:KIF_CORE_TEST_TARGET -ErrorAction Stop | Out-Null"],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            self.skipTest('Windows junction creation is unavailable: ' + result.stdout.strip())
        self.assertTrue(getattr(path.lstat(), 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)
        self.junctions.append(path)
        return path

    def test_accepts_actual_extracted_wheel_bytes(self):
        archive, directory, digest = self.wheel_fixture()
        self.assertEqual(verify_meson(archive, directory, digest), 4)

    def test_rejects_modified_cache_even_when_reported_version_is_unchanged(self):
        archive, directory, digest = self.wheel_fixture()
        entry = [sys.executable, '-B', directory / 'meson.py', '--version']
        self.assertEqual(self.host_command(entry).strip(), '1.9.1')
        module = directory / 'mesonbuild/mesonmain.py'
        content = module.read_bytes()
        module.write_bytes(content.rsplit(b'    return 0\n', 1)[0] + b'    return 7\n')
        self.assertEqual(self.host_command(entry).strip(), '1.9.1')
        with self.assertRaisesRegex(ValueError, 'cache differs'):
            verify_meson(archive, directory, digest)

    def test_rejects_extra_python_module_in_extracted_cache(self):
        archive, directory, digest = self.wheel_fixture()
        (directory / 'mesonbuild/unexpected.py').write_bytes(b'CACHE_INJECTION = True\n')
        with self.assertRaisesRegex(ValueError, 'Unexpected files'):
            verify_meson(archive, directory, digest)

    def test_rejects_wheel_bytes_that_do_not_match_digest(self):
        archive, directory, digest = self.wheel_fixture()
        with archive.open('ab') as stream:
            stream.write(b'changed archive bytes')
        with self.assertRaisesRegex(ValueError, 'archive SHA256'):
            verify_meson(archive, directory, digest)

    @unittest.skipUnless(os.name == 'nt', 'Prepared tools target native Windows hosts')
    def test_real_prepare_removes_host_search_paths_without_changing_parent_environment(self):
        self.local_tools()
        args = SimpleNamespace(
            source=ROOT / 'temp/windows-native/sources/mkxp-z',
            ndk=ROOT / 'temp/tools/android-ndk-r25c',
            prefix=ROOT / 'temp/windows-native/prefix/arm64-v8a',
            output=self.base / 'real-prepare')
        if not (args.source / '.git').exists() or not (args.ndk / 'source.properties').is_file():
            self.skipTest('Fixed local runtime checkout and NDK are required for real prepare')
        inherited = (
            'CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'CPATH',
            'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH', 'LIBRARY_PATH',
            'COMPILER_PATH', 'GCC_EXEC_PREFIX', 'INCLUDE', 'LIB', 'LIBPATH',
            'CMAKE_PREFIX_PATH', 'CMAKE_TOOLCHAIN_FILE', 'PKG_CONFIG_SYSROOT_DIR')
        poison = {name: str(self.base / 'host-inputs' / name.lower()) for name in inherited}
        poison['PKG_CONFIG_PATH'] = str(self.base / 'host-pkgconfig')
        before = dict(os.environ)
        with mock.patch.dict(os.environ, poison):
            _, output, build, prefix, _, clean_env, record = core.prepare(args)
            for name in inherited:
                with self.subTest(variable=name):
                    self.assertNotIn(name, clean_env)
                    self.assertEqual(os.environ[name], poison[name])
            self.assertEqual(clean_env['PKG_CONFIG_PATH'], '')
            self.assertEqual(clean_env['PKG_CONFIG_LIBDIR'], str(prefix / 'lib/pkgconfig'))
            self.assertEqual(os.environ['PKG_CONFIG_PATH'], poison['PKG_CONFIG_PATH'])
            self.assertEqual(record['status'], 'prepared')
            self.assertFalse(record['coreBuilt'])
            self.assertFalse(record['targetExecuted'])
            self.assertFalse((build / 'meson-private/coredata.dat').exists())
            self.assertEqual(core.read_json(output / 'preparation.json')['fingerprint'], record['fingerprint'])
        self.assertEqual(dict(os.environ), before)

    def test_rejects_output_child_junction_to_another_directory(self):
        output, target = self.base / 'output', self.base / 'outside-output'
        output.mkdir()
        target.mkdir()
        sentinel = target / 'sentinel.txt'
        sentinel.write_text('do not overwrite', encoding='utf-8')
        self.junction(output / 'build', target)
        with self.assertRaisesRegex(ValueError, 'escaped|reparse|symbolic'):
            core.local_path(output, 'build')
        self.assertEqual(sentinel.read_text(encoding='utf-8'), 'do not overwrite')

    def test_rejects_junction_even_when_its_target_is_inside_output(self):
        output = self.base / 'output'
        target = output / 'real-build'
        target.mkdir(parents=True)
        self.junction(output / 'build', target)
        with self.assertRaisesRegex(ValueError, 'reparse|symbolic'):
            core.local_path(output, 'build')

    def test_rejects_nested_junction_in_existing_build(self):
        build, target = self.base / 'build', self.base / 'outside-build'
        nested = build / 'meson-private'
        nested.mkdir(parents=True)
        target.mkdir()
        sentinel = target / 'coredata.dat'
        sentinel.write_bytes(b'preserved external fixture')
        self.junction(nested / 'redirected-cache', target)
        with self.assertRaisesRegex(ValueError, 'contains a link'):
            core.reject_build_links(build)
        self.assertEqual(sentinel.read_bytes(), b'preserved external fixture')

    @unittest.skipUnless(os.name == 'nt', 'Prepared pkgconf is a native Windows executable')
    def test_fixed_meson_clearcache_refreshes_changed_pkgconfig_dependency(self):
        tools = self.local_tools()
        source, build, pkgconfig = self.base / 'source', self.base / 'build', self.base / 'pkgconfig'
        source.mkdir()
        pkgconfig.mkdir()
        (source / 'meson.build').write_text(
            "project('core-dependency-cache-regression')\n"
            "fixture = dependency('kif-core-cache-fixture', method: 'pkg-config')\n"
            "message('fixture-version=' + fixture.version())\n", encoding='utf-8')
        pc = pkgconfig / 'kif-core-cache-fixture.pc'

        def write_pc(version):
            pc.write_text('Name: KIF dependency cache fixture\n'
                          'Description: host-only fixture; no binary or library\n'
                          f'Version: {version}\nLibs:\nCflags:\n', encoding='utf-8')

        env = dict(os.environ, PKG_CONFIG=tools['pkgconf'], PKG_CONFIG_LIBDIR=str(pkgconfig),
                   PKG_CONFIG_PATH='', PYTHONDONTWRITEBYTECODE='1')
        env.pop('PKG_CONFIG_SYSROOT_DIR', None)
        env['PATH'] = str(Path(tools['ninja']).parent) + os.pathsep + env['PATH']
        command = [tools['python'], '-B', tools['mesonEntry']]
        self.assertEqual(self.host_command(command + ['--version'], env=env).strip(), '1.9.1')
        setup = command + ['setup', build, source, '--wrap-mode=nofallback']
        write_pc('1.0')
        self.assertIn('fixture-version=1.0', self.host_command(setup, env=env))
        write_pc('2.0')
        # A real reconfigure keeps the old dependency. Clearing the cache must
        # discover the changed .pc without compiling or running any binary.
        cached = self.host_command(setup + ['--reconfigure'], env=env)
        self.assertIn('fixture-version=1.0', cached)
        refreshed = self.host_command(setup + ['--reconfigure', '--clearcache'], env=env)
        self.assertIn('fixture-version=2.0', refreshed)

    def test_core_cached_configure_requests_dependency_cache_refresh(self):
        source, output, prefix = self.base / 'source', self.base / 'output', self.base / 'prefix'
        build = output / 'build'
        source.mkdir()
        (build / 'meson-private').mkdir(parents=True)
        (build / 'meson-private/coredata.dat').write_bytes(b'existing configuration fixture')
        (prefix / 'lib/pkgconfig').mkdir(parents=True)
        for name in core.REQUIRED_LIBS:
            (prefix / 'lib' / name).write_bytes(b'not an executable; command is intercepted')
        (prefix / 'lib/pkgconfig/ruby-3.4.pc').write_text('Name: Ruby fixture\n', encoding='utf-8')
        record = dict(status='prepared', runtimeCommit='fixture', packages={}, missingDependencies=[],
                      nativeFile=str(output / 'native.ini'), crossFile=str(output / 'cross.ini'))
        prepared = source, output, build, prefix, {'python': sys.executable, 'mesonEntry': 'intercepted-meson'}, {}, record
        validation_path = core.TEMP / 'windows-native/ruby-module-validation.json'
        real_read_json = core.read_json

        def read_fixture_validation(path):
            if Path(path) == validation_path:
                return dict(runtimeSearchPath='none', sha256=core.sha(prefix / 'lib/libruby.so'))
            return real_read_json(path)

        with mock.patch.object(core, 'prepare', return_value=prepared), \
                mock.patch.object(core, 'read_json', side_effect=read_fixture_validation), \
                mock.patch.object(core, 'run') as run, \
                mock.patch.object(sys, 'argv', [str(core.SCRIPT), '--stage', 'configure']), \
                contextlib.redirect_stdout(io.StringIO()):
            core.main()
        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(command[3], 'setup')
        self.assertIn('--reconfigure', command)
        self.assertIn('--clearcache', command)
        self.assertEqual(core.read_json(output / 'build-result.json')['status'], 'configured; core compilation pending')


if __name__ == '__main__':
    unittest.main()
