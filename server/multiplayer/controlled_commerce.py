"""GOLD commerce for original, server-owned Pokemon; no client asset payloads."""
from contextlib import closing
import copy
import json
import secrets
from urllib.parse import parse_qs, urlsplit

try:
    from .admin_data import readonly
    from .native_rules import NativeRulesError
except ImportError:
    from admin_data import readonly
    from native_rules import NativeRulesError


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


class ControlledCommerceFeatures:
    def init_original_commerce(self, db):
        db.executescript("""
          CREATE TABLE IF NOT EXISTS original_market(
            id TEXT PRIMARY KEY,seller TEXT NOT NULL,monster_id TEXT NOT NULL,price INTEGER NOT NULL,
            fee INTEGER NOT NULL,status TEXT NOT NULL,version INTEGER NOT NULL,rules_hash TEXT NOT NULL,
            asset TEXT NOT NULL,snapshot TEXT NOT NULL,created REAL NOT NULL,expires REAL NOT NULL,buyer TEXT);
          CREATE INDEX IF NOT EXISTS original_market_browse ON original_market(status,expires,price,id);
          CREATE INDEX IF NOT EXISTS original_market_owner ON original_market(seller,created,id);
          CREATE TABLE IF NOT EXISTS original_sales(
            listing_id TEXT PRIMARY KEY,monster_id TEXT NOT NULL,seller TEXT NOT NULL,buyer TEXT NOT NULL,
            price INTEGER NOT NULL,fee INTEGER NOT NULL,snapshot TEXT NOT NULL,created REAL NOT NULL,sold REAL NOT NULL,
            buyer_ledger INTEGER NOT NULL UNIQUE,seller_ledger INTEGER NOT NULL UNIQUE,ownership_id INTEGER NOT NULL UNIQUE);
          CREATE TABLE IF NOT EXISTS original_ownership(
            id INTEGER PRIMARY KEY AUTOINCREMENT,monster_id TEXT NOT NULL,source TEXT NOT NULL,target TEXT NOT NULL,
            kind TEXT NOT NULL,reference TEXT NOT NULL,asset TEXT NOT NULL,snapshot TEXT NOT NULL,created REAL NOT NULL,
            UNIQUE(monster_id,kind,reference));
          CREATE INDEX IF NOT EXISTS original_ownership_role ON original_ownership(source,target,id);
          CREATE INDEX IF NOT EXISTS original_ownership_asset ON original_ownership(monster_id,id);
          CREATE TABLE IF NOT EXISTS original_offers(
            id TEXT PRIMARY KEY,sender TEXT NOT NULL,receiver TEXT NOT NULL,status TEXT NOT NULL,version INTEGER NOT NULL,
            document TEXT NOT NULL,created REAL NOT NULL,expires REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS original_trade_locks(character_id TEXT PRIMARY KEY,offer_id TEXT NOT NULL,created REAL NOT NULL);
          CREATE INDEX IF NOT EXISTS original_sales_period ON original_sales(sold,listing_id);
          CREATE INDEX IF NOT EXISTS original_sales_asset ON original_sales(monster_id,sold);
          CREATE VIEW IF NOT EXISTS original_paid_sales AS
            SELECT listing_id,monster_id AS asset_id,seller,buyer,price,'GOLD' AS currency,sold AS sold_at,created AS listed_at,
              json_extract(snapshot,'$.species') AS species,json_extract(snapshot,'$.level') AS level,
              json_extract(snapshot,'$.shiny') AS shiny,
              (json_extract(snapshot,'$.iv.HP')+json_extract(snapshot,'$.iv.ATTACK')+json_extract(snapshot,'$.iv.DEFENSE')+
               json_extract(snapshot,'$.iv.SPECIAL_ATTACK')+json_extract(snapshot,'$.iv.SPECIAL_DEFENSE')+json_extract(snapshot,'$.iv.SPEED')) AS iv_total,
              buyer_ledger AS buyer_ledger_id,seller_ledger AS seller_ledger_id FROM original_sales;
        """)
        for table in ("original_sales", "original_ownership"):
            for action in ("UPDATE", "DELETE"):
                db.execute(f"CREATE TRIGGER IF NOT EXISTS {table}_immutable_{action.lower()} BEFORE {action} ON {table} BEGIN SELECT RAISE(ABORT,'Original ownership journal is append-only'); END")

    def original_trade_guard(self, db, character_id, reference=None):
        row = db.execute("SELECT l.offer_id FROM original_trade_locks l JOIN original_offers o ON o.id=l.offer_id WHERE l.character_id=? AND o.status='open' AND o.expires>?", (character_id, self.clock())).fetchone()
        require(row is None or row[0] == reference, "original_trade_locked", "This character has an outstanding trade offer", 409)

    def original_commerce_role(self, db, identifier, owner=None, body=None, *, pending=False, offer=None):
        character = self.controlled_character(db, identifier, owner)
        self.check_player_control(db, character["owner"], trade=True)
        row = self.original_row(db, identifier)
        require(row is not None, "original_not_active", "Migrate or activate this original character first", 409)
        require(pending or not row["pending"], "original_interaction_active", "Finish the current interaction first", 409)
        self.original_trade_guard(db, identifier, offer)
        wallet = self.shop_wallet(db, identifier, "GOLD")
        if body:
            require(character["revision"] == body["expected_revision"], "controlled_revision_conflict", "Character changed; refresh", 409)
            require(wallet["revision"] == body["expected_wallet_revision"], "wallet_version_conflict", "Wallet changed; refresh", 409)
            require(row["rules_hash"] == body["rules_hash"], "original_rules_changed", "Original rules changed", 409)
        return character, row, wallet

    def original_commerce_native(self, operation, rules_hash, **arguments):
        try:
            return self.original_engine().call(operation, rules_hash=rules_hash, **arguments)["result"]
        except NativeRulesError as error:
            code = str(error).split(":", 1)[0]
            if code == "native_rules_busy":
                raise APIError(429, "original_rules_busy", "Original rules are busy; retry shortly") from error
            if code in {"native_commerce_busy", "native_trade_last_able", "native_trade_storage_full", "native_borrowed_asset", "native_trade_asset_unavailable", "native_asset_duplicate", "native_inventory_quantity", "native_inventory_capacity", "native_restore_item_conflict"}:
                raise APIError(409, code, "The character or asset is not available for this trade") from error
            raise APIError(503, "original_rules_unavailable", "Original rules could not finish this trade; retry the same request") from error

    def original_commerce_write(self, db, character, row, result, reference, kind, detail, pending=None):
        projection = self.original_project(db, character, {"request_id": reference, "event_reference": reference, "listed_ids": detail.get("listed_ids", [])}, result)
        state = result.get("state") or row["state"]
        db.execute("UPDATE original_states SET state=?,view=?,pending=?,updated=? WHERE character_id=?",
                   (state, dumps(result["view"]), dumps(pending) if pending else None, self.clock(), character["id"]))
        db.execute("UPDATE controlled_characters SET revision=revision+1 WHERE id=?", (character["id"],))
        db.execute("INSERT INTO original_events(character_id,request_id,kind,document,created) VALUES(?,?,?,?,?)",
                   (character["id"], reference, kind, dumps(dict(detail, projection=projection, before=digest(row["state"]), after=digest(state))), self.clock()))
        updated = self.controlled_character(db, character["id"])
        if not pending:
            self.original_snapshot(db, updated, row["rules_hash"], state, result["view"])

    def original_market_public(self, db, row):
        seller = db.execute("SELECT c.name AS character_name,i.id AS account_id,i.nickname,i.friend_code FROM controlled_characters c JOIN identities i ON i.id=c.owner WHERE c.id=?", (row["seller"],)).fetchone()
        return {key: row[key] for key in ("id", "seller", "monster_id", "price", "fee", "status", "version", "created", "expires", "buyer")} | {"monster": json.loads(row["snapshot"]), "seller_identity": dict(seller)}

    def original_market_request(self, method, path, body, token):
        parsed = urlsplit(path)
        require(len(path) <= 2048 and not parsed.fragment, "invalid_query", "Invalid market query")
        try:
            values = parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True, max_num_fields=12)
        except ValueError:
            raise APIError(400, "invalid_query", "Invalid market query")
        require(all(len(value) == 1 for value in values.values()), "invalid_query", "Duplicate market query parameter")
        path, query = parsed.path, {key: value[0] for key, value in values.items()}
        parts = path.strip("/").split("/")
        require(len(parts) == 5 and parts[2] == "characters" and parts[4] == "market", "not_found", "Unknown original market route", 404)
        with closing(readonly(self.database)) as db:
            db.execute("BEGIN")
            identity = self.original_identity(db, token, mutation=method == "POST")
            character = self.controlled_character(db, parts[3], identity["id"])
            if method == "GET":
                require(set(query) <= {"page", "mine_page", "species", "min_level", "max_level", "shiny", "min_iv", "max_price"}, "invalid_query", "Unexpected market filter")
                def number(key, default, low, high):
                    value = query.get(key, str(default))
                    require(type(value) is str and value.isascii() and value.isdigit(), "invalid_filter", "Integer market filters required")
                    return integer(int(value), low, high, key)
                page, mine_page = number("page", 0, 0, 100000), number("mine_page", 0, 0, 100000)
                species = string(query.get("species", ""), 0, 64, "species", r"[A-Z0-9_]*")
                low, high = number("min_level", 1, 1, 100), number("max_level", 100, 1, 100)
                shiny = query.get("shiny", "any")
                require(low <= high and shiny in ("any", "0", "1"), "invalid_filter", "Invalid level or shiny filter")
                minimum_iv, maximum_price = number("min_iv", 0, 0, 186), number("max_price", 1_000_000_000, 1, 1_000_000_000)
                iv_sql = "+".join("json_extract(snapshot,'$.iv."+key+"')" for key in ("HP", "ATTACK", "DEFENSE", "SPECIAL_ATTACK", "SPECIAL_DEFENSE", "SPEED"))
                listings = db.execute("SELECT * FROM original_market WHERE status='active' AND expires>? AND (?='' OR json_extract(snapshot,'$.species')=?) AND json_extract(snapshot,'$.level') BETWEEN ? AND ? AND (?='any' OR json_extract(snapshot,'$.shiny')=?) AND ("+iv_sql+")>=? AND price<=? ORDER BY price,id LIMIT 51 OFFSET ?", (self.clock(), species, species, low, high, shiny, -1 if shiny == "any" else int(shiny), minimum_iv, maximum_price, page*50)).fetchall()
                mine = db.execute("SELECT * FROM original_market WHERE seller=? ORDER BY created DESC,id DESC LIMIT 51 OFFSET ?", (character["id"], mine_page*50)).fetchall()
                return 200, {"ok": True, "currency": "GOLD", "listings": [self.original_market_public(db, row) for row in listings[:50]], "mine": [self.original_market_public(db, row) for row in mine[:50]], "page": page, "has_more": len(listings)>50, "mine_page": mine_page, "mine_has_more": len(mine)>50, "as_of": self.clock()}
            require(method == "POST", "invalid_method", "Use GET or POST", 405)
            require(not query, "invalid_query", "Mutations do not accept query parameters")
            common = {"request_id", "expected_revision", "expected_wallet_revision", "rules_hash", "action"}
            action = body.get("action")
            extras = {"list": {"monster_id", "price"}, "buy": {"listing_id", "expected_price", "expected_fee", "expected_listing_version"}, "cancel": {"listing_id", "expected_listing_version"}, "claim": {"listing_id", "expected_listing_version"}}
            require(action in extras, "invalid_market_action", "Unknown original market action")
            obj(body, common | extras[action], common | extras[action])
            string(body["request_id"], 8, 100, "request_id", r"[A-Za-z0-9_-]+")
            integer(body["expected_revision"], 1, 2**53-1, "expected_revision")
            integer(body["expected_wallet_revision"], 0, 2**53-1, "expected_wallet_revision")
            string(body["rules_hash"], 64, 64, "rules_hash", r"[a-f0-9]{64}")
            fingerprint = digest(dumps({"path": path, "body": body}))
            previous = db.execute("SELECT * FROM original_receipts WHERE owner=? AND request_id=?", (identity["id"], body["request_id"])).fetchone()
            if previous:
                require(previous["fingerprint"] == fingerprint, "request_id_conflict", "Request ID already used", 409)
                return 200, self.original_reply(db, character, json.loads(previous["response"]))
            character, row, wallet = self.original_commerce_role(db, character["id"], identity["id"], body)
            require(action in ("cancel", "claim") or not self.shop_control(db, "market_paused", False), "market_paused", "Market operations are paused", 503)
            listing = None
            exchange_role = {"state": row["state"], "wallet_balance": wallet["balance"], "outgoing": [], "incoming": []}
            if action == "list":
                require(db.execute("SELECT count(*) FROM original_market m JOIN controlled_characters c ON c.id=m.seller WHERE c.owner=? AND m.status='active' AND m.expires>?", (identity["id"], self.clock())).fetchone()[0] < 10, "listing_limit", "At most ten active original listings per account", 409)
                identifier = string(body["monster_id"], 35, 35, "monster_id", r"cm_[a-f0-9]{32}")
                price = integer(body["price"], 1, 1_000_000_000, "price")
                asset = db.execute("SELECT * FROM original_creatures WHERE id=? AND character_id=? AND status='active'", (identifier, character["id"])).fetchone()
                require(asset is not None, "original_asset_unavailable", "Choose an owned available Pokemon", 409)
                exchange_role["outgoing"] = [identifier]
                rate = int(db.execute("SELECT value FROM admin_metadata WHERE key='original_market_fee_bps'").fetchone()[0])
                require(0 <= rate <= 10_000, "original_market_policy", "Invalid original market fee policy", 503)
                fee = min(price, (price * rate + 9999) // 10000)
                require(price - fee > 0, "original_market_price", "Price must exceed the fee")
            else:
                string(body["listing_id"], 36, 36, "listing_id", r"cml_[a-f0-9]{32}")
                integer(body["expected_listing_version"], 1, 2**53-1, "expected_listing_version")
                found = db.execute("SELECT * FROM original_market WHERE id=?", (body["listing_id"],)).fetchone()
                require(found is not None, "listing_unavailable", "Listing does not exist", 404)
                listing = dict(found)
                require(listing["version"] == body["expected_listing_version"], "listing_version_conflict", "Listing changed", 409)
                require(listing["rules_hash"] == row["rules_hash"], "original_rules_changed", "Listing uses another original rule version", 409)
                if action == "buy":
                    require(listing["status"] == "active" and listing["expires"] > self.clock(), "listing_unavailable", "Listing was sold, cancelled or expired", 409)
                    require(listing["seller"] != character["id"], "own_listing", "Cannot buy your own listing", 409)
                    require(type(body["expected_price"]) is int and body["expected_price"] == listing["price"] and type(body["expected_fee"]) is int and body["expected_fee"] == listing["fee"], "price_changed", "Review the listing price and fee", 409)
                    seller, _, _ = self.original_commerce_role(db, listing["seller"], pending=True)
                    require(seller["owner"] != identity["id"], "own_listing", "Cannot buy your account's listing", 409)
                    require(wallet["balance"] >= listing["price"], "insufficient_balance", "Not enough GOLD", 409)
                    exchange_role["wallet_balance"] -= listing["price"]
                else:
                    require(listing["seller"] == character["id"], "not_owner", "Only the seller may reclaim a listing", 403)
                    require(listing["status"] == "active" or action == "claim" and listing["status"] == "withdrawn", "listing_unavailable", "Listing is no longer reclaimable", 409)
                    require(action != "claim" or listing["expires"] <= self.clock() or listing["status"] == "withdrawn", "listing_not_expired", "The listing has not expired", 409)
                exchange_role["incoming"] = [{"id": listing["monster_id"], "blob": listing["asset"], "traded": action == "buy"}]
        result = self.original_commerce_native("asset_exchange", row["rules_hash"], exchange={"time": self.clock(), "roles": {character["id"]: exchange_role}})
        role_result = result["roles"][character["id"]]
        evolution = None
        if action == "buy":
            evolution_document = {"initial": role_result["state"], "time": self.clock(), "seed": secrets.randbits(256), "wallet_balance": exchange_role["wallet_balance"], "inputs": [], "incoming": [{"id": listing["monster_id"]}]}
            evolution = self.original_commerce_native("trade_finish", row["rules_hash"], trade=evolution_document)
            if evolution.get("state"):
                role_result = evolution
        with self.lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            identity = self.original_identity(db, token, mutation=True)
            character = self.controlled_character(db, parts[3], identity["id"])
            previous = db.execute("SELECT * FROM original_receipts WHERE owner=? AND request_id=?", (identity["id"], body["request_id"])).fetchone()
            if previous:
                require(previous["fingerprint"] == fingerprint, "request_id_conflict", "Request ID already used", 409)
                return 200, self.original_reply(db, character, json.loads(previous["response"]))
            character, current, wallet = self.original_commerce_role(db, character["id"], identity["id"], body)
            require(action in ("cancel", "claim") or not self.shop_control(db, "market_paused", False), "market_paused", "Market operations are paused", 503)
            reference = "original_market:" + body["request_id"]
            if action == "list":
                require(db.execute("SELECT count(*) FROM original_market m JOIN controlled_characters c ON c.id=m.seller WHERE c.owner=? AND m.status='active' AND m.expires>?", (identity["id"], self.clock())).fetchone()[0] < 10, "listing_limit", "At most ten active original listings per account", 409)
                listing_id = "cml_" + secrets.token_hex(16)
                asset = result["assets"][identifier]
                db.execute("INSERT INTO original_market VALUES(?,?,?,?,?,'active',1,?,?,?,?,?,NULL)", (listing_id, character["id"], identifier, price, fee, row["rules_hash"], asset["blob"], dumps(asset["view"]), self.clock(), self.clock()+7*86400))
            else:
                found = db.execute("SELECT * FROM original_market WHERE id=?", (listing["id"],)).fetchone()
                require(found is not None and found["status"] == listing["status"] and found["version"] == listing["version"], "listing_unavailable", "Listing changed while preparing the transfer", 409)
                listing_id = listing["id"]
                if action == "buy":
                    require(found["expires"] > self.clock(), "listing_unavailable", "Listing expired", 409)
                    seller, seller_row, _ = self.original_commerce_role(db, listing["seller"], pending=True)
                    net = listing["price"] - listing["fee"]
                    self.shop_money(db, character["id"], "GOLD", -net, "managed:original_market_buy:" + listing_id)
                    if listing["fee"]:
                        self.shop_money(db, character["id"], "GOLD", -listing["fee"], "managed:original_market_tax:" + listing_id)
                    self.shop_money(db, seller["id"], "GOLD", net, "managed:original_market_sell:" + listing_id)
                    if seller_row["pending"]:
                        pending_seller = json.loads(seller_row["pending"])
                        pending_seller["wallet_revision"] = self.shop_wallet(db, seller["id"], "GOLD")["revision"]
                        db.execute("UPDATE original_states SET pending=? WHERE character_id=?", (dumps(pending_seller), seller["id"]))
                    changed = db.execute("UPDATE original_creatures SET character_id=?,status='in_transit',revision=revision+1 WHERE id=? AND character_id=? AND status='listed'", (character["id"], listing["monster_id"], listing["seller"]))
                    require(changed.rowcount == 1, "original_asset_unavailable", "Escrow ownership changed", 409)
                    ownership_asset = evolution["assets"][listing["monster_id"]]
                    ownership_view = dict(ownership_asset["view"], trade_before=json.loads(listing["snapshot"]))
                    ownership = db.execute("INSERT INTO original_ownership(monster_id,source,target,kind,reference,asset,snapshot,created) VALUES(?,?,?,'market',?,?,?,?)", (listing["monster_id"], listing["seller"], character["id"], listing_id, ownership_asset["blob"], dumps(ownership_view), self.clock())).lastrowid
                    buyer_ledger = db.execute("SELECT id FROM shop_ledger WHERE event=? AND owner=? AND currency='GOLD'", ("managed:original_market_buy:" + listing_id, character["id"])).fetchone()[0]
                    seller_ledger = db.execute("SELECT id FROM shop_ledger WHERE event=? AND owner=? AND currency='GOLD'", ("managed:original_market_sell:" + listing_id, seller["id"])).fetchone()[0]
                    db.execute("INSERT INTO original_sales VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (listing_id, listing["monster_id"], listing["seller"], character["id"], listing["price"], listing["fee"], listing["snapshot"], listing["created"], self.clock(), buyer_ledger, seller_ledger, ownership))
                    status = "sold"
                else:
                    status = "cancelled" if action == "cancel" else "returned"
                db.execute("UPDATE original_market SET status=?,version=version+1,buyer=? WHERE id=?", (status, character["id"] if action == "buy" else None, listing_id))
            pending = None
            if evolution and evolution.get("prompt"):
                role_result = dict(evolution, state=result["roles"][character["id"]]["state"])
                pending = {"operation": "trade_finish", "document": evolution_document, "prompt": evolution["prompt"], "applied_money": 0,
                           "event_count": len(evolution["events"]), "wallet_revision": self.shop_wallet(db, character["id"], "GOLD")["revision"]}
            self.original_commerce_write(db, character, current, role_result, reference, "market_"+action, {"listing_id": listing_id, "listed_ids": [identifier] if action == "list" else []}, pending)
            receipt = {"receipt": {"kind": "market_"+action, "listing_id": listing_id}, "events": evolution.get("events", []) if evolution else []}
            db.execute("INSERT INTO original_receipts VALUES(?,?,?,?,?)", (identity["id"], body["request_id"], fingerprint, dumps(receipt), self.clock()))
            self.record_player_activity(db, identity["id"])
            return 200, self.original_reply(db, self.controlled_character(db, character["id"]), receipt)

    def original_offer_public(self, row):
        document = json.loads(row["document"])
        return {key: row[key] for key in ("id", "sender", "receiver", "version", "created", "expires")} | {
            "status": "expired" if row["status"] == "open" and row["expires"] <= self.clock() else row["status"],
            **{key: document.get(key) for key in ("terms", "terms_hash", "participants", "locked", "confirmed", "ready_at", "result")}}

    def original_offer_terms(self, db, character, body):
        monsters = body["monsters"]
        require(type(monsters) is list and len(monsters) <= 6 and all(type(value) is str for value in monsters) and len(set(monsters)) == len(monsters), "trade_assets", "Choose up to six different Pokemon")
        for identifier in monsters:
            string(identifier, 35, 35, "monster_id", r"cm_[a-f0-9]{32}")
            require(db.execute("SELECT 1 FROM original_creatures WHERE id=? AND character_id=? AND status='active'", (identifier, character["id"])).fetchone() is not None, "original_asset_unavailable", "Choose an owned available Pokemon", 409)
        items = body["items"]
        require(type(items) is list and len(items) <= 8, "trade_items", "Choose up to eight item types")
        seen = set()
        catalog = self.original_item_catalog(db, self.original_row(db, character["id"]))
        for entry in items:
            obj(entry, {"item", "quantity"}, {"item", "quantity"})
            item = string(entry["item"], 1, 64, "item", r"[A-Z0-9_]+")
            require(any(value["id"] == item and not value["important"] for value in catalog), "trade_item_restricted", "Important story items cannot be traded", 409)
            integer(entry["quantity"], 1, 999, "quantity")
            require(item not in seen, "trade_items", "Duplicate item type")
            seen.add(item)
            stock = db.execute("SELECT quantity FROM controlled_inventory WHERE character_id=? AND item=?", (character["id"], item)).fetchone()
            require(stock is not None and stock[0] >= entry["quantity"], "original_inventory_limit", "Not enough items", 409)
        gold = integer(body["gold"], 0, 1_000_000_000, "gold")
        require(self.shop_wallet(db, character["id"], "GOLD")["balance"] >= gold, "insufficient_balance", "Not enough GOLD", 409)
        public = [json.loads(db.execute("SELECT document FROM original_creatures WHERE id=?", (identifier,)).fetchone()[0]) for identifier in sorted(monsters)]
        return {"monsters": sorted(monsters), "items": sorted(items, key=lambda item: item["item"]), "gold": gold, "details": public}

    def original_offer_receipt(self, db, identity, body, fingerprint, offer, character):
        receipt = {"receipt": {"kind": "trade_" + body["action"], "offer_id": offer["id"]}, "offer": self.original_offer_public(offer)}
        db.execute("INSERT INTO original_receipts VALUES(?,?,?,?,?)", (identity["id"], body["request_id"], fingerprint, dumps(receipt), self.clock()))
        return 200, self.original_reply(db, character, receipt)

    def original_offer_replay(self, db, character, saved):
        response = json.loads(saved["response"])
        current = db.execute("SELECT * FROM original_offers WHERE id=?", (response["receipt"]["offer_id"],)).fetchone()
        response["offer"] = self.original_offer_public(current)
        return 200, self.original_reply(db, character, response)

    def original_trade_request(self, method, path, body, token):
        parts = path.strip("/").split("/")
        require(len(parts) == 5 and parts[2] == "characters" and parts[4] == "trades", "not_found", "Unknown original trade route", 404)
        with self.lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            identity = self.original_identity(db, token, mutation=method == "POST")
            character = self.controlled_character(db, parts[3], identity["id"])
            if method == "GET":
                offers = db.execute("SELECT * FROM original_offers WHERE sender=? OR receiver=? ORDER BY created DESC,id DESC LIMIT 50", (character["id"], character["id"])).fetchall()
                return 200, {"ok": True, "offers": [self.original_offer_public(row) for row in offers], "as_of": self.clock()}
            require(method == "POST", "invalid_method", "Use GET or POST", 405)
            extras = {"invite": {"target", "monsters", "items", "gold"}, "edit": {"offer_id", "expected_offer_version", "monsters", "items", "gold"},
                      "lock": {"offer_id", "expected_offer_version", "terms_hash"}, "confirm": {"offer_id", "expected_offer_version", "terms_hash"}, "cancel": {"offer_id", "expected_offer_version"}}
            action = body.get("action")
            require(action in extras, "trade_action", "Unknown trade action")
            common = {"action", "request_id", "expected_revision", "expected_wallet_revision", "rules_hash"}
            obj(body, common | extras[action], common | extras[action])
            string(body["request_id"], 8, 100, "request_id", r"[A-Za-z0-9_-]+")
            integer(body["expected_revision"], 1, 2**53-1, "expected_revision")
            integer(body["expected_wallet_revision"], 0, 2**53-1, "expected_wallet_revision")
            string(body["rules_hash"], 64, 64, "rules_hash", r"[a-f0-9]{64}")
            fingerprint = digest(dumps({"path": path, "body": body}))
            previous = db.execute("SELECT * FROM original_receipts WHERE owner=? AND request_id=?", (identity["id"], body["request_id"])).fetchone()
            if previous:
                require(previous["fingerprint"] == fingerprint, "request_id_conflict", "Request ID already used", 409)
                return self.original_offer_replay(db, character, previous)
            offer = None
            if action != "invite":
                string(body["offer_id"], 36, 36, "offer_id", r"cto_[a-f0-9]{32}")
                integer(body["expected_offer_version"], 1, 2**53-1, "expected_offer_version")
                found = db.execute("SELECT * FROM original_offers WHERE id=?", (body["offer_id"],)).fetchone()
                require(found is not None and character["id"] in (found["sender"], found["receiver"]), "trade_unavailable", "Unknown trade", 404)
                offer = dict(found)
                require(offer["status"] == "open" and offer["expires"] > self.clock(), "trade_unavailable", "Trade completed, cancelled or expired", 409)
                require(offer["version"] == body["expected_offer_version"], "trade_version_conflict", "Review the changed trade", 409)
            character, row, wallet = self.original_commerce_role(db, character["id"], identity["id"], body, offer=offer["id"] if offer else None)
            require(action == "cancel" or not self.shop_control(db, "market_paused", False), "market_paused", "Trading is paused", 503)
            if action == "invite":
                target = string(body["target"], 35, 35, "target", r"cc_[a-f0-9]{32}")
                require(target != character["id"], "trade_target", "Choose another character")
                target_character, target_row, _ = self.original_commerce_role(db, target)
                require(target_character["owner"] != identity["id"], "trade_target", "Choose another player's character", 409)
                require(target_row["rules_hash"] == row["rules_hash"], "original_rules_changed", "Both characters must use the same rules", 409)
                offer = {"id": "cto_"+secrets.token_hex(16), "sender": character["id"], "receiver": target, "status": "open", "version": 1, "created": self.clock(), "expires": self.clock()+600}
                document = {"terms": {character["id"]: self.original_offer_terms(db, character, body), target: {"monsters": [], "items": [], "gold": 0, "details": []}}, "locked": [], "confirmed": [], "snapshots": {}, "ready_at": None}
                document["participants"] = {}
                for participant in (character, target_character):
                    account = db.execute("SELECT id,nickname,friend_code FROM identities WHERE id=?", (participant["owner"],)).fetchone()
                    document["participants"][participant["id"]] = dict(account, character_name=participant["name"])
                db.execute("INSERT INTO original_offers VALUES(?,?,?,?,?,?,?,?)", (offer["id"], offer["sender"], offer["receiver"], "open", 1, "{}", offer["created"], offer["expires"]))
            else:
                document = json.loads(offer["document"])
            if action in ("invite", "edit"):
                if action == "edit":
                    document["terms"][character["id"]] = self.original_offer_terms(db, character, body)
                    offer["version"] += 1
                document.update(locked=[], confirmed=[], ready_at=None)
                document["snapshots"][character["id"]] = {"revision": character["revision"], "wallet_revision": wallet["revision"], "state_hash": digest(row["state"])}
                document["terms_hash"] = digest(dumps(document["terms"]))
                db.execute("DELETE FROM original_trade_locks WHERE character_id=?", (character["id"],))
                db.execute("INSERT INTO original_trade_locks VALUES(?,?,?)", (character["id"], offer["id"], self.clock()))
            elif action == "cancel":
                offer["status"] = "cancelled"
                db.execute("DELETE FROM original_trade_locks WHERE offer_id=?", (offer["id"],))
            else:
                require(body["terms_hash"] == document["terms_hash"], "trade_terms_changed", "Review the exact trade terms", 409)
                if action == "lock":
                    require(character["id"] not in document["locked"], "trade_already_locked", "Your list is already locked", 409)
                    self.original_offer_terms(db, character, document["terms"][character["id"]])
                    document["snapshots"][character["id"]] = {"revision": character["revision"], "wallet_revision": wallet["revision"], "state_hash": digest(row["state"])}
                    db.execute("DELETE FROM original_trade_locks WHERE character_id=?", (character["id"],))
                    db.execute("INSERT INTO original_trade_locks VALUES(?,?,?)", (character["id"], offer["id"], self.clock()))
                    document["locked"].append(character["id"])
                    if len(document["locked"]) == 2:
                        require(any(terms["monsters"] or terms["items"] or terms["gold"] for terms in document["terms"].values()), "trade_empty", "Both lists are empty")
                        document["ready_at"] = self.clock()+3
                else:
                    require(len(document["locked"]) == 2 and self.clock() >= document["ready_at"], "trade_not_ready", "Both lists must be locked; wait for the review timer", 409)
                    require(character["id"] not in document["confirmed"], "trade_already_confirmed", "Your final confirmation was already recorded", 409)
                    document["confirmed"].append(character["id"])
                    if len(document["confirmed"]) == 2:
                        prepared = self.original_trade_prepare(db, offer, document)
                        # Native evolution runs outside the SQLite write transaction.
            if action != "confirm" or len(document["confirmed"]) < 2:
                offer["document"] = dumps(document)
                db.execute("UPDATE original_offers SET status=?,version=?,document=? WHERE id=?", (offer["status"], offer["version"], offer["document"], offer["id"]))
                return self.original_offer_receipt(db, identity, body, fingerprint, offer, character)
        return self.original_trade_settle(token, body, fingerprint, offer, document, prepared)

    def original_trade_prepare(self, db, offer, document):
        roles, originals = {}, {}
        for identifier in (offer["sender"], offer["receiver"]):
            character, row, wallet = self.original_commerce_role(db, identifier, offer=offer["id"])
            snapshot = document["snapshots"].get(identifier)
            require(snapshot == {"revision": character["revision"], "wallet_revision": wallet["revision"], "state_hash": digest(row["state"])}, "trade_character_changed", "A participant changed; edit and review the trade again", 409)
            own = document["terms"][identifier]
            peer = document["terms"][offer["receiver"] if identifier == offer["sender"] else offer["sender"]]
            self.original_offer_terms(db, character, own)
            roles[identifier] = {"state": row["state"], "wallet_balance": wallet["balance"]-own["gold"]+peer["gold"], "outgoing": own["monsters"], "incoming": [{"id": key, "source": key} for key in peer["monsters"]], "outgoing_items": own["items"], "incoming_items": peer["items"]}
            require(roles[identifier]["wallet_balance"] <= 1_000_000_000, "wallet_limit", "Recipient wallet exceeds its limit", 409)
            originals[identifier] = (character, row)
        require(len({row["rules_hash"] for _, row in originals.values()}) == 1, "original_rules_changed", "Both participants must use the same rules", 409)
        return {"roles": roles, "originals": originals, "rules_hash": next(iter(originals.values()))[1]["rules_hash"]}

    def original_trade_settle(self, token, body, fingerprint, offer, document, prepared):
        exchange = self.original_commerce_native("asset_exchange", prepared["rules_hash"], exchange={"roles": prepared["roles"], "time": self.clock()})
        results, pending, documents = {}, {}, {}
        for identifier, role in prepared["roles"].items():
            own = document["terms"][identifier]
            incoming = []
            for index, asset in enumerate(role["incoming"]):
                counterpart_id = own["monsters"][index] if index < len(own["monsters"]) else None
                incoming.append({"id": asset["id"], "counterpart": {"id": counterpart_id, "blob": exchange["assets"][counterpart_id]["blob"]} if counterpart_id else None})
            documents[identifier] = {"initial": exchange["roles"][identifier]["state"], "time": self.clock(), "seed": secrets.randbits(256), "wallet_balance": role["wallet_balance"], "inputs": [], "incoming": incoming}
            results[identifier] = self.original_commerce_native("trade_finish", prepared["rules_hash"], trade=documents[identifier])
        with self.lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            identity = self.original_identity(db, token, mutation=True)
            character = self.controlled_character(db, next(key for key, (entry, _) in prepared["originals"].items() if entry["owner"] == identity["id"] and key in document["confirmed"] and key not in json.loads(offer["document"])["confirmed"]), identity["id"])
            previous = db.execute("SELECT * FROM original_receipts WHERE owner=? AND request_id=?", (identity["id"], body["request_id"])).fetchone()
            if previous:
                require(previous["fingerprint"] == fingerprint, "request_id_conflict", "Request ID already used", 409)
                return self.original_offer_replay(db, character, previous)
            current = db.execute("SELECT * FROM original_offers WHERE id=?", (offer["id"],)).fetchone()
            require(current is not None and current["status"] == "open" and current["version"] == offer["version"] and current["document"] == offer["document"] and current["expires"] > self.clock(), "trade_version_conflict", "The trade changed or expired during settlement", 409)
            self.original_trade_prepare(db, offer, document)
            require(not self.shop_control(db, "market_paused", False), "market_paused", "Trading was paused during settlement", 503)
            for source, terms in document["terms"].items():
                target = offer["receiver"] if source == offer["sender"] else offer["sender"]
                for identifier in terms["monsters"]:
                    changed = db.execute("UPDATE original_creatures SET character_id=?,status='in_transit',revision=revision+1 WHERE id=? AND character_id=? AND status='active'", (target, identifier, source))
                    require(changed.rowcount == 1, "original_asset_unavailable", "Asset ownership changed", 409)
                    asset = results[target]["assets"][identifier]
                    ownership_view = dict(asset["view"], trade_before=exchange["assets"][identifier]["view"])
                    db.execute("INSERT INTO original_ownership(monster_id,source,target,kind,reference,asset,snapshot,created) VALUES(?,?,?,'trade',?,?,?,?)", (identifier, source, target, offer["id"], asset["blob"], dumps(ownership_view), self.clock()))
            for identifier, own in document["terms"].items():
                if own["gold"]:
                    self.shop_money(db, identifier, "GOLD", -own["gold"], "managed:original_trade:"+offer["id"]+":out")
            for identifier, own in document["terms"].items():
                peer = offer["receiver"] if identifier == offer["sender"] else offer["sender"]
                if own["gold"]:
                    self.shop_money(db, peer, "GOLD", own["gold"], "managed:original_trade:"+offer["id"]+":in")
            for identifier, (participant, row) in prepared["originals"].items():
                own = document["terms"][identifier]
                peer = document["terms"][offer["receiver"] if identifier == offer["sender"] else offer["sender"]]
                result = results[identifier]
                if result.get("prompt"):
                    pending[identifier] = {"operation": "trade_finish", "document": documents[identifier], "prompt": result["prompt"], "applied_money": 0, "event_count": len(result["events"]), "wallet_revision": self.shop_wallet(db, identifier, "GOLD")["revision"]}
                    result = dict(result, state=exchange["roles"][identifier]["state"])
                self.original_commerce_write(db, participant, row, result, "original_trade:"+offer["id"], "trade", {"offer_id": offer["id"], "terms_hash": document["terms_hash"]}, pending.get(identifier))
            document["result"] = {"transaction_id": offer["id"], "terms_hash": document["terms_hash"], "completed": self.clock()}
            offer.update(status="completed", document=dumps(document))
            db.execute("UPDATE original_offers SET status='completed',document=? WHERE id=?", (offer["document"], offer["id"]))
            db.execute("DELETE FROM original_trade_locks WHERE offer_id=?", (offer["id"],))
            return self.original_offer_receipt(db, identity, body, fingerprint, offer, self.controlled_character(db, character["id"]))
