import base64
from contextlib import closing
import copy
import hashlib
import io
import json
import sqlite3
from pathlib import Path
import shutil
import threading
import unittest
import uuid
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import zlib

from admin_data import create_administrator, day_key, summarize_save, totp
from service import Store, PROTOCOL, RULES, make_server
from test_service import FakeClock


def save_fixture(money=12345):
    graph = {"version": 1, "root": {"ref": 0}, "nodes": [
        {"type": "hash", "items": [[{"symbol": "player"}, {"ref": 1}]]},
        {"type": "object", "class": "Player", "ivars": {"@name": {"ref": 2}, "@id": 7,
          "@money": money, "@party": {"ref": 3}, "@badges": {"ref": 4}}},
        {"type": "string", "bytes": base64.b64encode("测试训练师".encode()).decode(), "encoding": "UTF-8"},
        {"type": "array", "items": []}, {"type": "array", "items": [True, False, True]}]}
    raw = zlib.compress(json.dumps(graph).encode())
    return {"format": "kif-save-json-v1", "game_version": "test", "payload": base64.b64encode(raw).decode(), "sha256": hashlib.sha256(raw).hexdigest()}


class AdminTests(unittest.TestCase):
    def setUp(self):
        base = Path(__file__).resolve().parents[2] / "temp/admin-tests"
        base.mkdir(parents=True, exist_ok=True)
        self.directory = base / uuid.uuid4().hex
        self.directory.mkdir()
        self.database = self.directory / "game.sqlite3"
        self.clock = FakeClock()
        self.store = Store(self.database, clock=self.clock)
        self.secret = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
        self.password = "AdministratorFixture123"
        with self.store.connect() as db:
            for username, role in (("operator", "admin"), ("reader", "observer"), ("moderator", "gm")):
                create_administrator(db, username, self.password, role, self.secret, now=self.clock())
        self.alice = self.register("alice")
        self.admin = self.login()
        self.owner = self.alice["identity"]["id"]
        self.compat = {"protocol": PROTOCOL, "game_version": "test", "data_hash": "test-data", "mods_hash": "none", "rules_version": RULES}
        self.session = "session_" + "a" * 24

    def tearDown(self):
        self.store.close()
        assert self.directory.resolve().parent == (Path(__file__).resolve().parents[2] / "temp/admin-tests").resolve()
        shutil.rmtree(self.directory)

    def register(self, username):
        status, result = self.store.request("POST", "/v1/auth/register", {"username": username, "password": "PlayerPassword123", "protocol": PROTOCOL})
        self.assertEqual(status, 201, result)
        return result

    def login(self, username="operator", expected=200, **overrides):
        body = {"username": username, "password": self.password, "otp": totp(self.secret, self.clock())}
        body.update(overrides)
        status, result = self.store.request("POST", "/admin/v1/login", body)
        self.assertEqual(status, expected, result)
        return result

    def request(self, path, body=None, expected=200, person=None):
        token = (person or self.admin)["token"]
        status, result = self.store.request("GET" if body is None else "POST", "/admin/v1/" + path, body, token)
        self.assertEqual(status, expected, result)
        return result

    def game(self, path, body, expected=200, person=None):
        status, result = self.store.request("POST", "/v1/" + path, body, (person or self.alice)["token"])
        self.assertEqual(status, expected, result)
        return result

    def command(self, action, expected_version=0, **kwargs):
        body = {"id": uuid.uuid4().hex, "action": action, "target": self.owner,
                "reason": "Support ticket 100", "expected_version": expected_version}
        body.update(kwargs)
        return body

    def test_auth_totp_replay_expiry_and_player_credentials_are_separate(self):
        self.login(expected=401)
        self.request("players", person=self.alice, expected=401)
        self.assertEqual(self.store.request("GET", "/v1/identity", token=self.admin["token"])[0], 401)
        self.login("reader", otp="000000", expected=401)
        self.clock.advance(31)
        second = self.login()
        self.assertNotEqual(second["token"], self.admin["token"])
        self.request("logout", {}, person=second)
        self.request("me", person=second, expected=401)
        self.clock.advance(3601)
        self.request("me", expected=401)

    def test_failed_login_budget_survives_restart_and_no_secrets_in_audit(self):
        for _ in range(9):
            self.login("missing", password="wrong", expected=401)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.login("missing", password="wrong", expected=401)
        self.login("missing", expected=429)
        with self.store.connect() as db:
            audit = " ".join(row[0] for row in db.execute("SELECT document FROM admin_audit"))
            stored = " ".join(row[0] for row in db.execute("SELECT token_hash FROM admin_sessions"))
        self.assertNotIn(self.password, audit)
        self.assertNotIn(self.secret, audit)
        self.assertNotIn(self.admin["token"], stored)

    def test_permissions_queries_search_pagination_and_sensitive_columns(self):
        reader = self.login("reader")
        result = self.request("players?q=ALICE", person=reader)
        self.assertEqual(len(result["players"]), 1)
        self.assertEqual(result["players"][0]["username"], "alice")
        self.register("bob")
        first = self.request("players?limit=1")
        second = self.request("players?limit=1&after=" + first["next_cursor"])
        self.assertNotEqual(first["players"][0]["id"], second["players"][0]["id"])
        detail = self.request("players/" + self.owner)
        private = json.dumps(detail)
        for value in ("password_hash", "recovery_hash", "token_hash", self.alice["token"]):
            self.assertNotIn(value, private)
        self.request("commands", self.command("ban"), expected=403, person=reader)
        self.request("commands", self.command("note"), expected=403, person=reader)
        self.request("players?limit=1000", expected=400)
        self.request("players?q=alice&q=bob", expected=400)
        self.request("players?unknown=x", expected=400)
        self.request("players/%00", expected=400)

    def test_ban_blocks_login_all_tokens_recovery_and_cloud_chunks(self):
        self.game("cloud/open", {"session_id": self.session, "compatibility": self.compat})
        self.game("world/join", {"session_id": self.session, "compatibility": self.compat})
        body = self.command("ban", duration_seconds=60)
        first = self.request("commands", body)
        self.assertEqual(first["controls"]["version"], 1)
        self.assertEqual(self.request("commands", body), first)
        self.request("commands", dict(body, reason="Changed reason"), expected=409)
        self.game("world/sync", {}, expected=401)
        self.game("cloud/chunk", {}, expected=401)
        result = self.store.request("POST", "/v1/auth/login", {"username": "alice", "password": "PlayerPassword123", "protocol": PROTOCOL})
        self.assertEqual(result[0], 403)
        self.assertEqual(result[1]["error"]["code"], "account_banned")
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM cloud_leases WHERE owner=?", (self.owner,)).fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM world_presence WHERE owner=?", (self.owner,)).fetchone()[0], 0)
            count = db.execute("SELECT count(*) FROM admin_audit WHERE action='ban'").fetchone()[0]
        self.assertEqual(count, 1)
        self.clock.advance(61)
        self.assertEqual(self.store.request("POST", "/v1/auth/login", {"username": "alice", "password": "PlayerPassword123", "protocol": PROTOCOL})[0], 200)
        self.game("cloud/upload", {}, expected=401)

    def test_legacy_recovery_cannot_bypass_ban(self):
        status, legacy = self.store.request("POST", "/v1/identities", {"nickname": "Legacy", "protocol": PROTOCOL})
        self.assertEqual(status, 201)
        body = self.command("ban", target=legacy["identity"]["id"])
        self.request("commands", body)
        status, response = self.store.request("POST", "/v1/identities/recover", {"recovery_code": legacy["recovery_code"], "protocol": PROTOCOL})
        self.assertEqual(status, 403, response)
        self.request("commands", self.command("unban", target=legacy["identity"]["id"], expected_version=1))
        self.assertEqual(self.store.request("POST", "/v1/identities/recover", {"recovery_code": legacy["recovery_code"], "protocol": PROTOCOL})[0], 200)

    def test_mute_checks_before_duplicate_message_and_kick_allows_fresh_login(self):
        self.game("world/join", {"session_id": self.session, "compatibility": self.compat})
        chat = {"session_id": self.session, "client_id": uuid.uuid4().hex, "channel": "world", "text": "Hello"}
        self.game("chat/send", chat, expected=201)
        self.request("commands", self.command("mute", duration_seconds=60))
        self.game("chat/send", chat, expected=403)
        self.request("commands", self.command("unmute", expected_version=0), expected=409)
        self.request("commands", self.command("unmute", expected_version=1))
        self.game("chat/send", chat)
        self.request("commands", self.command("kick", expected_version=2))
        self.game("world/join", {"session_id": self.session, "compatibility": self.compat}, expected=401)
        self.assertEqual(self.store.request("POST", "/v1/auth/login", {"username": "alice", "password": "PlayerPassword123", "protocol": PROTOCOL})[0], 200)

    def test_online_active_accounts_distinct_and_restart_history(self):
        self.game("world/join", {"session_id": self.session, "compatibility": self.compat})
        for seq in range(1, 4):
            self.clock.advance(2)
            self.game("world/sync", {"session_id": self.session, "seq": seq, "position": None, "after": 0})
        report = self.request("overview")
        self.assertEqual((report["online"], report["dau"], report["mau"]), (1, 1, 1))
        self.assertEqual(report["activity"][0]["observed_seconds"], 6)
        self.clock.advance(21)
        self.assertEqual(self.request("overview")["online"], 0)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        report = self.request("overview")
        self.assertEqual((report["online"], report["dau"]), (0, 1))
        self.assertIsNone(report["mainline_gold"]["value"])
        self.assertEqual(day_key(0), "1970-01-01")

    def test_save_summaries_are_revision_bound_and_invalid_is_not_zero(self):
        self.game("cloud/open", {"session_id": self.session, "compatibility": self.compat})
        upload = {"session_id": self.session, "slot": "file-a", "revision": 0, "upload_id": uuid.uuid4().hex, "save": save_fixture()}
        self.game("cloud/upload", upload)
        self.assertEqual(self.request("players/" + self.owner)["saves"][0]["summary"]["status"], "pending")
        self.store.refresh_admin_summaries()
        summary = self.request("players/" + self.owner)["saves"][0]["summary"]
        self.assertEqual(summary["money"], 12345)
        self.assertEqual(summary["badges"], 2)
        self.assertEqual(summary["trainer_name"], "测试训练师")
        upload.update(revision=1, upload_id=uuid.uuid4().hex, save=save_fixture(999))
        self.game("cloud/upload", upload)
        self.assertEqual(self.request("players/" + self.owner)["saves"][0]["summary"]["status"], "pending")
        self.store.refresh_admin_summaries()
        self.assertEqual(self.request("players/" + self.owner)["saves"][0]["summary"]["money"], 999)
        upload.update(revision=2, upload_id=uuid.uuid4().hex, save=save_fixture(-1))
        self.game("cloud/upload", upload)
        self.store.refresh_admin_summaries()
        summary = self.request("players/" + self.owner)["saves"][0]["summary"]
        self.assertEqual(summary["status"], "invalid")
        self.assertIsNone(summary["money"])

    def test_summary_rejects_bombs_bad_references_and_executable_classes(self):
        valid = save_fixture()
        raw = zlib.compress(b" " * (32 * 1024 * 1024 + 1))
        bomb = dict(valid, payload=base64.b64encode(raw).decode(), sha256=hashlib.sha256(raw).hexdigest())
        with self.assertRaises(ValueError):
            summarize_save(bomb)
        graph = json.loads(zlib.decompress(base64.b64decode(valid["payload"])))
        for mutation in (lambda value: value.update(root={"ref": True}),
                         lambda value: value["nodes"][1].update({"class": "ArbitraryCode"})):
            bad = copy.deepcopy(graph)
            mutation(bad)
            raw = zlib.compress(json.dumps(bad).encode())
            with self.assertRaises(ValueError):
                summarize_save(dict(valid, payload=base64.b64encode(raw).decode(), sha256=hashlib.sha256(raw).hexdigest()))

    def test_audit_and_command_write_failure_roll_back_player_state(self):
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER fail_audit BEFORE INSERT ON admin_audit WHEN NEW.action='ban' BEGIN SELECT RAISE(ABORT,'audit unavailable'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.request("commands", self.command("ban"))
        self.assertEqual(self.store.request("GET", "/v1/identity", token=self.alice["token"])[0], 200)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM admin_commands").fetchone()[0], 0)

    def test_concurrent_commands_with_same_version_only_one_commits(self):
        results = []
        def run(action):
            results.append(self.store.request("POST", "/admin/v1/commands", self.command(action), self.admin["token"])[0])
        threads = [threading.Thread(target=run, args=(action,)) for action in ("mute", "ban")]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(sorted(results), [200, 409])

    def test_real_http_static_security_headers_and_admin_query_routing(self):
        server = make_server("127.0.0.1", 0, self.store)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        address = "http://127.0.0.1:" + str(server.server_port)
        try:
            with urlopen(address + "/admin/") as response:
                self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])
                self.assertIn("运营管理后台", response.read().decode())
            with urlopen(Request(address + "/admin/v1/players?q=alice", headers={"Authorization": "Bearer " + self.admin["token"]})) as response:
                self.assertEqual(json.load(response)["players"][0]["username"], "alice")
            with self.assertRaises(HTTPError) as error:
                urlopen(address + "/v1/health?x=1")
            self.assertEqual(error.exception.code, 400)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_production_wsgi_admin_queries_and_static_use_same_store(self):
        from production import Application, RateBudget
        # Exercise the real adapter against this fixture's existing Store;
        # lifecycle fencing itself is covered by test_production.py.
        app = object.__new__(Application)
        app.store = self.store
        app.closed = False
        app.capacity = threading.BoundedSemaphore(8)
        app.budget = RateBudget()
        environ = {"REQUEST_METHOD": "GET", "PATH_INFO": "/admin/v1/players", "QUERY_STRING": "q=alice",
                   "REMOTE_ADDR": "127.0.0.1", "HTTP_X_KIF_CLIENT_IP": "203.0.113.1",
                   "HTTP_AUTHORIZATION": "Bearer " + self.admin["token"], "CONTENT_LENGTH": "", "wsgi.input": io.BytesIO()}
        captured = {}
        def start(status, headers):
            captured["status"] = status
        data = json.loads(b"".join(app(environ, start)))
        self.assertEqual(captured["status"], "200 OK")
        self.assertEqual(data["players"][0]["username"], "alice")
        environ.update(PATH_INFO="/admin/", QUERY_STRING="")
        self.assertIn("运营管理后台", b"".join(app(environ, start)).decode())

    def test_missing_admin_journal_is_not_silently_recreated(self):
        self.store.close()
        with closing(sqlite3.connect(self.database)) as db:
            db.execute("DROP TABLE admin_audit")
            db.commit()
        with self.assertRaisesRegex(RuntimeError, "restore its journals"):
            Store(self.database, clock=self.clock)
        with closing(sqlite3.connect(self.database)) as db:
            self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='admin_audit'").fetchone())

    def test_private_hosted_asset_details_are_audited_against_current_owner(self):
        granted = self.game("collections/starter", {"request_id": uuid.uuid4().hex, "catalog_version": 1}, expected=201)
        result = self.request("assets/" + granted["asset"]["id"])
        self.assertEqual(result["current_owner"], self.owner)
        self.assertIn("iv", result["asset"]["snapshot"])
        history = self.request("audit?target=" + self.owner)["entries"]
        self.assertTrue(any(entry["action"] == "read" and entry["detail"].get("path", "").startswith("/admin/v1/assets/") for entry in history))

    def test_old_summary_projection_is_rebuilt_after_extractor_upgrade(self):
        self.game("cloud/open", {"session_id": self.session, "compatibility": self.compat})
        self.game("cloud/upload", {"session_id": self.session, "slot": "file-a", "revision": 0,
            "upload_id": uuid.uuid4().hex, "save": save_fixture()})
        self.store.refresh_admin_summaries()
        with self.store.connect() as db:
            db.execute("UPDATE save_summaries SET document=json_set(document,'$.extractor_version',1,'$.money',1)")
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.assertEqual(self.request("players/" + self.owner)["saves"][0]["summary"]["status"], "pending")
        self.store.refresh_admin_summaries()
        summary = self.request("players/" + self.owner)["saves"][0]["summary"]
        self.assertEqual((summary["extractor_version"], summary["money"]), (2, 12345))


if __name__ == "__main__":
    unittest.main()
