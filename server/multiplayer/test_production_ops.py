import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import unittest
import uuid

from production import Application
from production_data import Config, atomic_bytes
from production_ops import initialize, backup, restore, run, restic
from service import PROTOCOL, RULES


class ProductionRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(os.environ.get("KIF_TEST_TEMP_ROOT", str(Path(__file__).resolve().parents[2] / "temp/production-ops-tests"))).resolve()
        self.root = self.base / uuid.uuid4().hex[:12]
        self.root.mkdir(parents=True)
        executable = os.environ.get("KIF_TEST_RESTIC") or (str(Path(__file__).resolve().parents[2] / "temp/tools/multiplayer-production/restic.exe") if os.name == "nt" else shutil.which("restic"))
        if not executable or not Path(executable).is_file():
            self.skipTest("Install the verified Restic test tool or set KIF_TEST_RESTIC")
        self.config = Config("if.pikastairs.cc", self.root / "data", self.root / "data-id", self.root / "backups",
                             self.root / "repository-file", self.root / "password-file", executable, self.root / "release", allow_local_repository=True)
        atomic_bytes(self.config.restic_repository_file, str(self.root / "encrypted-repository").encode())
        self.password = secrets.token_hex(32).encode()
        atomic_bytes(self.config.restic_password_file, self.password)
        initialize(self.config)
        run(self.config, "repo-init")
        self.app = Application(self.config)
        status, self.alice = self.app.store.request("POST", "/v1/auth/register", {"username": "alice", "password": "RecoveryFixturePassword9", "protocol": PROTOCOL})
        self.assertEqual(status, 201)
        self.session = "session_" + uuid.uuid4().hex
        self.compat = {"protocol": PROTOCOL, "game_version": "fixture", "data_hash": "same-data", "mods_hash": "same-mods", "rules_version": RULES}
        self.call("/v1/cloud/open", {"session_id": self.session, "compatibility": self.compat})

    def tearDown(self):
        if hasattr(self, "app"):
            self.app.close()
        assert self.root.resolve().parent == self.base.resolve()
        shutil.rmtree(self.root)

    def call(self, path, body, expected=200):
        status, response = self.app.store.request("POST", path, body, self.alice["token"])
        self.assertEqual(status, expected, response)
        return response

    def upload(self, revision, text):
        raw = text.encode()
        return {"session_id": self.session, "slot": "file-a", "revision": revision, "upload_id": uuid.uuid4().hex,
                "save": {"format": "kif-save-json-v1", "game_version": "fixture", "payload": base64.b64encode(raw).decode(), "sha256": hashlib.sha256(raw).hexdigest()}}

    def test_encrypted_online_snapshot_restart_restore_and_stale_upload_fence(self):
        first = self.upload(0, "cloud_progress_before_backup_你好")
        self.call("/v1/cloud/upload", first)
        self.call("/v1/world/join", {"session_id": self.session, "compatibility": self.compat})
        with self.app.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM world_presence").fetchone()[0], 1)
        receipt = backup(self.config)
        with self.app.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM world_presence").fetchone()[0], 1, "Backup instantiated Store and reset live players")
        with self.assertRaises(RuntimeError):
            restore(self.config, receipt["snapshot_id"])
        self.call("/v1/cloud/upload", self.upload(1, "progress_after_backup"))
        stale = self.upload(2, "pending_upload_must_not_overwrite_recovery")
        self.app.close()
        result = restore(self.config, receipt["snapshot_id"])
        self.assertTrue(result["requires_login"])
        self.assertTrue((Path(result["pre_restore_copy"]) / "multiplayer.sqlite3").is_file())
        self.app = Application(self.config)
        self.assertEqual(self.app.store.request("GET", "/v1/identity", token=self.alice["token"])[0], 401)
        status, self.alice = self.app.store.request("POST", "/v1/auth/login", {"username": "alice", "password": "RecoveryFixturePassword9", "protocol": PROTOCOL})
        self.assertEqual(status, 200)
        self.call("/v1/cloud/open", {"session_id": self.session, "compatibility": self.compat})
        downloaded = self.call("/v1/cloud/download", {"session_id": self.session, "slot": "file-a"})
        self.assertEqual(downloaded["save"], first["save"])
        self.assertGreater(downloaded["revision"], 2)
        self.call("/v1/cloud/upload", stale, 409)
        self.call("/v1/cloud/upload", self.upload(downloaded["revision"], "new_progress_after_recovery"))
        for _ in range(3):
            backup(self.config)
        self.assertEqual(len(list(self.config.backup_dir.glob("snapshot-*"))), 2)
        self.assertTrue(Path(result["pre_restore_copy"]).exists(), "Routine rotation deleted the pre-restore recovery copy")
        run(self.config, "retention")
        run(self.config, "repo-check")
        run(self.config, "backup-status")
        # The repository itself contains encrypted data, not plaintext account
        # credentials or cloud save payloads. Config/password files are outside it.
        for file in (self.root / "encrypted-repository").rglob("*"):
            if file.is_file():
                self.assertNotIn(b"RecoveryFixturePassword9", file.read_bytes())
                self.assertNotIn(first["save"]["payload"].encode(), file.read_bytes())

    def test_backup_failure_and_invalid_restore_do_not_destroy_current_progress(self):
        body = self.upload(0, "real_cloud_save_for_failure_tests")
        self.call("/v1/cloud/upload", body)
        receipt = backup(self.config)
        atomic_bytes(self.config.restic_password_file, b"wrong_password_longer_than_twenty_bytes")
        with self.assertRaises(RuntimeError):
            backup(self.config)
        state = json.loads((self.config.data_dir / "backup-status.json").read_text())
        self.assertFalse(state["ok"])
        self.assertEqual(state["last_success"], receipt["last_success"])
        atomic_bytes(self.config.restic_password_file, self.password)
        self.app.close()
        with self.assertRaises(RuntimeError):
            restore(self.config, "f" * 64)
        # Publish an intentionally corrupt manifest through the real encrypted
        # tool; the restore guard must reject it before replacing the live file.
        manifest_file = self.config.backup_dir / "current/manifest.json"
        document = json.loads(manifest_file.read_text())
        document["database_sha256"] = "0" * 64
        manifest_file.write_text(json.dumps(document))
        output = restic(self.config, "backup", str(manifest_file.parent), "--host", self.config.domain,
                        "--tag", "kif-mmo", "--tag", "data-id=" + self.config.data_id(), "--json")
        corrupt = next(json.loads(line)["snapshot_id"] for line in output.splitlines() if json.loads(line).get("message_type") == "summary")
        with self.assertRaises(RuntimeError):
            restore(self.config, corrupt)
        self.app = Application(self.config)
        self.call("/v1/cloud/open", {"session_id": self.session, "compatibility": self.compat})
        downloaded = self.call("/v1/cloud/download", {"session_id": self.session, "slot": "file-a"})
        self.assertEqual(downloaded["save"], body["save"])
        with self.assertRaises(RuntimeError):
            initialize(self.config)


if __name__ == "__main__":
    unittest.main()
