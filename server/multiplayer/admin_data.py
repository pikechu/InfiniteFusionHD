"""Bounded save projections and administrator credential primitives.

This module never imports the Ruby runtime, constructs Store, or executes save
objects. A projection describes an untrusted uploaded snapshot, not ownership.
"""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import sqlite3
import struct
import time
from urllib.parse import parse_qs, urlsplit
import zlib

SHANGHAI = timezone(timedelta(hours=8))
SAVE_EXTRACTOR_VERSION = 2
ADMIN_REQUIRED_TABLES = frozenset("admin_users admin_sessions admin_login_attempts admin_audit admin_commands player_controls player_activity player_first_activity admin_online_peaks save_summaries save_summary_queue admin_metadata economy_entries economy_proposals economy_admin_usage economy_batches admin_exports admin_alerts player_maintenance cloud_history online_characters character_slots shop_wallets shop_ledger shop_orders shop_grants shop_equipment shop_codes shop_redemptions shop_attempts shop_controls shop_audit market_listings market_receipts".split())
ROLES = {
    "observer": frozenset({"overview", "players", "audit"}),
    "gm": frozenset({"overview", "players", "audit", "moderate"}),
    "operator": frozenset({"overview", "players", "audit", "moderate", "economy", "export"}),
    "admin": frozenset({"overview", "players", "audit", "moderate", "economy", "export", "administrators"}),
}


def day_key(timestamp):
    return datetime.fromtimestamp(timestamp, SHANGHAI).date().isoformat()


def validate_admin_schema(db):
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "admin_metadata" not in tables:
        return  # Explicitly supported upgrade from the pre-administration schema.
    marker = db.execute("SELECT value FROM admin_metadata WHERE key='schema_version'").fetchone()
    if marker:
        if marker[0] not in ("1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"):
            raise RuntimeError("Administration schema is incomplete; restore its journals instead of reinitializing")
        version = int(marker[0])
        expected = ADMIN_REQUIRED_TABLES | ({"commerce_proposals"} if version >= 2 else set())
        if version >= 3:
            expected |= {"controlled_characters", "controlled_inventory", "controlled_claims", "controlled_receipts", "controlled_item_events", "controlled_proposals"}
        if version >= 4:
            expected |= {"controlled_progress", "controlled_monsters", "controlled_battles", "controlled_rulebooks", "controlled_captures", "controlled_encounter_usage", "controlled_creature_events"}
        if version >= 5:
            expected |= {"save_rollback_proposals"}
        if version >= 6:
            expected |= {"market_sales"}
        if version >= 7:
            expected |= {"original_states", "original_receipts", "original_creatures", "original_events", "original_snapshots"}
        if version >= 8:
            expected |= {"original_migrations"}
        if version >= 9:
            expected |= {"original_market", "original_sales", "original_ownership", "original_offers", "original_trade_locks"}
        if version >= 10:
            expected |= {"original_lineage", "original_rollback_proposals", "original_rollback_runs"}
        if version >= 11 and "before_pending" not in {row[1] for row in db.execute("PRAGMA table_info(original_rollback_runs)")}:
            raise RuntimeError("Administration schema is incomplete; restore its journals instead of reinitializing")
        if not expected <= tables:
            raise RuntimeError("Administration schema is incomplete; restore its journals instead of reinitializing")


def password_digest(password, salt):
    return hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt), n=16384, r=8, p=1).hex()


