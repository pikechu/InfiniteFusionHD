"""Installed catalog assets and durable third-release state machines.

The service module injects its strict JSON validators after defining them. This
keeps one validation contract without importing a second running service module
when service.py is launched as __main__.
"""
import copy
import json
import secrets
from pathlib import Path


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "boolean", "dumps", "digest", "validate_pokemon", "validate_trade_snapshot", "validate_runtime_state", "validate_compatibility", "APIError", "COMPATIBILITY", "RULES", "PROTOCOL"):
        globals()[name] = api[name]


class V3Features:
    def init_v3(self, db):
        self.catalog_path = Path(__file__).parent / "catalog-rental-v1.json"
        self.avatar_catalog_path = Path(__file__).parent / "catalog-card-avatars-v1.json"
        db.executescript("""
            CREATE TABLE IF NOT EXISTS pool_deposits(id TEXT PRIMARY KEY,owner TEXT NOT NULL,document TEXT NOT NULL,updated REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS hosted_assets(id TEXT PRIMARY KEY,owner TEXT NOT NULL,document TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS asset_locks(asset_id TEXT PRIMARY KEY,reference TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS halls(code TEXT PRIMARY KEY,document TEXT NOT NULL,updated REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS dungeons(id TEXT PRIMARY KEY,document TEXT NOT NULL,updated REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS replays(id TEXT PRIMARY KEY,document TEXT NOT NULL,updated REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS cards(owner TEXT PRIMARY KEY,document TEXT NOT NULL,updated REAL NOT NULL);
        """)
        # Upgrade existing route documents without resetting their progress or
        # granting another day whenever the coordinator restarts.
        for row in db.execute("SELECT document FROM dungeons").fetchall():
            self.expire_dungeon(db, json.loads(row["document"]))

    def catalog(self, compatibility=None):
        require(self.catalog_path.is_file(), "catalog_unavailable", "Install the game-validated server catalog first", 503)
        catalog = json.loads(self.catalog_path.read_text(encoding="utf-8-sig"))
        require(catalog.get("version") == 1 and type(catalog.get("pokemon")) is list and len(catalog["pokemon"]) >= 12, "catalog_invalid", "Installed catalog is incomplete", 503)
        validate_compatibility(catalog["compatibility"])
        for snapshot in catalog["pokemon"]:
            validate_pokemon(snapshot)
        if compatibility is not None:
            require(catalog["compatibility"] == compatibility, "catalog_incompatible", "Installed catalog does not match this client build", 409)
        return catalog

    def dispatch_v3(self, db, identity, method, parts, body):
        if parts[:2] == ["v1", "cards"]:
            return self.cards_request(db, identity, method, parts, body)
        if parts == ["v1", "showcases"] and method == "GET":
            return 200, {"ok": True, "showcases": self.owned_card_showcases(db, identity["id"])}
        if parts[:2] == ["v1", "collections"]:
            return self.collections_request(db, identity, method, parts, body)
        if parts[:3] == ["v1", "pool", "deposits"]:
            return self.pool_request(db, identity, method, parts, body)
        if parts[:2] == ["v1", "trades"]:
            hosted = len(parts) == 2 and body.get("source") == "server_managed"
            if len(parts) >= 3:
                row = db.execute("SELECT document FROM trades WHERE code=?", (parts[2].upper(),)).fetchone()
                hosted = bool(row and json.loads(row["document"])["source"] == "server_managed")
            if hosted:
                return self.hosted_trade_request(db, identity, method, parts, body)
        if parts[:2] == ["v1", "rooms"] and len(parts) == 4 and parts[3] in ("draft", "pick"):
            require(method == "POST", "not_found", "Rental mutations require POST", 404)
            return self.rental_request(db, identity, parts, body)
        if parts[:2] == ["v1", "halls"]:
            return self.hall_request(db, identity, method, parts, body)
        if parts[:2] == ["v1", "dungeons"]:
            return self.dungeon_request(db, identity, method, parts, body)
        if parts[:2] == ["v1", "replays"]:
            return self.replay_request(db, identity, method, parts, body)
        return None

    def card_avatar_catalog(self):
        require(self.avatar_catalog_path.is_file(), "avatar_catalog_unavailable", "Install the trusted TrainerType avatar catalog", 503)
        catalog = json.loads(self.avatar_catalog_path.read_text(encoding="utf-8-sig"))
        require(catalog.get("version") == 1 and type(catalog.get("avatars")) is list and type(catalog.get("default")) is str and catalog["default"] in catalog["avatars"], "avatar_catalog_invalid", "Installed TrainerType avatar catalog is invalid", 503)
        return catalog

    def owned_card_showcases(self, db, owner, codes=None):
        by_code = {}
        for row in db.execute("SELECT code,document FROM showcases WHERE owner=? AND active=1 ORDER BY updated DESC", (owner,)):
            document = json.loads(row["document"])
            if document.get("owner_id") != owner:
                continue
            if document.get("source") == "server_managed":
                asset = db.execute("SELECT owner FROM hosted_assets WHERE id=?", (document.get("asset_id"),)).fetchone()
                if asset is None or asset["owner"] != owner:
                    continue
            # Showcases already contain only the explicitly published projection;
            # no full private team snapshot is joined into card responses.
            by_code[row["code"]] = document
        ordered = list(by_code) if codes is None else codes
        return [copy.deepcopy(by_code[code]) for code in ordered if code in by_code]

    def card_view(self, db, identity):
        row = db.execute("SELECT document FROM cards WHERE owner=?", (identity["id"],)).fetchone()
        settings = json.loads(row["document"]) if row else {"avatar": self.card_avatar_catalog()["default"], "show_badges": False, "showcases": []}
        showcases = self.owned_card_showcases(db, identity["id"], settings["showcases"])
        badges = []
        if settings["show_badges"]:
            for row in db.execute("SELECT document FROM rewards WHERE owner=? ORDER BY rowid DESC", (identity["id"],)):
                reward = json.loads(row["document"])
                if reward.get("kind") not in ("boss_medal", "gym_medal", "dungeon_medal"):
                    continue
                badges.append({key: reward[key] for key in ("id", "kind", "boss_id", "gym_code", "dungeon_id") if key in reward})
                if len(badges) == 64:
                    break
        return {"id": identity["id"], "nickname": identity["nickname"], "friend_code": identity["friend_code"], "avatar": settings["avatar"], "show_badges": settings["show_badges"], "badges": badges, "showcases": showcases, "showcase_codes": [showcase["code"] for showcase in showcases], "capacity": 6}

    def cards_request(self, db, identity, method, parts, body):
        require(len(parts) == 3, "not_found", "Unknown trainer-card endpoint", 404)
        owner = identity["id"]
        if method == "GET":
            target = identity
            if parts[2] != "me":
                friend_code = string(parts[2], 8, 8, "friend_code", r"[A-Fa-f0-9]+")
                row = db.execute("SELECT id,nickname,friend_code FROM identities WHERE friend_code=?", (friend_code.upper(),)).fetchone()
                require(row is not None, "card_not_found", "Trainer friend code does not exist", 404)
                target = dict(row)
            return 200, {"ok": True, "card": self.card_view(db, target)}
        require(method == "POST" and parts[2] == "me", "not_found", "Only the current identity may update its card", 404)
        obj(body, {"request_id", "avatar", "show_badges", "showcases"}, {"request_id", "avatar", "show_badges", "showcases"})
        avatar = string(body["avatar"], 1, 80, "avatar", r"[A-Za-z_][A-Za-z0-9_]*")
        require(avatar in self.card_avatar_catalog()["avatars"], "avatar_unsupported", "Avatar is not in the installed trusted TrainerType catalog", 409)
        boolean(body["show_badges"], "show_badges")
        require(type(body["showcases"]) is list and len(body["showcases"]) <= 6, "invalid_card_showcases", "A trainer card has at most six showcase slots")
        codes = [string(code, 8, 8, "showcase_code", r"[A-Fa-f0-9]+").upper() for code in body["showcases"]]
        require(len(set(codes)) == len(codes), "duplicate_showcase", "A showcase cannot fill two card slots")
        available = {showcase["code"] for showcase in self.owned_card_showcases(db, owner)}
        require(set(codes) <= available, "showcase_not_owned", "Only active showcases currently owned by this identity may be selected", 403)
        settings = {"avatar": avatar, "show_badges": body["show_badges"], "showcases": codes}
        db.execute("INSERT OR REPLACE INTO cards VALUES(?,?,?)", (owner, dumps(settings), self.clock()))
        return 200, {"ok": True, "card": self.card_view(db, identity)}

    def asset(self, db, asset_id, owner=None):
        string(asset_id, 1, 80, "asset_id")
        row = db.execute("SELECT owner,document FROM hosted_assets WHERE id=?", (asset_id,)).fetchone()
        require(row is not None, "asset_not_found", "Hosted asset does not exist", 404)
        require(owner is None or row["owner"] == owner, "not_owner", "Hosted asset belongs to another identity", 403)
        return json.loads(row["document"])

    def lock_asset(self, db, asset_id, owner, reference):
        self.market_custody_guard(db,asset_id,owner,'inspect' if reference.startswith('mainline:') else 'trade')
        asset = self.asset(db, asset_id, owner)
        if not reference.startswith("mainline:"):
            require(self.mainline_assignment(db, asset_id) is None, "asset_in_party", "Move this asset to the online PC before trading", 409)
        old = self.refresh_asset_lock(db, asset_id)
        require(old is None or old["reference"] == reference, "asset_locked", "Hosted asset is already committed to another operation", 409)
        db.execute("INSERT OR REPLACE INTO asset_locks VALUES(?,?)", (asset_id, reference))
        return asset

    def refresh_asset_lock(self, db, asset_id):
        old = db.execute("SELECT reference FROM asset_locks WHERE asset_id=?", (asset_id,)).fetchone()
        if old and old["reference"].startswith("trade:"):
            self.trade_document(db, old["reference"].split(":", 1)[1])
        elif old and old["reference"].startswith("pool:"):
            self.deposit(db, old["reference"].split(":", 1)[1])
        elif old and old["reference"].startswith(("market:", "exchange:")):
            self.refresh_trading_lock(db, old["reference"])
        elif old and old["reference"].startswith("mainline:"):
            self.refresh_mainline_lock(db, old["reference"])
        elif old and old['reference'].startswith('contract:'):
            self.market_contract(db,old['reference'].split(':',1)[1])
        return db.execute("SELECT reference FROM asset_locks WHERE asset_id=?", (asset_id,)).fetchone()

    def transfer_asset(self, db, asset_id, old_owner, new_owner, reference):
        asset = self.asset(db, asset_id, old_owner)
        locked = db.execute("SELECT reference FROM asset_locks WHERE asset_id=?", (asset_id,)).fetchone()
        require(locked is not None and locked["reference"] == reference, "asset_lock_lost", "Hosted asset has no matching authority lock", 409)
        asset["owner_id"] = new_owner
        db.execute("UPDATE hosted_assets SET owner=?,document=? WHERE id=? AND owner=?", (new_owner, dumps(asset), asset_id, old_owner))
        db.execute("DELETE FROM asset_locks WHERE asset_id=?", (asset_id,))
        for row in db.execute("SELECT code,document FROM showcases WHERE owner=? AND active=1", (old_owner,)).fetchall():
            if json.loads(row["document"]).get("asset_id") == asset_id:
                db.execute("UPDATE showcases SET active=0,updated=? WHERE code=?", (self.clock(), row["code"]))
        return asset

    def collections_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        if method == "GET" and len(parts) == 2:
            assets = []
            for row in db.execute("SELECT document FROM hosted_assets WHERE owner=?", (owner,)):
                asset = json.loads(row["document"])
                lock = self.refresh_asset_lock(db, asset["id"])
                asset["locked"] = bool(lock)
                asset["lock_reference"] = lock["reference"] if lock else None
                custody=db.execute('SELECT contract_id,kind,expires FROM market_custody WHERE asset_id=?',(asset['id'],)).fetchone()
                if custody:asset.update(locked=True,lock_reference='custody:'+custody['contract_id'],custody=dict(custody))
                assigned = self.mainline_assignment(db, asset["id"])
                if assigned is not None:
                    asset.update(locked=True, lock_reference="party:" + assigned["character_id"], assigned_character=assigned["character_id"])
                assets.append(asset)
            return 200, {"ok": True, "assets": assets}
        require(method == "POST", "not_found", "Unknown collection endpoint", 404)
        if len(parts) == 3 and parts[2] == "starter":
            obj(body, {"request_id", "catalog_version"}, {"request_id", "catalog_version"})
            require(type(body["catalog_version"]) is int and body["catalog_version"] == 1, "catalog_version", "Unsupported installed catalog", 409)
            grant = db.execute("SELECT document FROM rewards WHERE owner=? AND scope='collection:starter'", (owner,)).fetchone()
            if grant:
                previous = json.loads(grant["document"])
                # Grant remains consumed if the original asset was traded away.
                asset = self.asset(db, previous["asset_id"])
                return 200, {"ok": True, "asset": asset, "already_granted": True}
            catalog = self.catalog()
            asset = {"id": "pkm_" + secrets.token_hex(16), "owner_id": owner, "snapshot": copy.deepcopy(catalog["pokemon"][0]), "source": "server_catalog", "catalog_version": 1, "catalog_hash": digest(dumps(catalog)), "created_at": self.clock()}
            db.execute("INSERT INTO hosted_assets VALUES(?,?,?)", (asset["id"], owner, dumps(asset)))
            self.claim_reward(db, owner, "collection:starter", {"kind": "hosted_starter_grant", "asset_id": asset["id"]})
            return 201, {"ok": True, "asset": asset, "already_granted": False}
        if len(parts) == 4 and parts[3] == "showcase":
            obj(body, {"request_id"}, {"request_id"})
            asset = self.asset(db, parts[2], owner)
            code = secrets.token_hex(4).upper()
            public = {key: copy.deepcopy(asset["snapshot"][key]) for key in ("version", "species", "level", "form", "moves", "ability", "ability2", "shiny", "appearance")}
            public["appearance"].pop("head_nickname", None)
            showcase = {"code": code, "owner_id": owner, "version": 1, "snapshot": public, "public_fields": [], "source": "server_managed", "asset_id": asset["id"]}
            db.execute("INSERT INTO showcases VALUES(?,?,?,?,?,?)", (code, owner, dumps(showcase), 1, 1, self.clock()))
            return 200, {"ok": True, "showcase": showcase}
        raise APIError(404, "not_found", "Unknown collection operation")

    def hosted_trade_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        if len(parts) == 2 and method == "POST":
            obj(body, {"request_id", "compatibility", "source"}, {"request_id", "compatibility", "source"})
            compat = validate_compatibility(body["compatibility"])
            self.check_free_trade(db, owner)
            code = secrets.token_hex(4).upper()
            while db.execute("SELECT 1 FROM trades WHERE code=?", (code,)).fetchone():
                code = secrets.token_hex(4).upper()
            trade = {"code": code, "host_id": owner, "members": {owner: {"id": owner, "nickname": identity["nickname"]}}, "compatibility": compat, "source": "server_managed", "status": "waiting", "revision": 1, "offers": {}, "confirmations": [], "transaction_id": None, "created_at": self.clock(), "expires_at": self.clock() + 86400}
            self.save_trade(db, trade)
            return 201, {"ok": True, "trade": self.trade_view(db, trade, owner)}
        trade = self.trade_document(db, parts[2])
        if trade["status"] == "expired":
            db.execute("DELETE FROM asset_locks WHERE reference=?", ("trade:" + trade["code"],))
        if method == "GET" and len(parts) == 3:
            return 200, {"ok": True, "trade": self.trade_view(db, trade, owner)}
        require(method == "POST" and len(parts) == 4, "not_found", "Unknown hosted exchange endpoint", 404)
        action = parts[3]
        if action in ("join", "ack"):
            # These transitions do not deserialize snapshots and share the V2
            # implementation (including receipt ownership and version checks).
            return self.trade_request(db, identity, method, parts, body)
        require(owner in trade["members"], "not_member", "Identity is not an exchange member", 403)
        require(trade["status"] in ("waiting", "offering"), "trade_closed", "Hosted exchange is already committed or closed", 409)
        if action in ("offer", "confirm"):
            require(trade["compatibility"]["protocol"] == PROTOCOL, "protocol_mismatch", "Cancel this older exchange before creating a new one", 409)
        if action == "cancel":
            obj(body, {"request_id"}, {"request_id"})
            trade["status"] = "cancelled"
            trade["confirmations"] = []
            trade["revision"] += 1
            db.execute("DELETE FROM asset_locks WHERE reference=?", ("trade:" + trade["code"],))
        elif action == "offer":
            obj(body, {"request_id", "asset_id", "offer_id"}, {"request_id", "asset_id", "offer_id"})
            string(body["offer_id"], 1, 100, "offer_id", r"[A-Za-z0-9_\-]+")
            asset = self.lock_asset(db, body["asset_id"], owner, "trade:" + trade["code"])
            old = trade["offers"].get(owner)
            if old and old["asset_id"] != asset["id"]:
                db.execute("DELETE FROM asset_locks WHERE asset_id=? AND reference=?", (old["asset_id"], "trade:" + trade["code"]))
            trade["offers"][owner] = {"asset_id": asset["id"], "snapshot": copy.deepcopy(asset["snapshot"]), "offer_id": body["offer_id"], "hash": digest(dumps(asset["snapshot"]))}
            trade["confirmations"] = []
            trade["revision"] += 1
        elif action == "confirm":
            obj(body, {"request_id", "revision", "offer_hashes"}, {"request_id", "revision", "offer_hashes"})
            require(type(body["revision"]) is int and body["revision"] == trade["revision"], "offer_changed", "Inspect the updated hosted offers before confirming", 409)
            require(len(trade["members"]) == 2 and set(trade["offers"]) == set(trade["members"]), "offers_required", "Both asset offers are required", 409)
            require(body["offer_hashes"] == {key: offer["hash"] for key, offer in trade["offers"].items()}, "offer_changed", "Hosted offer hashes differ", 409)
            if owner not in trade["confirmations"]:
                trade["confirmations"].append(owner)
            if len(trade["confirmations"]) == 2:
                trade["status"] = "committed"
                trade["transaction_id"] = "tx_" + secrets.token_hex(16)
                transferred = {}
                for participant, offer in trade["offers"].items():
                    other = next(key for key in trade["members"] if key != participant)
                    transferred[other] = self.transfer_asset(db, offer["asset_id"], participant, other, "trade:" + trade["code"])
                for participant in trade["members"]:
                    asset = transferred[participant]
                    self.queue_trade_evolution(db,trade["transaction_id"],asset["id"],participant,trade["offers"][participant]["snapshot"])
                    receipt = {"transaction_id": trade["transaction_id"], "source": "server_managed", "owner_id": participant, "offered_hash": trade["offers"][participant]["hash"], "received_hash": digest(dumps(asset["snapshot"])), "received_asset": asset, "committed_at": self.clock()}
                    db.execute("INSERT INTO trade_receipts VALUES(?,?,?,0)", (trade["transaction_id"], participant, dumps(receipt)))
        else:
            raise APIError(404, "not_found", "Unknown hosted exchange operation")
        self.save_trade(db, trade)
        return 200, {"ok": True, "trade": self.trade_view(db, trade, owner)}

    def save_deposit(self, db, deposit):
        db.execute("INSERT OR REPLACE INTO pool_deposits VALUES(?,?,?,?)", (deposit["deposit_id"], deposit["owner_id"], dumps(deposit), self.clock()))

    def deposit(self, db, deposit_id):
        row = db.execute("SELECT document FROM pool_deposits WHERE id=?", (deposit_id,)).fetchone()
        require(row is not None, "deposit_not_found", "Wonder-pool deposit does not exist", 404)
        deposit = json.loads(row["document"])
        if deposit["status"] == "waiting" and self.clock() >= deposit["expires_at"]:
            self.return_deposit(db, deposit, "expired")
        return deposit

    def return_deposit(self, db, deposit, status):
        deposit["status"] = status
        deposit["final_status"] = status
        deposit["transaction_id"] = "return_" + deposit["deposit_id"]
        receipt = {"transaction_id": deposit["transaction_id"], "source": deposit["source"], "owner_id": deposit["owner_id"], "kind": "return", "offer_id": deposit["offer_id"], "offered_hash": deposit["offered_hash"], "committed_at": self.clock()}
        if deposit["source"] == "local_casual":
            receipt.update({"offered_snapshot": copy.deepcopy(deposit["snapshot"]), "received_snapshot": copy.deepcopy(deposit["snapshot"]), "received_hash": deposit["offered_hash"]})
        else:
            receipt["received_asset"] = self.asset(db, deposit["asset_id"], deposit["owner_id"])
            receipt["received_hash"] = digest(dumps(receipt["received_asset"]["snapshot"]))
            db.execute("DELETE FROM asset_locks WHERE asset_id=? AND reference=?", (deposit["asset_id"], "pool:" + deposit["deposit_id"]))
        deposit["receipt"] = receipt
        self.save_deposit(db, deposit)

    def match_deposits(self, db, first, second):
        transaction = "pooltx_" + secrets.token_hex(16)
        for own, other in ((first, second), (second, first)):
            receipt = {"transaction_id": transaction, "source": own["source"], "owner_id": own["owner_id"], "kind": "exchange", "offer_id": own["offer_id"], "offered_hash": own["offered_hash"], "committed_at": self.clock()}
            if own["source"] == "local_casual":
                receipt.update({"offered_snapshot": copy.deepcopy(own["snapshot"]), "received_snapshot": copy.deepcopy(other["snapshot"]), "received_hash": other["offered_hash"]})
            else:
                receipt["received_asset"] = self.transfer_asset(db, other["asset_id"], other["owner_id"], own["owner_id"], "pool:" + other["deposit_id"])
                receipt["received_hash"] = digest(dumps(receipt["received_asset"]["snapshot"]))
                offered=self.asset(db,own["asset_id"])
                self.queue_trade_evolution(db,transaction,other["asset_id"],own["owner_id"],offered.get("full",offered["snapshot"]))
            own.update({"status": "matched", "final_status": "matched", "transaction_id": transaction, "receipt": receipt})
            self.save_deposit(db, own)

    def pool_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        if method == "GET" and len(parts) == 3:
            deposits = [self.deposit(db, row["id"]) for row in db.execute("SELECT id FROM pool_deposits WHERE owner=? ORDER BY updated DESC", (owner,)).fetchall()]
            return 200, {"ok": True, "deposits": deposits[:100]}
        if method == "POST" and len(parts) == 3:
            obj(body, {"request_id", "deposit_id", "source", "compatibility", "snapshot", "asset_id", "offer_id"}, {"request_id", "deposit_id", "source", "compatibility", "offer_id"})
            string(body["deposit_id"], 37, 37, "deposit_id", r"pool_[a-f0-9]{32}")
            string(body["offer_id"], 1, 100, "offer_id", r"[A-Za-z0-9_\-]+")
            require(body["source"] in ("local_casual", "server_managed"), "unsupported_source", "Unsupported exchange-pool source", 409)
            require(not db.execute("SELECT 1 FROM pool_deposits WHERE id=?", (body["deposit_id"],)).fetchone(), "deposit_exists", "Recover the existing deposit ID", 409)
            for row in db.execute("SELECT id FROM pool_deposits WHERE owner=?", (owner,)).fetchall():
                old = self.deposit(db, row["id"])
                require(old["status"] == "completed", "deposit_pending", "Recover the existing pool receipt first", 409, {"deposit_id": old["deposit_id"]})
            compat = validate_compatibility(body["compatibility"])
            deposit = {"id": body["deposit_id"], "deposit_id": body["deposit_id"], "owner_id": owner, "source": body["source"], "compatibility": compat, "offer_id": body["offer_id"], "status": "waiting", "final_status": None, "acked": False, "transaction_id": None, "receipt": None, "created_at": self.clock(), "expires_at": self.clock() + 86400}
            if body["source"] == "local_casual":
                require("snapshot" in body and "asset_id" not in body, "invalid_source", "Local pool requires a complete local snapshot")
                deposit["snapshot"] = validate_trade_snapshot(body["snapshot"])
            else:
                require("asset_id" in body and "snapshot" not in body, "invalid_source", "Hosted pool accepts only a server asset ID")
                asset = self.lock_asset(db, body["asset_id"], owner, "pool:" + body["deposit_id"])
                deposit.update({"asset_id": asset["id"], "snapshot": copy.deepcopy(asset["snapshot"])})
            deposit["offered_hash"] = digest(dumps(deposit["snapshot"]))
            self.save_deposit(db, deposit)
            for row in db.execute("SELECT id FROM pool_deposits WHERE owner<>? ORDER BY updated", (owner,)).fetchall():
                other = self.deposit(db, row["id"])
                if other["status"] == "waiting" and other["source"] == deposit["source"] and other["compatibility"] == compat:
                    self.match_deposits(db, other, deposit)
                    break
            return 201, {"ok": True, "deposit": deposit}
        require(len(parts) in (4, 5), "not_found", "Unknown wonder-pool endpoint", 404)
        deposit = self.deposit(db, parts[3])
        require(deposit["owner_id"] == owner, "not_owner", "This pool deposit belongs to another identity", 403)
        if method == "GET" and len(parts) == 4:
            return 200, {"ok": True, "deposit": deposit}
        require(method == "POST" and len(parts) == 5, "not_found", "Unknown wonder-pool endpoint", 404)
        if parts[4] == "withdraw":
            obj(body, {"request_id"}, {"request_id"})
            require(deposit["status"] in ("waiting", "withdrawn", "expired"), "deposit_matched", "This deposit already has a committed match; recover its receipt", 409)
            if deposit["status"] == "waiting":
                self.return_deposit(db, deposit, "withdrawn")
        elif parts[4] == "ack":
            obj(body, {"request_id", "transaction_id"}, {"request_id", "transaction_id"})
            require(deposit["transaction_id"] is not None and body["transaction_id"] == deposit["transaction_id"], "transaction_mismatch", "No matching pool receipt", 409)
            deposit.update({"status": "completed", "acked": True})
            self.save_deposit(db, deposit)
        else:
            raise APIError(404, "not_found", "Unknown wonder-pool operation")
        return 200, {"ok": True, "deposit": deposit}

    def choose_rental(self, db, room, owner, slot):
        draft = room["draft"]
        require(draft["status"] == "picking" and draft["next_owner_id"] == owner, "not_your_pick", "It is another player's pick", 409)
        integer(slot, 0, 11, "slot")
        require(slot in draft["remaining"], "slot_taken", "This rental candidate was already selected", 409)
        draft["picks"][owner].append(slot)
        draft["remaining"].remove(slot)
        count = sum(len(picks) for picks in draft["picks"].values())
        draft["pick_index"] = count
        draft["next_owner_id"] = draft["order"][count] if count < 6 else None
        draft["deadline"] = self.clock() + 30 if count < 6 else None
        if count == 6:
            draft["status"] = "complete"
            for participant, member in room["members"].items():
                member["candidates"] = [copy.deepcopy(candidate["snapshot"]) for candidate in draft["pool"]]
                member["selected"] = list(draft["picks"][participant])
                member["ready"] = True
            room["status"] = "ready"
            self.save_room(db, room)
            host_row = db.execute("SELECT id,nickname,friend_code FROM identities WHERE id=?", (room["host_id"],)).fetchone()
            _, response = self.dispatch(db, dict(host_row), "POST", "/v1/rooms/" + room["code"] + "/start", {"request_id": "draft_start_" + draft["id"]})
            battle = self.battle(db, response["battle_id"])
            battle["draft_id"] = draft["id"]
            for participant in battle["players"]:
                battle["presence"][participant]["remaining"] = draft["presence"][participant]["remaining"]
            self.save_battle(db, battle)
            updated_room = self.room(db, room["code"])
            room.clear()
            room.update(updated_room)
            room["draft"]["battle_id"] = battle["id"]
        self.save_room(db, room)

    def tick_draft(self, db, room, owner=None):
        draft = room["draft"]
        if draft["status"] != "picking":
            return
        now, paused = self.clock(), 0
        exhausted = False
        for participant, presence in draft["presence"].items():
            start = presence["last_seen"] + self.heartbeat_seconds
            if now > start:
                loss = max(0, now - max(start, draft["last_tick"]))
                presence["remaining"] = max(0, presence["remaining"] - loss)
                presence["disconnected"] = True
                paused = max(paused, loss)
                exhausted = exhausted or presence["remaining"] <= 0
            if participant == owner:
                presence["last_seen"] = now
                presence["disconnected"] = False
        draft["last_tick"] = now
        draft["reconnect_remaining"] = {key: round(value["remaining"], 1) for key, value in draft["presence"].items()}
        draft["disconnected"] = [key for key, value in draft["presence"].items() if value["disconnected"]]
        if exhausted or room["status"] == "closed":
            draft.update({"status": "cancelled", "next_owner_id": None, "deadline": None, "reason": "disconnect_timeout" if exhausted else "room_closed"})
            if room["status"] != "closed":
                room["status"] = "settled"
        else:
            if paused:
                draft["deadline"] += paused
            # Returning after a brief disconnect does not forgive a pick that
            # was already overdue before the disconnect window began. Wait
            # while anyone is still absent, then commit the server default.
            if not draft["disconnected"] and now >= draft["deadline"]:
                self.choose_rental(db, room, draft["next_owner_id"], draft["remaining"][0])
        self.save_room(db, room)

    def rental_request(self, db, identity, parts, body):
        owner = identity["id"]
        room = self.room(db, parts[2])
        self.member(room, owner)
        require(room.get("mode") == "rental_singles", "wrong_mode", "This is not a rental room", 409)
        if parts[3] == "draft":
            obj(body, {"request_id"}, {"request_id"})
            require(owner == room["host_id"], "host_only", "Only the room host may begin the draft", 403)
            require(room["status"] not in ("closed", "playing", "drafting") and len(room["members"]) == 2, "draft_unavailable", "Two idle members are required", 409)
            catalog = self.catalog(room["compatibility"])
            pool = secrets.SystemRandom().sample(catalog["pokemon"], 12)
            order = list(room["members"])
            secrets.SystemRandom().shuffle(order)
            first, second = order
            room["draft"] = {"id": "draft_" + secrets.token_hex(16), "catalog_version": 1, "status": "picking", "pool": [{"slot": index, "snapshot": copy.deepcopy(snapshot)} for index, snapshot in enumerate(pool)], "order": [first, second, second, first, first, second], "pick_index": 0, "picks": {key: [] for key in order}, "remaining": list(range(12)), "next_owner_id": first, "deadline": self.clock() + 30, "last_tick": self.clock(), "presence": {key: {"last_seen": self.clock(), "remaining": self.reconnect_seconds, "disconnected": False} for key in order}, "reconnect_remaining": {key: self.reconnect_seconds for key in order}, "disconnected": []}
            room["status"] = "drafting"
        else:
            obj(body, {"request_id", "draft_id", "pick_index", "slot"}, {"request_id", "draft_id", "pick_index", "slot"})
            integer(body["pick_index"], 0, 5, "pick_index")
            require(room.get("draft", {}).get("id") == body["draft_id"], "draft_mismatch", "This pick belongs to another rental draft", 409)
            self.tick_draft(db, room, owner)
            if body["pick_index"] != room["draft"]["pick_index"]:
                # Preserve an already committed timer choice even when this
                # late UI click belongs to the preceding (possibly same-owner)
                # selection. Raising here would roll the timer back.
                error = APIError(409, "pick_mismatch", "Refresh the current draft selection", {"pick_index": room["draft"]["pick_index"]})
                return error.status, error.response()
            require(not room["draft"]["disconnected"], "draft_paused", "Waiting for the disconnected player", 409)
            self.choose_rental(db, room, owner, body["slot"])
        room["revision"] += 1
        self.save_room(db, room)
        return 200, {"ok": True, "room": self.room_view(room), "battle_id": room.get("battle_id")}

    def hall_activity(self, db, owner):
        for row in db.execute("SELECT code FROM rooms ORDER BY updated DESC LIMIT 100").fetchall():
            room = self.room(db, row["code"])
            if owner not in room["members"]:
                continue
            if room["status"] == "playing" and room.get("battle_id"):
                battle = self.battle(db, room["battle_id"])
                self.tick(db, battle)
                if battle["status"] != "active":
                    continue
            if room["status"] in ("waiting", "configuring", "ready", "playing", "drafting"):
                return "battle"
        for row in db.execute("SELECT code FROM trades ORDER BY updated DESC LIMIT 100").fetchall():
            trade = self.trade_document(db, row["code"])
            if owner in trade["members"] and trade["status"] in ("waiting", "offering", "committed"):
                if trade["status"] == "committed":
                    ack = db.execute("SELECT acked FROM trade_receipts WHERE transaction_id=? AND owner=?", (trade["transaction_id"], owner)).fetchone()
                    if ack and ack["acked"]:
                        continue
                return "trade"
        return "online"

    def hall_recent_activity(self, db, owner):
        cutoff = self.clock() - 30
        for table, column in (("rooms", "members"), ("trades", "members")):
            for row in db.execute("SELECT document FROM " + table + " WHERE updated>=?", (cutoff,)):
                if owner in json.loads(row["document"])[column]:
                    return True
        return False

    def save_hall(self, db, hall):
        db.execute("INSERT OR REPLACE INTO halls VALUES(?,?,?)", (hall["code"], dumps(hall), self.clock()))

    def hall_view(self, db, hall):
        members = []
        for member in hall["members"].values():
            view = copy.deepcopy(member)
            activity = self.hall_activity(db, member["id"])
            view["status"] = "reconnecting" if activity == "online" and self.clock() > member["last_seen"] + self.heartbeat_seconds else activity
            if self.clock() > member.get("emote_until", 0):
                view["emote"] = None
            members.append(view)
        return {"code": hall["code"], "name": hall["name"], "map": {"id": "social-lobby-v1", "width": 20, "height": 15}, "members": members, "invites": copy.deepcopy(hall["invites"])}

    def hall_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        if method == "POST" and len(parts) == 2:
            obj(body, {"request_id", "name", "compatibility"}, {"request_id", "name", "compatibility"})
            string(body["name"], 1, 48, "name")
            compat = validate_compatibility(body["compatibility"])
            code = secrets.token_hex(3).upper()
            while db.execute("SELECT 1 FROM halls WHERE code=?", (code,)).fetchone():
                code = secrets.token_hex(3).upper()
            hall = {"code": code, "name": body["name"], "compatibility": compat, "members": {}, "invites": []}
            action = "join"
        else:
            require(len(parts) in (3, 4), "not_found", "Unknown lobby endpoint", 404)
            row = db.execute("SELECT document FROM halls WHERE code=?", (parts[2].upper(),)).fetchone()
            require(row is not None, "hall_not_found", "Lobby does not exist", 404)
            hall = json.loads(row["document"])
            hall["members"] = {key: member for key, member in hall["members"].items() if self.clock() - member["last_seen"] <= 30 or self.hall_activity(db, key) in ("battle", "trade") or self.hall_recent_activity(db, key)}
            for invite in hall["invites"]:
                if invite["status"] == "pending" and self.clock() >= invite["expires_at"]:
                    invite["status"] = "expired"
            hall["invites"] = hall["invites"][-40:]
            action = parts[3] if len(parts) == 4 else None
        require(method == "POST" or method == "GET" and len(parts) == 3, "not_found", "Unknown lobby operation", 404)
        if action == "join":
            if len(parts) != 2:
                obj(body, {"request_id", "compatibility"}, {"request_id", "compatibility"})
                require(validate_compatibility(body["compatibility"]) == hall["compatibility"], "compatibility_mismatch", "Lobby versions differ", 409)
            require(owner in hall["members"] or len(hall["members"]) < 4, "hall_full", "Lobby already has four members", 409)
            hall["members"].setdefault(owner, {"id": owner, "nickname": identity["nickname"], "x": 10, "y": 7, "direction": 2, "seq": 0, "emote": None})
        else:
            require(owner in hall["members"], "not_member", "Identity is not in this lobby; join again after timeout", 403)
            member = hall["members"][owner]
            if action == "move":
                obj(body, {"request_id", "seq", "x", "y", "direction"}, {"request_id", "seq", "x", "y", "direction"})
                integer(body["seq"], 1, 2147483647, "seq")
                integer(body["x"], 0, 19, "x")
                integer(body["y"], 0, 14, "y")
                require(type(body["direction"]) is int and body["direction"] in (2, 4, 6, 8), "invalid_direction", "Unsupported lobby facing")
                if body["seq"] > member["seq"]:
                    member.update({key: body[key] for key in ("seq", "x", "y", "direction")})
            elif action == "emote":
                obj(body, {"request_id", "emote"}, {"request_id", "emote"})
                require(body["emote"] in ("hello", "happy", "ready", "thanks"), "invalid_emote", "Unknown preset emote")
                member.update({"emote": body["emote"], "emote_until": self.clock() + 5})
            elif action == "leave":
                obj(body, {"request_id"}, {"request_id"})
                del hall["members"][owner]
            elif action == "invite":
                obj(body, {"request_id", "target_id", "kind"}, {"request_id", "target_id", "kind"})
                require(type(body["target_id"]) is str and body["target_id"] in hall["members"] and body["target_id"] != owner, "invalid_member", "Select another lobby member")
                require(body["kind"] in ("battle", "trade"), "invalid_invite", "Unknown lobby invitation")
                require(self.hall_activity(db, owner) == "online" and self.hall_activity(db, body["target_id"]) == "online", "member_busy", "A participant is already in an activity", 409)
                require(not any(invite["status"] == "pending" and invite["from_id"] == owner for invite in hall["invites"]), "invite_pending", "Resolve the existing lobby invite first", 409)
                hall["invites"].append({"id": "inv_" + secrets.token_hex(12), "from_id": owner, "to_id": body["target_id"], "kind": body["kind"], "status": "pending", "expires_at": self.clock() + 60})
            elif action in ("accept", "decline"):
                obj(body, {"request_id", "invite_id"}, {"request_id", "invite_id"})
                invite = next((item for item in hall["invites"] if item["id"] == body["invite_id"]), None)
                require(invite is not None and invite["to_id"] == owner, "invite_not_found", "No invitation addressed to this identity", 404)
                require(invite["status"] == "pending", "invite_closed", "Invitation already resolved or expired", 409)
                if action == "decline":
                    invite["status"] = "declined"
                else:
                    require(invite["from_id"] in hall["members"], "member_left", "Inviting player left the lobby", 409)
                    require(self.hall_activity(db, owner) == "online" and self.hall_activity(db, invite["from_id"]) == "online", "member_busy", "A participant is already in an activity", 409)
                    sender = dict(db.execute("SELECT id,nickname,friend_code FROM identities WHERE id=?", (invite["from_id"],)).fetchone())
                    if invite["kind"] == "battle":
                        _, response = self.dispatch(db, sender, "POST", "/v1/rooms", {"request_id": "hall_create_" + invite["id"], "name": hall["name"], "compatibility": hall["compatibility"]})
                        invite["room_code"] = response["room"]["code"]
                        self.dispatch(db, identity, "POST", "/v1/rooms/" + invite["room_code"] + "/join", {"request_id": "hall_join_" + invite["id"], "compatibility": hall["compatibility"]})
                    else:
                        _, response = self.trade_request(db, sender, "POST", ["v1", "trades"], {"request_id": "hall_create_" + invite["id"], "compatibility": hall["compatibility"]})
                        invite["trade_code"] = response["trade"]["code"]
                        self.trade_request(db, identity, "POST", ["v1", "trades", invite["trade_code"], "join"], {"request_id": "hall_join_" + invite["id"], "compatibility": hall["compatibility"]})
                    invite["status"] = "accepted"
            elif action is not None:
                raise APIError(404, "not_found", "Unknown lobby operation")
        if owner in hall["members"]:
            hall["members"][owner]["last_seen"] = self.clock()
        self.save_hall(db, hall)
        return 200, {"ok": True, "hall": self.hall_view(db, hall)}

    def dungeon(self, db, dungeon_id, owner):
        row = db.execute("SELECT document FROM dungeons WHERE id=?", (dungeon_id,)).fetchone()
        require(row is not None, "dungeon_not_found", "Cooperative route does not exist", 404)
        dungeon = json.loads(row["document"])
        require(owner in dungeon["players"], "not_participant", "Identity is not a route participant", 403)
        self.expire_dungeon(db, dungeon)
        return dungeon

    def expire_dungeon(self, db, dungeon):
        migrate = "expires_at" not in dungeon or "abandon_votes" not in dungeon
        dungeon.setdefault("expires_at", dungeon["created_at"] + 86400)
        dungeon.setdefault("abandon_votes", [])
        if dungeon["status"] not in ("completed", "failed", "abandoned", "expired") and self.clock() >= dungeon["expires_at"]:
            dungeon.update({"status": "expired", "expired_at": self.clock(), "readies": []})
            if dungeon.get("battle_id"):
                battle = self.battle(db, dungeon["battle_id"])
                self.finish(db, battle, None, "route_expired", abnormal=True)
            self.save_dungeon(db, dungeon)
        elif migrate:
            self.save_dungeon(db, dungeon)

    def save_dungeon(self, db, dungeon):
        db.execute("INSERT OR REPLACE INTO dungeons VALUES(?,?,?)", (dungeon["id"], dumps(dungeon), self.clock()))

    def active_route_for_room(self, db, code):
        for row in db.execute("SELECT document FROM dungeons").fetchall():
            route = json.loads(row["document"])
            if route["room_code"] != code:
                continue
            self.expire_dungeon(db, route)
            if route["status"] not in ("completed", "failed", "abandoned", "expired"):
                return route
        return None

    def validate_team_states(self, dungeon, value):
        allowed_items = {pokemon["item"] for party in dungeon["teams"].values() for pokemon in party if pokemon["item"] is not None}
        allowed_items.update(encounter["item"] for encounter in dungeon["encounters"].values() if encounter.get("item") is not None)
        return validate_runtime_state(value, dungeon["players"], dungeon["teams"], dungeon.get("team_states"), allowed_items)

    def start_dungeon_node(self, db, dungeon):
        room = self.room(db, dungeon["room_code"])
        require(room["status"] not in ("closed", "playing") and set(room["members"]) == set(dungeon["players"]), "route_room_changed", "Restore an idle original two-player room before continuing", 409)
        for row in db.execute("SELECT document FROM battles"):
            current = json.loads(row["document"])
            require(current["room_code"] != room["code"] or current["status"] != "active", "room_battle_active", "This route room already has an active battle", 409)
        for owner, member in room["members"].items():
            member.update({"candidates": copy.deepcopy(dungeon["teams"][owner]), "selected": [0, 1, 2], "ready": True})
        room.update({"mode": "coop_boss", "boss": copy.deepcopy(dungeon["encounters"][str(dungeon["node_index"])]), "status": "ready"})
        self.save_room(db, room)
        host = dict(db.execute("SELECT id,nickname,friend_code FROM identities WHERE id=?", (dungeon["host_id"],)).fetchone())
        _, response = self.dispatch(db, host, "POST", "/v1/rooms/" + room["code"] + "/start", {"request_id": "node_start_" + dungeon["id"]}, internal_route_id=dungeon["id"])
        battle = self.battle(db, response["battle_id"])
        battle.update({"dungeon_id": dungeon["id"], "node_index": dungeon["node_index"], "runtime_state": copy.deepcopy(dungeon["team_states"])})
        self.save_battle(db, battle)
        dungeon.update({"status": "battle", "battle_id": battle["id"], "node_pre_state": copy.deepcopy(dungeon["team_states"]), "readies": [], "abandon_votes": []})

    def dungeon_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        if method == "GET" and len(parts) == 2:
            routes = [json.loads(row["document"]) for row in db.execute("SELECT document FROM dungeons ORDER BY updated DESC")]
            return 200, {"ok": True, "dungeons": [self.dungeon(db, route["id"], owner) for route in routes if owner in route["players"]][:100]}
        if method == "POST" and len(parts) == 2:
            obj(body, {"request_id", "room_code"}, {"request_id", "room_code"})
            string(body["room_code"], 6, 6, "room_code", r"[A-Fa-f0-9]+")
            room = self.room(db, body["room_code"])
            require(room["host_id"] == owner, "host_only", "Only the host may open a cooperative route", 403)
            require(room.get("mode") == "coop_boss" and room["status"] not in ("playing", "closed") and len(room["members"]) == 2 and all(len(member["selected"]) == 3 for member in room["members"].values()), "route_not_ready", "Choose two three-Pokemon teams in a cooperative room first", 409)
            for row in db.execute("SELECT document FROM dungeons").fetchall():
                prior = json.loads(row["document"])
                self.expire_dungeon(db, prior)
                require(not set(prior["players"]) & set(room["members"]) or prior["status"] in ("completed", "failed", "abandoned", "expired"), "route_active", "A participant already has an active cooperative route", 409, {"dungeon_id": prior["id"]})
            catalog = self.catalog(room["compatibility"])
            encounters = {}
            for node in (0, 1, 2):
                snapshot = catalog["pokemon"][node + 1]
                encounters[str(node)] = {"id": "route-encounter-" + str(node), "version": 1, "name": "路线训练员 " + str(node + 1), "difficulty": "normal", "species": snapshot["species"], "level": 50, "moves": [move["id"] for move in snapshot["moves"]], "ability": snapshot["ability"], "stat_stages": {}, "hp_multiplier": 1}
            encounters["4"] = copy.deepcopy(room["boss"])
            dungeon = {"id": "d_" + secrets.token_hex(16), "room_code": room["code"], "host_id": owner, "players": list(room["members"]), "status": "preparing", "node_index": 0, "node_kind": "battle", "nodes": ["battle", "battle", "battle", "rest", "boss"], "teams": {key: [copy.deepcopy(member["candidates"][index]) for index in member["selected"]] for key, member in room["members"].items()}, "team_states": None, "encounters": encounters, "readies": [], "rested": [], "abandon_votes": [], "battle_id": None, "retry_used": False, "history": [], "created_at": self.clock(), "expires_at": self.clock() + 86400}
            self.save_dungeon(db, dungeon)
            return 201, {"ok": True, "dungeon": dungeon}
        require(len(parts) in (3, 4), "not_found", "Unknown cooperative route endpoint", 404)
        dungeon = self.dungeon(db, parts[2], owner)
        if method == "GET" and len(parts) == 3:
            return 200, {"ok": True, "dungeon": dungeon}
        require(method == "POST" and len(parts) == 4, "not_found", "Unknown cooperative route operation", 404)
        if dungeon["status"] == "expired":
            error = APIError(409, "route_expired", "The cooperative route expired after 24 hours")
            return error.status, error.response()  # Keep the time-based closure committed.
        action = parts[3]
        if action == "claim":
            obj(body, {"request_id"}, {"request_id"})
            require(dungeon["status"] == "completed", "reward_unavailable", "Complete the fixed route first", 409)
            return 200, {"ok": True, "reward": self.claim_reward(db, owner, "dungeon:" + dungeon["id"], {"kind": "dungeon_medal", "dungeon_id": dungeon["id"]})}
        require(dungeon["status"] not in ("completed", "failed", "abandoned"), "route_finished", "Cooperative route is already finished", 409)
        if action == "ready":
            obj(body, {"request_id", "ready"}, {"request_id", "ready"})
            boolean(body["ready"], "ready")
            require(dungeon["status"] == "preparing", "wrong_route_phase", "This node is not accepting readiness", 409)
            if body["ready"] and owner not in dungeon["readies"]:
                dungeon["readies"].append(owner)
            elif not body["ready"] and owner in dungeon["readies"]:
                dungeon["readies"].remove(owner)
            if len(dungeon["readies"]) == 2:
                self.start_dungeon_node(db, dungeon)
        elif action == "advance":
            obj(body, {"request_id", "battle_id", "team_states"}, {"request_id", "battle_id"})
            require(owner == dungeon["host_id"], "host_only", "Only the engine host may post temporary team state", 403)
            previous = next((entry for entry in dungeon["history"] if entry.get("battle_id") == body["battle_id"]), None)
            if previous:
                return 200, {"ok": True, "dungeon": dungeon}
            require(dungeon["status"] == "battle" and body["battle_id"] == dungeon["battle_id"], "node_battle_mismatch", "This is not the current route battle", 409)
            battle = self.battle(db, body["battle_id"])
            require(battle["status"] != "active", "battle_active", "Finish the route battle before advancing", 409)
            entry = {"battle_id": battle["id"], "node_index": dungeon["node_index"], "pre_state": copy.deepcopy(dungeon["node_pre_state"]), "result": copy.deepcopy(battle["result"])}
            if battle["status"] == "abnormal":
                entry["post_state"] = copy.deepcopy(dungeon["node_pre_state"])
                dungeon["team_states"] = copy.deepcopy(dungeon["node_pre_state"])
                if dungeon["retry_used"]:
                    dungeon["status"] = "failed"
                else:
                    dungeon.update({"retry_used": True, "status": "preparing", "battle_id": None, "readies": []})
            else:
                authority = battle.get("state", {}).get("team_states")
                if battle["result"].get("coop_outcome") != "victory":
                    # An initializing surrender has a confirmed defeat but may
                    # have no engine frame. It must terminate rather than trap
                    # the route waiting for state that can never be produced.
                    entry["post_state"] = self.validate_team_states(dungeon, authority) if authority is not None else None
                    if authority is not None:
                        dungeon["team_states"] = copy.deepcopy(entry["post_state"])
                    dungeon["status"] = "failed"
                else:
                    require(authority is not None, "post_state_unavailable", "The final host resolution has no durable full-party state; this node cannot be recovered", 409)
                    if "team_states" in body:
                        supplied = self.validate_team_states(dungeon, body["team_states"])
                        require(dumps(supplied) == dumps(authority), "post_state_mismatch", "The supplied party state differs from the committed final resolution", 409)
                    dungeon["team_states"] = self.validate_team_states(dungeon, authority)
                    entry["post_state"] = copy.deepcopy(dungeon["team_states"])
                    dungeon["node_index"] += 1
                    dungeon["battle_id"] = None
                    dungeon["readies"] = []
                    if dungeon["node_index"] == 5:
                        dungeon.update({"status": "completed", "node_kind": "complete"})
                    else:
                        dungeon["node_kind"] = dungeon["nodes"][dungeon["node_index"]]
                        dungeon["status"] = "rest" if dungeon["node_kind"] == "rest" else "preparing"
            dungeon["history"].append(entry)
            dungeon["abandon_votes"] = []
        elif action == "rest":
            obj(body, {"request_id", "choice"}, {"request_id", "choice"})
            require(dungeon["status"] == "rest" and body["choice"] == "heal", "wrong_route_phase", "Only the fixed rest node supports healing", 409)
            if owner not in dungeon["rested"]:
                for state in dungeon["team_states"][owner]:
                    state.update({"hp": state["totalhp"], "pp": list(state["total_pp"]), "status": "NONE", "status_count": 0})
                dungeon["rested"].append(owner)
            if len(dungeon["rested"]) == 2:
                dungeon.update({"node_index": 4, "node_kind": "boss", "status": "preparing", "readies": []})
        elif action == "abandon":
            obj(body, {"request_id"}, {"request_id"})
            votes = dungeon.setdefault("abandon_votes", [])
            if owner not in votes:
                votes.append(owner)
            if set(votes) == set(dungeon["players"]):
                if dungeon["battle_id"]:
                    battle = self.battle(db, dungeon["battle_id"])
                    self.finish(db, battle, None, "route_abandoned", abnormal=True)
                dungeon["status"] = "abandoned"
        else:
            raise APIError(404, "not_found", "Unknown cooperative route operation")
        self.save_dungeon(db, dungeon)
        return 200, {"ok": True, "dungeon": dungeon}

    def replay_view(self, replay):
        return {key: copy.deepcopy(replay[key]) for key in ("id", "battle_id", "players", "creator_id", "status", "visibility", "consents", "compatibility", "created_at", "result")}

    def replay_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        if method == "GET" and len(parts) == 2:
            replays = [json.loads(row["document"]) for row in db.execute("SELECT document FROM replays ORDER BY updated DESC")]
            return 200, {"ok": True, "replays": [self.replay_view(replay) for replay in replays if owner in replay["players"] or replay["status"] == "published" and replay["visibility"] == "public"][:100]}
        if method == "POST" and len(parts) == 2:
            obj(body, {"request_id", "battle_id"}, {"request_id", "battle_id"})
            battle = self.battle(db, body["battle_id"])
            require(owner in battle["players"], "not_participant", "Only battle participants may request a replay", 403)
            require(battle["status"] != "active" and battle["updates"], "replay_unavailable", "Only ended battles with recorded states can be shared", 409)
            for row in db.execute("SELECT document FROM replays"):
                existing = json.loads(row["document"])
                if existing["battle_id"] == battle["id"]:
                    return 200, {"ok": True, "replay": self.replay_view(existing)}
            room = self.room(db, battle["room_code"])
            replay = {"id": "replay_" + secrets.token_hex(16), "battle_id": battle["id"], "players": list(battle["players"]), "creator_id": owner, "status": "private", "visibility": "unlisted", "consents": [], "compatibility": copy.deepcopy(battle.get("compatibility", room["compatibility"])), "created_at": self.clock(), "result": copy.deepcopy(battle["result"]), "data": {"version": 1, "mode": battle.get("mode", "friendly_singles"), "host_id": battle["host_id"], "initial_teams": copy.deepcopy(battle["initial_teams"]), "boss": copy.deepcopy(battle.get("boss")), "updates": copy.deepcopy(battle["updates"]), "result": copy.deepcopy(battle["result"])}}
            require(len(dumps(replay).encode("utf-8")) <= 1800000, "replay_too_large", "Replay exceeds the current client display limit", 409)
            replay["data"]["runtime_state"] = copy.deepcopy(battle.get("runtime_state"))
            self.save_replay(db, replay)
            return 201, {"ok": True, "replay": self.replay_view(replay)}
        require(len(parts) in (3, 4), "not_found", "Unknown replay endpoint", 404)
        row = db.execute("SELECT document FROM replays WHERE id=?", (parts[2],)).fetchone()
        require(row is not None, "replay_not_found", "Replay does not exist", 404)
        replay = json.loads(row["document"])
        require(owner in replay["players"] or replay["status"] == "published", "replay_private", "Replay is private or unpublished", 403)
        if method == "GET" and len(parts) == 3:
            return 200, {"ok": True, "replay": self.replay_view(replay)}
        require(method == "POST" and len(parts) == 4, "not_found", "Unknown replay operation", 404)
        action = parts[3]
        if action == "download":
            obj(body, {"request_id", "compatibility"}, {"request_id", "compatibility"})
            require(replay["status"] == "published" and set(replay["consents"]) == set(replay["players"]), "replay_unpublished", "Both participants must consent and publish this replay", 409)
            require(validate_compatibility(body["compatibility"]) == replay["compatibility"], "compatibility_mismatch", "Replay game, data, mods or rules differ", 409)
            return 200, {"ok": True, "replay": {**self.replay_view(replay), "data": copy.deepcopy(replay["data"])}}
        require(owner in replay["players"], "not_participant", "Only participants can manage replay consent", 403)
        if action == "consent":
            obj(body, {"request_id", "consent"}, {"request_id", "consent"})
            boolean(body["consent"], "consent")
            if body["consent"] and owner not in replay["consents"]:
                replay["consents"].append(owner)
            elif not body["consent"]:
                replay["consents"] = [key for key in replay["consents"] if key != owner]
                replay["status"] = "private"
        elif action == "publish":
            obj(body, {"request_id", "visibility"}, {"request_id", "visibility"})
            require(owner == replay["creator_id"], "creator_only", "Only the replay creator may publish", 403)
            require(body["visibility"] in ("public", "unlisted"), "invalid_visibility", "Unsupported replay visibility")
            require(set(replay["consents"]) == set(replay["players"]), "consent_required", "Both participants must explicitly consent before publication", 409)
            replay.update({"status": "published", "visibility": body["visibility"]})
        elif action == "unpublish":
            obj(body, {"request_id"}, {"request_id"})
            replay["status"] = "private"
        else:
            raise APIError(404, "not_found", "Unknown replay operation")
        self.save_replay(db, replay)
        return 200, {"ok": True, "replay": self.replay_view(replay)}

    def save_replay(self, db, replay):
        db.execute("INSERT OR REPLACE INTO replays VALUES(?,?,?)", (replay["id"], dumps(replay), self.clock()))
