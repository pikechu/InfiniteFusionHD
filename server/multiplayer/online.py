"""Account login, opaque JSON cloud saves, and ephemeral overworld presence.

Independent implementation informed by OpenMMO's authenticated session and
map-scoped presence design. No OpenMMO code or wire format is incorporated.
"""
import base64
import hashlib
import hmac
import json
import re
import secrets

MAX_CLOUD_BODY = 8 * 1024 * 1024
CLOUD_SLOTS = {"file-" + c for c in "abcdefgh"} | {"auto-1", "auto-2"}


def bind_api(api):
    for name in ("obj", "require", "string", "integer", "dumps", "digest", "validate_compatibility", "PROTOCOL"):
        globals()[name] = api[name]


class OnlineFeatures:
    def init_online(self, db):
        db.executescript("""
            CREATE TABLE IF NOT EXISTS accounts(username TEXT PRIMARY KEY,owner TEXT UNIQUE NOT NULL,salt TEXT NOT NULL,password_hash TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS account_sessions(token_hash TEXT PRIMARY KEY,owner TEXT NOT NULL,expires REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS cloud_leases(owner TEXT PRIMARY KEY,session_id TEXT NOT NULL,compatibility TEXT NOT NULL,expires REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS cloud_saves(owner TEXT NOT NULL,slot TEXT NOT NULL,revision INTEGER NOT NULL,document TEXT NOT NULL,updated REAL NOT NULL,PRIMARY KEY(owner,slot));
            CREATE TABLE IF NOT EXISTS cloud_uploads(owner TEXT NOT NULL,upload_id TEXT NOT NULL,fingerprint TEXT NOT NULL,slot TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(owner,upload_id));
            CREATE TABLE IF NOT EXISTS world_presence(owner TEXT PRIMARY KEY,session_id TEXT NOT NULL,compatibility TEXT NOT NULL,map_key TEXT,document TEXT NOT NULL,seq INTEGER NOT NULL,updated REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS world_presence_map ON world_presence(map_key,updated);
            CREATE TABLE IF NOT EXISTS chat_messages(id INTEGER PRIMARY KEY AUTOINCREMENT,owner TEXT NOT NULL,client_id TEXT NOT NULL,fingerprint TEXT NOT NULL,channel TEXT NOT NULL,map_key TEXT,document TEXT NOT NULL,created REAL NOT NULL,UNIQUE(owner,client_id));
            CREATE INDEX IF NOT EXISTS chat_scope ON chat_messages(channel,map_key,id);
        """)
        db.execute("DELETE FROM world_presence")
        self.auth_attempts = {}

    def account_identity(self, db, token):
        row = db.execute("""SELECT i.id,i.nickname,i.friend_code,a.username FROM account_sessions s
            JOIN identities i ON i.id=s.owner JOIN accounts a ON a.owner=i.id
            WHERE s.token_hash=? AND s.expires>?""", (digest(token or ""), self.clock())).fetchone()
        return dict(row) if row else None

    def auth_request(self, db, path, body, peer):
        obj(body, {"username", "password", "nickname", "protocol"}, {"username", "password", "protocol"})
        require(type(body["protocol"]) is int and body["protocol"] == PROTOCOL, "protocol_mismatch", "Protocol version is incompatible", 409)
        username = string(body["username"], 3, 32, "username", r"[A-Za-z0-9_]+(?:[.-][A-Za-z0-9_]+)*").lower()
        password = string(body["password"], 8, 128, "password")
        # Limit both address and account guessing, and bound the in-memory keys.
        now = self.clock()
        self.auth_attempts = {key: [t for t in times if t > now - 300] for key, times in self.auth_attempts.items() if times and times[-1] > now - 300}
        require(len(self.auth_attempts) < 10000, "auth_rate_limited", "Please retry login later", 429)
        for key in ("peer:" + peer, "user:" + username):
            attempts = self.auth_attempts.setdefault(key, [])
            require(len(attempts) < (60 if key.startswith("peer:") else 12), "auth_rate_limited", "Too many attempts; retry in five minutes", 429)
            attempts.append(now)
        row = db.execute("SELECT * FROM accounts WHERE username=?", (username,)).fetchone()
        if path == "/v1/auth/register":
            require(row is None, "username_taken", "Username is already registered", 409)
            nickname = string(body.get("nickname", body["username"]), 1, 32, "nickname")
            owner, salt = "p_" + secrets.token_hex(12), secrets.token_hex(16)
            password_hash = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt), n=16384, r=8, p=1).hex()
            db.execute("INSERT INTO identities VALUES(?,?,?,?,?,?)", (owner, nickname, secrets.token_hex(4).upper(), digest(secrets.token_urlsafe(32)), digest(secrets.token_urlsafe(32)), now))
            db.execute("INSERT INTO accounts VALUES(?,?,?,?)", (username, owner, salt, password_hash))
        else:
            # Use the same KDF for an unknown username to avoid a fast oracle.
            salt = row["salt"] if row else "00" * 16
            check = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt), n=16384, r=8, p=1).hex()
            require(row is not None and hmac.compare_digest(check, row["password_hash"]), "login_invalid", "Incorrect username or password", 401)
            owner = row["owner"]
        token = secrets.token_urlsafe(32)
        expires = now + 7 * 86400
        db.execute("DELETE FROM account_sessions WHERE expires<=?", (now,))
        db.execute("INSERT INTO account_sessions VALUES(?,?,?)", (digest(token), owner, expires))
        identity = dict(db.execute("SELECT id,nickname,friend_code FROM identities WHERE id=?", (owner,)).fetchone())
        return (201 if path.endswith("register") else 200), {"ok": True, "identity": identity, "username": username, "token": token, "expires_at": expires}

    def online_session_id(self, body):
        return string(body.get("session_id"), 16, 80, "session_id", r"[A-Za-z0-9_-]+")

    def cloud_lease(self, db, owner, session):
        lease = db.execute("SELECT * FROM cloud_leases WHERE owner=?", (owner,)).fetchone()
        require(lease is not None and lease["session_id"] == session and lease["expires"] > self.clock(), "cloud_session_lost", "Online save session expired or belongs to another device", 409)
        db.execute("UPDATE cloud_leases SET expires=? WHERE owner=?", (self.clock() + 120, owner))
        return lease

    def cloud_request(self, db, identity, method, parts, body):
        owner = identity["id"]
        require(db.execute("SELECT 1 FROM accounts WHERE owner=?", (owner,)).fetchone() is not None, "account_required", "Register or log in before online play", 403)
        require(method == "POST" and len(parts) == 3, "not_found", "Unknown cloud operation", 404)
        session = self.online_session_id(body)
        action = parts[2]
        if action == "open":
            obj(body, {"session_id", "compatibility"}, {"session_id", "compatibility"})
            compatibility = validate_compatibility(body["compatibility"])
            old = db.execute("SELECT * FROM cloud_leases WHERE owner=?", (owner,)).fetchone()
            require(old is None or old["session_id"] == session or old["expires"] <= self.clock(), "account_in_use", "This account is playing on another device; sign out there or wait two minutes", 409)
            db.execute("INSERT OR REPLACE INTO cloud_leases VALUES(?,?,?,?)", (owner, session, dumps(compatibility), self.clock() + 120))
            saves = [{"slot": row["slot"], "revision": row["revision"], "updated_at": row["updated"]} for row in db.execute("SELECT slot,revision,updated FROM cloud_saves WHERE owner=? ORDER BY slot", (owner,))]
            return 200, {"ok": True, "saves": saves, "lease_seconds": 120}
        self.cloud_lease(db, owner, session)
        if action in ("heartbeat", "close"):
            obj(body, {"session_id"}, {"session_id"})
            if action == "close":
                db.execute("DELETE FROM cloud_leases WHERE owner=? AND session_id=?", (owner, session))
                db.execute("DELETE FROM world_presence WHERE owner=? AND session_id=?", (owner, session))
            return 200, {"ok": True}
        slot = string(body.get("slot"), 6, 6, "slot")
        require(slot in CLOUD_SLOTS, "invalid_slot", "Unsupported cloud save slot")
        if action == "download":
            obj(body, {"session_id", "slot"}, {"session_id", "slot"})
            row = db.execute("SELECT revision,document FROM cloud_saves WHERE owner=? AND slot=?", (owner, slot)).fetchone()
            require(row is not None, "cloud_save_missing", "No cloud save in this slot", 404)
            return 200, {"ok": True, "slot": slot, "revision": row["revision"], "save": json.loads(row["document"])}
        require(action == "upload", "not_found", "Unknown cloud operation", 404)
        obj(body, {"session_id", "slot", "revision", "upload_id", "save"}, {"session_id", "slot", "revision", "upload_id", "save"})
        upload_id = string(body["upload_id"], 16, 80, "upload_id", r"[A-Za-z0-9_-]+")
        revision = integer(body["revision"], 0, 2**53 - 1, "revision")
        document = obj(body["save"], {"format", "game_version", "payload", "sha256"}, {"format", "game_version", "payload", "sha256"})
        require(document["format"] == "kif-save-json-v1", "save_format", "Unsupported cloud save format")
        string(document["game_version"], 1, 128, "game_version")
        payload = string(document["payload"], 4, 6 * 1024 * 1024, "payload", r"[A-Za-z0-9+/]*={0,2}")
        string(document["sha256"], 64, 64, "sha256", r"[a-f0-9]{64}")
        try:
            raw = base64.b64decode(payload, validate=True)
        except ValueError:
            require(False, "save_checksum", "Invalid cloud save encoding")
        require(hashlib.sha256(raw).hexdigest() == document["sha256"], "save_checksum", "Cloud save checksum mismatch")
        fingerprint = digest(dumps({"slot": slot, "revision": revision, "save": document}))
        old = db.execute("SELECT * FROM cloud_uploads WHERE owner=? AND upload_id=?", (owner, upload_id)).fetchone()
        if old:
            require(old["fingerprint"] == fingerprint, "upload_conflict", "Upload ID reused for different data", 409)
            return 200, {"ok": True, "slot": slot, "revision": old["revision"], "upload_id": upload_id}
        row = db.execute("SELECT revision FROM cloud_saves WHERE owner=? AND slot=?", (owner, slot)).fetchone()
        current = row["revision"] if row else 0
        require(current == revision, "cloud_revision_conflict", "Cloud save changed; keep local progress and log in again before resolving", 409)
        db.execute("INSERT OR REPLACE INTO cloud_saves VALUES(?,?,?,?,?)", (owner, slot, current + 1, dumps(document), self.clock()))
        db.execute("INSERT INTO cloud_uploads VALUES(?,?,?,?,?)", (owner, upload_id, fingerprint, slot, current + 1))
        return 200, {"ok": True, "slot": slot, "revision": current + 1, "upload_id": upload_id}

    def world_member(self, db, owner, session):
        row = db.execute("SELECT * FROM world_presence WHERE owner=?", (owner,)).fetchone()
        require(row is not None and row["session_id"] == session and row["updated"] > self.clock() - 20, "world_session_lost", "Rejoin the world session", 409)
        return row

    def world_position(self, position):
        if position is None:
            return None
        obj(position, {"map_id", "map_hash", "width", "height", "x", "y", "direction", "character_id", "moving"}, {"map_id", "map_hash", "width", "height", "x", "y", "direction", "character_id", "moving"})
        integer(position["map_id"], 1, 99999, "map_id")
        string(position["map_hash"], 64, 64, "map_hash", r"[a-f0-9]{64}")
        integer(position["width"], 1, 2000, "width")
        integer(position["height"], 1, 2000, "height")
        integer(position["x"], 0, position["width"] - 1, "x")
        integer(position["y"], 0, position["height"] - 1, "y")
        require(type(position["direction"]) is int and position["direction"] in (2, 4, 6, 8), "invalid_position", "Invalid direction")
        integer(position["character_id"], 0, 7, "character_id")
        require(type(position["moving"]) is bool, "invalid_position", "Invalid movement flag")
        return dict(position)

    def world_request(self, db, identity, method, parts, body):
        require(method == "POST" and len(parts) == 3, "not_found", "Unknown world operation", 404)
        owner, action = identity["id"], parts[2]
        session = self.online_session_id(body)
        now = self.clock()
        db.execute("DELETE FROM world_presence WHERE updated<=?", (now - 20,))
        if action == "join":
            obj(body, {"session_id", "compatibility"}, {"session_id", "compatibility"})
            compatibility = dumps(validate_compatibility(body["compatibility"]))
            old = db.execute("SELECT session_id FROM world_presence WHERE owner=?", (owner,)).fetchone()
            require(old is None or old["session_id"] == session, "world_in_use", "This identity is already in the world on another device", 409)
            if old is None:
                db.execute("INSERT INTO world_presence VALUES(?,?,?,?,?,?,?)", (owner, session, compatibility, None, "{}", -1, now))
            return 200, {"ok": True, "session_id": session}
        member = self.world_member(db, owner, session)
        if action == "leave":
            obj(body, {"session_id"}, {"session_id"})
            db.execute("DELETE FROM world_presence WHERE owner=? AND session_id=?", (owner, session))
            return 200, {"ok": True}
        require(action == "sync", "not_found", "Unknown world operation", 404)
        obj(body, {"session_id", "seq", "position", "after"}, {"session_id", "seq", "position", "after"})
        seq = integer(body["seq"], 0, 2**53 - 1, "seq")
        after = integer(body["after"], 0, 2**53 - 1, "after")
        position = self.world_position(body["position"])
        if seq > member["seq"]:
            map_key = digest(dumps([member["compatibility"], position["map_id"], position["map_hash"], position["width"], position["height"]])) if position else None
            document = dict(position or {}, id=owner, nickname=identity["nickname"], seq=seq)
            db.execute("UPDATE world_presence SET map_key=?,document=?,seq=?,updated=? WHERE owner=?", (map_key, dumps(document), seq, now, owner))
            member = self.world_member(db, owner, session)
        players = [json.loads(row["document"]) for row in db.execute("SELECT document FROM world_presence WHERE map_key=? AND owner!=? AND updated>? ORDER BY owner LIMIT 128", (member["map_key"], owner, now - 20))] if member["map_key"] else []
        rows = db.execute("SELECT id,document FROM chat_messages WHERE (channel='world' OR map_key=?) AND id>? ORDER BY id " + ("DESC" if after == 0 else "ASC") + " LIMIT 50", (member["map_key"], after)).fetchall()
        rows = list(reversed(rows)) if after == 0 else rows
        cursor = rows[-1]["id"] if rows else max(after, db.execute("SELECT COALESCE(MAX(id),0) FROM chat_messages").fetchone()[0])
        # Online mode keeps its single-writer lease alive even during menus.
        db.execute("UPDATE cloud_leases SET expires=? WHERE owner=? AND session_id=? AND expires>?", (now + 120, owner, session, now))
        return 200, {"ok": True, "world": {"players": players, "map_key": member["map_key"], "messages": [json.loads(row["document"]) for row in rows], "cursor": cursor, "server_time": now}}

    def chat_request(self, db, identity, method, parts, body):
        require(method == "POST" and parts == ["v1", "chat", "send"], "not_found", "Unknown chat operation", 404)
        obj(body, {"session_id", "client_id", "channel", "text"}, {"session_id", "client_id", "channel", "text"})
        owner, now = identity["id"], self.clock()
        member = self.world_member(db, owner, self.online_session_id(body))
        client_id = string(body["client_id"], 16, 80, "client_id", r"[A-Za-z0-9_-]+")
        require(body["channel"] in ("map", "world"), "invalid_channel", "Choose map or world chat")
        text = string(body["text"], 1, 200, "text")
        require(text.strip() == text and text.strip(), "invalid_message", "Chat message is empty or has surrounding whitespace")
        require(not any(ord(c) == 127 or 0x202A <= ord(c) <= 0x202E or 0x2066 <= ord(c) <= 0x2069 for c in text), "invalid_message", "Unsupported control character")
        fingerprint = digest(dumps([body["channel"], text]))
        old = db.execute("SELECT fingerprint,document FROM chat_messages WHERE owner=? AND client_id=?", (owner, client_id)).fetchone()
        if old:
            require(old["fingerprint"] == fingerprint, "message_conflict", "Message ID reused for different text", 409)
            return 200, {"ok": True, "message": json.loads(old["document"])}
        require(body["channel"] == "world" or member["map_key"] is not None, "map_chat_unavailable", "Enter a map before using map chat", 409)
        count = db.execute("SELECT COUNT(*) FROM chat_messages WHERE owner=? AND created>?", (owner, now - 3)).fetchone()[0]
        require(count < 3, "chat_rate_limited", "Please wait before sending more messages", 429)
        map_key = member["map_key"] if body["channel"] == "map" else None
        message = {"sender_id": owner, "nickname": identity["nickname"], "channel": body["channel"], "map_key": map_key, "text": text, "created_at": now}
        cursor = db.execute("INSERT INTO chat_messages(owner,client_id,fingerprint,channel,map_key,document,created) VALUES(?,?,?,?,?,?,?)", (owner, client_id, fingerprint, body["channel"], map_key, "{}", now)).lastrowid
        message["id"] = cursor
        db.execute("UPDATE chat_messages SET document=? WHERE id=?", (dumps(message), cursor))
        db.execute("DELETE FROM chat_messages WHERE created<? OR id<?", (now - 7 * 86400, cursor - 10000))
        return 201, {"ok": True, "message": message}

    def dispatch_online(self, db, identity, method, parts, body):
        if parts[:2] == ["v1", "cloud"]:
            return self.cloud_request(db, identity, method, parts, body)
        if parts[:2] == ["v1", "world"]:
            return self.world_request(db, identity, method, parts, body)
        if parts[:2] == ["v1", "chat"]:
            return self.chat_request(db, identity, method, parts, body)
        if parts == ["v1", "auth", "logout"] and method == "POST":
            obj(body, {"request_id"})
            # Logout closes this game's lease via /cloud/close before revocation.
            return 200, {"ok": True}
        return None
