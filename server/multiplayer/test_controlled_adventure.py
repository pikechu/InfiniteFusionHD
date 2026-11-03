import concurrent.futures
import copy
import json
import sqlite3
import unittest
import uuid
from unittest.mock import patch

import controlled_engine as engine
import test_admin as fixtures
from test_historical_v1_support import HistoricalV1Store as Store
import test_controlled as controlled_fixtures


class AdventureTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    game = fixtures.AdminTests.game
    tearDown = fixtures.AdminTests.tearDown
    catalog = controlled_fixtures.ControlledTests.catalog
    create = controlled_fixtures.ControlledTests.create
    state = controlled_fixtures.ControlledTests.state
    change = controlled_fixtures.ControlledTests.change

    def setUp(self):
        with patch.object(fixtures, "Store", Store):
            fixtures.AdminTests.setUp(self)
        self.character = self.create()["character"]
        self.rules = self.store.adventure_catalog()
        self.intent("starter", species="BULBASAUR")

    def intent_body(self, action, **fields):
        return {"request_id": uuid.uuid4().hex, "expected_revision": self.character["revision"],
                "expected_wallet_revision": self.character["wallet"]["revision"], "rules_hash": self.rules["hash"], "action": action, **fields}

    def intent(self, action, expected=200, person=None, **fields):
        result = self.game("controlled/characters/" + self.character["id"] + "/adventure",
                           self.intent_body(action, **fields), expected=expected, person=person)
        if expected == 200:
            self.character = result["character"]
        return result

    def view(self):
        status, result = self.store.request("GET", "/v1/controlled/characters/" + self.character["id"] + "/adventure", token=self.alice["token"])
        self.assertEqual(status, 200, result)
        self.character = result["character"]
        return result["adventure"]

    def start(self, kind="trainer", entry="chapter-0"):
        self.clock.advance(2)
        return self.intent("start", kind=kind, entry=entry)["adventure"]["battle"]

    def move(self, battle, expected=200, **fields):
        active = battle["party"][battle["active"]]
        slots = [(index, self.rules["moves"][row["id"]]["base_damage"]) for index, row in enumerate(active["moves"]) if row["pp"] > 0]
        slot = max(slots, key=lambda entry: entry[1])[0] if slots else -1
        return self.intent("turn", battle_id=battle["id"], expected_round=battle["round"], command={"kind": "move", "slot": slot}, expected=expected, **fields)

    def win_intro(self):
        with patch.object(engine.BattleRandom, "randrange", return_value=0):
            battle = self.start()
            for _ in range(50):
                result = self.move(battle)
                battle = result["settled_battle"]
                if battle["status"] != "active":
                    break
        self.assertEqual(battle["outcome"], "win", battle)
        return result

    def mint_fixture(self, species="BULBASAUR", level=5, **fields):
        monster = engine.make_monster(self.rules, species, level)
        monster.update(fields)
        with self.store.connect() as db:
            self.store.adventure_record_monster(db, self.character["id"], monster, "fixture", uuid.uuid4().hex, mint=True)
        return monster

    def buy_ball(self):
        item = next(row for row in self.catalog()["items"] if row["id"] == "POKEBALL")
        self.character = self.change(self.character, "buy", item="POKEBALL", expected_unit_price=item["buy_price"])["character"]

    def test_public_rules_identity_and_strict_intents(self):
        status, public = self.store.request("GET", "/v1/controlled/adventure-catalog", token=self.alice["token"])
        self.assertEqual(status, 200)
        self.assertEqual(len(public["catalog"]["stages"]), 14)
        self.assertFalse(public["catalog"]["policy"]["abilities"])
        monster = self.view()["monsters"][0]
        self.assertEqual(monster["species"], "BULBASAUR")
        self.intent("starter", species="CHARMANDER", expected=409)
        self.intent("start", kind="trainer", entry="chapter-13", expected=403)
        self.intent("start", kind="trainer", entry="chapter-0", winner=True, expected=400)
        self.intent("train", monster_id=monster["id"], stat="ATTACK", amount=True, expected=400)
        bob = self.register("bob")
        self.intent("heal", person=bob, expected=404)

    def test_server_victory_issues_once_and_advances_campaign(self):
        result = self.win_intro()
        self.assertEqual(result["adventure"]["progress"]["chapter"], 1)
        self.assertEqual(self.character["wallet"]["balance"], 1200)
        self.assertGreater(result["adventure"]["monsters"][0]["exp"], 135)
        self.clock.advance(2)
        self.intent("start", kind="trainer", entry="chapter-0", expected=403)
        report = self.request("economy?currency=GOLD")
        self.assertTrue(report["reconciliation"]["ok"], report)
        self.assertIn("campaign_reward", {row["source"] for row in report["sources"]})
        self.assertNotIn("random_key", json.dumps(result))
        inspected = self.request("controlled-character?id=" + self.character["id"])
        self.assertEqual(inspected["adventure"]["progress"]["chapter"], 1)
        self.assertTrue(inspected["events"])

    def test_battle_restart_durable_retry_and_rulebook_pin(self):
        battle = self.start()
        body = self.intent_body("turn", battle_id=battle["id"], expected_round=0, command={"kind": "move", "slot": 0})
        result = self.game("controlled/characters/" + self.character["id"] + "/adventure", body)
        self.character = result["character"]
        with self.store.connect() as db:
            db.execute("DELETE FROM operations WHERE owner=?", (self.owner,))
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.assertEqual(self.game("controlled/characters/" + self.character["id"] + "/adventure", body), result)
        self.assertEqual(self.view()["battle"]["round"], 1)
        changed = copy.deepcopy(self.rules)
        changed["hash"] = "f" * 64
        with patch.object(self.store, "adventure_catalog", return_value=changed):
            self.move(self.view()["battle"])

    def test_concurrent_turns_commit_only_one_revision(self):
        battle = self.start()
        bodies = [self.intent_body("turn", battle_id=battle["id"], expected_round=0, command={"kind": "move", "slot": 0}) for _ in range(2)]
        def send(body):
            return self.store.request("POST", "/v1/controlled/characters/" + self.character["id"] + "/adventure", body, self.alice["token"])[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
            self.assertEqual(sorted(workers.map(send, bodies)), [200, 409])
        self.assertEqual(self.view()["battle"]["round"], 1)

    def test_capture_consumes_ball_and_mints_unique_asset_once(self):
        self.buy_ball()
        region = min(self.rules["regions"], key=lambda row: min(entry["min_level"] for entry in row["encounters"]))
        battle = self.start("wild", region["id"])
        body = self.intent_body("turn", battle_id=battle["id"], expected_round=0, command={"kind": "catch", "item": "POKEBALL"})
        path = "controlled/characters/" + self.character["id"] + "/adventure"
        with patch.object(engine, "catch_shakes", return_value=4):
            result = self.game(path, body)
        self.assertEqual(self.game(path, body), result)
        self.character = result["character"]
        self.assertEqual(result["settled_battle"]["outcome"], "captured")
        self.assertEqual(len(self.view()["monsters"]), 2)
        self.assertEqual(self.character["inventory"], [])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM controlled_captures").fetchone()[0], 1)

    def test_failed_capture_and_trainer_protection(self):
        self.buy_ball()
        battle = self.start()
        self.intent("turn", battle_id=battle["id"], expected_round=0, command={"kind": "catch", "item": "POKEBALL"}, expected=403)
        self.assertEqual(self.view()["battle"]["round"], 0)
        self.intent("turn", battle_id=battle["id"], expected_round=0, command={"kind": "flee"})
        region = min(self.rules["regions"], key=lambda row: min(entry["min_level"] for entry in row["encounters"]))
        battle = self.start("wild", region["id"])
        with patch.object(engine, "catch_shakes", return_value=0):
            result = self.intent("turn", battle_id=battle["id"], expected_round=0, command={"kind": "catch", "item": "POKEBALL"})
        self.assertNotEqual(result["settled_battle"].get("outcome"), "captured")
        self.assertEqual(len(result["adventure"]["monsters"]), 1)
        self.assertEqual(self.character["inventory"], [])

    def test_combat_lock_invalid_items_and_expiry(self):
        battle = self.start()
        monster = self.view()["monsters"][0]
        self.intent("train", monster_id=monster["id"], stat="ATTACK", amount=1, expected=409)
        self.change(self.character, "daily", expected=409)
        self.intent("turn", battle_id=battle["id"], expected_round=0, command={"kind": "item", "item": "POTION", "monster_id": monster["id"]}, expected=409)
        self.intent("turn", battle_id=battle["id"], expected_round=0, command={"kind": "move", "slot": -1}, expected=409)
        self.clock.advance(1801)
        self.assertIsNone(self.view()["battle"])
        self.intent("heal")
        self.assertEqual(self.character["wallet"]["balance"], 1000)

    def test_training_bounds_relearning_and_gold_atomicity(self):
        monster = self.view()["monsters"][0]
        self.intent("train", monster_id=monster["id"], stat="ATTACK", amount=5)
        self.assertEqual(self.character["wallet"]["balance"], 900)
        self.intent("train", monster_id=monster["id"], stat="ATTACK", amount=250, expected=409)
        before = self.view()
        self.intent("train", monster_id=monster["id"], stat="DEFENSE", amount=100, expected=409)
        self.assertEqual(self.view(), before)
        self.intent("learn", monster_id=monster["id"], move="HYDROPUMP", slot=0, expected=403)
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])

    def test_level_evolution_preserves_identity_and_trusted_learnset(self):
        creature = self.mint_fixture(level=16)
        self.intent("evolve", monster_id=creature["id"], species="CHARIZARD", expected=409)
        self.intent("evolve", monster_id=creature["id"], species="IVYSAUR")
        evolved = next(row for row in self.view()["monsters"] if row["id"] == creature["id"])
        self.assertEqual(evolved["species"], "IVYSAUR")
        self.assertEqual(evolved["iv"], creature["iv"])
        self.intent("learn", monster_id=creature["id"], move="TACKLE", slot=0)
        self.assertEqual(self.character["wallet"]["balance"], 700)

    def test_breeding_hatch_time_identity_and_parent_cooldown(self):
        parents = [self.mint_fixture(gender="male"), self.mint_fixture(gender="female")]
        result = self.intent("breed", parents=[parent["id"] for parent in parents])
        egg_id = result["monster_id"]
        self.assertEqual(self.character["wallet"]["balance"], 500)
        self.intent("hatch", monster_id=egg_id, expected=409)
        self.intent("breed", parents=[parent["id"] for parent in parents], expected=409)
        self.clock.advance(300)
        self.intent("hatch", monster_id=egg_id)
        child = next(row for row in self.view()["monsters"] if row["id"] == egg_id)
        self.assertFalse(child["egg"])
        self.assertEqual(child["species"], "BULBASAUR")
        self.assertEqual(child["parents"], [parent["id"] for parent in parents])
        self.assertNotIn(child["id"], [parent["id"] for parent in parents])

    def test_fusion_split_reactivates_original_ids_without_duplicate_parents(self):
        original = self.view()["monsters"][0]
        second = self.mint_fixture("CHARMANDER")
        result = self.intent("fuse", parents=[original["id"], second["id"]])
        fused = result["monster_id"]
        self.assertEqual(len(self.view()["monsters"]), 1)
        self.intent("train", monster_id=original["id"], stat="ATTACK", amount=1, expected=404)
        self.intent("split", monster_id=fused)
        self.assertEqual({row["id"] for row in self.view()["monsters"]}, {original["id"], second["id"]})
        self.intent("split", monster_id=fused, expected=404)
        self.assertEqual(self.character["wallet"]["balance"], 0)
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])

    def test_journal_failure_rolls_back_entire_turn(self):
        battle = self.start()
        before = self.view()
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER reject_creature_event BEFORE INSERT ON controlled_creature_events WHEN NEW.kind='battle' BEGIN SELECT RAISE(ABORT,'journal failed'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.move(battle)
        self.assertEqual(self.view(), before)

    def test_all_published_chapters_settle_once_with_endgame_fixture(self):
        # This covers every installed trainer/fusion and progression transition;
        # it is not a balance test of a naturally levelled five-level starter.
        party = [self.mint_fixture(species, 100) for species in ("CHARIZARD", "MEWTWO", "MEW", "BLASTOISE", "DRAGONITE", "GENGAR")]
        self.intent("party", party=[monster["id"] for monster in party])
        with patch.object(engine.BattleRandom, "randrange", return_value=0):
            for stage in self.rules["stages"]:
                self.intent("heal")
                battle = self.start("trainer", stage["id"])
                for _ in range(100):
                    active = battle["party"][battle["active"]]
                    if active["hp"] == 0:
                        replacement = next(row for row in battle["party"] if row["hp"] > 0)
                        result = self.intent("turn", battle_id=battle["id"], expected_round=battle["round"], command={"kind": "switch", "monster_id": replacement["id"]})
                    else:
                        enemy = battle["enemies"][battle["enemy_active"]]
                        available = [(index, self.rules["moves"][move["id"]]) for index, move in enumerate(active["moves"]) if move["pp"] > 0]
                        slot = max(available, key=lambda row: row[1]["base_damage"] * engine.type_multiplier(self.rules, row[1]["type"], enemy))[0] if available else -1
                        result = self.intent("turn", battle_id=battle["id"], expected_round=battle["round"], command={"kind": "move", "slot": slot})
                    battle = result["settled_battle"]
                    if battle["status"] != "active":
                        break
                self.assertEqual(battle["outcome"], "win", (stage["name"], battle))
        self.assertEqual(self.view()["progress"]["chapter"], 14)
        self.assertEqual(self.character["wallet"]["balance"], 1000 + sum(stage["gold"] for stage in self.rules["stages"]))
        self.clock.advance(2)
        self.intent("start", kind="trainer", entry="chapter-13", expected=409)


class MechanicsTests(unittest.TestCase):
    def setUp(self):
        from pathlib import Path
        self.rules = json.loads((Path(__file__).parent / "catalog-controlled-adventure-v1.json").read_text(encoding="utf-8"))

    def test_base_stats_fusion_typing_and_growth_boundaries(self):
        monster = engine.make_monster(self.rules, "BULBASAUR", 5)
        monster["iv"] = {stat: 31 for stat in engine.STATS}
        self.assertEqual(engine.stats(self.rules, monster)["HP"], 21)
        info = engine.species_info(self.rules, "B4H1")
        self.assertEqual(info["base_stats"]["HP"], 2 * 45 // 3 + 39 // 3)
        self.assertEqual(info["type1"], "GRASS")
        engine.gain_exp(self.rules, monster, 9999999, 10)
        self.assertEqual(monster["level"], 10)
        self.assertEqual(monster["exp"], self.rules["growth"]["Parabolic"][9])

    def test_secret_random_stream_survives_serialization(self):
        battle = {"random_key": "a" * 64, "random_counter": 0}
        rng = engine.BattleRandom(battle)
        self.assertTrue(0 <= rng.randrange(100) < 100)
        restored = json.loads(json.dumps(battle))
        self.assertEqual(rng.randrange(65536), engine.BattleRandom(restored).randrange(65536))

    def test_capture_formula_guarantee_and_no_roll_after_failure(self):
        monster = engine.make_monster(self.rules, "CATERPIE", 2)
        monster.update(hp=1, status="SLEEP")
        with patch.object(engine.BattleRandom, "randrange", return_value=65535):
            self.assertEqual(engine.catch_shakes(self.rules, monster, engine.BattleRandom({})), 4)
        monster.update(hp=engine.stats(self.rules, monster)["HP"], status="NONE")
        rng = unittest.mock.Mock()
        rng.randrange.return_value = 65535
        self.assertEqual(engine.catch_shakes(self.rules, monster, rng), 0)
        self.assertEqual(rng.randrange.call_count, 1)


if __name__ == "__main__":
    unittest.main()
