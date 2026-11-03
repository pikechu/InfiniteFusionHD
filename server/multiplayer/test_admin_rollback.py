import base64
import copy
import hashlib
import json
import sqlite3
import unittest
import uuid
import zlib

from admin_data import create_administrator, summarize_save
import test_admin as fixtures
import test_admin_saves as saves_fixtures
from service import Store
from test_historical_v1_support import HistoricalV1Store
from unittest.mock import patch


class RollbackTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    game = fixtures.AdminTests.game
    tearDown = fixtures.AdminTests.tearDown
    open = saves_fixtures.AdminSaveTests.open
    upload = saves_fixtures.AdminSaveTests.upload

    def setUp(self):
        with patch.object(fixtures, "Store", HistoricalV1Store):
            fixtures.AdminTests.setUp(self)
        with self.store.connect() as db:
            create_administrator(db, "reviewer", self.password, "operator", self.secret, now=self.clock())
        self.reviewer = self.login("reviewer")
        self.open()
        self.upload(money=100)
        self.upload(revision=1, money=200)
        self.maintenance = self.request("commands", self.command("begin_maintenance", force=True))["detail"]["maintenance_id"]

    def proposal(self, **fields):
        return self.command("request_save_rollback", expected_version=1, maintenance_id=self.maintenance,
            slot="file-a", expected_revision=2, expected_sha256=fixtures.save_fixture(200)["sha256"],
            restore_revision=1, restore_sha256=fixtures.save_fixture(100)["sha256"], **fields)

    def approve(self, proposal, **fields):
        return {"id": uuid.uuid4().hex, "action": "approve_save_rollback", "reason": "Independent restore review",
                "proposal_id": proposal["id"], **fields}

    def current(self):
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM cloud_saves WHERE owner=? AND slot='file-a'", (self.owner,)).fetchone()
            return dict(row, document=json.loads(row["document"]))

    def test_dual_review_whole_restore_new_revision_and_durable_receipts(self):
        body = self.proposal()
        pending = self.request("commands", body)
        self.assertEqual(pending["status"], "pending_approval")
        self.assertEqual(self.current()["revision"], 2)
        approval = self.approve(body)
        self.request("commands", approval, expected=403)
        completed = self.request("commands", approval, person=self.reviewer)
        current = self.current()
        self.assertEqual(current["revision"], 3)
        self.assertEqual(current["document"], fixtures.save_fixture(100))
        self.assertEqual(completed["detail"]["scope"], "legacy_cloud_only")
        self.assertEqual(self.request("commands", approval, person=self.reviewer), completed)
        self.assertEqual(self.request("commands", body)["status"], "completed")
        self.request("commands", self.approve(body), person=self.reviewer, expected=409)
        history = self.request("save-history?owner=" + self.owner + "&slot=file-a")["versions"]
        self.assertEqual([row["revision"] for row in history], [3, 2, 1])
        self.assertTrue(all(row["pinned"] for row in history if row["revision"] in (1, 2)))
        self.store.refresh_admin_summaries()
        self.assertEqual(self.request("players/" + self.owner)["saves"][0]["summary"]["money"], 100)
        old_token = self.alice["token"]
        self.request("commands", self.command("end_maintenance", expected_version=2, maintenance_id=self.maintenance))
        status, self.alice = self.store.request("POST", "/v1/auth/login", {"username": "alice", "password": "PlayerPassword123", "protocol": 2})
        self.assertEqual(status, 200)
        self.assertEqual(self.store.request("GET", "/v1/identity", token=old_token)[0], 401)
        self.open()
        downloaded = self.game("cloud/download", {"session_id": self.session, "slot": "file-a"})
        self.assertEqual(downloaded["revision"], 3)
        self.assertEqual(downloaded["save"], fixtures.save_fixture(100))
        self.game("cloud/upload", {"session_id": self.session, "slot": "file-a", "revision": 2,
                  "upload_id": uuid.uuid4().hex, "save": fixtures.save_fixture(999)}, expected=409)

    def test_managed_wallets_inventory_creatures_and_ownership_stay_current(self):
        # Seed authoritative assets through their own server producers, while
        # the restore only replaces the legacy cloud row.
        with self.store.connect() as db:
            db.execute("DELETE FROM player_maintenance WHERE owner=?", (self.owner,))
        status, self.alice = self.store.request("POST", "/v1/auth/login", {"username": "alice", "password": "PlayerPassword123", "protocol": 2})
        self.assertEqual(status, 200)
        controlled = self.game("controlled/characters", {"request_id": uuid.uuid4().hex, "name": "Current managed role", "catalog_hash": self.store.controlled_catalog()["hash"]})["character"]
        self.game("controlled/characters/" + controlled["id"] + "/adventure", {"request_id": uuid.uuid4().hex,
            "action": "starter", "species": "BULBASAUR", "expected_revision": controlled["revision"],
            "expected_wallet_revision": controlled["wallet"]["revision"], "rules_hash": self.store.adventure_catalog()["hash"]})
        self.game("collections/starter", {"request_id": uuid.uuid4().hex, "catalog_version": 1}, expected=201)
        with self.store.connect() as db:
            self.store.shop_money(db, self.owner, "RP", 800, "admin:rollback-fixture")
            self.store.controlled_item_change(db, controlled["id"], "POTION", 2, "rollback-fixture")
        self.maintenance = self.request("commands", self.command("begin_maintenance", expected_version=1, force=True))["detail"]["maintenance_id"]
        with self.store.connect() as db:
            before = self.store.rollback_economic_fence(db, self.owner)
        body = self.proposal()
        body["expected_version"] = 2
        self.request("commands", body)
        result = self.request("commands", self.approve(body), person=self.reviewer)
        with self.store.connect() as db:
            self.assertEqual(self.store.rollback_economic_fence(db, self.owner), before)
        self.assertEqual(result["detail"]["preserved"]["creatures"], 1)
        self.assertEqual(result["detail"]["preserved"]["hosted"], 1)
        self.assertEqual(result["detail"]["preserved"]["inventory"], 1)
        self.assertEqual(self.request("economy?currency=GOLD")["player_total"], 1000)

    def test_maintenance_permissions_cancel_and_expiry(self):
        body = self.proposal()
        reader = self.login("reader")
        self.request("commands", body, person=reader, expected=403)
        self.request("commands", body)
        self.request("commands", self.command("end_maintenance", expected_version=1, maintenance_id=self.maintenance), expected=409)
        cancelled = {"id": uuid.uuid4().hex, "action": "cancel_save_rollback", "reason": "Changed recovery plan", "proposal_id": body["id"]}
        self.request("commands", cancelled, person=self.reviewer, expected=403)
        self.assertEqual(self.request("commands", cancelled)["status"], "cancelled")
        self.request("commands", self.approve(body), person=self.reviewer, expected=409)
        body = self.proposal()
        self.request("commands", body)
        self.clock.advance(86401)
        self.admin, self.reviewer = self.login(), self.login("reviewer")
        self.request("commands", self.approve(body), person=self.reviewer, expected=409)
        self.request("commands", self.command("end_maintenance", expected_version=1, maintenance_id=self.maintenance))

    def test_economic_and_cloud_changes_invalidate_pending_review(self):
        body = self.proposal()
        self.request("commands", body)
        with self.store.connect() as db:
            self.store.shop_money(db, self.owner, "MARKET", 10, "admin:changed-after-preview")
        self.request("commands", self.approve(body), person=self.reviewer, expected=409)
        self.assertEqual(self.current()["revision"], 2)
        with self.store.connect() as db:
            db.execute("UPDATE cloud_saves SET revision=3 WHERE owner=? AND slot='file-a'", (self.owner,))
        self.request("commands", self.approve(body), person=self.reviewer, expected=409)

    def test_revoked_initiator_and_audit_failure_cannot_restore(self):
        body = self.proposal()
        self.request("commands", body)
        with self.store.connect() as db:
            db.execute("UPDATE admin_users SET enabled=0 WHERE username='operator'")
        self.request("commands", self.approve(body), person=self.reviewer, expected=403)
        with self.store.connect() as db:
            db.execute("UPDATE admin_users SET enabled=1 WHERE username='operator'")
            db.execute("CREATE TRIGGER reject_restore_audit BEFORE INSERT ON admin_audit WHEN NEW.action='approve_save_rollback' BEGIN SELECT RAISE(ABORT,'audit failed'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.request("commands", self.approve(body), person=self.reviewer)
        self.assertEqual(self.current()["revision"], 2)
        self.assertEqual(self.request("players/" + self.owner)["controls"]["version"], 1)
        self.assertEqual(self.request("save-rollbacks?target=" + self.owner)["proposals"][0]["status"], "pending")

    def test_snapshot_hashes_whitelist_and_unmaintained_targets_are_rejected(self):
        for overrides in ({"expected_sha256": "f" * 64}, {"restore_sha256": "e" * 64}, {"maintenance_id": "wrong"},
                          {"restore_revision": 2}, {"expected_revision": 1}):
            body = self.proposal()
            body.update(overrides)
            self.request("commands", body, expected=400 if overrides.get("restore_revision") == 2 or overrides.get("expected_revision") == 1 else 409)
        document = fixtures.save_fixture(100)
        graph = json.loads(zlib.decompress(base64.b64decode(document["payload"])))
        graph["nodes"].append({"type": "object", "class": "UntrustedExecutable", "ivars": {}})
        compressed = zlib.compress(json.dumps(graph).encode())
        bad = dict(document, payload=base64.b64encode(compressed).decode(), sha256=hashlib.sha256(compressed).hexdigest())
        with self.store.connect() as db:
            db.execute("UPDATE cloud_history SET document=? WHERE owner=? AND slot='file-a' AND revision=1", (json.dumps(bad), self.owner))
        body = self.proposal()
        body["restore_sha256"] = bad["sha256"]
        self.request("commands", body, expected=400)
        self.assertEqual(self.current()["revision"], 2)

    def test_restart_retains_pending_and_missing_journal_fails_closed(self):
        body = self.proposal()
        self.request("commands", body)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.request("commands", self.approve(body), person=self.reviewer)
        self.assertEqual(summarize_save(self.current()["document"])["money"], 100)
        with self.store.connect() as db:
            db.execute("DROP TABLE save_rollback_proposals")
        self.store.close()
        with self.assertRaises(RuntimeError):
            Store(self.database, clock=self.clock)


if __name__ == "__main__":
    unittest.main()
