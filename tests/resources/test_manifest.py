"""The resource catalog must verify raw GitHub files and Windows ZIP contents."""
from pathlib import Path
import hashlib
import importlib.util
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("resource_manifest", ROOT / "scripts/resources/build_manifest.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ManifestTests(unittest.TestCase):
    def test_windows_data_hashes_match_canonical_git_bytes(self):
        with patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_bytes", return_value=b"first\r\nsecond\r\n"):
            rows = builder.bundled_data()
        expected = b"first\nsecond\n"
        self.assertEqual(len(rows), len(builder.DATA) - 1)
        for row in rows:
            content = b"first\r\nsecond\r\n" if row["path"].endswith(".gz") else expected
            self.assertEqual(row["size"], len(content))
            self.assertEqual(row["sha256"], hashlib.sha256(content).hexdigest())

    def test_revision_is_deterministic_and_case_collisions_fail(self):
        rows = [{"path": "b.png"}, {"path": "a.png"}]
        self.assertEqual(builder.seal("a" * 40, rows.copy()), builder.seal("a" * 40, list(reversed(rows))))
        with self.assertRaises(ValueError):
            builder.seal("a" * 40, [{"path": "A.png"}, {"path": "a.png"}])


if __name__ == "__main__":
    unittest.main()
