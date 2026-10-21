"""Real Windows junction regressions; host-only, no APK/toolchain/device work.

All real targets and fake checkout roots are inside this checkout's temp.
Fixture cleanup uses only PowerShell LiteralPath operations after explicit
absolute boundary and reparse checks; no junction target is recursively removed.
"""
from pathlib import Path
import contextlib
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import unittest
from unittest import mock
import uuid

sys.dont_write_bytecode = True
REAL_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REAL_ROOT / "scripts/android"))
import build_native_probe as probe
import build_native_full_probe as full


class OutputGuardTests(unittest.TestCase):
    junctions_created = 0

    def setUp(self):
        self.parent = REAL_ROOT / "temp/host-output-guards"
        probe.reject_reparse_ancestors(self.parent)
        self.parent.mkdir(parents=True, exist_ok=True)
        self.base = self.parent / ("junction-regression-" + uuid.uuid4().hex)
        self.base.mkdir()
        self.repo = self.base / "checkout"
        self.repo.mkdir()
        self.out = self.repo / "temp/native-probe"
        self.external = self.base / "outside-fake-checkout"
        self.external.mkdir()
        self.sentinel = self.external / "sentinel.txt"
        self.sentinel.write_bytes(b"outside target must stay intact")
        self.links = []
        self.powershell = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
        if os.name != "nt" or not self.powershell:
            self.fail("This regression requires actual Windows junctions and PowerShell; do not count a skipped/model test as a pass")

    @contextlib.contextmanager
    def configured(self, output=None, root=None):
        with mock.patch.object(probe, "ROOT", root or self.repo), \
             mock.patch.object(probe, "OUTPUT", output or self.out), \
             mock.patch.object(full, "ROOT", root or self.repo), \
             mock.patch.object(full, "OUTPUT", output or self.out):
            yield

    def powershell_command(self, script, **values):
        env = dict(os.environ)
        env.update(values)
        result = subprocess.run([self.powershell, "-NoProfile", "-NonInteractive", "-Command", script],
                                env=env, text=True, encoding="utf-8", errors="replace",
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)

    def junction(self, path, target):
        self.assertTrue(path.parent.resolve().is_relative_to(self.base.resolve()))
        self.assertTrue(target.resolve().is_relative_to(self.base.resolve()))
        path.parent.mkdir(parents=True, exist_ok=True)
        self.powershell_command(
            "New-Item -ItemType Junction -Path $env:KIF_PROBE_GUARD_LINK "
            "-Target $env:KIF_PROBE_GUARD_TARGET -ErrorAction Stop | Out-Null",
            KIF_PROBE_GUARD_LINK=str(path), KIF_PROBE_GUARD_TARGET=str(target))
        self.assertTrue(getattr(path.lstat(), "st_file_attributes", 0) & 0x400)
        # Demonstrates why the old is_symlink-only guard was insufficient.
        self.assertFalse(path.is_symlink())
        self.links.append(path)
        type(self).junctions_created += 1
        return path

    def assert_external_preserved(self):
        self.assertEqual(self.sentinel.read_bytes(), b"outside target must stay intact")

    def tearDown(self):
        if not hasattr(self, "powershell") or not self.powershell:
            return
        # All removal stays in a single PowerShell implementation; links are
        # unlinked first, then remaining descendants are checked before rmtree.
        self.powershell_command(r'''
$ErrorActionPreference = 'Stop'
$base = [IO.Path]::GetFullPath($env:KIF_PROBE_GUARD_BASE)
$parent = [IO.Path]::GetFullPath($env:KIF_PROBE_GUARD_PARENT)
if ([IO.Path]::GetDirectoryName($base) -ne $parent -or ![IO.Path]::GetFileName($base).StartsWith('junction-regression-')) { throw 'Unsafe fixture cleanup root' }
$links = @(ConvertFrom-Json $env:KIF_PROBE_GUARD_LINKS)
[array]::Reverse($links)
foreach ($link in $links) {
    $absolute = [IO.Path]::GetFullPath($link)
    if (!$absolute.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe junction cleanup path' }
    $item = Get-Item -LiteralPath $absolute -Force
    if (!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected test-owned junction' }
    Remove-Item -LiteralPath $absolute -Force
}
$baseItem = Get-Item -LiteralPath $base -Force
if ($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture root became a reparse point' }
$queue = [Collections.Generic.Queue[string]]::new()
$queue.Enqueue($base)
while ($queue.Count) {
    $directory = $queue.Dequeue()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected remaining cleanup reparse point' }
        if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
    }
}
$resolved = (Resolve-Path -LiteralPath $base).ProviderPath
if ([IO.Path]::GetFullPath($resolved) -ne $base) { throw 'Fixture cleanup resolved outside expected absolute root' }
Remove-Item -LiteralPath $base -Recurse -Force
''', KIF_PROBE_GUARD_BASE=str(self.base), KIF_PROBE_GUARD_PARENT=str(self.parent.resolve()),
             KIF_PROBE_GUARD_LINKS=json.dumps([str(path) for path in self.links]))
        self.assertFalse(self.base.exists())

    def test_normal_directory_creation_write_and_reset(self):
        with self.configured():
            work = probe.create_output_directory(self.out / "work")
            probe.write_json(work / "result.json", {"hostOnly": True})
            self.assertEqual(json.loads((work / "result.json").read_text()), {"hostOnly": True})
            probe.reset_directory(work)
            self.assertEqual(list(work.iterdir()), [])
            self.assertEqual(probe.validate_output_root(scan_tree=True), self.out)
        self.assert_external_preserved()

    def test_rejects_lexically_external_root_even_with_dedicated_name(self):
        bad = self.external / "temp/native-probe"
        with self.configured(output=bad):
            with self.assertRaisesRegex(ValueError, "directly below"):
                probe.create_output_directory(bad / "work")
        self.assertFalse(bad.exists())
        self.assert_external_preserved()

    def test_rejects_output_root_junction_before_resolve_or_reset(self):
        victim = self.external / "work"
        victim.mkdir()
        (victim / "keep.txt").write_bytes(b"do not delete")
        self.junction(self.out, self.external)
        with self.configured():
            for action in (probe.safe_output, probe.reset_directory, probe.create_output_directory):
                with self.subTest(action=action.__name__), self.assertRaisesRegex(ValueError, "reparse"):
                    action(self.out / "work")
        self.assertEqual((victim / "keep.txt").read_bytes(), b"do not delete")
        self.assert_external_preserved()

    def test_rejects_work_target_junction(self):
        self.out.mkdir(parents=True)
        work = self.junction(self.out / "work", self.external)
        with self.configured(), self.assertRaisesRegex(ValueError, "reparse"):
            probe.reset_directory(work)
        self.assert_external_preserved()

    def test_rejects_nested_parent_junction_before_writing(self):
        self.out.mkdir(parents=True)
        redirected = self.junction(self.out / "staging", self.external)
        victim = self.external / "protected.json"
        victim.write_bytes(b"original external JSON")
        with self.configured(), self.assertRaisesRegex(ValueError, "reparse"):
            probe.write_json(redirected / "protected.json", {"mustNotWrite": True})
        self.assertEqual(victim.read_bytes(), b"original external JSON")
        self.assert_external_preserved()

    def test_rejects_temp_ancestor_junction(self):
        self.junction(self.repo / "temp", self.external)
        with self.configured(), self.assertRaisesRegex(ValueError, "reparse"):
            probe.create_output_directory(self.out / "work")
        self.assertFalse((self.external / "native-probe").exists())
        self.assert_external_preserved()

    def test_rejects_checkout_ancestor_junction(self):
        alias = self.junction(self.base / "checkout-alias", self.repo)
        with self.configured(root=alias, output=alias / "temp/native-probe"), self.assertRaisesRegex(ValueError, "reparse"):
            probe.create_output_directory(alias / "temp/native-probe/work")
        self.assertFalse((self.repo / "temp").exists())
        self.assert_external_preserved()

    def test_rejects_junction_even_with_internal_target(self):
        target = self.out / "real-work"
        target.mkdir(parents=True)
        (target / "keep.txt").write_bytes(b"inside target still preserved")
        linked = self.junction(self.out / "work", target)
        with self.configured(), self.assertRaisesRegex(ValueError, "reparse"):
            probe.reset_directory(linked)
        self.assertEqual((target / "keep.txt").read_bytes(), b"inside target still preserved")

    def test_reset_rejects_child_junction_without_traversing_it(self):
        work = self.out / "work"
        work.mkdir(parents=True)
        (work / "local.txt").write_bytes(b"local tree preserved")
        self.junction(work / "redirected", self.external)
        with self.configured(), self.assertRaisesRegex(ValueError, "reparse"):
            probe.reset_directory(work)
        self.assertEqual((work / "local.txt").read_bytes(), b"local tree preserved")
        self.assert_external_preserved()

    def test_both_main_entries_reject_root_junction_before_first_write(self):
        for module, name in ((probe, "native-probe"), (full, "native-full-probe")):
            with self.subTest(builder=module.__name__):
                output = self.repo / "temp" / name
                self.junction(output, self.external)
                before = set(self.external.iterdir())
                with self.configured(output=output), \
                     mock.patch.object(sys, "argv", [module.__file__, "--prepare-only"]), \
                     mock.patch.object(probe, "manifest_safety", side_effect=AssertionError("Guard must run before preparation")):
                    with self.assertRaisesRegex(ValueError, "reparse"):
                        module.main()
                self.assertEqual(set(self.external.iterdir()), before)
                self.assert_external_preserved()

    def test_both_main_entries_reject_work_junction_before_first_write(self):
        for module, name, work_name in ((probe, "native-probe", "arm64"), (full, "native-full-probe", "build")):
            with self.subTest(builder=module.__name__):
                output = self.repo / "temp" / name
                output.mkdir(parents=True)
                self.junction(output / work_name, self.external)
                with self.configured(output=output), \
                     mock.patch.object(sys, "argv", [module.__file__, "--prepare-only"]), \
                     mock.patch.object(probe, "manifest_safety", side_effect=AssertionError("Guard must run before preparation")):
                    with self.assertRaisesRegex(ValueError, "reparse"):
                        module.main()
                self.assert_external_preserved()


