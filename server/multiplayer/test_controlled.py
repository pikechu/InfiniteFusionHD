import concurrent.futures
import copy
import unittest
import uuid
from unittest.mock import patch

import test_admin as fixtures
from test_historical_v1_support import HistoricalV1Store as Store


class ControlledTests(unittest.TestCase):
    register = fixtures.AdminTests.register
    login = fixtures.AdminTests.login
    request = fixtures.AdminTests.request
    command = fixtures.AdminTests.command
    game = fixtures.AdminTests.game
    def setUp(self):
        with patch.object(fixtures, "Store", Store):
            fixtures.AdminTests.setUp(self)
    tearDown = fixtures.AdminTests.tearDown

    def catalog(self):
        status, result = self.store.request("GET", "/v1/controlled/catalog", token=self.alice["token"])
        self.assertEqual(status, 200, result)
        return result["catalog"]

    def create(self, name="新角色", expected=200, person=None, **overrides):
        body = {"request_id": uuid.uuid4().hex, "name": name, "catalog_hash": self.catalog()["hash"]}
        body.update(overrides)
        return self.game("controlled/characters", body, expected=expected, person=person)

    def state(self, character_id, person=None, expected=200):
        status, result = self.store.request("GET", "/v1/controlled/characters/" + character_id, token=(person or self.alice)["token"])
        self.assertEqual(status, expected, result)
        return result.get("character")

    def change(self, character, action, expected=200, **overrides):
        body = {"request_id": uuid.uuid4().hex, "expected_revision": character["revision"]}
        if action in ("buy", "sell"):
            item = self.catalog()["items"][0]
            body.update(item=item["id"], quantity=1, catalog_hash=self.catalog()["hash"],
                        expected_unit_price=item["buy_price" if action == "buy" else "sell_price"],
                        expected_wallet_revision=character["wallet"]["revision"])
        body.update(overrides)
        return self.game("controlled/characters/" + character["id"] + "/" + action, body, expected=expected)

    def test_new_roles_initial_grant_once_per_account_and_limit(self):
        first = self.create()["character"]
        second = self.create("第二角色")["character"]
        self.assertEqual(first["wallet"]["balance"], 1000)
        self.assertEqual(second["wallet"]["balance"], 0)
        self.create("第三角色")
        self.create("第四角色", expected=409)
        self.assertEqual(self.request("economy?currency=GOLD")["player_total"], 1000)
        report = self.request("overview")
        self.assertEqual((report["controlled_characters"], report["controlled_gold"], report["controlled_gold_issued_today"]), (3, 1000, 1000))
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])
        self.assertEqual(len(self.request("players/" + self.owner)["controlled_characters"]), 3)

    def test_creation_is_durable_after_generic_receipt_cleanup_and_restart(self):
        request_id = uuid.uuid4().hex
        first = self.create(request_id=request_id)
        with self.store.connect() as db:
            db.execute("DELETE FROM operations WHERE owner=?", (self.owner,))
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.assertEqual(self.create(request_id=request_id), first)
        self.assertEqual(self.request("economy?currency=GOLD")["player_total"], 1000)

    def test_local_gold_assets_and_claimed_victory_cannot_be_imported(self):
        self.create(money=999999, expected=400)
        self.create(inventory={"POTION": 999}, expected=400)
        character = self.create()["character"]
        self.change(character, "daily", reward=999999, expected=400)
        self.change(character, "battle_win", expected=404)
        self.assertEqual(self.state(character["id"])["wallet"]["balance"], 1000)

    def test_other_accounts_cannot_view_or_modify_roles(self):
        character = self.create()["character"]
        bob = self.register("bob")
        self.state(character["id"], person=bob, expected=404)
        self.game("controlled/characters/" + character["id"] + "/daily",
                  {"request_id": uuid.uuid4().hex, "expected_revision": character["revision"]}, person=bob, expected=404)

    def test_daily_reward_once_per_account_across_roles_and_next_shanghai_day(self):
        first = self.create()["character"]
        second = self.create("角色二")["character"]
        first_claim = self.change(first, "daily")
        second_claim = self.change(second, "daily")
        self.assertEqual(first_claim["reward_amount"], 100)
        self.assertEqual(second_claim["reward_amount"], 0)
        self.assertEqual(second_claim["character"]["wallet"]["balance"], 0)
        self.clock.advance(86400)
        next_claim = self.change(second_claim["character"], "daily")
        self.assertEqual(next_claim["reward_amount"], 100)

    def test_npc_buy_sell_post_wallet_inventory_and_source_categories_atomically(self):
        character = self.create()["character"]
        bought = self.change(character, "buy")["character"]
        self.assertEqual(bought["wallet"]["balance"], 800)
        self.assertEqual(bought["inventory"][0]["quantity"], 1)
        sold = self.change(bought, "sell")["character"]
        self.assertEqual(sold["wallet"]["balance"], 900)
        self.assertEqual(sold["inventory"], [])
        report = self.request("economy?currency=GOLD")
        self.assertTrue(report["reconciliation"]["ok"])
        self.assertEqual((report["issued"], report["retired"], report["outstanding_supply"]), (1100, 200, 900))
        self.assertEqual({entry["source"] for entry in report["sources"]}, {"new_character_grant", "npc_purchase", "npc_sale"})
        self.assertEqual(report["top_wallets"][0]["account_id"], self.owner)

    def test_price_quantity_ownership_and_balance_checks_prevent_minting(self):
        character = self.create()["character"]
        for overrides, status in (({"quantity": -1}, 400), ({"quantity": True}, 400),
                                  ({"expected_unit_price": 0}, 409), ({"quantity": 999}, 409)):
            self.change(character, "buy", expected=status, **overrides)
        self.change(character, "sell", expected=409)
        self.assertEqual(self.state(character["id"]), character)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM controlled_item_events").fetchone()[0], 0)

    def test_simultaneous_purchases_with_same_revision_only_one_commits(self):
        character = self.create()["character"]
        item = self.catalog()["items"][0]
        def buy(_):
            return self.store.request("POST", "/v1/controlled/characters/" + character["id"] + "/buy",
                {"request_id": uuid.uuid4().hex, "expected_revision": 1, "expected_wallet_revision": 1,
                 "item": item["id"], "quantity": 1, "catalog_hash": self.catalog()["hash"], "expected_unit_price": item["buy_price"]}, self.alice["token"])[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(buy, range(2))), [200, 409])
        self.assertEqual(self.state(character["id"])["wallet"]["balance"], 800)

    def test_account_economic_freeze_and_moderation_apply_to_new_roles(self):
        character = self.create()["character"]
        self.request("commands", self.command("freeze_trade"))
        self.change(character, "daily", expected=403)
        self.assertEqual(self.state(character["id"])["wallet"]["balance"], 1000)
        report = self.request("economy?currency=GOLD")
        self.assertEqual((report["player_total"], report["frozen_total"], report["available_total"]), (1000, 1000, 0))
        self.request("commands", self.command("ban", expected_version=1))
        self.state(character["id"], expected=401)

    def test_admin_gold_adjustment_requires_account_owned_character_and_wallet_revision(self):
        character = self.create()["character"]
        body = self.command("adjust_wallet", currency="GOLD", character_id=character["id"], amount=50, expected_wallet_revision=1)
        self.request("commands", body)
        self.assertEqual(self.state(character["id"])["wallet"]["balance"], 1050)
        self.request("commands", dict(body, id=uuid.uuid4().hex), expected=409)
        bob = self.register("bob")
        self.request("commands", dict(body, id=uuid.uuid4().hex, target=bob["identity"]["id"], expected_wallet_revision=2), expected=404)

    def test_missing_controlled_catalog_does_not_break_basic_player_lookup(self):
        with patch("controlled.Path.read_bytes", side_effect=FileNotFoundError):
            status, result = self.store.request("GET", "/v1/controlled/catalog", token=self.alice["token"])
            self.assertEqual(status, 503, result)
            detail = self.request("players/" + self.owner)
            self.assertTrue(detail["controlled_catalog"]["unavailable"])


if __name__ == "__main__":
    unittest.main()
