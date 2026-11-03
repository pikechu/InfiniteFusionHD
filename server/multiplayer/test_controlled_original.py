import copy
import json
import sqlite3
import subprocess
import shutil
from pathlib import Path
import unittest
import uuid
import threading
from unittest.mock import patch

import test_admin as fixtures
import test_controlled as controlled_fixtures
from service import Store
from native_rules import NativeRules
from admin_data import create_administrator
import controlled_engine as v1_engine

RUBY = Path(__file__).resolve().parents[2] / "temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe"


@unittest.skipUnless(RUBY.is_file(), "Standalone Ruby required for original-game integration")
class OriginalCharacterTests(unittest.TestCase):
    _journey = None
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    game = fixtures.AdminTests.game
    catalog = controlled_fixtures.ControlledTests.catalog
    create = controlled_fixtures.ControlledTests.create
    state = controlled_fixtures.ControlledTests.state
    tearDown = fixtures.AdminTests.tearDown

    def setUp(self):
        fixtures.AdminTests.setUp(self)
        self.store._original_engine = NativeRules(ruby=RUBY)

    def original_catalog(self):
        status, result = self.store.request("GET", "/v1/controlled/original-catalog", token=self.alice["token"])
        self.assertEqual(status, 200, result)
        return result

    def original(self, character_id, person=None, expected=200):
        status, result = self.store.request("GET", f"/v1/controlled/characters/{character_id}/original", token=(person or self.alice)["token"])
        self.assertEqual(status, expected, result)
        return result

    def act(self, snapshot, intent, expected=200, **overrides):
        self.clock.advance(1)
        character = snapshot["character"]
        body = dict(request_id=uuid.uuid4().hex, expected_revision=character["revision"],
                    expected_wallet_revision=character["wallet"]["revision"],
                    rules_hash=snapshot["original"].get("rules_hash") or self.original_catalog()["rules_hash"], intent=intent)
        body.update(overrides)
        result = self.game(f"controlled/characters/{character['id']}/original", body, expected=expected)
        return result, body

    def activate(self):
        character = self.create()["character"]
        return self.act(self.original(character["id"]), {"kind": "activate"})

    def install_natural_fixture(self, name):
        if type(self)._journey is None:
            root = Path(__file__).resolve().parents[2]
            base = root / "temp/native-settlement-tests"
            base.mkdir(parents=True, exist_ok=True)
            directory = base / uuid.uuid4().hex
            directory.mkdir()
            try:
                output = directory / "natural.json"
                completed = subprocess.run([str(RUBY), "--disable-gems", "tests/multiplayer/original_world_journey_test.rb", str(output)],
                    cwd=root, capture_output=True, text=True, encoding="utf-8", timeout=180,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                type(self)._journey = json.loads(output.read_text(encoding="utf-8"))
            finally:
                assert directory.resolve().parent == base.resolve()
                shutil.rmtree(directory)
        fixture = type(self)._journey
        state, _ = self.activate()
        self.assertEqual(fixture["rules_hash"], state["original"]["rules_hash"])
        character_id = state["character"]["id"]
        with self.store.connect() as db:
            character = self.store.controlled_character(db, character_id)
            self.store.original_project(db, character, {"request_id": "trusted_test_fixture"}, fixture[name])
            db.execute("UPDATE original_states SET state=?,view=? WHERE character_id=?",
                       (fixture[name]["state"], json.dumps(fixture[name]["view"]), character_id))
            db.execute("UPDATE controlled_characters SET revision=revision+1 WHERE id=?", (character_id,))
        return self.original(character_id)

    def finish_opening(self, state):
        state, _ = self.act(state, {"kind": "wait"})
        for _ in range(30):
            prompt = state["original"]["prompt"]
            if prompt is None:
                return state
            if prompt["kind"] == "choice":
                choices = prompt["choices"]
                value = choices.index("Confirm") if "Confirm" in choices else choices.index("Normal") if "Normal" in choices else 0
            elif prompt["kind"] == "confirm":
                value = True
            elif prompt["kind"] == "name":
                value = "Original"
            else:
                self.fail("Unexpected opening prompt: " + str(prompt))
            state, _ = self.act(state, {"kind": "choose", "prompt_index": state["original"]["prompt_index"], "value": value})
        self.fail("Original opening did not finish")

    def test_opening_checkpoint_retries_and_restart(self):
        state, activation = self.activate()
        identifier = state["character"]["id"]
        state = self.finish_opening(state)
        self.assertEqual(state["original"]["view"]["world"]["map_id"], 157)
        self.assertEqual(state["character"]["wallet"]["balance"], 1000)
        self.assertEqual(state["original"]["view"]["party"], [])
        self.assertNotIn("state", state["original"])
        self.assertNotIn("seed", json.dumps(state))
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM original_snapshots WHERE character_id=?", (identifier,)).fetchone()[0], 2)
            db.execute("DELETE FROM operations WHERE owner=?", (self.owner,))
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.store._original_engine = NativeRules(ruby=RUBY)
        replayed = self.game(f"controlled/characters/{identifier}/original", activation)
        self.assertEqual(replayed["original"], state["original"])
        self.assertEqual(replayed["character"]["revision"], state["character"]["revision"])
        self.assertEqual(replayed["receipt"]["revision"], 2)
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])

    def test_untrusted_fields_and_other_accounts_cannot_mutate(self):
        state, _ = self.activate()
        identifier = state["character"]["id"]
        bob = self.register("original_bob")
        self.original(identifier, person=bob, expected=404)
        self.act(state, {"kind": "move", "direction": 2, "reward": 99999}, expected=400)
        self.act(state, {"kind": "wait"}, expected=400, state="z2_untrusted")
        self.game(f"controlled/characters/{identifier}/daily", {"request_id": uuid.uuid4().hex,
                  "expected_revision": state["character"]["revision"]}, expected=409)
        self.assertEqual(self.original(identifier)["character"]["wallet"]["balance"], 1000)
        self.create(name="\\ch[96,0,A]", expected=400)

    def test_native_engine_lookup_cannot_deadlock_a_database_writer_with_the_game_lock(self):
        finished = threading.Event()
        found = []
        def lookup():
            found.append(self.store.original_engine())
            finished.set()
        worker = threading.Thread(target=lookup)
        try:
            with self.store.lock:
                worker.start()
                self.assertTrue(finished.wait(1), "Native engine lookup took the game commit lock")
        finally:
            worker.join(timeout=2)
        self.assertIs(found[0], self.store._original_engine)

    def test_wallet_changed_while_native_computes_rejects_commit(self):
        character = self.create()["character"]
        state = self.original(character["id"])
        catalog = self.original_catalog()
        engine_call = self.store._original_engine.call

        def change_during_compute(*arguments, **keywords):
            result = engine_call(*arguments, **keywords)
            with self.store.connect() as db:
                self.store.shop_money(db, character["id"], "GOLD", 50, "gm:original-version-race")
            return result

        with patch.object(self.store._original_engine, "call", side_effect=change_during_compute):
            self.act(state, {"kind": "activate"}, expected=409, rules_hash=catalog["rules_hash"])
        self.assertFalse(self.original(character["id"])["original"]["active"])
        self.assertEqual(self.state(character["id"])["wallet"]["balance"], 1050)

    def test_invalid_native_choice_preserves_pending_interaction(self):
        state, _ = self.activate()
        state, _ = self.act(state, {"kind": "wait"})
        character_id = state["character"]["id"]
        self.assertIsNotNone(state["original"]["prompt"])
        self.act(state, {"kind": "choose", "prompt_index": state["original"]["prompt_index"], "value": 999999}, expected=400)
        after = self.original(character_id)
        self.assertEqual(after["character"], state["character"])
        self.assertEqual(after["original"], state["original"])
        self.act(state, {"kind": "choose", "prompt_index": state["original"]["prompt_index"], "value": 0})

    def test_ban_while_native_computes_rejects_commit(self):
        character = self.create()["character"]
        state = self.original(character["id"])
        engine_call = self.store._original_engine.call
        catalog = self.original_catalog()

        def ban_during_compute(*arguments, **keywords):
            result = engine_call(*arguments, **keywords)
            self.request("commands", self.command("ban"))
            return result

        with patch.object(self.store._original_engine, "call", side_effect=ban_during_compute):
            self.act(state, {"kind": "activate"}, expected=401, rules_hash=catalog["rules_hash"])
        with self.store.connect() as db:
            self.assertIsNone(self.store.original_row(db, character["id"]))
            self.assertEqual(self.store.shop_wallet(db, character["id"], "GOLD")["balance"], 1000)

    def test_native_online_and_admin_queries_use_authoritative_projection(self):
        self.assertEqual(self.request("overview")["online"], 0)
        state, _ = self.activate()
        identifier = state["character"]["id"]
        self.assertEqual(self.request("overview")["online"], 1)
        players = self.request("players?state=online")["players"]
        self.assertEqual([player["id"] for player in players], [self.owner])
        details = self.request("controlled-character?id=" + identifier)
        self.assertEqual(details["original"], state["original"])
        self.assertIsNone(details["adventure"])
        self.assertNotIn("z2_", json.dumps(details))
        presence = self.request("players/" + self.owner)["presence"]
        self.assertEqual(presence["position"]["source"], "controlled_original")
        self.clock.advance(21)
        self.assertEqual(self.request("overview")["online"], 0)
        self.assertEqual(self.request("players?state=online")["players"], [])

    def test_high_existing_wallet_is_preserved_by_native_purse_cap(self):
        character = self.create()["character"]
        with self.store.connect() as db:
            self.store.shop_money(db, character["id"], "GOLD", 1500000, "gm:original-existing-gold")
        state, _ = self.act(self.original(character["id"]), {"kind": "activate"})
        self.assertEqual(state["original"]["view"]["money"], 999999)
        self.assertEqual(state["character"]["wallet"]["balance"], 1501000)
        state = self.finish_opening(state)
        self.assertEqual(state["character"]["wallet"]["balance"], 1501000)
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])

    def inventory_proposal(self, state, amount=2):
        return self.command("adjust_inventory", character_id=state["character"]["id"],
                            expected_revision=state["character"]["revision"], item="LEFTOVERS", amount=amount)

    def inventory_reviewer(self):
        with self.store.connect() as db:
            create_administrator(db, "native_reviewer", self.password, "operator", self.secret, now=self.clock())
        return self.login("native_reviewer")

    def test_native_inventory_approval_updates_blob_projection_journal_and_snapshot(self):
        state, _ = self.activate()
        reviewer = self.inventory_reviewer()
        details = self.request("controlled-character?id=" + state["character"]["id"])
        self.assertEqual(len(details["item_catalog"]), 725)
        pending = self.request("commands", self.inventory_proposal(state))
        approval = {"id": uuid.uuid4().hex, "action": "approve_inventory", "reason": "Native inventory fixture", "proposal_id": pending["command_id"]}
        self.request("commands", approval, expected=403)
        result = self.request("commands", approval, person=reviewer)
        self.assertEqual(self.request("commands", approval, person=reviewer), result)
        current = self.original(state["character"]["id"])
        self.assertIn({"item": "LEFTOVERS", "quantity": 2}, current["character"]["inventory"])
        self.assertIn({"item": "LEFTOVERS", "quantity": 2}, current["original"]["view"]["inventory"])
        self.assertEqual(current["character"]["wallet"]["balance"], 1000)
        with self.store.connect() as db:
            self.assertTrue(self.store.controlled_inventory_audit(db)["ok"])
            self.assertEqual(db.execute("SELECT count(*) FROM original_snapshots WHERE character_id=?", (state["character"]["id"],)).fetchone()[0], 2)
            self.assertEqual(db.execute("SELECT count(*) FROM original_events WHERE kind='admin_inventory'").fetchone()[0], 1)
        self.act(current, {"kind": "wait"})
        self.assertIn({"item": "LEFTOVERS", "quantity": 2}, self.original(state["character"]["id"])["original"]["view"]["inventory"])

    def test_native_inventory_audit_failure_rolls_back_all_asset_state(self):
        state, _ = self.activate()
        reviewer = self.inventory_reviewer()
        pending = self.request("commands", self.inventory_proposal(state))
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER native_audit_failure BEFORE INSERT ON admin_audit WHEN NEW.action='inventory_adjusted' BEGIN SELECT RAISE(ABORT,'audit failed'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.request("commands", {"id": uuid.uuid4().hex, "action": "approve_inventory", "reason": "Native failure fixture", "proposal_id": pending["command_id"]}, person=reviewer)
        after = self.original(state["character"]["id"])
        self.assertEqual(after, self.original(state["character"]["id"]))
        self.assertEqual(after["original"], state["original"])
        self.assertEqual(after["character"], state["character"])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM original_snapshots").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT count(*) FROM original_events WHERE kind='admin_inventory'").fetchone()[0], 0)

    def test_native_inventory_adjustment_cannot_interrupt_native_dialogue(self):
        state, _ = self.activate()
        state, _ = self.act(state, {"kind": "wait"})
        self.request("commands", self.inventory_proposal(state), expected=409)

    def test_native_mainline_battle_settles_wallet_experience_and_resumes_after_restart(self):
        seed = patch("controlled_original.secrets.randbits", return_value=123456)
        seed.start()
        self.addCleanup(seed.stop)
        state = self.install_natural_fixture("before_rival")
        initial_exp = state["original"]["view"]["party"][0]["exp"]
        events = []
        for direction in type(self)._journey["rival_approach"]:
            state, _ = self.act(state, {"kind": "move", "direction": direction})
            events += state["events"]
            if state["original"]["prompt"]:
                break
        self.assertIsNotNone(state["original"]["view"].get("battle"))
        self.assertEqual(state["original"]["prompt"]["kind"], "command")
        character_id = state["character"]["id"]
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.store._original_engine = NativeRules(ruby=RUBY)
        self.assertEqual(self.original(character_id)["original"], state["original"])
        for _ in range(120):
            prompt = state["original"]["prompt"]
            if prompt is None:
                break
            value = False if prompt["kind"] == "confirm" else 1 if prompt["kind"] == "target" else 0
            state, _ = self.act(state, {"kind": "choose", "prompt_index": state["original"]["prompt_index"], "value": value})
            events += state["events"]
        self.assertIsNone(state["original"]["prompt"])
        decisions = [event["decision"] for event in events if event["kind"] == "battle_end"]
        self.assertEqual(decisions, [1])
        self.assertGreater(state["original"]["view"]["party"][0]["exp"], initial_exp)
        self.assertGreater(state["character"]["wallet"]["balance"], 1000)
        self.assertEqual(state["character"]["wallet"]["balance"], state["original"]["view"]["money"])
        report = self.request("economy?currency=GOLD")
        self.assertTrue(report["reconciliation"]["ok"])
        self.assertIn("original_battle_income", {source["source"] for source in report["sources"]})

    def test_native_item_use_consumes_canonical_stock_and_preserves_captured_ids(self):
        state = self.install_natural_fixture("after_capture")
        reviewer = self.inventory_reviewer()
        proposal = self.inventory_proposal(state, 1)
        proposal["item"] = "POTION"
        pending = self.request("commands", proposal)
        self.request("commands", {"id": uuid.uuid4().hex, "action": "approve_inventory", "reason": "Native potion fixture", "proposal_id": pending["command_id"]}, person=reviewer)
        state = self.original(state["character"]["id"])
        identifiers = {monster["id"] for monster in state["original"]["view"]["monsters"]}
        target = state["original"]["view"]["party"][0]
        self.assertLess(target["hp"], target["max_hp"])
        used, body = self.act(state, {"kind": "use_item", "monster_id": target["id"], "item": "POTION"})
        self.assertEqual(used["original"]["view"]["party"][0]["hp"], target["max_hp"])
        self.assertEqual({monster["id"] for monster in used["original"]["view"]["monsters"]}, identifiers)
        self.assertFalse(any(item["item"] == "POTION" and item["quantity"] > 0 for item in used["character"]["inventory"]))
        retried = self.game("controlled/characters/" + state["character"]["id"] + "/original", body)
        self.assertEqual(retried["character"], used["character"])
        with self.store.connect() as db:
            self.assertTrue(self.store.controlled_inventory_audit(db)["ok"])

    def test_movement_uses_original_speed_instead_of_request_frequency(self):
        state = self.install_natural_fixture("before_rival")
        state, _ = self.act(state, {"kind": "move", "direction": 6})
        self.assertGreater(state["original"]["view"]["next_move_at"], self.clock())
        body = {"request_id": uuid.uuid4().hex, "expected_revision": state["character"]["revision"],
                "expected_wallet_revision": state["character"]["wallet"]["revision"], "rules_hash": state["original"]["rules_hash"],
                "intent": {"kind": "move", "direction": 2}}
        self.clock.advance(0.06)
        self.game("controlled/characters/" + state["character"]["id"] + "/original", body, expected=429)
        after = self.original(state["character"]["id"])
        self.assertEqual(after["original"], state["original"])

    def test_presence_does_not_execute_or_change_pending_gameplay(self):
        state, _ = self.activate()
        state, _ = self.act(state, {"kind": "wait"})
        identifier = state["character"]["id"]
        self.clock.advance(10)
        with patch.object(self.store, "original_engine", side_effect=AssertionError("Presence must not execute the game")):
            result = self.game("controlled/characters/" + identifier + "/original/presence", {"request_id": uuid.uuid4().hex})
        self.assertEqual(result["revision"], state["character"]["revision"])
        current = self.original(identifier)
        self.assertEqual(current["original"], state["original"])
        self.assertEqual(current["character"], state["character"])
        self.assertEqual(self.request("overview")["online"], 1)

    def make_v1_character(self):
        character = self.create()["character"]
        old_catalog = self.store.adventure_catalog()
        # Reconstruct a pre-cutover registry, then restore production policy.
        with patch.object(self.store, "controlled_v1_action_allowed", return_value=True):
            response = self.game("controlled/characters/" + character["id"] + "/adventure", {
                "request_id": uuid.uuid4().hex, "action": "starter", "species": "BULBASAUR", "rules_hash": old_catalog["hash"],
                "expected_revision": character["revision"], "expected_wallet_revision": character["wallet"]["revision"]})
        return self.original(character["id"]), response

    def test_server_v1_migration_preserves_ids_genetics_wallet_and_archive(self):
        state, old = self.make_v1_character()
        identifier = state["character"]["id"]
        migration = state["original"]["migration"]
        self.assertTrue(migration["required"])
        before = old["adventure"]["monsters"] if "adventure" in old else old["monsters"]
        current, body = self.act(state, {"kind": "migrate", "policy": migration["policy"]})
        self.assertEqual(current["character"]["wallet"], state["character"]["wallet"])
        self.assertEqual({monster["id"] for monster in current["original"]["view"]["monsters"]}, {monster["id"] for monster in before})
        imported = current["original"]["view"]["monsters"][0]
        self.assertEqual((imported["iv"], imported["ev"], imported["level"]), (before[0]["iv"], before[0]["ev"], before[0]["level"]))
        self.assertEqual(imported["nature"], "HARDY")
        self.assertFalse(imported["shiny"])
        self.assertEqual(self.game("controlled/characters/" + identifier + "/original", body)["character"], current["character"])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM original_migrations WHERE character_id=?", (identifier,)).fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT status FROM controlled_monsters WHERE character_id=?", (identifier,)).fetchone()[0], "migrated")
            self.assertTrue(self.store.controlled_inventory_audit(db)["ok"])
        self.game("controlled/characters/" + identifier + "/daily", {"request_id": uuid.uuid4().hex, "expected_revision": current["character"]["revision"]}, expected=409)
        current = self.finish_opening(current)
        self.assertEqual(current["original"]["view"]["monsters"][0]["owner"]["name"], current["original"]["view"]["trainer"]["name"])

    def test_migration_failure_does_not_retire_existing_v1_assets(self):
        state, _ = self.make_v1_character()
        identifier = state["character"]["id"]
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER reject_migration_archive BEFORE INSERT ON original_migrations BEGIN SELECT RAISE(ABORT,'archive failed'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.act(state, {"kind": "migrate", "policy": "server_v1_preserve_assets"})
        after = self.original(identifier)
        self.assertEqual(after["character"], state["character"])
        self.assertFalse(after["original"]["active"])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT status FROM controlled_monsters WHERE character_id=?", (identifier,)).fetchone()[0], "active")
            self.assertEqual(db.execute("SELECT count(*) FROM original_creatures").fetchone()[0], 0)

    def test_migration_preserves_fused_experience_egg_progress_and_inventory(self):
        state, old = self.make_v1_character()
        identifier = state["character"]["id"]
        catalog = self.store.adventure_catalog()
        with self.store.connect() as db:
            body = json.loads(db.execute("SELECT document FROM controlled_monsters WHERE character_id=? AND status='active'", (identifier,)).fetchone()[0])
            head = v1_engine.make_monster(catalog, "PIDGEY", 12)
            self.store.adventure_record_monster(db, identifier, head, "fixture", uuid.uuid4().hex, mint=True, status="consumed")
            self.store.adventure_record_monster(db, identifier, body, "fixture_consume", uuid.uuid4().hex, status="consumed")
            fused = v1_engine.make_monster(catalog, "B1H16", 20)
            fused.update(components=[body, head], fusion_initial_exp=fused["exp"])
            self.store.adventure_record_monster(db, identifier, fused, "fixture", uuid.uuid4().hex, mint=True)
            egg = v1_engine.make_monster(catalog, "BULBASAUR", 1)
            egg.update(egg=True, hatch_at=self.clock() + catalog["hatch_seconds"] / 2, parents=[body["id"], head["id"]])
            self.store.adventure_record_monster(db, identifier, egg, "fixture", uuid.uuid4().hex, mint=True)
            progress = self.store.adventure_progress(db, identifier)
            progress["party"] = [fused["id"]]
            self.store.adventure_save_progress(db, identifier, progress)
            self.store.controlled_item_change(db, identifier, "POTION", 2, "fixture:server_v1_stock")
        state = self.original(identifier)
        migrated, _ = self.act(state, {"kind": "migrate", "policy": "server_v1_preserve_assets"})
        creatures = {monster["id"]: monster for monster in migrated["original"]["view"]["monsters"]}
        self.assertEqual(set(creatures), {fused["id"], egg["id"]})
        self.assertEqual(creatures[fused["id"]]["level"], 20)
        self.assertGreater(creatures[egg["id"]]["egg_steps"], 0)
        self.assertIn({"item": "POTION", "quantity": 2}, migrated["character"]["inventory"])
        reviewer = self.inventory_reviewer()
        proposal = self.inventory_proposal(migrated, 1)
        proposal["item"] = "DNASPLICERS"
        pending = self.request("commands", proposal)
        self.request("commands", {"id": uuid.uuid4().hex, "action": "approve_inventory", "reason": "Migration unfuse fixture", "proposal_id": pending["command_id"]}, person=reviewer)
        migrated = self.original(identifier)
        result, _ = self.act(migrated, {"kind": "use_item", "monster_id": fused["id"], "item": "DNASPLICERS"})
        for _ in range(20):
            prompt = result["original"]["prompt"]
            if prompt is None:
                break
            self.assertIn(prompt["kind"], ("confirm", "choice"))
            result, _ = self.act(result, {"kind": "choose", "prompt_index": result["original"]["prompt_index"], "value": True if prompt["kind"] == "confirm" else 0})
        self.assertIsNone(result["original"]["prompt"])
        self.assertEqual({monster["species"] for monster in result["original"]["view"]["party"]}, {"BULBASAUR", "PIDGEY"})
        self.assertEqual(sorted(monster["level"] for monster in result["original"]["view"]["party"]), [5, 12])
        self.assertEqual(result["character"]["wallet"]["balance"], 1000)

    def test_migration_cannot_discard_an_active_v1_battle(self):
        state, _ = self.make_v1_character()
        character = state["character"]
        with patch.object(self.store, "controlled_v1_action_allowed", return_value=True):
            self.game("controlled/characters/" + character["id"] + "/adventure", {
                "request_id": uuid.uuid4().hex, "action": "start", "kind": "trainer", "entry": "chapter-0",
                "rules_hash": self.store.adventure_catalog()["hash"], "expected_revision": character["revision"],
                "expected_wallet_revision": character["wallet"]["revision"]})
        state = self.original(character["id"])
        self.act(state, {"kind": "migrate", "policy": "server_v1_preserve_assets"}, expected=409)
        self.assertFalse(self.original(character["id"])["original"]["active"])

    def test_new_v1_rewards_are_closed_but_historical_receipts_survive_restart(self):
        character = self.create()["character"]
        body = {"request_id": uuid.uuid4().hex, "expected_revision": character["revision"]}
        with patch.object(self.store, "controlled_v1_action_allowed", return_value=True):
            old = self.game("controlled/characters/" + character["id"] + "/daily", body)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.store._original_engine = NativeRules(ruby=RUBY)
        self.assertEqual(self.game("controlled/characters/" + character["id"] + "/daily", body), old)
        self.game("controlled/characters/" + character["id"] + "/daily", {"request_id": uuid.uuid4().hex, "expected_revision": old["character"]["revision"]}, expected=409)
        self.game("controlled/characters/" + character["id"] + "/adventure", {
            "request_id": uuid.uuid4().hex, "action": "starter", "species": "BULBASAUR", "rules_hash": self.store.adventure_catalog()["hash"],
            "expected_revision": old["character"]["revision"], "expected_wallet_revision": old["character"]["wallet"]["revision"]}, expected=409)
        self.assertEqual(self.original(character["id"])["character"]["wallet"]["balance"], 1100)


if __name__ == "__main__":
    unittest.main()
