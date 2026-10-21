"""Independent test identities and databases only; no game saves are opened."""
import copy
import json
import threading
import unittest
import uuid
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from service import Store, make_server, STATS, RULES, PROTOCOL


class FakeClock:
    def __init__(self):
        self.now = 1700000000.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


def pokemon(species="PIKACHU"):
    return {"version": 1, "species": species, "level": 20, "form": 0, "name": "测试", "gender": 0, "personal_id": 123456, "nature": "HARDY", "nature_for_stats": None, "hidden_power_type": None, "iv_maxed": {stat: False for stat in STATS}, "ability": "STATIC", "ability_index": 0, "ability2": None, "ability2_index": None, "item": "ORANBERRY", "moves": [{"id": "THUNDERWAVE", "pp": 20, "ppup": 0}, {"id": "TACKLE", "pp": 35, "ppup": 0}], "iv": {stat: 31 for stat in STATS}, "ev": {stat: 0 for stat in STATS}, "happiness": 70, "shiny": True, "appearance": {"head_shiny": True, "shinyValue": 120, "shinyKRS": [1, 2, 3, 0, 1, 2, 0, 1, 2], "head_nickname": "测试"}, "owner": {"id": 987, "name": "PrivateOT", "gender": 0, "language": 1}}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        test_directory = Path(__file__).parent / "data" / "tests"
        test_directory.mkdir(parents=True, exist_ok=True)
        # Windows sandbox ACLs can reject tempfile's private-mode directories.
        # Unique files in this explicit test-only directory inherit its ACL.
        self.database = test_directory / ("test_" + uuid.uuid4().hex + ".sqlite3")
        self.clock = FakeClock()
        self.store = Store(self.database, clock=self.clock)
        self.request_seq = 0
        self.alice = self.identity("Alice")
        self.bob = self.identity("Bob")
        self.eve = self.identity("Eve")
        self.compat = {"protocol": PROTOCOL, "game_version": "test-build", "data_hash": "test-data", "mods_hash": "no-mods", "rules_version": RULES}

    def tearDown(self):
        self.store.close()
        for suffix in ("", "-wal", "-shm"):
            Path(str(self.database) + suffix).unlink(missing_ok=True)

    def identity(self, name):
        status, response = self.store.request("POST", "/v1/identities", {"nickname": name, "protocol": PROTOCOL})
        self.assertEqual(status, 201)
        return response

    def engine_request(self, person, method, path, body, expected):
        # Positive fixtures model one live engine per host. Negative authority
        # tests call Store.request directly rather than inheriting this helper.
        parts = path.strip("/").split("/")
        if parts[:2] == ["v1", "battles"] and len(parts) >= 3:
            with self.store.connect() as db:
                row = db.execute("SELECT document FROM battles WHERE id=?", (parts[2],)).fetchone()
                battle = json.loads(row["document"]) if row else None
            if battle and battle["host_id"] == person["identity"]["id"]:
                authority = battle.get("authority_id")
                if authority is None and battle["status"] == "active" and battle["phase"] == "initializing" and expected < 400 and parts[-1] != "authority":
                    authority = "fixture_engine_" + parts[2]
                    self.request_seq += 1
                    self.call(person, "POST", "/v1/battles/" + parts[2] + "/authority", {"request_id": "fixture_claim_%012d" % self.request_seq, "authority_id": authority})
                if authority:
                    if method == "GET" and len(parts) == 3:
                        method, path, body = "POST", path + "/heartbeat", {"authority_id": authority}
                    elif method == "POST" and len(parts) == 4 and parts[3] not in ("authority", "claim"):
                        body = dict(body or {}, authority_id=authority)
        return method, path, body

    def call(self, person, method, path, body=None, expected=200):
        method, path, body = ServiceTests.engine_request(self, person, method, path, body, expected)
        if body is not None:
            body = copy.deepcopy(body)
            self.request_seq += 1
            body.setdefault("request_id", "test_%012d" % self.request_seq)
        status, response = self.store.request(method, path, body, person["token"])
        self.assertEqual(status, expected, response)
        return response

    def room(self):
        room = self.call(self.alice, "POST", "/v1/rooms", {"name": "Test room", "compatibility": self.compat}, 201)["room"]
        self.code = room["code"]
        self.base = "/v1/rooms/" + self.code
        self.call(self.bob, "POST", self.base + "/join", {"compatibility": self.compat})
        return room

    def prepared_room(self):
        self.room()
        for person in (self.alice, self.bob):
            self.call(person, "POST", self.base + "/team", {"candidates": [pokemon(), pokemon("EEVEE"), pokemon("DITTO"), pokemon("MEW")], "selected": [2, 0, 1]})
        for person in (self.alice, self.bob):
            self.call(person, "POST", self.base + "/ready", {"ready": True})

    def battle(self):
        self.prepared_room()
        self.battle_id = self.call(self.alice, "POST", self.base + "/start", {})["battle_id"]
        self.battle_base = "/v1/battles/" + self.battle_id
        self.players = [self.alice["identity"]["id"], self.bob["identity"]["id"]]
        self.state = {"kind": "command", "turn_count": 1, "weather": "None", "terrain": "None", "events": ["Test battle"], "battlers": [{"owner_id": owner, "index": index, "party_index": 0, "species": "DITTO", "hp": 100, "totalhp": 100, "status": "NONE", "name": "Active", "level": 50} for index, owner in enumerate(self.players)], "actions": {owner: {"moves": [{"index": 0, "id": "TACKLE", "name": "Tackle", "pp": 35, "total_pp": 35}], "switches": [{"party_index": 1, "species": "PIKACHU", "hp": 100, "totalhp": 100}], "can_switch": True, "forced": False} for owner in self.players}, "phase_owner_ids": self.players}
        self.resolve(0)
        return self.battle_id

    def resolve(self, turn, decision=0, state=None):
        return self.call(self.alice, "POST", self.battle_base + "/resolve", {"turn": turn, "state": state or self.state, "digest": "a" * 64, "random_tape": [{"limit": 100, "value": 42}], "decision": decision})["battle"]

    def command(self, person, turn, command=None, expected=200, request_id=None):
        body = {"turn": turn, "command": command or {"action": "move", "move_index": 0, "target": 1 if person == self.alice else 0}}
        if request_id:
            body["request_id"] = request_id
        return self.call(person, "POST", self.battle_base + "/commands", body, expected)

    def ack(self, turn):
        return self.call(self.bob, "POST", self.battle_base + "/ack", {"turn": turn, "digest": "a" * 64})["battle"]

    def test_health_identity_auth_protocol_recovery(self):
        status, health = self.store.request("GET", "/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(health["protocol"], PROTOCOL)
        status, _ = self.store.request("GET", "/v1/identity", token="forged")
        self.assertEqual(status, 401)
        status, _ = self.store.request("POST", "/v1/identities", {"nickname": "Bad", "protocol": 1})
        self.assertEqual(status, 409)
        status, recovered = self.store.request("POST", "/v1/identities/recover", {"recovery_code": self.alice["recovery_code"], "protocol": PROTOCOL})
        self.assertEqual(status, 200)
        self.assertEqual(recovered["identity"], self.alice["identity"])
        self.assertNotEqual(recovered["token"], self.alice["token"])
        status, _ = self.store.request("GET", "/v1/identity", token=self.alice["token"])
        self.assertEqual(status, 401)

    def test_room_capacity_permissions_and_compatibility(self):
        self.room()
        self.call(self.eve, "POST", self.base + "/join", {"compatibility": self.compat}, 409)
        self.call(self.eve, "GET", self.base, expected=403)
        self.call(self.bob, "POST", self.base + "/configure", {"name": "Stolen"}, 403)
        self.call(self.bob, "POST", self.base + "/leave", {})
        for key in ("game_version", "data_hash", "mods_hash", "rules_version"):
            compat = {**self.compat, key: "different"}
            self.call(self.bob, "POST", self.base + "/join", {"compatibility": compat}, 409)
        self.call(self.bob, "POST", self.base + "/join", {"compatibility": self.compat})
        self.call(self.alice, "POST", self.base + "/leave", {})
        self.call(self.bob, "POST", self.base + "/join", {"compatibility": self.compat}, 409)

    def test_team_configuration_invalidates_prepared_and_has_no_leaks(self):
        self.prepared_room()
        view = self.call(self.alice, "GET", self.base)["room"]
        encoded = json.dumps(view)
        for forbidden in ("THUNDERWAVE", "PrivateOT", "personal_id", "selected\"", "ability"):
            self.assertNotIn(forbidden, encoded)
        self.assertTrue(all(member["ready"] for member in view["members"]))
        self.call(self.alice, "POST", self.base + "/configure", {"name": "New name"})
        self.call(self.alice, "POST", self.base + "/start", {}, 409)
        for person in (self.alice, self.bob):
            self.call(person, "POST", self.base + "/ready", {"ready": True})
        room = self.call(self.bob, "POST", self.base + "/team", {"candidates": [pokemon()] * 3, "selected": [0, 1, 2]})["room"]
        self.assertTrue(all(not member["ready"] for member in room["members"]))

    def test_bad_team_and_unknown_json_fields_rejected(self):
        self.room()
        for change in ({"form": 1}, {"ev": {stat: 252 for stat in STATS}}, {"payload": "eval me"}, {"appearance": {"kuraycustomfile": "D:/private.png"}}, {"appearance": {"spriteform_head": "../bad"}}, {"version": 2}, {"level": True}, {"moves": [{"id": "TACKLE", "pp": 999, "ppup": 0}]}):
            candidate = {**pokemon(), **change}
            self.call(self.alice, "POST", self.base + "/team", {"candidates": [candidate] * 3, "selected": [0, 1, 2]}, 400 if not any(key in change for key in ("version", "form")) else 409)
        self.call(self.alice, "POST", self.base + "/team", {"candidates": [pokemon()] * 3, "selected": [0, 0, 1]}, 400)

    def test_idempotent_operation_status_and_payload_conflict(self):
        body = {"name": "Idempotent", "compatibility": self.compat, "request_id": "immutable_request_id"}
        first = self.call(self.alice, "POST", "/v1/rooms", body, 201)
        self.assertEqual(first, self.call(self.alice, "POST", "/v1/rooms", body, 201))
        operation = self.call(self.alice, "GET", "/v1/operations/immutable_request_id")
        self.assertEqual(operation["response"], first)
        self.call(self.bob, "GET", "/v1/operations/immutable_request_id", expected=404)
        self.call(self.alice, "POST", "/v1/rooms", {**body, "name": "Changed"}, 409)

    def test_simultaneous_starts_only_one_battle(self):
        self.prepared_room()
        def start(index):
            return self.store.request("POST", self.base + "/start", {"request_id": "parallel_start_%d" % index}, self.alice["token"])
        with ThreadPoolExecutor(max_workers=8) as executor:
            responses = list(executor.map(start, range(8)))
        self.assertEqual({status for status, _ in responses}, {200})
        self.assertEqual(len({response["battle_id"] for _, response in responses}), 1)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM battles").fetchone()[0], 1)

    def test_battle_private_teams_and_unlocked_commands(self):
        self.battle()
        host = self.call(self.alice, "GET", self.battle_base)["battle"]
        guest = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(host["players"][0], host["host_id"])
        self.assertIn("initial_teams", host)
        self.assertNotIn("initial_teams", guest)
        self.assertEqual(set(guest["state"]["actions"]), {self.players[1]})
        self.assertEqual(set(guest["updates"][0]["state"]["actions"]), {self.players[1]})
        self.assertNotIn("random_tape", guest["updates"][0])
        self.assertIn("random_tape", host["updates"][0])
        self.command(self.bob, 1)
        host = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertNotIn("commands", host)
        self.assertEqual(host["submitted"], [self.players[1]])
        self.call(self.eve, "GET", self.battle_base, expected=403)
        self.call(self.alice, "POST", self.base + "/configure", {"name": "During battle"}, 409)

    def test_command_lock_withdraw_late_duplicate_and_foreign_resolution(self):
        self.battle()
        self.command(self.bob, 1, request_id="duplicate_command_01")
        self.call(self.bob, "POST", self.battle_base + "/withdraw", {"turn": 1})
        self.command(self.bob, 1)
        battle = self.command(self.alice, 1)["battle"]
        self.assertEqual(battle["phase"], "locked")
        self.assertEqual(len(battle["commands"]), 2)
        self.command(self.bob, 1, request_id="duplicate_command_01")  # original committed response
        self.call(self.bob, "POST", self.battle_base + "/withdraw", {"turn": 1}, 409)
        self.command(self.alice, 1, expected=409)
        self.call(self.bob, "POST", self.battle_base + "/resolve", {"turn": 1, "state": self.state, "digest": "a" * 64, "decision": 0}, 403)
        self.resolve(1)
        self.command(self.alice, 0, expected=409)
        self.assertEqual(self.ack(1)["turn"], 2)

    def test_move_target_switch_and_forced_action_validation(self):
        self.battle()
        self.command(self.alice, 1, {"action": "move", "move_index": 3, "target": 1}, 409)
        self.command(self.alice, 1, {"action": "move", "move_index": 0, "target": 3}, 409)
        self.command(self.alice, 1, {"action": "switch", "party_index": 2}, 409)
        self.command(self.alice, 1, {"action": "forced"}, 409)
        self.command(self.alice, 1, {"action": "switch", "party_index": 1})
        self.command(self.bob, 1)
        switch = copy.deepcopy(self.state)
        switch["kind"] = "switch"
        switch["phase_owner_ids"] = [self.players[1]]
        self.resolve(1, state=switch)
        phase = self.ack(1)
        self.assertEqual(phase["submitted"], [self.players[0]])
        self.command(self.bob, 2, {"action": "move", "move_index": 0, "target": 0}, 409)
        self.command(self.bob, 2, {"action": "switch", "party_index": 1})

    def test_random_tape_status_and_settlement_once_rematch(self):
        self.battle()
        self.command(self.alice, 1)
        self.command(self.bob, 1)
        state = copy.deepcopy(self.state)
        state["battlers"][1]["hp"] = 0
        state["battlers"][1]["status"] = "POISON"
        state["weather"] = "Rain"
        self.call(self.alice, "POST", self.battle_base + "/resolve", {"turn": 1, "state": state, "digest": "a" * 64, "decision": 1, "random_tape": [{"limit": 100, "value": 100}]}, 400)
        body = {"request_id": "single_resolution_01", "turn": 1, "state": state, "digest": "a" * 64, "decision": 1, "random_tape": [{"limit": 100, "value": 99}]}
        first = self.call(self.alice, "POST", self.battle_base + "/resolve", body)["battle"]
        second = self.call(self.alice, "POST", self.battle_base + "/resolve", body)["battle"]
        self.assertEqual(first, second)
        self.assertEqual(first["result"]["winner_id"], self.players[0])
        self.assertEqual(first["result"]["rewards"], [])
        self.assertEqual(self.call(self.bob, "GET", self.battle_base)["battle"]["state"]["weather"], "Rain")
        self.command(self.bob, 1, expected=409)
        for person in (self.alice, self.bob):
            self.call(person, "POST", self.base + "/ready", {"ready": True})
        new_id = self.call(self.alice, "POST", self.base + "/start", {})["battle_id"]
        self.assertNotEqual(new_id, self.battle_id)

    def test_ack_divergence_does_not_advance_and_abort_has_no_winner(self):
        self.battle()
        self.command(self.alice, 1)
        self.command(self.bob, 1)
        self.resolve(1)
        self.call(self.bob, "POST", self.battle_base + "/ack", {"turn": 1, "digest": "b" * 64}, 409)
        self.assertEqual(self.call(self.bob, "GET", self.battle_base)["battle"]["phase"], "playback")
        result = self.call(self.bob, "POST", self.battle_base + "/abort", {"reason": "client_error"})["battle"]["result"]
        self.assertTrue(result["abnormal"])
        self.assertIsNone(result["winner_id"])

    def test_disconnect_budget_is_cumulative_and_pauses_deadline(self):
        self.battle()
        deadline = self.call(self.alice, "GET", self.battle_base)["battle"]["deadline"]
        self.clock.advance(20)
        battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["reconnect_remaining"][self.players[1]], 48)
        self.assertEqual(battle["deadline"], deadline + 12)
        self.call(self.bob, "GET", self.battle_base)
        self.clock.advance(15)
        self.call(self.alice, "GET", self.battle_base)
        battle = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["reconnect_remaining"][self.players[1]], 41)
        # Bob returns, but his already used budget does not reset.
        self.assertNotIn(self.players[1], battle["disconnected"])

    def test_late_return_after_budget_cannot_revive_battle(self):
        self.battle()
        for _ in range(14):
            self.clock.advance(5)
            self.call(self.alice, "GET", self.battle_base)
        battle = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["result"]["reason"], "disconnect_timeout")
        self.assertEqual(battle["result"]["winner_id"], self.players[0])

    def test_host_disconnect_or_both_disconnect_abnormal(self):
        self.battle()
        for _ in range(14):
            self.clock.advance(5)
            self.call(self.bob, "GET", self.battle_base)
        battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["result"]["reason"], "host_disconnected")
        self.assertTrue(battle["result"]["abnormal"])

    def test_action_timeout_deterministic_then_three_strikes(self):
        self.battle()
        for phase in range(1, 4):
            self.command(self.alice, phase)
            for _ in range(12):
                self.clock.advance(5)
                self.call(self.alice, "GET", self.battle_base)
                latest = self.call(self.bob, "GET", self.battle_base)["battle"]
            host = self.call(self.alice, "GET", self.battle_base)["battle"]
            if phase < 3:
                self.assertEqual(host["phase"], "locked")
                self.assertEqual(host["commands"][self.players[1]], {"action": "move", "move_index": 0, "target": 0})
                self.resolve(phase)
                self.ack(phase)
            else:
                self.assertEqual(host["result"]["reason"], "three_action_timeouts")

    def test_empty_phase_auto_locks_waits(self):
        self.battle()
        self.command(self.alice, 1)
        self.command(self.bob, 1)
        state = copy.deepcopy(self.state)
        state["phase_owner_ids"] = []
        self.resolve(1, state=state)
        self.ack(1)
        battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["phase"], "locked")
        self.assertEqual(battle["commands"], {owner: {"action": "wait"} for owner in self.players})

    def test_restart_persistence_and_active_engine_abnormal(self):
        self.battle()
        showcase = self.call(self.alice, "POST", "/v1/showcases", {"snapshot": pokemon(), "public_fields": []})["showcase"]
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        if hasattr(self, "server"):
            self.server.store = self.store
        self.assertEqual(self.call(self.alice, "GET", "/v1/identity")["identity"], self.alice["identity"])
        battle = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["result"]["reason"], "service_restart")
        self.assertIsNone(battle["result"]["winner_id"])
        self.assertFalse(any(member["ready"] for member in self.call(self.alice, "GET", self.base)["room"]["members"]))
        self.call(self.bob, "GET", "/v1/showcases/" + showcase["code"])

    def test_showcase_privacy_appearance_update_and_unpublish(self):
        original = pokemon()
        before = copy.deepcopy(original)
        showcase = self.call(self.alice, "POST", "/v1/showcases", {"snapshot": original, "public_fields": []})["showcase"]
        self.assertEqual(original, before)
        base = "/v1/showcases/" + showcase["code"]
        public = self.call(self.bob, "GET", base)["showcase"]["snapshot"]
        for field in ("name", "owner", "iv", "ev", "personal_id", "item", "nature"):
            self.assertNotIn(field, public)
        self.assertEqual(public["appearance"], {key: value for key, value in original["appearance"].items() if key != "head_nickname"})
        self.call(self.bob, "POST", "/v1/showcases", {"code": showcase["code"], "snapshot": original, "public_fields": []}, 403)
        self.call(self.alice, "POST", "/v1/showcases", {"code": showcase["code"], "snapshot": {**original, "form": 2}, "public_fields": []}, 409)
        self.assertEqual(self.call(self.bob, "GET", base)["showcase"]["version"], 1)
        updated = self.call(self.alice, "POST", "/v1/showcases", {"code": showcase["code"], "snapshot": original, "public_fields": ["name", "iv"]})["showcase"]
        self.assertEqual(updated["version"], 2)
        self.assertIn("iv", updated["snapshot"])
        self.call(self.bob, "POST", base + "/unpublish", {}, 403)
        self.call(self.alice, "POST", base + "/unpublish", {})
        self.call(self.bob, "GET", base, expected=404)

    def test_expired_room_stays_closed(self):
        self.room()
        self.clock.advance(86401)
        self.assertEqual(self.call(self.alice, "GET", self.base)["room"]["status"], "closed")
        self.call(self.bob, "POST", self.base + "/join", {"compatibility": self.compat}, 409)


