"""Account economy. All mutations execute inside Store's existing write transaction.

RP is an isolated, non-transferable cosmetics balance. MARKET is separately
issued by operators for hosted-asset trading; neither imports local save money.
No payment callback or client-controlled minting endpoint exists.
"""
import copy
import hashlib
import json
import re
import secrets
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAX_BALANCE = 1_000_000_000


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest"):
        globals()[name] = api[name]


class ShopFeatures:
    def init_shop(self, db):
        db.executescript("""
            CREATE TABLE IF NOT EXISTS shop_wallets(owner TEXT NOT NULL,currency TEXT NOT NULL,balance INTEGER NOT NULL CHECK(balance>=0 AND balance<=1000000000),revision INTEGER NOT NULL,PRIMARY KEY(owner,currency));
            CREATE TABLE IF NOT EXISTS shop_ledger(id INTEGER PRIMARY KEY AUTOINCREMENT,owner TEXT NOT NULL,currency TEXT NOT NULL,amount INTEGER NOT NULL,balance INTEGER NOT NULL,event TEXT NOT NULL,created REAL NOT NULL,UNIQUE(owner,currency,event));
            CREATE TABLE IF NOT EXISTS shop_orders(id TEXT PRIMARY KEY,owner TEXT NOT NULL,request_id TEXT NOT NULL,fingerprint TEXT NOT NULL,document TEXT NOT NULL,UNIQUE(owner,request_id));
            CREATE TABLE IF NOT EXISTS shop_grants(owner TEXT NOT NULL,entitlement TEXT NOT NULL,order_id TEXT NOT NULL,active INTEGER NOT NULL,PRIMARY KEY(owner,entitlement,order_id));
            CREATE TABLE IF NOT EXISTS shop_equipment(owner TEXT PRIMARY KEY,document TEXT NOT NULL,revision INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS shop_codes(hash TEXT PRIMARY KEY,amount INTEGER NOT NULL,currency TEXT NOT NULL,expires REAL NOT NULL,uses INTEGER NOT NULL,maximum INTEGER NOT NULL,target TEXT,batch TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS shop_redemptions(owner TEXT NOT NULL,code_hash TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(owner,code_hash));
            CREATE TABLE IF NOT EXISTS shop_attempts(owner TEXT NOT NULL,created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS shop_controls(key TEXT PRIMARY KEY,document TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS shop_audit(id INTEGER PRIMARY KEY AUTOINCREMENT,actor TEXT NOT NULL,action TEXT NOT NULL,reference TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS market_listings(id TEXT PRIMARY KEY,owner TEXT NOT NULL,asset_id TEXT NOT NULL,price INTEGER NOT NULL,status TEXT NOT NULL,expires REAL NOT NULL,document TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS market_receipts(owner TEXT NOT NULL,request_id TEXT NOT NULL,fingerprint TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(owner,request_id));
            CREATE INDEX IF NOT EXISTS market_active ON market_listings(status,expires);
        """)

    def shop_catalog(self):
        try:
            raw = (ROOT / "Data/shop/catalog.json").read_bytes()
            catalog = json.loads(raw)
            if catalog["version"] != 1 or len(catalog["products"]) > 1000:
                raise ValueError("Invalid catalog")
            catalog["hash"] = hashlib.sha256(raw).hexdigest()
            return catalog
        except (OSError, ValueError, KeyError, TypeError):
            require(False, "shop_unavailable", "商城目录暂时不可用。", 503)

    def shop_account(self, db, identity, body=None):
        require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (identity["id"],)).fetchone(), "account_required", "请使用注册账号登录在线模式。", 403)
        if body is not None:
            self.cloud_lease(db, identity["id"], self.online_session_id(body))

    def shop_control(self, db, key, default=None):
        row = db.execute("SELECT document FROM shop_controls WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def shop_owned(self, db, owner):
        return sorted(row[0] for row in db.execute("SELECT DISTINCT entitlement FROM shop_grants WHERE owner=? AND active=1", (owner,)))

    def shop_wallet(self, db, owner, currency="RP"):
        row = db.execute("SELECT balance,revision FROM shop_wallets WHERE owner=? AND currency=?", (owner, currency)).fetchone()
        return {"currency": currency, "balance": row[0] if row else 0, "revision": row[1] if row else 0}

    def shop_money(self, db, owner, currency, amount, event):
        require(currency in ("RP", "MARKET", "GOLD"), "invalid_currency", "不支持的货币。")
        if currency == "GOLD":
            self.controlled_character(db, owner)
            if hasattr(self, "_original_engine"):
                self.original_wallet_write(db, owner, event)
        require(type(amount) is int and -MAX_BALANCE <= amount <= MAX_BALANCE and amount != 0, "invalid_amount", "金额无效。")
        old = db.execute("SELECT amount FROM shop_ledger WHERE owner=? AND currency=? AND event=?", (owner, currency, event)).fetchone()
        if old:
            require(old[0] == amount, "event_conflict", "同一入账来源不能变更金额。", 409)
            return self.shop_wallet(db, owner, currency)
        wallet = self.shop_wallet(db, owner, currency)
        balance = wallet["balance"] + amount
        require(balance >= 0, "insufficient_funds", "余额不足。", 409)
        require(balance <= MAX_BALANCE, "wallet_limit", "余额达到上限。", 409)
        db.execute("INSERT OR REPLACE INTO shop_wallets VALUES(?,?,?,?)", (owner, currency, balance, wallet["revision"] + 1))
        db.execute("INSERT INTO shop_ledger(owner,currency,amount,balance,event,created) VALUES(?,?,?,?,?,?)", (owner, currency, amount, balance, event, self.clock()))
        return self.shop_wallet(db, owner, currency)

    def shop_equipped(self, db, owner):
        row = db.execute("SELECT document,revision FROM shop_equipment WHERE owner=?", (owner,)).fetchone()
        equipment = json.loads(row[0]) if row else {}
        owned = set(self.shop_owned(db, owner))
        equipment = {slot: value for slot, value in equipment.items() if value in owned}
        return {"slots": equipment, "revision": row[1] if row else 0, "version": 1}

    def shop_state(self, db, owner):
        return {"wallet": self.shop_wallet(db, owner), "market_wallet": self.shop_wallet(db, owner, "MARKET"),
                "entitlements": self.shop_owned(db, owner), "equipment": self.shop_equipped(db, owner)}

    def shop_card_decoration(self, db, owner):
        catalog = self.shop_catalog()
        return {slot: catalog["entitlements"][key] for slot, key in self.shop_equipped(db, owner)["slots"].items()
                if slot in ("frame", "title") and key in catalog["entitlements"]}

    def shop_product(self, db, product):
        value = copy.deepcopy(product)
        override = self.shop_control(db, "sku:" + product["id"], {})
        value.update(override)
        if "price" in override and len(value["grants"]) > 1:
            value["description"] = "按当前套装优惠价计算未拥有部分，确认页显示实际总价。永久账号绑定。"
        return value

    def shop_available(self, db, owner, product):
        now = self.clock()
        return bool(product.get("enabled", True) and product.get("starts_at", 0) <= now < product.get("ends_at", 4102444800)
                    and (not product.get("audience") or owner in product["audience"]))

    def shop_quote(self, product, owned, catalog):
        # Bundles charge only for missing constituents, using immutable component
        # prices in the same catalog version. Existing grants are never revoked.
        missing = [key for key in product["grants"] if key not in owned]
        prices = {key: val["value"] for key, val in catalog["entitlements"].items()}
        if len(product["grants"]) == 1:
            return product["price"] if missing else 0, missing
        full_value = sum(prices[key] for key in product["grants"])
        total = sum(prices[key] for key in missing) * product["price"] // full_value
        return max(1, total) if missing else 0, missing

    def shop_appearance(self, db, owner, base=None):
        catalog = self.shop_catalog()
        base = dict(base or {})
        allowed = catalog["base"]
        for slot in ("clothes", "hat", "hair", "skin_tone"):
            value = base.get(slot)
            require(value is None or isinstance(value, str) and value in allowed[slot], "invalid_appearance", "基础外观资源无效。")
        for key in ("clothes_color", "hat_color", "hair_color"):
            integer(base.get(key, 0), 0, 359, key)
        result = {key: base.get(key, allowed[key][0]) for key in ("clothes", "hat", "hair", "skin_tone")}
        result.update({key: base.get(key, 0) for key in ("clothes_color", "hat_color", "hair_color")})
        equipped = self.shop_equipped(db, owner)
        for slot, entitlement in equipped["slots"].items():
            definition = catalog["entitlements"].get(entitlement)
            if definition and slot in ("clothes", "hat", "hair"):
                result[slot] = definition["resource"]
                result[slot + "_color"] = 0
        result.update({"version": 1, "revision": equipped["revision"], "catalog_hash": catalog["hash"]})
        return result

    def shop_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        self.shop_account(db, identity)
        catalog = self.shop_catalog()
        action = parts[2] if len(parts) >= 3 else ""
        if method == "GET":
            if action == "catalog" and len(parts) == 3:
                owned = set(self.shop_owned(db, owner))
                products = []
                for original in catalog["products"]:
                    product = self.shop_product(db, original)
                    if not self.shop_available(db, owner, product):
                        continue
                    product["total"], product["missing"] = self.shop_quote(product, owned, catalog)
                    product["owned"] = not product["missing"]
                    products.append(product)
                return 200, {"ok": True, "catalog": {"version": 1, "hash": catalog["hash"], "products": products,
                             "entitlements": catalog["entitlements"], "server_time": self.clock(), "paused": self.shop_control(db, "paused", False)}}
            if action == "state" and len(parts) == 3:
                return 200, dict(ok=True, **self.shop_state(db, owner))
            if action == "wallet" and len(parts) == 3:
                return 200, {"ok": True, "wallet": self.shop_wallet(db, owner), "market_wallet": self.shop_wallet(db, owner, "MARKET")}
            if action == "entitlements" and len(parts) == 3:
                return 200, {"ok": True, "entitlements": self.shop_owned(db, owner)}
            if action == "orders":
                if len(parts) == 5 and parts[3] == "page":
                    require(re.fullmatch(r"[0-9]{1,16}", parts[4]), "invalid_cursor", "记录游标无效。")
                    cursor = int(parts[4])
                    rows = db.execute("SELECT rowid,document FROM shop_orders WHERE owner=? AND (?=0 OR rowid<?) ORDER BY rowid DESC LIMIT 21", (owner, cursor, cursor)).fetchall()
                    return 200, {"ok": True, "orders": [json.loads(row[1]) for row in rows[:20]], "next_cursor": rows[19][0] if len(rows) > 20 else None}
                if len(parts) == 4:
                    row = db.execute("SELECT document FROM shop_orders WHERE owner=? AND id=?", (owner, parts[3])).fetchone()
                    require(row, "order_not_found", "订单不存在。", 404)
                    return 200, {"ok": True, "order": json.loads(row[0])}
                rows = db.execute("SELECT document FROM shop_orders WHERE owner=? ORDER BY rowid DESC LIMIT 100", (owner,))
                return 200, {"ok": True, "orders": [json.loads(row[0]) for row in rows]}
            if action == "ledger" and len(parts) == 5 and parts[3] == "page":
                require(re.fullmatch(r"[0-9]{1,16}", parts[4]), "invalid_cursor", "记录游标无效。")
                cursor = int(parts[4])
                rows = db.execute("SELECT id,currency,amount,balance,event,created FROM shop_ledger WHERE owner=? AND (?=0 OR id<?) ORDER BY id DESC LIMIT 21", (owner, cursor, cursor)).fetchall()
                return 200, {"ok": True, "ledger": [dict(row) for row in rows[:20]], "next_cursor": rows[19][0] if len(rows) > 20 else None}
            if action == "ledger" and len(parts) == 3:
                rows = db.execute("SELECT currency,amount,balance,event,created FROM shop_ledger WHERE owner=? ORDER BY id DESC LIMIT 100", (owner,))
                return 200, {"ok": True, "ledger": [dict(row) for row in rows]}
        require(method == "POST" and len(parts) == 3, "not_found", "商城操作不存在。", 404)
        if action not in ("orders", "redeem"):
            self.shop_account(db, identity, body)
        if action == "orders":
            obj(body, {"request_id", "session_id", "sku", "quantity", "catalog_hash", "expected_total"}, {"request_id", "session_id", "sku", "quantity", "catalog_hash", "expected_total"})
            request_id = body["request_id"]
            fingerprint = digest(dumps(body))
            old = db.execute("SELECT fingerprint,document FROM shop_orders WHERE owner=? AND request_id=?", (owner, request_id)).fetchone()
            if old:
                require(old[0] == fingerprint, "request_id_conflict", "订单请求内容已变化。", 409)
                return 200, {"ok": True, "order": json.loads(old[1])}
            self.shop_account(db, identity, body)
            require(not self.shop_control(db, "paused", False), "shop_paused", "商城购买暂时维护。", 503)
            require(body["catalog_hash"] == catalog["hash"], "catalog_changed", "商品目录已更新，请重新确认。", 409)
            require(type(body["quantity"]) is int and body["quantity"] == 1, "invalid_quantity", "永久商品每次只能购买一份。")
            product = next((self.shop_product(db, item) for item in catalog["products"] if item["id"] == body["sku"]), None)
            require(product and self.shop_available(db, owner, product), "product_unavailable", "商品已下架或不在活动期间。", 409)
            total, missing = self.shop_quote(product, set(self.shop_owned(db, owner)), catalog)
            require(missing, "already_owned", "已经拥有该商品。", 409)
            require(type(body["expected_total"]) is int and body["expected_total"] == total, "price_changed", "价格或套装内容已变化，请重新确认。", 409)
            integer(total, 1, MAX_BALANCE, "total")
            stock = product.get("stock")
            if stock is not None:
                count = db.execute("SELECT COUNT(*) FROM shop_orders WHERE json_extract(document,'$.sku')=?", (product["id"],)).fetchone()[0]
                require(count < stock, "sold_out", "商品已售罄。", 409)
            order_id = "so_" + secrets.token_hex(12)
            self.shop_money(db, owner, "RP", -total, order_id)
            for entitlement in missing:
                db.execute("INSERT INTO shop_grants VALUES(?,?,?,1)", (owner, entitlement, order_id))
            order = {"id": order_id, "sku": product["id"], "name": product["name"], "currency": "RP", "total": total,
                     "grants": missing, "status": "completed", "created_at": self.clock(), "catalog_hash": catalog["hash"]}
            db.execute("INSERT INTO shop_orders VALUES(?,?,?,?,?)", (order_id, owner, request_id, fingerprint, dumps(order)))
            return 201, dict(ok=True, order=order, **self.shop_state(db, owner))
        if action == "equipment":
            obj(body, {"request_id", "session_id", "catalog_hash", "slots"}, {"request_id", "session_id", "catalog_hash", "slots"})
            require(not self.shop_control(db, "equipment_paused", False), "equipment_paused", "装扮功能暂时维护。", 503)
            require(body["catalog_hash"] == catalog["hash"], "catalog_changed", "请更新装扮资源。", 409)
            obj(body["slots"], {"clothes", "hat", "hair", "frame", "title", "palette"})
            owned = set(self.shop_owned(db, owner))
            for slot, key in body["slots"].items():
                require(isinstance(key, str) and key in owned and catalog["entitlements"].get(key, {}).get("slot") == slot, "entitlement_required", "尚未拥有此装扮。", 403)
            current = self.shop_equipped(db, owner)
            revision = current["revision"] + (body["slots"] != current["slots"])
            db.execute("INSERT OR REPLACE INTO shop_equipment VALUES(?,?,?)", (owner, dumps(body["slots"]), revision))
            # Existing map presence must stop showing revoked or superseded clothes.
            db.execute("DELETE FROM world_presence WHERE owner=?", (owner,))
            return 200, {"ok": True, "equipment": self.shop_equipped(db, owner)}
        if action == "redeem":
            obj(body, {"request_id", "session_id", "code"}, {"request_id", "session_id", "code"})
            code = string(body["code"], 12, 80, "code", r"[A-Za-z0-9-]+").upper()
            code_hash = digest(code)
            old = db.execute("SELECT document FROM shop_redemptions WHERE owner=? AND code_hash=?", (owner, code_hash)).fetchone()
            if old:
                return 200, dict(ok=True, redemption=json.loads(old[0]), **self.shop_state(db, owner))
            self.shop_account(db, identity, body)
            # Rejections roll back transactions. Count failures separately in Store
            # before dispatch so rejected guesses cannot evade this rate limit.
            self.shop_code_limit(owner)
            row = db.execute("SELECT * FROM shop_codes WHERE hash=?", (code_hash,)).fetchone()
            require(row and row["expires"] > self.clock() and row["uses"] < row["maximum"] and row["target"] in (None, owner), "code_unavailable", "兑换码无效、已用完或已过期。", 409)
            event = "redeem:" + code_hash
            self.shop_money(db, owner, row["currency"], row["amount"], event)
            receipt = {"currency": row["currency"], "amount": row["amount"], "batch": row["batch"], "created_at": self.clock()}
            db.execute("INSERT INTO shop_redemptions VALUES(?,?,?)", (owner, code_hash, dumps(receipt)))
            db.execute("UPDATE shop_codes SET uses=uses+1 WHERE hash=?", (code_hash,))
            return 200, dict(ok=True, redemption=receipt, **self.shop_state(db, owner))
        require(False, "not_found", "商城操作不存在。", 404)

    def shop_code_limit(self, owner):
        if not hasattr(self, "shop_guesses"):
            self.shop_guesses = {}
        now = self.clock()
        self.shop_guesses = {key: times for key, times in self.shop_guesses.items() if times and times[-1] > now - 300}
        times = [t for t in self.shop_guesses.get(owner, []) if t > now - 300]
        require(len(times) < 10 and len(self.shop_guesses) < 10000, "code_rate_limited", "兑换尝试过多，请五分钟后重试。", 429)
        self.shop_guesses[owner] = times + [now]

    def shop_admin(self, actor, action, reference, data):
        """Offline CLI wrapper. Web operations use the same transactional body."""
        with self.lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            return self.shop_admin_in_transaction(db, actor, action, reference, data)

    def shop_admin_in_transaction(self, db, actor, action, reference, data):
        """Caller must authorize the administrator and own the write transaction."""
        require(db.in_transaction, "transaction_required", "An economic write transaction is required", 409)
        string(actor, 1, 80, "actor")
        string(reference, 1, 100, "reference")
        audit = dict(data)
        if action == "code" and isinstance(audit.get("code"), str):
            audit["code"] = "sha256:" + digest(audit["code"].upper())
        old = db.execute("SELECT document FROM shop_audit WHERE actor=? AND action=? AND reference=?", (actor, action, reference)).fetchone()
        if old:
            require(json.loads(old[0]) == audit, "admin_conflict", "管理事件编号已用于其他内容。", 409)
            return {"ok": True, "replayed": True}
        if action == "credit":
            obj(data, {"owner", "currency", "amount", "reason"}, {"owner", "currency", "amount", "reason"})
            require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (data["owner"],)).fetchone(), "account_required", "账号不存在。", 404)
            string(data["reason"], 1, 200, "reason")
            self.shop_money(db, data["owner"], data["currency"], data["amount"], "admin:" + actor + ":" + reference)
        elif action == "code":
            obj(data, {"code", "currency", "amount", "expires", "maximum", "target", "batch"}, {"code", "currency", "amount", "expires", "maximum", "batch"})
            code = string(data["code"], 12, 80, "code", r"[A-Za-z0-9-]+").upper()
            require(data["currency"] in ("RP", "MARKET"), "invalid_currency", "货币无效。")
            integer(data["amount"], 1, MAX_BALANCE, "amount")
            integer(data["maximum"], 1, 100000, "maximum")
            require(type(data["expires"]) in (int, float) and self.clock() < data["expires"] <= 4102444800, "invalid_expiry", "有效期无效。")
            string(data["batch"], 1, 80, "batch")
            require(not db.execute("SELECT 1 FROM shop_codes WHERE hash=?", (digest(code),)).fetchone(), "code_exists", "兑换码已存在。", 409)
            if data.get("target"):
                require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (data["target"],)).fetchone(), "account_required", "目标账号不存在。")
            db.execute("INSERT INTO shop_codes VALUES(?,?,?,?,0,?,?,?)", (digest(code), data["amount"], data["currency"], data["expires"], data["maximum"], data.get("target"), data["batch"]))
        elif action == "control":
            obj(data, {"key", "value"}, {"key", "value"})
            key, value = data["key"], data["value"]
            if key in ("paused", "equipment_paused", "market_paused"):
                require(type(value) is bool, "invalid_control", "维护开关必须为布尔值。")
            else:
                require(isinstance(key, str) and key.startswith("sku:") and any(p["id"] == key[4:] for p in self.shop_catalog()["products"]), "invalid_control", "未知商品。")
                obj(value, {"enabled", "price", "starts_at", "ends_at", "stock", "audience"})
                for name in ("price", "stock"):
                    if name in value:
                        integer(value[name], 1, MAX_BALANCE, name)
                if "enabled" in value:
                    require(type(value["enabled"]) is bool, "invalid_control", "上架状态无效。")
                for name in ("starts_at", "ends_at"):
                    if name in value:
                        integer(value[name], 0, 4102444800, name)
                if "audience" in value:
                    require(isinstance(value["audience"], list) and len(value["audience"]) <= 1000 and all(isinstance(x, str) and re.fullmatch(r"p_[a-f0-9]{24}", x) for x in value["audience"]), "invalid_control", "灰度账号无效。")
            db.execute("INSERT OR REPLACE INTO shop_controls VALUES(?,?)", (key, dumps(value)))
        elif action == "refund":
            obj(data, {"order_id", "reason"}, {"order_id", "reason"})
            string(data["reason"], 1, 200, "reason")
            row = db.execute("SELECT owner,document FROM shop_orders WHERE id=?", (data["order_id"],)).fetchone()
            require(row, "order_not_found", "订单不存在。", 404)
            order = json.loads(row[1])
            require(order["status"] == "completed", "already_refunded", "订单已退款。", 409)
            self.shop_money(db, row[0], "RP", order["total"], "refund:" + order["id"])
            db.execute("UPDATE shop_grants SET active=0 WHERE owner=? AND order_id=?", (row[0], order["id"]))
            order.update(status="refunded", refunded_at=self.clock(), refund_reason=data["reason"])
            db.execute("UPDATE shop_orders SET document=? WHERE id=?", (dumps(order), order["id"]))
            db.execute("DELETE FROM world_presence WHERE owner=?", (row[0],))
        else:
            require(False, "invalid_admin_action", "未知管理操作。")
        # Store only a digest of redeem secrets in the audit record.
        db.execute("INSERT INTO shop_audit(actor,action,reference,document,created) VALUES(?,?,?,?,?)", (actor, action, reference, dumps(audit), self.clock()))
        return {"ok": True}

    def market_expire(self, db):
        for row in db.execute("SELECT id,asset_id FROM market_listings WHERE status='active' AND expires<=?", (self.clock(),)).fetchall():
            db.execute("UPDATE market_listings SET status='expired' WHERE id=?", (row["id"],))
            db.execute("DELETE FROM asset_locks WHERE asset_id=? AND reference=?", (row["asset_id"], "market:" + row["id"]))

    def market_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        self.shop_account(db, identity)
        self.market_expire(db)
        if method == "GET":
            if len(parts) == 7 and parts[2] in ("listings", "mine") and parts[3] == "page":
                require(re.fullmatch(r"[0-9]{1,6}", parts[4]) and parts[5] in ("recent", "low", "high") and re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", parts[6]), "invalid_page", "筛选或页码无效。")
                offset, order, species = int(parts[4]), parts[5], parts[6]
                clause = "owner=?" if parts[2] == "mine" else "status='active'"
                params = [owner] if parts[2] == "mine" else []
                if species != "_":
                    clause += " AND instr(upper(json_extract(document,'$.snapshot.species')),?)>0"
                    params.append(species.upper())
                sorting = {"recent": "rowid DESC", "low": "price ASC,rowid DESC", "high": "price DESC,rowid DESC"}[order]
                rows = db.execute("SELECT * FROM market_listings WHERE " + clause + " ORDER BY " + sorting + " LIMIT 21 OFFSET ?", params + [offset]).fetchall()
                listings = []
                for row in rows[:20]:
                    document = json.loads(row["document"])
                    document.update(status=row["status"], price=row["price"], expires_at=row["expires"], mine=row["owner"] == owner)
                    listings.append(document)
                return 200, {"ok": True, "listings": listings, "next_offset": offset + 20 if len(rows) > 20 else None, "wallet": self.shop_wallet(db, owner, "MARKET")}
            require(len(parts) == 3 and parts[2] in ("listings", "mine", "history"), "not_found", "交易所入口不存在。", 404)
            if parts[2] == "history":
                rows = db.execute("SELECT document FROM market_receipts WHERE owner=? ORDER BY rowid DESC LIMIT 100", (owner,))
                return 200, {"ok": True, "receipts": [json.loads(row[0]) for row in rows]}
            mine = parts[2] == "mine"
            rows = db.execute("SELECT * FROM market_listings WHERE owner=? ORDER BY rowid DESC LIMIT 100" if mine else "SELECT * FROM market_listings WHERE status='active' ORDER BY rowid DESC LIMIT 100", (owner,) if mine else ())
            listings = []
            for row in rows:
                document = json.loads(row["document"])
                document.update(status=row["status"], price=row["price"], expires_at=row["expires"], mine=row["owner"] == owner)
                listings.append(document)
            return 200, {"ok": True, "listings": listings, "wallet": self.shop_wallet(db, owner, "MARKET")}
        require(method == "POST", "not_found", "交易所操作不存在。", 404)
        require(parts[2:3] == ["cancel"] or not self.shop_control(db, "market_paused", False), "market_paused", "交易所新增操作暂时维护。", 503)
        fingerprint = digest(dumps({"path": parts, "body": body}))
        old = db.execute("SELECT fingerprint,document FROM market_receipts WHERE owner=? AND request_id=?", (owner, body["request_id"])).fetchone()
        if old:
            require(old[0] == fingerprint, "request_id_conflict", "请求内容已变化。", 409)
            return 200, {"ok": True, "receipt": json.loads(old[1])}
        self.shop_account(db, identity, body)
        if parts == ["v1", "market", "listings"]:
            obj(body, {"request_id", "session_id", "asset_id", "price"}, {"request_id", "session_id", "asset_id", "price"})
            price = integer(body["price"], 1, MAX_BALANCE, "price")
            require(db.execute("SELECT COUNT(*) FROM market_listings WHERE owner=? AND status='active'", (owner,)).fetchone()[0] < 10, "listing_limit", "最多同时上架十件。", 409)
            listing_id = "ml_" + secrets.token_hex(12)
            asset = self.lock_asset(db, body["asset_id"], owner, "market:" + listing_id)
            # Publish only the existing approved public snapshot projection.
            snapshot = {key: copy.deepcopy(value) for key, value in asset["snapshot"].items()
                        if key in {"version", "species", "level", "form", "moves", "ability", "ability2", "shiny", "appearance", "iv", "ev", "nature", "item"}}
            snapshot.get("appearance", {}).pop("head_nickname", None)
            document = {"id": listing_id, "asset_id": asset["id"], "snapshot": snapshot, "currency": "MARKET", "created_at": self.clock()}
            db.execute("INSERT INTO market_listings VALUES(?,?,?,?,'active',?,?)", (listing_id, owner, asset["id"], price, self.clock() + 7 * 86400, dumps(document)))
            receipt = {"kind": "listed", "listing_id": listing_id, "asset_id": asset["id"], "price": price}
        else:
            require(len(parts) == 4 and parts[2] in ("buy", "cancel"), "not_found", "交易所操作不存在。", 404)
            obj(body, {"request_id", "session_id", "expected_price"}, {"request_id", "session_id"})
            row = db.execute("SELECT * FROM market_listings WHERE id=?", (parts[3],)).fetchone()
            require(row and row["status"] == "active", "listing_unavailable", "挂牌已成交、撤回或到期。", 409)
            if parts[2] == "cancel":
                require(row["owner"] == owner, "not_owner", "只能撤回自己的挂牌。", 403)
                db.execute("DELETE FROM asset_locks WHERE asset_id=? AND reference=?", (row["asset_id"], "market:" + row["id"]))
                status = "cancelled"
            else:
                require(row["owner"] != owner, "own_listing", "不能购买自己的挂牌。", 409)
                require(type(body.get("expected_price")) is int and body["expected_price"] == row["price"], "price_changed", "请重新确认挂牌价格。", 409)
                self.shop_money(db, owner, "MARKET", -row["price"], "buy:" + row["id"])
                self.shop_money(db, row["owner"], "MARKET", row["price"], "sell:" + row["id"])
                self.transfer_asset(db, row["asset_id"], row["owner"], owner, "market:" + row["id"])
                status = "sold"
                seller_receipt = {"kind": "sold", "listing_id": row["id"], "asset_id": row["asset_id"], "price": row["price"], "created_at": self.clock()}
                db.execute("INSERT INTO market_receipts VALUES(?,?,?,?)", (row["owner"], "sold_" + row["id"], fingerprint, dumps(seller_receipt)))
            db.execute("UPDATE market_listings SET status=? WHERE id=?", (status, row["id"]))
            receipt = {"kind": "purchased" if status == "sold" else status, "listing_id": row["id"], "asset_id": row["asset_id"], "price": row["price"]}
        receipt["created_at"] = self.clock()
        db.execute("INSERT INTO market_receipts VALUES(?,?,?,?)", (owner, body["request_id"], fingerprint, dumps(receipt)))
        return 200, {"ok": True, "receipt": receipt}
