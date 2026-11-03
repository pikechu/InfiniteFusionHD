"""Administrator API, persistent moderation, statistics and audited commands."""
from contextlib import closing
from datetime import datetime
import hmac
import json
import secrets
import sqlite3
import threading
import zlib

PLAYER_PRESENCE = """(SELECT owner,max(updated) AS updated FROM (
    SELECT owner,updated FROM world_presence UNION ALL
    SELECT c.owner,s.last_seen AS updated FROM original_states s
    JOIN controlled_characters c ON c.id=s.character_id) GROUP BY owner)"""
try:
    from .admin_economy import EconomyAdminFeatures, bind_api as bind_economy_api
except ImportError:
    from admin_economy import EconomyAdminFeatures, bind_api as bind_economy_api
try:
    from .admin_jobs import AdminJobFeatures, bind_api as bind_job_api
except ImportError:
    from admin_jobs import AdminJobFeatures, bind_api as bind_job_api
try:
    from .admin_saves import AdminSaveFeatures, bind_api as bind_save_api
except ImportError:
    from admin_saves import AdminSaveFeatures, bind_api as bind_save_api
try:
    from .admin_commerce import CommerceAdminFeatures, bind_api as bind_commerce_api
except ImportError:
    from admin_commerce import CommerceAdminFeatures, bind_api as bind_commerce_api
try:
    from .admin_controlled import ControlledAdminFeatures, bind_api as bind_controlled_admin_api
except ImportError:
    from admin_controlled import ControlledAdminFeatures, bind_api as bind_controlled_admin_api
try:
    from .admin_market import MarketAnalyticsFeatures, bind_api as bind_market_api
except ImportError:
    from admin_market import MarketAnalyticsFeatures, bind_api as bind_market_api

try:
    from .admin_data import (ROLES, SHANGHAI, SAVE_EXTRACTOR_VERSION, day_key, init_schema, readonly,
                             password_digest, split_admin_path, summarize_save, totp)
except ImportError:
    from admin_data import (ROLES, SHANGHAI, SAVE_EXTRACTOR_VERSION, day_key, init_schema, readonly,
                            password_digest, split_admin_path, summarize_save, totp)


def bind_api(api):
    bind_market_api(api)
    bind_economy_api(api)
    bind_job_api(api)
    bind_save_api(api)
    bind_commerce_api(api)
    bind_controlled_admin_api(api)
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "APIError"):
        globals()[name] = api[name]


