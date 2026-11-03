from datetime import date, timedelta
import json
import unittest
import uuid

import test_admin as fixtures
from admin_data import day_key
from admin_jobs import csv_text


class AdminJobTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    setUp = fixtures.AdminTests.setUp
    tearDown = fixtures.AdminTests.tearDown

    def test_export_lifecycle_permission_expiry_and_actor_isolation(self):
        body = {"id": uuid.uuid4().hex, "kind": "players"}
        reader = self.login("reader")
        self.request("exports", body, person=reader, expected=403)
        self.request("exports", body, expected=202)
        self.request("exports", body)
        self.store.process_admin_export()
        result = self.request("exports/" + body["id"])
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["result"]["rows"], 1)
        self.assertIn("alice", result["result"]["csv"])
        for secret in (self.alice["token"], self.password, "password_hash", "totp_secret"):
            self.assertNotIn(secret, result["result"]["csv"])
        self.clock.advance(31)
        with self.store.connect() as db:
            db.execute("UPDATE admin_users SET role='admin' WHERE username='reader'")
        reader = self.login("reader")
        self.request("exports/" + body["id"], person=reader, expected=403)
        self.clock.advance(86401)
        self.admin = self.login()
        self.assertEqual(self.request("exports/" + body["id"])["status"], "expired")
        self.store.process_admin_export()
        with self.store.connect() as db:
            self.assertIsNone(db.execute("SELECT result FROM admin_exports WHERE id=?", (body["id"],)).fetchone()[0])

    def test_csv_formula_injection_and_numeric_amounts(self):
        result = csv_text(["name", "amount"], [["=HYPERLINK(\"evil\")", -25], [" \t+cmd", 10], ["@SUM(A1)", 0]])
        self.assertIn("'=HYPERLINK", result)
        self.assertIn("' \t+cmd", result)
        self.assertIn("'@SUM", result)
        self.assertIn(",-25", result)

    def test_ledger_export_dates_stay_anchored_across_midnight_and_retry(self):
        self.clock.advance(86400 - (self.clock() + 8 * 3600) % 86400 - 10)
        self.admin = self.login()
        day = day_key(self.clock())
        with self.store.connect() as db:
            self.store.shop_money(db, self.owner, "MARKET", 100, "admin:before-midnight")
        body = {"id": uuid.uuid4().hex, "kind": "ledger", "currency": "MARKET", "period": "today"}
        self.request("exports", body, expected=202)
        self.clock.advance(20)
        with self.store.connect() as db:
            self.store.shop_money(db, self.owner, "MARKET", 200, "admin:next-day")
        self.store.process_admin_export()
        result = self.request("exports/" + body["id"])["result"]
        self.assertEqual(result["rows"], 1)
        self.assertIn("admin:before-midnight", result["csv"])
        self.assertNotIn("admin:next-day", result["csv"])
        self.assertEqual((result["filters"]["start"], result["filters"]["end"]), (day, day))
        listed = self.request("exports")["exports"][0]
        self.assertEqual(listed["filters"], {"currency": "MARKET", "start": day, "end": day})
        self.assertEqual(self.request("exports", body)["status"], "ready")
        self.request("exports", dict(body, id=uuid.uuid4().hex, period="yesterday", kind="players"), expected=400)

    def test_queue_limit_conflict_and_restart_recovery(self):
        first = {"id": uuid.uuid4().hex, "kind": "audit"}
        self.request("exports", first, expected=202)
        self.request("exports", dict(first, kind="players"), expected=409)
        self.request("exports", {"id": uuid.uuid4().hex, "kind": "players"}, expected=202)
        self.request("exports", {"id": uuid.uuid4().hex, "kind": "ledger"}, expected=429)
        with self.store.connect() as db:
            db.execute("UPDATE admin_exports SET status='working' WHERE id=?", (first["id"],))
        self.store.close()
        from service import Store
        self.store = Store(self.database, clock=self.clock)
        self.store.process_admin_export()
        self.assertEqual(self.request("exports/" + first["id"])["status"], "ready")

    def test_retention_uses_first_observed_activity_and_unmatured_is_null(self):
        today = date.fromisoformat(day_key(self.clock()))
        cohort = (today - timedelta(days=30)).isoformat()
        with self.store.connect() as db:
            db.execute("INSERT INTO player_first_activity VALUES(?,?,?)", (self.owner, cohort, self.clock() - 30 * 86400))
            for delta in (0, 1, 7, 30):
                db.execute("INSERT INTO player_activity VALUES(?,?,?,?,0)", (self.owner, (date.fromisoformat(cohort) + timedelta(days=delta)).isoformat(), self.clock(), self.clock()))
        result = self.request("retention")["cohorts"][0]
        self.assertEqual((result["cohort"], result["accounts"], result["d1"], result["d7"], result["d30"]), (cohort, 1, 1, 1, 1))
        bob = self.register("bob")
        with self.store.connect() as db:
            self.store.record_player_activity(db, bob["identity"]["id"])
        result = self.request("retention")["cohorts"][0]
        self.assertEqual(result["cohort"], today.isoformat())
        self.assertIsNone(result["d1"])
        self.request("retention?day=9999-01-01", expected=400)

    def test_risk_evidence_changes_require_review_and_cleared_case_reopens(self):
        with self.store.connect() as db:
            self.store.shop_money(db, self.owner, "MARKET", 100, "admin:test:grant")
            db.execute("UPDATE shop_wallets SET balance=99 WHERE owner=? AND currency='MARKET'", (self.owner,))
        self.store.scan_admin_risks()
        first = self.request("alerts")["alerts"][0]
        self.assertEqual(first["rule"], "ledger_reconciliation")
        self.assertFalse(self.request("alerts")["automatic_enforcement"])
        self.store.scan_admin_risks()
        self.assertEqual(self.request("alerts")["alerts"][0]["version"], first["version"])
        body = self.command("alert_status", target=first["id"], expected_version=first["version"], status="investigating")
        self.request("commands", body)
        self.request("commands", body)
        with self.store.connect() as db:
            db.execute("UPDATE shop_wallets SET balance=98 WHERE owner=? AND currency='MARKET'", (self.owner,))
        self.store.scan_admin_risks()
        self.request("commands", dict(body, id=uuid.uuid4().hex, status="resolved"), expected=409)
        with self.store.connect() as db:
            db.execute("UPDATE shop_wallets SET balance=100 WHERE owner=? AND currency='MARKET'", (self.owner,))
        self.store.scan_admin_risks()
        self.assertEqual(self.request("alerts")["alerts"][0]["present"], 0)
        with self.store.connect() as db:
            db.execute("UPDATE shop_wallets SET balance=98 WHERE owner=? AND currency='MARKET'", (self.owner,))
        self.store.scan_admin_risks()
        self.assertEqual(self.request("alerts")["alerts"][0]["status"], "open")


if __name__ == "__main__":
    unittest.main()
