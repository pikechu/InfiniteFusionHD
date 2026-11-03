"""Independently reviewed whole legacy-cloud restores with economic fencing."""
import json
import zlib

try:
    from .admin_data import summarize_save
except ImportError:
    from admin_data import summarize_save


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


class RollbackFeatures:
    def init_save_rollback(self, db):
        db.executescript("""CREATE TABLE IF NOT EXISTS save_rollback_proposals(
            id TEXT PRIMARY KEY,actor TEXT NOT NULL,target TEXT NOT NULL,status TEXT NOT NULL,
            document TEXT NOT NULL,expires REAL NOT NULL,approved_by TEXT);
            CREATE INDEX IF NOT EXISTS rollback_target_status ON save_rollback_proposals(target,status,expires);
            CREATE INDEX IF NOT EXISTS shop_orders_owner ON shop_orders(owner,id);
        """)

    def rollback_economic_fence(self, db, owner):
        # The restore never writes any of these tables. Hash the current owned
        # projections as an additional review fence, including their revisions.
        query = lambda sql, args=None: [list(row) for row in db.execute(sql, args if args is not None else (owner,))]
        snapshots = {
            "wallets": query("SELECT owner,currency,balance,revision FROM shop_wallets WHERE owner=? OR owner IN(SELECT id FROM controlled_characters WHERE owner=?) ORDER BY owner,currency", (owner, owner)),
            "hosted": query("SELECT id,document FROM hosted_assets WHERE owner=? ORDER BY id LIMIT 1001"),
            "roles": query("SELECT id,revision,status FROM controlled_characters WHERE owner=? ORDER BY id"),
            "inventory": query("SELECT i.character_id,i.item,i.quantity FROM controlled_inventory i JOIN controlled_characters c ON c.id=i.character_id WHERE c.owner=? ORDER BY i.character_id,i.item"),
            "creatures": query("SELECT m.id,m.document FROM controlled_monsters m JOIN controlled_characters c ON c.id=m.character_id WHERE c.owner=? AND m.status='active' ORDER BY m.id"),
            "progress": query("SELECT p.character_id,p.document FROM controlled_progress p JOIN controlled_characters c ON c.id=p.character_id WHERE c.owner=? ORDER BY p.character_id"),
            "battles": query("SELECT b.id,b.document FROM controlled_battles b JOIN controlled_characters c ON c.id=b.character_id WHERE c.owner=? AND b.status='active' ORDER BY b.id"),
            "orders": query("SELECT count(*),coalesce(max(rowid),0) FROM shop_orders WHERE owner=?")}
        require(len(snapshots["hosted"]) <= 1000, "rollback_asset_limit", "More than 1000 hosted creatures; use an offline recovery workflow", 409)
        preserved = {key: len(value) for key, value in snapshots.items()}
        preserved["orders"] = snapshots["orders"][0][0]
        return {"hash": digest(dumps(snapshots)), "preserved": preserved}

    def rollback_read(self, db, actor, path, query):
        if path != "/admin/v1/save-rollbacks":
            return None
        self.admin_permission(actor, "economy")
        require(not set(query) - {"target"}, "invalid_query", "Unexpected query")
        target = string(query.get("target", ""), 0, 80, "target", r"[A-Za-z0-9_-]*")
        return {"proposals": [dict(row, detail=json.loads(row["document"])) for row in db.execute(
            "SELECT * FROM save_rollback_proposals WHERE (?='' OR target=?) ORDER BY rowid DESC LIMIT 50", (target, target))], "as_of": self.clock()}

    def prepare_admin_rollback(self, db, actor, body, validator):
        action = body.get("action")
        if action not in ("request_save_rollback", "approve_save_rollback"):
            return None
        self.admin_permission(actor, "economy")
        if isinstance(body.get("id"), str) and db.execute("SELECT 1 FROM admin_commands WHERE id=?", (body["id"],)).fetchone():
            return None
        if action == "request_save_rollback":
            fields = {"id", "action", "target", "reason", "expected_version", "maintenance_id", "slot", "expected_revision", "expected_sha256", "restore_revision", "restore_sha256"}
            obj(body, fields, fields)
            instruction = body
            proposal_id = None
        else:
            obj(body, {"id", "action", "reason", "proposal_id"}, {"id", "action", "reason", "proposal_id"})
            proposal_id = string(body["proposal_id"], 16, 100, "proposal_id", r"[A-Za-z0-9_-]+")
            proposal = db.execute("SELECT * FROM save_rollback_proposals WHERE id=?", (proposal_id,)).fetchone()
            require(proposal is not None and proposal["status"] == "pending" and proposal["expires"] > self.clock(), "rollback_unavailable", "Rollback proposal is unavailable or expired", 409)
            require(proposal["actor"] != actor["username"], "independent_review_required", "Another administrator must approve", 403)
            instruction = json.loads(proposal["document"])["instruction"]
        owner = string(instruction["target"], 1, 80, "target", r"p_[a-f0-9]{24}")
        slot = string(instruction["slot"], 6, 6, "slot")
        revision = integer(instruction["expected_revision"], 1, 2**53 - 2, "expected_revision")
        restore_revision = integer(instruction["restore_revision"], 1, revision - 1, "restore_revision")
        for key in ("expected_sha256", "restore_sha256"):
            string(instruction[key], 64, 64, key, r"[a-f0-9]{64}")
        current = db.execute("SELECT revision,document FROM cloud_saves WHERE owner=? AND slot=?", (owner, slot)).fetchone()
        history = db.execute("SELECT document,updated FROM cloud_history WHERE owner=? AND slot=? AND revision=?", (owner, slot, restore_revision)).fetchone()
        require(current is not None and current["revision"] == revision and history is not None, "cloud_revision_conflict", "Save or historical version changed", 409)
        try:
            original, candidate = json.loads(current["document"]), json.loads(history["document"])
            require(original["sha256"] == instruction["expected_sha256"] and candidate["sha256"] == instruction["restore_sha256"], "cloud_hash_conflict", "Save checksum differs from preview", 409)
            before, after = summarize_save(original), summarize_save(candidate)
            # Reuse the strict, bounded object/class whitelist without altering
            # the historical bytes. No Ruby class is instantiated on the server.
            validator(candidate, after["money"])
        except (ValueError, TypeError, KeyError, RecursionError, zlib.error):
            raise APIError(400, "rollback_snapshot_unsupported", "Historical snapshot cannot be safely restored")
        fence = self.rollback_economic_fence(db, owner)
        return {"proposal_id": proposal_id, "instruction": instruction, "candidate": candidate,
                "before": before, "after": after, "fence": fence, "historical_updated": history["updated"]}

    def admin_rollback_command(self, db, actor, body, prepared):
        self.admin_permission(actor, "economy")
        action = body["action"]
        common = {"id", "action", "reason"}
        if action == "request_save_rollback":
            fields = common | {"target", "expected_version", "maintenance_id", "slot", "expected_revision", "expected_sha256", "restore_revision", "restore_sha256"}
        else:
            fields = common | {"proposal_id"}
        obj(body, fields, fields)
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        reason = string(body["reason"], 3, 500, "reason")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(old["response"])
        proposal = None
        if action != "request_save_rollback":
            proposal_id = string(body["proposal_id"], 16, 100, "proposal_id", r"[A-Za-z0-9_-]+")
            proposal = db.execute("SELECT * FROM save_rollback_proposals WHERE id=?", (proposal_id,)).fetchone()
            require(proposal is not None and proposal["status"] == "pending", "rollback_unavailable", "Rollback proposal is no longer pending", 409)
            detail = json.loads(proposal["document"])
            instruction = detail["instruction"]
        else:
            require(prepared is not None and prepared["proposal_id"] is None, "rollback_not_prepared", "Restore preview is unavailable", 409)
            instruction = prepared["instruction"]
        owner = instruction["target"]
        if action == "cancel_save_rollback":
            require(proposal["actor"] == actor["username"] or actor["role"] == "admin", "admin_forbidden", "Only the initiator or administrator may cancel", 403)
            db.execute("UPDATE save_rollback_proposals SET status='cancelled' WHERE id=?", (proposal["id"],))
            status = "cancelled"
            result_detail = {"proposal_id": proposal["id"]}
        else:
            expected_version = integer(instruction["expected_version"], 0, 2**53 - 1, "expected_version")
            require(self.controls(db, owner)["version"] == expected_version, "control_version_conflict", "Player controls changed", 409)
            maintenance = db.execute("SELECT id FROM player_maintenance WHERE owner=?", (owner,)).fetchone()
            require(maintenance is not None and maintenance["id"] == instruction["maintenance_id"], "maintenance_lost", "Maintenance session changed", 409)
            require(prepared is not None and prepared["instruction"] == instruction and prepared["proposal_id"] == (proposal["id"] if proposal else None), "rollback_not_prepared", "Restore preview changed", 409)
            row = db.execute("SELECT revision,document FROM cloud_saves WHERE owner=? AND slot=?", (owner, instruction["slot"])).fetchone()
            candidate = db.execute("SELECT document FROM cloud_history WHERE owner=? AND slot=? AND revision=?", (owner, instruction["slot"], instruction["restore_revision"])).fetchone()
            require(row is not None and row["revision"] == instruction["expected_revision"] and json.loads(row["document"])["sha256"] == instruction["expected_sha256"] and
                    candidate is not None and json.loads(candidate[0])["sha256"] == instruction["restore_sha256"], "cloud_revision_conflict", "Save changed after preview", 409)
            fence = self.rollback_economic_fence(db, owner)
            require(fence["hash"] == prepared["fence"]["hash"], "economic_state_changed", "Managed assets changed after preview", 409)
            if action == "request_save_rollback":
                require(db.execute("SELECT count(*) FROM save_rollback_proposals WHERE target=? AND status='pending' AND expires>?", (owner, self.clock())).fetchone()[0] == 0,
                        "rollback_pending", "Resolve the pending rollback first", 409)
                detail = {"instruction": instruction, "before": prepared["before"], "after": prepared["after"],
                          "fence": fence, "historical_updated": prepared["historical_updated"], "scope": "legacy_cloud_only"}
                db.execute("INSERT INTO save_rollback_proposals VALUES(?,?,?,'pending',?,?,NULL)", (command_id, actor["username"], owner, dumps(detail), self.clock() + 86400))
                db.execute("UPDATE cloud_history SET pinned=1 WHERE owner=? AND slot=? AND revision IN (?,?)", (owner, instruction["slot"], instruction["expected_revision"], instruction["restore_revision"]))
                status, result_detail = "pending_approval", {"proposal_id": command_id, "preview": detail}
            else:
                require(proposal["expires"] > self.clock() and proposal["actor"] != actor["username"], "independent_review_required", "Independent unexpired review required", 403)
                initiator = db.execute("SELECT role FROM admin_users WHERE username=? AND enabled=1", (proposal["actor"],)).fetchone()
                self.admin_permission(dict(initiator) if initiator else {"role": "observer"}, "economy")
                require(fence["hash"] == detail["fence"]["hash"], "economic_state_changed", "Managed assets changed since the request; submit a new preview", 409)
                # New revision, exact historical legacy bytes, current economic
                # tables untouched. Both before-image and source remain pinned.
                db.execute("UPDATE cloud_saves SET revision=revision+1,document=?,updated=? WHERE owner=? AND slot=?",
                           (dumps(prepared["candidate"]), self.clock(), owner, instruction["slot"]))
                db.execute("UPDATE player_controls SET version=version+1 WHERE owner=?", (owner,))
                db.execute("UPDATE save_rollback_proposals SET status='completed',approved_by=? WHERE id=?", (actor["username"], proposal["id"]))
                status, result_detail = "completed", {"proposal_id": proposal["id"], "slot": instruction["slot"],
                    "restored_from_revision": instruction["restore_revision"], "revision": instruction["expected_revision"] + 1,
                    "sha256": instruction["restore_sha256"], "preserved": fence["preserved"], "scope": "legacy_cloud_only"}
        result = {"ok": True, "command_id": command_id, "status": status, "target": owner, "detail": result_detail, "controls": self.controls(db, owner)}
        self.audit(db, actor["username"], action, owner, reason, dict(result_detail, command_id=command_id))
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        if proposal is not None:
            db.execute("UPDATE admin_commands SET response=? WHERE id=?", (dumps(dict(result, command_id=proposal["id"])), proposal["id"]))
        return 200, result