class HTTPIntegrationTests(ServiceTests):
    """Same business tests additionally traverse real localhost HTTP sockets."""
    def setUp(self):
        super().setUp()
        self.server = make_server("127.0.0.1", 0, self.store)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%d" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        super().tearDown()

    def call(self, person, method, path, body=None, expected=200):
        method, path, body = ServiceTests.engine_request(self, person, method, path, body, expected)
        if body is not None:
            body = copy.deepcopy(body)
            self.request_seq += 1
            body.setdefault("request_id", "http_%012d" % self.request_seq)
        request = urllib.request.Request(self.url + path, data=None if body is None else json.dumps(body).encode(), headers={"Authorization": "Bearer " + person["token"], "Content-Type": "application/json"}, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=3)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            result = json.load(response)
            self.assertEqual(response.status, expected, result)
            return result

    def test_malformed_http_json_rejected(self):
        for data in (b"{", b"[]", b'{"number":NaN}', b'{"number":Infinity}'):
            request = urllib.request.Request(self.url + "/v1/rooms", data=data, headers={"Content-Type": "application/json", "Authorization": "Bearer " + self.alice["token"]})
            with self.assertRaises(urllib.error.HTTPError) as context:
                urllib.request.urlopen(request, timeout=3)
            self.assertEqual(context.exception.code, 400)

    def test_http_no_content_type_rejected(self):
        request = urllib.request.Request(self.url + "/v1/identities", data=b'{}')
        with self.assertRaises(urllib.error.HTTPError) as context:
            urllib.request.urlopen(request, timeout=3)
        self.assertEqual(context.exception.code, 415)

    def test_same_port_cannot_bind_second_service(self):
        with self.assertRaises(OSError):
            make_server("127.0.0.1", self.server.server_port, self.store)


if __name__ == "__main__":
    unittest.main(verbosity=2)
