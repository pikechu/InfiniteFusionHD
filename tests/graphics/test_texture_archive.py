from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/graphics"))
import texture_archive as tool


class TextureArchiveTests(unittest.TestCase):
    def setUp(self):
        self.parent = ROOT / "temp"
        self.created_parent = not self.parent.exists()
        self.parent.mkdir(exist_ok=True)
        self.workspace = tempfile.TemporaryDirectory(prefix="texture-archive-test-", dir=self.parent)
        self.root = Path(self.workspace.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.archive = self.root / "archive.zip"
        for name, data in {
            "batch-001/originals/原图.png": b"\x00original\xff\r\n",
            "batch-001/delivery/原图.png": b"\x00original\xff\r\n",
            "p1-evidence/result.json": b'{"pass":true}\r\n',
            "probe.rb": b"puts 'exact LF'\n",
        }.items():
            output = self.source / name
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(data)
        (self.source / "empty-directory").mkdir()

    def tearDown(self):
        self.workspace.cleanup()
        if self.created_parent:
            self.parent.rmdir()

    def create(self):
        return tool.create(self.source, self.archive, workers=2)

    def rewrite_manifest(self, change):
        altered = self.root / "altered.zip"
        with zipfile.ZipFile(self.archive) as source, zipfile.ZipFile(altered, "w") as target:
            manifest = json.loads(source.read("manifest.json"))
            change(manifest)
            for name in source.namelist():
                target.writestr(name, json.dumps(manifest) if name == "manifest.json" else source.read(name))
        return altered

    def test_roundtrip_preserves_all_paths_bytes_and_empty_directories(self):
        result = self.create()
        self.assertEqual((result["file_count"], result["object_count"]), (4, 3))
        target = self.root / "restored"
        tool.restore(self.archive, target, result["sha256"])
        for source in self.source.rglob("*"):
            output = target / source.relative_to(self.source)
            self.assertEqual(source.is_dir(), output.is_dir())
            if source.is_file():
                self.assertEqual(source.read_bytes(), output.read_bytes())

    def test_restore_refuses_existing_destination_and_wrong_archive_hash(self):
        self.create()
        with self.assertRaises(FileExistsError):
            tool.restore(self.archive, self.source)
        target = self.root / "restored"
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            tool.restore(self.archive, target, "0" * 64)
        self.assertFalse(target.exists())

    def test_path_traversal_is_rejected_before_restore(self):
        self.create()
        def change(manifest):
            manifest["files"]["../escaped"] = manifest["files"].pop("probe.rb")
        altered = self.rewrite_manifest(change)
        with self.assertRaisesRegex(ValueError, "Unsafe archive path"):
            tool.restore(altered, self.root / "restored")
        self.assertFalse((self.root / "escaped").exists())

    def test_corruption_and_missing_objects_are_rejected(self):
        self.create()
        for omit in (False, True):
            damaged = self.root / f"damaged-{omit}.zip"
            with zipfile.ZipFile(self.archive) as source, zipfile.ZipFile(damaged, "w") as target:
                for i, name in enumerate(source.namelist()):
                    if i == 0 and omit:
                        continue
                    data = source.read(name)
                    target.writestr(name, b"x" * len(data) if i == 0 else data)
            with self.assertRaises(ValueError):
                tool.restore(damaged, self.root / "restored")

    def test_failure_cleans_only_its_partial_archive_or_restore(self):
        with patch.object(tool, "verify", side_effect=ValueError("injected verification failure")):
            with self.assertRaises(ValueError):
                self.create()
        self.assertFalse(self.archive.exists())
        self.assertFalse(self.archive.with_name("archive.zip.pending").exists())
        self.create()
        real_hash = tool.file_hash
        target = self.root / "restored"
        def fail_output(path):
            if Path(path).is_relative_to(target):
                raise OSError("injected restore write failure")
            return real_hash(path)
        with patch.object(tool, "file_hash", side_effect=fail_output):
            with self.assertRaises(OSError):
                tool.restore(self.archive, target)
        self.assertFalse(target.exists())
        self.assertTrue(self.source.is_dir())


if __name__ == "__main__":
    unittest.main()
