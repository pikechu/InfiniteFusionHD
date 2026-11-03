"""Audited shop controls, market cancellation and independently reviewed refunds/codes."""
import json

try:
    from .admin_data import ROLES
except ImportError:
    from admin_data import ROLES


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


def code_configuration(row):
    return {key: row[key] for key in ("hash", "amount", "currency", "expires", "maximum", "target", "batch")}


class CommerceAdminFeatures:
    def init_admin_commerce(self, db):
        db.executescript("""CREATE TABLE IF NOT EXISTS commerce_proposals(
            id TEXT PRIMARY KEY,actor TEXT NOT NULL,action TEXT NOT NULL,document TEXT NOT NULL,
            status TEXT NOT NULL,expires REAL NOT NULL,approved_by TEXT);""")

    def commerce_read(self, db, actor, path, query):
        if path in ("/admin/v1/commerce-order", "/admin/v1/commerce-listing"):
            self.admin_permission(actor, "economy")
            field = "order_id" if path.endswith("order") else "listing_id"
            require(set(query) == {field}, "invalid_query", "Specify one business identifier")
            reference = string(query[field], 1, 80, field, r"[A-Za-z0-9_-]+")
            if field == "order_id":
                row = db.execute("SELECT owner,document FROM shop_orders WHERE id=?", (reference,)).fetchone()
                require(row is not None, "order_not_found", "Order does not exist", 404)
                return {"owner": row["owner"], "order": json.loads(row["document"]), "wallet": self.shop_wallet(db, row["owner"])}
            if reference.startswith("cml_"):
                row = db.execute("SELECT * FROM original_market WHERE id=?", (reference,)).fetchone()
                require(row is not None, "listing_not_found", "Listing does not exist", 404)
                public = self.original_market_public(db, row)
                return {"listing": dict(public, owner=public["seller_identity"]["account_id"], asset_id=public["monster_id"], currency="GOLD")}
            row = db.execute("SELECT id,owner,asset_id,price,status,expires FROM market_listings WHERE id=?", (reference,)).fetchone()
            require(row is not None, "listing_not_found", "Listing does not exist", 404)
            return {"listing": dict(row)}
        if path != "/admin/v1/commerce":
            return None
        self.admin_permission(actor, "economy")
        require(not query, "invalid_query", "Unexpected query")
        catalog = self.shop_catalog()
        controls = []
        for key in ("paused", "market_paused", "equipment_paused"):
            value = self.shop_control(db, key)
            controls.append({"key": key, "value": value, "hash": digest(dumps(value))})
        products = []
        for product in catalog["products"]:
            key = "sku:" + product["id"]
            override = self.shop_control(db, key)
            products.append({"product": self.shop_product(db, product), "key": key,
                             "override": override, "hash": digest(dumps(override))})
        codes = []
        for row in db.execute("SELECT * FROM shop_codes ORDER BY rowid DESC LIMIT 100"):
            codes.append(dict(row, configuration_hash=digest(dumps(code_configuration(row)))))
        return {"controls": controls, "products": products, "codes": codes,
                "proposals": [dict(row, detail=json.loads(row["document"])) for row in db.execute("SELECT * FROM commerce_proposals ORDER BY rowid DESC LIMIT 50")],
                "as_of": self.clock()}

    def validate_refund(self, db, data):
        obj(data, {"order_id", "expected_wallet_revision", "player_message"}, {"order_id", "expected_wallet_revision", "player_message"})
        order_id = string(data["order_id"], 1, 80, "order_id", r"[A-Za-z0-9_-]+")
        string(data["player_message"], 1, 200, "player_message")
        revision = integer(data["expected_wallet_revision"], 0, 2**53 - 1, "expected_wallet_revision")
        row = db.execute("SELECT owner,document FROM shop_orders WHERE id=?", (order_id,)).fetchone()
        require(row is not None, "order_not_found", "Order does not exist", 404)
        order = json.loads(row["document"])
        require(order["status"] == "completed", "already_refunded", "Order is no longer refundable", 409)
        wallet = self.shop_wallet(db, row["owner"])
        require(wallet["revision"] == revision, "wallet_version_conflict", "Refund wallet changed; review again", 409)
        require(wallet["balance"] + order["total"] <= 1000000000, "wallet_limit", "Refund exceeds wallet limit", 409)
        return row["owner"], order

    def commerce_command(self, db, actor, body):
        self.admin_permission(actor, "economy")
        action = body["action"]
        common = {"id", "action", "reason"}
        extra = {"commerce_control": {"data", "expected_hash"}, "create_code": {"data"},
                 "disable_code": {"reference", "expected_hash"}, "refund_order": {"data"},
                 "approve_commerce": {"proposal_id"}, "cancel_listing": {"reference"}}[action]
        obj(body, common | extra, common | extra)
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        reason = string(body["reason"], 3, 500, "reason")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(old["response"])
        detail, target, status = {}, "", "completed"
        if action == "commerce_control":
            data = obj(body["data"], {"key", "value"}, {"key", "value"})
            key = string(data["key"], 1, 100, "key")
            before = self.shop_control(db, key)
            require(body["expected_hash"] == digest(dumps(before)), "commerce_version_conflict", "Configuration changed; refresh and review", 409)
            self.shop_admin_in_transaction(db, actor["username"], "control", command_id, data)
            detail, target = {"before": before, "after": data["value"]}, key
        elif action == "disable_code":
            code_hash = string(body["reference"], 64, 64, "reference", r"[a-f0-9]{64}")
            row = db.execute("SELECT * FROM shop_codes WHERE hash=?", (code_hash,)).fetchone()
            require(row is not None, "code_not_found", "Code does not exist", 404)
            require(body["expected_hash"] == digest(dumps(code_configuration(row))), "commerce_version_conflict", "Code configuration changed", 409)
            db.execute("UPDATE shop_codes SET maximum=uses WHERE hash=?", (code_hash,))
            pending = db.execute("SELECT id FROM commerce_proposals WHERE status='pending' AND json_extract(document,'$.data.code_hash')=?", (code_hash,)).fetchall()
            for proposal in pending:
                db.execute("UPDATE commerce_proposals SET status='cancelled' WHERE id=?", (proposal["id"],))
                db.execute("UPDATE admin_commands SET response=? WHERE id=?", (dumps({"ok": True, "command_id": proposal["id"], "status": "cancelled", "detail": {"code_hash": code_hash}}), proposal["id"]))
            detail, target = {"before": dict(row), "maximum": row["uses"], "cancelled_proposals": [item["id"] for item in pending]}, code_hash
        elif action == "cancel_listing":
            listing_id = string(body["reference"], 1, 80, "reference", r"[A-Za-z0-9_-]+")
            if listing_id.startswith("cml_"):
                row = db.execute("SELECT * FROM original_market WHERE id=?", (listing_id,)).fetchone()
                require(row is not None and row["status"] == "active", "listing_unavailable", "Listing already closed", 409)
                character = self.controlled_character(db, row["seller"])
                require(db.execute("SELECT 1 FROM original_creatures WHERE id=? AND character_id=? AND status='listed'", (row["monster_id"],row["seller"])).fetchone() is not None, "asset_lock_lost", "Original escrow ownership changed", 409)
                db.execute("UPDATE original_market SET status='withdrawn',version=version+1 WHERE id=?", (listing_id,))
                detail = {"listing_id": listing_id, "asset_id": row["monster_id"], "character_id": row["seller"], "currency": "GOLD", "delivery": "seller_claim", "version": row["version"]+1}
                result = {"ok": True, "command_id": command_id, "status": "completed", "target": character["owner"], "detail": detail}
                self.audit(db, actor["username"], action, character["owner"], reason, detail)
                db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
                return 200, result
            row = db.execute("SELECT * FROM market_listings WHERE id=?", (listing_id,)).fetchone()
            require(row is not None and row["status"] == "active", "listing_unavailable", "Listing already closed", 409)
            asset = self.asset(db, row["asset_id"], row["owner"])
            lock = db.execute("SELECT reference FROM asset_locks WHERE asset_id=?", (asset["id"],)).fetchone()
            require(lock is not None and lock["reference"] == "market:" + listing_id, "asset_lock_lost", "Listing asset no longer has its expected lock", 409)
            db.execute("UPDATE market_listings SET status='cancelled' WHERE id=?", (listing_id,))
            db.execute("DELETE FROM asset_locks WHERE asset_id=? AND reference=?", (asset["id"], "market:" + listing_id))
            receipt = {"kind": "cancelled", "listing_id": listing_id, "asset_id": asset["id"], "price": row["price"], "reason": "operator_cancelled", "created_at": self.clock()}
            db.execute("INSERT INTO market_receipts VALUES(?,?,?,?)", (row["owner"], "admin_" + command_id, fingerprint, dumps(receipt)))
            detail, target = receipt, row["owner"]
        elif action in ("create_code", "refund_order"):
            count = db.execute("SELECT count(*) FROM commerce_proposals WHERE actor=? AND status='pending' AND expires>?", (actor["username"], self.clock())).fetchone()[0]
            require(count < 50, "proposal_limit", "Resolve existing proposals first", 429)
            if action == "create_code":
                data = obj(body["data"], {"code", "currency", "amount", "expires", "maximum", "target", "batch"},
                           {"code", "currency", "amount", "expires", "maximum", "batch"})
                if data.get("target") is not None:
                    string(data["target"], 1, 80, "target", r"p_[a-f0-9]{24}")
                amount = integer(data["amount"], 1, 1000000000, "amount")
                maximum = integer(data["maximum"], 1, 100000, "maximum")
                require(amount * maximum <= 1000000000, "campaign_limit", "Campaign face value exceeds limit")
                self.shop_admin_in_transaction(db, actor["username"], "code", command_id, data)
                code_hash = digest(data["code"].upper())
                # Creation and deactivation share this transaction: no player can
                # redeem a code before the independent reviewer activates it.
                db.execute("UPDATE shop_codes SET maximum=0 WHERE hash=?", (code_hash,))
                sanitized = {key: value for key, value in data.items() if key != "code"}
                sanitized["code_hash"] = code_hash
                detail, target = sanitized, code_hash
            else:
                target, order = self.validate_refund(db, body["data"])
                detail = dict(body["data"], order_hash=digest(dumps(order)), owner=target, total=order["total"])
            proposal = {"action": action, "data": detail, "reason": reason}
            db.execute("INSERT INTO commerce_proposals VALUES(?,?,?,?, 'pending',?,NULL)",
                       (command_id, actor["username"], action, dumps(proposal), self.clock() + 86400))
            status = "pending_approval"
        else:
            proposal_id = string(body["proposal_id"], 16, 100, "proposal_id", r"[A-Za-z0-9_-]+")
            proposal = db.execute("SELECT * FROM commerce_proposals WHERE id=?", (proposal_id,)).fetchone()
            require(proposal is not None and proposal["status"] == "pending" and proposal["expires"] > self.clock(), "proposal_unavailable", "Proposal expired or already processed", 409)
            require(proposal["actor"] != actor["username"], "independent_approval_required", "Another administrator must review this operation", 403)
            initiator = db.execute("SELECT role FROM admin_users WHERE username=? AND enabled=1", (proposal["actor"],)).fetchone()
            require(initiator is not None and "economy" in ROLES.get(initiator["role"], ()), "proposal_revoked", "Initiator permissions were revoked", 403)
            instruction = json.loads(proposal["document"])
            data = instruction["data"]
            if instruction["action"] == "create_code":
                code_hash = data["code_hash"]
                row = db.execute("SELECT * FROM shop_codes WHERE hash=?", (code_hash,)).fetchone()
                require(row is not None and row["maximum"] == 0 and row["uses"] == 0 and row["expires"] > self.clock(), "code_unavailable", "Reserved code changed or expired", 409)
                db.execute("UPDATE shop_codes SET maximum=? WHERE hash=?", (data["maximum"], code_hash))
                detail, target = {"activated": True, "code_hash": code_hash}, code_hash
            else:
                target, order = self.validate_refund(db, {key: data[key] for key in ("order_id", "expected_wallet_revision", "player_message")})
                require(data["order_hash"] == digest(dumps(order)), "order_version_conflict", "Order changed; review again", 409)
                self.shop_admin_in_transaction(db, actor["username"], "refund", command_id, {"order_id": data["order_id"], "reason": data["player_message"]})
                detail = {"order_id": data["order_id"], "amount": order["total"], "currency": "RP"}
            db.execute("UPDATE commerce_proposals SET status='completed',approved_by=? WHERE id=?", (actor["username"], proposal_id))
            detail["proposal_id"] = proposal_id
            db.execute("UPDATE admin_commands SET response=? WHERE id=?", (dumps({"ok": True, "command_id": proposal_id, "status": "completed", "detail": detail}), proposal_id))
        result = {"ok": True, "command_id": command_id, "status": status, "detail": detail}
        self.audit(db, actor["username"], action, target, reason, dict(detail, command_id=command_id, status=status))
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        return 200, result
