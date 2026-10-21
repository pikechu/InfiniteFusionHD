"""Cosmetic-only native renderer tape: bounded JSON and playback barriers."""
import copy
import unittest

import test_service as base
import test_v2 as v2
from service import APIError, validate_state


class VisualTests(unittest.TestCase):
    setUp = base.ServiceTests.setUp
    tearDown = base.ServiceTests.tearDown
    identity = base.ServiceTests.identity
    call = base.ServiceTests.call
    room = base.ServiceTests.room
    prepared_room = base.ServiceTests.prepared_room
    battle = base.ServiceTests.battle
    resolve = base.ServiceTests.resolve
    command = base.ServiceTests.command
    ack = base.ServiceTests.ack

    def visuals(self, seq=1):
        battlers = [{"slot": entry["index"], "species": entry["species"], "level": 50, "name": "Active", "hp": entry["hp"], "totalhp": entry["totalhp"], "status": entry["status"], "party_index": 0, "form": 0, "gender": 0, "shiny": False, "appearance": {}} for entry in self.state["battlers"]]
        return {"version": 1, "seq": seq, "complete": True, "battlers": battlers, "events": [{"kind": "move", "move_id": "TACKLE", "user": 0, "targets": [1], "hit": 0}, {"kind": "hp", "slot": 1, "from": 100, "to": 80, "totalhp": 100}, {"kind": "recall", "slot": 0}, {"kind": "replace", "pokemon": copy.deepcopy(battlers[0])}, {"kind": "faint", "slot": 1}]}

    def visual_state(self, seq=1):
        return {**copy.deepcopy(self.state), "visuals": self.visuals(seq)}

    def test_initial_native_intro_waits_for_playback_ack_before_timer(self):
        self.battle()
        with self.store.connect() as db:
            battle = self.store.battle(db, self.battle_id)
            battle.update({"turn": 0, "phase": "initializing", "state": {}, "updates": [], "commands": {}, "deadline": None})
            self.store.save_battle(db, battle)
        initial = self.resolve(0, 0, self.visual_state())
        self.assertEqual((initial["turn"], initial["phase"], initial["deadline"]), (0, "playback", None))
        for _ in range(7):
            self.clock.advance(5)
            self.call(self.alice, "GET", self.battle_base)
            waiting = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(waiting["phase"], "playback")
        next_phase = self.ack(0)
        self.assertEqual((next_phase["turn"], next_phase["phase"]), (1, "commands"))
        self.assertEqual(next_phase["deadline"], self.clock() + 60)

    def test_visuals_cannot_publish_until_both_commands_locked(self):
        self.battle()
        self.command(self.alice, 1)
        hidden = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertNotIn("commands", hidden)
        self.assertNotIn("visuals", hidden["state"])
        self.call(self.alice, "POST", self.battle_base + "/resolve", {"turn": 1, "state": self.visual_state(), "digest": "a" * 64, "decision": 0}, 409)
        self.command(self.bob, 1)
        self.resolve(1, 0, self.visual_state())
        public = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(public["state"]["visuals"], self.visuals())
        self.assertEqual(set(public["state"]["actions"]), {self.players[1]})
        self.assertNotIn("initial_teams", public)
        self.assertNotIn("random_tape", public["updates"][-1])

    def test_visual_sequence_and_idempotent_final_resolution(self):
        self.battle()
        for person in (self.alice, self.bob):
            self.command(person, 1)
        self.resolve(1, 0, self.visual_state())
        self.ack(1)
        for person in (self.alice, self.bob):
            self.command(person, 2)
        self.call(self.alice, "POST", self.battle_base + "/resolve", {"turn": 2, "state": self.visual_state(), "digest": "a" * 64, "decision": 1}, 409)
        body = {"request_id": "visual_final_once", "turn": 2, "state": self.visual_state(2), "digest": "a" * 64, "decision": 1}
        first = self.call(self.alice, "POST", self.battle_base + "/resolve", body)
        repeated = self.call(self.alice, "POST", self.battle_base + "/resolve", body)
        self.assertEqual(first, repeated)
        final = self.call(self.bob, "GET", self.battle_base)["battle"]
        self.assertEqual(final["status"], "finished")
        self.assertEqual(final["state"]["visuals"]["seq"], 2)
        self.assertEqual(len(final["updates"]), 3)

    def test_visuals_strict_fields_bounds_slots_and_paths(self):
        self.battle()
        mutations = [
            lambda v: v.update(script="Kernel.exit"),
            lambda v: v.update(version=True),
            lambda v: v.update(seq=0),
            lambda v: v.update(complete="true"),
            lambda v: v.update(events=[{"kind": "faint", "slot": 1}] * 129),
            lambda v: v["battlers"][0].update(moves=["SECRET_BENCH_MOVE"]),
            lambda v: v["battlers"][0].update(slot=3),
            lambda v: v["battlers"][0].update(appearance={"kuraycustomfile": "../../private.png"}),
            lambda v: v["battlers"][0].update(appearance={"head_shiny": "true"}),
            lambda v: v["battlers"][0].update(status={"bad": "object"}),
            lambda v: v["events"][0].update(move_id="../../private"),
            lambda v: v["events"][0].update(targets=[1, 1]),
            lambda v: v["events"][0].update(user=3),
            lambda v: v["events"][0].update(code="arbitrary Ruby"),
            lambda v: v["events"][1].update(to=101),
            lambda v: v["events"][2].update(kind="execute"),
            lambda v: v["battlers"].append(copy.deepcopy(v["battlers"][0])),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(case=index):
                visuals = self.visuals()
                mutate(visuals)
                with self.assertRaises(APIError):
                    validate_state({**copy.deepcopy(self.state), "visuals": visuals}, self.players)

    def test_coop_third_public_slot_and_bounded_partial_tape(self):
        v2.V2Tests.boss(self)
        self.command(self.alice, 1)
        self.command(self.bob, 1, {"action": "move", "move_index": 0, "target": 1})
        state = self.visual_state()
        state["visuals"]["complete"] = False
        state["visuals"]["events"][0]["targets"] = [0, 1, 2]
        battle = self.resolve(1, 1, state)
        self.assertEqual(battle["result"]["coop_outcome"], "victory")
        self.assertEqual(len(battle["state"]["visuals"]["battlers"]), 3)
        self.assertFalse(battle["state"]["visuals"]["complete"])


if __name__ == "__main__":
    unittest.main()
