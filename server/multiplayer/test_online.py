import base64
import copy
import hashlib
import json
import unittest
import uuid
from pathlib import Path

from service import Store, PROTOCOL, RULES, make_server
from test_service import FakeClock


class OnlineTests(unittest.TestCase):
    def setUp(self):
        self.database = Path(__file__).parent / "data" / "tests" / ("online_" + uuid.uuid4().hex + ".sqlite3")
        self.clock = FakeClock()
        self.store = Store(self.database, clock=self.clock)
        self.compat = {"protocol": PROTOCOL, "game_version": "test", "data_hash": "test-data", "mods_hash": "no-mods", "rules_version": RULES}
        self.alice = self.auth("register", "alice")
        self.bob = self.auth("register", "bob")
        self.session = "session_" + "a" * 24
        self.other = "session_" + "b" * 24
        self.position = {"map_id": 1, "map_hash": "a" * 64, "width": 20, "height": 15, "x": 4, "y": 5, "direction": 2, "character_id": 0, "moving": False}

    def tearDown(self):
        self.store.close()
        for suffix in ("", "-wal", "-shm"):
            Path(str(self.database) + suffix).unlink(missing_ok=True)

    def auth(self, action, username, password="password123", expected=201):
        status, result = self.store.request("POST", "/v1/auth/" + action, {"username": username, "password": password, "protocol": PROTOCOL})
        self.assertEqual(status, expected, result)
        return result

    def call(self, person, path, body, expected=200):
        status, result = self.store.request("POST", path, body, person["token"])
        self.assertEqual(status, expected, result)
        return result

    def join(self, person, session=None, compatibility=None):
        return self.call(person, "/v1/world/join", {"session_id": session or self.session, "compatibility": compatibility or self.compat})

    def sync(self, person, position=None, seq=1, after=0, session=None):
        return self.call(person, "/v1/world/sync", {"session_id": session or self.session, "seq": seq, "after": after, "position": position})["world"]

    def send(self, person, channel, text, expected=201, client_id=None):
        return self.call(person, "/v1/chat/send", {"session_id": self.session, "client_id": client_id or uuid.uuid4().hex, "channel": channel, "text": text}, expected)

    def open_cloud(self, person=None, session=None, expected=200):
        return self.call(person or self.alice, "/v1/cloud/open", {"session_id": session or self.session, "compatibility": self.compat}, expected)

    def upload(self, revision=0, upload_id=None):
        raw = b"opaque compressed safe JSON fixture"
        return {"session_id": self.session, "slot": "file-a", "revision": revision, "upload_id": upload_id or uuid.uuid4().hex,
                "save": {"format": "kif-save-json-v1", "game_version": "test", "payload": base64.b64encode(raw).decode(), "sha256": hashlib.sha256(raw).hexdigest()}}

    def test_registration_login_expiry_logout_and_no_password_storage(self):
        self.auth("register", "ALICE", expected=409)
        self.auth("login", "alice", "wrongpass", expected=401)
        result = self.auth("login", "ALICE", expected=200)
        self.assertEqual(result["identity"], self.alice["identity"])
        self.assertNotEqual(result["token"], self.alice["token"])
        self.assertEqual(self.store.request("GET", "/v1/identity", token=result["token"])[0], 200)
        with self.store.connect() as db:
            account = dict(db.execute("SELECT * FROM accounts WHERE username='alice'").fetchone())
        self.assertNotIn("password123", json.dumps(account))
        self.call(result, "/v1/auth/logout", {})
        self.assertEqual(self.store.request("GET", "/v1/identity", token=result["token"])[0], 401)
        self.clock.advance(7 * 86400 + 1)
        self.assertEqual(self.store.request("GET", "/v1/identity", token=self.alice["token"])[0], 401)

    def test_failed_login_rate_limit(self):
        for _ in range(11):
            self.auth("login", "alice", "wrongpass", expected=401)
        self.auth("login", "alice", expected=429)
        self.clock.advance(301)
        self.auth("login", "alice", expected=200)

    def test_cloud_owner_revision_idempotency_and_single_writer(self):
        self.assertEqual(self.open_cloud()["saves"], [])
        self.open_cloud(session=self.other, expected=409)
        body = self.upload()
        self.assertEqual(self.call(self.alice, "/v1/cloud/upload", body)["revision"], 1)
        self.assertEqual(self.call(self.alice, "/v1/cloud/upload", body)["revision"], 1)
        self.call(self.alice, "/v1/cloud/upload", self.upload(), 409)
        changed = copy.deepcopy(body)
        changed["revision"] = 1
        self.call(self.alice, "/v1/cloud/upload", changed, 409)
        download = self.call(self.alice, "/v1/cloud/download", {"session_id": self.session, "slot": "file-a"})
        self.assertEqual(download["save"], body["save"])
        self.open_cloud(self.bob)
        self.call(self.bob, "/v1/cloud/download", {"session_id": self.session, "slot": "file-a"}, 404)
        self.call(self.alice, "/v1/cloud/close", {"session_id": self.session})
        self.open_cloud(session=self.other)
        self.call(self.alice, "/v1/cloud/upload", body, 409)

    def test_cloud_restart_and_checksum_and_invalid_slots(self):
        self.open_cloud()
        body = self.upload()
        bad = copy.deepcopy(body)
        bad["save"]["sha256"] = "0" * 64
        self.call(self.alice, "/v1/cloud/upload", bad, 400)
        bad = copy.deepcopy(body)
        bad["slot"] = "../foo"
        self.call(self.alice, "/v1/cloud/upload", bad, 400)
        self.call(self.alice, "/v1/cloud/upload", body)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.assertEqual(self.open_cloud()["saves"][0]["revision"], 1)
        self.assertEqual(self.call(self.alice, "/v1/cloud/upload", body)["revision"], 1)
        self.clock.advance(121)
        self.call(self.alice, "/v1/cloud/heartbeat", {"session_id": self.session}, 409)

    def test_presence_map_scope_movement_hide_timeout_and_build_isolation(self):
        self.join(self.alice)
        self.join(self.bob)
        self.sync(self.alice, self.position)
        world = self.sync(self.bob, self.position)
        self.assertEqual(world["players"][0]["id"], self.alice["identity"]["id"])
        self.assertNotIn("token", json.dumps(world))
        moved = dict(self.position, x=8, direction=6)
        self.sync(self.alice, moved, seq=3)
        self.sync(self.alice, self.position, seq=2)
        self.assertEqual(self.sync(self.bob, self.position, seq=2)["players"][0]["x"], 8)
        self.assertEqual(self.sync(self.bob, dict(self.position, map_id=2), seq=3)["players"], [])
        self.sync(self.alice, None, seq=4)
        self.assertEqual(self.sync(self.bob, self.position, seq=4)["players"], [])
        self.clock.advance(21)
        self.assertEqual(self.store.request("POST", "/v1/world/sync", {"session_id": self.session, "seq": 5, "after": 0, "position": self.position}, self.alice["token"])[0], 409)
        self.join(self.alice, compatibility=dict(self.compat, data_hash="other"))
        self.join(self.bob)
        self.sync(self.alice, self.position)
        self.assertEqual(self.sync(self.bob, self.position)["players"], [])

    def test_chat_map_world_unicode_retries_and_validation(self):
        self.join(self.alice)
        self.join(self.bob)
        self.sync(self.alice, self.position)
        self.sync(self.bob, dict(self.position, map_id=2))
        message_id = uuid.uuid4().hex
        result = self.send(self.alice, "map", "你好，地图😀", client_id=message_id)
        self.assertEqual(self.send(self.alice, "map", "你好，地图😀", expected=200, client_id=message_id), result)
        self.send(self.alice, "map", "修改", expected=409, client_id=message_id)
        self.send(self.alice, "world", "世界频道")
        messages = self.sync(self.bob, dict(self.position, map_id=2), seq=2)["messages"]
        self.assertEqual([m["text"] for m in messages], ["世界频道"])
        messages = self.sync(self.bob, self.position, seq=3)["messages"]
        self.assertEqual([m["text"] for m in messages], ["你好，地图😀", "世界频道"])
        self.send(self.alice, "world", "\\v[1]<c=red>纯文字</c>")
        self.send(self.alice, "world", "太快", expected=429)
        self.send(self.bob, "world", "\n", expected=400)
        self.send(self.bob, "world", "a" * 201, expected=400)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM operations").fetchone()[0], 0)

    def test_chat_cursor_pages_without_dropping_messages(self):
        self.join(self.alice)
        self.join(self.bob)
        self.sync(self.bob, self.position)
        first = self.send(self.alice, "world", "first")["message"]["id"]
        for index in range(55):
            self.clock.advance(1.1)
            self.join(self.alice)
            self.sync(self.alice, self.position, seq=index + 1)
            self.send(self.alice, "world", str(index))
        self.join(self.bob)
        page = self.sync(self.bob, self.position, seq=2, after=first)
        self.assertEqual(len(page["messages"]), 50)
        page2 = self.sync(self.bob, self.position, seq=3, after=page["cursor"])
        self.assertEqual(len(page2["messages"]), 5)

    def test_invalid_position_and_second_device_do_not_overwrite_presence(self):
        self.join(self.alice)
        self.call(self.alice, "/v1/world/join", {"session_id": self.other, "compatibility": self.compat}, 409)
        self.call(self.alice, "/v1/world/sync", {"session_id": self.session, "seq": 1, "after": 0, "position": dict(self.position, x=20)}, 400)
        self.call(self.alice, "/v1/world/leave", {"session_id": self.other}, 409)
        self.assertEqual(self.store.request("POST", "/v1/world/join", {"session_id": self.session, "compatibility": self.compat}, "bad")[0], 401)

    def test_chunked_cloud_upload_resumes_and_commits_exactly_once(self):
        self.open_cloud()
        body = self.upload()
        raw_bytes = b"cloud json fixture" * 6000
        body["save"]["payload"] = base64.b64encode(raw_bytes).decode()
        body["save"]["sha256"] = hashlib.sha256(raw_bytes).hexdigest()
        raw = json.dumps({key: value for key, value in body.items() if key != "session_id"}, ensure_ascii=False).encode()
        parts = [raw[i:i + 16384] for i in range(0, len(raw), 16384)]
        checksum = hashlib.sha256(raw).hexdigest()
        chunks = [{"session_id": self.session, "upload_id": body["upload_id"], "index": i, "total": len(parts), "sha256": checksum, "data": base64.b64encode(part).decode()} for i, part in enumerate(parts)]
        first = self.call(self.alice, "/v1/cloud/chunk", chunks[0])
        self.assertEqual(first["next_index"], 1)
        self.call(self.alice, "/v1/cloud/chunk", chunks[1])
        self.call(self.alice, "/v1/cloud/close", {"session_id": self.session})
        self.open_cloud(session=self.other)
        for chunk in chunks:
            chunk["session_id"] = self.other
        self.assertEqual(self.call(self.alice, "/v1/cloud/chunk", chunks[0])["next_index"], 2)
        for chunk in chunks[2:]:
            result = self.call(self.alice, "/v1/cloud/chunk", chunk)
        self.assertEqual(result["revision"], 1)
        self.assertEqual(self.call(self.alice, "/v1/cloud/chunk", chunks[0]), result)
        bad = dict(chunks[0], sha256="0" * 64)
        self.call(self.alice, "/v1/cloud/chunk", bad, 409)
        received = self.call(self.alice, "/v1/cloud/download", {"session_id": self.other, "slot": "file-a"})
        self.assertEqual(received["save"], body["save"])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM cloud_chunks").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