def totp(secret, timestamp):
    key = base64.b32decode(secret, casefold=True)
    digest = hmac.new(key, struct.pack(">Q", int(timestamp // 30)), hashlib.sha1).digest()
    offset = digest[-1] & 15
    value = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7fffffff) % 1000000
    return f"{value:06d}"


def readonly(database):
    connection = sqlite3.connect(Path(database).resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    # Bound CPU work as well as lock waits for operator searches.
    deadline = time.monotonic() + 3
    connection.set_progress_handler(lambda: int(time.monotonic() > deadline), 2000)
    return connection


def split_admin_path(path):
    parsed = urlsplit(path)
    if len(path) > 2048 or parsed.fragment or not parsed.path.startswith("/admin/v1/"):
        raise ValueError("Invalid admin path")
    query = parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True, max_num_fields=12)
    if any(len(values) != 1 for values in query.values()):
        raise ValueError("Duplicate query parameter")
    return parsed.path, {key: values[0] for key, values in query.items()}


def init_schema(db):
    db.executescript("""
      CREATE TABLE IF NOT EXISTS admin_users(
        username TEXT PRIMARY KEY,salt TEXT NOT NULL,password_hash TEXT NOT NULL,
        role TEXT NOT NULL,totp_secret TEXT NOT NULL,last_counter INTEGER NOT NULL DEFAULT -1,
        enabled INTEGER NOT NULL DEFAULT 1,created REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS admin_sessions(
        token_hash TEXT PRIMARY KEY,username TEXT NOT NULL,expires REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS admin_login_attempts(
        bucket TEXT PRIMARY KEY,started REAL NOT NULL,attempts INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS admin_audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT,actor TEXT NOT NULL,action TEXT NOT NULL,
        target TEXT NOT NULL,reason TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
      CREATE INDEX IF NOT EXISTS admin_audit_target ON admin_audit(target,id);
      CREATE TABLE IF NOT EXISTS admin_commands(
        id TEXT PRIMARY KEY,actor TEXT NOT NULL,fingerprint TEXT NOT NULL,
        response TEXT NOT NULL,created REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS player_controls(
        owner TEXT PRIMARY KEY,version INTEGER NOT NULL DEFAULT 0,
        ban_until REAL NOT NULL DEFAULT 0,mute_until REAL NOT NULL DEFAULT 0,
        trade_frozen INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS player_activity(
        owner TEXT NOT NULL,day TEXT NOT NULL,first REAL NOT NULL,last REAL NOT NULL,
        seconds REAL NOT NULL DEFAULT 0,PRIMARY KEY(owner,day));
      CREATE INDEX IF NOT EXISTS player_activity_day ON player_activity(day,owner);
      CREATE TABLE IF NOT EXISTS admin_online_peaks(day TEXT PRIMARY KEY,peak INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS save_summaries(
        owner TEXT NOT NULL,slot TEXT NOT NULL,revision INTEGER NOT NULL,
        document TEXT NOT NULL,updated REAL NOT NULL,PRIMARY KEY(owner,slot));
      CREATE TABLE IF NOT EXISTS save_summary_queue(owner TEXT NOT NULL,slot TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(owner,slot));
      CREATE TRIGGER IF NOT EXISTS save_summary_queue_insert AFTER INSERT ON cloud_saves BEGIN
        INSERT INTO save_summary_queue VALUES(NEW.owner,NEW.slot,NEW.revision)
          ON CONFLICT(owner,slot) DO UPDATE SET revision=excluded.revision;
      END;
      CREATE TRIGGER IF NOT EXISTS save_summary_queue_update AFTER UPDATE ON cloud_saves BEGIN
        INSERT INTO save_summary_queue VALUES(NEW.owner,NEW.slot,NEW.revision)
          ON CONFLICT(owner,slot) DO UPDATE SET revision=excluded.revision;
      END;
      CREATE TABLE IF NOT EXISTS admin_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    """)
    db.execute("""INSERT OR REPLACE INTO save_summary_queue SELECT c.owner,c.slot,c.revision FROM cloud_saves c
        LEFT JOIN save_summaries s ON s.owner=c.owner AND s.slot=c.slot WHERE s.revision IS NULL OR s.revision!=c.revision
        OR coalesce(json_extract(s.document,'$.extractor_version'),0)!=?""", (SAVE_EXTRACTOR_VERSION,))


def create_administrator(db, username, password, role="admin", secret=None, now=None):
    """Local bootstrap only; there is deliberately no unauthenticated HTTP setup."""
    import re
    import time
    if not isinstance(username, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]{3,32}", username):
        raise ValueError("Administrator username must be 3..32 ASCII letters/digits/._-")
    if not isinstance(password, str) or not 12 <= len(password) <= 128 or role not in ROLES:
        raise ValueError("Use a 12..128 character password and a valid role")
    secret = secret or base64.b32encode(secrets.token_bytes(20)).decode("ascii")
    if len(base64.b32decode(secret, casefold=True)) < 20:
        raise ValueError("TOTP secret must contain at least 160 bits")
    salt = secrets.token_hex(16)
    # Call init_schema during service startup, never here: executescript commits.
    db.execute("INSERT INTO admin_users(username,salt,password_hash,role,totp_secret,created) VALUES(?,?,?,?,?,?)",
               (username.lower(), salt, password_digest(password, salt), role, secret, time.time() if now is None else now))
    return secret


class ProjectionError(ValueError):
    pass


def summarize_save(document):
    """Read a handful of white-listed graph fields without allocating objects."""
    def check(value):
        if not value:
            raise ProjectionError("Unsupported or malformed save graph")

    check(type(document) is dict and document.get("format") == "kif-save-json-v1")
    payload = document.get("payload")
    check(type(payload) is str and len(payload) <= 1398104)
    raw = base64.b64decode(payload, validate=True)
    check(len(raw) <= 1024 * 1024 and hashlib.sha256(raw).hexdigest() == document.get("sha256"))
    inflater = zlib.decompressobj()
    decoded = inflater.decompress(raw, 32 * 1024 * 1024 + 1)
    check(len(decoded) <= 32 * 1024 * 1024 and inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail)
    graph = json.loads(decoded, parse_constant=lambda _: (_ for _ in ()).throw(ProjectionError("Non-finite number")))
    check(type(graph) is dict and graph.get("version") == 1)
    nodes = graph.get("nodes")
    check(type(nodes) is list and 0 < len(nodes) <= 100000)

    def node(value):
        check(type(value) is dict and set(value) == {"ref"} and type(value["ref"]) is int and 0 <= value["ref"] < len(nodes))
        result = nodes[value["ref"]]
        check(type(result) is dict)
        return result

    def text(value):
        if type(value) is dict and set(value) == {"symbol"}:
            check(type(value["symbol"]) is str and len(value["symbol"]) <= 128)
            return value["symbol"]
        item = node(value)
        check(item.get("type") == "string" and type(item.get("bytes")) is str and len(item["bytes"]) <= 2048)
        return base64.b64decode(item["bytes"], validate=True).decode("utf-8", errors="replace")[:128]

    root = node(graph.get("root"))
    check(root.get("type") == "hash" and type(root.get("items")) is list and len(root["items"]) <= 1000)
    fields = {}
    for pair in root["items"]:
        check(type(pair) is list and len(pair) == 2)
        name = text(pair[0])
        # Ruby SaveData uses symbol keys. A string "player" is a different key
        # and must not shadow :player in a projection or a repair.
        if type(pair[0]) is dict and set(pair[0]) == {"symbol"}:
            fields[name] = pair[1]
    # KIF persists the active modded player alongside a vanilla compatibility
    # clone. SaveData and TradeSave prefer :kuray_player when it is present.
    player_ref = fields.get("kuray_player", fields.get("player", fields.get("trainer")))
    check(player_ref is not None)
    player = node(player_ref)
    check(player.get("type") == "object" and player.get("class") == "Player" and type(player.get("ivars")) is dict)
    ivars = player["ivars"]
    result = {"source": "untrusted_cloud_snapshot", "extractor_version": SAVE_EXTRACTOR_VERSION,
              "game_version": document.get("game_version"), "sha256": document["sha256"],
              "character_resolution": "unresolved", "money": None, "party_count": None,
              "trainer_name": None, "trainer_id": None, "badges": None, "status": "ready"}
    money = ivars.get("@money")
    check(money is None or type(money) is int and 0 <= money <= 2**53 - 1)
    result["money"] = money
    if "@name" in ivars:
        result["trainer_name"] = text(ivars["@name"])
    trainer_id = ivars.get("@id")
    if type(trainer_id) is int:
        result["trainer_id"] = trainer_id
    if "@party" in ivars:
        party = node(ivars["@party"])
        check(party.get("type") == "array" and type(party.get("items")) is list and len(party["items"]) <= 6)
        result["party_count"] = len(party["items"])
    if "@badges" in ivars:
        badges = node(ivars["@badges"])
        check(badges.get("type") == "array" and type(badges.get("items")) is list and len(badges["items"]) <= 256)
        result["badges"] = sum(value is True for value in badges["items"])
    return result


STATIC = {"/admin": "index.html", "/admin/": "index.html", "/admin/app.js": "app.js", "/admin/style.css": "style.css"}
SECURITY_HEADERS = [("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
                    ("Referrer-Policy", "no-referrer"),
                    ("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")]


def static_response(method, path):
    if method != "GET" or path not in STATIC:
        return None
    name = STATIC[path]
    content = (Path(__file__).parent / "admin_web" / name).read_bytes()
    content_type = {".html": "text/html", ".js": "text/javascript", ".css": "text/css"}[Path(name).suffix]
    return content, [("Content-Type", content_type + "; charset=utf-8"), ("Content-Length", str(len(content)))] + SECURITY_HEADERS
