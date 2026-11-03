"""Independently reviewed inventory adjustments for server-owned characters."""
import json
try:
    from .admin_data import ROLES
    from .admin_original_rollback import OriginalRollbackFeatures, bind_api as bind_original_rollback_api
except ImportError:
    from admin_data import ROLES
    from admin_original_rollback import OriginalRollbackFeatures, bind_api as bind_original_rollback_api


def bind_api(api):
    bind_original_rollback_api(api)
    for name in ("obj", "require", "string", "integer", "dumps", "digest"):
        globals()[name] = api[name]


class ControlledAdminFeatures(OriginalRollbackFeatures):
    def controlled_admin_read(self, db, actor, path, query):
        original_rollback = self.original_rollback_read(db, actor, path, query)
        if original_rollback is not None:
            return original_rollback
        if path == "/admin/v1/controlled-character":
            self.admin_permission(actor, "players")
            require(set(query) == {"id"}, "invalid_query", "Specify one controlled character")
            character = self.controlled_character(db, query["id"])
            if self.original_row(db, character["id"]):
                return {**self.original_reply(db, character), "adventure": None,
                        "item_catalog": self.original_item_catalog(db, self.original_row(db, character["id"])),
                        "events": [dict(row, detail=json.loads(row["document"])) for row in db.execute(
                            "SELECT id,kind,request_id,document,created FROM original_events WHERE character_id=? ORDER BY id DESC LIMIT 100", (character["id"],))],
                        "as_of": self.clock()}
            return {"character": self.controlled_view(db, character), "adventure": self.adventure_view(db, character, expire=False),
                    "events": [dict(row, detail=json.loads(row["document"])) for row in db.execute(
                        "SELECT id,monster_id,kind,reference,document,created FROM controlled_creature_events WHERE character_id=? ORDER BY id DESC LIMIT 100", (character["id"],))], "as_of": self.clock()}
        if path != "/admin/v1/controlled-proposals":
            return None
        self.admin_permission(actor, "economy")
        require(not set(query) - {"target"}, "invalid_query", "Unexpected query")
        target = string(query.get("target", ""), 0, 80, "target")
        return {"proposals": [dict(row, detail=json.loads(row["document"])) for row in db.execute(
            "SELECT * FROM controlled_proposals WHERE (?='' OR json_extract(document,'$.target')=?) ORDER BY rowid DESC LIMIT 50", (target, target))], "as_of": self.clock()}

    def validate_controlled_adjustment(self, db, instruction):
        owner = string(instruction["target"], 1, 80, "target", r"p_[a-f0-9]{24}")
        expected = integer(instruction["expected_version"], 0, 2**53 - 1, "expected_version")
        require(self.controls(db, owner)["version"] == expected, "control_version_conflict", "Player state changed", 409)
        character = self.controlled_character(db, instruction["character_id"], owner)
        revision = integer(instruction["expected_revision"], 1, 2**53 - 1, "expected_revision")
        require(character["revision"] == revision, "controlled_revision_conflict", "Character inventory changed", 409)
        item_id = string(instruction["item"], 1, 64, "item", r"[A-Z0-9_]+")
        amount = integer(instruction["amount"], -999, 999, "amount")
        require(amount != 0, "invalid_amount", "Nonzero amount required")
        original = self.original_row(db, character["id"])
        if original:
            self.original_trade_guard(db, character["id"])
            require(not original["pending"], "original_interaction_active", "Finish the current original-game interaction first", 409)
            require(any(entry["id"] == item_id for entry in self.original_item_catalog(db, original)), "controlled_item_unknown", "Unknown original item", 404)
            row = db.execute("SELECT quantity FROM controlled_inventory WHERE character_id=? AND item=?", (character["id"], item_id)).fetchone()
            before = row[0] if row else 0
            require(before + amount >= 0, "controlled_inventory_limit", "Inventory adjustment exceeds its quantity", 409)
            return character, before
        item = next((item for item in self.controlled_catalog()["items"] if item["id"] == item_id), None)
        require(item is not None, "controlled_item_unknown", "Unknown controlled item", 404)
        row = db.execute("SELECT quantity FROM controlled_inventory WHERE character_id=? AND item=?", (character["id"], item_id)).fetchone()
        before = row[0] if row else 0
        require(0 <= before + amount <= item["max_stack"], "controlled_inventory_limit", "Inventory adjustment exceeds limits", 409)
        return character, before

    def controlled_admin_command(self, db, actor, body):
        self.admin_permission(actor, "economy")
        approve = body["action"] == "approve_inventory"
        fields = {"id", "action", "reason"} | ({"proposal_id"} if approve else {"target", "expected_version", "character_id", "expected_revision", "item", "amount"})
        obj(body, fields, fields)
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        reason = string(body["reason"], 3, 500, "reason")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(old["response"])
        if not approve:
            character, before = self.validate_controlled_adjustment(db, body)
            count = db.execute("SELECT count(*) FROM controlled_proposals WHERE actor=? AND status='pending' AND expires>?", (actor["username"], self.clock())).fetchone()[0]
            require(count < 50, "proposal_limit", "Resolve existing proposals first", 429)
            db.execute("INSERT INTO controlled_proposals VALUES(?,?,?,'pending',?,NULL)", (command_id, actor["username"], dumps(body), self.clock() + 86400))
            result = {"ok": True, "command_id": command_id, "status": "pending_approval", "before": before, "after": before + body["amount"]}
            self.audit(db, actor["username"], "inventory_proposed", character["owner"], reason,
                       {"command_id": command_id, "character_id": character["id"], "item": body["item"], "before": before, "after": before + body["amount"]})
        else:
            proposal_id = string(body["proposal_id"], 16, 100, "proposal_id", r"[A-Za-z0-9_-]+")
            proposal = db.execute("SELECT * FROM controlled_proposals WHERE id=?", (proposal_id,)).fetchone()
            require(proposal is not None and proposal["status"] == "pending" and proposal["expires"] > self.clock(), "proposal_unavailable", "Proposal expired or already processed", 409)
            require(proposal["actor"] != actor["username"], "independent_approval_required", "Another administrator must review the inventory change", 403)
            initiator = db.execute("SELECT role FROM admin_users WHERE username=? AND enabled=1", (proposal["actor"],)).fetchone()
            require(initiator is not None and "economy" in ROLES.get(initiator["role"], ()), "proposal_revoked", "Initiator permissions were revoked", 403)
            instruction = json.loads(proposal["document"])
            character, before = self.validate_controlled_adjustment(db, instruction)
            if self.original_row(db, character["id"]):
                self.original_adjust_inventory(db, character, instruction["item"], instruction["amount"], "admin_inventory:" + proposal_id)
            else:
                self.controlled_item_change(db, character["id"], instruction["item"], instruction["amount"], "admin_inventory:" + proposal_id)
                db.execute("UPDATE controlled_characters SET revision=revision+1 WHERE id=?", (character["id"],))
            db.execute("UPDATE controlled_proposals SET status='completed',approved_by=? WHERE id=?", (actor["username"], proposal_id))
            result = {"ok": True, "command_id": command_id, "status": "completed", "character": self.controlled_view(db, self.controlled_character(db, character["id"]))}
            self.audit(db, actor["username"], "inventory_adjusted", character["owner"], reason,
                       {"proposal_id": proposal_id, "character_id": character["id"], "item": instruction["item"], "before": before, "after": before + instruction["amount"], "initiator": proposal["actor"]})
            db.execute("UPDATE admin_commands SET response=? WHERE id=?", (dumps(dict(result, command_id=proposal_id)), proposal_id))
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        return 200, result
