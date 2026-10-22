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

MAX_CLOUD_BODY = 2 * 1024 * 1024
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
            CREATE TABLE IF NOT EXISTS cloud_chunks(owner TEXT NOT NULL,upload_id TEXT NOT NULL,part INTEGER NOT NULL,total INTEGER NOT NULL,sha TEXT NOT NULL,payload BLOB NOT NULL,created REAL NOT NULL,PRIMARY KEY(owner,upload_id,part));
            CREATE TABLE IF NOT EXISTS cloud_chunk_receipts(owner TEXT NOT NULL,upload_id TEXT NOT NULL,sha TEXT NOT NULL,response TEXT NOT NULL,PRIMARY KEY(owner,upload_id));
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

    def auth_request(self, path, body, peer):
        obj(body, {"username", "password", "nickname", "protocol"}, {"username", "password", "protocol"})
        require(type(body["protocol"]) is int and body["protocol"] == PROTOCOL, "protocol_mismatch", "Protocol version is incompatible", 409)
        username = string(body["username"], 3, 32, "username", r"[A-Za-z0-9_]+(?:[.-][A-Za-z0-9_]+)*").lower()
        password = string(body["password"], 8, 128, "password")
        # Limit both address and account guessing, and bound the in-memory keys.
        now = self.clock()
        with self.auth_lock:
            self.auth_attempts = {key: [t for t in times if t > now - 300] for key, times in self.auth_attempts.items() if times and times[-1] > now - 300}
            require(len(self.auth_attempts) < 10000, "auth_rate_limited", "Please retry login later", 429)
            for key in ("peer:" + peer, "user:" + username):
                attempts = self.auth_attempts.setdefault(key, [])
                require(len(attempts) < (60 if key.startswith("peer:") else 12), "auth_rate_limited", "Too many attempts; retry in five minutes", 429)
                attempts.append(now)
        require(self.auth_slots.acquire(blocking=False), "auth_busy", "Authentication is busy; retry shortly", 429)
        try:
            with self.connect() as db:
                found = db.execute("SELECT * FROM accounts WHERE username=?", (username,)).fetchone()
                row = dict(found) if found else None
            registering = path == "/v1/auth/register"
            nickname = string(body.get("nickname", body["username"]), 1, 32, "nickname") if registering else None
            if registering:
                require(row is None, "username_taken", "Username is already registered", 409)
            salt = secrets.token_hex(16) if registering else row["salt"] if row else "00" * 16
            # The expensive KDF holds neither the SQLite transaction nor the
            # game's shared request lock. At most auth_concurrency KDFs run.
            computed = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt), n=16384, r=8, p=1).hex()
            if not registering:
                require(row is not None and hmac.compare_digest(computed, row["password_hash"]), "login_invalid", "Incorrect username or password", 401)
            with self.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                current = db.execute("SELECT * FROM accounts WHERE username=?", (username,)).fetchone()
                if registering:
                    require(current is None, "username_taken", "Username is already registered", 409)
                    owner = "p_" + secrets.token_hex(12)
                    friend = secrets.token_hex(4).upper()
                    while db.execute("SELECT 1 FROM identities WHERE friend_code=?", (friend,)).fetchone():
                        friend = secrets.token_hex(4).upper()
                    db.execute("INSERT INTO identities VALUES(?,?,?,?,?,?)", (owner, nickname, friend, digest(secrets.token_urlsafe(32)), digest(secrets.token_urlsafe(32)), now))
                    db.execute("INSERT INTO accounts VALUES(?,?,?,?)", (username, owner, salt, computed))
                else:
                    # A concurrent password reset/account change must invalidate
                    # the result computed from the old credentials.
                    require(current is not None and dict(current) == row, "login_invalid", "Account credentials changed; log in again", 401)
                    owner = row["owner"]
                token = secrets.token_urlsafe(32)
                issued = self.clock()
                expires = issued + 7 * 86400
                db.execute("DELETE FROM account_sessions WHERE expires<=?", (issued,))
                db.execute("INSERT INTO account_sessions VALUES(?,?,?)", (digest(token), owner, expires))
                identity = dict(db.execute("SELECT id,nickname,friend_code FROM identities WHERE id=?", (owner,)).fetchone())
                return (201 if registering else 200), {"ok": True, "identity": identity, "username": username, "token": token, "expires_at": expires}
        finally:
            self.auth_slots.release()

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
        if action == "chunk":
            return self.cloud_chunk(db, identity, body)
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
        payload = string(document["payload"], 4, 1400000, "payload", r"[A-Za-z0-9+/]*={0,2}")
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

    def cloud_chunk(self, db, identity, body):
        obj(body, {"session_id", "upload_id", "index", "total", "sha256", "data"}, {"session_id", "upload_id", "index", "total", "sha256", "data"})
        owner, now = identity["id"], self.clock()
        upload_id = string(body["upload_id"], 16, 80, "upload_id", r"[A-Za-z0-9_-]+")
        total = integer(body["total"], 1, 128, "total")
        index = integer(body["index"], 0, total - 1, "index")
        sha = string(body["sha256"], 64, 64, "sha256", r"[a-f0-9]{64}")
        encoded = string(body["data"], 4, 24000, "data", r"[A-Za-z0-9+/]*={0,2}")
        try:
            payload = base64.b64decode(encoded, validate=True)
        except ValueError:
            require(False, "invalid_chunk", "Invalid chunk encoding")
        require(0 < len(payload) <= 16384, "invalid_chunk", "Chunk is too large")
        old = db.execute("SELECT sha,response FROM cloud_chunk_receipts WHERE owner=? AND upload_id=?", (owner, upload_id)).fetchone()
        if old:
            require(old["sha"] == sha, "upload_conflict", "Chunk upload ID reused for different data", 409)
            return 200, json.loads(old["response"])
        db.execute("DELETE FROM cloud_chunks WHERE created<?", (now - 300,))
        first = db.execute("SELECT total,sha FROM cloud_chunks WHERE owner=? AND upload_id=? LIMIT 1", (owner, upload_id)).fetchone()
        if first:
            require(first["total"] == total and first["sha"] == sha, "upload_conflict", "Chunk metadata changed", 409)
        else:
            count = db.execute("SELECT COUNT(DISTINCT upload_id) FROM cloud_chunks WHERE owner=?", (owner,)).fetchone()[0]
            require(count < 2, "cloud_chunk_busy", "Finish the current upload first", 409)
        previous = db.execute("SELECT payload FROM cloud_chunks WHERE owner=? AND upload_id=? AND part=?", (owner, upload_id, index)).fetchone()
        require(previous is None or previous["payload"] == payload, "upload_conflict", "Chunk data changed", 409)
        db.execute("INSERT OR REPLACE INTO cloud_chunks VALUES(?,?,?,?,?,?,?)", (owner, upload_id, index, total, sha, payload, now))
        chunks = db.execute("SELECT part,payload FROM cloud_chunks WHERE owner=? AND upload_id=? ORDER BY part", (owner, upload_id)).fetchall()
        require(sum(len(row["payload"]) for row in chunks) <= MAX_CLOUD_BODY, "body_too_large", "Cloud upload exceeds size limit", 413)
        if len(chunks) != total:
            next_index = 0
            for row in chunks:
                if row["part"] != next_index:
                    break
                next_index += 1
            return 200, {"ok": True, "upload_id": upload_id, "next_index": next_index}
        raw = b"".join(row["payload"] for row in chunks)
        require(hashlib.sha256(raw).hexdigest() == sha, "save_checksum", "Chunk upload checksum mismatch")
        original = json.loads(raw.decode("utf-8"))
        obj(original)
        require(original.get("session_id") in (None, body["session_id"]) and original.get("upload_id") == upload_id, "upload_conflict", "Chunk owner session or upload ID changed", 409)
        original["session_id"] = body["session_id"]
        status, response = self.cloud_request(db, identity, "POST", ["v1", "cloud", "upload"], original)
        db.execute("INSERT INTO cloud_chunk_receipts VALUES(?,?,?,?)", (owner, upload_id, sha, dumps(response)))
        db.execute("DELETE FROM cloud_chunks WHERE owner=? AND upload_id=?", (owner, upload_id))
        return status, response

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
        # Keep old world clients working: their parser knows only map/world.
        # Current-build clients additionally receive trade messages and invites.
        trade_build = False
        try:
            current = json.loads(self.catalog_path.read_text(encoding='utf-8-sig'))['compatibility']
            trade_build = json.loads(member['compatibility']) == current
        except (OSError,ValueError,KeyError,AttributeError):
            pass
        rows = db.execute("SELECT id,document FROM chat_messages WHERE (channel='world' OR (channel='trade' AND ?) OR map_key=?) AND id>? ORDER BY id " + ("DESC" if after == 0 else "ASC") + " LIMIT 50", (int(trade_build), member["map_key"], after)).fetchall()
        rows = list(reversed(rows)) if after == 0 else rows
        cursor = rows[-1]["id"] if rows else max(after, db.execute("SELECT COALESCE(MAX(id),0) FROM chat_messages").fetchone()[0])
        # Online mode keeps its single-writer lease alive even during menus.
        db.execute("UPDATE cloud_leases SET expires=? WHERE owner=? AND session_id=? AND expires>?", (now + 120, owner, session, now))
        invites = []
        if trade_build:
            for row in db.execute("SELECT x.id,x.idle,i.nickname,i.friend_code FROM exchange_sessions x JOIN identities i ON i.id=x.host WHERE x.guest=? AND x.status='invited' AND x.idle>? AND x.expires>? ORDER BY x.id LIMIT 5",(owner,now,now)):
                invites.append({'id':row['id'],'nickname':row['nickname'],'friend_code':row['friend_code'],'expires_at':row['idle']})
        return 200, {"ok": True, "world": {"players": players, "map_key": member["map_key"], "messages": [json.loads(row["document"]) for row in rows], "cursor": cursor, "server_time": now, 'trade_invites':invites}}

    def chat_request(self, db, identity, method, parts, body):
        require(method == "POST" and parts == ["v1", "chat", "send"], "not_found", "Unknown chat operation", 404)
        obj(body, {"session_id", "client_id", "channel", "text", "listing_id"}, {"session_id", "client_id", "channel", "text"})
        owner, now = identity["id"], self.clock()
        member = self.world_member(db, owner, self.online_session_id(body))
        client_id = string(body["client_id"], 16, 80, "client_id", r"[A-Za-z0-9_-]+")
        require(body["channel"] in ("map", "world", "trade"), "invalid_channel", "Choose map, world or trade chat")
        text = string(body["text"], 1, 200, "text")
        require(text.strip() == text and text.strip(), "invalid_message", "Chat message is empty or has surrounding whitespace")
        require(not any(ord(c) == 127 or 0x202A <= ord(c) <= 0x202E or 0x2066 <= ord(c) <= 0x2069 for c in text), "invalid_message", "Unsupported control character")
        material = [body['channel'],text]
        if 'listing_id' in body:
            require(body['channel']=='trade','invalid_channel','Listing cards require the trade channel')
            string(body['listing_id'],1,80,'listing_id',r'[A-Za-z0-9_-]+')
            material.append(body['listing_id'])
        fingerprint = digest(dumps(material))
        old = db.execute("SELECT fingerprint,document FROM chat_messages WHERE owner=? AND client_id=?", (owner, client_id)).fetchone()
        if old:
            require(old["fingerprint"] == fingerprint, "message_conflict", "Message ID reused for different text", 409)
            return 200, {"ok": True, "message": json.loads(old["document"])}
        require(body["channel"] in ("world","trade") or member["map_key"] is not None, "map_chat_unavailable", "Enter a map before using map chat", 409)
        count = db.execute("SELECT COUNT(*) FROM chat_messages WHERE owner=? AND created>?", (owner, now - 3)).fetchone()[0]
        require(count < 3, "chat_rate_limited", "Please wait before sending more messages", 429)
        map_key = member["map_key"] if body["channel"] == "map" else None
        message = {"sender_id": owner, "nickname": identity["nickname"], "channel": body["channel"], "map_key": map_key, "text": text, "created_at": now}
        if 'listing_id' in body:
            listing = self.market_listing(db,body['listing_id'])
            require(listing['status']=='active' and listing['seller_id']==owner,'listing_unavailable','Only the seller can share an active listing',409)
            message['listing'] = {key:listing[key] for key in ('id','price','currency')}
            message['listing'].update(kind=listing.get('kind','pokemon'),label=listing['item']['name'] if listing.get('kind')=='item' else listing['snapshot']['species'])
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
