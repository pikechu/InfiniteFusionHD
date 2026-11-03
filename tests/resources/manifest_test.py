"""Bundled-data manifest guards use real bytes and no network."""
from pathlib import Path
import json
import os
import shutil
import stat
import sys
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/resources"))
from build_manifest import DATA, bundled_data, check_bundled_data, seal
DATA = tuple(name for name in DATA if not name.endswith(".gz"))


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.parent = (ROOT / "temp").resolve()
        self.root = self.parent / ("resource-manifest-" + uuid.uuid4().hex)
        self.root.mkdir()  # Inherit the workspace ACL on Windows.

    def tearDown(self):
        self.assertEqual(self.root.resolve().parent, self.parent)
        def remove_readonly(function, path, error):
            self.assertTrue(Path(path).resolve().is_relative_to(self.root.resolve()))
            os.chmod(path, stat.S_IREAD | stat.S_IWRITE)
            function(path)
        shutil.rmtree(self.root, onerror=remove_readonly)

    def test_all_data_changes_and_missing_entries_are_detected(self):
        root = self.root
        for name in DATA:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"original data")
        manifest = seal("a" * 40, bundled_data(root=root))
        self.assertEqual(set(check_bundled_data(manifest, root)), set(DATA))
        for name in DATA:
            with self.subTest(path=name):
                path = root / name
                path.write_bytes(b"modified data")  # Same length; size alone cannot detect this.
                with self.assertRaisesRegex(ValueError, name):
                    check_bundled_data(manifest, root)
                path.write_bytes(b"original data")
        for name in DATA:
            with self.subTest(missing=name):
                incomplete = dict(manifest, files=[row for row in manifest["files"] if row["path"] != name])
                with self.assertRaisesRegex(ValueError, name):
                    check_bundled_data(incomplete, root)

    def test_data_refresh_preserves_pinned_images(self):
        root = self.root
        for name in DATA:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"data")
        image = {"path": "Graphics/Battlers/Special/000.png", "kind": "image", "size": 10,
                 "sha1": "b" * 40, "url": "https://fixture.invalid/pinned.png"}
        before = seal("a" * 40, [image] + bundled_data(root=root))
        (root / "Data/pokedex/dex_zh.json").write_bytes("更新后的图鉴".encode())
        after = seal(before["upstream_commit"], [row for row in before["files"] if row["kind"] == "image"] + bundled_data(root=root))
        self.assertNotEqual(before["revision"], after["revision"])
        self.assertEqual([row for row in after["files"] if row["kind"] == "image"], [image])
        self.assertEqual(after["upstream_commit"], before["upstream_commit"])
        check_bundled_data(after, root)

    def test_git_checkout_preserves_resource_bytes_across_line_ending_settings(self):
        root = self.root
        (root / ".gitattributes").write_bytes((ROOT / ".gitattributes").read_bytes())
        raw = b"first line\nsecond line\n"
        names = (*DATA, "Data/shop/catalog.json", "Data/offline-resources.json", "Data/multiplayer-build.json")
        for name in names:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        manifest = seal("a" * 40, bundled_data(root=root))
        def git(*args):
            return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)
        git("init", "-q")
        git("-c", "core.autocrlf=true", "add", ".gitattributes", "Data")
        for setting in ("false", "true"):
            git("-c", "core.autocrlf=" + setting, "checkout-index", "-a", "-f")
            check_bundled_data(manifest, root)
            for name in names:
                self.assertEqual((root / name).read_bytes(), raw, name)


if __name__ == "__main__":
    unittest.main()
