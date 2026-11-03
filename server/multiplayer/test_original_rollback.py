import json
import sqlite3
import unittest
import uuid
from unittest.mock import patch

import test_controlled_commerce as commerce_fixtures
import test_controlled_original as original_fixtures
from admin_data import create_administrator


@unittest.skipUnless(original_fixtures.RUBY.is_file(), "Standalone Ruby required")
class OriginalRollbackTests(unittest.TestCase):
    _journey = None
    for _name in ("setUp", "tearDown", "register", "login", "request", "command", "game", "catalog", "create", "state", "original_catalog", "original", "act", "activate", "install_natural_fixture", "finish_opening"):
        locals()[_name] = getattr(original_fixtures.OriginalCharacterTests, _name)
    market = commerce_fixtures.OriginalCommerceTests.market
    buyer = commerce_fixtures.OriginalCommerceTests.buyer

    def checkpoint(self, state):
        identifier = state["character"]["id"]
        with self.store.connect() as db:
            row = self.store.original_row(db, identifier)
            self.store.original_snapshot(db, self.store.controlled_character(db, identifier), row["rules_hash"], row["state"], json.loads(row["view"]))
        return state["character"]["revision"]

    def maintenance_and_proposal(self, state, source):
        with self.store.connect() as db:
            create_administrator(db, "reviewer", self.password, "operator", self.secret, now=self.clock())
        self.reviewer = self.login("reviewer")
        maintenance = self.request("commands", self.command("begin_maintenance", force=True))
        return self.command("request_original_rollback", expected_version=1, maintenance_id=maintenance["detail"]["maintenance_id"],
                            character_id=state["character"]["id"], expected_revision=state["character"]["revision"], restore_revision=source)

    def approve(self, proposal):
        return {"id": uuid.uuid4().hex, "action": "approve_original_rollback", "reason": "Independent native whole-role review", "proposal_id": proposal["id"]}

    def raw(self, identifier):
        with self.store.connect() as db:
            return self.store.original_row(db, identifier)

    def test_full_native_checkpoint_restore_compensates_wallet_and_keeps_backup(self):
        state = self.install_natural_fixture("after_capture")
        identifier = state["character"]["id"]
        with self.store.connect() as db:
            character = self.store.controlled_character(db, identifier)
            self.store.original_adjust_inventory(db, character, "POTION", 1, "fixture_native_potion")
        checkpoint = self.original(identifier)
        source = checkpoint["character"]["revision"]  # GM adjustment already captured a checkpoint.
        target = checkpoint["original"]["view"]["party"][0]
        changed, _ = self.act(checkpoint, {"kind": "use_item", "monster_id": target["id"], "item": "POTION"})
        with self.store.connect() as db:
            self.store.shop_money(db, identifier, "GOLD", 80, "managed:original_income:battle_income:trusted_fixture")
        changed = self.original(identifier)
        before = self.raw(identifier)
        proposal = self.maintenance_and_proposal(changed, source)
        pending = self.request("commands", proposal)
        self.assertEqual(pending["preview"]["money_after"], 1000)
        approval = self.approve(proposal)
        self.request("commands", approval, expected=403)
        done = self.request("commands", approval, person=self.reviewer)
        self.assertEqual(done["status"], "completed")
        restored = self.raw(identifier)
        view = json.loads(restored["view"])
        self.assertEqual(view["party"][0]["hp"], target["hp"])
        self.assertIn({"item": "POTION", "quantity": 1}, view["inventory"])
        self.assertEqual(view["world"], checkpoint["original"]["view"]["world"])
        self.assertEqual(self.request("commands", approval, person=self.reviewer), done)
        with self.store.connect() as db:
            self.assertEqual(self.store.shop_wallet(db, identifier, "GOLD")["balance"], 1000)
            backup = db.execute("SELECT * FROM original_rollback_runs").fetchone()
            self.assertEqual(backup["before_state"], before["state"])
            self.assertEqual(db.execute("SELECT count(*) FROM shop_ledger WHERE event LIKE 'admin:original_rollback:%'").fetchone()[0], 1)
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])
        self.assertNotIn("z2_", json.dumps(done))

    def test_sold_pokemon_is_not_cloned_and_external_proceeds_stay_in_wallet(self):
        seller = self.install_natural_fixture("after_capture")
        source = self.checkpoint(seller)
        monster = seller["original"]["view"]["party"][-1]
        listed, _ = self.market(seller, "list", monster_id=monster["id"], price=300)
        person, buyer = self.buyer()
        bought, _ = self.market(buyer, "buy", person=person, listing_id=listed["receipt"]["listing_id"], expected_price=300, expected_fee=0, expected_listing_version=1)
        pending_save, _ = self.act(self.original(seller["character"]["id"]), {"kind": "save"})
        self.assertIsNotNone(pending_save["original"]["prompt"])
        proposal = self.maintenance_and_proposal(pending_save, source)
        pending = self.request("commands", proposal)
        self.assertIn(monster["id"], pending["preview"]["protected_ids"])
        self.request("commands", self.approve(proposal), person=self.reviewer)
        restored = json.loads(self.raw(seller["character"]["id"])["view"])
        self.assertNotIn(monster["id"], [entry["id"] for entry in restored["monsters"]])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT character_id FROM original_creatures WHERE id=?", (monster["id"],)).fetchone()[0], buyer["character"]["id"])
            self.assertEqual(self.store.shop_wallet(db, seller["character"]["id"], "GOLD")["balance"], 1300)
        self.assertEqual(self.original(buyer["character"]["id"], person)["original"]["view"], bought["original"]["view"])

    def test_audit_failure_leaves_native_blob_wallet_proposal_and_backup_unchanged(self):
        state = self.install_natural_fixture("after_capture")
        source = self.checkpoint(state)
        state, _ = self.act(state, {"kind": "wait"})
        proposal = self.maintenance_and_proposal(state, source)
        self.request("commands", proposal)
        before = self.raw(state["character"]["id"])
        with patch.object(self.store, "audit", side_effect=sqlite3.IntegrityError("fixture audit failure")):
            with self.assertRaises(sqlite3.IntegrityError):
                self.request("commands", self.approve(proposal), person=self.reviewer)
        self.assertEqual(self.raw(state["character"]["id"]), before)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM original_rollback_runs").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT status FROM original_rollback_proposals").fetchone()[0], "pending")

    def test_maintenance_can_restore_a_pending_native_interaction_and_preserves_recovery_document(self):
        state = self.install_natural_fixture("after_capture")
        source = self.checkpoint(state)
        state, _ = self.act(state, {"kind": "save"})
        self.assertIsNotNone(state["original"]["prompt"])
        before = self.raw(state["character"]["id"])
        proposal = self.maintenance_and_proposal(state,source)
        pending = self.request("commands", proposal)
        self.assertEqual(pending["preview"]["interrupted_interaction"], "confirm")
        self.request("commands", self.approve(proposal), person=self.reviewer)
        self.assertIsNone(self.raw(state["character"]["id"])["pending"])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT before_pending FROM original_rollback_runs").fetchone()[0], before["pending"])