class AdminFeatures(EconomyAdminFeatures, AdminJobFeatures, AdminSaveFeatures, CommerceAdminFeatures, ControlledAdminFeatures, MarketAnalyticsFeatures):
    def init_admin(self, db):
        init_schema(db)
        self.init_admin_economy(db)
        self.init_admin_jobs(db)
        self.init_admin_saves(db)
        self.init_admin_commerce(db)
        self.init_market_analytics(db)
        db.execute("INSERT OR REPLACE INTO admin_metadata VALUES('schema_version','11')")
        db.execute("INSERT OR IGNORE INTO admin_metadata VALUES('original_market_fee_bps','0')")
        db.execute("INSERT OR IGNORE INTO admin_metadata VALUES('original_market_started',?)", (str(self.clock()),))
        db.execute("INSERT OR IGNORE INTO admin_metadata VALUES('collection_started',?)", (str(self.clock()),))
        self.admin_stop = threading.Event()
        self.admin_worker = None
        self.admin_peak_sample = None
        db.execute("CREATE INDEX IF NOT EXISTS account_sessions_owner_expiry ON account_sessions(owner,expires)")
        db.execute("CREATE INDEX IF NOT EXISTS world_presence_updated ON world_presence(updated)")

    def audit(self, db, actor, action, target="", reason="", detail=None):
        db.execute("INSERT INTO admin_audit(actor,action,target,reason,document,created) VALUES(?,?,?,?,?,?)",
                   (actor, action, target, reason, dumps(detail or {}), self.clock()))

    def controls(self, db, owner):
        row = db.execute("SELECT * FROM player_controls WHERE owner=?", (owner,)).fetchone()
        return dict(row) if row else {"owner": owner, "version": 0, "ban_until": 0, "mute_until": 0, "trade_frozen": 0}

    def check_player_control(self, db, owner, *, chat=False, trade=False):
        state = self.controls(db, owner)
        now = self.clock()
        require(state["ban_until"] <= now, "account_banned", "Account is suspended", 403,
                {"until": state["ban_until"]})
        require(db.execute("SELECT 1 FROM player_maintenance WHERE owner=?", (owner,)).fetchone() is None,
                "account_maintenance", "Account is in maintenance; contact an administrator", 409)
        if chat:
            require(state["mute_until"] <= now, "account_muted", "Chat is suspended", 403,
                    {"until": state["mute_until"]})
        if trade:
            require(not state["trade_frozen"], "trade_frozen", "Economic operations are frozen", 403)

    def record_player_activity(self, db, owner, force_peak=False):
        now, day = self.clock(), day_key(self.clock())
        # Only registered game accounts participate in account metrics.
        if not db.execute("SELECT 1 FROM accounts WHERE owner=?", (owner,)).fetchone():
            return
        previous = db.execute("SELECT last FROM player_activity WHERE owner=? AND day=?", (owner, day)).fetchone()
        elapsed = min(20, max(0, now - previous[0])) if previous else 0
        db.execute("""INSERT INTO player_activity(owner,day,first,last,seconds) VALUES(?,?,?,?,?)
                   ON CONFLICT(owner,day) DO UPDATE SET last=excluded.last,seconds=seconds+excluded.seconds""",
                   (owner, day, now, now, elapsed))
        db.execute("INSERT OR IGNORE INTO player_first_activity VALUES(?,?,?)", (owner, day, now))
        if not force_peak and self.admin_peak_sample is not None and now - self.admin_peak_sample < 1:
            return
        online = db.execute(f"""SELECT count(*) FROM {PLAYER_PRESENCE} p JOIN accounts a ON a.owner=p.owner
                   WHERE p.updated>? AND EXISTS(SELECT 1 FROM account_sessions s WHERE s.owner=p.owner AND s.expires>?)""",
                            (now - 20, now)).fetchone()[0]
        db.execute("INSERT INTO admin_online_peaks VALUES(?,?) ON CONFLICT(day) DO UPDATE SET peak=MAX(peak,excluded.peak)", (day, online))
        self.admin_peak_sample = now

    def admin_identity(self, db, token):
        row = db.execute("""SELECT u.username,u.role FROM admin_sessions s JOIN admin_users u ON u.username=s.username
                         WHERE s.token_hash=? AND s.expires>? AND u.enabled=1""", (digest(token or ""), self.clock())).fetchone()
        require(row is not None, "admin_auth_required", "Administrator login required", 401)
        return dict(row)

    def admin_permission(self, actor, permission):
        require(permission in ROLES.get(actor["role"], ()), "admin_forbidden", "Permission is not granted", 403)

    def admin_login(self, body, peer):
        obj(body, {"username", "password", "otp"}, {"username", "password", "otp"})
        username = string(body["username"], 3, 32, "username", r"[A-Za-z0-9_.-]+").lower()
        password = string(body["password"], 1, 128, "password")
        otp = string(body["otp"], 6, 6, "otp", r"[0-9]{6}")
        now = self.clock()
        # Failed attempts survive restarts. Never store passwords or OTPs.
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM admin_login_attempts WHERE started<?", (now - 900,))
            for kind, value, maximum in (("ip", peer, 30), ("user", username, 10)):
                bucket = kind + ":" + digest(value)
                old = db.execute("SELECT attempts FROM admin_login_attempts WHERE bucket=?", (bucket,)).fetchone()
                require(old is None or old[0] < maximum, "admin_rate_limited", "Try administrator login later", 429)
            require(db.execute("SELECT count(*) FROM admin_login_attempts").fetchone()[0] < 10000,
                    "admin_rate_limited", "Administrator login is busy", 429)
            for kind, value in (("ip", peer), ("user", username)):
                db.execute("INSERT INTO admin_login_attempts VALUES(?,?,1) ON CONFLICT(bucket) DO UPDATE SET attempts=attempts+1",
                           (kind + ":" + digest(value), now))
            found = db.execute("SELECT * FROM admin_users WHERE username=?", (username,)).fetchone()
            saved = dict(found) if found else None
        require(self.auth_slots.acquire(blocking=False), "auth_busy", "Authentication is busy", 429)
        try:
            computed = password_digest(password, saved["salt"] if saved else "00" * 16)
        finally:
            self.auth_slots.release()
        counter = None
        if saved and hmac.compare_digest(computed, saved["password_hash"]):
            for step in (-1, 0, 1):
                tick = int(self.clock() // 30) + step
                if tick > saved["last_counter"] and tick >= 0 and hmac.compare_digest(totp(saved["totp_secret"], tick * 30), otp):
                    counter = tick
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT * FROM admin_users WHERE username=?", (username,)).fetchone()
            valid = counter is not None and current is not None and dict(current) == saved and current["enabled"]
            if not valid:
                self.audit(db, username, "login_failed", detail={"peer_hash": digest(peer)})
                return 401, {"ok": False, "error": {"code": "admin_login_invalid", "message": "Invalid administrator credentials or verification code"}}
            token = secrets.token_urlsafe(32)
            expires = self.clock() + 3600
            db.execute("UPDATE admin_users SET last_counter=? WHERE username=?", (counter, username))
            db.execute("DELETE FROM admin_sessions WHERE expires<=?", (self.clock(),))
            db.execute("INSERT INTO admin_sessions VALUES(?,?,?)", (digest(token), username, expires))
            self.audit(db, username, "login")
            return 200, {"ok": True, "token": token, "expires_at": expires,
                         "administrator": {"username": username, "role": saved["role"], "permissions": sorted(ROLES[saved["role"]])}}

    def admin_request(self, method, path, body, token, peer):
        path, query = split_admin_path(path)
        if method == "POST" and path == "/admin/v1/login":
            require(not query, "invalid_query", "Login does not accept query parameters")
            return self.admin_login(body, peer)
        actor = None
        prepared = None
        try:
            with closing(readonly(self.database)) as db:
                db.execute("BEGIN")
                actor = self.admin_identity(db, token)
                if method == "GET":
                    result = self.admin_read(db, actor, path, query)
                else:
                    result = None
                    if path == "/admin/v1/commands":
                        prepared = self.prepare_admin_save(db, actor, body)
            if method == "POST":
                require(not query, "invalid_query", "Commands do not accept query parameters")
                with self.connect() as db:
                    db.execute("BEGIN IMMEDIATE")
                    actor = self.admin_identity(db, token)
                    if path == "/admin/v1/logout":
                        obj(body, set())
                        db.execute("DELETE FROM admin_sessions WHERE token_hash=?", (digest(token),))
                        self.audit(db, actor["username"], "logout")
                        return 200, {"ok": True}
                    if path == "/admin/v1/exports":
                        return self.create_admin_export(db, actor, body)
                    require(path == "/admin/v1/commands", "not_found", "Unknown administrator endpoint", 404)
                    return self.admin_command(db, actor, body, prepared)
            require(method == "GET", "invalid_method", "Use GET or POST", 405)
            audit_target = path
            if path.startswith("/admin/v1/players/") and result.get("player"):
                audit_target = result["player"]["id"]
            elif path.startswith("/admin/v1/assets/") and result.get("current_owner"):
                audit_target = result["current_owner"]
            elif path == "/admin/v1/controlled-character":
                audit_target = result["character"]["owner"]
            with self.connect() as db:
                self.audit(db, actor["username"], "read", audit_target, detail={"path": path, "filters": query})
            return 200, dict(result, ok=True)
        except APIError as error:
            if actor:
                with self.connect() as db:
                    self.audit(db, actor["username"], "rejected", path, detail={"code": error.code})
            return error.status, error.response()
        except sqlite3.OperationalError:
            return 503, {"ok": False, "error": {"code": "admin_query_busy", "message": "Query timed out; narrow the search and retry"}}

    def admin_read(self, db, actor, path, query):
        prices = self.market_prices_read(db, actor, path, query)
        if prices is not None:
            return prices
        if path.startswith("/admin/v1/assets/"):
            self.admin_permission(actor, "players")
            require(not query, "invalid_query", "Unexpected query")
            asset_id = string(path.rsplit("/", 1)[1], 1, 80, "asset_id", r"[A-Za-z0-9_-]+")
            row = db.execute("SELECT owner,document FROM hosted_assets WHERE id=?", (asset_id,)).fetchone()
            require(row is not None, "asset_not_found", "Hosted asset does not exist", 404)
            lock = db.execute("SELECT reference FROM asset_locks WHERE asset_id=?", (asset_id,)).fetchone()
            return {"asset": json.loads(row["document"]), "current_owner": row["owner"],
                    "lock_record": dict(lock) if lock else None, "as_of": self.clock()}
        controlled = self.controlled_admin_read(db, actor, path, query)
        if controlled is not None:
            return controlled
        commerce = self.commerce_read(db, actor, path, query)
        if commerce is not None:
            return commerce
        save = self.admin_save_read(db, actor, path, query)
        if save is not None:
            return save
        job = self.admin_job_read(db, actor, path, query)
        if job is not None:
            return job
        economy = self.economy_read(db, actor, path, query)
        if economy is not None:
            return economy
        if path == "/admin/v1/me":
            require(not query, "invalid_query", "Unexpected query")
            return {"administrator": dict(actor, permissions=sorted(ROLES[actor["role"]]))}
        if path == "/admin/v1/overview":
            self.admin_permission(actor, "overview")
            require(not set(query) - {"day"}, "invalid_query", "Unexpected query")
            day = query.get("day", day_key(self.clock()))
            string(day, 10, 10, "day", r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
            start = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=SHANGHAI).timestamp()
            now = self.clock()
            scalar = lambda sql, args=(): db.execute(sql, args).fetchone()[0]
            online = scalar(f"""SELECT count(*) FROM {PLAYER_PRESENCE} p JOIN accounts a ON a.owner=p.owner
                          WHERE p.updated>? AND EXISTS(SELECT 1 FROM account_sessions s WHERE s.owner=p.owner AND s.expires>?)""", (now - 20, now))
            series = [dict(row) for row in db.execute("""SELECT day,count(*) AS active_accounts,CAST(sum(seconds) AS INTEGER) AS observed_seconds
                                  FROM player_activity WHERE day BETWEEN ? AND ? GROUP BY day ORDER BY day""",
                                  (day_key(start - 29 * 86400), day))]
            return {"timezone": "Asia/Shanghai", "as_of": now, "day": day,
                    "collection_started": float(scalar("SELECT value FROM admin_metadata WHERE key='collection_started'")),
                    "accounts": scalar("SELECT count(*) FROM accounts"),
                    "legacy_identities": scalar("SELECT count(*) FROM identities i WHERE NOT EXISTS(SELECT 1 FROM accounts a WHERE a.owner=i.id)"),
                    "new_accounts": scalar("SELECT count(*) FROM identities i JOIN accounts a ON a.owner=i.id WHERE i.created>=? AND i.created<?", (start, start + 86400)),
                    "online": online,
                    "dau": scalar("SELECT count(*) FROM player_activity WHERE day=?", (day,)),
                    "wau": scalar("SELECT count(DISTINCT owner) FROM player_activity WHERE day BETWEEN ? AND ?", (day_key(start - 6 * 86400), day)),
                    "mau": scalar("SELECT count(DISTINCT owner) FROM player_activity WHERE day BETWEEN ? AND ?", (day_key(start - 29 * 86400), day)),
                    "peak_online": scalar("SELECT coalesce(max(peak),0) FROM admin_online_peaks WHERE day=?", (day,)),
                    "banned": scalar("SELECT count(*) FROM player_controls WHERE ban_until>?", (now,)),
                    "muted": scalar("SELECT count(*) FROM player_controls WHERE mute_until>?", (now,)),
                    "cloud_slots": scalar("SELECT count(*) FROM cloud_saves"),
                    "summarized_slots": scalar("SELECT count(*) FROM save_summaries s JOIN cloud_saves c ON c.owner=s.owner AND c.slot=s.slot AND c.revision=s.revision WHERE json_extract(s.document,'$.extractor_version')=?", (SAVE_EXTRACTOR_VERSION,)),
                    "hosted_assets": scalar("SELECT count(*) FROM hosted_assets"), "activity": series,
                    "controlled_characters": scalar("SELECT count(*) FROM controlled_characters"),
                    "controlled_gold": scalar("SELECT coalesce(sum(balance),0) FROM shop_wallets WHERE currency='GOLD'"),
                    "controlled_gold_issued_today": scalar("SELECT coalesce(-sum(amount),0) FROM economy_entries WHERE currency='GOLD' AND account='system:issuance' AND created>=? AND created<?", (start, start + 86400)),
                    "controlled_gold_retired_today": scalar("SELECT coalesce(sum(amount),0) FROM economy_entries WHERE currency='GOLD' AND account='system:retired' AND created>=? AND created<?", (start, start + 86400)),
                    "mainline_gold": self.snapshot_gold_total(db)}
        if path == "/admin/v1/players":
            self.admin_permission(actor, "players")
            require(not set(query) - {"q", "after", "limit", "state"}, "invalid_query", "Unexpected query")
            search = string(query.get("q", ""), 0, 80, "q").lower()
            after = string(query.get("after", ""), 0, 80, "after")
            limit = integer(int(query.get("limit", "30")), 1, 100, "limit")
            state = query.get("state", "all")
            require(state in ("all", "online", "banned", "muted"), "invalid_query", "Invalid player state")
            online_sql = "p.updated>? AND (a.owner IS NULL OR EXISTS(SELECT 1 FROM account_sessions s WHERE s.owner=i.id AND s.expires>?))"
            conditions = {"all": "1", "online": online_sql, "banned": "c.ban_until>?", "muted": "c.mute_until>?"}
            args = [self.clock() - 20, self.clock(), after, search, search, search, search]
            if state != "all":
                args.append(self.clock() - 20 if state == "online" else self.clock())
                if state == "online":
                    args.append(self.clock())
            args.append(limit + 1)
            rows = db.execute("SELECT (" + online_sql + """ ) AS online,i.id,i.nickname,i.friend_code,i.created,a.username,p.updated AS last_world_heartbeat,
                        coalesce(c.version,0) AS control_version,coalesce(c.ban_until,0) AS ban_until,
                        coalesce(c.mute_until,0) AS mute_until,coalesce(c.trade_frozen,0) AS trade_frozen
                        FROM identities i LEFT JOIN accounts a ON a.owner=i.id
                        LEFT JOIN """ + PLAYER_PRESENCE + """ p ON p.owner=i.id LEFT JOIN player_controls c ON c.owner=i.id
                        WHERE i.id>? AND (instr(lower(i.id),?) OR instr(lower(i.nickname),?) OR
                          instr(lower(i.friend_code),?) OR instr(coalesce(a.username,''),?)) AND """ + conditions[state] + " ORDER BY i.id LIMIT ?", args).fetchall()
            return {"players": [dict(row) for row in rows[:limit]], "next_cursor": rows[limit - 1]["id"] if len(rows) > limit else None,
                    "as_of": self.clock()}
        if path.startswith("/admin/v1/players/"):
            self.admin_permission(actor, "players")
            require(not query, "invalid_query", "Unexpected query")
            owner = string(path.rsplit("/", 1)[1], 1, 80, "owner", r"[A-Za-z0-9_-]+")
            row = db.execute("""SELECT i.id,i.nickname,i.friend_code,i.created,a.username FROM identities i
                             LEFT JOIN accounts a ON a.owner=i.id WHERE i.id=?""", (owner,)).fetchone()
            require(row is not None, "player_not_found", "Player does not exist", 404)
            saves = []
            for item in db.execute("""SELECT c.slot,c.revision,c.updated,s.document,s.revision AS summary_revision
                     FROM cloud_saves c LEFT JOIN save_summaries s ON c.owner=s.owner AND c.slot=s.slot WHERE c.owner=? ORDER BY c.slot""", (owner,)):
                projection = json.loads(item["document"]) if item["document"] else None
                current = item["summary_revision"] == item["revision"] and projection is not None and projection.get("extractor_version") == SAVE_EXTRACTOR_VERSION
                saves.append({"slot": item["slot"], "revision": item["revision"], "uploaded_at": item["updated"],
                              "summary": projection if current else {"status": "pending", "source": "untrusted_cloud_snapshot"}})
            presence = db.execute("SELECT updated,document FROM world_presence WHERE owner=? AND updated>?", (owner, self.clock() - 20)).fetchone()
            native = db.execute("SELECT s.last_seen AS updated,s.view FROM original_states s JOIN controlled_characters c ON c.id=s.character_id WHERE c.owner=? AND s.last_seen>? ORDER BY s.last_seen DESC LIMIT 1", (owner, self.clock() - 20)).fetchone()
            if native and (not presence or native["updated"] > presence["updated"]):
                presence = {"updated": native["updated"], "document": dumps(dict(json.loads(native["view"]).get("world", {}), source="controlled_original"))}
            if presence and row["username"] is not None and not db.execute("SELECT 1 FROM account_sessions WHERE owner=? AND expires>?", (owner, self.clock())).fetchone():
                presence = None
            # Hosted asset snapshots are bounded by the existing game's validator.
            assets = []
            for item in db.execute("SELECT id,document FROM hosted_assets WHERE owner=? ORDER BY id LIMIT 100", (owner,)):
                asset = json.loads(item["document"])
                snapshot = asset.get("snapshot", {})
                assets.append({"id": item["id"], "source": asset.get("source"),
                               "species": snapshot.get("species"), "level": snapshot.get("level"),
                               "locked": bool(db.execute("SELECT 1 FROM asset_locks WHERE asset_id=?", (item["id"],)).fetchone())})
            try:
                controlled_catalog = self.controlled_catalog()
            except APIError:
                controlled_catalog = {"items": [], "unavailable": True}
            return {"player": dict(row), "controls": self.controls(db, owner), "saves": saves, "hosted_assets": assets,
                    "wallets": [self.shop_wallet(db, owner, currency) for currency in ("RP", "MARKET")],
                    "controlled_characters": [self.controlled_view(db, dict(item)) for item in db.execute("SELECT * FROM controlled_characters WHERE owner=? ORDER BY created,id", (owner,)).fetchall()],
                    "controlled_catalog": controlled_catalog,
                    "maintenance": dict(maintenance) if (maintenance := db.execute("SELECT id,actor,created FROM player_maintenance WHERE owner=?", (owner,)).fetchone()) else None,
                    "characters": [dict(item, slots=[entry[0] for entry in db.execute("SELECT slot FROM character_slots WHERE character_id=? ORDER BY slot", (item["id"],))]) for item in db.execute("SELECT id,canonical_slot,created FROM online_characters WHERE owner=? ORDER BY created", (owner,)).fetchall()],
                    "presence": {"heartbeat_at": presence["updated"], "position": json.loads(presence["document"])} if presence else None,
                    "sessions": [dict(item) for item in db.execute("SELECT expires FROM account_sessions WHERE owner=? AND expires>? ORDER BY expires DESC LIMIT 50", (owner, self.clock()))],
                    "activity": [dict(item) for item in db.execute("SELECT day,first,last,seconds FROM player_activity WHERE owner=? ORDER BY day DESC LIMIT 30", (owner,))],
                    "history": self.audit_rows(db, owner, 0, 30), "as_of": self.clock()}
        if path == "/admin/v1/audit":
            self.admin_permission(actor, "audit")
            require(not set(query) - {"target", "before", "limit"}, "invalid_query", "Unexpected query")
            return {"entries": self.audit_rows(db, string(query.get("target", ""), 0, 80, "target"),
                                               integer(int(query.get("before", "0")), 0, 2**53 - 1, "before"),
                                               integer(int(query.get("limit", "50")), 1, 100, "limit"))}
        if path.startswith("/admin/v1/commands/"):
            require(not query, "invalid_query", "Unexpected query")
            command = db.execute("SELECT actor,response FROM admin_commands WHERE id=?", (path.rsplit("/", 1)[1],)).fetchone()
            require(command is not None, "command_not_found", "Command does not exist", 404)
            require(command["actor"] == actor["username"] or actor["role"] == "admin", "admin_forbidden", "Command belongs to another administrator", 403)
            return json.loads(command["response"])
        raise APIError(404, "not_found", "Unknown administrator endpoint")

    def audit_rows(self, db, target, before, limit):
        return [dict(row, detail=json.loads(row["document"])) for row in db.execute(
            "SELECT id,actor,action,target,reason,document,created FROM admin_audit WHERE (?='' OR target=?) AND (?=0 OR id<?) ORDER BY id DESC LIMIT ?",
            (target, target, before, before, limit))]

    def admin_command(self, db, actor, body, prepared=None):
        if body.get("action") in ("request_original_rollback", "approve_original_rollback", "cancel_original_rollback"):
            return self.original_rollback_command(db, actor, body, prepared)
        if body.get("action") in ("request_save_rollback", "approve_save_rollback", "cancel_save_rollback"):
            return self.admin_rollback_command(db, actor, body, prepared)
        if body.get("action") in ("adjust_inventory", "approve_inventory"):
            return self.controlled_admin_command(db, actor, body)
        if body.get("action") in ("commerce_control", "create_code", "disable_code", "refund_order", "approve_commerce", "cancel_listing"):
            return self.commerce_command(db, actor, body)
        if body.get("action") in ("batch_wallet", "approve_batch"):
            return self.economy_batch_command(db, actor, body)
        if body.get("action") in ("begin_maintenance", "end_maintenance", "repair_save_money", "group_character"):
            return self.admin_save_command(db, actor, body, prepared)
        if body.get("action") == "alert_status":
            return self.admin_alert_command(db, actor, body)
        if body.get("action") in ("adjust_wallet", "approve_wallet"):
            return self.economy_command(db, actor, body)
        obj(body, {"id", "action", "target", "reason", "expected_version", "duration_seconds"}, {"id", "action", "target", "reason", "expected_version"})
        command_id = string(body["id"], 16, 100, "id", r"[A-Za-z0-9_-]+")
        action = string(body["action"], 1, 32, "action")
        require(action in ("ban", "unban", "mute", "unmute", "kick", "note", "freeze_trade", "unfreeze_trade"), "invalid_action", "Unsupported command")
        self.admin_permission(actor, "players" if action == "note" else "moderate")
        # Notes also need a mutation permission, not merely access to a page.
        if action == "note":
            require(actor["role"] != "observer", "admin_forbidden", "Read-only role cannot add notes", 403)
        owner = string(body["target"], 1, 80, "target", r"[A-Za-z0-9_-]+")
        reason = string(body["reason"], 3, 500, "reason")
        expected = integer(body["expected_version"], 0, 2**53 - 1, "expected_version")
        duration = integer(body.get("duration_seconds", 86400), 0, 365 * 86400, "duration_seconds")
        require(action in ("ban", "mute") or "duration_seconds" not in body, "invalid_command", "Duration only applies to ban/mute")
        fingerprint = digest(dumps(body))
        old = db.execute("SELECT * FROM admin_commands WHERE id=?", (command_id,)).fetchone()
        if old:
            require(old["actor"] == actor["username"] and old["fingerprint"] == fingerprint, "command_conflict", "Command ID already used", 409)
            return 200, json.loads(old["response"])
        require(db.execute("SELECT 1 FROM identities WHERE id=?", (owner,)).fetchone() is not None, "player_not_found", "Player does not exist", 404)
        before = self.controls(db, owner)
        require(before["version"] == expected, "control_version_conflict", "Player state changed; refresh and review", 409)
        after = dict(before, version=before["version"] + 1)
        until = self.clock() + duration if duration else 253402214400
        if action in ("ban", "unban"):
            after["ban_until"] = until if action == "ban" else 0
        if action in ("mute", "unmute"):
            after["mute_until"] = until if action == "mute" else 0
        if action in ("freeze_trade", "unfreeze_trade"):
            after["trade_frozen"] = int(action == "freeze_trade")
        if action in ("ban", "kick"):
            db.execute("DELETE FROM account_sessions WHERE owner=?", (owner,))
            db.execute("UPDATE identities SET token_hash=? WHERE id=?", (digest(secrets.token_urlsafe(32)), owner))
            db.execute("DELETE FROM cloud_leases WHERE owner=?", (owner,))
            db.execute("DELETE FROM world_presence WHERE owner=?", (owner,))
            db.execute("DELETE FROM cloud_chunks WHERE owner=?", (owner,))
        db.execute("INSERT OR REPLACE INTO player_controls VALUES(?,?,?,?,?)",
                   tuple(after[key] for key in ("owner", "version", "ban_until", "mute_until", "trade_frozen")))
        result = {"ok": True, "command_id": command_id, "status": "completed", "target": owner, "controls": after}
        self.audit(db, actor["username"], action, owner, reason, {"command_id": command_id, "before": before, "after": after})
        db.execute("INSERT INTO admin_commands VALUES(?,?,?,?,?)", (command_id, actor["username"], fingerprint, dumps(result), self.clock()))
        return 200, result

    def refresh_admin_summaries(self, batch=4):
        with closing(readonly(self.database)) as db:
            rows = db.execute("""SELECT c.owner,c.slot,c.revision,c.document FROM save_summary_queue q JOIN cloud_saves c
                       ON c.owner=q.owner AND c.slot=q.slot AND c.revision=q.revision
                       ORDER BY c.updated LIMIT ?""", (batch,)).fetchall()
        for row in rows:
            if self.admin_stop.is_set():
                break
            try:
                summary = summarize_save(json.loads(row["document"]))
            except (ValueError, TypeError, KeyError, RecursionError, OverflowError, zlib.error):
                summary = {"status": "invalid", "source": "untrusted_cloud_snapshot", "money": None, "extractor_version": SAVE_EXTRACTOR_VERSION}
            with self.connect() as db:
                # A concurrent upload cannot cause a stale projection to replace
                # the result for the new revision.
                current = db.execute("SELECT revision FROM cloud_saves WHERE owner=? AND slot=?", (row["owner"], row["slot"])).fetchone()
                if current and current[0] == row["revision"]:
                    db.execute("INSERT OR REPLACE INTO save_summaries VALUES(?,?,?,?,?)",
                               (row["owner"], row["slot"], row["revision"], dumps(summary), self.clock()))
                    db.execute("DELETE FROM save_summary_queue WHERE owner=? AND slot=? AND revision=?", (row["owner"], row["slot"], row["revision"]))
        return len(rows)

    def start_admin_worker(self):
        if self.admin_worker is not None:
            return
        def run():
            while not self.admin_stop.is_set():
                try:
                    count = self.refresh_admin_summaries()
                    self.process_admin_export()
                    if self.clock() - self.admin_last_risk_scan >= 60:
                        self.scan_admin_risks()
                except (sqlite3.Error, OSError):
                    count = 0
                self.admin_stop.wait(0.1 if count else 2)
        self.admin_worker = threading.Thread(target=run, name="admin-save-projection", daemon=True)
        self.admin_worker.start()

    def stop_admin_worker(self):
        self.admin_stop.set()
        if self.admin_worker:
            self.admin_worker.join(timeout=5)
