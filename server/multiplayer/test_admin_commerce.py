import json
import sqlite3
import unittest
import uuid

import test_admin as fixtures
from admin_data import create_administrator


class CommerceTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    game = fixtures.AdminTests.game
    tearDown = fixtures.AdminTests.tearDown

    def setUp(self):
        fixtures.AdminTests.setUp(self)
        with self.store.connect() as db:
            create_administrator(db, "reviewer", self.password, "operator", self.secret, now=self.clock())
        self.reviewer = self.login("reviewer")

    def business(self, action, **extra):
        return {"id": uuid.uuid4().hex, "action": action, "reason": "Commerce fixture ticket", **extra}

    def approve(self, proposal, **extra):
        return self.business("approve_commerce", proposal_id=proposal["command_id"], **extra)

    def code_data(self):
        return {"code": "FIXTURE-" + uuid.uuid4().hex.upper(), "currency": "RP", "amount": 100,
                "maximum": 10, "expires": int(self.clock() + 3600), "batch": "fixture-campaign"}

    def test_code_inactive_until_independent_approval_and_no_raw_code_storage(self):
        data = self.code_data()
        body = self.business("create_code", data=data)
        pending = self.request("commands", body)
        self.assertEqual(pending["status"], "pending_approval")
        self.assertEqual(self.request("commands", body), pending)
        self.game("cloud/open", {"session_id": self.session, "compatibility": self.compat})
        redeem = {"request_id": uuid.uuid4().hex, "session_id": self.session, "code": data["code"]}
        self.game("shop/redeem", redeem, expected=409)
        approval = self.approve(pending)
        self.request("commands", approval, expected=403)
        self.request("commands", approval, person=self.reviewer)
        redeem["request_id"] = uuid.uuid4().hex
        self.game("shop/redeem", redeem)
        self.assertEqual(self.request("economy?currency=RP")["player_total"], 100)
        with self.store.connect() as db:
            records = [row[0] for table in ("admin_audit", "shop_audit", "commerce_proposals") for row in db.execute("SELECT document FROM " + table)]
            records += [row[0] for row in db.execute("SELECT response FROM admin_commands")]
        self.assertNotIn(data["code"], " ".join(records))

    def test_control_cas_and_market_pause_keep_queries_available(self):
        config = self.request("commerce")
        control = next(item for item in config["controls"] if item["key"] == "market_paused")
        body = self.business("commerce_control", data={"key": "market_paused", "value": True}, expected_hash=control["hash"])
        self.request("commands", body)
        self.request("commands", dict(body, id=uuid.uuid4().hex), expected=409)
        self.game("market/listings", {"request_id": uuid.uuid4().hex}, expected=503)
        status, result = self.store.request("GET", "/v1/market/listings", token=self.alice["token"])
        self.assertEqual(status, 200, result)
        reader = self.login("reader")
        self.request("commerce", person=reader, expected=403)
        self.request("commands", body, person=reader, expected=403)

    def test_refund_independent_review_wallet_version_and_entitlement_revocation(self):
        self.store.shop_admin("fixture", "credit", "rp-seed", {"owner": self.owner, "currency": "RP", "amount": 1000, "reason": "Fixture setup"})
        order = {"id": "so_" + uuid.uuid4().hex, "status": "completed", "total": 200, "grants": ["fixture_hat"], "created_at": self.clock()}
        with self.store.connect() as db:
            self.store.shop_money(db, self.owner, "RP", -200, order["id"])
            db.execute("INSERT INTO shop_orders VALUES(?,?,?,?,?)", (order["id"], self.owner, uuid.uuid4().hex, "fixture", json.dumps(order)))
            db.execute("INSERT INTO shop_grants VALUES(?,?,?,1)", (self.owner, "fixture_hat", order["id"]))
        pending = self.request("commands", self.business("refund_order", data={"order_id": order["id"], "expected_wallet_revision": 2, "player_message": "运营退款"}))
        self.assertEqual(self.request("economy?currency=RP")["player_total"], 800)
        self.request("commands", self.approve(pending), person=self.reviewer)
        self.assertEqual(self.request("economy?currency=RP")["player_total"], 1000)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT active FROM shop_grants WHERE order_id=?", (order["id"],)).fetchone()[0], 0)
            self.assertEqual(json.loads(db.execute("SELECT document FROM shop_orders WHERE id=?", (order["id"],)).fetchone()[0])["status"], "refunded")
        self.request("commands", self.approve(pending), person=self.reviewer, expected=409)

    def test_market_cancellation_releases_exact_asset_and_hides_staff_notes(self):
        self.game("cloud/open", {"session_id": self.session, "compatibility": self.compat})
        asset = self.game("collections/starter", {"request_id": uuid.uuid4().hex, "catalog_version": 1}, expected=201)["asset"]
        listed = self.game("market/listings", {"request_id": uuid.uuid4().hex, "session_id": self.session, "asset_id": asset["id"], "price": 100})["receipt"]
        body = self.business("cancel_listing", reference=listed["listing_id"], reason="Private fraud investigation notes")
        self.request("commands", body)
        with self.store.connect() as db:
            self.assertIsNone(db.execute("SELECT 1 FROM asset_locks WHERE asset_id=?", (asset["id"],)).fetchone())
            self.assertEqual(db.execute("SELECT owner FROM hosted_assets WHERE id=?", (asset["id"],)).fetchone()[0], self.owner)
            receipts = " ".join(row[0] for row in db.execute("SELECT document FROM market_receipts WHERE owner=?", (self.owner,)))
        self.assertNotIn(body["reason"], receipts)

    def test_code_and_shop_audit_roll_back_if_management_audit_fails(self):
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER reject_code_audit BEFORE INSERT ON admin_audit WHEN NEW.action='create_code' BEGIN SELECT RAISE(ABORT,'audit failed'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.request("commands", self.business("create_code", data=self.code_data()))
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM shop_codes").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM commerce_proposals").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM shop_audit").fetchone()[0], 0)

    def test_disabling_reserved_code_cancels_its_pending_activation(self):
        pending = self.request("commands", self.business("create_code", data=self.code_data()))
        code = self.request("commerce")["codes"][0]
        self.request("commands", self.business("disable_code", reference=code["hash"], expected_hash=code["configuration_hash"]))
        self.request("commands", self.approve(pending), person=self.reviewer, expected=409)

    def test_bundle_price_changes_affect_full_and_owned_component_quotes(self):
        entry = next(item for item in self.request("commerce")["products"] if item["product"]["id"] == "bundle-azure")
        self.request("commands", self.business("commerce_control", data={"key": entry["key"], "value": {"price": 200}}, expected_hash=entry["hash"]))
        catalog = self.store.shop_catalog()
        with self.store.connect() as db:
            product = self.store.shop_product(db, next(item for item in catalog["products"] if item["id"] == "bundle-azure"))
        full, _ = self.store.shop_quote(product, set(), catalog)
        partial, missing = self.store.shop_quote(product, {"clothes:azure"}, catalog)
        owned, _ = self.store.shop_quote(product, set(product["grants"]), catalog)
        self.assertEqual((full, partial, owned), (200, 80, 0))
        self.assertNotIn("clothes:azure", missing)


if __name__ == "__main__":
    unittest.main()
