"""Second release: real SQLite transitions; all fixtures are test-only."""
import copy
import json
import threading
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from service import Store, make_server, validate_trade_snapshot, APIError, PROTOCOL
import test_service as baseline
from test_service import pokemon


def trade_snapshot(species="PIKACHU"):
    preserved = {"exp": 8000, "hp": 60, "status_count": 0, "markings": 0, "obtain_method": 0, "obtain_map": 1, "hatched_map": 0, "obtain_level": 20, "kuray_no_evo": 0, "hat_x": 0, "hat_y": 0, "status": "NONE", "poke_ball": "POKEBALL", "first_moves": ["TACKLE"], "ribbons": [], "obtain_text": None, "veryunique": None, "glitter": None, "force_disobey": None, "imported": False, "type1kuray": None, "type2kuray": None, "sprite_asset": None, "old_sprite_asset": None}
    for field in ("cool", "beauty", "cute", "smart", "tough", "sheen", "pokerus"):
        preserved[field] = 0
    for field in ("time_form_set", "time_received", "time_egg_hatched", "exp_when_fused_head", "exp_when_fused_body", "exp_gained_since_fused", "body_original_ability_index", "head_original_ability_index"):
        preserved[field] = None
    return {"version": 1, "pokemon": pokemon(species), "preserved": preserved}


