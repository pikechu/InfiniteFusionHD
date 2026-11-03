"""Authoritative original-game intents, using the installed Ruby rules."""
from contextlib import closing
import copy
import json
import secrets
import threading

try:
    from .admin_data import readonly
    from .controlled_adventure import ControlledAdventureFeatures, bind_api as bind_adventure_api
    from .native_rules import NativeRules, NativeRulesError
    from .native_rulebooks import NativeRulebooks
    from . import controlled_engine as v1_engine
except ImportError:
    from admin_data import readonly
    from controlled_adventure import ControlledAdventureFeatures, bind_api as bind_adventure_api
    from native_rules import NativeRules, NativeRulesError
    from native_rulebooks import NativeRulebooks
    import controlled_engine as v1_engine


def bind_api(api):
    bind_adventure_api(api)
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


class ControlledOriginalFeatures(ControlledAdventureFeatures):
    def controlled_v1_action_allowed(self, db, character_id, action):
        # Old committed receipts remain readable. Only a battle already in
        # progress may finish under its pinned historical rulebook.
        return action == "turn" and self.adventure_active_battle(db, character_id, expire=False) is not None

    def init_original(self, db):
        self._original_engine = None
        self._original_engine_lock = threading.RLock()
        db.executescript("""
          CREATE TABLE IF NOT EXISTS original_states(
            character_id TEXT PRIMARY KEY,rules_hash TEXT NOT NULL,state TEXT NOT NULL,
            view TEXT NOT NULL,pending TEXT,updated REAL NOT NULL,last_seen REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS original_receipts(
            owner TEXT NOT NULL,request_id TEXT NOT NULL,fingerprint TEXT NOT NULL,
            response TEXT NOT NULL,created REAL NOT NULL,PRIMARY KEY(owner,request_id));
          CREATE INDEX IF NOT EXISTS original_states_presence ON original_states(last_seen,character_id);
          CREATE TABLE IF NOT EXISTS original_creatures(
            id TEXT PRIMARY KEY,character_id TEXT NOT NULL,status TEXT NOT NULL,
            revision INTEGER NOT NULL,document TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS original_creatures_owner ON original_creatures(character_id,status,id);
          CREATE TABLE IF NOT EXISTS original_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,character_id TEXT NOT NULL,request_id TEXT NOT NULL,
            kind TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL,
            UNIQUE(character_id,request_id));
          CREATE TABLE IF NOT EXISTS original_snapshots(
            character_id TEXT NOT NULL,revision INTEGER NOT NULL,rules_hash TEXT NOT NULL,
            state TEXT NOT NULL,view TEXT NOT NULL,wallet_balance INTEGER NOT NULL,
            ledger_cursor INTEGER NOT NULL,event_cursor INTEGER NOT NULL,created REAL NOT NULL,
            PRIMARY KEY(character_id,revision));
          CREATE TABLE IF NOT EXISTS original_migrations(
            character_id TEXT PRIMARY KEY,policy TEXT NOT NULL,document TEXT NOT NULL,
            before_hash TEXT NOT NULL,after_hash TEXT NOT NULL,created REAL NOT NULL);
        """)
        for table in ("original_receipts", "original_events", "original_snapshots", "original_migrations"):
            for action in ("UPDATE", "DELETE"):
                db.execute(f"CREATE TRIGGER IF NOT EXISTS {table}_immutable_{action.lower()} BEFORE {action} ON {table} "
                           "BEGIN SELECT RAISE(ABORT,'Original game journal is append-only'); END")
        inventory_sql = db.execute("SELECT sql FROM sqlite_master WHERE name='controlled_inventory'").fetchone()[0]
        if "quantity<=999" in inventory_sql.replace(" ", ""):
            # Original bags can contain several stacks of one item; the old v1
            # endpoint still enforces its own 999-unit business limit.
            db.execute("SAVEPOINT original_inventory_upgrade")
            try:
                db.execute("CREATE TABLE controlled_inventory_wide(character_id TEXT NOT NULL,item TEXT NOT NULL,"
                           "quantity INTEGER NOT NULL CHECK(quantity>=0 AND quantity<=9007199254740991),PRIMARY KEY(character_id,item))")
                db.execute("INSERT INTO controlled_inventory_wide SELECT * FROM controlled_inventory")
                db.execute("DROP TABLE controlled_inventory")
                db.execute("ALTER TABLE controlled_inventory_wide RENAME TO controlled_inventory")
                db.execute("RELEASE original_inventory_upgrade")
            except Exception:
                db.execute("ROLLBACK TO original_inventory_upgrade")
                db.execute("RELEASE original_inventory_upgrade")
                raise

    def original_engine(self):
        with self._original_engine_lock:
            if self._original_engine is None:
                self._original_engine = NativeRulebooks()
            return self._original_engine

    def original_close(self):
        if getattr(self, "_original_engine", None):
            self._original_engine.close()

    def original_row(self, db, character_id):
        row = db.execute("SELECT * FROM original_states WHERE character_id=?", (character_id,)).fetchone()
        return dict(row) if row else None

    def original_wallet_write(self, db, character_id, event):
        row = self.original_row(db, character_id)
        require(row is None or not row["pending"] or event.startswith(("managed:original_income:", "managed:original_expense:", "managed:original_market_sell:", "admin:original_rollback:")),
                "original_interaction_active", "Finish the current original-game interaction before changing its wallet", 409)
        if row and not event.startswith("managed:original_trade:"):
            self.original_trade_guard(db, character_id)

    def original_reply(self, db, character, receipt=None, *, full=True):
        row = self.original_row(db, character["id"])
        original = {"active": False} if row is None else {
            "active": True, "rules_hash": row["rules_hash"], "view": json.loads(row["view"]),
            "prompt": json.loads(row["pending"])["prompt"] if row["pending"] else None,
            "prompt_index": len(json.loads(row["pending"])["document"]["inputs"]) if row["pending"] else None}
        if row and row["pending"]:
            pending = json.loads(row["pending"])
            if pending["prompt"]["kind"] == "fishing":
                original["prompt_remaining"] = max(0, pending["prompt"]["seconds"]-max(0, self.clock()-pending["prompt_started"]))
                original["view"]["monsters"] = original["view"]["party"]
                original["view"]["monsters_limited"] = True
        if row and not full and len(original["view"]["monsters"]) > len(original["view"]["party"]):
            original["view"]["monsters"] = original["view"]["party"]
            original["view"]["monsters_limited"] = True
        if row is None:
            monsters = db.execute("SELECT count(*) FROM controlled_monsters WHERE character_id=? AND status='active'", (character["id"],)).fetchone()[0]
            inventory = db.execute("SELECT count(*) FROM controlled_inventory WHERE character_id=? AND quantity>0", (character["id"],)).fetchone()[0]
            chapter = self.adventure_progress(db, character["id"])["chapter"]
            original["migration"] = {"required": bool(monsters or inventory or chapter), "monsters": monsters,
                                     "inventory_lines": inventory, "old_chapter": chapter, "policy": "server_v1_preserve_assets",
                                     "active_battle": self.adventure_active_battle(db, character["id"], expire=False) is not None}
        return {"ok": True, "character": self.controlled_view(db, character), "original": original,
                "as_of": self.clock(),
                **(receipt or {})}

    def original_identity(self, db, token, *, mutation=False):
        identity = self.account_identity(db, token)
        require(identity is not None, "identity_invalid", "Missing or expired account session", 401)
        self.check_player_control(db, identity["id"], trade=mutation)
        return identity

    def original_presence_request(self, method, path, body, token):
        parts = path.strip("/").split("/")
        require(method == "POST" and len(parts) == 6 and parts[2] == "characters" and parts[4:] == ["original", "presence"], "not_found", "Unknown original presence route", 404)
        obj(body, {"request_id"}, {"request_id"})
        string(body["request_id"], 8, 100, "request_id", r"[A-Za-z0-9_-]+")
        with self.lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            identity = self.original_identity(db, token)
            character = self.controlled_character(db, parts[3], identity["id"])
            row = self.original_row(db, character["id"])
            require(row is not None, "original_not_active", "Activate the original game first", 409)
            db.execute("UPDATE original_states SET last_seen=? WHERE character_id=?", (self.clock(), character["id"]))
            self.record_player_activity(db, identity["id"])
            return 200, {"ok": True, "as_of": self.clock(), "revision": character["revision"]}

    def original_validate_intent(self, body):
        fields = {"request_id", "expected_revision", "expected_wallet_revision", "rules_hash", "intent"}
        obj(body, fields, fields)
        string(body["request_id"], 8, 100, "request_id", r"[A-Za-z0-9_-]+")
        integer(body["expected_revision"], 1, 2**53 - 1, "expected_revision")
        integer(body["expected_wallet_revision"], 0, 2**53 - 1, "expected_wallet_revision")
        string(body["rules_hash"], 64, 64, "rules_hash", r"[a-f0-9]{64}")
        intent = body["intent"]
        obj(intent, required={"kind"})
        extras = {"activate": set(), "migrate": {"policy"}, "wait": set(), "move": {"direction"}, "turn": {"direction"},
                  "interact": set(), "choose": {"prompt_index", "value"},
                  "use_item": {"monster_id", "item"}, "give_item": {"monster_id", "item"},
                  "take_item": {"monster_id"}}
        extras.update(field_move={"monster_id", "move"}, field_item={"item"}, reorder={"party"}, save=set())
        require(intent["kind"] in extras, "original_intent_unknown", "Unsupported original game intent")
        obj(intent, {"kind"} | extras[intent["kind"]], {"kind"} | extras[intent["kind"]])
        if intent["kind"] == "migrate":
            require(intent["policy"] == "server_v1_preserve_assets", "original_migration_policy", "Review the server v1 migration policy")
        if intent["kind"] in ("move", "turn"):
            require(type(intent["direction"]) is int and intent["direction"] in (2,4,6,8), "original_direction", "Invalid movement direction")
        if intent["kind"] == "choose":
            integer(intent["prompt_index"], 0, 8191, "prompt_index")
            require(len(dumps(intent["value"]).encode()) <= 2048, "original_choice_limit", "Choice exceeds its size limit")
        if "monster_id" in intent:
            string(intent["monster_id"], 35, 35, "monster_id", r"cm_[a-f0-9]{32}")
        if "item" in intent:
            string(intent["item"], 1, 64, "item", r"[A-Za-z0-9_]+")
        if "move" in intent:
            string(intent["move"], 1, 64, "move", r"[A-Z0-9_]+")
        if intent["kind"] == "reorder":
            party = intent["party"]
            require(type(party) is list and len(party) <= 6 and all(type(value) is str for value in party) and len(set(party)) == len(party), "original_party", "Supply the current party in its new order")
            for identifier in party:
                string(identifier, 35, 35, "monster_id", r"cm_[a-f0-9]{32}")
        return intent

    def original_prepare(self, db, character, row, body):
        intent = self.original_validate_intent(body)
        wallet = self.shop_wallet(db, character["id"], "GOLD")
        require(character["revision"] == body["expected_revision"], "controlled_revision_conflict", "Character changed; refresh", 409)
        require(wallet["revision"] == body["expected_wallet_revision"], "wallet_version_conflict", "Wallet changed; refresh", 409)
        if intent["kind"] in ("activate", "migrate"):
            require(row is None, "original_already_active", "Original game already activated", 409)
            require(self.adventure_active_battle(db, character["id"], expire=False) is None, "controlled_in_battle", "Finish the existing battle first", 409)
            if intent["kind"] == "migrate":
                archive = self.original_managed_v1_archive(db, character)
                return {"operation": "world_migrate", "arguments": {"name": character["name"], "money": wallet["balance"],
                        "time": self.clock(), "seed": secrets.randbits(256), "managed_v1": archive}, "previous_money": 0, "previous_events": 0}
            require(not db.execute("SELECT 1 FROM controlled_monsters WHERE character_id=? AND status='active'", (character["id"],)).fetchone()
                    and not db.execute("SELECT 1 FROM controlled_inventory WHERE character_id=? AND quantity>0", (character["id"],)).fetchone(),
                    "original_migration_required", "Existing controlled assets require migration", 409)
            return {"operation": "world_create", "arguments": {"name": character["name"], "money": wallet["balance"],
                    "time": self.clock(), "seed": secrets.randbits(256)}, "previous_money": 0, "previous_events": 0}
        require(row is not None, "original_not_active", "Activate the original game first", 409)
        self.original_trade_guard(db, character["id"])
        require(row["rules_hash"] == body["rules_hash"], "original_rules_changed", "Review the current rules", 409)
        if intent["kind"] == "move":
            require(self.clock() >= json.loads(row["view"]).get("next_move_at", 0), "original_movement_rate", "The original movement is still completing", 429)
        if row["pending"]:
            pending = json.loads(row["pending"])
            require(intent["kind"] == "choose" and intent["prompt_index"] == len(pending["document"]["inputs"]),
                    "original_prompt_conflict", "Respond to the current prompt", 409)
            require(wallet["revision"] == pending["wallet_revision"], "original_wallet_conflict", "Wallet changed during the interaction", 409)
            document = copy.deepcopy(pending["document"])
            document["inputs"].append({"prompt": pending["prompt"], "value": intent["value"], "time": self.clock()})
            if pending["prompt"]["kind"] == "fishing":
                document["inputs"][-1]["elapsed"] = max(0, self.clock()-pending["prompt_started"])
            key = {"world_step": "world", "cultivate": "cultivation", "trade_finish": "trade"}.get(pending["operation"])
            require(key is not None, "original_pending_invalid", "Unknown pending original operation", 503)
            return {"operation": pending["operation"], "arguments": {key: document},
                    "previous_money": pending["applied_money"], "previous_events": pending["event_count"]}
        require(intent["kind"] != "choose", "original_prompt_conflict", "No prompt is awaiting a choice", 409)
        require(self.clock() - row["updated"] >= 0.05, "original_intent_rate", "Please wait before another action", 429)
        operation = "cultivate" if intent["kind"] in ("use_item", "give_item", "take_item") else "world_step"
        document = {"initial": row["state"], "time": self.clock(), "seed": secrets.randbits(256),
                    "wallet_balance": wallet["balance"], "action": intent, "inputs": []}
        if operation == "world_step":
            document["frames"] = min(40, max(1, int((self.clock() - row["updated"]) * 40)))
        return {"operation": operation, "arguments": {"world" if operation == "world_step" else "cultivation": document},
                "previous_money": 0, "previous_events": 0}

    def original_managed_v1_archive(self, db, character):
        catalog = self.adventure_catalog()
        def enrich(monster):
            value = copy.deepcopy(monster)
            info = v1_engine.species_info(catalog, value["species"])
            growth = catalog["growth"][info["growth_rate"]]
            value.update(max_hp=v1_engine.stats(catalog, value)["HP"], growth_min=growth[value["level"] - 1], growth_next=growth[min(99, value["level"])])
            if value.get("components"):
                value["components"] = [enrich(component) for component in value["components"]]
            return value
        monsters = [json.loads(row[0]) for row in db.execute("SELECT document FROM controlled_monsters WHERE character_id=? AND status='active' ORDER BY id", (character["id"],))]
        return {"progress": self.adventure_progress(db, character["id"]), "monsters": [enrich(monster) for monster in monsters],
                "raw_monsters": monsters, "inventory": [dict(row) for row in db.execute("SELECT item,quantity FROM controlled_inventory WHERE character_id=? AND quantity>0 ORDER BY item", (character["id"],))],
                "hatch_seconds": catalog["hatch_seconds"], "old_rules_hash": catalog["hash"]}

    def original_project(self, db, character, body, result):
        reference = body.get("event_reference", "original:" + body["request_id"])
        before = {row["item"]: row["quantity"] for row in db.execute("SELECT item,quantity FROM controlled_inventory WHERE character_id=?", (character["id"],))}
        after = {}
        for entry in result["view"]["inventory"]:
            after[entry["item"]] = after.get(entry["item"], 0) + entry["quantity"]
        items = []
        for item in before.keys() | after.keys():
            amount = after.get(item, 0) - before.get(item, 0)
            if amount:
                db.execute("INSERT OR REPLACE INTO controlled_inventory VALUES(?,?,?)", (character["id"], item, after.get(item, 0)))
                db.execute("INSERT INTO controlled_item_events(character_id,item,amount,quantity,event,created) VALUES(?,?,?,?,?,?)",
                           (character["id"], item, amount, after.get(item, 0), reference, self.clock()))
                items.append({"item": item, "amount": amount})
        current = {row["id"]: dict(row) for row in db.execute("SELECT * FROM original_creatures WHERE character_id=? AND status IN ('active','borrowed')", (character["id"],))}
        creatures = {}
        statuses = {}
        for monster in result["view"]["monsters"]:
            identifier = string(monster["id"], 35, 35, "native_monster_id", r"cm_[a-f0-9]{32}")
            require(identifier not in creatures, "original_duplicate_creature", "Original engine produced a duplicate creature", 503)
            creatures[identifier] = dumps(monster)
            statuses[identifier] = "borrowed" if monster.get("borrowed") else "active"
            for root in monster.get("lineage", [identifier]):
                string(root, 35, 35, "lineage_id", r"cm_[a-f0-9]{32}")
                db.execute("INSERT OR IGNORE INTO original_lineage VALUES(?,?)", (identifier, root))
        changes = []
        for identifier in current.keys() | creatures.keys():
            old = current.get(identifier)
            document = creatures.get(identifier)
            status = statuses.get(identifier, "listed" if identifier in body.get("listed_ids", []) else "retired")
            if old and old["status"] == status and document == old["document"]:
                continue
            other = db.execute("SELECT * FROM original_creatures WHERE id=?", (identifier,)).fetchone()
            require(other is None or other["character_id"] == character["id"], "original_creature_owner_conflict", "Creature is owned by another role", 409)
            old = old or (dict(other) if other else None)
            revision = old["revision"] + 1 if old else 1
            db.execute("INSERT OR REPLACE INTO original_creatures VALUES(?,?,?,?,?)",
                       (identifier, character["id"], status, revision, document or old["document"]))
            changes.append({"id": identifier, "before": digest(old["document"]) if old else None,
                            "after": digest(document) if document else None, "before_status": old["status"] if old else None,
                            "after_status": status})
        return {"items": items, "creatures": changes}

    def original_item_catalog(self, db, row):
        saved = db.execute("SELECT value FROM admin_metadata WHERE key=?", ("original_catalog:" + row["rules_hash"],)).fetchone()
        require(saved is not None, "original_catalog_unavailable", "Original item catalog is unavailable", 503)
        return json.loads(saved[0])

    def original_adjust_inventory(self, db, character, item, amount, reference):
        row = self.original_row(db, character["id"])
        require(row is not None and not row["pending"], "original_interaction_active", "Finish the current original-game interaction first", 409)
        try:
            native = self.original_engine().call("inventory_adjust", rules_hash=row["rules_hash"], state=row["state"],
                time=self.clock(), wallet_balance=self.shop_wallet(db, character["id"], "GOLD")["balance"], item=item, amount=amount)
        except NativeRulesError as error:
            if str(error) in {"native_inventory_capacity", "native_inventory_quantity"}:
                raise APIError(409, "original_inventory_limit", "Original bag capacity or quantity changed") from error
            raise APIError(503, "original_rules_unavailable", "Original rules could not finish the inventory adjustment") from error
        result = native["result"]
        projection = self.original_project(db, character, {"request_id": reference, "event_reference": reference}, result)
        db.execute("UPDATE original_states SET state=?,view=?,updated=? WHERE character_id=?",
                   (result["state"], dumps(result["view"]), self.clock(), character["id"]))
        db.execute("UPDATE controlled_characters SET revision=revision+1 WHERE id=?", (character["id"],))
        db.execute("INSERT INTO original_events(character_id,request_id,kind,document,created) VALUES(?,?,'admin_inventory',?,?)",
                   (character["id"], "admin:" + reference, dumps({"projection": projection, "before": digest(row["state"]),
                    "after": digest(result["state"]), "rules_hash": native["rules_hash"]}), self.clock()))
        character = self.controlled_character(db, character["id"])
        self.original_snapshot(db, character, native["rules_hash"], result["state"], result["view"])

    def original_snapshot(self, db, character, rules_hash, state, view):
        wallet = self.shop_wallet(db, character["id"], "GOLD")
        ledger = db.execute("SELECT coalesce(max(id),0) FROM shop_ledger WHERE owner=? AND currency='GOLD'", (character["id"],)).fetchone()[0]
        event = db.execute("SELECT coalesce(max(id),0) FROM original_events WHERE character_id=?", (character["id"],)).fetchone()[0]
        ownership = db.execute("SELECT coalesce(max(id),0) FROM original_ownership").fetchone()[0]
        item = db.execute("SELECT coalesce(max(id),0) FROM controlled_item_events WHERE character_id=?", (character["id"],)).fetchone()[0]
        db.execute("INSERT INTO original_snapshots VALUES(?,?,?,?,?,?,?,?,?,?,?)", (character["id"], character["revision"], rules_hash,
                   state, dumps(view), wallet["balance"], ledger, event, self.clock(), ownership, item))

    def original_request(self, method, path, body, token, peer):
        parts = path.strip("/").split("/")
        catalog = parts == ["v1", "controlled", "original-catalog"]
        require(catalog or len(parts) == 5 and parts[2] == "characters" and parts[4] == "original", "not_found", "Unknown original game route", 404)
        with closing(readonly(self.database)) as db:
            db.execute("BEGIN")
            identity = self.original_identity(db, token, mutation=method == "POST")
            if not catalog:
                character = self.controlled_character(db, parts[3], identity["id"])
                row = self.original_row(db, character["id"])
            if method == "GET" and not catalog:
                return 200, self.original_reply(db, character)
            if method == "POST":
                require(not catalog, "invalid_method", "Catalog is read-only", 405)
                self.original_validate_intent(body)
                fingerprint = digest(dumps({"path": path, "body": body}))
                old = db.execute("SELECT * FROM original_receipts WHERE owner=? AND request_id=?", (identity["id"], body["request_id"])).fetchone()
                if old:
                    require(old["fingerprint"] == fingerprint, "request_id_conflict", "Request ID already used", 409)
                    return 200, self.original_reply(db, character, json.loads(old["response"]), full=body["intent"]["kind"] == "migrate")
                prepared = self.original_prepare(db, character, row, body)
            else:
                require(method == "GET" and catalog, "invalid_method", "Use GET or POST", 405)
        try:
            native = self.original_engine().call("catalog" if catalog else prepared["operation"],
                                               **({} if catalog else dict(prepared["arguments"], rules_hash=body["rules_hash"])))
        except NativeRulesError as error:
            code = str(error).split(":", 1)[0]
            if code == "native_rules_busy":
                raise APIError(429, "original_rules_busy", "Original rules are busy; retry this intent shortly") from error
            if code in {"invalid_native_choice", "native_name_limit", "item_not_owned", "unknown_native_item",
                        "native_party_monster_not_found", "invalid_item_target", "invalid_item_move", "native_field_move", "native_party_order", "native_wait_early"}:
                raise APIError(400, "original_choice_invalid", "This choice is not available in the current interaction") from error
            if code in {"native_prompt_conflict", "native_rules_changed", "native_save_disabled"}:
                raise APIError(409, "original_rules_conflict", "Original rules or the pending prompt changed; refresh") from error
            if code == "native_offline_only_feature":
                raise APIError(409, "original_offline_only_feature", "此功能保留在历史离线玩法；受控角色请使用受控交易与管理入口。") from error
            raise APIError(503, "original_rules_unavailable", "Original rules could not finish this intent; retry the same request") from error
        if catalog:
            return 200, {"ok": True, "rules_hash": native["rules_hash"], "catalog": native["result"]}
        result = native["result"]
        with self.lock, self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            identity = self.original_identity(db, token, mutation=True)
            character = self.controlled_character(db, parts[3], identity["id"])
            old = db.execute("SELECT * FROM original_receipts WHERE owner=? AND request_id=?", (identity["id"], body["request_id"])).fetchone()
            if old:
                require(old["fingerprint"] == fingerprint, "request_id_conflict", "Request ID already used", 409)
                return 200, self.original_reply(db, character, json.loads(old["response"]))
            current = self.original_row(db, character["id"])
            self.original_prepare(db, character, current, body)
            delta = result.get("money_delta", 0) - prepared["previous_money"]
            integer(delta, -(2**53 - 1), 2**53 - 1, "native_money_delta")
            events = result.get("events", [])[prepared["previous_events"]:]
            money_events = [event for event in events if event["kind"] == "money"]
            for event in money_events:
                integer(event["amount"], -(2**53 - 1), 2**53 - 1, "native_money_amount")
                require(event["source"] in {"battle_income", "battle_loss", "npc_sale", "npc_purchase", "quest_reward", "tutor_cost", "daycare_cost", "event_income", "event_expense"},
                        "original_money_source", "Original rules returned an unknown money source", 503)
            require(sum(event["amount"] for event in money_events) == delta, "original_money_reconciliation", "Original rules money journal differs from its purse", 503)
            for index, event in enumerate(money_events):
                prefix = "managed:original_income:" if event["amount"] > 0 else "managed:original_expense:"
                self.shop_money(db, character["id"], "GOLD", event["amount"], prefix + event["source"] + ":" + character["id"] + ":" + body["request_id"] + ":" + str(index))
            projection = self.original_project(db, character, body, result)
            if prepared["operation"] == "world_migrate":
                archive = prepared["arguments"]["managed_v1"]
                db.execute("INSERT INTO original_migrations VALUES(?,?,?,?,?,?)", (character["id"], "server_v1_preserve_assets", dumps(archive), digest(dumps(archive)), digest(result["state"]), self.clock()))
                for monster in archive["raw_monsters"]:
                    self.adventure_record_monster(db, character["id"], monster, "original_migration", body["request_id"], status="migrated")
            view = result["view"]
            if current and "world" not in view:
                view = dict(json.loads(current["view"]), **view)
            if current:
                view["next_move_at"] = json.loads(current["view"]).get("next_move_at", 0)
            if body["intent"]["kind"] == "move" and result.get("movement_seconds", 0) > 0:
                view["next_move_at"] = prepared["arguments"]["world"]["time"] + result["movement_seconds"]
            pending = None
            if result.get("prompt"):
                key = {"world_step": "world", "cultivate": "cultivation", "trade_finish": "trade"}[prepared["operation"]]
                pending = {"operation": prepared["operation"], "document": prepared["arguments"][key], "prompt": result["prompt"],
                           "applied_money": result["money_delta"], "event_count": len(result["events"]),
                           "wallet_revision": self.shop_wallet(db, character["id"], "GOLD")["revision"], "prompt_started": self.clock()}
            state = result.get("state") or current["state"]
            if "item_catalog" in result:
                db.execute("INSERT OR REPLACE INTO admin_metadata VALUES(?,?)", ("original_catalog:" + native["rules_hash"], dumps(result["item_catalog"])))
            db.execute("INSERT OR REPLACE INTO original_states VALUES(?,?,?,?,?,?,?)", (character["id"], native["rules_hash"], state,
                       dumps(view), dumps(pending) if pending else None, self.clock(), self.clock()))
            db.execute("UPDATE controlled_characters SET revision=revision+1 WHERE id=?", (character["id"],))
            character = self.controlled_character(db, character["id"], identity["id"])
            detail = {"intent": body["intent"], "money_delta": delta, "money_events": money_events, "projection": projection,
                      "before": digest(current["state"]) if current else None, "after": digest(state), "rules_hash": native["rules_hash"]}
            if prepared["operation"] == "world_migrate":
                detail["migration"] = {"policy": "server_v1_preserve_assets", "archive_hash": digest(dumps(archive)),
                                       "monsters": len(archive["raw_monsters"]), "old_chapter": archive["progress"]["chapter"]}
            db.execute("INSERT INTO original_events(character_id,request_id,kind,document,created) VALUES(?,?,?,?,?)",
                       (character["id"], body["request_id"], body["intent"]["kind"], dumps(detail), self.clock()))
            receipt = {"receipt": {"request_id": body["request_id"], "revision": character["revision"], "money_delta": delta}, "events": events}
            db.execute("INSERT INTO original_receipts VALUES(?,?,?,?,?)", (identity["id"], body["request_id"], fingerprint, dumps(receipt), self.clock()))
            if result.get("state") and (current is None or any(event["kind"] == "checkpoint_requested" for event in result.get("events", []))):
                self.original_snapshot(db, character, native["rules_hash"], state, view)
            self.record_player_activity(db, identity["id"])
            return 200, self.original_reply(db, character, receipt, full=body["intent"]["kind"] == "migrate")
