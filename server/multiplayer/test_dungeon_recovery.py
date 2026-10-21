"""Full-party authority snapshots close the resolve/advance crash window."""
import copy
import json
import unittest

import test_v3 as fixtures
from service import APIError, validate_state
from test_service import pokemon


class DungeonRecoveryTests(unittest.TestCase):
    setUp = fixtures.V3Tests.setUp
    tearDown = fixtures.V3Tests.tearDown
    identity = fixtures.V3Tests.identity
    call = fixtures.V3Tests.call
    restart = fixtures.V3Tests.restart
    route = fixtures.V3Tests.route
    route_start = fixtures.V3Tests.route_start
    route_win = fixtures.V3Tests.route_win
    boss = fixtures.V3Tests.boss
    resolve = fixtures.V3Tests.resolve
    command = fixtures.V3Tests.command

    def states(self):
        return {owner: [{"hp": 77 - index, "totalhp": 100, "status": "POISON" if index == 2 else "NONE", "status_count": index, "pp": [12 - index, 17], "total_pp": [20, 35], "item": None} for index in range(3)] for owner in self.players}

    def win_without_advance(self, durable=True):
        self.route_start()
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        states = self.states()
        state = {**copy.deepcopy(self.state), "team_states": states} if durable else self.state
        battle = self.resolve(1, 1, state)
        return battle, states

    def test_resolve_then_crash_restart_advance_uses_all_party_authority(self):
        self.route()
        battle, states = self.win_without_advance()
        self.assertEqual(battle["result"]["team_states"], states)
        self.call(self.alice, "POST", self.battle_base + "/claim", {}, 409)
        self.restart()
        persisted = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(persisted["state"]["team_states"], states)
        dungeon = self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": self.battle_id})["dungeon"]
        self.assertEqual(dungeon["node_index"], 1)
        self.assertEqual(dungeon["team_states"], states)
        self.assertFalse(dungeon["retry_used"])
        self.assertEqual(dungeon["history"][0]["post_state"], states)
        self.assertEqual(dungeon["team_states"][self.players[1]][2]["pp"], [10, 17])

    def test_explicit_post_must_match_committed_authority(self):
        self.route()
        _, states = self.win_without_advance()
        changed = copy.deepcopy(states)
        changed[self.players[1]][2]["hp"] += 1
        response = self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": self.battle_id, "team_states": changed}, 409)
        self.assertEqual(response["error"]["code"], "post_state_mismatch")
        route = self.call(self.alice, "GET", self.route_base)["dungeon"]
        self.assertEqual(route["history"], [])
        malformed = copy.deepcopy(states)
        malformed[self.players[0]][0]["hp"] = True
        self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": self.battle_id, "team_states": malformed}, 400)
        route = self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": self.battle_id, "team_states": states})["dungeon"]
        self.assertEqual(route["team_states"], states)

    def test_missing_authority_never_fabricates_or_trusts_late_state(self):
        self.route()
        _, states = self.win_without_advance(False)
        for body in ({"battle_id": self.battle_id}, {"battle_id": self.battle_id, "team_states": states}):
            result = self.call(self.alice, "POST", self.route_base + "/advance", body, 409)
            self.assertEqual(result["error"]["code"], "post_state_unavailable")
        self.assertIsNone(self.call(self.alice, "GET", self.route_base)["dungeon"]["team_states"])

    def test_team_states_coop_only_and_strict_json(self):
        self.boss()
        state = {**copy.deepcopy(self.state), "team_states": self.states()}
        for mode in ("friendly_singles", "rental_singles"):
            with self.assertRaises(APIError) as caught:
                validate_state(state, self.players, mode)
            self.assertEqual(caught.exception.code, "unknown_field")
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        for mutate in (lambda data: data[self.players[0]][0].update(hp=True), lambda data: data[self.players[0]][1].update(pp=[999, 1]), lambda data: data[self.players[0]][2].update(item="../../file"), lambda data: data[self.players[0]][0].update(extra="unexpected")):
            malformed = self.states()
            mutate(malformed)
            self.call(self.alice, "POST", self.battle_base + "/resolve", {"turn": 1, "state": {**copy.deepcopy(self.state), "team_states": malformed}, "digest": "a" * 64, "decision": 1}, 400)
        valid = self.resolve(1, 1, state)
        self.assertEqual(valid["result"]["team_states"], state["team_states"])

    def test_legal_item_transfer_and_recycle_stay_inside_frozen_item_set(self):
        self.boss()
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        with self.store.connect() as db:
            battle = self.store.battle(db, self.battle_id)
            battle["initial_teams"][self.players[1]][0]["item"] = "LEFTOVERS"
            battle["state"]["team_states"] = self.states()  # Earlier frame had consumed held items.
            self.store.save_battle(db, battle)
        transferred = self.states()
        transferred[self.players[0]][0]["item"] = "LEFTOVERS"
        transferred[self.players[1]][0]["item"] = "ORANBERRY"
        invalid = copy.deepcopy(transferred)
        invalid[self.players[0]][0]["item"] = "MASTERBALL"
        self.call(self.alice, "POST", self.battle_base + "/resolve", {"turn": 1, "state": {**copy.deepcopy(self.state), "team_states": invalid}, "digest": "a" * 64, "decision": 1}, 400)
        finished = self.resolve(1, 1, {**copy.deepcopy(self.state), "team_states": transferred})
        self.assertEqual(finished["result"]["team_states"], transferred)

    def test_expiry_closes_active_battle_and_never_awards(self):
        route = self.route()
        self.route_start()
        self.assertEqual(route["expires_at"], route["created_at"] + 86400)
        self.clock.advance(86401)
        denied = self.call(self.alice, "POST", self.route_base + "/claim", {}, 409)
        self.assertEqual(denied["error"]["code"], "route_expired")
        with self.store.connect() as db:
            stored = json.loads(db.execute("SELECT document FROM dungeons WHERE id=?", (route["id"],)).fetchone()[0])
            self.assertEqual(stored["status"], "expired")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM rewards").fetchone()[0], 0)
        battle = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["status"], "abnormal")
        self.assertEqual(battle["result"]["reason"], "route_expired")
        self.restart()
        self.assertEqual(self.call(self.alice, "GET", self.route_base)["dungeon"]["status"], "expired")

    def test_battle_poll_alone_applies_route_expiry(self):
        self.route()
        self.route_start()
        self.clock.advance(86401)
        battle = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(battle["result"]["reason"], "route_expired")
        self.assertEqual(self.call(self.bob, "GET", self.route_base)["dungeon"]["status"], "expired")

    def test_same_participant_cannot_open_parallel_route_in_another_room(self):
        first = self.route()
        room = self.call(self.alice, "POST", "/v1/rooms", {"name": "Other pair", "mode": "coop_boss", "compatibility": self.compat}, 201)["room"]
        base = "/v1/rooms/" + room["code"]
        self.call(self.eve, "POST", base + "/join", {"compatibility": self.compat})
        for person in (self.alice, self.eve):
            self.call(person, "POST", base + "/team", {"candidates": [pokemon()] * 3, "selected": [0, 1, 2]})
        denied = self.call(self.alice, "POST", "/v1/dungeons", {"room_code": room["code"]}, 409)
        self.assertEqual(denied["error"]["code"], "route_active")
        self.assertEqual(denied["error"]["details"]["dungeon_id"], first["id"])
        self.clock.advance(86399)
        self.call(self.alice, "POST", base + "/configure", {"name": "Still-open other room"})
        self.clock.advance(2)
        # The old route expires while the other room remains recently active.
        new_route = self.call(self.alice, "POST", "/v1/dungeons", {"room_code": room["code"]}, 201)["dungeon"]
        self.assertNotEqual(new_route["id"], first["id"])

    def test_legacy_route_expiry_migration_keeps_original_deadline(self):
        route = self.route()
        with self.store.connect() as db:
            del route["expires_at"]
            self.store.save_dungeon(db, route)
        self.clock.advance(100)
        self.restart()
        migrated = self.call(self.alice, "GET", self.route_base)["dungeon"]
        self.assertEqual(migrated["expires_at"], route["created_at"] + 86400)

    def test_route_room_cannot_start_parallel_boss_or_forge_internal_prefix(self):
        route = self.route()
        _, states = self.win_without_advance()
        room_base = "/v1/rooms/" + route["room_code"]
        for person, action, payload in ((self.alice, "ready", {"ready": True}), (self.bob, "configure", {"name": "hijack"}), (self.alice, "start", {"request_id": "node_start_" + route["id"]}), (self.alice, "team", {"candidates": [pokemon()] * 3, "selected": [0, 1, 2]}), (self.bob, "leave", {})):
            denied = self.call(person, "POST", room_base + "/" + action, payload, 409)
            self.assertEqual(denied["error"]["code"], "route_bound")
        self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": self.battle_id})
        started = self.route_start()
        with self.store.connect() as db:
            active = [json.loads(row[0]) for row in db.execute("SELECT document FROM battles") if json.loads(row[0])["room_code"] == route["room_code"] and json.loads(row[0])["status"] == "active"]
        self.assertEqual([battle["id"] for battle in active], [started["battle_id"]])

    def test_node_refuses_legacy_orphan_active_battle_without_overwriting_room(self):
        route = self.route()
        with self.store.connect() as db:
            orphan = self.store.battle(db, self.battle_id)
            orphan.update({"id": "b_legacy_orphan", "status": "active", "phase": "initializing", "result": None})
            self.store.save_battle(db, orphan)
            original_room_battle = self.store.room(db, route["room_code"])["battle_id"]
        self.call(self.alice, "POST", self.route_base + "/ready", {"ready": True})
        denied = self.call(self.bob, "POST", self.route_base + "/ready", {"ready": True}, 409)
        self.assertEqual(denied["error"]["code"], "room_battle_active")
        with self.store.connect() as db:
            self.assertEqual(self.store.room(db, route["room_code"])["battle_id"], original_room_battle)
            self.assertEqual(self.store.battle(db, "b_legacy_orphan")["status"], "active")

    def test_initial_surrender_has_no_frame_but_finishes_route_as_defeat(self):
        self.route()
        self.call(self.alice, "POST", self.route_base + "/ready", {"ready": True})
        started = self.call(self.bob, "POST", self.route_base + "/ready", {"ready": True})["dungeon"]
        battle_base = "/v1/battles/" + started["battle_id"]
        self.call(self.bob, "POST", battle_base + "/commands", {"turn": 0, "command": {"action": "surrender"}})
        failed = self.call(self.alice, "POST", self.route_base + "/advance", {"battle_id": started["battle_id"]})["dungeon"]
        self.assertEqual(failed["status"], "failed")
        self.assertIsNone(failed["history"][0]["post_state"])
        self.call(self.alice, "POST", self.route_base + "/claim", {}, 409)

    def test_abandonment_requires_two_distinct_participant_votes(self):
        route = self.route()
        first = self.call(self.alice, "POST", self.route_base + "/abandon", {})["dungeon"]
        self.assertEqual(first["status"], "preparing")
        self.assertEqual(first["abandon_votes"], [self.players[0]])
        repeated = self.call(self.alice, "POST", self.route_base + "/abandon", {})["dungeon"]
        self.assertEqual(repeated["abandon_votes"], first["abandon_votes"])
        self.call(self.eve, "POST", self.route_base + "/abandon", {}, 403)
        ended = self.call(self.bob, "POST", self.route_base + "/abandon", {})["dungeon"]
        self.assertEqual(ended["status"], "abandoned")
        self.assertEqual(set(ended["abandon_votes"]), set(self.players))
        self.call(self.alice, "POST", "/v1/rooms/" + route["room_code"] + "/configure", {"name": "Released room"})

    def test_single_abandon_vote_does_not_abort_active_node(self):
        self.route()
        self.route_start()
        self.call(self.alice, "POST", self.route_base + "/abandon", {})
        self.assertEqual(self.call(self.alice, "GET", self.battle_base)["battle"]["status"], "active")
        self.call(self.bob, "POST", self.route_base + "/abandon", {})
        ended = self.call(self.alice, "GET", self.battle_base)["battle"]
        self.assertEqual(ended["status"], "abnormal")
        self.assertEqual(ended["result"]["reason"], "route_abandoned")


if __name__ == "__main__":
    unittest.main()
