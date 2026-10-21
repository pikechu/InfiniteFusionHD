"""Third release state machines, authority boundaries, races and recovery."""
import copy
import json
import secrets
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor

import test_v2 as v2
from test_service import pokemon
from service import Store, make_server


class V3Tests(unittest.TestCase):
    identity = v2.V2Tests.identity
    call = v2.V2Tests.call
    boss = v2.V2Tests.boss
    resolve = v2.V2Tests.resolve
    command = v2.V2Tests.command
    trade = v2.V2Tests.trade
    offers = v2.V2Tests.offers
    confirm = v2.V2Tests.confirm

    def setUp(self):
        v2.V2Tests.setUp(self)
        self.catalog_file = self.database.with_suffix(".catalog.json")
        self.catalog_file.write_text(json.dumps({"version": 1, "compatibility": self.compat, "pokemon": [pokemon("B%dH%d" % (i + 25, i + 133)) for i in range(12)]}), encoding="utf-8")
        self.store.catalog_path = self.catalog_file

    def tearDown(self):
        v2.V2Tests.tearDown(self)
        self.catalog_file.unlink(missing_ok=True)

    def restart(self):
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.store.catalog_path = self.catalog_file

    def deposit(self, person, species="PIKACHU", **extra):
        body = {"deposit_id": "pool_" + secrets.token_hex(16), "offer_id": "offer_" + secrets.token_hex(8), "source": "local_casual", "compatibility": self.compat, "snapshot": v2.trade_snapshot(species), **extra}
        return self.call(person, "POST", "/v1/pool/deposits", body, 201)["deposit"]

    def starter(self, person):
        return self.call(person, "POST", "/v1/collections/starter", {"catalog_version": 1}, 201)["asset"]

    def hosted_deposit(self, person, asset):
        return self.call(person, "POST", "/v1/pool/deposits", {"deposit_id": "pool_" + secrets.token_hex(16), "offer_id": "hosted_offer", "source": "server_managed", "compatibility": self.compat, "asset_id": asset["id"]}, 201)["deposit"]

    def rental(self):
        room = self.call(self.alice, "POST", "/v1/rooms", {"name": "Rental", "mode": "rental_singles", "compatibility": self.compat}, 201)["room"]
        self.base = "/v1/rooms/" + room["code"]
        self.call(self.bob, "POST", self.base + "/join", {"compatibility": self.compat})
        return self.call(self.alice, "POST", self.base + "/draft", {})["room"]

    def pick(self, room, **extra):
        draft = room["draft"]
        person = self.alice if draft["next_owner_id"] == self.alice["identity"]["id"] else self.bob
        return self.call(person, "POST", self.base + "/pick", {"draft_id": draft["id"], "pick_index": draft["pick_index"], "slot": draft["remaining"][0], **extra})["room"]

    def hall(self):
        hall = self.call(self.alice, "POST", "/v1/halls", {"name": "Lobby", "compatibility": self.compat})["hall"]
        self.hall_base = "/v1/halls/" + hall["code"]
        return self.call(self.bob, "POST", self.hall_base + "/join", {"compatibility": self.compat})["hall"]

    def route(self):
        self.boss()
        self.call(self.alice, "POST", self.battle_base + "/abort", {})
        dungeon = self.call(self.alice, "POST", "/v1/dungeons", {"room_code": self.code}, 201)["dungeon"]
        self.route_base = "/v1/dungeons/" + dungeon["id"]
        return dungeon

    def route_start(self):
        self.call(self.alice, "POST", self.route_base + "/ready", {"ready": True})
        dungeon = self.call(self.bob, "POST", self.route_base + "/ready", {"ready": True})["dungeon"]
        self.battle_id = dungeon["battle_id"]
        self.battle_base = "/v1/battles/" + self.battle_id
        self.resolve(0)
        return dungeon

    def route_win(self, item=None):
        self.route_start()
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        states = {owner: [{"hp": 50, "totalhp": 100, "status": "POISON", "status_count": 2, "pp": [10, 20], "total_pp": [20, 35], "item": item} for _ in range(3)] for owner in self.players}
        self.resolve(1, 1, {**copy.deepcopy(self.state), "team_states": states})
        dungeon = self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": self.battle_id, "team_states": states})["dungeon"]
        return dungeon, states

    def ended_battle(self):
        self.boss()
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        self.resolve(1, 1)
        replay = self.call(self.alice, "POST", "/v1/replays", {"battle_id": self.battle_id}, 201)["replay"]
        self.replay_base = "/v1/replays/" + replay["id"]
        return replay

    def test_pool_distinct_owners_matching_and_private_receipts(self):
        first = self.deposit(self.alice)
        second = self.deposit(self.bob, "EEVEE")
        self.assertEqual(second["status"], "matched")
        a = self.call(self.alice, "GET", "/v1/pool/deposits/" + first["id"])["deposit"]
        self.assertEqual(a["transaction_id"], second["transaction_id"])
        self.assertEqual(a["receipt"]["received_snapshot"], v2.trade_snapshot("EEVEE"))
        self.assertEqual(second["receipt"]["received_snapshot"], v2.trade_snapshot())
        self.call(self.eve, "GET", "/v1/pool/deposits/" + first["id"], expected=403)
        self.call(self.alice, "POST", "/v1/pool/deposits/" + first["id"] + "/withdraw", {}, 409)

    def test_pool_single_pending_version_source_and_ack(self):
        first = self.deposit(self.alice)
        self.call(self.alice, "POST", "/v1/pool/deposits", {"deposit_id": "pool_" + secrets.token_hex(16), "source": "local_casual", "compatibility": self.compat, "offer_id": "second", "snapshot": v2.trade_snapshot()}, 409)
        other = self.deposit(self.bob, compatibility={**self.compat, "mods_hash": "different"})
        self.assertEqual(other["status"], "waiting")
        withdrawn = self.call(self.alice, "POST", "/v1/pool/deposits/" + first["id"] + "/withdraw", {})["deposit"]
        self.assertEqual(withdrawn["receipt"]["kind"], "return")
        self.call(self.alice, "POST", "/v1/pool/deposits/" + first["id"] + "/ack", {"transaction_id": "wrong"}, 409)
        complete = self.call(self.alice, "POST", "/v1/pool/deposits/" + first["id"] + "/ack", {"transaction_id": withdrawn["transaction_id"]})["deposit"]
        self.assertEqual(complete["status"], "completed")
        self.deposit(self.alice)

    def test_pool_expiry_return_restart_and_repeated_ack(self):
        first = self.deposit(self.alice)
        self.clock.advance(86401)
        self.restart()
        expired = self.call(self.alice, "GET", "/v1/pool/deposits/" + first["id"])["deposit"]
        self.assertEqual(expired["status"], "expired")
        self.assertEqual(expired["receipt"]["received_snapshot"], v2.trade_snapshot())
        for _ in range(2):
            self.call(self.alice, "POST", "/v1/pool/deposits/" + first["id"] + "/ack", {"transaction_id": expired["transaction_id"]})

    def test_pool_withdraw_match_race_unique_destination(self):
        first = self.deposit(self.alice)
        def withdraw():
            return self.store.request("POST", "/v1/pool/deposits/" + first["id"] + "/withdraw", {"request_id": "race_withdraw_pool"}, self.alice["token"])
        def match():
            return self.store.request("POST", "/v1/pool/deposits", {"request_id": "race_match_pool", "deposit_id": "pool_" + secrets.token_hex(16), "offer_id": "race", "source": "local_casual", "compatibility": self.compat, "snapshot": v2.trade_snapshot("EEVEE")}, self.bob["token"])
        with ThreadPoolExecutor(max_workers=2) as executor:
            result = list(executor.map(lambda fn: fn(), (withdraw, match)))
        self.assertIn(result[0][0], (200, 409))
        self.assertEqual(result[1][0], 201)
        final = self.call(self.alice, "GET", "/v1/pool/deposits/" + first["id"])["deposit"]
        self.assertIn((final["status"], final["receipt"]["kind"]), (("withdrawn", "return"), ("matched", "exchange")))

    def test_hosted_starter_once_no_import_or_client_reward_mint(self):
        first = self.starter(self.alice)
        second = self.call(self.alice, "POST", "/v1/collections/starter", {"catalog_version": 1})["asset"]
        self.assertEqual(first, second)
        self.call(self.alice, "POST", "/v1/collections/starter", {"catalog_version": 1, "snapshot": pokemon("MEW")}, 400)
        self.call(self.alice, "POST", "/v1/collections/import", {"snapshot": pokemon()}, 404)
        self.assertEqual(len(self.call(self.alice, "GET", "/v1/collections")["assets"]), 1)
        self.restart()
        self.assertEqual(self.call(self.alice, "POST", "/v1/collections/starter", {"catalog_version": 1})["asset"], first)

    def test_hosted_pool_atomic_owner_swap_and_old_showcase_unpublish(self):
        first, second = self.starter(self.alice), self.starter(self.bob)
        showcase = self.call(self.alice, "POST", "/v1/collections/" + first["id"] + "/showcase", {})["showcase"]
        one = self.hosted_deposit(self.alice, first)
        self.assertTrue(self.call(self.alice, "GET", "/v1/collections")["assets"][0]["locked"])
        two = self.hosted_deposit(self.bob, second)
        self.assertEqual(two["receipt"]["received_asset"]["id"], first["id"])
        self.assertEqual(self.call(self.alice, "GET", "/v1/collections")["assets"][0]["id"], second["id"])
        self.call(self.eve, "GET", "/v1/showcases/" + showcase["code"], expected=404)
        # Repeating the starter grant cannot mint an asset after ownership moved.
        prior = self.call(self.alice, "POST", "/v1/collections/starter", {"catalog_version": 1})["asset"]
        self.assertEqual(prior["owner_id"], self.bob["identity"]["id"])
        self.assertEqual(len(self.call(self.alice, "GET", "/v1/collections")["assets"]), 1)

    def test_hosted_foreign_asset_source_mix_and_lock_rejected(self):
        first = self.starter(self.alice)
        self.call(self.eve, "POST", "/v1/pool/deposits", {"deposit_id": "pool_" + secrets.token_hex(16), "offer_id": "fake", "source": "server_managed", "compatibility": self.compat, "asset_id": first["id"]}, 403)
        self.hosted_deposit(self.alice, first)
        self.assertEqual(self.deposit(self.bob)["status"], "waiting")
        trade = self.call(self.alice, "POST", "/v1/trades", {"source": "server_managed", "compatibility": self.compat}, 201)["trade"]
        self.call(self.alice, "POST", "/v1/trades/" + trade["code"] + "/offer", {"asset_id": first["id"], "offer_id": "double"}, 409)

    def test_hosted_friend_trade_owner_swap_and_restart(self):
        first, second = self.starter(self.alice), self.starter(self.bob)
        trade = self.call(self.alice, "POST", "/v1/trades", {"source": "server_managed", "compatibility": self.compat}, 201)["trade"]
        self.trade_base = "/v1/trades/" + trade["code"]
        self.call(self.bob, "POST", self.trade_base + "/join", {"source": "local_casual", "compatibility": self.compat}, 409)
        self.call(self.bob, "POST", self.trade_base + "/join", {"source": "server_managed", "compatibility": self.compat})
        for person, asset in ((self.alice, first), (self.bob, second)):
            trade = self.call(person, "POST", self.trade_base + "/offer", {"asset_id": asset["id"], "offer_id": "individual"})["trade"]
        self.confirm(self.alice, trade)
        committed = self.confirm(self.bob, trade)
        self.assertEqual(committed["receipt"]["received_asset"]["id"], first["id"])
        self.restart()
        self.assertEqual(self.call(self.alice, "GET", self.trade_base)["trade"]["receipt"]["received_asset"]["id"], second["id"])
        self.assertEqual(self.call(self.alice, "GET", "/v1/collections")["assets"][0]["id"], second["id"])

    def test_hosted_expired_trade_releases_asset_lock(self):
        asset = self.starter(self.alice)
        trade = self.call(self.alice, "POST", "/v1/trades", {"source": "server_managed", "compatibility": self.compat}, 201)["trade"]
        base = "/v1/trades/" + trade["code"]
        self.call(self.alice, "POST", base + "/offer", {"asset_id": asset["id"], "offer_id": "expiring"})
        self.clock.advance(86401)
        self.call(self.alice, "GET", base)
        self.assertFalse(self.call(self.alice, "GET", "/v1/collections")["assets"][0]["locked"])

    def test_hosted_old_unqueried_trade_lock_expires_on_next_asset_operation(self):
        asset = self.starter(self.alice)
        trade = self.call(self.alice, "POST", "/v1/trades", {"source": "server_managed", "compatibility": self.compat}, 201)["trade"]
        self.call(self.alice, "POST", "/v1/trades/" + trade["code"] + "/offer", {"asset_id": asset["id"], "offer_id": "old"})
        self.clock.advance(86401)
        deposit = self.hosted_deposit(self.alice, asset)
        self.assertEqual(deposit["status"], "waiting")

    def test_rental_abbaab_complete_uses_frozen_server_teams(self):
        room = self.rental()
        draft = room["draft"]
        a, b = draft["order"][:2]
        self.assertEqual(draft["order"], [a, b, b, a, a, b])
        for _ in range(6):
            room = self.pick(room)
        self.assertEqual(room["status"], "playing")
        self.assertEqual(room["draft"]["status"], "complete")
        self.assertEqual(sum(len(picks) for picks in room["draft"]["picks"].values()), 6)
        battle = self.call(self.alice, "GET", "/v1/battles/" + room["battle_id"])["battle"]
        self.assertEqual(battle["mode"], "rental_singles")
        self.assertEqual(len(battle["initial_teams"][self.alice["identity"]["id"]]), 3)

    def test_rental_wrong_owner_duplicate_slot_and_configuration_frozen(self):
        room = self.rental()
        draft = room["draft"]
        wrong = self.bob if draft["next_owner_id"] == self.alice["identity"]["id"] else self.alice
        self.call(wrong, "POST", self.base + "/pick", {"draft_id": draft["id"], "pick_index": draft["pick_index"], "slot": 0}, 409)
        self.call(self.alice, "POST", self.base + "/configure", {"name": "changed"}, 409)
        room = self.pick(room)
        next_person = self.alice if room["draft"]["next_owner_id"] == self.alice["identity"]["id"] else self.bob
        self.call(next_person, "POST", self.base + "/pick", {"draft_id": draft["id"], "pick_index": room["draft"]["pick_index"], "slot": 0}, 409)

    def test_rental_late_consecutive_pick_does_not_choose_twice(self):
        room = self.pick(self.rental())
        draft = room["draft"]
        person = self.alice if draft["next_owner_id"] == self.alice["identity"]["id"] else self.bob
        for _ in range(6):
            self.clock.advance(5)
            # Keep presence alive without triggering the draft timer itself.
            with self.store.connect() as db:
                saved = self.store.room(db, self.base.rsplit("/", 1)[1])
                for presence in saved["draft"]["presence"].values():
                    presence["last_seen"] = self.clock()
                self.store.save_room(db, saved)
        self.call(person, "POST", self.base + "/pick", {"draft_id": draft["id"], "pick_index": 1, "slot": draft["remaining"][1]}, 409)
        current = self.call(person, "GET", self.base)["room"]["draft"]
        self.assertEqual(current["pick_index"], 2)
        self.assertIn(draft["remaining"][1], current["remaining"])

    def test_rental_cannot_upload_local_party_or_skip_draft(self):
        room = self.call(self.alice, "POST", "/v1/rooms", {"name": "Rental", "mode": "rental_singles", "compatibility": self.compat}, 201)["room"]
        base = "/v1/rooms/" + room["code"]
        self.call(self.alice, "POST", base + "/team", {"candidates": [pokemon()] * 3, "selected": [0, 1, 2]}, 409)
        self.call(self.alice, "POST", base + "/ready", {"ready": True}, 409)
        self.call(self.alice, "POST", base + "/start", {}, 409)

    def test_rental_timeout_default_and_cumulative_reconnect_battle(self):
        room = self.rental()
        self.clock.advance(10)
        self.call(self.alice, "GET", self.base)
        room = self.call(self.bob, "GET", self.base)["room"]
        remaining = room["draft"]["reconnect_remaining"][self.bob["identity"]["id"]]
        self.assertLess(remaining, 60)
        for _ in range(6):
            for _ in range(7):
                self.clock.advance(5)
                self.call(self.alice, "GET", self.base)
                room = self.call(self.bob, "GET", self.base)["room"]
            if room["status"] == "playing":
                break
        self.assertEqual(room["status"], "playing")
        battle = self.call(self.alice, "GET", "/v1/battles/" + room["battle_id"])["battle"]
        self.assertLess(battle["reconnect_remaining"][self.bob["identity"]["id"]], 60)

    def test_rental_disconnect_cancel_and_catalog_mismatch(self):
        self.rental()
        self.clock.advance(70)
        room = self.call(self.alice, "GET", self.base)["room"]
        self.assertEqual(room["draft"]["status"], "cancelled")
        self.catalog_file.write_text(json.dumps({"version": 1, "compatibility": {**self.compat, "data_hash": "wrong"}, "pokemon": [pokemon()] * 12}), encoding="utf-8")
        self.call(self.alice, "POST", self.base + "/draft", {}, 409)

    def test_hall_capacity_positions_sequence_and_privacy(self):
        self.hall()
        fourth, fifth = self.identity("Fourth"), self.identity("Fifth")
        for person in (self.eve, fourth):
            self.call(person, "POST", self.hall_base + "/join", {"compatibility": self.compat})
        self.call(fifth, "POST", self.hall_base + "/join", {"compatibility": self.compat}, 409)
        self.call(fifth, "GET", self.hall_base, expected=403)
        for seq, x in ((2, 12), (1, 1)):
            hall = self.call(self.alice, "POST", self.hall_base + "/move", {"seq": seq, "x": x, "y": 4, "direction": 6})["hall"]
        member = next(member for member in hall["members"] if member["id"] == self.alice["identity"]["id"])
        self.assertEqual((member["seq"], member["x"]), (2, 12))
        self.call(self.alice, "POST", self.hall_base + "/move", {"seq": 3, "x": 20, "y": 4, "direction": 6}, 400)

    def test_hall_invite_accept_creates_real_two_player_room(self):
        self.hall()
        hall = self.call(self.alice, "POST", self.hall_base + "/invite", {"target_id": self.bob["identity"]["id"], "kind": "battle"})["hall"]
        invite = hall["invites"][-1]
        self.call(self.alice, "POST", self.hall_base + "/accept", {"invite_id": invite["id"]}, 404)
        accepted = self.call(self.bob, "POST", self.hall_base + "/accept", {"invite_id": invite["id"]})["hall"]
        room_code = accepted["invites"][-1]["room_code"]
        self.assertEqual(len(self.call(self.alice, "GET", "/v1/rooms/" + room_code)["room"]["members"]), 2)
        self.clock.advance(31)
        active = self.call(self.alice, "GET", self.hall_base)["hall"]
        self.assertEqual(len(active["members"]), 2)
        self.assertTrue(all(member["status"] == "battle" for member in active["members"]))

    def test_hall_invite_trade_and_expire_idle(self):
        self.hall()
        hall = self.call(self.alice, "POST", self.hall_base + "/invite", {"target_id": self.bob["identity"]["id"], "kind": "trade"})["hall"]
        accepted = self.call(self.bob, "POST", self.hall_base + "/accept", {"invite_id": hall["invites"][-1]["id"]})["hall"]
        code = accepted["invites"][-1]["trade_code"]
        self.assertEqual(len(self.call(self.alice, "GET", "/v1/trades/" + code)["trade"]["members"]), 2)
        self.call(self.alice, "POST", "/v1/trades/" + code + "/cancel", {})
        self.clock.advance(31)
        self.call(self.alice, "GET", self.hall_base, expected=403)

    def test_dungeon_full_route_preserves_state_rest_and_unique_medal(self):
        self.route()
        dungeon, states = self.route_win()
        self.assertEqual(dungeon["team_states"], states)
        for _ in range(2):
            dungeon, states = self.route_win()
        self.assertEqual(dungeon["status"], "rest")
        for person in (self.alice, self.bob):
            dungeon = self.call(person, "POST", self.route_base + "/rest", {"choice": "heal"})["dungeon"]
        self.assertTrue(all(state["hp"] == state["totalhp"] and state["item"] is None and state["status"] == "NONE" for party in dungeon["team_states"].values() for state in party))
        dungeon, _ = self.route_win()
        self.assertEqual(dungeon["status"], "completed")
        reward = self.call(self.alice, "POST", self.route_base + "/claim", {})["reward"]
        self.assertEqual(reward, self.call(self.alice, "POST", self.route_base + "/claim", {})["reward"])
        self.assertEqual(len(dungeon["history"]), 4)

    def test_dungeon_abnormal_restart_once_uses_prestate(self):
        self.route()
        self.route_win()
        before = self.route_start()
        self.restart()
        retry = self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": before["battle_id"], "team_states": {"forged": []}})["dungeon"]
        self.assertEqual(retry["status"], "preparing")
        self.assertTrue(retry["retry_used"])
        self.assertEqual(retry["team_states"], before["team_states"])
        second = self.route_start()
        self.call(self.alice, "POST", self.battle_base + "/abort", {})
        failed = self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": second["battle_id"]})["dungeon"]
        self.assertEqual(failed["status"], "failed")
        self.call(self.bob, "POST", self.route_base + "/claim", {}, 409)

    def test_dungeon_original_item_cannot_regenerate_and_duplicate_advance(self):
        self.route()
        dungeon, _ = self.route_win()
        prior_battle = dungeon["history"][0]["battle_id"]
        repeated = self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": prior_battle})["dungeon"]
        self.assertEqual(len(repeated["history"]), 1)
        self.route_start()
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        self.resolve(1, 1, {**copy.deepcopy(self.state), "team_states": dungeon["team_states"]})
        forged = copy.deepcopy(dungeon["team_states"])
        forged[self.players[0]][0]["item"] = "ORANBERRY"
        self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": self.battle_id, "team_states": forged}, 409)
        self.call(self.eve, "GET", self.route_base, expected=403)

    def test_replay_active_private_consent_and_download_compatibility(self):
        self.boss()
        self.call(self.alice, "POST", "/v1/replays", {"battle_id": self.battle_id}, 409)
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        self.resolve(1, 1)
        replay = self.call(self.alice, "POST", "/v1/replays", {"battle_id": self.battle_id}, 201)["replay"]
        self.replay_base = "/v1/replays/" + replay["id"]
        self.call(self.eve, "GET", self.replay_base, expected=403)
        self.call(self.alice, "POST", self.replay_base + "/consent", {"consent": True})
        self.call(self.alice, "POST", self.replay_base + "/publish", {"visibility": "public"}, 409)
        self.call(self.bob, "POST", self.replay_base + "/consent", {"consent": True})
        self.call(self.alice, "POST", self.replay_base + "/publish", {"visibility": "public"})
        self.call(self.eve, "POST", self.replay_base + "/download", {"compatibility": {**self.compat, "mods_hash": "wrong"}}, 409)
        shared = self.call(self.eve, "POST", self.replay_base + "/download", {"compatibility": self.compat})["replay"]
        self.assertEqual(set(shared["data"]["initial_teams"]), set(self.players))
        self.assertEqual(len(shared["data"]["updates"]), 2)

    def test_replay_unpublish_rechecks_even_same_download_request_id(self):
        self.ended_battle()
        for person in (self.alice, self.bob):
            self.call(person, "POST", self.replay_base + "/consent", {"consent": True})
        self.call(self.alice, "POST", self.replay_base + "/publish", {"visibility": "unlisted"})
        self.call(self.eve, "POST", self.replay_base + "/download", {"compatibility": self.compat, "request_id": "download_same_operation"})
        self.call(self.bob, "POST", self.replay_base + "/consent", {"consent": False})
        self.call(self.eve, "POST", self.replay_base + "/download", {"compatibility": self.compat, "request_id": "download_same_operation"}, 403)
        self.restart()
        private = self.call(self.alice, "GET", self.replay_base)["replay"]
        self.assertEqual(private["status"], "private")


