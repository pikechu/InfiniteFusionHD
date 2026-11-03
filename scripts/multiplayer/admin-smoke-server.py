"""Loopback-only browser fixture. Always creates a fresh disposable test database."""
import sys
import os
from pathlib import Path
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server/multiplayer"))
from admin_data import create_administrator
from service import Store, PROTOCOL, RULES, make_server
from test_historical_v1_support import HistoricalV1Store as Store
from test_admin import save_fixture


def main():
    directory = ROOT / "temp/admin-smoke" / uuid.uuid4().hex
    directory.mkdir(parents=True)
    now = time.time()
    fixture_clock = {"now": now - 3 * 86400}
    store = Store(directory / "multiplayer.sqlite3", clock=lambda: fixture_clock["now"])
    accounts = []
    with store.connect() as db:
        create_administrator(db, "preview_admin", "PreviewAdminFixture123", "admin", "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP")
        create_administrator(db, "preview_reviewer", "PreviewReviewerFixture123", "operator", "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP")
    for index, (username, nickname) in enumerate((("alice", "小智"), ("bob", "测试玩家"), ("carol", "<script>alert(1)</script>"))):
        status, account = store.request("POST", "/v1/auth/register", {"username": username, "nickname": nickname, "password": "PlayerFixture123", "protocol": PROTOCOL})
        if status != 201:
            raise RuntimeError("Fixture creation failed")
        accounts.append(account)
        with store.connect() as db:
            db.execute("INSERT INTO cloud_saves VALUES(?,?,?,?,?)", (account["identity"]["id"], "file-a", 1, __import__("json").dumps(save_fixture()), store.clock()))
            store.record_player_activity(db, account["identity"]["id"])
            store.shop_money(db, account["identity"]["id"], "MARKET", (index + 1) * 1000, "admin:fixture:" + username)
            store.shop_money(db, account["identity"]["id"], "RP", 2000, "admin:fixture:rp:" + username)
        created = store.request("POST", "/v1/controlled/characters", {"request_id": uuid.uuid4().hex, "name": "受控角色" + str(index + 1), "catalog_hash": store.controlled_catalog()["hash"]}, account["token"])
        if created[0] != 200:
            raise RuntimeError("Controlled fixture creation failed")
        if index == 0:
            character = created[1]["character"]
            catalog = store.controlled_catalog()
            bought = store.request("POST", "/v1/controlled/characters/" + character["id"] + "/buy", {
                "request_id": uuid.uuid4().hex, "expected_revision": character["revision"], "expected_wallet_revision": character["wallet"]["revision"],
                "item": "POTION", "quantity": 1, "catalog_hash": catalog["hash"], "expected_unit_price": catalog["items"][0]["buy_price"]}, account["token"])[1]["character"]
            store.request("POST", "/v1/controlled/characters/" + character["id"] + "/adventure", {
                "request_id": uuid.uuid4().hex, "action": "starter", "species": "BULBASAUR", "rules_hash": store.adventure_catalog()["hash"],
                "expected_revision": bought["revision"], "expected_wallet_revision": bought["wallet"]["revision"]}, account["token"])
    def game(index, path, body, expected=200):
        status, result = store.request("POST", "/v1/" + path, body, accounts[index]["token"])
        if status != expected:
            raise RuntimeError((path, status, result))
        return result
    assets = [game(index, "collections/starter", {"request_id": uuid.uuid4().hex, "catalog_version": 1}, 201)["asset"] for index in range(3)]
    sessions = ["fixture_price_" + uuid.uuid4().hex for _ in range(3)]
    compatibility = {"protocol": PROTOCOL, "game_version": "fixture", "data_hash": "fixture-data", "mods_hash": "none", "rules_version": RULES}
    for index, asset in enumerate(assets):
        fixture_clock["now"] = now - (2 - index) * 86400 - 300
        holder = index
        for offset, price in enumerate(((100, 120), (90, 110), (105, 2000))[index]):
            buyer = (holder + 1) % 3
            for participant in (holder, buyer):
                game(participant, "cloud/open", {"session_id": sessions[participant], "compatibility": compatibility})
            listing = game(holder, "market/listings", {"request_id": uuid.uuid4().hex, "session_id": sessions[holder], "asset_id": asset["id"], "price": price})["receipt"]
            fixture_clock["now"] += 20
            game(buyer, "market/buy/" + listing["listing_id"], {"request_id": uuid.uuid4().hex, "session_id": sessions[buyer], "expected_price": price})
            holder = buyer
    fixture_clock["now"] = now
    with store.connect() as db:
        db.execute("UPDATE cloud_saves SET revision=2,document=?,updated=? WHERE owner=? AND slot='file-a'", (__import__("json").dumps(save_fixture(50000)), now, accounts[0]["identity"]["id"]))
    store.clock = time.time
    if "--original" in sys.argv:
        token = accounts[1]["token"]
        with store.connect() as db:
            character = store.controlled_view(db, store.controlled_character(db, db.execute("SELECT id FROM controlled_characters WHERE owner=?", (accounts[1]["identity"]["id"],)).fetchone()[0]))
        status, catalog = store.request("GET", "/v1/controlled/original-catalog", token=token)
        if status != 200:
            raise RuntimeError("Native fixture catalog failed")
        status, _ = store.request("POST", "/v1/controlled/characters/" + character["id"] + "/original", {
            "request_id": uuid.uuid4().hex, "expected_revision": character["revision"], "expected_wallet_revision": character["wallet"]["revision"],
            "rules_hash": catalog["rules_hash"], "intent": {"kind": "activate"}}, token=token)
        if status != 200:
            raise RuntimeError("Native fixture activation failed")
    server = make_server("127.0.0.1", 18765, store)
    print("ADMIN_SMOKE_URL=http://127.0.0.1:18765/admin/", flush=True)
    print("ADMIN_SMOKE_PID=" + str(os.getpid()), flush=True)
    print("ADMIN_SMOKE_DATABASE=" + str(directory / "multiplayer.sqlite3"), flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        store.close()


if __name__ == "__main__":
    main()
