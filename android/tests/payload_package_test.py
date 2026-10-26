"""Exercise real ZIP bytes, alias metadata and legacy/current refresh workflows."""
from pathlib import Path
import hashlib
import json
import sys
import shutil
import unittest
from unittest import mock
import zipfile
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/android"))
import package_game
import build_apk
from build_apk import validate_apk_assets


class PayloadPackageTest(unittest.TestCase):
    def setUp(self):
        parent = ROOT / "temp/host-checks"
        parent.mkdir(parents=True, exist_ok=True)
        self.approved_parent = parent.resolve()
        self.base = self.approved_parent / ("payload-package-" + uuid.uuid4().hex)
        # Inherit the workspace ACL. Python's Windows mkdir(mode=0700) in
        # TemporaryDirectory can exclude this sandbox's restricted process token.
        self.base.mkdir()

    def tearDown(self):
        # Delete only this test-owned directory after checking its resolved absolute parent.
        self.assertEqual(self.base.resolve().parent, self.approved_parent)
        self.assertTrue(self.base.name.startswith("payload-package-"))
        shutil.rmtree(self.base)

    def write(self, path, logical):
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            writer = package_game.PayloadWriter(archive)
            for name, data in sorted(logical.items()):
                writer.add(name, data)
            manifest = writer.manifest(False)
        return manifest

    def test_lossless_aliases_keep_every_original_path(self):
        logical = {"Audio/canonical.ogg": b"audio bytes" * 100,
                   "Audio/renamed.ogg": b"audio bytes" * 100,
                   "Graphics/alias.png": b"audio bytes" * 100,
                   "Data/other.dat": b"different bytes"}
        path = self.base / "payload.zip"
        manifest = self.write(path, logical)
        package_game.validate_payload(path, manifest, verify_hashes=True)
        self.assertEqual(manifest["archiveFormat"], 2)
        self.assertEqual(manifest["archiveFiles"], 2)
        self.assertEqual(manifest["bytes"], sum(map(len, logical.values())))
        with zipfile.ZipFile(path) as archive:
            self.assertEqual(set(archive.namelist()), {"Audio/canonical.ogg", "Data/other.dat"})
            for name, expected in logical.items():
                self.assertEqual(package_game.read_payload_file(archive, manifest, name), expected)
        # Compression and alias layout must not invent another content identity.
        old_logical = {name: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                       for name, data in logical.items()}
        expected_id = hashlib.sha256(json.dumps(old_logical, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:24]
        self.assertEqual(manifest["id"], expected_id)

    def test_reproducible_archive_and_manifest(self):
        logical = {"A/a.png": b"image" * 1024, "B/alias.png": b"image" * 1024, "C/c.rb": b"puts 1\n"}
        first, second = self.base / "one.zip", self.base / "two.zip"
        self.assertEqual(self.write(first, logical), self.write(second, logical))
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_reject_alias_chain_mismatch_and_missing_source(self):
        path = self.base / "payload.zip"
        original = self.write(path, {"a.bin": b"same", "b.bin": b"same", "c.bin": b"same"})
        for field, value in (("source", "b.bin"), ("source", "missing.bin"), ("size", 100), ("sha256", "f" * 64)):
            bad = json.loads(json.dumps(original))
            bad["files"]["c.bin"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                package_game.validate_payload(path, bad, verify_hashes=True)

    def test_reject_corrupt_missing_and_duplicate_zip_members(self):
        correct = self.base / "payload.zip"
        manifest = self.write(correct, {"a.bin": b"good"})
        for scenario in ("corrupt", "missing", "duplicate", "extra"):
            path = self.base / (scenario + ".zip")
            with zipfile.ZipFile(path, "w") as archive:
                if scenario != "missing": archive.writestr("a.bin", b"evil" if scenario == "corrupt" else b"good")
                if scenario == "duplicate": archive.writestr("a.bin", b"good")
                if scenario == "extra": archive.writestr("unlisted", b"good")
            with self.subTest(scenario=scenario), self.assertRaises(ValueError):
                package_game.validate_payload(path, manifest, verify_hashes=True)

    def test_refresh_old_and_deduplicated_payloads(self):
        for legacy in (True, False):
            with self.subTest(legacy=legacy):
                fixture = self.base / ("legacy" if legacy else "deduplicated")
                output = fixture / "staging"
                output.mkdir(parents=True)
                scripts = fixture / "Data/Scripts"
                scripts.mkdir(parents=True)
                (scripts / "000_Platform.rb").write_bytes(b"new platform\n")
                (scripts / "001_Example.rb").write_bytes(b"new script\n")
                (fixture / "Data/messages_zh.dat").write_bytes(b"Chinese language pack")
                helpers = fixture / "android/ruby"
                helpers.mkdir(parents=True)
                for name in ("kif_android_preload.rb", "android-runtime-smoke.rb", "android-game-smoke.rb",
                             "android-network-smoke.rb", "android-font-smoke.rb"):
                    (helpers / name).write_bytes(("new helper " + name).encode())
                logical = {"Graphics/canonical.png": b"image bytes" * 100,
                           "Graphics/other.png": b"image bytes" * 100,
                           "Data/Scripts/000_Platform.rb": b"old platform\n",
                           "Data/Scripts/001_Example.rb": b"old script\n"}
                path = output / "payload.zip"
                manifest = self.write(path, logical)
                if legacy:
                    manifest.pop("archiveFormat"); manifest.pop("archiveFiles"); manifest.pop("archiveBytes")
                    for item in manifest["files"].values(): item.pop("source", None)
                    with zipfile.ZipFile(path, "w") as archive:
                        for name, data in logical.items(): archive.writestr(name, data)
                (output / "payload-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                inventory = b"Data/Scripts/000_Platform.rb\0Data/Scripts/001_Example.rb\0"
                with mock.patch.object(package_game, "ROOT", fixture), mock.patch.object(package_game.subprocess, "check_output", return_value=inventory):
                    refreshed = package_game.refresh_ruby_payload(output)
                package_game.validate_payload(path, refreshed, verify_hashes=True)
                with zipfile.ZipFile(path) as archive:
                    self.assertEqual(package_game.read_payload_file(archive, refreshed, "Data/Scripts/001_Example.rb"), b"new script\n")
                    self.assertEqual(package_game.read_payload_file(archive, refreshed, "Data/messages_zh.dat"), b"Chinese language pack")
                    self.assertEqual(package_game.read_payload_file(archive, refreshed, "Graphics/other.png"), logical["Graphics/other.png"])
                    self.assertNotIn("Graphics/other.png", archive.namelist())
                self.assertEqual(refreshed["archiveFormat"], 2)

    def asset_staging(self):
        assets = self.base / "assets"
        assets.mkdir()
        for name in ("payload.zip", "payload-manifest.json", "mkxp-base.json"):
            (assets / name).write_bytes(b"fixture; content validation is tested separately")
        return assets

    def test_build_source_snapshot_detects_concurrent_edits(self):
        fixture = self.base / "source-snapshot"
        script = fixture / "android/ruby/probe.rb"
        script.parent.mkdir(parents=True)
        script.write_bytes(b"first version\n")
        with mock.patch.object(build_apk, "ROOT", fixture):
            snapshot = build_apk.source_snapshot()
            build_apk.assert_sources_unchanged(snapshot)
            script.write_bytes(b"edited during compilation\n")
            with self.assertRaisesRegex(SystemExit, "probe.rb"):
                build_apk.assert_sources_unchanged(snapshot)
            script.unlink()
            with self.assertRaisesRegex(SystemExit, "probe.rb"):
                build_apk.assert_sources_unchanged(snapshot)

    def test_skip_payload_rejects_stale_game_script(self):
        fixture = self.base / "script-snapshot"
        script = fixture / "Data/Scripts/000_Platform.rb"
        script.parent.mkdir(parents=True)
        script.write_bytes(b"current platform\n")
        manifest = {"files": {"Data/Scripts/000_Platform.rb": {
            "sha256": hashlib.sha256(script.read_bytes()).hexdigest()}}}
        # Legacy .rb assets outside the ordered source tree come from --asset-root,
        # not android/ruby; a sparse source checkout need not contain these.
        manifest["files"]["Data/compiler.rb"] = {"sha256": "0" * 64}
        with mock.patch.object(build_apk, "ROOT", fixture):
            build_apk.validate_staged_scripts(manifest)
            script.write_bytes(b"changed platform\n")
            with self.assertRaisesRegex(SystemExit, "refresh-ruby"):
                build_apk.validate_staged_scripts(manifest)

    def test_reject_leftover_partial_before_aapt_collection(self):
        # Real aapt2 reproduction in temp/evidence/payload-review proved this exact
        # filename is packaged by -A. The build must refuse it and preserve evidence.
        assets = self.asset_staging()
        validate_apk_assets(assets, False)
        pending = assets / "payload.zip.pending"
        pending.write_bytes(b"interrupted 700 MB archive fixture")
        for require_payload in (False, True):
            with self.subTest(require_payload=require_payload), self.assertRaisesRegex(ValueError, "payload.zip.pending"):
                validate_apk_assets(assets, False, require_payload=require_payload)
            self.assertEqual(pending.read_bytes(), b"interrupted 700 MB archive fixture")

    def test_strict_assets_reject_unknown_files_and_directories(self):
        assets = self.asset_staging()
        for name, directory in (("old.zip", False), ("nested", True)):
            path = assets / name
            path.mkdir() if directory else path.write_bytes(b"unexpected")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, name):
                validate_apk_assets(assets, False, require_payload=False)
            self.assertTrue(path.exists())
            path.rmdir() if directory else path.unlink()
        (assets / "payload.zip").unlink()
        (assets / "payload.zip").mkdir()
        with self.assertRaisesRegex(ValueError, "payload.zip"):
            validate_apk_assets(assets, False)
        self.assertTrue((assets / "payload.zip").is_dir())

    def test_network_marker_is_exclusive_to_network_variant(self):
        assets = self.asset_staging()
        validate_apk_assets(assets, True, require_payload=False)
        with self.assertRaisesRegex(ValueError, "network-enabled"):
            validate_apk_assets(assets, True)
        marker = assets / "network-enabled"
        marker.write_bytes(b"1")
        validate_apk_assets(assets, True)
        with self.assertRaisesRegex(ValueError, "network-enabled"):
            validate_apk_assets(assets, False, require_payload=False)
        self.assertEqual(marker.read_bytes(), b"1")
        marker.write_bytes(b"wrong marker")
        with self.assertRaisesRegex(ValueError, "Invalid network-enabled"):
            validate_apk_assets(assets, True, require_payload=False)
        self.assertEqual(marker.read_bytes(), b"wrong marker")

    def test_build_main_refuses_partial_before_any_compile_or_pack_command(self):
        fixture = self.base / "cli"
        javac = fixture / "temp/tools/jdk-17-fixture/bin/javac.exe"
        javac.parent.mkdir(parents=True)
        javac.write_bytes(b"must never execute")
        assets = fixture / "temp/android-build/assets"
        assets.mkdir(parents=True)
        pending = assets / "payload.zip.pending"
        pending.write_bytes(b"retain this interrupted payload")
        with mock.patch.object(build_apk, "ROOT", fixture), \
             mock.patch.object(build_apk, "select_runtime", return_value=(None, None, None)), \
             mock.patch.object(build_apk, "require_input_bridge", return_value={}), \
             mock.patch.object(build_apk, "run") as commands, \
             mock.patch.object(sys, "argv", ["build_apk.py", "--skip-payload"]):
            with self.assertRaisesRegex(ValueError, "payload.zip.pending"):
                build_apk.main()
            commands.assert_not_called()
        self.assertEqual(pending.read_bytes(), b"retain this interrupted payload")
        self.assertFalse((fixture / "temp/android-build/classes").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