class V3HTTPTests(unittest.TestCase):
    identity = V3Tests.identity
    call = v2.V2HTTPTests.call
    http = v2.V2HTTPTests.http
    deposit = V3Tests.deposit
    starter = V3Tests.starter
    hosted_deposit = V3Tests.hosted_deposit
    rental = V3Tests.rental
    pick = V3Tests.pick
    hall = V3Tests.hall

    def setUp(self):
        V3Tests.setUp(self)
        self.server = make_server("127.0.0.1", 0, self.store)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.url = "http://127.0.0.1:%s" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=3)
        V3Tests.tearDown(self)

    def test_real_http_local_and_hosted_pools_hall_and_rental(self):
        first, second = self.deposit(self.alice), self.deposit(self.bob, "EEVEE")
        for person, deposit in ((self.alice, first), (self.bob, second)):
            current = self.call(person, "GET", "/v1/pool/deposits/" + deposit["id"])["deposit"]
            self.call(person, "POST", "/v1/pool/deposits/" + deposit["id"] + "/ack", {"transaction_id": current["transaction_id"]})
        first_asset, second_asset = self.starter(self.alice), self.starter(self.bob)
        hosted = self.hosted_deposit(self.alice, first_asset)
        matched = self.hosted_deposit(self.bob, second_asset)
        self.assertEqual(matched["receipt"]["received_asset"]["id"], first_asset["id"])
        self.hall()
        moved = self.call(self.alice, "POST", self.hall_base + "/move", {"seq": 1, "x": 3, "y": 4, "direction": 6})["hall"]
        own = next(member for member in moved["members"] if member["id"] == self.alice["identity"]["id"])
        self.assertEqual(own["x"], 3)
        room = self.rental()
        for _ in range(6):
            room = self.pick(room)
        self.assertTrue(room["battle_id"].startswith("b_"))


if __name__ == "__main__":
    unittest.main()
