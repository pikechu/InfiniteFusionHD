import sqlite3
import unittest
import uuid
from unittest.mock import patch
from test_historical_v1_support import HistoricalV1Store

import test_admin as fixtures
import test_controlled as controlled
from admin_data import create_administrator


class ControlledAdminTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    game = fixtures.AdminTests.game
    tearDown = fixtures.AdminTests.tearDown
    catalog = controlled.ControlledTests.catalog
    create = controlled.ControlledTests.create
    state = controlled.ControlledTests.state
    change = controlled.ControlledTests.change

    def setUp(self):
        with patch.object(fixtures, "Store", HistoricalV1Store):
            fixtures.AdminTests.setUp(self)
        with self.store.connect() as db:
            create_administrator(db, "reviewer", self.password, "operator", self.secret, now=self.clock())
        self.reviewer = self.login("reviewer")
        self.character = self.create()["character"]

    def propose(self, amount=2, **overrides):
        return self.command("adjust_inventory", character_id=self.character["id"], expected_revision=self.character["revision"], item="POTION", amount=amount, **overrides)

    def approve(self, pending):
        return {"id": uuid.uuid4().hex, "action": "approve_inventory", "reason": "Inventory review fixture", "proposal_id": pending["command_id"]}

    def test_inventory_grant_and_recall_need_independent_review(self):
        body = self.propose()
        pending = self.request("commands", body)
        self.assertEqual(self.state(self.character["id"])["inventory"], [])
        self.request("commands", self.approve(pending), expected=403)
        approval = self.approve(pending)
        result = self.request("commands", approval, person=self.reviewer)
        self.assertEqual(self.request("commands", approval, person=self.reviewer), result)
        self.assertEqual(self.request("commands", body)["status"], "completed")
        self.character = self.state(self.character["id"])
        self.assertEqual(self.character["inventory"][0]["quantity"], 2)
        self.assertEqual(self.character["wallet"]["balance"], 1000)
        recall = self.request("commands", self.propose(-1))
        self.request("commands", self.approve(recall), person=self.reviewer)
        self.assertEqual(self.state(self.character["id"])["inventory"][0]["quantity"], 1)

    def test_inventory_revision_conflict_and_audit_failure_are_atomic(self):
        pending = self.request("commands", self.propose())
        self.change(self.character, "daily")
        self.request("commands", self.approve(pending), person=self.reviewer, expected=409)
        self.character = self.state(self.character["id"])
        pending = self.request("commands", self.propose())
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER reject_inventory_audit BEFORE INSERT ON admin_audit WHEN NEW.action='inventory_adjusted' BEGIN SELECT RAISE(ABORT,'audit failed'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.request("commands", self.approve(pending), person=self.reviewer)
        self.assertEqual(self.state(self.character["id"])["inventory"], [])

    def test_gold_batch_resolves_character_wallets_and_rejects_owner_spoofing(self):
        second = self.create("第二受控角色")["character"]
        preview = self.request("batch-preview?currency=GOLD&characters=" + self.character["id"] + "," + second["id"])
        recipients = [{key: value for key, value in row.items() if key != "balance"} for row in preview["recipients"]]
        for row in recipients:
            row["amount"] = 10
        body = {"id": uuid.uuid4().hex, "action": "batch_wallet", "currency": "GOLD", "recipients": recipients, "reason": "Controlled gold batch"}
        pending = self.request("commands", body)
        self.request("commands", {"id": uuid.uuid4().hex, "action": "approve_batch", "proposal_id": pending["command_id"], "reason": "Reviewed controlled gold"}, person=self.reviewer)
        self.assertEqual(self.request("economy?currency=GOLD")["player_total"], 1020)
        self.assertEqual(self.state(second["id"])["wallet"]["balance"], 10)
        bob = self.register("bob")
        body["id"] = uuid.uuid4().hex
        body["recipients"][0]["owner"] = bob["identity"]["id"]
        self.request("commands", body, expected=404)

    def test_inventory_ledger_reconciliation_detects_direct_quantity_corruption(self):
        pending = self.request("commands", self.propose())
        self.request("commands", self.approve(pending), person=self.reviewer)
        with self.store.connect() as db:
            self.assertTrue(self.store.controlled_inventory_audit(db)["ok"])
            db.execute("UPDATE controlled_inventory SET quantity=99 WHERE character_id=?", (self.character["id"],))
        self.store.scan_admin_risks()
        alerts = self.request("alerts")["alerts"]
        self.assertIn("controlled_inventory_reconciliation", {row["rule"] for row in alerts})
