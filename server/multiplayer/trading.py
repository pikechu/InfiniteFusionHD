"""Managed Pokemon marketplace and versioned, two-step barter sessions.

No local save import and no client-side mint/credit endpoint. All methods run
inside the same Store transaction as the idempotent operation receipt.
"""
import copy
import json
import re
import secrets
from pathlib import Path
try:
    from .inventory import InventoryFeatures, bind_api as bind_inventory_api
except ImportError:
    from inventory import InventoryFeatures, bind_api as bind_inventory_api


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "boolean", "dumps", "digest", "validate_compatibility", "STATS", "APIError"):
        globals()[name] = api[name]
    bind_inventory_api(api)


class TradingFeatures(InventoryFeatures):
    def init_trading(self, db):
        self.catalog_history_path = Path(__file__).parent / 'catalog-asset-history-v1.json'
        self.init_economy(db)
        self.init_inventory(db)
        db.executescript("""
            CREATE TABLE IF NOT EXISTS market_listings(id TEXT PRIMARY KEY,seller TEXT NOT NULL,asset_id TEXT NOT NULL,status TEXT NOT NULL,price INTEGER NOT NULL,fee INTEGER NOT NULL,revision INTEGER NOT NULL,created REAL NOT NULL,expires REAL NOT NULL,species TEXT NOT NULL,level INTEGER NOT NULL,nature TEXT NOT NULL,shiny INTEGER NOT NULL,iv_total INTEGER NOT NULL,snapshot TEXT NOT NULL,document TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS market_search ON market_listings(status,price,id);
            CREATE INDEX IF NOT EXISTS market_species ON market_listings(status,species,price);
            CREATE INDEX IF NOT EXISTS market_seller ON market_listings(seller,status);
            CREATE INDEX IF NOT EXISTS market_expiry ON market_listings(status,expires);
            CREATE TABLE IF NOT EXISTS market_orders(id TEXT PRIMARY KEY,listing_id TEXT UNIQUE NOT NULL,buyer TEXT NOT NULL,seller TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS trading_deliveries(id TEXT PRIMARY KEY,owner TEXT NOT NULL,event_id TEXT NOT NULL,asset_id TEXT NOT NULL,status TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL,UNIQUE(event_id,asset_id));
            CREATE INDEX IF NOT EXISTS deliveries_owner ON trading_deliveries(owner,status,created);
            CREATE TABLE IF NOT EXISTS exchange_sessions(id TEXT PRIMARY KEY,host TEXT NOT NULL,guest TEXT NOT NULL,status TEXT NOT NULL,expires REAL NOT NULL,idle REAL NOT NULL,document TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS exchange_host ON exchange_sessions(host,status);
            CREATE INDEX IF NOT EXISTS exchange_guest ON exchange_sessions(guest,status);
            CREATE TABLE IF NOT EXISTS trading_events(id TEXT NOT NULL,owner TEXT NOT NULL,kind TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL,PRIMARY KEY(id,owner));
            CREATE INDEX IF NOT EXISTS trading_history ON trading_events(owner,created,id);
            CREATE TABLE IF NOT EXISTS trading_preferences(owner TEXT PRIMARY KEY,document TEXT NOT NULL);
        """)

    def trading_account(self, db, owner, writing=False):
        require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (owner,)).fetchone() is not None, "account_required", "Please log in to a registered online account", 403)
        if writing:
            require(db.execute("SELECT value FROM economy_meta WHERE name='enabled'").fetchone()[0] == "true", "trading_paused", "New trading operations are temporarily paused", 503)

    def trading_preferences(self, db, owner):
        row = db.execute('SELECT document FROM trading_preferences WHERE owner=?',(owner,)).fetchone()
        return json.loads(row[0]) if row else {'allow_nearby':True,'allow_friend':True,'blocked_ids':[]}

    def preferences_request(self, db, owner, method, body):
        settings = self.trading_preferences(db,owner)
        if method == 'POST':
            obj(body,{'request_id','allow_nearby','allow_friend','block_friend_code','unblock_friend_code'},{'request_id'})
            for key in ('allow_nearby','allow_friend'):
                if key in body:
                    settings[key] = boolean(body[key],key)
            for action in ('block_friend_code','unblock_friend_code'):
                if action in body:
                    code = string(body[action],8,8,action,r'[A-Fa-f0-9]+').upper()
                    target = db.execute('SELECT id FROM identities WHERE friend_code=?',(code,)).fetchone()
                    require(target is not None and target[0]!=owner,'invalid_target','Choose another trainer friend code',404)
                    blocked = settings['blocked_ids']
                    if action=='block_friend_code' and target[0] not in blocked:
                        require(len(blocked)<100,'block_limit','At most one hundred blocked trainers',409)
                        blocked.append(target[0])
                    elif action=='unblock_friend_code' and target[0] in blocked:
                        blocked.remove(target[0])
            db.execute('INSERT OR REPLACE INTO trading_preferences VALUES(?,?)',(owner,dumps(settings)))
            for row in db.execute("SELECT id FROM exchange_sessions WHERE (host=? OR guest=?) AND status='invited'",(owner,owner)).fetchall():
                session = self.exchange_session(db,row[0])
                other = next(p for p in session['members'] if p!=owner)
                disabled = session['guest_id']==owner and not settings['allow_nearby' if session.get('invite_kind')=='nearby' else 'allow_friend']
                if other in settings['blocked_ids'] or disabled:
                    session.update(status='cancelled',reason='blocked')
                    self.release_exchange(db,session)
                    self.save_exchange(db,session)
        blocked = []
        for target_id in settings['blocked_ids']:
            row = db.execute('SELECT friend_code,nickname FROM identities WHERE id=?',(target_id,)).fetchone()
            if row:
                blocked.append(dict(row))
        return 200, {'ok':True,'preferences':{'allow_nearby':settings['allow_nearby'],'allow_friend':settings['allow_friend'],'blocked':blocked}}

    def trading_event(self, db, event_id, owners, kind, document):
        for owner in owners:
            db.execute("INSERT INTO trading_events VALUES(?,?,?,?,?)", (event_id, owner, kind, dumps(document), self.clock()))

    def trading_compatibility(self, compatibility):
        compatibility = validate_compatibility(compatibility)
        self.catalog(compatibility)
        return compatibility

    def asset_contract(self, catalog):
        compatibility = catalog['compatibility']
        # UI/source build hashes are deliberately excluded from the immutable
        # asset contract; compiled mechanics data, Mods and schema remain bound.
        data = catalog.get('data_files') or {'templates': digest(dumps(catalog['pokemon']))}
        return digest(dumps({'schema':1,'game_version':compatibility['game_version'],'mods_hash':compatibility['mods_hash'],'rules_version':compatibility['rules_version'],'data_files':data}))

    def asset_origin_catalog(self, asset, current):
        candidates = [current]
        if self.catalog_history_path.is_file():
            history = json.loads(self.catalog_history_path.read_text(encoding='utf-8-sig'))
            require(history.get('version') == 1 and type(history.get('catalogs')) is list and len(history['catalogs']) <= 16, 'catalog_history_invalid', 'Installed asset history is invalid', 503)
            candidates += history['catalogs']
        return next((candidate for candidate in candidates if digest(dumps(candidate)) == asset.get('catalog_hash')), None)

    def trading_asset(self, db, asset_id, owner, compatibility):
        asset = self.asset(db, asset_id, owner)
        require(asset.get("source") == "server_catalog" and asset.get("catalog_version") == 1, "untrusted_asset", "Only server-managed assets can be traded", 409)
        catalog = self.catalog(compatibility)
        expected = self.asset_contract(catalog)
        if 'asset_rules_hash' not in asset:
            origin = self.asset_origin_catalog(asset, catalog)
            if origin is not None:
                asset['asset_rules_hash'] = self.asset_contract(origin)
            else:
                require(asset['snapshot'] in catalog['pokemon'], 'asset_incompatible', 'Older asset needs an explicit catalog migration', 409)
                asset['asset_rules_hash'] = expected
        require(asset['asset_rules_hash'] == expected, 'asset_incompatible', 'Asset mechanics data require an explicit migration', 409)
        if asset.get('compatibility') != compatibility or 'issued_compatibility' not in asset:
            asset.setdefault('issued_compatibility', copy.deepcopy(asset.get('compatibility', compatibility)))
            asset['compatibility'] = copy.deepcopy(compatibility)
        db.execute('UPDATE hosted_assets SET document=? WHERE id=?', (dumps(asset),asset_id))
        return asset

    def new_delivery(self, db, owner, asset_id, event_id, reason):
        delivery_id = "del_" + secrets.token_hex(16)
        document = {"id": delivery_id, "owner_id": owner, "asset_id": asset_id, "event_id": event_id, "reason": reason, "status": "pending", "created_at": self.clock()}
        db.execute("INSERT INTO trading_deliveries VALUES(?,?,?,?,?,?,?)", (delivery_id, owner, event_id, asset_id, "pending", dumps(document), self.clock()))
        db.execute("INSERT INTO asset_locks VALUES(?,?)", (asset_id, "delivery:" + delivery_id))
        return document

    def close_listing(self, db, listing, status):
        if listing["status"] != "active":
            return listing
        require(status in ("cancelled", "expired"), "invalid_status", "Invalid listing close state")
        if listing.get('kind') == 'item':
            return self.close_item_listing(db,listing,status)
        asset = self.asset(db, listing["asset_id"], listing["seller_id"])
        lock = db.execute("SELECT reference FROM asset_locks WHERE asset_id=?", (asset["id"],)).fetchone()
        require(lock and lock[0] == "market:" + listing["id"], "asset_lock_lost", "Listing asset lock needs inspection", 409)
        db.execute("DELETE FROM asset_locks WHERE asset_id=?", (asset["id"],))
        listing["status"], listing["revision"] = status, listing["revision"] + 1
        delivery = self.new_delivery(db, listing["seller_id"], asset["id"], status + "_" + listing["id"], status)
        listing["delivery_id"] = delivery["id"]
        self.save_listing(db, listing)
        self.trading_event(db, status + "_" + listing["id"], [listing["seller_id"]], status, listing)
        return listing

    def save_listing(self, db, listing):
        db.execute("UPDATE market_listings SET status=?,revision=?,document=? WHERE id=?", (listing["status"], listing["revision"], dumps(listing), listing["id"]))

    def market_listing(self, db, listing_id, upgrade=True):
        string(listing_id, 1, 80, "listing_id", r"[A-Za-z0-9_-]+")
        row = db.execute("SELECT document FROM market_listings WHERE id=?", (listing_id,)).fetchone()
        require(row is not None, "listing_not_found", "Listing does not exist", 404)
        listing = json.loads(row[0])
        if listing["status"] == "active" and self.clock() >= listing["expires_at"]:
            self.close_listing(db, listing, "expired")
        elif listing['status'] == 'active' and upgrade:
            current = self.catalog()
            if listing['compatibility'] != current['compatibility']:
                try:
                    if listing.get('kind') == 'item':
                        require(listing.get('asset_rules_hash') == self.asset_contract(current), 'asset_incompatible', 'Item mechanics changed; cancel and migrate this listing', 409)
                        self.inventory_item(listing['item_id'],current['compatibility'])
                    else:
                        asset = self.trading_asset(db,listing['asset_id'],listing['seller_id'],current['compatibility'])
                        require(asset['snapshot'] == listing['snapshot'],'offer_changed','Listed asset changed',409)
                except APIError as error:
                    if error.code not in ('asset_incompatible','item_not_tradeable'):
                        raise
                    listing['reason'] = 'asset_contract_changed'
                    self.close_listing(db,listing,'cancelled')
                    return listing
                listing.update(compatibility=current['compatibility'],revision=listing['revision']+1)
                self.save_listing(db,listing)
        return listing

    def save_exchange(self, db, session):
        db.execute("INSERT OR REPLACE INTO exchange_sessions VALUES(?,?,?,?,?,?,?)", (session["id"], session["host_id"], session["guest_id"], session["status"], session["expires_at"], session["idle_until"], dumps(session)))

    def release_exchange(self, db, session):
        reference = "exchange:" + session["id"]
        db.execute("DELETE FROM asset_locks WHERE reference=?", (reference,))
        db.execute("DELETE FROM wallet_holds WHERE reference=?", (reference,))
        item_owners = [row[0] for row in db.execute('SELECT DISTINCT owner FROM item_holds WHERE reference=?',(reference,))]
        db.execute('DELETE FROM item_holds WHERE reference=?',(reference,))
        for owner in item_owners:
            self.touch_inventory(db,owner)

    def exchange_session(self, db, session_id):
        string(session_id, 1, 80, "session_id", r"[A-Za-z0-9_-]+")
        row = db.execute("SELECT document FROM exchange_sessions WHERE id=?", (session_id,)).fetchone()
        require(row is not None, "exchange_not_found", "Exchange does not exist", 404)
        session = json.loads(row[0])
        if session['status'] not in ('committed','cancelled','expired') and session['compatibility'] != self.catalog()['compatibility']:
            session.update(status='cancelled',reason='build_changed',revision=session['revision']+1,locked=[],confirmed=[])
            self.release_exchange(db,session)
            self.save_exchange(db,session)
        if session["status"] not in ("committed", "cancelled", "expired") and self.clock() >= min(session["expires_at"], session["idle_until"]):
            session["status"] = "expired"
            self.release_exchange(db, session)
            self.save_exchange(db, session)
        return session

    def tick_trading(self, db):
        for row in db.execute("SELECT id FROM market_listings WHERE status='active' AND expires<=? LIMIT 200", (self.clock(),)).fetchall():
            self.market_listing(db, row[0])
        for row in db.execute("SELECT id FROM exchange_sessions WHERE status NOT IN ('committed','cancelled','expired') AND (expires<=? OR idle<=?) LIMIT 200", (self.clock(), self.clock())).fetchall():
            self.exchange_session(db, row[0])

    def refresh_trading_lock(self, db, reference):
        if reference.startswith("market:"):
            self.market_listing(db, reference.split(":", 1)[1], upgrade=False)
        elif reference.startswith("exchange:"):
            self.exchange_session(db, reference.split(":", 1)[1])

    def market_search(self, db, body):
        obj(body, {"filters", "sort", "cursor"})
        filters = body.get("filters", {})
        obj(filters, {"category", "item_id", "species", "nature", "ability", "gender", "shiny", "min_level", "max_level", "min_price", "max_price", "iv_min", "iv_exact", "min_perfect", "head", "body", "fused"})
        sql, args = ["status='active'", "expires> ?"], [self.clock()]
        category = filters.get('category','pokemon')
        require(category in ('pokemon','item'),'invalid_category','Choose Pokemon or items')
        sql.append("COALESCE(json_extract(document,'$.kind'),'pokemon')=?")
        args.append(category)
        if 'item_id' in filters:
            string(filters['item_id'],1,80,'item_id',r'[A-Z0-9_]+')
            sql.append('species=?')
            args.append(filters['item_id'])
        for key in ("species", "nature"):
            if key in filters:
                value = string(filters[key], 1, 80, key, r"[A-Za-z0-9_]+")
                sql.append(key + "=?")
                args.append(value.upper())
        for key, column, operator, low, high in (("min_level", "level", ">=", 1, 100), ("max_level", "level", "<=", 1, 100), ("min_price", "price", ">=", 1, 9_999_999_999), ("max_price", "price", "<=", 1, 9_999_999_999)):
            if key in filters:
                sql.append(column + operator + "?")
                args.append(integer(filters[key], low, high, key))
        if "shiny" in filters:
            sql.append("shiny=?")
            args.append(int(boolean(filters["shiny"], "shiny")))
        for key, path, low, high in (("gender", "gender", 0, 2),):
            if key in filters:
                sql.append("json_extract(snapshot,'$." + path + "')=?")
                args.append(integer(filters[key], low, high, key))
        if "ability" in filters:
            value = string(filters["ability"], 1, 80, "ability", r"[A-Za-z0-9_]+")
            sql.append("(json_extract(snapshot,'$.ability')=? OR json_extract(snapshot,'$.ability2')=?)")
            args.extend([value.upper(), value.upper()])
        for key, operator in (("iv_min", ">="), ("iv_exact", "=")):
            values = filters.get(key, {})
            obj(values, STATS)
            for stat, value in values.items():
                sql.append("json_extract(snapshot,'$.iv." + stat + "')" + operator + "?")
                args.append(integer(value, 0, 31, key + "." + stat))
        if "min_perfect" in filters:
            sql.append("(" + "+".join("(json_extract(snapshot,'$.iv." + stat + "')=31)" for stat in sorted(STATS)) + ")>=?")
            args.append(integer(filters["min_perfect"], 0, 6, "min_perfect"))
        if "fused" in filters:
            sql.append("species " + ("GLOB" if boolean(filters["fused"], "fused") else "NOT GLOB") + " 'B[0-9]*H[0-9]*'")
        for key in ("head", "body"):
            if key in filters:
                value = integer(filters[key], 1, 10_000, key)
                sql.append("species GLOB ?")
                args.append("B*H" + str(value) if key == "head" else "B" + str(value) + "H*")
        order_key = body.get("sort", "price_asc")
        orders = {"price_asc": ("price", "ASC"), "price_desc": ("price", "DESC"), "newest": ("created", "DESC"), "expiring": ("expires", "ASC"), "level_desc": ("level", "DESC"), "iv_desc": ("iv_total", "DESC")}
        require(type(order_key) is str and order_key in orders, "invalid_sort", "Unsupported market sort")
        column, direction = orders[order_key]
        if body.get("cursor") is not None:
            cursor = body["cursor"]
            obj(cursor, {"id", "value", "sort", "query_hash"}, {"id", "value", "sort", "query_hash"})
            string(cursor["id"], 1, 80, "cursor.id", r"[A-Za-z0-9_-]+")
            require(type(cursor["value"]) in (int, float) and 0 <= cursor["value"] <= 9_999_999_999 and cursor["sort"] == order_key and cursor["query_hash"] == digest(dumps(filters)), "invalid_cursor", "Restart pagination after changing filters")
            operator = ">" if direction == "ASC" else "<"
            sql.append("(" + column + operator + "? OR (" + column + "=? AND id" + operator + "?))")
            args.extend([cursor["value"], cursor["value"], cursor["id"]])
        rows = db.execute("SELECT * FROM market_listings WHERE " + " AND ".join(sql) + " ORDER BY " + column + " " + direction + ",id " + direction + " LIMIT 21", args).fetchall()
        page = rows[:20]
        next_cursor = None
        if len(rows) > 20:
            last = page[-1]
            next_cursor = {"id": last["id"], "value": last[column], "sort": order_key, "query_hash": digest(dumps(filters))}
        return {"ok": True, "listings": [json.loads(row["document"]) for row in page], "next_cursor": next_cursor}

    def create_listing(self, db, owner, body):
        if body.get('kind') == 'item':
            return self.create_item_listing(db,owner,body)
        obj(body, {"request_id", "asset_id", "price", "compatibility"}, {"request_id", "asset_id", "price", "compatibility"})
        compatibility = self.trading_compatibility(body["compatibility"])
        price = integer(body["price"], 1, 9_999_999_999, "price")
        require(db.execute("SELECT COUNT(*) FROM market_listings WHERE seller=? AND status='active'", (owner,)).fetchone()[0] < 10, "listing_limit", "At most ten active listings per account", 409)
        asset = self.trading_asset(db, body["asset_id"], owner, compatibility)
        listing_id = "lst_" + secrets.token_hex(16)
        self.lock_asset(db, asset["id"], owner, "market:" + listing_id)
        fee = min(25000, max(100, (price * 2 + 99) // 100))
        self.post_money(db, "fee_" + listing_id, "listing_fee", {owner: -fee, "system:fees": fee}, {"listing_id": listing_id})
        snapshot = asset["snapshot"]
        listing = {"id": listing_id, "kind":"pokemon", "seller_id": owner, "asset_id": asset["id"], "asset_rules_hash":asset['asset_rules_hash'], "status": "active", "price": price, "fee": fee, "currency": "LINK", "revision": 1, "created_at": self.clock(), "expires_at": self.clock() + 7 * 86400, "snapshot": copy.deepcopy(snapshot), "compatibility": compatibility}
        db.execute("INSERT INTO market_listings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (listing_id, owner, asset["id"], "active", price, fee, 1, self.clock(), listing["expires_at"], snapshot["species"], snapshot["level"], snapshot["nature"], int(snapshot["shiny"]), sum(snapshot["iv"].values()), dumps(snapshot), dumps(listing)))
        self.trading_event(db, "listed_" + listing_id, [owner], "listed", listing)
        return 201, {"ok": True, "listing": listing, "wallet": self.wallet(db, owner)}

    def buy_listing(self, db, owner, listing, body):
        obj(body, {"request_id", "revision", "price", "compatibility"}, {"request_id", "revision", "price", "compatibility"})
        require(listing["status"] == "active", "listing_closed", "Listing has already sold, expired or been cancelled", 409)
        require(owner != listing["seller_id"], "own_listing", "Cannot purchase your own listing", 409)
        require(type(body["revision"]) is int and body["revision"] == listing["revision"] and type(body["price"]) is int and body["price"] == listing["price"], "listing_changed", "Inspect the current listing before purchasing", 409)
        require(self.trading_compatibility(body["compatibility"]) == listing["compatibility"], "asset_incompatible", "Listing and client versions differ", 409)
        if listing.get('kind') != 'item':
            self.trading_asset(db, listing["asset_id"], listing["seller_id"], listing["compatibility"])
        order_id = "ord_" + secrets.token_hex(16)
        self.post_money(db, order_id, "market_purchase", {owner: -listing["price"], listing["seller_id"]: listing["price"]}, {"listing_id": listing["id"]})
        if listing.get('kind') == 'item':
            delivery = self.buy_item_listing(db,owner,listing,order_id)
        else:
            self.transfer_asset(db, listing["asset_id"], listing["seller_id"], owner, "market:" + listing["id"])
            delivery = self.new_delivery(db, owner, listing["asset_id"], order_id, "purchase")
        order = {"id": order_id, "listing_id": listing["id"], "asset_id": listing["asset_id"], "buyer_id": owner, "seller_id": listing["seller_id"], "price": listing["price"], "currency": "LINK", "delivery_id": delivery["id"], "created_at": self.clock()}
        if listing.get('kind') == 'item':
            order.update(kind='item',item_id=listing['item_id'],quantity=listing['quantity'],unit_price=listing['unit_price'])
        listing.update(status="sold", revision=listing["revision"] + 1, order_id=order_id)
        self.save_listing(db, listing)
        db.execute("INSERT INTO market_orders VALUES(?,?,?,?,?,?)", (order_id, listing["id"], owner, listing["seller_id"], dumps(order), self.clock()))
        self.trading_event(db, order_id, [owner, listing["seller_id"]], "purchase", order)
        return 200, {"ok": True, "order": order, "delivery": delivery, "wallet": self.wallet(db, owner)}

    def exchange_hash(self, session):
        return digest(dumps({"revision": session["revision"], "offers": session["offers"], "compatibility": session["compatibility"]}))

    def exchange_request(self, db, owner, method, parts, body):
        if len(parts) == 2:
            if method == "GET":
                rows = db.execute("SELECT id FROM exchange_sessions WHERE (host=? OR guest=?) ORDER BY rowid DESC LIMIT 100", (owner, owner)).fetchall()
                return 200, {"ok": True, "exchanges": [self.exchange_session(db, row[0]) for row in rows]}
            obj(body, {"request_id", "friend_code", "target_id", "compatibility"}, {"request_id", "compatibility"})
            require(('friend_code' in body) != ('target_id' in body),'invalid_target','Choose a friend code or nearby player')
            if 'friend_code' in body:
                code = string(body['friend_code'],8,8,'friend_code',r'[A-Fa-f0-9]+').upper()
                target = db.execute('SELECT i.id,i.nickname,i.friend_code FROM identities i JOIN accounts a ON a.owner=i.id WHERE friend_code=?',(code,)).fetchone()
            else:
                target_id = string(body['target_id'],1,80,'target_id',r'[A-Za-z0-9_-]+')
                target = db.execute('SELECT i.id,i.nickname,i.friend_code FROM identities i JOIN accounts a ON a.owner=i.id WHERE i.id=?',(target_id,)).fetchone()
                presence = db.execute('SELECT map_key,document,updated FROM world_presence WHERE owner IN (?,?)',(owner,target_id)).fetchall()
                require(len(presence)==2 and presence[0]['map_key'] and presence[0]['map_key']==presence[1]['map_key'] and all(row['updated']>self.clock()-20 for row in presence),'not_nearby','Both players must be online on the same map',409)
                positions = [json.loads(row['document']) for row in presence]
                require(max(abs(positions[0]['x']-positions[1]['x']),abs(positions[0]['y']-positions[1]['y']))<=5,'not_nearby','Nearby trade requires a distance of at most five tiles',409)
                code = target['friend_code'] if target else ''
            require(target is not None and target["id"] != owner, "invalid_target", "Choose another registered online player", 404)
            preferences = self.trading_preferences(db,target['id'])
            require(owner not in preferences['blocked_ids'] and preferences['allow_nearby' if 'target_id' in body else 'allow_friend'],'invites_disabled','This trainer is not accepting this kind of invitation',403)
            recent = db.execute("SELECT COUNT(*) FROM exchange_sessions WHERE host=? AND json_extract(document,'$.created_at')>?",(owner,self.clock()-60)).fetchone()[0]
            require(recent<5,'invite_rate_limited','Please wait before inviting another trainer',429)
            compatibility = self.trading_compatibility(body["compatibility"])
            for participant in (owner, target["id"]):
                require(not db.execute("SELECT 1 FROM exchange_sessions WHERE (host=? OR guest=?) AND status NOT IN ('committed','cancelled','expired')", (participant, participant)).fetchone(), "exchange_pending", "A participant already has an open exchange", 409)
            session = {"id": "exc_" + secrets.token_hex(16), "host_id": owner, "guest_id": target["id"], "members": [owner, target["id"]], "friend_codes": {owner: db.execute("SELECT friend_code FROM identities WHERE id=?", (owner,)).fetchone()[0], target["id"]: code}, "status": "invited", "compatibility": compatibility, "revision": 1, "offers": {p: {"assets": [], "amount": 0} for p in (owner, target["id"])}, "locked": [], "confirmed": [], "created_at": self.clock(), "expires_at": self.clock() + 600, "idle_until": self.clock() + 30, "confirm_after": None}
            session['invite_kind'] = 'nearby' if 'target_id' in body else 'friend'
            self.save_exchange(db, session)
            return 201, {"ok": True, "exchange": session}
        session = self.exchange_session(db, parts[2])
        require(owner in session["members"], "not_member", "Exchange belongs to other players", 403)
        if method == "GET" and len(parts) == 3:
            return 200, {"ok": True, "exchange": session}
        require(method == "POST" and len(parts) == 4, "not_found", "Unknown exchange action", 404)
        action = parts[3]
        if action == "cancel":
            obj(body, {"request_id"}, {"request_id"})
            require(session["status"] != "committed", "exchange_committed", "Exchange was committed; recover its result", 409)
            if session["status"] not in ("cancelled", "expired"):
                session["status"] = "cancelled"
                self.release_exchange(db, session)
        else:
            self.trading_account(db, owner, True)
            require(session["status"] not in ("committed", "cancelled", "expired"), "exchange_closed", "Exchange is closed", 409)
            if action == "accept":
                obj(body, {"request_id", "compatibility"}, {"request_id", "compatibility"})
                require(owner == session["guest_id"] and session["status"] == "invited", "invalid_accept", "Only the invited player may accept", 409)
                require(self.trading_compatibility(body["compatibility"]) == session["compatibility"], "asset_incompatible", "Players have different data versions", 409)
                session["status"] = "offering"
            else:
                require(session["status"] in ("offering", "locked"), "exchange_not_accepted", "Wait for the other player to accept", 409)
                reference = "exchange:" + session["id"]
                if action == "offer":
                    obj(body, {"request_id", "asset_ids", "amount", "revision", "items"}, {"request_id", "asset_ids", "amount", "revision"})
                    require(type(body["revision"]) is int and body["revision"] == session["revision"], "offer_changed", "Inspect the new offer version", 409)
                    ids = body["asset_ids"]
                    require(type(ids) is list and len(ids) <= 6 and all(type(value) is str for value in ids) and len(set(ids)) == len(ids), "invalid_offer", "Choose at most six different managed assets")
                    assets = []
                    for asset_id in ids:
                        asset = self.trading_asset(db, asset_id, owner, session["compatibility"])
                        self.lock_asset(db, asset_id, owner, reference)
                        assets.append({"id": asset_id, "snapshot": copy.deepcopy(asset["snapshot"])})
                    for old in session["offers"][owner]["assets"]:
                        if old["id"] not in ids:
                            db.execute("DELETE FROM asset_locks WHERE asset_id=? AND reference=?", (old["id"], reference))
                    self.reserve_money(db, owner, reference, body["amount"])
                    session["offers"][owner] = {"assets": assets, "amount": body["amount"]}
                    items = body.get('items',{})
                    self.hold_items(db,owner,reference,items)
                    if items:
                        session['offers'][owner]['items'] = items
                    session.update(revision=session["revision"] + 1, locked=[], confirmed=[], status="offering", confirm_after=None)
                elif action in ("lock", "confirm"):
                    obj(body, {"request_id", "revision", "offer_hash"}, {"request_id", "revision", "offer_hash"})
                    require(type(body["revision"]) is int and body["revision"] == session["revision"] and body["offer_hash"] == self.exchange_hash(session), "offer_changed", "Inspect both current offers before confirming", 409)
                    require(any(offer["assets"] or offer["amount"] or offer.get('items') for offer in session["offers"].values()), "empty_exchange", "Both offers cannot be empty", 409)
                    if action == "lock":
                        if owner not in session["locked"]:
                            session["locked"].append(owner)
                        if len(session["locked"]) == 2 and session["status"] != "locked":
                            session.update(status="locked", confirm_after=self.clock() + 3)
                    else:
                        require(session["status"] == "locked" and len(session["locked"]) == 2 and self.clock() >= session["confirm_after"], "confirm_not_ready", "Both players must lock and review the offers for three seconds", 409)
                        if owner not in session["confirmed"]:
                            session["confirmed"].append(owner)
                        if len(session["confirmed"]) == 2:
                            self.commit_exchange(db, session)
                else:
                    raise APIError(404, "not_found", "Unknown exchange action")
            session["idle_until"] = min(session["expires_at"], self.clock() + 180)
        self.save_exchange(db, session)
        return 200, {"ok": True, "exchange": session, "wallet": self.wallet(db, owner)}

    def commit_exchange(self, db, session):
        reference = "exchange:" + session["id"]
        a, b = session["members"]
        for owner in (a, b):
            offer = session["offers"][owner]
            for item in offer["assets"]:
                asset = self.trading_asset(db, item["id"], owner, session["compatibility"])
                require(asset["snapshot"] == item["snapshot"], "offer_changed", "Managed asset changed after inspection", 409)
            hold = db.execute("SELECT amount FROM wallet_holds WHERE owner=? AND reference=?", (owner, reference)).fetchone()
            require((hold[0] if hold else 0) == offer["amount"], "money_hold_lost", "Exchange reserve differs from confirmed offer", 409)
            item_holds = {row[0]:row[1] for row in db.execute('SELECT item_id,quantity FROM item_holds WHERE owner=? AND reference=?',(owner,reference))}
            require(item_holds == offer.get('items',{}),'item_hold_lost','Exchange item reserves differ',409)
        transaction_id = "exc_tx_" + secrets.token_hex(16)
        db.execute("DELETE FROM wallet_holds WHERE reference=?", (reference,))
        db.execute('DELETE FROM item_holds WHERE reference=?',(reference,))
        net = session["offers"][b]["amount"] - session["offers"][a]["amount"]
        self.post_money(db, transaction_id, "direct_exchange", {a: net, b: -net}, {"exchange_id": session["id"], "offers": session["offers"]})
        item_changes = {}
        for item_id in set(session['offers'][a].get('items',{})) | set(session['offers'][b].get('items',{})):
            delta = session['offers'][b].get('items',{}).get(item_id,0)-session['offers'][a].get('items',{}).get(item_id,0)
            item_changes[a,item_id],item_changes[b,item_id] = delta,-delta
        if item_changes:
            self.post_items(db,transaction_id,'direct_exchange',item_changes,{'exchange_id':session['id']})
        for owner, recipient in ((a, b), (b, a)):
            for asset in session["offers"][owner]["assets"]:
                self.transfer_asset(db, asset["id"], owner, recipient, reference)
        session.update(status="committed", transaction_id=transaction_id, committed_at=self.clock())
        self.release_exchange(db, session)
        self.trading_event(db, transaction_id, [a, b], "exchange", session)

    def dispatch_trading(self, db, identity, method, parts, body):
        if parts[:2] not in (["v1", "market"], ["v1", "wallet"], ["v1", "exchanges"], ["v1", "deliveries"], ["v1", "trading"], ['v1','inventory']):
            return None
        owner = identity["id"]
        self.trading_account(db, owner)
        self.tick_trading(db)
        if parts == ['v1','trading','preferences'] and method in ('GET','POST'):
            return self.preferences_request(db,owner,method,body)
        if method == 'GET' and parts == ['v1','inventory']:
            return 200, {'ok':True,'inventory':self.inventory_view(db,owner)}
        if method == "GET" and parts == ["v1", "wallet"]:
            return 200, {"ok": True, "wallet": self.wallet(db, owner)}
        if method == "GET" and parts == ["v1", "market", "config"]:
            return 200, {"ok": True, "config": {"enabled": db.execute("SELECT value FROM economy_meta WHERE name='enabled'").fetchone()[0] == "true", "currency": "LINK", "max_listings": 10, "listing_days": 7, "fee_percent": 2, "fee_min": 100, "fee_max": 25000, "max_coins": 9_999_999_999, "source": "server_managed", "economy": "closed_beta"}}
        if parts[:2] == ["v1", "exchanges"]:
            if method == "POST" and len(parts) == 2:
                self.trading_account(db, owner, True)
            status, response = self.exchange_request(db, owner, method, parts, body)
            if "exchange" in response:
                response["exchange"]["offer_hash"] = self.exchange_hash(response["exchange"])
                response["exchange"]["server_time"] = self.clock()
            return status, response
        if parts == ["v1", "market", "search"] and method == "POST":
            return 200, self.market_search(db, body)
        if parts == ["v1", "market", "my-listings"] and method == "GET":
            rows = db.execute("SELECT document FROM market_listings WHERE seller=? ORDER BY (status='active') DESC,created DESC,id DESC LIMIT 100", (owner,)).fetchall()
            return 200, {"ok": True, "listings": [json.loads(row[0]) for row in rows]}
        if parts == ["v1", "market", "listings"]:
            if method == "GET":
                return 200, self.market_search(db, {})
            self.trading_account(db, owner, True)
            return self.create_listing(db, owner, body)
        if len(parts) in (4, 5) and parts[:3] == ["v1", "market", "listings"]:
            listing = self.market_listing(db, parts[3], upgrade=not(method == 'POST' and len(parts) == 5 and parts[4] == 'cancel'))
            if method == "GET" and len(parts) == 4:
                return 200, {"ok": True, "listing": listing}
            if method == "POST" and len(parts) == 5:
                if parts[4] == "buy":
                    self.trading_account(db, owner, True)
                    return self.buy_listing(db, owner, listing, body)
                if parts[4] == "cancel":
                    obj(body, {"request_id"}, {"request_id"})
                    require(listing["seller_id"] == owner, "not_owner", "Only the seller may cancel", 403)
                    require(listing["status"] != "sold", "listing_sold", "Listing was sold; recover its result", 409)
                    return 200, {"ok": True, "listing": self.close_listing(db, listing, "cancelled")}
        if parts == ["v1", "deliveries"] and method == "GET":
            rows = db.execute("SELECT document FROM trading_deliveries WHERE owner=? ORDER BY (status='pending') DESC,created DESC,id DESC LIMIT 200", (owner,)).fetchall()
            deliveries = [json.loads(row[0]) for row in rows]
            for delivery in deliveries:
                # Historical claims do not return mutable current-owner data.
                if delivery["status"] == "pending" and delivery.get('kind') != 'item':
                    delivery["asset"] = self.asset(db, delivery["asset_id"], owner)
            return 200, {"ok": True, "deliveries": deliveries}
        if len(parts) == 4 and parts[:2] == ["v1", "deliveries"] and parts[3] == "claim" and method == "POST":
            obj(body, {"request_id"}, {"request_id"})
            row = db.execute("SELECT document FROM trading_deliveries WHERE id=? AND owner=?", (parts[2], owner)).fetchone()
            require(row is not None, "delivery_not_found", "Delivery does not belong to this account", 404)
            delivery = json.loads(row[0])
            if delivery.get('kind') == 'item':
                return self.claim_item_delivery(db,owner,delivery)
            if delivery["status"] == "pending":
                self.asset(db, delivery["asset_id"], owner)
                lock = db.execute("SELECT reference FROM asset_locks WHERE asset_id=?", (delivery["asset_id"],)).fetchone()
                require(lock and lock[0] == "delivery:" + delivery["id"], "delivery_lock_lost", "Delivery asset needs inspection", 409)
                db.execute("DELETE FROM asset_locks WHERE asset_id=?", (delivery["asset_id"],))
                delivery.update(status="claimed", claimed_at=self.clock())
                db.execute("UPDATE trading_deliveries SET status='claimed',document=? WHERE id=?", (dumps(delivery), delivery["id"]))
                self.trading_event(db, "claimed_" + delivery["id"], [owner], "claimed", delivery)
            return 200, {"ok": True, "delivery": delivery}
        if parts == ["v1", "trading", "history"] and method == "GET":
            rows = db.execute("SELECT id,kind,document,created FROM trading_events WHERE owner=? ORDER BY created DESC,id DESC LIMIT 100", (owner,)).fetchall()
            return 200, {"ok": True, "events": [{"id": row["id"], "kind": row["kind"], "created_at": row["created"], "data": json.loads(row["document"])} for row in rows]}
        raise APIError(404, "not_found", "Unknown trading endpoint")