class V2Tests(unittest.TestCase):
    setUp = baseline.ServiceTests.setUp
    tearDown = baseline.ServiceTests.tearDown
    identity = baseline.ServiceTests.identity
    call = baseline.ServiceTests.call
    room = baseline.ServiceTests.room
    prepared_room = baseline.ServiceTests.prepared_room
    resolve = baseline.ServiceTests.resolve
    command = baseline.ServiceTests.command
    ack = baseline.ServiceTests.ack

    def boss(self):
        room = self.call(self.alice, "POST", "/v1/rooms", {"name": "Boss", "compatibility": self.compat, "mode": "coop_boss", "boss_id": "training-golem", "difficulty": "normal"}, 201)["room"]
        self.code = room["code"]
        self.base = "/v1/rooms/" + self.code
        self.call(self.bob, "POST", self.base + "/join", {"compatibility": self.compat})
        for person in (self.alice, self.bob):
            self.call(person, "POST", self.base + "/team", {"candidates": [pokemon(), pokemon("EEVEE"), pokemon("DITTO")], "selected": [0, 1, 2]})
        for person in (self.alice, self.bob):
            self.call(person, "POST", self.base + "/ready", {"ready": True})
        self.battle_id = self.call(self.alice, "POST", self.base + "/start", {})["battle_id"]
        self.battle_base = "/v1/battles/" + self.battle_id
        self.players = [self.alice["identity"]["id"], self.bob["identity"]["id"]]
        self.state = {"kind": "command", "turn_count": 0, "events": [], "battlers": [{"owner_id": owner, "index": index, "party_index": 0, "species": "PIKACHU", "hp": 100, "totalhp": 100, "status": "NONE"} for owner, index in zip(self.players + ["boss"], [0, 2, 1])], "actions": {owner: {"moves": [{"index": 0, "id": "TACKLE", "name": "Tackle", "pp": 35, "total_pp": 35, "targets": [1, 2]}], "switches": [{"party_index": 1, "species": "EEVEE", "hp": 100, "totalhp": 100}], "can_switch": True, "forced": False} for owner in self.players}, "phase_owner_ids": self.players}
        self.resolve(0)
        return room

    def gym(self):
        self.gym_payload = {"name": "AI Gym", "description": "Test only", "intro": "Welcome", "compatibility": self.compat, "team": [pokemon("DITTO"), pokemon("EEVEE")]}
        gym = self.call(self.alice, "POST", "/v1/gyms", self.gym_payload, 201)["gym"]
        self.gym_base = "/v1/gyms/" + gym["code"]
        return gym

    def challenge(self):
        challenge = self.call(self.bob, "POST", self.gym_base + "/challenge", {"compatibility": self.compat, "team": [pokemon(), pokemon(), pokemon()]}, 201)["challenge"]
        self.challenge_base = "/v1/gym-challenges/" + challenge["id"]
        return challenge

    def trade(self):
        trade = self.call(self.alice, "POST", "/v1/trades", {"compatibility": self.compat, "source": "local_casual"}, 201)["trade"]
        self.trade_base = "/v1/trades/" + trade["code"]
        self.call(self.bob, "POST", self.trade_base + "/join", {"compatibility": self.compat})
        return trade

    def offers(self):
        self.trade()
        self.call(self.alice, "POST", self.trade_base + "/offer", {"snapshot": trade_snapshot(), "offer_id": "local-a"})
        return self.call(self.bob, "POST", self.trade_base + "/offer", {"snapshot": trade_snapshot("EEVEE"), "offer_id": "local-b"})["trade"]

    def confirm(self, person, trade, **extra):
        return self.call(person, "POST", self.trade_base + "/confirm", {"revision": trade["revision"], "offer_hashes": {owner: offer["hash"] for owner, offer in trade["offers"].items()}, **extra})["trade"]

    def commit(self):
        trade = self.offers()
        self.confirm(self.alice, trade)
        return self.confirm(self.bob, trade)

    def restart(self):
        self.store.close()
        self.store = Store(self.database, clock=self.clock)

    def test_cr_pp_zero_and_legal_targets(self):
        self.boss()
        state = copy.deepcopy(self.state)
        state["actions"][self.players[0]]["moves"][0]["pp"] = 0
        with self.store.connect() as db:
            battle = self.store.battle(db, self.battle_id)
            battle["state"] = state
            self.store.save_battle(db, battle)
        self.command(self.alice, 1, {"action": "move", "move_index": 0, "target": 1}, 409)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 0}, 409)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 2})

    def test_cr_lowercase_showcase_code(self):
        self.call(self.alice, "POST", "/v1/showcases", {"code": "deadbeef", "snapshot": pokemon(), "public_fields": []})
        showcase = self.call(self.bob, "GET", "/v1/showcases/DEADBEEF")["showcase"]
        self.assertEqual(showcase["code"], "DEADBEEF")

    def test_cr_identity_expected_mismatch_does_not_rotate_token(self):
        status, _ = self.store.request("POST", "/v1/identities/recover", {"recovery_code": self.alice["recovery_code"], "protocol": PROTOCOL, "expected_identity_id": self.bob["identity"]["id"]})
        self.assertEqual(status, 409)
        self.call(self.alice, "GET", "/v1/identity")
        status, _ = self.store.request("POST", "/v1/identities/recover", {"recovery_code": "wrong-but-long-enough-value", "protocol": PROTOCOL, "expected_identity_id": self.alice["identity"]["id"]})
        self.assertEqual(status, 401)
        self.call(self.alice, "GET", "/v1/identity")
        status, recovered = self.store.request("POST", "/v1/identities/recover", {"recovery_code": self.alice["recovery_code"], "protocol": PROTOCOL, "expected_identity_id": self.alice["identity"]["id"]})
        self.assertEqual(status, 200)
        self.call(self.alice, "GET", "/v1/identity", expected=401)
        self.alice["token"] = recovered["token"]
        self.call(self.alice, "GET", "/v1/identity")

    def test_cr_appearance_strict_engine_types(self):
        for field, value in (("head_shiny", "yes"), ("shinyValue", True), ("shinyKRS", [1, 2, 3]), ("sprite_scale", 0), ("size_category", "GIANT"), ("head_nickname", "../x")):
            with self.subTest(field=field):
                snapshot = pokemon()
                snapshot["appearance"][field] = value
                self.call(self.alice, "POST", "/v1/showcases", {"snapshot": snapshot, "public_fields": []}, 400)

    def test_boss_configuration_team_visibility_signal(self):
        room = self.boss()
        current = self.call(self.bob, "GET", self.base)["room"]
        self.assertEqual(current["boss"]["species"], "B76H95")
        self.assertEqual(current["members"][0]["team"][0], pokemon())
        battle = self.call(self.bob, "POST", self.battle_base + "/signal", {"signal": "support"})["battle"]
        self.assertEqual(battle["signals"][self.players[1]]["signal"], "support")
        self.assertEqual(set(battle["initial_teams"]), set(self.players))
        self.assertNotIn("commands", battle)

    def test_boss_mode_config_invalid(self):
        self.call(self.alice, "POST", "/v1/rooms", {"name": "Boss", "compatibility": self.compat, "mode": "coop_boss", "boss_id": "injected"}, 409)
        self.call(self.alice, "POST", "/v1/rooms", {"name": "Boss", "compatibility": self.compat, "mode": "coop_boss", "difficulty": "hacked"}, 400)
        self.call(self.alice, "POST", "/v1/rooms", {"name": "Boss", "compatibility": self.compat, "mode": "unknown"}, 400)

    def test_boss_victory_unique_reward_authorization(self):
        self.boss()
        self.call(self.alice, "POST", self.battle_base + "/claim", {}, 409)
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        finished = self.resolve(1, 1)
        self.assertEqual(finished["result"]["winner_ids"], self.players)
        first = self.call(self.alice, "POST", self.battle_base + "/claim", {})["reward"]
        second = self.call(self.alice, "POST", self.battle_base + "/claim", {})["reward"]
        self.assertEqual(first, second)
        other = self.call(self.bob, "POST", self.battle_base + "/claim", {})["reward"]
        self.assertNotEqual(first["id"], other["id"])
        self.call(self.eve, "POST", self.battle_base + "/claim", {}, 403)
        self.restart()
        self.assertEqual(self.call(self.alice, "POST", self.battle_base + "/claim", {})["reward"], first)

    def test_boss_defeat_no_reward(self):
        self.boss()
        self.command(self.bob, 1, {"action": "surrender"})
        self.call(self.alice, "POST", self.battle_base + "/claim", {}, 409)
        battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["result"]["coop_outcome"], "defeat")

    def test_boss_defeat_never_names_guest_as_winner(self):
        self.boss()
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        battle = self.resolve(1, 2)
        self.assertEqual(battle["result"]["coop_outcome"], "defeat")
        self.assertIsNone(battle["result"]["winner_id"])
        self.assertEqual(battle["result"]["winner_ids"], [])

    def test_v1_timeout_uses_legal_engine_auto_target(self):
        baseline.ServiceTests.battle(self)
        with self.store.connect() as db:
            battle = self.store.battle(db, self.battle_id)
            for actions in battle["state"]["actions"].values():
                actions["moves"][0]["targets"] = [-1]
            self.store.save_battle(db, battle)
        for _ in range(13):
            self.clock.advance(5)
            self.call(self.bob, "GET", self.battle_base)
            battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertTrue(all(command["target"] == -1 for command in battle["commands"].values()))

    def test_boss_timeout_ai_does_not_forfeit(self):
        self.boss()
        for _ in range(13):
            self.clock.advance(5)
            self.call(self.bob, "GET", self.battle_base)
            battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["phase"], "locked")
        self.assertTrue(all(command == {"action": "ai"} for command in battle["commands"].values()))

    def test_boss_guest_disconnect_ai_and_boundary_restoration(self):
        self.boss()
        self.command(self.alice, 1)
        for _ in range(15):
            self.clock.advance(5)
            battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        guest = self.players[1]
        self.assertIn(guest, battle["ai_controlled_ids"])
        self.assertEqual(battle["commands"][guest], {"action": "ai"})
        # A reconnect cannot replace the phase's locked AI command.
        back = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertIn(guest, back["control_restore_pending_ids"])
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1}, 409)
        next_phase = self.resolve(1)
        self.assertEqual(next_phase["turn"], 2)
        self.assertNotIn(guest, next_phase["ai_controlled_ids"])
        self.command(self.bob, 2, {"action": "move", "move_index": 0, "target": 1})
        # Spent allowance never grants another one-minute pause.
        for _ in range(3):
            self.clock.advance(5)
            battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertIn(guest, battle["ai_controlled_ids"])

    def test_boss_locked_guest_command_preserved_on_takeover(self):
        self.boss()
        self.command(self.bob, 1, {"action": "switch", "party_index": 1})
        for _ in range(15):
            self.clock.advance(5)
            battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["status"], "active")
        self.command(self.alice, 1)
        battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["commands"][self.players[1]], {"action": "switch", "party_index": 1})

    def test_boss_reconnect_then_disappear_keeps_ai_at_boundary(self):
        self.boss()
        self.command(self.alice, 1)
        for _ in range(15):
            self.clock.advance(5)
            self.call(self.alice, "GET", self.battle_base)
        self.call(self.bob, "GET", self.battle_base)
        self.clock.advance(9)
        battle = self.resolve(1)
        self.assertIn(self.players[1], battle["ai_controlled_ids"])

    def test_boss_host_disconnect_remains_abnormal(self):
        self.boss()
        for _ in range(15):
            self.clock.advance(5)
            battle = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["status"], "abnormal")
        self.assertEqual(battle["result"]["reason"], "host_disconnected")

    def test_gym_publish_public_private_fields(self):
        gym = self.gym()
        public = self.call(self.bob, "GET", self.gym_base)["gym"]
        self.assertNotIn("team", public)
        self.assertNotIn("head_nickname", public["team_preview"][0]["appearance"])
        self.assertEqual(gym["team"][0], pokemon("DITTO"))
        self.assertTrue(self.call(self.bob, "GET", "/v1/gyms")["gyms"])
        self.call(self.bob, "POST", self.gym_base + "/publish", self.gym_payload, 403)
        self.call(self.bob, "POST", self.gym_base + "/close", {}, 403)

    def test_gym_fixed_version_after_update_and_close(self):
        self.gym()
        challenge = self.challenge()
        self.gym_payload["team"] = [pokemon("MEW")]
        changed = self.call(self.alice, "POST", self.gym_base + "/publish", self.gym_payload)["gym"]
        self.assertEqual(changed["version"], 2)
        self.call(self.alice, "POST", self.gym_base + "/close", {})
        self.call(self.bob, "POST", self.gym_base + "/challenge", {"compatibility": self.compat, "team": [pokemon()] * 3}, 409)
        old = self.call(self.bob, "GET", self.challenge_base)["challenge"]
        self.assertEqual(old, challenge)
        self.assertEqual(old["defender_team"][0]["species"], "DITTO")
        self.call(self.bob, "POST", self.challenge_base + "/result", {"outcome": "win", "turns": 2, "summary": "Test"})

    def test_gym_result_immutable_and_unique_reward_across_versions(self):
        self.gym()
        self.challenge()
        body = {"outcome": "win", "turns": 3, "summary": "Test"}
        self.call(self.bob, "POST", self.challenge_base + "/result", body)
        first = self.call(self.bob, "POST", self.challenge_base + "/claim", {})["reward"]
        self.call(self.bob, "POST", self.challenge_base + "/result", {**body, "outcome": "loss"}, 409)
        self.call(self.alice, "POST", self.gym_base + "/publish", self.gym_payload)
        self.challenge()
        self.call(self.bob, "POST", self.challenge_base + "/result", body)
        second = self.call(self.bob, "POST", self.challenge_base + "/claim", {})["reward"]
        self.assertEqual(first, second)
        self.assertEqual(len(self.call(self.bob, "GET", "/v1/gym-challenges")["challenges"]), 2)

    def test_gym_loss_cannot_upgrade_and_not_participant(self):
        self.gym()
        self.challenge()
        self.call(self.eve, "GET", self.challenge_base, expected=403)
        self.call(self.alice, "POST", self.challenge_base + "/result", {"outcome": "win", "turns": 1, "summary": ""}, 403)
        for outcome in ("loss", "abandon", "abnormal"):
            self.challenge()
            self.call(self.bob, "POST", self.challenge_base + "/result", {"outcome": outcome, "turns": 1, "summary": ""})
            self.call(self.bob, "POST", self.challenge_base + "/claim", {}, 409)
            self.call(self.bob, "POST", self.challenge_base + "/result", {"outcome": "win", "turns": 1, "summary": ""}, 409)

    def test_gym_compatibility_and_favorite_restart(self):
        self.gym()
        self.call(self.bob, "POST", self.gym_base + "/challenge", {"compatibility": {**self.compat, "data_hash": "wrong"}, "team": [pokemon()] * 3}, 409)
        self.call(self.bob, "POST", self.gym_base + "/favorite", {"favorite": True})
        self.challenge()
        self.restart()
        self.assertTrue(self.call(self.bob, "GET", "/v1/gyms")["gyms"][0]["favorite"])
        self.assertEqual(self.call(self.bob, "GET", self.challenge_base)["challenge"]["status"], "active")

    def test_trade_snapshot_roundtrip_and_strict_whitelist(self):
        snapshot = trade_snapshot()
        self.assertEqual(validate_trade_snapshot(snapshot), snapshot)
        for field, value in (("hp", True), ("poke_ball", "../../x"), ("status", "invalid"), ("hat", "unsafe"), ("veryunique", "../id"), ("sprite_asset", "base:../../1"), ("old_sprite_asset", "C:/private.png")):
            changed = copy.deepcopy(snapshot)
            changed["preserved"][field] = value
            with self.assertRaises(APIError):
                validate_trade_snapshot(changed)
        changed = copy.deepcopy(snapshot)
        del changed["preserved"]["exp"]
        with self.assertRaises(APIError):
            validate_trade_snapshot(changed)

    def test_trade_identity_compatibility_and_single_pending(self):
        self.trade()
        self.call(self.eve, "GET", self.trade_base, expected=403)
        self.call(self.eve, "POST", self.trade_base + "/offer", {"snapshot": trade_snapshot(), "offer_id": "evil"}, 403)
        self.call(self.eve, "POST", self.trade_base + "/join", {"compatibility": self.compat}, 409)
        self.call(self.alice, "POST", "/v1/trades", {"compatibility": self.compat}, 409)
        self.call(self.eve, "POST", "/v1/trades", {"compatibility": self.compat, "source": "forged_assets"}, 409)

    def test_trade_offer_change_clears_confirmations_and_stale_rejected(self):
        trade = self.offers()
        self.confirm(self.alice, trade)
        changed = self.call(self.bob, "POST", self.trade_base + "/offer", {"snapshot": trade_snapshot("MEW"), "offer_id": "local-new"})["trade"]
        self.assertEqual(changed["confirmations"], [])
        body = {"revision": trade["revision"], "offer_hashes": {key: value["hash"] for key, value in trade["offers"].items()}}
        self.call(self.alice, "POST", self.trade_base + "/confirm", body, 409)

    def test_trade_hash_mismatch_and_untrusted_owner_fields_rejected(self):
        trade = self.offers()
        hashes = {key: value["hash"] for key, value in trade["offers"].items()}
        hashes[self.alice["identity"]["id"]] = "0" * 64
        self.call(self.alice, "POST", self.trade_base + "/confirm", {"revision": trade["revision"], "offer_hashes": hashes}, 409)
        self.call(self.alice, "POST", self.trade_base + "/offer", {"snapshot": trade_snapshot(), "offer_id": "new", "owner_id": self.bob["identity"]["id"]}, 400)

    def test_trade_commit_receipt_ack_idempotent_restart(self):
        trade = self.commit()
        transaction = trade["transaction_id"]
        self.assertEqual(trade["status"], "committed")
        self.assertEqual(trade["receipt"]["received_snapshot"], trade_snapshot())
        self.call(self.alice, "POST", self.trade_base + "/cancel", {}, 409)
        self.restart()
        recovered = self.call(self.alice, "GET", self.trade_base)["trade"]
        self.assertEqual(recovered["transaction_id"], transaction)
        self.assertEqual(recovered["receipt"]["received_snapshot"], trade_snapshot("EEVEE"))
        self.call(self.alice, "POST", self.trade_base + "/ack", {"transaction_id": "wrong"}, 409)
        self.call(self.alice, "POST", self.trade_base + "/ack", {"transaction_id": transaction})
        self.call(self.alice, "POST", self.trade_base + "/ack", {"transaction_id": transaction})
        complete = self.call(self.bob, "POST", self.trade_base + "/ack", {"transaction_id": transaction})["trade"]
        self.assertEqual(complete["status"], "completed")
        self.assertEqual(len(complete["acked"]), 2)

    def test_trade_repeated_confirm_same_request_single_transaction(self):
        trade = self.offers()
        self.confirm(self.alice, trade)
        first = self.confirm(self.bob, trade, request_id="confirm_bob_once")
        second = self.confirm(self.bob, trade, request_id="confirm_bob_once")
        self.assertEqual(first, second)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM trade_receipts").fetchone()[0], 2)

    def test_trade_own_ack_allows_new_session_without_other_online(self):
        trade = self.commit()
        self.call(self.alice, "POST", self.trade_base + "/ack", {"transaction_id": trade["transaction_id"]})
        self.call(self.alice, "POST", "/v1/trades", {"compatibility": self.compat}, 201)
        self.call(self.bob, "POST", "/v1/trades", {"compatibility": self.compat}, 409)

    def test_trade_cancel_expiry_and_recovery_list(self):
        self.trade()
        self.call(self.bob, "POST", self.trade_base + "/cancel", {})
        self.call(self.alice, "POST", self.trade_base + "/offer", {"snapshot": trade_snapshot(), "offer_id": "old"}, 409)
        next_trade = self.call(self.alice, "POST", "/v1/trades", {"compatibility": self.compat}, 201)["trade"]
        self.clock.advance(86401)
        expired = self.call(self.alice, "GET", "/v1/trades/" + next_trade["code"])["trade"]
        self.assertEqual(expired["status"], "expired")
        self.assertEqual(len(self.call(self.alice, "GET", "/v1/trades")["trades"]), 2)


