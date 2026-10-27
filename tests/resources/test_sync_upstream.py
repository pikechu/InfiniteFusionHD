from pathlib import Path
import gzip
import hashlib
import json
import shutil
import struct
import sys
import unittest
import urllib.error
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/resources"))
import sync_upstream as sync


class UpstreamSyncTests(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / "temp" / ("sync-test-" + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        for name, data in {
            "Data/Scripts/001_Settings.rb": b"NB_POKEMON = 501\n",
            "Data/sprites/CUSTOM_SPRITES": b"1.1.png\n",
            "Data/sprites/BASE_SPRITES": b"1.png\n",
            "Data/sprites/Sprite Credits.csv": b"1.1,local artist\n2.2,local-only artist\n",
            "Data/pokedex/dex.json": json.dumps([{"sprite":"1.1.png","entry":"Local text","author":"local"}]).encode(),
            "Data/pokedex/all_entries.json": b"{}\n",
            "Data/offline-resources.json": json.dumps({"format":1,"revision":"a"*64,"upstream_commit":"b"*40,"files":[]}).encode(),
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.requests = []
        self.bad_image = False
        self.root_patch = patch.object(sync, "ROOT", self.root)
        self.catalog_patch = patch.object(sync.catalog, "ROOT", self.root)
        self.image_catalog_patch = patch.object(sync.catalog, "build", return_value={"upstream_commit":"b"*40,"files":[]})
        self.root_patch.start(); self.catalog_patch.start(); self.image_catalog_patch.start()

    def tearDown(self):
        self.root_patch.stop(); self.catalog_patch.stop(); self.image_catalog_patch.stop()
        target = self.root.resolve()
        self.assertTrue(target.is_relative_to((ROOT / "temp").resolve()))
        self.assertTrue(target.name.startswith("sync-test-"))
        shutil.rmtree(target)

    def api(self, path, repo):
        return {"sha": ("a" if repo == sync.PIF else "b") * 40}

    def fetch(self, url, limit, probe=False):
        self.requests.append((url, probe))
        if url.endswith("CUSTOM_SPRITES"):
            return b"1.1.png\n1.2a.png\n999.1.png\n", ""
        if url.endswith("BASE_SPRITES"):
            return b"1.png\n999.png\n", ""
        if url.endswith("dex.json"):
            return json.dumps([{"sprite":"1.2a.png","entry":"Upstream text","author":"artist"}]).encode(), ""
        if url.endswith("Sprite_Credits.csv"):
            return b"1.1,new artist,main,\n", ""
        width = 1920 if "/spritesheets_custom/" in url else 960
        header = b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + struct.pack(">II", width, 96)
        if self.bad_image:
            header = b"invalid"
        return (header if probe else header + b"payload"), '"fixture-etag"'

    def test_verified_sync_is_idempotent_and_preserves_local_content(self):
        outputs, summary = sync.prepare(self.fetch, self.api, workers=1)
        changed = sync.apply(outputs)
        self.assertTrue(set(changed).issubset(sync.OUTPUTS))
        self.assertIn("Data/pokedex/dex.json.gz", changed)
        self.assertIn("Data/offline-resources.json", changed)
        records = json.loads(outputs["Data/pokedex/dex.json"])
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["entry"], "Local text")
        self.assertEqual(gzip.decompress(outputs["Data/pokedex/dex.json.gz"]), outputs["Data/pokedex/dex.json"])
        self.assertIn(b"local-only artist", outputs["Data/sprites/Sprite Credits.csv"])
        self.assertIn(b"new artist", outputs["Data/sprites/Sprite Credits.csv"])
        self.assertNotIn(b"999", outputs["Data/sprites/CUSTOM_SPRITES"])
        self.assertEqual(summary["verified_sheets"], 3)
        manifest = json.loads(outputs["Data/offline-resources.json"])
        self.assertNotIn("Data/pokedex/dex.json", {row["path"] for row in manifest["files"]})
        packed = next(row for row in manifest["files"] if row["path"].endswith(".gz"))
        self.assertEqual(packed["sha256"], hashlib.sha256(outputs[packed["path"]]).hexdigest())
        self.requests.clear()
        again, _ = sync.prepare(self.fetch, self.api, workers=1)
        self.assertEqual(sync.apply(again), [])
        self.assertTrue(all(probe for url, probe in self.requests if url.endswith(".png")))

    def test_invalid_upstream_never_writes_partial_resources(self):
        before = {p.relative_to(self.root):p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.bad_image = True
        with self.assertRaises(ValueError):
            sync.prepare(self.fetch, self.api, workers=1)
        after = {p.relative_to(self.root):p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_html_and_capacity_errors_are_rejected(self):
        with self.assertRaises(ValueError):
            sync.index_names(b"<html>server error</html>", False, 501)
        with self.assertRaises(ValueError):
            sync.merge_credits(b"1.1,artist\n", b"<html>error</html>")
        with self.assertRaises(ValueError):
            sync.merge_dex([{"bad":"local"}], [], 501)
        with self.assertRaises(ValueError):
            sync.apply({"unexpected/path":b"x"})

    def test_unpublished_sheet_is_deferred_without_publishing_a_dead_url(self):
        def fetch(url, limit, probe=False):
            if url.endswith('/1a.png'):
                raise urllib.error.HTTPError(url, 404, 'not published', {}, None)
            return self.fetch(url, limit, probe)
        outputs, summary = sync.prepare(fetch, self.api, workers=1)
        self.assertEqual(summary['pending_sheets'], 1)
        self.assertEqual(summary['verified_sheets'], 2)
        manifest = json.loads(outputs['Data/offline-resources.json'])
        self.assertFalse(any(row['url'].endswith('/1a.png') for row in manifest['files']))
        self.assertTrue(json.loads(outputs[sync.STATE])['pending_sheets'])


if __name__ == "__main__":
    unittest.main()
