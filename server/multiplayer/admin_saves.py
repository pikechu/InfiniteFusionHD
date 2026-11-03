"""Controlled maintenance of legacy cloud snapshots; never a wallet mint path.

Save editing remains explicitly untrusted legacy data. It is fenced from live
writers and cannot move or restore server-managed assets, orders or wallets.
"""
import base64
import hashlib
import json
import secrets
import zlib

try:
    from .admin_data import summarize_save, SAVE_EXTRACTOR_VERSION
    from .admin_rollback import RollbackFeatures, bind_api as bind_rollback_api
except ImportError:
    from admin_data import summarize_save, SAVE_EXTRACTOR_VERSION
    from admin_rollback import RollbackFeatures, bind_api as bind_rollback_api


def bind_api(api):
    bind_rollback_api(api)
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


def repair_legacy_money(document, money):
    # Match Settings::MAX_MONEY in the current game, not the online wallet cap.
    if type(money) is not int or not 0 <= money <= 999999:
        raise ValueError("Money exceeds current game limits")
    # Validate bounds, references and the selected Player before reading again.
    summarize_save(document)
    graph = json.loads(zlib.decompress(base64.b64decode(document["payload"], validate=True)))
    nodes = graph["nodes"]
    fields = {}
    for key, value in nodes[graph["root"]["ref"]]["items"]:
        if "symbol" in key:
            fields[key["symbol"]] = value
    safe_classes = set("Player Player::Pokedex Pokemon Pokemon::Owner Pokemon::Move PokemonBag PokemonStorage PokemonBox PokemonGlobalMetadata PokemonMapMetadata PokemonSystem Game_System Game_Switches Game_Variables Game_SelfSwitches Game_Screen Game_Picture SafariState BugContestState PokemonMail Pokemon::Mail Pokemon::MoveRelearner PokemonSelection RPG::AudioFile".split())
    safe_types = {"string", "array", "hash", "time", "map_factory", "player_position", "color", "tone", "species", "object"}
    for node in nodes:
        if type(node) is not dict or node.get("type") not in safe_types or node.get("type") == "object" and node.get("class") not in safe_classes:
            raise ValueError("Unsupported cloud object in save repair")
    # Keep both KIF's active player and its vanilla compatibility clone aligned.
    # Their party graphs may differ; only the white-listed money scalar changes.
    for key in ("kuray_player", "player", "trainer"):
        if key not in fields:
            continue
        ref = fields[key]
        if type(ref) is not dict or set(ref) != {"ref"} or type(ref["ref"]) is not int or not 0 <= ref["ref"] < len(nodes):
            raise ValueError("Invalid player reference")
        player = nodes[ref["ref"]]
        if player.get("type") != "object" or player.get("class") != "Player" or type(player.get("ivars")) is not dict:
            raise ValueError("Unsupported player compatibility object")
        player["ivars"]["@money"] = money
    raw = zlib.compress(json.dumps(graph, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8"))
    if len(raw) > 1024 * 1024:
        raise ValueError("Repaired save exceeds compressed limit")
    return dict(document, payload=base64.b64encode(raw).decode("ascii"), sha256=hashlib.sha256(raw).hexdigest())


class AdminSaveFeatures(RollbackFeatures):
    def init_admin_saves(self, db):
        db.executescript("""
          CREATE TABLE IF NOT EXISTS player_maintenance(owner TEXT PRIMARY KEY,id TEXT NOT NULL,actor TEXT NOT NULL,created REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS cloud_history(owner TEXT NOT NULL,slot TEXT NOT NULL,revision INTEGER NOT NULL,
            document TEXT NOT NULL,updated REAL NOT NULL,pinned INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(owner,slot,revision));
          CREATE TABLE IF NOT EXISTS online_characters(id TEXT PRIMARY KEY,owner TEXT NOT NULL,canonical_slot TEXT NOT NULL,created REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS character_slots(owner TEXT NOT NULL,slot TEXT NOT NULL,character_id TEXT NOT NULL,PRIMARY KEY(owner,slot));
          CREATE TRIGGER IF NOT EXISTS cloud_history_insert AFTER INSERT ON cloud_saves BEGIN
            INSERT OR IGNORE INTO cloud_history VALUES(NEW.owner,NEW.slot,NEW.revision,NEW.document,NEW.updated,0);
            DELETE FROM cloud_history WHERE owner=NEW.owner AND slot=NEW.slot AND pinned=0
              AND revision NOT IN(SELECT revision FROM cloud_history WHERE owner=NEW.owner AND slot=NEW.slot ORDER BY revision DESC LIMIT 3)
              AND revision NOT IN(SELECT max(revision) FROM cloud_history WHERE owner=NEW.owner AND slot=NEW.slot AND updated>=NEW.updated-604800 GROUP BY CAST((updated+28800)/86400 AS INTEGER));
          END;
          CREATE TRIGGER IF NOT EXISTS cloud_history_update AFTER UPDATE ON cloud_saves BEGIN
            INSERT OR IGNORE INTO cloud_history VALUES(NEW.owner,NEW.slot,NEW.revision,NEW.document,NEW.updated,0);
          END;
        """)
        db.execute("INSERT OR IGNORE INTO cloud_history SELECT owner,slot,revision,document,updated,0 FROM cloud_saves")
        self.init_save_rollback(db)

    def admin_save_read(self, db, actor, path, query):
        rollback = self.rollback_read(db, actor, path, query)
        if rollback is not None:
            return rollback
        if path != "/admin/v1/save-history":
            return None
        self.admin_permission(actor, "players")
        require(not set(query) - {"owner", "slot"}, "invalid_query", "Unexpected query")
        owner = string(query.get("owner"), 1, 80, "owner", r"[A-Za-z0-9_-]+")
        slot = string(query.get("slot"), 6, 6, "slot")
        return {"versions": [dict(row) for row in db.execute("""SELECT slot,revision,updated,pinned,json_extract(document,'$.sha256') AS sha256
                 FROM cloud_history WHERE owner=? AND slot=? ORDER BY revision DESC LIMIT 30""", (owner, slot))]}

    def prepare_admin_save(self, db, actor, body):
        if body.get("action") in ("request_original_rollback", "approve_original_rollback"):
            return self.prepare_original_rollback(db, actor, body)
        if body.get("action") in ("request_save_rollback", "approve_save_rollback"):
            return self.prepare_admin_rollback(db, actor, body, repair_legacy_money)
        if body.get("action") != "repair_save_money":
            return None
        self.admin_permission(actor, "economy")
        # An uncertain retry must recover its receipt even after the save revision
        # advanced. The write-side command verifies the cached fingerprint.
        if isinstance(body.get("id"), str) and db.execute("SELECT 1 FROM admin_commands WHERE id=?", (body["id"],)).fetchone():
            return None
        obj(body, {"id", "action", "target", "reason", "expected_version", "maintenance_id", "slot", "expected_revision", "money"},
            {"id", "action", "target", "reason", "expected_version", "maintenance_id", "slot", "expected_revision", "money"})
        owner = string(body["target"], 1, 80, "target", r"[A-Za-z0-9_-]+")
        slot = string(body["slot"], 6, 6, "slot")
        revision = integer(body["expected_revision"], 1, 2**53 - 2, "expected_revision")
        money = integer(body["money"], 0, 999999, "money")
        current = db.execute("SELECT revision,document FROM cloud_saves WHERE owner=? AND slot=?", (owner, slot)).fetchone()
        require(current is not None and current["revision"] == revision, "cloud_revision_conflict", "Save changed; review the current revision", 409)
        try:
            original = json.loads(current["document"])
            repaired = repair_legacy_money(original, money)
        except (ValueError, TypeError, KeyError, RecursionError, zlib.error):
            raise APIError(400, "save_repair_unsupported", "Save cannot be safely projected or repaired")
        return {"document": repaired, "old_sha256": original["sha256"], "old_money": summarize_save(original)["money"]}

    def snapshot_gold_total(self, db):
        row = db.execute("""SELECT count(*) AS characters,
            sum(CASE WHEN s.revision=c.revision AND json_extract(s.document,'$.status')='ready' AND json_extract(s.document,'$.extractor_version')=?
                AND json_type(s.document,'$.money')='integer' THEN 1 ELSE 0 END) AS covered,
            sum(CASE WHEN s.revision=c.revision AND json_extract(s.document,'$.status')='ready' AND json_extract(s.document,'$.extractor_version')=?
                THEN json_extract(s.document,'$.money') ELSE NULL END) AS amount
            FROM online_characters ch LEFT JOIN cloud_saves c ON c.owner=ch.owner AND c.slot=ch.canonical_slot
            LEFT JOIN save_summaries s ON s.owner=c.owner AND s.slot=c.slot""", (SAVE_EXTRACTOR_VERSION, SAVE_EXTRACTOR_VERSION)).fetchone()
        unresolved = db.execute("SELECT count(*) FROM cloud_saves c WHERE NOT EXISTS(SELECT 1 FROM character_slots s WHERE s.owner=c.owner AND s.slot=c.slot)").fetchone()[0]
        return {"value": row["amount"], "covered_characters": row["covered"] or 0,
                "registered_characters": row["characters"], "unresolved_slots": unresolved,
                "status": "snapshot_only", "source": "untrusted_cloud_snapshot"}

    def admin_save_command(self, db, actor, body, prepared=None):
        action = body["action"]
        self.admin_permission(actor, "economy" if action in ("repair_save_money", "group_character") else "moderate")
        common = {"id", "action", "target", "reason", "expected_version"}
        extras = {"begin_maintenance": {"force"}, "end_maintenance": {"maintenance_id"},
                  "repair_save_money": {"maintenance_id", "slot", "expected_revision", "money"},
                  "group_character": {"slots", "canonical_slot"}}[action]
        obj(body, common | extras, common | (extras - {"force"}))
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        owner = string(body["target"], 1, 80, "target", r"[A-Za-z0-9_-]+")
        reason = string(body["reason"], 3, 500, "reason")
        expected = integer(body["expected_version"], 0, 2**53 - 1, "expected_version")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(old["response"])
        require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (owner,)).fetchone() is not None, "account_required", "Registered account required", 404)
        controls = self.controls(db, owner)
        require(controls["version"] == expected, "control_version_conflict", "Player state changed", 409)
        maintenance = db.execute("SELECT * FROM player_maintenance WHERE owner=?", (owner,)).fetchone()
        detail = {}
        if action == "begin_maintenance":
            force = body.get("force", False)
            require(type(force) is bool, "invalid_command", "force must be boolean")
            require(maintenance is None, "already_in_maintenance", "Account already in maintenance", 409)
            lease = db.execute("SELECT 1 FROM cloud_leases WHERE owner=? AND expires>?", (owner, self.clock())).fetchone()
            require(force or lease is None, "player_still_active", "Player still has a cloud writer; close the game or explicitly force maintenance", 409)
            # Revocation fences every outstanding upload before editing begins.
            db.execute("DELETE FROM account_sessions WHERE owner=?", (owner,))
            db.execute("UPDATE identities SET token_hash=? WHERE id=?", (digest(secrets.token_urlsafe(32)), owner))
            db.execute("DELETE FROM cloud_leases WHERE owner=?", (owner,))
            db.execute("DELETE FROM world_presence WHERE owner=?", (owner,))
            db.execute("DELETE FROM cloud_chunks WHERE owner=?", (owner,))
            maintenance_id = "maint_" + secrets.token_hex(16)
            db.execute("INSERT INTO player_maintenance VALUES(?,?,?,?)", (owner, maintenance_id, actor["username"], self.clock()))
            offers = db.execute("SELECT * FROM original_offers WHERE status='open' AND (sender IN(SELECT id FROM controlled_characters WHERE owner=?) OR receiver IN(SELECT id FROM controlled_characters WHERE owner=?))", (owner, owner)).fetchall()
            for offer in offers:
                document = json.loads(offer["document"])
                document["cancellation"] = {"kind": "account_maintenance", "maintenance_id": maintenance_id, "created": self.clock()}
                db.execute("UPDATE original_offers SET status='cancelled',document=? WHERE id=?", (dumps(document), offer["id"]))
                db.execute("DELETE FROM original_trade_locks WHERE offer_id=?", (offer["id"],))
            detail = {"maintenance_id": maintenance_id, "forced": force, "had_active_writer": bool(lease), "cancelled_original_offers": [offer["id"] for offer in offers]}
        elif action == "group_character":
            slots = body["slots"]
            require(type(slots) is list and 1 <= len(slots) <= 10 and all(type(slot) is str for slot in slots) and len(set(slots)) == len(slots), "invalid_slots", "Choose 1..10 distinct existing save slots")
            canonical = string(body["canonical_slot"], 6, 6, "canonical_slot")
            require(canonical in slots, "invalid_slots", "Canonical slot must belong to this character")
            for slot in slots:
                require(db.execute("SELECT 1 FROM cloud_saves WHERE owner=? AND slot=?", (owner, slot)).fetchone() is not None, "save_not_found", "Save slot does not exist", 404)
                require(db.execute("SELECT 1 FROM character_slots WHERE owner=? AND slot=?", (owner, slot)).fetchone() is None, "slot_already_grouped", "A slot already belongs to a character", 409)
            character = "char_" + secrets.token_hex(16)
            db.execute("INSERT INTO online_characters VALUES(?,?,?,?)", (character, owner, canonical, self.clock()))
            db.executemany("INSERT INTO character_slots VALUES(?,?,?)", [(owner, slot, character) for slot in slots])
            detail = {"character_id": character, "slots": slots, "canonical_slot": canonical, "source": "operator_reviewed_legacy_snapshot"}
        else:
            require(maintenance is not None and maintenance["id"] == body["maintenance_id"], "maintenance_lost", "Maintenance session changed", 409)
            if action == "end_maintenance":
                require(db.execute("SELECT 1 FROM original_rollback_proposals WHERE target=? AND status='pending' AND expires>?", (owner, self.clock())).fetchone() is None,
                        "rollback_pending", "Approve or cancel the original-role rollback first", 409)
                require(db.execute("SELECT count(*) FROM save_rollback_proposals WHERE target=? AND status='pending' AND expires>?", (owner, self.clock())).fetchone()[0] == 0,
                        "rollback_pending", "Approve or cancel the pending rollback before ending maintenance", 409)
                db.execute("DELETE FROM player_maintenance WHERE owner=?", (owner,))
                detail = {"maintenance_id": maintenance["id"]}
            else:
                require(prepared is not None, "repair_not_prepared", "Repair projection is unavailable", 409)
                row = db.execute("SELECT revision,document FROM cloud_saves WHERE owner=? AND slot=?", (owner, body["slot"])).fetchone()
                require(row is not None and row["revision"] == body["expected_revision"] and json.loads(row["document"])["sha256"] == prepared["old_sha256"], "cloud_revision_conflict", "Save changed after preview", 409)
                # Keep the before-image independently of normal history rotation.
                db.execute("UPDATE cloud_history SET pinned=1 WHERE owner=? AND slot=? AND revision=?", (owner, body["slot"], row["revision"]))
                db.execute("UPDATE cloud_saves SET revision=revision+1,document=?,updated=? WHERE owner=? AND slot=?",
                           (dumps(prepared["document"]), self.clock(), owner, body["slot"]))
                detail = {"slot": body["slot"], "old_revision": row["revision"], "revision": row["revision"] + 1,
                          "before_money": prepared["old_money"], "after_money": body["money"], "source": "untrusted_cloud_snapshot"}
        db.execute("INSERT OR IGNORE INTO player_controls(owner,version) VALUES(?,0)", (owner,))
        db.execute("UPDATE player_controls SET version=version+1 WHERE owner=?", (owner,))
        result = {"ok": True, "command_id": command_id, "status": "completed", "target": owner, "detail": detail, "controls": self.controls(db, owner)}
        self.audit(db, actor["username"], action, owner, reason, dict(detail, command_id=command_id))
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        return 200, result
