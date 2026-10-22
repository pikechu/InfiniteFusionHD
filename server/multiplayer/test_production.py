import base64
import io
import json
from pathlib import Path
import sqlite3
import shutil
import threading
import unittest
from unittest.mock import patch
import uuid
from wsgiref.util import setup_testing_defaults
from wsgiref.validate import validator

import online
from production import Application
from production_data import Config, atomic_bytes, SCHEMA_VERSION
from service import Store, PROTOCOL


class ProductionTests(unittest.TestCase):
    def setUp(self):
        self.test_base = Path(__file__).resolve().parents[2] / "temp/production-tests"
        self.root = self.test_base / uuid.uuid4().hex
        self.root.mkdir(parents=True)
        self.data = self.root / "data"
        self.data.mkdir()
        self.identity = uuid.uuid4().hex
        atomic_bytes(self.root / "data-id", (self.identity + "\n").encode())
        self.config = Config("if.pikastairs.cc", self.data, self.root / "data-id", self.root / "backups",
                             self.root / "repo-file", self.root / "password-file", "restic", self.root)
        self.initialize()
        self.app = Application(self.config)

    def initialize(self):
        store = Store(self.config.database, synchronous="FULL")
        with store.connect() as db:
            db.execute("CREATE TABLE deployment_meta(name TEXT PRIMARY KEY,value TEXT NOT NULL)")
            db.executemany("INSERT INTO deployment_meta VALUES(?,?)", [("schema_version", str(SCHEMA_VERSION)), ("data_id", self.identity)])
        store.close()

    def tearDown(self):
        self.app.close()
        assert self.root.resolve().parent == self.test_base.resolve()
        shutil.rmtree(self.root)

    def request(self, method="GET", path="/v1/health", body=None, ip="203.0.113.1", remote="127.0.0.1", validate=True, **overrides):
        environ = {}
        setup_testing_defaults(environ)
        raw = json.dumps(body).encode() if body is not None else b""
        environ.update(REQUEST_METHOD=method, PATH_INFO=path, REMOTE_ADDR=remote,
                       QUERY_STRING="",
                       HTTP_X_KIF_CLIENT_IP=ip, CONTENT_LENGTH=str(len(raw)) if raw else "",
                       CONTENT_TYPE="application/json", **{"wsgi.input": io.BytesIO(raw)})
        environ.update(overrides)
        captured = {}
        def start(status, headers, exc_info=None):
            captured.update(status=int(status[:3]), headers=dict(headers))
        response = (validator(self.app) if validate else self.app)(environ, start)
        try:
            value = json.loads(b"".join(response))
        finally:
            if hasattr(response, "close"):
                response.close()
        return captured["status"], value

    def auth(self, action, username="alice", **overrides):
        return self.request("POST", "/v1/auth/" + action,
                            {"protocol": PROTOCOL, "username": username, "password": "FixturePassword9"}, **overrides)

    def test_wsgi_auth_and_full_durability(self):
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.auth("register")[0], 201)
        self.assertEqual(self.auth("login")[0], 200)
        self.assertEqual(self.app.store._db.execute("PRAGMA synchronous").fetchone()[0], 2)

    def test_config_paths_and_domain_validation(self):
        values = {key: str(value) if isinstance(value, Path) else value for key, value in vars(self.config).items()}
        path = self.root / "config.json"
        path.write_text(json.dumps(values))
        self.assertEqual(Config.load(path), self.config)
        for override in ({"domain": "bad;domain"}, {"backup_dir": str(self.data)},
                         {"data_dir": "relative"}, {"data_id_file": str(self.data / "identity")}):
            path.write_text(json.dumps({**values, **override}))
            with self.assertRaises(ValueError):
                Config.load(path)

    def test_missing_mismatched_and_duplicate_store_fail_closed(self):
        with self.assertRaises(RuntimeError):
            Application(self.config)
        self.app.close()
        atomic_bytes(self.config.data_id_file, (uuid.uuid4().hex + "\n").encode())
        with self.assertRaises(RuntimeError):
            Application(self.config)
        self.config.database.unlink()
        with self.assertRaises(RuntimeError):
            Application(self.config)
        self.assertFalse(self.config.database.exists())

    def test_missing_legacy_journal_is_not_silently_reinitialized(self):
        self.app.close()
        connection = sqlite3.connect(self.config.database)
        connection.execute("DROP TABLE operations")
        connection.close()
        with self.assertRaises(RuntimeError):
            Application(self.config)
        database = sqlite3.connect(self.config.database)
        try:
            self.assertFalse(database.execute("SELECT 1 FROM sqlite_master WHERE name='operations'").fetchone())
        finally:
            database.close()

    def test_proxy_boundary_and_invalid_input(self):
        self.assertEqual(self.request(remote="198.51.100.1")[0], 403)
        self.assertEqual(self.request(ip="203.0.113.1, 1.2.3.4")[0], 400)
        self.assertEqual(self.request(HTTP_X_FORWARDED_FOR="1.2.3.4, malicious")[0], 200)
        self.assertEqual(self.request(QUERY_STRING="secret=excluded")[0], 400)
        self.assertEqual(self.request("POST", CONTENT_LENGTH="2097153")[0], 413)
        # A conforming WSGI server normally rejects this before the app; also
        # test the adapter's defense if a nonconforming host passes it through.
        self.assertEqual(self.request("POST", CONTENT_LENGTH="-1", validate=False)[0], 411)
        self.assertEqual(self.request("POST", body={}, CONTENT_TYPE="text/plain")[0], 415)
        self.assertEqual(self.request("POST", body={}, HTTP_TRANSFER_ENCODING="chunked")[0], 400)
        self.assertEqual(self.request("POST", body={}, CONTENT_LENGTH="4")[0], 400)

    def test_real_clients_have_independent_login_budgets(self):
        with patch.object(online.hashlib, "scrypt", return_value=b"\x00" * 64):
            for i in range(60):
                self.assertEqual(self.auth("login", "unknown_" + str(i))[0], 401)
            self.assertEqual(self.auth("login", "another")[0], 429)
            self.assertEqual(self.auth("login", "another", ip="203.0.113.2")[0], 401)

    def test_slow_passwords_do_not_hold_world_database_lock_and_are_bounded(self):
        self.assertEqual(self.auth("register")[0], 201)
        entered, release = threading.Barrier(3), threading.Event()
        real = online.hashlib.scrypt
        results = []
        def slow(*args, **kwargs):
            entered.wait(timeout=5)
            release.wait(timeout=5)
            return real(*args, **kwargs)
        with patch.object(online.hashlib, "scrypt", side_effect=slow):
            threads = [threading.Thread(target=lambda: results.append(self.auth("login")[0])) for _ in range(2)]
            for thread in threads:
                thread.start()
            try:
                entered.wait(timeout=5)
                completed = threading.Event()
                health = threading.Thread(target=lambda: (self.request(), completed.set()))
                health.start()
                self.assertTrue(completed.wait(1), "Password hashing blocked unrelated service requests")
                health.join()
                self.assertEqual(self.auth("login")[0], 429)
            finally:
                release.set()
                for thread in threads:
                    thread.join(10)
        self.assertEqual(sorted(results), [200, 200])

    def test_registration_race_and_password_change_during_kdf(self):
        barrier = threading.Barrier(2)
        real = online.hashlib.scrypt
        def simultaneous(*args, **kwargs):
            barrier.wait(timeout=5)
            return real(*args, **kwargs)
        results = []
        with patch.object(online.hashlib, "scrypt", side_effect=simultaneous):
            threads = [threading.Thread(target=lambda: results.append(self.auth("register")[0])) for _ in range(2)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(10)
        self.assertEqual(sorted(results), [201, 409])
        def reset(*args, **kwargs):
            answer = real(*args, **kwargs)
            with self.app.store.connect() as db:
                db.execute("UPDATE accounts SET password_hash='changed' WHERE username='alice'")
            return answer
        with patch.object(online.hashlib, "scrypt", side_effect=reset):
            self.assertEqual(self.auth("login")[0], 401)


if __name__ == "__main__":
    unittest.main()
