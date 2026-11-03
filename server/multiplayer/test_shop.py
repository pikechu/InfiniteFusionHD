import concurrent.futures
import copy
import json
import sqlite3
import unittest
import uuid
from pathlib import Path
from service import Store, PROTOCOL, RULES, APIError
from test_service import FakeClock


class ShopTests(unittest.TestCase):
    def setUp(self):
        directory = Path(__file__).resolve().parents[2] / "temp/multiplayer/shop-tests"
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / (uuid.uuid4().hex + ".sqlite3")
        self.clock = FakeClock()
        self.store = Store(self.path, clock=self.clock)
        self.compat = {"protocol": PROTOCOL, "game_version": "test", "data_hash": "test-data", "mods_hash": "no-mods", "rules_version": RULES}
        self.accounts = []
        for name in ("alice", "bob"):
            person = self.call(None, "/v1/auth/register", {"username": name, "password": "password123", "protocol": PROTOCOL}, 201)
            person["session"] = uuid.uuid4().hex
            self.call(person, "/v1/cloud/open", {"session_id": person["session"], "compatibility": self.compat})
            self.accounts.append(person)
        self.a, self.b = self.accounts
        self.catalog = self.get(self.a, "/v1/shop/catalog")["catalog"]

    def tearDown(self):
        self.store.close()
        for suffix in ("", "-wal", "-shm"):
            Path(str(self.path) + suffix).unlink(missing_ok=True)

    def call(self, who, path, body, expected=200):
        status, result = self.store.request("POST", path, body, who["token"] if who else None)
        self.assertEqual(status, expected, result)
        return result

    def post(self, who, path, body=None, expected=200, request_id=None):
        return self.call(who, path, dict(body or {}, session_id=who["session"], request_id=request_id or uuid.uuid4().hex), expected)

    def get(self, who, path, expected=200):
        status, result = self.store.request("GET", path, token=who["token"])
        self.assertEqual(status, expected, result)
        return result

    def credit(self, who=None, amount=1000, currency="RP", reference=None):
        who = who or self.a
        return self.store.shop_admin("test", "credit", reference or uuid.uuid4().hex, {"owner": who["identity"]["id"], "currency": currency, "amount": amount, "reason": "isolated test grant"})

    def buy(self, sku="shop-clothes-azure", total=300, expected=201, who=None, request_id=None):
        return self.post(who or self.a, "/v1/shop/orders", {"sku": sku, "quantity": 1, "catalog_hash": self.catalog["hash"], "expected_total": total}, expected, request_id)

    def test_purchase_has_one_wallet_order_and_entitlement(self):
        self.credit()
        result = self.buy()
        self.assertEqual(result["wallet"]["balance"], 700)
        self.assertEqual(result["entitlements"], ["clothes:azure"])
        self.assertEqual(len(self.get(self.a, "/v1/shop/orders")["orders"]), 1)
        self.assertEqual(sum(x["amount"] for x in self.get(self.a, "/v1/shop/ledger")["ledger"]), 700)

    def test_insufficient_funds_and_duplicate_with_different_ids(self):
        self.buy(expected=409)
        self.credit()
        self.buy()
        result = self.buy(expected=409)
        self.assertEqual(result["error"]["code"], "already_owned")
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 700)

    def test_order_survives_operations_cleanup_and_restart(self):
        self.credit()
        request = uuid.uuid4().hex
        order = self.buy(request_id=request)["order"]
        with self.store.connect() as db:
            db.execute("DELETE FROM operations")
        self.store.close()
        self.store = Store(self.path, clock=self.clock)
        self.assertEqual(self.buy(request_id=request, expected=200)["order"], order)
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 700)

    def test_concurrent_permanent_purchases_only_debit_once(self):
        self.credit()
        def purchase(_):
            return self.store.request("POST", "/v1/shop/orders", {"session_id": self.a["session"], "request_id": uuid.uuid4().hex, "sku": "shop-clothes-azure", "quantity": 1, "catalog_hash": self.catalog["hash"], "expected_total": 300}, self.a["token"])[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(purchase, range(4)))
        self.assertEqual(results.count(201), 1)
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 700)

    def test_committed_receipts_recover_after_lease_expiry_and_journal_pruning(self):
        self.credit()
        request_id = uuid.uuid4().hex
        order = self.buy(request_id=request_id)["order"]
        asset = self.seed_asset(self.a)
        listing_request = uuid.uuid4().hex
        listing = self.post(self.a, "/v1/market/listings", {"asset_id": asset["id"], "price": 100}, request_id=listing_request)["receipt"]
        self.clock.advance(121)
        with self.store.connect() as db:
            db.execute("DELETE FROM operations")
        self.assertEqual(self.buy(request_id=request_id, expected=200)["order"], order)
        self.assertEqual(self.post(self.a, "/v1/market/listings", {"asset_id": asset["id"], "price": 100}, request_id=listing_request)["receipt"], listing)
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 700)
        self.buy("shop-hat-jade", 100, 409)

    def test_transaction_rollback_after_debit(self):
        self.credit()
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER fail_grant BEFORE INSERT ON shop_grants BEGIN SELECT RAISE(ABORT,'test crash'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.buy()
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 1000)
        self.assertEqual(self.get(self.a, "/v1/shop/orders")["orders"], [])

    def test_stale_catalog_price_quantity_and_foreign_order(self):
        self.credit()
        self.buy(total=299, expected=409)
        for quantity in (0, -1, True, 2, 2**63):
            self.post(self.a, "/v1/shop/orders", {"sku": "shop-clothes-azure", "quantity": quantity, "catalog_hash": self.catalog["hash"], "expected_total": 300}, 400)
        self.post(self.a, "/v1/shop/orders", {"sku": "shop-clothes-azure", "quantity": 1, "catalog_hash": "stale", "expected_total": 300}, 409)
        order = self.buy()["order"]
        self.get(self.b, "/v1/shop/orders/" + order["id"], 404)

    def test_equipment_requires_owned_resource_and_live_session(self):
        self.post(self.a, "/v1/shop/equipment", {"catalog_hash": self.catalog["hash"], "slots": {"clothes": "clothes:azure"}}, 403)
        self.credit()
        self.buy()
        equipment = self.post(self.a, "/v1/shop/equipment", {"catalog_hash": self.catalog["hash"], "slots": {"clothes": "clothes:azure"}})["equipment"]
        self.assertEqual(equipment["slots"]["clothes"], "clothes:azure")
        self.clock.advance(121)
        self.post(self.a, "/v1/shop/equipment", {"catalog_hash": self.catalog["hash"], "slots": {}}, 409)

    def test_bundle_prorates_missing_parts_and_season_ends(self):
        self.credit()
        self.buy()
        self.buy("bundle-azure", 160)
        self.assertEqual(len(self.get(self.a, "/v1/shop/entitlements")["entitlements"]), 3)
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 540)
        self.store.shop_admin("test", "control", "bundle-sale", {"key": "sku:bundle-jade", "value": {"price": 250}})
        self.buy("bundle-jade", 250)
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 290)
        self.store.shop_admin("test", "control", "season-end", {"key": "sku:season-ember", "value": {"ends_at": 1}})
        self.buy("season-ember", 350, 409)

    def test_admin_pause_price_graylist_and_replayed_credit(self):
        self.credit(reference="same-event")
        self.credit(reference="same-event")
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 1000)
        self.store.shop_admin("test", "control", "pause", {"key": "paused", "value": True})
        self.buy(expected=503)
        self.store.shop_admin("test", "control", "unpause", {"key": "paused", "value": False})
        self.store.shop_admin("test", "control", "price", {"key": "sku:shop-clothes-azure", "value": {"price": 320}})
        self.buy(expected=409)
        self.buy(total=320)

    def test_redeem_is_unique_bound_and_secret_not_audited(self):
        data = {"code": "ISOLATED-CODE-123", "currency": "RP", "amount": 500, "expires": self.clock() + 100, "maximum": 2, "target": self.a["identity"]["id"], "batch": "test"}
        self.store.shop_admin("test", "code", "code-event", data)
        self.store.shop_admin("test", "code", "code-event", data)
        self.post(self.b, "/v1/shop/redeem", {"code": data["code"]}, 409)
        self.post(self.a, "/v1/shop/redeem", {"code": data["code"]})
        self.post(self.a, "/v1/shop/redeem", {"code": data["code"]})
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["wallet"]["balance"], 500)
        with self.store.connect() as db:
            self.assertNotIn(data["code"], " ".join(row[0] for row in db.execute("SELECT document FROM shop_audit")))

    def test_rejected_code_guesses_rate_limit(self):
        for _ in range(10):
            self.post(self.a, "/v1/shop/redeem", {"code": "WRONG-CODE-1234"}, 409)
        self.post(self.a, "/v1/shop/redeem", {"code": "WRONG-CODE-1234"}, 429)

    def test_refund_revokes_and_uses_compensating_ledger(self):
        self.credit()
        order = self.buy()["order"]
        self.post(self.a, "/v1/shop/equipment", {"catalog_hash": self.catalog["hash"], "slots": {"clothes": "clothes:azure"}})
        self.store.shop_admin("test", "refund", "refund-event", {"order_id": order["id"], "reason": "test"})
        state = self.get(self.a, "/v1/shop/state")
        self.assertEqual(state["wallet"]["balance"], 1000)
        self.assertEqual(state["entitlements"], [])
        self.assertEqual(state["equipment"]["slots"], {})
        self.assertEqual(self.get(self.a, "/v1/shop/orders")["orders"][0]["status"], "refunded")

    def test_world_uses_server_equipment_not_uploaded_purchase_claim(self):
        self.credit()
        self.buy()
        self.post(self.a, "/v1/shop/equipment", {"catalog_hash": self.catalog["hash"], "slots": {"clothes": "clothes:azure"}})
        for person in self.accounts:
            self.call(person, "/v1/world/join", {"session_id": person["session"], "compatibility": self.compat})
        base = {"map_id": 1, "map_hash": "a" * 64, "width": 20, "height": 20, "x": 1, "y": 1, "direction": 2, "character_id": 0, "moving": False, "appearance": {"clothes": "red", "hair": "3_red", "hat": None, "skin_tone": "default"}}
        for person in self.accounts:
            result = self.call(person, "/v1/world/sync", {"session_id": person["session"], "seq": 1, "after": 0, "position": base})
        appearance = result["world"]["players"][0]["appearance"]
        self.assertEqual(appearance["clothes"], "shopazure")
        self.assertNotIn("entitlements", appearance)
        bad = copy.deepcopy(base)
        bad["appearance"]["clothes"] = "../../bad"
        self.call(self.b, "/v1/world/sync", {"session_id": self.b["session"], "seq": 2, "after": 0, "position": bad}, 400)

    def seed_asset(self, who):
        # Existing server-controlled starter path; no client snapshot minting.
        return self.call(who, "/v1/collections/starter", {"catalog_version": 1, "request_id": uuid.uuid4().hex}, 201)["asset"]

    def test_market_transfer_currency_and_lock_atomicity(self):
        asset = self.seed_asset(self.a)
        self.credit(self.b, 1000, "MARKET")
        listing = self.post(self.a, "/v1/market/listings", {"asset_id": asset["id"], "price": 200})["receipt"]["listing_id"]
        self.post(self.a, "/v1/market/listings", {"asset_id": asset["id"], "price": 200}, 409)
        public = self.get(self.b, "/v1/market/listings")["listings"][0]
        self.assertNotIn("owner", public["snapshot"])
        self.assertNotIn("personal_id", public["snapshot"])
        self.post(self.b, "/v1/market/buy/" + listing, {"expected_price": 200})
        self.post(self.a, "/v1/market/cancel/" + listing, {}, 409)
        self.assertEqual(self.get(self.b, "/v1/collections")["assets"][0]["id"], asset["id"])
        self.assertEqual(self.get(self.a, "/v1/shop/wallet")["market_wallet"]["balance"], 200)
        self.assertEqual(self.get(self.b, "/v1/shop/wallet")["market_wallet"]["balance"], 800)

    def test_market_expiry_releases_lock_for_other_systems(self):
        asset = self.seed_asset(self.a)
        self.post(self.a, "/v1/market/listings", {"asset_id": asset["id"], "price": 100})
        self.clock.advance(7 * 86400 + 1)
        self.a["token"] = self.call(None, "/v1/auth/login", {"username": "alice", "password": "password123", "protocol": PROTOCOL})["token"]
        self.assertEqual(self.get(self.a, "/v1/collections")["assets"][0]["locked"], False)

    def test_no_local_money_or_admin_http_routes(self):
        self.post(self.a, "/v1/shop/credit", {"amount": 10000}, 404)
        self.post(self.a, "/v1/shop/orders", {"money": 999999}, 400)

    def test_history_cursor_keeps_all_entries_and_filters_account(self):
        for index in range(25):
            self.credit(amount=1, reference="page-" + str(index))
        first = self.get(self.a, "/v1/shop/ledger/page/0")
        self.assertEqual(len(first["ledger"]), 20)
        second = self.get(self.a, "/v1/shop/ledger/page/" + str(first["next_cursor"]))
        self.assertEqual(len(second["ledger"]), 5)
        self.assertEqual(len({row["id"] for row in first["ledger"] + second["ledger"]}), 25)
        self.assertEqual(self.get(self.b, "/v1/shop/ledger/page/0")["ledger"], [])
        self.get(self.a, "/v1/shop/ledger/page/not-a-number", 400)

    def test_market_search_sorts_and_does_not_expose_other_mine(self):
        asset = self.seed_asset(self.a)
        self.post(self.a, "/v1/market/listings", {"asset_id": asset["id"], "price": 100})
        result = self.get(self.b, "/v1/market/listings/page/0/low/_")
        self.assertEqual(len(result["listings"]), 1)
        self.assertEqual(self.get(self.b, "/v1/market/mine/page/0/recent/_")["listings"], [])
        self.assertEqual(self.get(self.b, "/v1/market/listings/page/0/low/NO_SUCH_SPECIES")["listings"], [])


if __name__ == "__main__":
    unittest.main()