def protected_artifact_hashes():
    paths = [
        REAL_ROOT / "temp/native-probe/Native-Ruby-Probe-arm64-emulator-test.apk",
        REAL_ROOT / "temp/native-probe/Native-Ruby-Probe-arm64-emulator-test-build-record.json",
        REAL_ROOT / "temp/native-full-probe/Native-Full-Runtime-Probe-arm64-test.apk",
        REAL_ROOT / "temp/native-full-probe/Native-Full-Runtime-Probe-arm64-test-build-record.json",
    ]
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths if path.is_file()}


if __name__ == "__main__":
    before = protected_artifact_hashes()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(OutputGuardTests))
    after = protected_artifact_hashes()
    if after != before:
        raise AssertionError("Already Android-tested APKs or records changed during host-only regression")
    summary = {"hostOnly": True, "testsRun": result.testsRun, "failures": len(result.failures),
               "errors": len(result.errors), "skipped": len(result.skipped),
               "actualWindowsJunctionsCreated": OutputGuardTests.junctions_created,
               "testedArtifactsUnchanged": after == before, "testedArtifactSha256": after,
               "apkRebuilt": False, "nativeCompilerInvoked": False, "deviceCommandsInvoked": False}
    probe.write_json(REAL_ROOT / "temp/native-full-probe/history/tested-builders/output-guard-host-result.json", summary)
    raise SystemExit(0 if result.wasSuccessful() else 1)
