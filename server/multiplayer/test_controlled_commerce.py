import json
import sqlite3
import threading
import unittest
import uuid
from unittest.mock import patch

import test_controlled_original as original_fixtures
from service import PROTOCOL


@unittest.skipUnless(original_fixtures.RUBY.is_file(), "Standalone Ruby required")
class OriginalCommerceTests(unittest.TestCase):
    _journey = None
    for _name in ("setUp", "tearDown", "register", "login", "request", "command", "game", "catalog", "create", "state", "original_catalog", "original", "act", "activate", "install_natural_fixture", "finish_opening"):
        locals()[_name] = getattr(original_fixtures.OriginalCharacterTests, _name)

    def market(self, state, action, expected=200, person=None, **fields):
        character = state["character"]
        body = dict(request_id=uuid.uuid4().hex, expected_revision=character["revision"],
                    expected_wallet_revision=character["wallet"]["revision"],
                    rules_hash=state["original"]["rules_hash"], action=action, **fields)
        return self.game(f"controlled/characters/{character['id']}/market", body, expected=expected, person=person), body

    def buyer(self, name="native_buyer"):
        person = self.register(name)
        role = self.create(person=person)["character"]
        state = self.original(role["id"], person)
        body = dict(request_id=uuid.uuid4().hex, expected_revision=role["revision"],
                    expected_wallet_revision=role["wallet"]["revision"], rules_hash=self.original_catalog()["rules_hash"], intent={"kind": "activate"})
        state = self.game(f"controlled/characters/{role['id']}/original", body, person=person)
        previous = self.alice
        try:
            self.alice = person
            return person,self.finish_opening(state)
        finally:
            self.alice = previous

    def test_market_escrow_delivery_idempotency_and_balanced_gold(self):
        seller = self.install_natural_fixture("after_capture")
        monster = seller["original"]["view"]["party"][-1]
        listed, body = self.market(seller, "list", monster_id=monster["id"], price=300)
        listing_id = listed["receipt"]["listing_id"]
        self.assertNotIn(monster["id"], [m["id"] for m in listed["original"]["view"]["monsters"]])
        retry = self.game(f"controlled/characters/{seller['character']['id']}/market", body)
        self.assertEqual(retry, listed)
        person, buyer = self.buyer()
        bought, purchase = self.market(buyer, "buy", person=person, listing_id=listing_id,
                                     expected_price=300, expected_fee=0, expected_listing_version=1)
        self.assertEqual(bought["character"]["wallet"]["balance"], 700)
        delivered = next(m for m in bought["original"]["view"]["monsters"] if m["id"] == monster["id"])
        self.assertEqual(delivered["owner"], monster["owner"])
        self.assertEqual(delivered["obtain_method"], 2)
        self.assertEqual(self.original(seller["character"]["id"])["character"]["wallet"]["balance"], 1300)
        self.assertEqual(self.game(f"controlled/characters/{buyer['character']['id']}/market", purchase, person=person), bought)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM original_sales").fetchone()[0], 1)
            row = db.execute("SELECT character_id,status FROM original_creatures WHERE id=?", (monster["id"],)).fetchone()
            self.assertEqual(tuple(row), (buyer["character"]["id"], "active"))
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])
        prices = self.request("market-prices?currency=GOLD")
        self.assertEqual(prices["summary"]["volume"], 300)
        self.assertEqual(prices["summary"]["trades"], 1)
        self.assertTrue(prices["integrity"]["ok"])
        self.assertEqual(self.request("market-prices?currency=MARKET")["summary"]["trades"], 0)
        status, market = self.store.request("GET", f"/v1/controlled/characters/{buyer['character']['id']}/market?page=0&species=PIDGEY", token=person["token"])
        self.assertEqual(status, 200, market)
        self.assertEqual(market["currency"], "GOLD")
        export = self.request("exports", {"id": uuid.uuid4().hex, "kind": "market_sales", "currency": "GOLD"}, expected=202)
        self.store.process_admin_export()
        download = self.request("exports/"+export["id"])
        self.assertIn("GOLD", json.dumps(download))
        self.store.scan_admin_risks()
        self.assertNotIn("np1_", json.dumps(bought))

    def test_concurrent_buyers_deliver_once_and_reconcile_nonzero_fee(self):
        seller = self.install_natural_fixture("after_capture")
        monster = seller["original"]["view"]["party"][-1]
        with self.store.connect() as db:
            db.execute("UPDATE admin_metadata SET value='500' WHERE key='original_market_fee_bps'")
        listed, _ = self.market(seller,"list",monster_id=monster["id"],price=300)
        buyers = [self.buyer("native_race_a"), self.buyer("native_race_b")]
        barrier, results = threading.Barrier(2), []
        native = self.store.original_commerce_native
        def synchronized(operation, *args, **kwargs):
            if operation == "asset_exchange":
                barrier.wait(timeout=15)
            return native(operation,*args,**kwargs)
        def purchase(person,state):
            role = state["character"]
            body = dict(request_id=uuid.uuid4().hex,expected_revision=role["revision"],expected_wallet_revision=role["wallet"]["revision"],
                        rules_hash=state["original"]["rules_hash"],action="buy",listing_id=listed["receipt"]["listing_id"],expected_price=300,expected_fee=15,expected_listing_version=1)
            results.append(self.store.request("POST",f"/v1/controlled/characters/{role['id']}/market",body,person["token"]))
        with patch.object(self.store,"original_commerce_native",side_effect=synchronized):
            workers = [threading.Thread(target=purchase,args=buyer) for buyer in buyers]
            for worker in workers: worker.start()
            for worker in workers: worker.join(30)
            self.assertTrue(all(not worker.is_alive() for worker in workers))
        self.assertEqual(sorted(status for status,_ in results),[200,409],results)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM original_sales").fetchone()[0],1)
            self.assertEqual(tuple(db.execute("SELECT price,fee FROM original_sales").fetchone()),(300,15))
            self.assertEqual(self.store.shop_wallet(db,seller["character"]["id"],"GOLD")["balance"],1285)
            self.assertEqual(sum(self.store.shop_wallet(db,state["character"]["id"],"GOLD")["balance"] for _,state in buyers),1700)
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])
        self.assertTrue(self.request("market-prices?currency=GOLD")["integrity"]["ok"])

    def test_last_able_price_versions_and_expiry_are_enforced(self):
        seller = self.install_natural_fixture("after_capture")
        monster = seller["original"]["view"]["party"][-1]
        listed, _ = self.market(seller, "list", monster_id=monster["id"], price=300)
        listing_id = listed["receipt"]["listing_id"]
        self.market(listed, "list", monster_id=listed["original"]["view"]["party"][0]["id"], price=10, expected=409)
        self.market(listed, "claim", listing_id=listing_id, expected_listing_version=1, expected=409)
        person, buyer = self.buyer()
        self.market(buyer, "buy", person=person, listing_id=listing_id, expected_price=299, expected_fee=0, expected_listing_version=1, expected=409)
        self.clock.advance(7*86400+1)
        person = self.register("expired_buyer")
        self.market(buyer, "buy", listing_id=listing_id, expected_price=300, expected_fee=0, expected_listing_version=1, expected=401)
        self.alice = self.game("auth/login", {"username": "alice", "password": "PlayerPassword123", "protocol": PROTOCOL})
        returned, _ = self.market(listed, "claim", listing_id=listing_id, expected_listing_version=1)
        restored = next(m for m in returned["original"]["view"]["monsters"] if m["id"] == monster["id"])
        self.assertEqual(restored["obtain_method"], monster["obtain_method"])

    def test_transfer_failure_rolls_back_money_escrow_and_ownership(self):
        seller = self.install_natural_fixture("after_capture")
        listed, _ = self.market(seller, "list", monster_id=seller["original"]["view"]["party"][-1]["id"], price=300)
        person, buyer = self.buyer()
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER fail_delivery BEFORE INSERT ON original_sales BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.market(buyer, "buy", person=person, listing_id=listed["receipt"]["listing_id"], expected_price=300, expected_fee=0, expected_listing_version=1)
        self.assertEqual(self.original(buyer["character"]["id"], person)["character"]["wallet"]["balance"], 1000)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT status FROM original_market").fetchone()[0], "active")
            self.assertEqual(db.execute("SELECT count(*) FROM original_ownership").fetchone()[0], 0)

    def trade(self, state, action, expected=200, person=None, **fields):
        character = state["character"]
        body = dict(request_id=uuid.uuid4().hex, expected_revision=character["revision"],
                    expected_wallet_revision=character["wallet"]["revision"], rules_hash=state["original"]["rules_hash"], action=action, **fields)
        return self.game(f"controlled/characters/{character['id']}/trades", body, expected=expected, person=person), body

    def test_two_party_lock_review_confirm_delivers_original_assets_and_gold(self):
        seller = self.install_natural_fixture("after_capture")
        person, buyer = self.buyer()
        monster = seller["original"]["view"]["party"][-1]
        invited, _ = self.trade(seller, "invite", target=buyer["character"]["id"], monsters=[monster["id"]], items=[], gold=0)
        offer = invited["offer"]
        locked_state = self.original(seller["character"]["id"])
        self.act(locked_state, {"kind": "wait"}, expected=409)
        edited, _ = self.trade(buyer, "edit", person=person, offer_id=offer["id"], expected_offer_version=1, monsters=[], items=[], gold=200)
        offer = edited["offer"]
        locked, _ = self.trade(seller, "lock", offer_id=offer["id"], expected_offer_version=2, terms_hash=offer["terms_hash"])
        locked, _ = self.trade(buyer, "lock", person=person, offer_id=offer["id"], expected_offer_version=2, terms_hash=offer["terms_hash"])
        self.trade(seller, "confirm", offer_id=offer["id"], expected_offer_version=2, terms_hash=offer["terms_hash"], expected=409)
        self.clock.advance(3)
        first, _ = self.trade(seller, "confirm", offer_id=offer["id"], expected_offer_version=2, terms_hash=offer["terms_hash"])
        self.assertEqual(first["offer"]["status"], "open")
        final, body = self.trade(buyer, "confirm", person=person, offer_id=offer["id"], expected_offer_version=2, terms_hash=offer["terms_hash"])
        self.assertEqual(final["offer"]["status"], "completed")
        self.assertEqual(final["character"]["wallet"]["balance"], 800)
        self.assertEqual(final["original"]["view"]["party"][0]["id"], monster["id"])
        self.assertEqual(self.original(seller["character"]["id"])["character"]["wallet"]["balance"], 1200)
        self.assertEqual(self.game(f"controlled/characters/{buyer['character']['id']}/trades", body, person=person), final)
        self.assertTrue(self.request("economy?currency=GOLD")["reconciliation"]["ok"])

    def test_offer_edit_clears_confirmations_cancel_and_timeout_release_locks(self):
        seller = self.install_natural_fixture("after_capture")
        person, buyer = self.buyer()
        invited, _ = self.trade(seller, "invite", target=buyer["character"]["id"], monsters=[], items=[], gold=10)
        offer = invited["offer"]
        self.trade(seller, "lock", offer_id=offer["id"], expected_offer_version=1, terms_hash=offer["terms_hash"])
        edited, _ = self.trade(buyer, "edit", person=person, offer_id=offer["id"], expected_offer_version=1, monsters=[], items=[], gold=20)
        self.assertEqual(edited["offer"]["locked"], [])
        self.assertEqual(edited["offer"]["confirmed"], [])
        self.trade(seller, "confirm", offer_id=offer["id"], expected_offer_version=1, terms_hash=offer["terms_hash"], expected=409)
        self.trade(buyer, "cancel", person=person, offer_id=offer["id"], expected_offer_version=2)
        after, _ = self.act(seller, {"kind": "wait"})
        # Another role's unsolicited invitation does not stop the recipient playing.
        invited, _ = self.trade(after, "invite", target=buyer["character"]["id"], monsters=[], items=[], gold=10)
        self.clock.advance(601)
        self.act(after, {"kind": "wait"})

    def test_operator_withdrawal_preserves_escrow_until_one_claim(self):
        seller = self.install_natural_fixture("after_capture")
        monster = seller["original"]["view"]["party"][-1]
        listed, _ = self.market(seller,"list",monster_id=monster["id"],price=300)
        listing_id = listed["receipt"]["listing_id"]
        order = self.request("commerce-listing?listing_id="+listing_id)
        self.assertEqual(order["listing"]["currency"],"GOLD")
        body = {"id":uuid.uuid4().hex,"action":"cancel_listing","reason":"Native escrow fixture review","reference":listing_id}
        cancelled = self.request("commands",body)
        self.assertEqual(self.request("commands",body),cancelled)
        person,buyer = self.buyer()
        self.market(buyer,"buy",person=person,listing_id=listing_id,expected_price=300,expected_fee=0,expected_listing_version=1,expected=409)
        claimed,claim = self.market(listed,"claim",listing_id=listing_id,expected_listing_version=2)
        self.assertEqual(self.game(f"controlled/characters/{seller['character']['id']}/market",claim),claimed)
        self.assertEqual(sum(entry["id"]==monster["id"] for entry in claimed["original"]["view"]["monsters"]),1)
        records = self.request("transactions?kind=original_market")["transactions"]
        self.assertEqual(records[0]["detail"]["status"],"returned")
        self.assertNotIn("np1_",json.dumps(records))

    def test_maintenance_cancels_unsubmitted_offers_and_releases_both_roles(self):
        seller = self.install_natural_fixture("after_capture")
        person,buyer = self.buyer()
        invited,body = self.trade(seller,"invite",target=buyer["character"]["id"],monsters=[],items=[],gold=20)
        offer = invited["offer"]
        self.trade(buyer,"edit",person=person,offer_id=offer["id"],expected_offer_version=1,monsters=[],items=[],gold=0)
        maintenance = self.request("commands",self.command("begin_maintenance",force=True))
        self.assertEqual(maintenance["detail"]["cancelled_original_offers"],[offer["id"]])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM original_trade_locks").fetchone()[0],0)
        records = self.request("transactions?kind=original_trade")["transactions"]
        self.assertEqual(records[0]["detail"]["status"],"cancelled")
        self.assertNotIn("state",records[0]["detail"])
