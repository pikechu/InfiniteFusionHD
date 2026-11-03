import json
import sqlite3
import unittest
import uuid
from datetime import date, datetime, timedelta

import test_admin as fixtures
from admin_data import create_administrator, day_key, SHANGHAI


class EconomyTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    tearDown = fixtures.AdminTests.tearDown

    def setUp(self):
        fixtures.AdminTests.setUp(self)
        with self.store.connect() as db:
            create_administrator(db, "reviewer", self.password, "operator", self.secret, now=self.clock())
        self.reviewer = self.login("reviewer")

    def adjustment(self, amount=1000, revision=0, **overrides):
        return self.command("adjust_wallet", currency="MARKET", amount=amount, expected_wallet_revision=revision, **overrides)

    def test_adjustment_idempotency_permissions_and_double_posting(self):
        body = self.adjustment()
        result = self.request("commands", body)
        self.assertEqual(result["wallet"]["balance"], 1000)
        self.assertEqual(self.request("commands", body), result)
        self.request("commands", dict(body, amount=500), expected=409)
        gm = self.login("moderator")
        self.request("commands", self.adjustment(1, 1), expected=403, person=gm)
        report = self.request("economy")
        self.assertTrue(report["reconciliation"]["ok"], report)
        self.assertEqual((report["player_total"], report["issued"], report["outstanding_supply"]), (1000, 1000, 1000))
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT sum(amount) FROM economy_entries").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM shop_ledger").fetchone()[0], 1)

    def test_wallet_revision_fence_nonnegative_and_recall_is_retirement(self):
        self.request("commands", self.adjustment())
        self.request("commands", self.adjustment(10), expected=409)
        self.request("commands", self.adjustment(-1001, 1), expected=409)
        self.request("commands", self.adjustment(-200, 1))
        report = self.request("economy")
        self.assertEqual((report["player_total"], report["retired"], report["issued"]), (800, 200, 1000))
        self.assertTrue(report["reconciliation"]["ok"])

    def test_large_adjustment_requires_independent_approval(self):
        body = self.adjustment(50000)
        pending = self.request("commands", body)
        self.assertEqual(pending["status"], "pending_approval")
        self.assertEqual(self.request("economy")["player_total"], 0)
        approval = self.command("approve_wallet", proposal_id=pending["command_id"])
        self.request("commands", approval, expected=403)
        result = self.request("commands", approval, person=self.reviewer)
        self.assertEqual(result["wallet"]["balance"], 50000)
        self.assertEqual(self.request("commands", approval, person=self.reviewer), result)
        self.assertEqual(self.request("commands", body)["status"], "completed")
        self.assertEqual(self.request("commands/" + pending["command_id"])["wallet"]["balance"], 50000)

    def test_approval_revalidates_wallet_and_player_control_versions(self):
        pending = self.request("commands", self.adjustment(50000))
        self.request("commands", self.adjustment(1))
        self.request("commands", self.command("approve_wallet", proposal_id=pending["command_id"]), person=self.reviewer, expected=409)
        pending2 = self.request("commands", self.adjustment(50000, 1))
        self.request("commands", self.command("mute", duration_seconds=60))
        self.request("commands", self.command("approve_wallet", expected_version=1, proposal_id=pending2["command_id"]), person=self.reviewer, expected=409)

    def test_market_transfer_changes_ownership_not_supply_and_shop_payment_is_treasury(self):
        bob = self.register("bob")
        owner2 = bob["identity"]["id"]
        self.request("commands", self.adjustment())
        with self.store.connect() as db:
            self.store.shop_money(db, self.owner, "MARKET", -100, "buy:fixture")
            self.store.shop_money(db, owner2, "MARKET", 100, "sell:fixture")
            self.store.shop_money(db, self.owner, "RP", 1000, "admin:test:rp")
            self.store.shop_money(db, self.owner, "RP", -200, "so_fixture")
        report = self.request("economy")
        self.assertEqual((report["player_total"], report["issued"], report["retired"]), (1000, 1000, 0))
        self.assertTrue(report["reconciliation"]["ok"])
        self.assertEqual(report["period_totals"]["market_volume"], 100)
        self.assertEqual(report["period_totals"]["market_trades"], 1)
        report = self.request("economy?currency=RP")
        self.assertEqual(report["player_total"], 800)
        self.assertEqual(report["system_balances"]["system:shop_treasury"], 200)
        self.assertEqual(report["outstanding_supply"], 1000)
        self.assertEqual(report["cash_revenue"]["status"], "not_connected")
        self.assertEqual(report["period_totals"]["shop_net_spend"], 200)

    def test_period_boundaries_and_partial_day_comparison(self):
        now = self.clock()
        today = date.fromisoformat(day_key(now))
        start = datetime.combine(today, datetime.min.time(), SHANGHAI).timestamp()
        with self.store.connect() as db:
            for index, (created, amount) in enumerate(((start - 86401, 10), (start - 86400, 100),
                    (now - 86400 + 1, 50), (start - 1, 20), (start, 300), (now, 200))):
                self.clock.now = created
                self.store.shop_money(db, self.owner, "MARKET", amount, "admin:period:" + str(index))
        self.clock.now = now
        report = self.request("economy?period=today")
        self.assertEqual(report["period_totals"]["issued"], 500)
        self.assertEqual(report["previous_totals"]["issued"], 100)
        self.assertTrue(report["period"]["partial_day"])
        self.assertEqual(report["period"]["previous_as_of"], now - 86400)
        yesterday = (today - timedelta(days=1)).isoformat()
        report = self.request("economy?start=" + yesterday + "&end=" + yesterday)
        self.assertEqual(report["period_totals"]["issued"], 170)
        self.assertFalse(report["period"]["partial_day"])
        self.assertEqual(report["previous_totals"]["issued"], 10)
        self.assertEqual(len(self.request("ledger?start=" + yesterday + "&end=" + yesterday)["entries"]), 3)
        self.assertEqual(len(self.request("ledger?period=today")["entries"]), 2)
        self.assertEqual(len(self.request("ledger")["entries"]), 6)
        self.assertEqual(self.request("economy?period=7d")["period_totals"]["issued"], 680)
        self.assertEqual(self.request("economy?period=30d")["period"]["days"], 30)
        self.assertEqual(self.request("economy?day=" + today.isoformat())["period_totals"]["issued"], 500)

    def test_invalid_dates_and_missing_history_are_explicit(self):
        today = date.fromisoformat(day_key(self.clock()))
        for query in ("day=2023-02-30", "period=weekly", "period=custom", "start=" + today.isoformat(),
                      "start=2023-01-01&end=2023-12-31", "day=2023-01-01&period=today",
                      "start=2023-02-02&end=2023-02-01", "day=" + (today + timedelta(days=1)).isoformat()):
            self.request("economy?" + query, expected=400)
            self.request("ledger?" + query, expected=400)
        report = self.request("economy?period=7d")
        self.assertFalse(report["period"]["coverage_complete"])
        self.assertFalse(report["period"]["previous_coverage_complete"])
        self.assertEqual(report["period_totals"]["market_trades"], 0)

    def test_ledger_corruption_and_unclassified_sources_are_detected(self):
        self.request("commands", self.adjustment())
        with self.store.connect() as db:
            db.execute("UPDATE shop_wallets SET balance=999 WHERE owner=?", (self.owner,))
        report = self.request("economy")
        self.assertFalse(report["reconciliation"]["ok"])
        self.assertEqual(len(report["reconciliation"]["wallet_mismatches"]), 1)
        with self.store.connect() as db:
            self.store.shop_money(db, self.owner, "RP", 5, "unknown-source")
        self.assertEqual(self.request("economy?currency=RP")["reconciliation"]["unclassified_events"], 1)
        with self.assertRaises(sqlite3.IntegrityError):
            with self.store.connect() as db:
                db.execute("DELETE FROM shop_ledger")

    def test_wallet_and_postings_roll_back_when_audit_fails(self):
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER reject_wallet_audit BEFORE INSERT ON admin_audit WHEN NEW.action='wallet_adjusted' BEGIN SELECT RAISE(ABORT,'audit failed'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.request("commands", self.adjustment())
        report = self.request("economy")
        self.assertEqual(report["player_total"], 0)
        self.assertEqual(self.request("ledger")["entries"], [])

    def batch(self, recipients):
        return {"id": uuid.uuid4().hex, "action": "batch_wallet", "reason": "Activity batch fixture",
                "currency": "MARKET", "recipients": [{"owner": owner, "amount": amount,
                    "expected_control_version": 0, "expected_wallet_revision": 0} for owner, amount in recipients]}

    def test_batch_requires_independent_review_and_posts_all_targets_once(self):
        bob = self.register("bob")["identity"]["id"]
        body = self.batch([(self.owner, 100), (bob, 200)])
        result = self.request("commands", body)
        self.assertEqual(result["status"], "pending_approval")
        approval = {"id": uuid.uuid4().hex, "action": "approve_batch", "reason": "Reviewed batch", "proposal_id": body["id"]}
        self.request("commands", approval, expected=403)
        completed = self.request("commands", approval, person=self.reviewer)
        self.assertEqual(self.request("commands", approval, person=self.reviewer), completed)
        self.assertEqual(self.request("commands", body)["status"], "completed")
        self.assertEqual(self.request("economy")["player_total"], 300)
        self.assertTrue(self.request("economy")["reconciliation"]["ok"])

    def test_batch_conflict_or_audit_failure_cannot_partially_pay(self):
        bob = self.register("bob")["identity"]["id"]
        body = self.batch([(self.owner, 100), (bob, 200)])
        self.request("commands", body)
        self.request("commands", self.adjustment(1, target=bob))
        approval = {"id": uuid.uuid4().hex, "action": "approve_batch", "reason": "Reviewed batch", "proposal_id": body["id"]}
        self.request("commands", approval, person=self.reviewer, expected=409)
        self.assertEqual(self.request("economy")["player_total"], 1)
        body = self.batch([(self.owner, 100), (bob, 200)])
        body["recipients"][1]["expected_wallet_revision"] = 1
        self.request("commands", body)
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER reject_batch_audit BEFORE INSERT ON admin_audit WHEN NEW.action='batch_wallet_adjusted' BEGIN SELECT RAISE(ABORT,'audit failed'); END")
        approval.update(id=uuid.uuid4().hex, proposal_id=body["id"])
        with self.assertRaises(sqlite3.IntegrityError):
            self.request("commands", approval, person=self.reviewer)
        self.assertEqual(self.request("economy")["player_total"], 1)

    def test_revoked_initiator_cannot_leave_executable_pending_grants(self):
        pending = self.request("commands", self.adjustment(50000))
        with self.store.connect() as db:
            db.execute("UPDATE admin_users SET enabled=0 WHERE username='operator'")
        approval = self.command("approve_wallet", proposal_id=pending["command_id"])
        self.request("commands", approval, person=self.reviewer, expected=403)


if __name__ == "__main__":
    unittest.main()
