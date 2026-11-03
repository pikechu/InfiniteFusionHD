"""Whole authoritative-role restores, with immutable backups and transfer fences."""
import json

try:
    from .admin_data import ROLES
except ImportError:
    from admin_data import ROLES


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest"):
        globals()[name] = api[name]


class OriginalRollbackFeatures:
    def init_original_rollback(self, db):
        db.executescript("""
          CREATE TABLE IF NOT EXISTS original_lineage(member TEXT NOT NULL,root TEXT NOT NULL,PRIMARY KEY(member,root));
          CREATE INDEX IF NOT EXISTS original_lineage_root ON original_lineage(root,member);
          CREATE TABLE IF NOT EXISTS original_rollback_proposals(
            id TEXT PRIMARY KEY,actor TEXT NOT NULL,target TEXT NOT NULL,status TEXT NOT NULL,
            document TEXT NOT NULL,expires REAL NOT NULL,approved_by TEXT);
          CREATE INDEX IF NOT EXISTS original_rollbacks_target ON original_rollback_proposals(target,status,expires);
          CREATE TABLE IF NOT EXISTS original_rollback_runs(
            id TEXT PRIMARY KEY,character_id TEXT NOT NULL,before_state TEXT NOT NULL,before_view TEXT NOT NULL,
            before_wallet INTEGER NOT NULL,after_hash TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
        """)
        columns = {row[1] for row in db.execute("PRAGMA table_info(original_snapshots)")}
        for name in ("ownership_cursor", "item_cursor"):
            if name not in columns:
                db.execute(f"ALTER TABLE original_snapshots ADD COLUMN {name} INTEGER NOT NULL DEFAULT 0")
        if "before_pending" not in {row[1] for row in db.execute("PRAGMA table_info(original_rollback_runs)")}:
            db.execute("ALTER TABLE original_rollback_runs ADD COLUMN before_pending TEXT")
        for table in ("original_lineage", "original_rollback_runs"):
            for action in ("UPDATE", "DELETE"):
                db.execute(f"CREATE TRIGGER IF NOT EXISTS {table}_immutable_{action.lower()} BEFORE {action} ON {table} BEGIN SELECT RAISE(ABORT,'Original restore journal is append-only'); END")

    def original_rollback_context(self, db, instruction):
        owner = string(instruction["target"], 26, 26, "target", r"p_[a-f0-9]{24}")
        character = self.controlled_character(db, instruction["character_id"], owner)
        integer(instruction["expected_revision"], 2, 2**53-1, "expected_revision")
        integer(instruction["restore_revision"], 1, instruction["expected_revision"]-1, "restore_revision")
        integer(instruction["expected_version"], 0, 2**53-1, "expected_version")
        require(self.controls(db, owner)["version"] == instruction["expected_version"], "control_version_conflict", "Player controls changed", 409)
        maintenance = db.execute("SELECT id FROM player_maintenance WHERE owner=?", (owner,)).fetchone()
        require(maintenance is not None and maintenance[0] == instruction["maintenance_id"], "maintenance_lost", "Begin account maintenance first", 409)
        row = self.original_row(db, character["id"])
        require(row is not None, "original_not_active", "Choose an original controlled character", 409)
        require(character["revision"] == instruction["expected_revision"], "controlled_revision_conflict", "Character changed", 409)
        self.original_trade_guard(db, character["id"])
        snapshot = db.execute("SELECT * FROM original_snapshots WHERE character_id=? AND revision=?", (character["id"], instruction["restore_revision"])).fetchone()
        require(snapshot is not None, "original_snapshot_missing", "Choose an authoritative checkpoint", 404)
        require(snapshot["rules_hash"] == row["rules_hash"], "original_rules_changed", "Restore requires the checkpoint's original rules", 409)
        transfers = [dict(entry) for entry in db.execute("SELECT id,monster_id,source,target,kind,reference,snapshot FROM original_ownership WHERE id>? AND (source=? OR target=?) ORDER BY id LIMIT 10001", (snapshot["ownership_cursor"], character["id"], character["id"]))]
        require(len(transfers) <= 10000, "rollback_transfer_limit", "Choose a newer checkpoint after reviewing this character's transfer history", 409)
        protected = {entry["monster_id"] for entry in transfers}
        external_held = {}
        for entry in transfers:
            asset = json.loads(entry["snapshot"])
            item = (asset if entry["target"] == character["id"] else asset.get("trade_before", asset)).get("item")
            if item:
                external_held[item] = external_held.get(item, 0) + (1 if entry["target"] == character["id"] else -1)
        for monster in json.loads(snapshot["view"])["monsters"]:
            current = db.execute("SELECT character_id,status FROM original_creatures WHERE id=?", (monster["id"],)).fetchone()
            if current and (current["character_id"] != character["id"] or current["status"] == "listed"):
                protected.add(monster["id"])
        # Fusion and splitting may change IDs; protect the entire connected
        # lineage so a historical ancestor cannot clone a transferred child.
        frontier = list(protected)
        while frontier:
            key = frontier.pop()
            related = {entry[0] for entry in db.execute("SELECT root FROM original_lineage WHERE member=? UNION SELECT member FROM original_lineage WHERE root=?", (key, key))}
            frontier.extend(related - protected)
            protected.update(related)
            require(len(protected) <= 10000, "rollback_lineage_limit", "Narrow the recovery after reviewing this asset lineage", 409)
        foreign_ids = []
        for identifier in protected:
            registered = db.execute("SELECT character_id,status FROM original_creatures WHERE id=?", (identifier,)).fetchone()
            if registered and (registered["character_id"] != character["id"] or registered["status"] == "listed"):
                foreign_ids.append(identifier)
        wallet = self.shop_wallet(db, character["id"], "GOLD")
        external_gold = db.execute("SELECT coalesce(sum(amount),0) FROM shop_ledger WHERE owner=? AND currency='GOLD' AND id>? AND (event LIKE 'managed:original_market_%' OR event LIKE 'managed:original_trade:%' OR ((event LIKE 'admin:%' OR event LIKE 'gm:%') AND event NOT LIKE 'admin:original_rollback:%'))", (character["id"], snapshot["ledger_cursor"])).fetchone()[0]
        target_gold = snapshot["wallet_balance"] + external_gold
        require(0 <= target_gold <= 1_000_000_000, "rollback_wallet_conflict", "Historical funds have crossed an external trade; resolve the funding difference before restoring", 409)
        external_items = {}
        for entry in db.execute("SELECT item,sum(amount) AS amount FROM controlled_item_events WHERE character_id=? AND id>? AND (event LIKE 'original_trade:%' OR event LIKE 'admin_inventory:%') GROUP BY item", (character["id"], snapshot["item_cursor"])):
            external_items[entry["item"]] = entry["amount"]
        fence = {"revision": character["revision"], "state_hash": digest(row["state"]), "pending_hash": digest(row["pending"] or ""), "wallet": wallet,
                 "ownership_cursor": db.execute("SELECT coalesce(max(id),0) FROM original_ownership WHERE source=? OR target=?", (character["id"], character["id"])).fetchone()[0],
                 "protected": sorted(protected), "foreign_ids": sorted(foreign_ids), "target_gold": target_gold, "external_items": external_items, "external_held": external_held,
                 "registry": [list(entry) for entry in db.execute("SELECT id,status,revision FROM original_creatures WHERE character_id=? ORDER BY id", (character["id"],))]}
        return character, row, dict(snapshot), fence

    def prepare_original_rollback(self, db, actor, body):
        action = body.get("action")
        if action not in ("request_original_rollback", "approve_original_rollback"):
            return None
        self.admin_permission(actor, "economy")
        if isinstance(body.get("id"), str) and db.execute("SELECT 1 FROM admin_commands WHERE id=?", (body["id"],)).fetchone():
            return None
        if action == "request_original_rollback":
            fields = {"id", "action", "target", "reason", "expected_version", "maintenance_id", "character_id", "expected_revision", "restore_revision"}
            obj(body, fields, fields)
            instruction, proposal_id = body, None
        else:
            obj(body, {"id", "action", "reason", "proposal_id"}, {"id", "action", "reason", "proposal_id"})
            proposal_id = string(body["proposal_id"], 16, 100, "proposal_id", r"[A-Za-z0-9_-]+")
            proposal = db.execute("SELECT * FROM original_rollback_proposals WHERE id=?", (proposal_id,)).fetchone()
            require(proposal is not None and proposal["status"] == "pending" and proposal["expires"] > self.clock(), "rollback_unavailable", "Proposal expired or unavailable", 409)
            require(proposal["actor"] != actor["username"], "independent_review_required", "Another administrator must review", 403)
            instruction = json.loads(proposal["document"])["instruction"]
        character, row, snapshot, fence = self.original_rollback_context(db, instruction)
        result = self.original_commerce_native("rollback", row["rules_hash"], restore={"current": row["state"], "pending": json.loads(row["pending"]) if row["pending"] else None, "snapshot": snapshot["state"], "time": snapshot["created"],
            "wallet_balance": fence["target_gold"], "protected": fence["protected"], "foreign_ids": fence["foreign_ids"], "external_items": fence["external_items"], "external_held": fence["external_held"]})
        # Private native documents stay out of proposals and API responses.
        def summary(view):
            return {"world": {key: view["world"].get(key) for key in ("map_id", "name", "x", "y")}, "trainer": view["trainer"],
                    "monsters": [{key: monster.get(key) for key in ("id", "species", "name", "level", "exp", "item", "egg_steps")} for monster in view["monsters"]], "inventory": view["inventory"]}
        preview = {"before": summary(json.loads(row["view"])), "after": summary(result["view"]), "money_before": fence["wallet"]["balance"], "money_after": fence["target_gold"],
                   "interrupted_interaction": json.loads(row["pending"])["prompt"]["kind"] if row["pending"] else None,
                   "protected_ids": fence["protected"], "transferred_assets_preserved": len(fence["protected"]), "external_item_changes": fence["external_items"], "after_hash": digest(result["state"])}
        return {"instruction": instruction, "proposal_id": proposal_id, "fence": fence, "fence_hash": digest(dumps(fence)), "result": result, "preview": preview}

    def original_rollback_read(self, db, actor, path, query):
        if path not in ("/admin/v1/original-checkpoints", "/admin/v1/original-rollbacks"):
            return None
        self.admin_permission(actor, "economy")
        if path.endswith("checkpoints"):
            require(set(query) == {"id"}, "invalid_query", "Specify a character")
            self.controlled_character(db, query["id"])
            return {"checkpoints": [{key: row[key] for key in ("revision", "rules_hash", "wallet_balance", "created")} | {"summary": {key: json.loads(row["view"])["world"].get(key) for key in ("map_id", "name", "x", "y")}} for row in db.execute("SELECT revision,rules_hash,view,wallet_balance,created FROM original_snapshots WHERE character_id=? ORDER BY revision DESC LIMIT 50", (query["id"],))], "as_of": self.clock()}
        require(set(query) <= {"target"}, "invalid_query", "Unexpected query")
        target = string(query.get("target", ""), 0, 80, "target")
        return {"proposals": [dict(row, detail=json.loads(row["document"])) for row in db.execute("SELECT * FROM original_rollback_proposals WHERE (?='' OR target=?) ORDER BY rowid DESC LIMIT 50", (target, target))], "as_of": self.clock()}

    def original_rollback_command(self, db, actor, body, prepared):
        self.admin_permission(actor, "economy")
        action = body["action"]
        fields = {"id", "action", "reason"} | ({"target", "expected_version", "maintenance_id", "character_id", "expected_revision", "restore_revision"} if action == "request_original_rollback" else {"proposal_id"})
        obj(body, fields, fields)
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        reason = string(body["reason"], 3, 500, "reason")
        fingerprint = digest(dumps(body))
        previous = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if previous:
            require(previous["actor"] == actor["username"] and previous["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(previous["response"])
        proposal = None
        if action != "request_original_rollback":
            proposal = db.execute("SELECT * FROM original_rollback_proposals WHERE id=?", (body["proposal_id"],)).fetchone()
            require(proposal is not None and proposal["status"] == "pending", "rollback_unavailable", "Proposal is unavailable", 409)
            detail = json.loads(proposal["document"])
            instruction = detail["instruction"]
        else:
            instruction = body
        if action == "cancel_original_rollback":
            require(proposal["actor"] == actor["username"] or actor["role"] == "admin", "admin_forbidden", "Only initiator or administrator may cancel", 403)
            db.execute("UPDATE original_rollback_proposals SET status='cancelled' WHERE id=?", (proposal["id"],))
            status, preview = "cancelled", {"proposal_id": proposal["id"]}
        else:
            require(prepared is not None and prepared["instruction"] == instruction and prepared["proposal_id"] == (proposal["id"] if proposal else None), "rollback_not_prepared", "Restore preview is unavailable", 409)
            character, row, snapshot, fence = self.original_rollback_context(db, instruction)
            require(digest(dumps(fence)) == prepared["fence_hash"], "economic_state_changed", "Character or external assets changed after preview", 409)
            preview = prepared["preview"]
            if action == "request_original_rollback":
                require(db.execute("SELECT 1 FROM original_rollback_proposals WHERE target=? AND status='pending' AND expires>?", (instruction["target"], self.clock())).fetchone() is None, "rollback_pending", "Resolve the existing proposal", 409)
                detail = {"instruction": instruction, "fence_hash": prepared["fence_hash"], "preview": preview}
                db.execute("INSERT INTO original_rollback_proposals VALUES(?,?,?,'pending',?,?,NULL)", (command_id, actor["username"], instruction["target"], dumps(detail), self.clock()+86400))
                status = "pending_approval"
            else:
                require(proposal["expires"] > self.clock() and proposal["actor"] != actor["username"], "independent_review_required", "An independent unexpired review is required", 403)
                initiator = db.execute("SELECT role FROM admin_users WHERE username=? AND enabled=1", (proposal["actor"],)).fetchone()
                require(initiator is not None and "economy" in ROLES.get(initiator["role"], ()), "proposal_revoked", "Initiator permission was revoked", 403)
                require(detail["fence_hash"] == prepared["fence_hash"] and detail["preview"]["after_hash"] == preview["after_hash"], "economic_state_changed", "Preview changed since the request; submit again", 409)
                if not row["pending"] and not db.execute("SELECT 1 FROM original_snapshots WHERE character_id=? AND revision=?", (character["id"], character["revision"])).fetchone():
                    self.original_snapshot(db, character, row["rules_hash"], row["state"], json.loads(row["view"]))
                db.execute("INSERT INTO original_rollback_runs VALUES(?,?,?,?,?,?,?,?,?)", (proposal["id"], character["id"], row["state"], row["view"], fence["wallet"]["balance"], preview["after_hash"], dumps(detail), self.clock(), row["pending"]))
                delta = fence["target_gold"]-fence["wallet"]["balance"]
                if delta:
                    self.shop_money(db, character["id"], "GOLD", delta, "admin:original_rollback:"+proposal["id"])
                self.original_commerce_write(db, character, row, prepared["result"], "original_rollback:"+proposal["id"], "admin_rollback", {"proposal_id": proposal["id"], "restore_revision": instruction["restore_revision"], "money_delta": delta, "protected": fence["protected"]})
                db.execute("UPDATE player_controls SET version=version+1 WHERE owner=?", (instruction["target"],))
                db.execute("UPDATE original_rollback_proposals SET status='completed',approved_by=? WHERE id=?", (actor["username"], proposal["id"]))
                status = "completed"
        result = {"ok": True, "command_id": command_id, "status": status, "target": instruction["target"], "preview": preview, "controls": self.controls(db, instruction["target"])}
        self.audit(db, actor["username"], action, instruction["target"], reason, {"command_id": command_id, "character_id": instruction["character_id"], "restore_revision": instruction["restore_revision"], "status": status, "preview": preview})
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        if proposal:
            db.execute("UPDATE admin_commands SET response=? WHERE id=?", (dumps(dict(result, command_id=proposal["id"])), proposal["id"]))
        return 200, result
