"""Shared production configuration and read-only database validation.

Backup/inspection deliberately do not construct Store: its startup recovery is
only appropriate when starting the game service or explicitly initializing it.
"""
from dataclasses import dataclass
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import uuid

SCHEMA_VERSION = 5
REQUIRED_TABLES = {"accounts", "identities", "account_sessions", "cloud_saves", "cloud_uploads",
                   "cloud_chunks", "cloud_chunk_receipts", "cloud_leases", "world_presence", "chat_messages", "deployment_meta",
                   "rooms", "battles", "operations", "showcases", "gyms", "gym_versions", "gym_challenges",
                   "gym_favorites", "rewards", "trades", "trade_receipts", "pool_deposits", "hosted_assets",
                   "asset_locks", "halls", "dungeons", "replays", "cards",
                   "economy_meta", "wallet_accounts", "wallet_holds", "ledger_transactions", "ledger_entries", "trading_grants",
                   "market_listings", "market_orders", "trading_deliveries", "exchange_sessions", "trading_events"}


REQUIRED_TABLES |= {"inventory_accounts", "item_balances", "item_holds", "item_ledger_transactions", "item_ledger_entries", "trading_preferences"}

REQUIRED_TABLES |= {"ml_characters", "ml_party", "ml_jobs", "ml_claims", "ml_commands", "ml_credits"}

REQUIRED_TABLES |= {"ml_eggs", "ml_trade_evolutions"}

REQUIRED_TABLES |= {"ml_story_sessions", "ml_roamers"}

def atomic_bytes(path, data):
    path = Path(path)
    temporary = path.with_name(".tmp-" + uuid.uuid4().hex[:16])
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        if os.name != "nt":
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8"))


def sha256(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


@contextmanager
def readonly(path):
    connection = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
    try:
        yield connection
    finally:
        connection.close()


@dataclass(frozen=True)
class Config:
    domain: str
    data_dir: Path
    data_id_file: Path
    backup_dir: Path
    restic_repository_file: Path
    restic_password_file: Path
    restic_executable: str
    release_dir: Path
    required_mount: Path | None = None
    allow_local_repository: bool = False
    backup_credentials_file: Path | None = None

    @property
    def database(self):
        return self.data_dir / "multiplayer.sqlite3"

    @classmethod
    def load(cls, path):
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        allowed = set(cls.__dataclass_fields__)
        if not isinstance(raw, dict) or set(raw) - allowed:
            raise ValueError("Unknown production configuration fields")
        raw.setdefault("domain", "if.pikastairs.cc")
        if not isinstance(raw["domain"], str) or not re.fullmatch(r"(?=.{1,253}$)[a-z0-9]+(?:[.-][a-z0-9]+)*", raw["domain"]):
            raise ValueError("Invalid server domain")
        for name in ("data_dir", "data_id_file", "backup_dir", "restic_repository_file", "restic_password_file", "release_dir", "required_mount", "backup_credentials_file"):
            if name in ("required_mount", "backup_credentials_file") and raw.get(name) is None:
                continue
            value = raw.get(name)
            if not isinstance(value, str) or not Path(value).is_absolute():
                raise ValueError("Absolute configuration path required: " + name)
            raw[name] = Path(value).resolve()
        if type(raw.get("allow_local_repository", False)) is not bool:
            raise ValueError("allow_local_repository must be boolean")
        if not isinstance(raw.get("restic_executable"), str) or not raw["restic_executable"]:
            raise ValueError("Restic executable required")
        if raw["data_id_file"].is_relative_to(raw["data_dir"]):
            raise ValueError("Expected data identity must be stored outside the data directory")
        if (raw["data_dir"] == raw["data_dir"].parent or raw["backup_dir"] == raw["backup_dir"].parent or
                raw["data_dir"].is_relative_to(raw["backup_dir"])):
            raise ValueError("Backup staging must be a separate directory")
        return cls(**raw)

    def check_mount(self):
        if self.required_mount is not None:
            if not self.required_mount.is_mount() or not self.data_dir.is_relative_to(self.required_mount):
                raise RuntimeError("Required persistent mount is unavailable")

    def data_id(self):
        self.check_mount()
        value = self.data_id_file.read_text(encoding="ascii").strip()
        if not re.fullmatch(r"[a-f0-9]{32}", value):
            raise RuntimeError("Invalid expected data identity")
        return value


def inspect_database(path, expected_id, full=False):
    path = Path(path)
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise RuntimeError("Production database is missing; explicit init-db or restore is required")
    with readonly(path) as database:
        check = database.execute("PRAGMA " + ("integrity_check" if full else "quick_check")).fetchall()
        if check != [("ok",)]:
            raise RuntimeError("Database integrity check failed")
        tables = {row[0] for row in database.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not REQUIRED_TABLES <= tables:
            raise RuntimeError("Production database schema is incomplete")
        meta = dict(database.execute("SELECT name,value FROM deployment_meta"))
        if meta.get("schema_version") != str(SCHEMA_VERSION) or meta.get("data_id") != expected_id:
            raise RuntimeError("Production database version/identity differs from configured data disk")
        return {"data_id": expected_id, "schema_version": SCHEMA_VERSION,
                "accounts": database.execute("SELECT count(*) FROM accounts").fetchone()[0],
                "cloud_slots": database.execute("SELECT count(*) FROM cloud_saves").fetchone()[0],
                "journal_mode": database.execute("PRAGMA journal_mode").fetchone()[0]}