class V2HTTPTests(unittest.TestCase):
    identity = baseline.ServiceTests.identity
    boss = V2Tests.boss
    resolve = V2Tests.resolve
    command = V2Tests.command
    gym = V2Tests.gym
    challenge = V2Tests.challenge
    trade = V2Tests.trade
    offers = V2Tests.offers
    confirm = V2Tests.confirm

    def setUp(self):
        baseline.ServiceTests.setUp(self)
        self.server = make_server("127.0.0.1", 0, self.store)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.url = "http://127.0.0.1:%s" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=3)
        baseline.ServiceTests.tearDown(self)

    def http(self, person, method, path, body=None):
        headers = {"Authorization": "Bearer " + person["token"]}
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def call(self, person, method, path, body=None, expected=200):
        method, path, body = baseline.ServiceTests.engine_request(self, person, method, path, body, expected)
        if body is not None:
            body = copy.deepcopy(body)
            self.request_seq += 1
            body.setdefault("request_id", "http_%012d" % self.request_seq)
        status, response = self.http(person, method, path, body)
        self.assertEqual(status, expected, response)
        return response

    def test_http_boss_gym_trade_endpoints(self):
        self.boss()
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        battle = self.resolve(1, 1)
        self.assertEqual(battle["result"]["coop_outcome"], "victory")
        self.call(self.bob, "POST", self.battle_base + "/claim", {})
        self.gym()
        self.challenge()
        self.call(self.bob, "POST", self.challenge_base + "/result", {"outcome": "win", "turns": 1, "summary": "HTTP smoke"})
        self.call(self.bob, "POST", self.challenge_base + "/claim", {})
        trade = self.offers()
        self.confirm(self.alice, trade)
        committed = self.confirm(self.bob, trade)
        for person in (self.alice, self.bob):
            self.call(person, "POST", self.trade_base + "/ack", {"transaction_id": committed["transaction_id"]})
        self.assertEqual(self.call(self.alice, "GET", self.trade_base)["trade"]["status"], "completed")

    def test_http_simultaneous_confirm_single_transaction(self):
        trade = self.offers()
        body = {"revision": trade["revision"], "offer_hashes": {owner: offer["hash"] for owner, offer in trade["offers"].items()}}
        def confirm(person):
            return self.http(person, "POST", self.trade_base + "/confirm", {**body, "request_id": "parallel_" + person["identity"]["id"]})
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(confirm, (self.alice, self.bob)))
        self.assertTrue(all(status == 200 for status, _ in results), results)
        committed = self.call(self.alice, "GET", self.trade_base)["trade"]
        self.assertEqual(committed["status"], "committed")
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM trade_receipts").fetchone()[0], 2)

    def test_http_commit_cancel_race_has_one_destination(self):
        trade = self.offers()
        self.confirm(self.alice, trade)
        confirm_body = {"revision": trade["revision"], "offer_hashes": {owner: offer["hash"] for owner, offer in trade["offers"].items()}, "request_id": "race_confirm_bob"}
        calls = [(self.bob, self.trade_base + "/confirm", confirm_body), (self.alice, self.trade_base + "/cancel", {"request_id": "race_cancel_alice"})]
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda args: self.http(args[0], "POST", args[1], args[2]), calls))
        self.assertEqual(sorted(status for status, _ in results), [200, 409])
        final = self.call(self.alice, "GET", self.trade_base)["trade"]
        with self.store.connect() as db:
            receipts = db.execute("SELECT COUNT(*) FROM trade_receipts").fetchone()[0]
        self.assertIn((final["status"], receipts), (("committed", 2), ("cancelled", 0)))


if __name__ == "__main__":
    unittest.main()
