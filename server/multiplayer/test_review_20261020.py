"""Fresh CR reproductions. Every identity/database is isolated test data."""
import copy
import json
import sqlite3
import subprocess
import sys
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

import test_service as base
import test_v2 as v2
import test_v3 as v3
from service import PROTOCOL, Store, database_instance_lock, make_server


class ReviewTests(unittest.TestCase):
    setUp = v3.V3Tests.setUp
    tearDown = v3.V3Tests.tearDown
    identity = base.ServiceTests.identity
    call = base.ServiceTests.call
    engine_request = base.ServiceTests.engine_request
    room = base.ServiceTests.room
    prepared_room = base.ServiceTests.prepared_room
    battle = base.ServiceTests.battle
    resolve = base.ServiceTests.resolve
    command = base.ServiceTests.command
    ack = base.ServiceTests.ack
    boss = v2.V2Tests.boss
    trade = v2.V2Tests.trade
    offers = v2.V2Tests.offers
    confirm = v2.V2Tests.confirm
    starter = v3.V3Tests.starter
    hosted_deposit = v3.V3Tests.hosted_deposit
    rental = v3.V3Tests.rental
    pick = v3.V3Tests.pick
    route = v3.V3Tests.route
    route_start = v3.V3Tests.route_start
    restart = v3.V3Tests.restart

    def raw(self, person, method, path, body=None):
        if method == "POST":
            self.request_seq += 1
            body = copy.deepcopy(body or {})
            body.setdefault("request_id", "review_%012d" % self.request_seq)
        return self.store.request(method, path, body, person["token"])

    def private_battle(self):
        with self.store.connect() as db:
            return self.store.battle(db, self.battle_id)

    def unclaimed(self):
        self.boss()
        with self.store.connect() as db:
            battle = self.store.battle(db, self.battle_id)
            battle.update({"turn": 0, "phase": "initializing", "commands": {}, "state": {}, "updates": [], "acks": [], "deadline": None, "authority_id": None, "authority_last_seen": self.clock()})
            self.store.save_battle(db, battle)

    def claim(self, authority, person=None, **extra):
        return self.raw(person or self.alice, "POST", self.battle_base + "/authority", {"authority_id": authority, **extra})

    def test_duplicate_cli_bind_failure_does_not_recover_live_database(self):
        self.battle()
        listener = make_server("127.0.0.1", 0, self.store)
        try:
            child = subprocess.run([sys.executable, str(Path(__file__).with_name("service.py")), "--host", "127.0.0.1", "--port", str(listener.server_port), "--database", str(self.database)], capture_output=True, timeout=10)
            self.assertNotEqual(child.returncode, 0)
            self.assertEqual(self.private_battle()["status"], "active")
            self.assertIsNone(self.private_battle()["result"])
        finally:
            listener.server_close()

    def test_same_port_different_database_does_not_create_the_database(self):
        listener = make_server("127.0.0.1", 0, self.store)
        new_database = self.database.with_suffix(".uncreated.sqlite3")
        try:
            child = subprocess.run([sys.executable, str(Path(__file__).with_name("service.py")), "--host", "127.0.0.1", "--port", str(listener.server_port), "--database", str(new_database)], capture_output=True, timeout=10)
            self.assertNotEqual(child.returncode, 0)
            self.assertFalse(new_database.exists())
            self.assertFalse(Path(str(new_database) + ".instance.lock").exists())
        finally:
            listener.server_close()

    def test_same_database_different_port_cannot_recover_live_battle(self):
        self.battle()
        lockfile = Path(str(self.database.resolve()) + ".instance.lock")
        try:
            with database_instance_lock(self.database):
                child = subprocess.run([sys.executable, str(Path(__file__).with_name("service.py")), "--port", "0", "--database", str(self.database)], capture_output=True, timeout=10)
                self.assertNotEqual(child.returncode, 0)
                self.assertIn(b"Database is already in use", child.stderr)
                self.assertEqual(self.private_battle()["status"], "active")
                self.assertIsNone(self.private_battle()["result"])
            # Normal termination releases the lock without deleting its inode.
            with database_instance_lock(self.database):
                self.assertEqual(self.private_battle()["status"], "active")
        finally:
            lockfile.unlink(missing_ok=True)

    def test_initializer_rejects_a_live_database_before_recovery(self):
        self.battle()
        lockfile = Path(str(self.database.resolve()) + ".instance.lock")
        try:
            with database_instance_lock(self.database):
                child = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(Path(__file__).with_name("init-db.ps1")), "-Database", str(self.database), "-PythonExecutable", sys.executable], capture_output=True, timeout=15)
                self.assertNotEqual(child.returncode, 0)
                self.assertIn(b"Database is already in use", child.stderr)
                self.assertEqual(self.private_battle()["status"], "active")
        finally:
            lockfile.unlink(missing_ok=True)

    def test_authority_first_claim_race_has_one_winner(self):
        self.unclaimed()
        barrier = threading.Barrier(2)

        def claim(index):
            barrier.wait()
            return self.store.request("POST", self.battle_base + "/authority", {"request_id": "claim_race_%012d" % index, "authority_id": "engine_race_%012d" % index}, self.alice["token"])

        with ThreadPoolExecutor(2) as pool:
            responses = list(pool.map(claim, (1, 2)))
        self.assertEqual(sorted(status for status, _ in responses), [200, 409])
        self.assertIn(self.private_battle()["authority_id"], ("engine_race_000000000001", "engine_race_000000000002"))
        self.assertEqual(self.private_battle()["status"], "active")

    def test_null_or_malformed_authority_is_not_a_claim(self):
        self.unclaimed()
        for invalid in (None, True, "short", "path/engine_instance_123456"):
            self.assertEqual(self.claim(invalid)[0], 400)
            self.assertIsNone(self.private_battle()["authority_id"])

    def test_authority_conflict_cannot_publish_or_abort_first_engine(self):
        self.unclaimed()
        first, second = "engine_original_123456", "engine_duplicate_12345"
        self.assertEqual(self.claim(first)[0], 200)
        self.assertEqual(self.claim(first)[0], 200)
        self.assertEqual(self.claim(second)[1]["error"]["code"], "authority_conflict")
        self.assertEqual(self.claim(second, self.bob)[0], 403)
        for action, payload in (("abort", {}), ("resolve", {"turn": 0, "state": self.state, "digest": "a" * 64, "decision": 1}), ("commands", {"turn": 0, "command": {"action": "surrender"}})):
            status, response = self.raw(self.alice, "POST", self.battle_base + "/" + action, {"authority_id": second, **payload})
            self.assertEqual((status, response["error"]["code"]), (409, "authority_conflict"))
        self.assertEqual(self.raw(self.alice, "POST", self.battle_base + "/abort", {})[0], 409)
        self.assertEqual((self.private_battle()["status"], self.private_battle()["updates"]), ("active", []))
        status, result = self.raw(self.alice, "POST", self.battle_base + "/resolve", {"authority_id": first, "turn": 0, "state": self.state, "digest": "a" * 64, "decision": 0})
        self.assertEqual(status, 200, result)

    def test_plain_host_identity_get_does_not_impersonate_engine_presence(self):
        self.boss()
        for _ in range(15):
            self.clock.advance(5)
            self.raw(self.alice, "GET", self.battle_base)
            status, response = self.raw(self.bob, "GET", self.battle_base)
            self.assertEqual(status, 200)
        self.assertEqual(response["battle"]["status"], "abnormal")
        self.assertEqual(response["battle"]["result"]["reason"], "host_disconnected")

    def test_engine_heartbeat_is_transient_private_and_never_refills_allowance(self):
        self.boss()
        authority = self.private_battle()["authority_id"]
        self.clock.advance(15)
        self.raw(self.bob, "GET", self.battle_base)
        before = self.private_battle()["presence"][self.players[0]]["remaining"]
        with self.store.connect() as db:
            operations = db.execute("SELECT COUNT(*) FROM operations").fetchone()[0]
        for _ in range(3):
            self.clock.advance(2)
            status, response = self.store.request("POST", self.battle_base + "/heartbeat", {"authority_id": authority}, self.alice["token"])
            self.assertEqual(status, 200)
            self.assertNotIn(authority, json.dumps(response))
            self.assertNotIn("authority_id", json.dumps(response))
            self.raw(self.bob, "GET", self.battle_base)
        # The first heartbeat at t+17 consumes the two newly absent seconds;
        # subsequent live heartbeats do not reset or consume its allowance.
        self.assertEqual(self.private_battle()["presence"][self.players[0]]["remaining"], before - 2)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM operations").fetchone()[0], operations)
        self.assertEqual(self.raw(self.bob, "POST", self.battle_base + "/heartbeat", {"authority_id": authority})[0], 409)

    def test_authority_state_is_not_in_room_guest_replay_or_operation_projection(self):
        self.boss()
        authority = self.private_battle()["authority_id"]
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        self.resolve(1, 1)
        replay = self.call(self.alice, "POST", "/v1/replays", {"battle_id": self.battle_id}, 201)["replay"]
        self.call(self.alice, "POST", "/v1/replays/" + replay["id"] + "/consent", {"consent": True})
        self.call(self.bob, "POST", "/v1/replays/" + replay["id"] + "/consent", {"consent": True})
        self.call(self.alice, "POST", "/v1/replays/" + replay["id"] + "/publish", {"visibility": "unlisted"})
        downloaded = self.call(self.eve, "POST", "/v1/replays/" + replay["id"] + "/download", {"compatibility": self.compat})
        self.assertNotIn(authority, json.dumps(downloaded))
        self.assertNotIn(authority, json.dumps(self.raw(self.bob, "GET", self.battle_base)[1]))
        self.assertNotIn(authority, json.dumps(self.call(self.bob, "GET", self.base)))
        with self.store.connect() as db:
            self.assertTrue(all(authority not in row[0] for row in db.execute("SELECT response FROM operations")))

    def test_service_restart_cannot_claim_a_replacement_authority(self):
        self.boss()
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        status, response = self.claim("new_engine_after_restart")
        self.assertEqual((status, response["error"]["code"]), (409, "battle_finished"))
        self.assertEqual(self.private_battle()["result"]["reason"], "service_restart")

    def test_ai_playback_takeover_does_not_extend_next_phase_deadline(self):
        self.boss()
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        self.assertEqual(self.resolve(1)["phase"], "playback")
        for _ in range(20):
            self.clock.advance(5)
            battle = self.call(self.alice, "GET", self.battle_base)["battle"]
            if battle["turn"] == 2:
                self.assertEqual(battle["deadline"], self.clock() + 60)
                self.assertIn(self.players[1], battle["ai_controlled_ids"])
                break
        else:
            self.fail("Guest was not taken over at the playback boundary")

    def test_ai_takeover_pauses_only_the_remaining_disconnect_allowance(self):
        self.boss()
        for seconds in [4] * 16 + [6]:
            self.clock.advance(seconds)
            battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertIn(self.players[1], battle["ai_controlled_ids"])
        self.assertEqual(battle["deadline"], 1700000000 + 60 + 60)

    def test_expired_action_timer_is_not_forgiven_by_a_later_disconnect(self):
        self.battle()
        for seconds in [5] * 11 + [4]:
            self.clock.advance(seconds)
            self.call(self.bob, "GET", self.battle_base)
            self.call(self.alice, "GET", self.battle_base)
        self.clock.advance(9)
        self.call(self.bob, "GET", self.battle_base)
        result = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(result["phase"], "locked")
        self.assertEqual(self.private_battle()["timeouts"], {owner: 1 for owner in self.players})

    def test_rejected_late_command_keeps_timeout_and_queryable_error(self):
        self.battle()
        for _ in range(11):
            self.clock.advance(5)
            self.call(self.alice, "GET", self.battle_base)
            self.call(self.bob, "GET", self.battle_base)
        self.clock.advance(5)
        payload = {"request_id": "late_rejected_command", "turn": 1, "command": {"action": "move", "move_index": 0, "target": 0}}
        status, response = self.store.request("POST", self.battle_base + "/commands", payload, self.bob["token"])
        self.assertEqual((status, response["error"]["code"]), (409, "turn_locked"))
        self.assertEqual(self.private_battle()["phase"], "locked")
        self.assertEqual(self.private_battle()["timeouts"], {owner: 1 for owner in self.players})
        self.assertEqual(self.raw(self.bob, "GET", "/v1/operations/late_rejected_command")[1]["http_status"], 409)
        self.assertEqual((status, response), self.store.request("POST", self.battle_base + "/commands", payload, self.bob["token"]))

    def test_leaving_rental_draft_cancels_before_immediate_rejoin(self):
        room = self.rental()
        old_draft = room["draft"]["id"]
        left = self.call(self.bob, "POST", self.base + "/leave", {})["room"]
        self.assertEqual(left["draft"]["status"], "cancelled")
        self.assertEqual(left["draft"]["reason"], "member_left")
        self.call(self.bob, "POST", self.base + "/join", {"compatibility": self.compat})
        newer = self.call(self.alice, "POST", self.base + "/draft", {})["room"]
        self.assertNotEqual(newer["draft"]["id"], old_draft)
        self.assertEqual(newer["draft"]["pick_index"], 0)

    def test_rental_overdue_pick_is_not_forgiven_by_later_reconnection(self):
        room = self.rental()
        for seconds in [5] * 5 + [4]:
            self.clock.advance(seconds)
            self.call(self.alice, "GET", self.base)
            self.call(self.bob, "GET", self.base)
        actor = self.alice if room["draft"]["next_owner_id"] == self.alice["identity"]["id"] else self.bob
        other = self.bob if actor is self.alice else self.alice
        self.clock.advance(8)
        self.call(other, "GET", self.base)
        self.clock.advance(1)
        error = self.call(actor, "POST", self.base + "/pick", {"draft_id": room["draft"]["id"], "pick_index": 0, "slot": 5}, 409)
        self.assertEqual(error["error"]["code"], "pick_mismatch")
        draft = self.call(actor, "GET", self.base)["room"]["draft"]
        self.assertEqual(draft["picks"][actor["identity"]["id"]], [0])
        self.assertEqual(draft["pick_index"], 1)

    def test_owned_room_recovery_lists_only_members_and_public_fields(self):
        self.prepared_room()
        expected_code = self.code
        hidden = self.call(self.eve, "POST", "/v1/rooms", {"name": "Hidden", "compatibility": self.compat}, 201)["room"]
        for person in (self.alice, self.bob):
            rooms = self.call(person, "GET", "/v1/rooms")["rooms"]
            self.assertEqual([room["code"] for room in rooms], [expected_code])
            encoded = json.dumps(rooms)
            for private in ("selected\"", "moves\"", "PrivateOT", "iv\"", "compatibility\"", hidden["code"]):
                self.assertNotIn(private, encoded)
        self.assertEqual([room["code"] for room in self.call(self.eve, "GET", "/v1/rooms")["rooms"]], [hidden["code"]])
        self.assertEqual(self.store.request("GET", "/v1/rooms")[0], 401)
        self.call(self.bob, "POST", self.base + "/leave", {})
        self.assertEqual(self.call(self.bob, "GET", "/v1/rooms")["rooms"], [])

    def test_owned_room_recovery_filters_closed_expired_and_caps_recent_first(self):
        self.room()
        with self.store.connect() as db:
            original = self.store.room(db, self.code)
            db.execute("DELETE FROM rooms")  # Only this isolated fixture database.
            for index in range(102):
                clone = copy.deepcopy(original)
                clone.update({"code": "%06X" % index, "name": "clone %d" % index})
                self.clock.advance(1)
                self.store.save_room(db, clone)
            closed = copy.deepcopy(original)
            closed.update({"code": "FFFFFE", "status": "closed"})
            self.store.save_room(db, closed)
            expired = copy.deepcopy(original)
            expired.update({"code": "FFFFFF", "updated_at": self.clock() - 86401})
            db.execute("INSERT INTO rooms VALUES(?,?,?)", (expired["code"], json.dumps(expired), self.clock() + 1))
        rooms = self.call(self.alice, "GET", "/v1/rooms")["rooms"]
        self.assertEqual(len(rooms), 100)
        self.assertEqual([room["code"] for room in rooms], ["%06X" % index for index in range(101, 1, -1)])
        with self.store.connect() as db:
            self.assertEqual(self.store.room(db, "FFFFFF")["status"], "closed")

    def test_protocol_one_identity_recovery_and_room_are_not_upgraded_silently(self):
        self.assertEqual(PROTOCOL, 2)
        status, response = self.store.request("POST", "/v1/identities", {"nickname": "old", "protocol": 1})
        self.assertEqual((status, response["error"]["code"]), (409, "protocol_mismatch"))
        status, response = self.store.request("POST", "/v1/identities/recover", {"recovery_code": self.alice["recovery_code"], "protocol": 1})
        self.assertEqual((status, response["error"]["code"]), (409, "protocol_mismatch"))
        self.call(self.alice, "GET", "/v1/identity")
        self.room()
        with self.store.connect() as db:
            room = self.store.room(db, self.code)
            room["compatibility"]["protocol"] = 1
            self.store.save_room(db, room)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.assertEqual(self.call(self.alice, "GET", self.base)["room"]["status"], "closed")

    def test_protocol_upgrade_abandons_unfinished_route_once_without_losing_history(self):
        dungeon = self.route()
        self.route_start()
        with self.store.connect() as db:
            route = self.store.dungeon(db, dungeon["id"], self.players[0])
            route["history"] = [{"evidence": "previous confirmed node"}]
            self.store.save_dungeon(db, route)
            before_states = copy.deepcopy(route["team_states"])
            room = self.store.room(db, self.code)
            room["compatibility"]["protocol"] = 1
            self.store.save_room(db, room)
        self.restart()
        current = self.call(self.alice, "GET", self.route_base)["dungeon"]
        self.assertEqual((current["status"], current["reason"]), ("abandoned", "protocol_mismatch"))
        self.assertEqual(current["history"], route["history"])
        self.assertEqual(current["team_states"], before_states)
        self.assertEqual(self.private_battle()["result"]["reason"], "service_restart")
        with self.store.connect() as db:
            self.assertIsNone(self.store.active_route_for_room(db, self.code))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM rewards").fetchone()[0], 0)
        self.restart()
        self.assertEqual(current, self.call(self.alice, "GET", self.route_base)["dungeon"])
        # Both identities can enter a fresh current-protocol route immediately.
        replacement = self.route()
        self.assertEqual(replacement["status"], "preparing")

    def test_protocol_upgrade_preserves_completed_route_and_claimed_reward(self):
        dungeon = self.route()
        with self.store.connect() as db:
            route = self.store.dungeon(db, dungeon["id"], self.players[0])
            route.update({"status": "completed", "node_index": 5, "node_kind": "complete"})
            self.store.save_dungeon(db, route)
            reward = self.store.claim_reward(db, self.players[0], "dungeon:" + route["id"], {"kind": "dungeon_medal", "dungeon_id": route["id"]})
            room = self.store.room(db, self.code)
            room["compatibility"]["protocol"] = 1
            self.store.save_room(db, room)
        self.restart()
        self.assertEqual(self.call(self.alice, "GET", self.route_base)["dungeon"], route)
        self.assertEqual(self.call(self.alice, "POST", self.route_base + "/claim", {})["reward"], reward)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM rewards").fetchone()[0], 1)

    def test_trade_write_failure_rolls_back_both_receipts_and_confirmation(self):
        trade = self.offers()
        self.confirm(self.alice, trade)
        payload = {"request_id": "fault_confirm_once", "revision": trade["revision"], "offer_hashes": {owner: offer["hash"] for owner, offer in trade["offers"].items()}}
        original = self.store.save_trade

        def failing_save(db, value):
            original(db, value)
            if value["status"] == "committed":
                raise sqlite3.OperationalError("injected durable write failure")

        with mock.patch.object(self.store, "save_trade", failing_save):
            with self.assertRaises(sqlite3.OperationalError):
                self.store.request("POST", self.trade_base + "/confirm", payload, self.bob["token"])
        with self.store.connect() as db:
            current = self.store.trade_document(db, trade["code"])
            self.assertEqual((current["status"], current["confirmations"]), ("offering", [self.alice["identity"]["id"]]))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM trade_receipts").fetchone()[0], 0)
        self.assertEqual(self.raw(self.bob, "GET", "/v1/operations/fault_confirm_once")[0], 404)
        first = self.store.request("POST", self.trade_base + "/confirm", payload, self.bob["token"])
        second = self.store.request("POST", self.trade_base + "/confirm", payload, self.bob["token"])
        self.assertEqual(first, second)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM trade_receipts").fetchone()[0], 2)

    def test_hosted_pool_second_transfer_failure_is_fully_atomic(self):
        a, b = self.starter(self.alice), self.starter(self.bob)
        first = self.hosted_deposit(self.alice, a)
        payload = {"request_id": "fault_pool_match_once", "deposit_id": "pool_" + "d" * 32, "offer_id": "fault_offer", "source": "server_managed", "compatibility": self.compat, "asset_id": b["id"]}
        original, count = self.store.transfer_asset, 0

        def failing_transfer(*args):
            nonlocal count
            count += 1
            value = original(*args)
            if count == 2:
                raise sqlite3.OperationalError("injected second ownership write failure")
            return value

        with mock.patch.object(self.store, "transfer_asset", failing_transfer):
            with self.assertRaises(sqlite3.OperationalError):
                self.store.request("POST", "/v1/pool/deposits", payload, self.bob["token"])
        with self.store.connect() as db:
            self.assertEqual(self.store.asset(db, a["id"])["owner_id"], self.alice["identity"]["id"])
            self.assertEqual(self.store.asset(db, b["id"])["owner_id"], self.bob["identity"]["id"])
            self.assertEqual(self.store.deposit(db, first["id"])["status"], "waiting")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM pool_deposits").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM asset_locks").fetchone()[0], 1)
        self.assertEqual(self.raw(self.bob, "GET", "/v1/operations/fault_pool_match_once")[0], 404)
        committed = self.store.request("POST", "/v1/pool/deposits", payload, self.bob["token"])
        self.assertEqual(committed[0], 201)
        self.assertEqual(committed, self.store.request("POST", "/v1/pool/deposits", payload, self.bob["token"]))
        with self.store.connect() as db:
            self.assertEqual(self.store.asset(db, a["id"])["owner_id"], self.bob["identity"]["id"])
            self.assertEqual(self.store.asset(db, b["id"])["owner_id"], self.alice["identity"]["id"])
            self.assertEqual(db.execute("SELECT COUNT(*) FROM asset_locks").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
