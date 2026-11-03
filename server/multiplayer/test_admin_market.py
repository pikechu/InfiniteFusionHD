import json
from contextlib import closing
import sqlite3
import unittest
import uuid

import test_admin as fixtures
from service import Store


class MarketPriceTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    game = fixtures.AdminTests.game
    tearDown = fixtures.AdminTests.tearDown

    def setUp(self):
        fixtures.AdminTests.setUp(self)
        self.bob = self.register("bob")
        self.players = {self.owner: self.alice, self.bob["identity"]["id"]: self.bob}
        self.sessions = {owner: "prices_" + uuid.uuid4().hex for owner in self.players}
        for owner, person in self.players.items():
            self.game("cloud/open", {"session_id": self.sessions[owner], "compatibility": self.compat}, person=person)
            with self.store.connect() as db:
                self.store.shop_money(db, owner, "MARKET", 1000000, "admin:market-price-fixture:" + owner)
        self.asset = self.game("collections/starter", {"request_id": uuid.uuid4().hex, "catalog_version": 1}, expected=201)["asset"]
        self.asset_owner = self.owner

    def sell(self, price, *, asset_id=None, seller=None, buyer=None):
        seller = seller or self.asset_owner
        buyer = buyer or next(owner for owner in self.players if owner != seller)
        asset_id = asset_id or self.asset["id"]
        listed = self.game("market/listings", {"request_id": uuid.uuid4().hex, "session_id": self.sessions[seller], "asset_id": asset_id, "price": price}, person=self.players[seller])["receipt"]
        self.clock.advance(2)
        body = {"request_id": uuid.uuid4().hex, "session_id": self.sessions[buyer], "expected_price": price}
        bought = self.game("market/buy/" + listed["listing_id"], body, person=self.players[buyer])
        self.asset_owner = buyer
        return listed, body, bought

    def add_player(self, name, funded=False):
        person = self.register(name)
        owner = person["identity"]["id"]
        self.players[owner] = person
        self.sessions[owner] = "prices_" + uuid.uuid4().hex
        self.game("cloud/open", {"session_id": self.sessions[owner], "compatibility": self.compat}, person=person)
        if funded:
            with self.store.connect() as db:
                self.store.shop_money(db, owner, "MARKET", 1000000, "admin:price-funding:" + owner)
        return owner

    def test_verified_sale_is_counted_once_across_receipts_retries_and_restart(self):
        listed, body, bought = self.sell(250)
        self.assertEqual(self.game("market/buy/" + listed["listing_id"], body, person=self.players[self.asset_owner]), bought)
        report = self.request("market-prices?period=today")
        self.assertEqual(report["summary"]["trades"], 1)
        self.assertEqual(report["summary"]["volume"], 250)
        self.assertEqual(report["summary"]["median"], 250)
        self.assertTrue(report["integrity"]["ok"], report)
        self.assertFalse(report["groups"][0]["sufficient_sample"])
        self.assertEqual(report["summary"]["median_seconds_to_sell"], 2)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.assertEqual(self.request("market-prices?period=today")["summary"]["trades"], 1)
        with self.assertRaises(sqlite3.IntegrityError):
            with self.store.connect() as db:
                db.execute("DELETE FROM market_sales")

    def test_medians_quantiles_repeated_assets_and_quotes_are_separate(self):
        for price in (100, 200, 300, 400, 1000):
            self.sell(price)
        # A current ask never becomes paid volume or a historical median.
        self.game("market/listings", {"request_id": uuid.uuid4().hex, "session_id": self.sessions[self.asset_owner], "asset_id": self.asset["id"], "price": 999999}, person=self.players[self.asset_owner])
        report = self.request("market-prices?period=today")
        summary = report["summary"]
        self.assertEqual((summary["trades"], summary["volume"], summary["median"], summary["p10"], summary["p90"]), (5, 2000, 300, 100, 1000))
        self.assertEqual((summary["distinct_assets"], summary["buyers"], summary["sellers"]), (1, 2, 2))
        self.assertEqual(report["active_asks"], {"count": 1, "median": 999999, "median_status": "available"})
        self.assertEqual(report["daily"][0]["volume"], 2000)
        self.assertFalse(report["groups"][0]["sufficient_sample"])
        self.store.scan_admin_risks()
        self.assertIn("market_asset_round_trip", {row["rule"] for row in self.request("alerts")["alerts"]})

    def test_species_level_shiny_iv_and_dates_filter_actual_sales(self):
        self.sell(150)
        species = self.asset["snapshot"]["species"]
        level = self.asset["snapshot"]["level"]
        selected = self.request("market-prices?period=today&species=" + species + "&min_level=" + str(level) + "&max_level=" + str(level) + "&min_iv=186&shiny=0")
        self.assertEqual(selected["summary"]["trades"], 1)
        for query in ("species=PIKACHU", "min_level=99", "shiny=1", "period=yesterday"):
            self.assertEqual(self.request("market-prices?" + query)["summary"]["trades"], 0)
        for query in ("min_level=abc", "max_level=0", "min_level=90&max_level=5", "min_iv=187", "shiny=true", "species=../bad", "day=2023-02-30"):
            self.request("market-prices?" + query, expected=400)
        reader = self.login("reader")
        self.assertEqual(self.request("market-prices", person=reader)["currency"], "MARKET")

    def test_unverified_historical_sold_rows_are_flagged_and_never_prices(self):
        with self.store.connect() as db:
            db.execute("INSERT INTO market_listings VALUES('ml_unverified',?,?,999,'sold',?,?)",
                (self.owner, self.asset["id"], self.clock(), json.dumps({"snapshot": self.asset["snapshot"], "created_at": self.clock()})))
        report = self.request("market-prices?period=today")
        self.assertEqual(report["summary"]["trades"], 0)
        self.assertFalse(report["integrity"]["ok"])
        self.assertEqual(report["integrity"]["unprojected_sales"], 1)
        self.store.scan_admin_risks()
        self.assertIn("market_sale_journal_gap", {row["rule"] for row in self.request("alerts")["alerts"]})

    def test_legacy_backfill_verifies_ledger_and_is_repeatable(self):
        self.sell(100)
        self.store.close()
        # Simulate the supported pre-analytics schema, not missing v6 journals.
        with closing(sqlite3.connect(self.database)) as db:
            db.execute("UPDATE admin_metadata SET value='5' WHERE key='schema_version'")
            db.execute("DROP TRIGGER market_sales_immutable_delete")
            db.execute("DELETE FROM market_sales")
            db.execute("DELETE FROM admin_metadata WHERE key IN ('market_sales_backfill_v1','market_sales_started')")
            db.commit()
        self.store = Store(self.database, clock=self.clock)
        self.assertEqual(self.request("market-prices")["summary"]["trades"], 1)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.assertEqual(self.request("market-prices")["summary"]["volume"], 100)

    def test_missing_canonical_sales_journal_stops_startup(self):
        with self.store.connect() as db:
            db.execute("DROP TABLE market_sales")
        self.store.close()
        with self.assertRaises(RuntimeError):
            Store(self.database, clock=self.clock)

    def test_paid_sales_export_uses_same_filters_and_one_row_per_listing(self):
        self.sell(100)
        self.sell(200)
        species = self.asset["snapshot"]["species"]
        body = {"id": uuid.uuid4().hex, "kind": "market_sales", "currency": "MARKET", "period": "today", "species": species, "min_level": 1, "max_level": 100, "shiny": "0", "min_iv": 186}
        self.request("exports", body, expected=202)
        self.store.process_admin_export()
        result = self.request("exports/" + body["id"])["result"]
        self.assertEqual(result["rows"], 2)
        self.assertEqual(result["filters"]["species"], species)
        self.assertTrue(result["csv"].startswith("\ufefflisting_id,asset_id,seller,buyer,price,currency"))
        self.assertNotIn(self.alice["token"], result["csv"])
        self.request("exports", dict(body, id=uuid.uuid4().hex, currency="RP"), expected=400)
        self.request("exports", dict(body, id=uuid.uuid4().hex, min_level=True), expected=400)

    def test_price_outlier_requires_independent_samples_and_is_evidence_only(self):
        third = self.add_player("third_buyer", funded=True)
        buyers = [self.owner, self.bob["identity"]["id"], third]
        for index, price in enumerate((100, 120, 90, 110, 105, 2000)):
            seller = self.add_player("seller_" + str(index))
            asset = self.game("collections/starter", {"request_id": uuid.uuid4().hex, "catalog_version": 1}, expected=201, person=self.players[seller])["asset"]
            listing, _, _ = self.sell(price, asset_id=asset["id"], seller=seller, buyer=buyers[index % 3])
        report = self.request("market-prices?period=today")
        self.assertTrue(report["groups"][0]["sufficient_sample"])
        self.store.scan_admin_risks()
        alerts = self.request("alerts")["alerts"]
        outlier = next(row for row in alerts if row["rule"] == "market_price_deviation")
        self.assertEqual(outlier["evidence"]["listing_id"], listing["listing_id"])
        self.assertEqual(outlier["evidence"]["peer_median"], 105)
        self.assertEqual(self.request("players/" + third)["controls"]["ban_until"], 0)
        self.store.scan_admin_risks()
        again = next(row for row in self.request("alerts")["alerts"] if row["id"] == outlier["id"])
        self.assertEqual(again["version"], outlier["version"])

    def test_new_account_concentration_and_small_peer_sets_are_not_valuations(self):
        buyer = self.bob["identity"]["id"]
        for index in range(5):
            seller = self.add_player("funds_seller_" + str(index))
            asset = self.game("collections/starter", {"request_id": uuid.uuid4().hex, "catalog_version": 1}, expected=201, person=self.players[seller])["asset"]
            self.sell(25000, asset_id=asset["id"], seller=seller, buyer=buyer)
        self.store.scan_admin_risks()
        rules = {row["rule"] for row in self.request("alerts")["alerts"]}
        self.assertIn("new_account_market_concentration", rules)
        self.assertNotIn("market_price_deviation", rules)


if __name__ == "__main__":
    unittest.main()
