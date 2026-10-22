import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import unittest
import uuid

from release_manager import stage, activate, validate_inventory


class ProductionReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = Path(__file__).resolve().parents[2]
        cls.base = cls.workspace / "temp/production-release-tests"
        cls.shared = cls.base / uuid.uuid4().hex[:12]
        cls.shared.mkdir(parents=True)
        specification = importlib.util.spec_from_file_location("production_builder", cls.workspace / "scripts/multiplayer/build-production-release.py")
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        wheels = cls.workspace / "temp/tools/multiplayer-production/wheels"
        if not wheels.is_dir():
            raise unittest.SkipTest("Prepare the verified offline production wheels")
        with contextlib.redirect_stdout(io.StringIO()):
            cls.archive = module.build(cls.shared / "artifacts", wheels)

    @classmethod
    def tearDownClass(cls):
        assert cls.shared.resolve().parent == cls.base.resolve()
        shutil.rmtree(cls.shared)

    def setUp(self):
        self.root = self.shared / uuid.uuid4().hex[:8]
        self.root.mkdir()
        self.releases = self.root / "releases"

    def test_offline_release_is_allowlisted_hash_verified_and_idempotent(self):
        installed = stage(self.archive, self.releases)
        metadata = json.loads((installed / "release.json").read_text())
        validate_inventory(installed, metadata)
        self.assertEqual(stage(self.archive, self.releases), installed)
        self.assertFalse(list(self.releases.glob(".partial-*")))
        self.assertTrue((installed / "wheels").is_dir())
        self.assertFalse(any(".sqlite3" in name or "password" in name or name.endswith(".sav") for name in metadata["files"]))
        self.assertEqual(json.loads((installed / "server/multiplayer/deploy/production.json").read_text())["domain"], "if.pikastairs.cc")

    def test_corrupt_release_fails_without_touching_data(self):
        installed = stage(self.archive, self.releases)
        (self.root / "account-data-preserve").write_bytes(b"unchanged")
        source = installed / "server/multiplayer/online.py"
        source.write_text("tampered")
        with self.assertRaises(RuntimeError):
            stage(self.archive, self.releases)
        self.assertEqual((self.root / "account-data-preserve").read_bytes(), b"unchanged")

    def test_archive_traversal_alias_and_symlink_are_rejected(self):
        for number, name in enumerate(("../escape", "server/multiplayer/../escape", "server//multiplayer/service.py")):
            archive = self.root / (str(number) + ".tar.gz")
            with tarfile.open(archive, "w:gz") as file:
                item = tarfile.TarInfo(name)
                item.size = 3
                file.addfile(item, io.BytesIO(b"bad"))
            with self.assertRaises(RuntimeError):
                stage(archive, self.releases)
        archive = self.root / "link.tar.gz"
        with tarfile.open(archive, "w:gz") as file:
            item = tarfile.TarInfo("server/multiplayer/service.py")
            item.type, item.linkname = tarfile.SYMTYPE, "/etc/passwd"
            file.addfile(item)
        with self.assertRaises(RuntimeError):
            stage(archive, self.releases)
        self.assertFalse((self.root / "escape").exists())

    def test_atomic_code_activation_validates_before_switch(self):
        installed = stage(self.archive, self.releases)
        try:
            activate(self.releases, installed.name)
        except OSError as error:
            if getattr(error, "winerror", None) == 1314:
                self.skipTest("Windows token cannot create directory symlinks; Linux activation remains a host check")
            raise
        self.assertEqual((self.root / "current").resolve(), installed)
        with self.assertRaises(RuntimeError):
            activate(self.releases, "../data")
        source = installed / "server/multiplayer/service.py"
        source.write_text("damaged")
        with self.assertRaises(RuntimeError):
            activate(self.releases, installed.name)
        self.assertEqual((self.root / "current").resolve(), installed)


if __name__ == "__main__":
    unittest.main()
