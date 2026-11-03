"""Isolated server-owned characters, GOLD and inventory.

No cloud payload, local balance, badge, catch or client victory is accepted as
an economic source. Current sources are a one-time account grant, daily account
check-in, validated NPC sales, and audited operator adjustments. Integrating the
full adventure engine requires a separate verified server-side producer.
"""
import hashlib
import json
from pathlib import Path
import secrets

try:
    from .admin_data import day_key
    from .controlled_original import ControlledOriginalFeatures, bind_api as bind_original_api
    from .controlled_commerce import ControlledCommerceFeatures, bind_api as bind_commerce_api
except ImportError:
    from admin_data import day_key
    from controlled_original import ControlledOriginalFeatures, bind_api as bind_original_api
    from controlled_commerce import ControlledCommerceFeatures, bind_api as bind_commerce_api


def bind_api(api):
    bind_original_api(api)
    bind_commerce_api(api)
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


class ControlledFeatures(ControlledOriginalFeatures, ControlledCommerceFeatures):
    def init_controlled(self, db):
        db.executescript("""
          CREATE TABLE IF NOT EXISTS controlled_characters(
            id TEXT PRIMARY KEY,owner TEXT NOT NULL,name TEXT NOT NULL,revision INTEGER NOT NULL,
            status TEXT NOT NULL,created REAL NOT NULL);
          CREATE INDEX IF NOT EXISTS controlled_characters_owner ON controlled_characters(owner,id);
          CREATE TABLE IF NOT EXISTS controlled_inventory(
            character_id TEXT NOT NULL,item TEXT NOT NULL,quantity INTEGER NOT NULL CHECK(quantity>=0 AND quantity<=999),
            PRIMARY KEY(character_id,item));
          CREATE TABLE IF NOT EXISTS controlled_claims(
            owner TEXT NOT NULL,day TEXT NOT NULL,character_id TEXT NOT NULL,event TEXT NOT NULL,
            created REAL NOT NULL,PRIMARY KEY(owner,day));
          CREATE TABLE IF NOT EXISTS controlled_receipts(
            owner TEXT NOT NULL,request_id TEXT NOT NULL,fingerprint TEXT NOT NULL,response TEXT NOT NULL,
            created REAL NOT NULL,PRIMARY KEY(owner,request_id));
          CREATE TABLE IF NOT EXISTS controlled_item_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,character_id TEXT NOT NULL,item TEXT NOT NULL,
            amount INTEGER NOT NULL,quantity INTEGER NOT NULL,event TEXT NOT NULL,created REAL NOT NULL,
            UNIQUE(character_id,item,event));
          CREATE TABLE IF NOT EXISTS controlled_proposals(
            id TEXT PRIMARY KEY,actor TEXT NOT NULL,document TEXT NOT NULL,status TEXT NOT NULL,
            expires REAL NOT NULL,approved_by TEXT);
          CREATE TRIGGER IF NOT EXISTS controlled_item_immutable_update BEFORE UPDATE ON controlled_item_events BEGIN
            SELECT RAISE(ABORT,'Inventory ledger is append-only');
          END;
          CREATE TRIGGER IF NOT EXISTS controlled_item_immutable_delete BEFORE DELETE ON controlled_item_events BEGIN
            SELECT RAISE(ABORT,'Inventory ledger is append-only');
          END;
        """)
        self.init_controlled_adventure(db)
        self.init_original(db)
        self.init_original_commerce(db)
        self.init_original_rollback(db)

    def controlled_catalog(self):
        try:
            raw = (Path(__file__).parent / "catalog-controlled-v1.json").read_bytes()
            catalog = json.loads(raw)
        except (OSError, ValueError):
            raise APIError(503, "controlled_catalog_unavailable", "Controlled catalog unavailable")
        require(type(catalog) is dict and catalog.get("version") == 1 and catalog.get("rules") == "controlled-assets-v1" and
                type(catalog.get("items")) is list and 1 <= len(catalog["items"]) <= 100,
                "controlled_catalog_unavailable", "Controlled catalog unavailable", 503)
        integer(catalog.get("max_characters"), 1, 10, "max_characters")
        integer(catalog.get("initial_gold"), 1, 10000, "initial_gold")
        integer(catalog.get("daily_gold"), 1, 1000, "daily_gold")
        for item in catalog["items"]:
            obj(item, {"id", "name", "buy_price", "sell_price", "max_stack"}, {"id", "name", "buy_price", "sell_price", "max_stack"})
            string(item["id"], 1, 64, "item", r"[A-Z0-9_]+")
            string(item["name"], 1, 80, "item_name")
            integer(item["buy_price"], 1, 1000000000, "buy_price")
            integer(item["sell_price"], 0, item["buy_price"], "sell_price")
            integer(item["max_stack"], 1, 999, "max_stack")
        require(len({item["id"] for item in catalog["items"]}) == len(catalog["items"]), "controlled_catalog_unavailable", "Duplicate catalog items", 503)
        catalog["hash"] = hashlib.sha256(raw).hexdigest()
        return catalog

    def controlled_character(self, db, character_id, owner=None):
        string(character_id, 35, 35, "character_id", r"cc_[a-f0-9]{32}")
        row = db.execute("SELECT * FROM controlled_characters WHERE id=?", (character_id,)).fetchone()
        require(row is not None and (owner is None or row["owner"] == owner), "controlled_character_not_found", "Controlled character does not exist or belongs to another account", 404)
        require(row["status"] == "active", "controlled_character_inactive", "Controlled character is inactive", 409)
        return dict(row)

    def controlled_view(self, db, character):
        original = self.original_row(db, character["id"])
        return dict(character, source="server_managed", rules_mode="original" if original else "v1", rules_hash=original["rules_hash"] if original else None, wallet=self.shop_wallet(db, character["id"], "GOLD"),
                    inventory=[dict(row) for row in db.execute("SELECT item,quantity FROM controlled_inventory WHERE character_id=? AND quantity>0 ORDER BY item", (character["id"],))])

    def controlled_item_change(self, db, character_id, item_id, amount, event):
        self.controlled_character(db, character_id)
        require(self.original_row(db, character_id) is None, "original_inventory_workflow", "Use the original-game inventory workflow for this character", 409)
        require(type(amount) is int and amount != 0, "invalid_amount", "Nonzero integer required")
        catalog = self.controlled_catalog()
        item = next((entry for entry in catalog["items"] if entry["id"] == item_id), None)
        require(item is not None, "controlled_item_unknown", "Item is not in the controlled catalog", 404)
        old = db.execute("SELECT amount FROM controlled_item_events WHERE character_id=? AND item=? AND event=?", (character_id, item_id, event)).fetchone()
        if old:
            require(old[0] == amount, "event_conflict", "Item event already used", 409)
            return
        row = db.execute("SELECT quantity FROM controlled_inventory WHERE character_id=? AND item=?", (character_id, item_id)).fetchone()
        quantity = (row[0] if row else 0) + amount
        require(0 <= quantity <= item["max_stack"], "controlled_inventory_limit", "Insufficient items or stack limit exceeded", 409)
        db.execute("INSERT OR REPLACE INTO controlled_inventory VALUES(?,?,?)", (character_id, item_id, quantity))
        db.execute("INSERT INTO controlled_item_events(character_id,item,amount,quantity,event,created) VALUES(?,?,?,?,?,?)",
                   (character_id, item_id, amount, quantity, event, self.clock()))

    def controlled_inventory_audit(self, db):
        mismatches = [dict(row) for row in db.execute("""SELECT i.character_id,i.item,i.quantity,coalesce(sum(e.amount),0) AS ledger_quantity
            FROM controlled_inventory i LEFT JOIN controlled_item_events e ON e.character_id=i.character_id AND e.item=i.item
            GROUP BY i.character_id,i.item HAVING i.quantity!=coalesce(sum(e.amount),0) LIMIT 100""")]
        missing = [dict(row) for row in db.execute("""SELECT e.character_id,e.item,sum(e.amount) AS ledger_quantity FROM controlled_item_events e
            LEFT JOIN controlled_inventory i ON i.character_id=e.character_id AND i.item=e.item WHERE i.character_id IS NULL
            GROUP BY e.character_id,e.item HAVING sum(e.amount)!=0 LIMIT 100""")]
        return {"ok": not (mismatches or missing), "mismatches": mismatches, "missing_inventory": missing}

    def controlled_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (owner,)).fetchone() is not None, "account_required", "Registered account required", 403)
        if method == "GET":
            adventure = self.controlled_adventure_request(db, identity, method, parts, body)
            if adventure is not None:
                return 200, adventure
        if method == "GET" and parts == ["v1", "controlled", "catalog"]:
            return 200, {"ok": True, "catalog": self.controlled_catalog()}
        if method == "GET" and parts == ["v1", "controlled", "characters"]:
            return 200, {"ok": True, "characters": [self.controlled_view(db, dict(row)) for row in db.execute("SELECT * FROM controlled_characters WHERE owner=? ORDER BY created,id", (owner,)).fetchall()]}
        if method == "GET" and len(parts) == 4 and parts[2] == "characters":
            return 200, {"ok": True, "character": self.controlled_view(db, self.controlled_character(db, parts[3], owner))}
        require(method == "POST", "not_found", "Unknown controlled character operation", 404)
        request_id = string(body.get("request_id"), 8, 100, "request_id", r"[A-Za-z0-9_-]+")
        fingerprint = digest(dumps({"path": parts, "body": body}))
        old = db.execute("SELECT fingerprint,response FROM controlled_receipts WHERE owner=? AND request_id=?", (owner, request_id)).fetchone()
        if old:
            require(old["fingerprint"] == fingerprint, "request_id_conflict", "Request ID already used", 409)
            return 200, json.loads(old["response"])
        adventure = self.controlled_adventure_request(db, identity, method, parts, body)
        if adventure is not None:
            db.execute("INSERT INTO controlled_receipts VALUES(?,?,?,?,?)", (owner, request_id, fingerprint, dumps(adventure), self.clock()))
            return 200, adventure
        catalog = self.controlled_catalog()
        reward_amount = None
        if parts == ["v1", "controlled", "characters"]:
            obj(body, {"request_id", "name", "catalog_hash"}, {"request_id", "name", "catalog_hash"})
            name = string(body["name"], 1, 20, "name")
            require("\\" not in name, "invalid_name", "Character names cannot contain message control commands")
            require(name.strip() == name, "invalid_name", "Name has surrounding whitespace")
            require(body["catalog_hash"] == catalog["hash"], "catalog_changed", "Controlled catalog changed; review again", 409)
            count = db.execute("SELECT count(*) FROM controlled_characters WHERE owner=?", (owner,)).fetchone()[0]
            require(count < catalog["max_characters"], "controlled_character_limit", "Controlled character limit reached", 409)
            character_id = "cc_" + secrets.token_hex(16)
            db.execute("INSERT INTO controlled_characters VALUES(?,?,?,1,'active',?)", (character_id, owner, name, self.clock()))
            if not db.execute("SELECT 1 FROM controlled_claims WHERE owner=? AND day='initial'", (owner,)).fetchone():
                event = "managed:initial:" + owner
                self.shop_money(db, character_id, "GOLD", catalog["initial_gold"], event)
                db.execute("INSERT INTO controlled_claims VALUES(?,'initial',?,?,?)", (owner, character_id, event, self.clock()))
            character = self.controlled_character(db, character_id, owner)
        else:
            require(len(parts) == 5 and parts[2] == "characters", "not_found", "Unknown controlled character operation", 404)
            character = self.controlled_character(db, parts[3], owner)
            require(self.original_row(db, character["id"]) is None, "original_rules_active", "Use the original game interface for this character", 409)
            require(self.adventure_active_battle(db, character["id"]) is None, "controlled_in_battle", "Finish or abandon the battle before other asset operations", 409)
            action = parts[4]
            fields = {"request_id", "expected_revision"} | ({"item", "quantity", "catalog_hash", "expected_unit_price", "expected_wallet_revision"} if action in ("buy", "sell") else set())
            obj(body, fields, fields)
            revision = integer(body["expected_revision"], 1, 2**53 - 1, "expected_revision")
            require(character["revision"] == revision, "controlled_revision_conflict", "Character changed; refresh and review", 409)
            require(self.controlled_v1_action_allowed(db, character["id"], action), "original_migration_required", "Use original-game NPCs after migrating this server-owned character", 409)
            if action == "daily":
                day = day_key(self.clock())
                reward_amount = 0
                if not db.execute("SELECT 1 FROM controlled_claims WHERE owner=? AND day=?", (owner, day)).fetchone():
                    event = "managed:daily:" + owner + ":" + day
                    self.shop_money(db, character["id"], "GOLD", catalog["daily_gold"], event)
                    db.execute("INSERT INTO controlled_claims VALUES(?,?,?,?,?)", (owner, day, character["id"], event, self.clock()))
                    reward_amount = catalog["daily_gold"]
            elif action in ("buy", "sell"):
                require(body["catalog_hash"] == catalog["hash"], "catalog_changed", "Controlled catalog changed; review again", 409)
                item_id = string(body["item"], 1, 64, "item", r"[A-Z0-9_]+")
                item = next((entry for entry in catalog["items"] if entry["id"] == item_id), None)
                require(item is not None, "controlled_item_unknown", "Unknown item", 404)
                quantity = integer(body["quantity"], 1, item["max_stack"], "quantity")
                price = item["buy_price" if action == "buy" else "sell_price"]
                require(type(body["expected_unit_price"]) is int and body["expected_unit_price"] == price, "price_changed", "Review the current item price", 409)
                wallet = self.shop_wallet(db, character["id"], "GOLD")
                require(wallet["revision"] == integer(body["expected_wallet_revision"], 0, 2**53 - 1, "expected_wallet_revision"), "wallet_version_conflict", "Wallet changed; refresh and review", 409)
                event = "managed:npc_" + action + ":" + character["id"] + ":" + request_id
                self.controlled_item_change(db, character["id"], item_id, quantity if action == "buy" else -quantity, event)
                if price:
                    self.shop_money(db, character["id"], "GOLD", price * quantity * (-1 if action == "buy" else 1), event)
            else:
                raise APIError(404, "not_found", "Unknown controlled character operation")
            db.execute("UPDATE controlled_characters SET revision=revision+1 WHERE id=?", (character["id"],))
            character = self.controlled_character(db, character["id"], owner)
        result = {"ok": True, "character": self.controlled_view(db, character)}
        if reward_amount is not None:
            result["reward_amount"] = reward_amount
        db.execute("INSERT INTO controlled_receipts VALUES(?,?,?,?,?)", (owner, request_id, fingerprint, dumps(result), self.clock()))
        return 200, result
