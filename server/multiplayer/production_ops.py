"""Explicit initialization, live SQLite snapshots and encrypted Restic recovery.

No remote repository is configured or contacted until the operator supplies it.
All commands also run on Windows for isolated local validation.
"""
import argparse
from datetime import datetime, timezone
from dataclasses import replace
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import subprocess
import time
import uuid

from production_data import (Config, SCHEMA_VERSION, REQUIRED_TABLES, atomic_bytes, atomic_json,
                             inspect_database, readonly, sha256)
from service import Store, database_instance_lock


class ResticFailure(RuntimeError):
    def __init__(self, action, result):
        super().__init__("Restic " + action + " failed with exit code " + str(result.returncode))
        # Available to an explicit local diagnostic without leaking provider
        # credentials into routine CLI/service logs.
        self.stderr = result.stderr


def private_directory(path):
    Path(path).mkdir(parents=True, exist_ok=True, mode=0o777 if os.name == "nt" else 0o700)


def snapshot(source, destination):
    """Copy committed WAL state with the online backup API, without Store init."""
    deadline = time.monotonic() + 120
    def progress(_status, _remaining, _total):
        if time.monotonic() > deadline:
            raise RuntimeError("SQLite snapshot exceeded its deadline")
    with readonly(source) as origin:
        target = sqlite3.connect(destination)
        try:
            origin.backup(target, pages=256, progress=progress, sleep=0.05)
            target.execute("PRAGMA synchronous=FULL")
            # A snapshot is a self-contained file, not a live WAL database.
            # This also prevents read-only verification from creating sidecars
            # that could accidentally enter the encrypted backup.
            target.execute("PRAGMA journal_mode=DELETE")
        finally:
            target.close()
    # Windows FlushFileBuffers requires a writable handle even when no bytes
    # are being changed; Linux also accepts this explicit durable flush.
    with Path(destination).open("r+b") as output:
        os.fsync(output.fileno())


def initialize(config, source=None):
    config.check_mount()
    private_directory(config.data_dir)
    with database_instance_lock(config.database):
        if config.database.exists() or config.data_id_file.exists():
            raise RuntimeError("Initialization refuses to overwrite an existing database or data identity")
        candidate = config.data_dir / (".initialize-" + uuid.uuid4().hex + ".sqlite3")
        if source:
            snapshot(Path(source), candidate)
            with readonly(candidate) as database:
                tables = {row[0] for row in database.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if not REQUIRED_TABLES - {"deployment_meta"} <= tables or "deployment_meta" in tables:
                    raise RuntimeError("Import requires a complete local service database; use restore for production backups")
        else:
            store = Store(candidate, synchronous="FULL")
            store.close()
        data_id = uuid.uuid4().hex
        database = sqlite3.connect(candidate)
        try:
            database.execute("PRAGMA synchronous=FULL")
            database.execute("PRAGMA journal_mode=DELETE")
            database.execute("CREATE TABLE deployment_meta(name TEXT PRIMARY KEY,value TEXT NOT NULL)")
            database.executemany("INSERT INTO deployment_meta VALUES(?,?)", [
                ("schema_version", str(SCHEMA_VERSION)), ("data_id", data_id)])
            database.commit()
        finally:
            database.close()
        inspect_database(candidate, data_id, full=True)
        private_directory(config.data_id_file.parent)
        os.replace(candidate, config.database)
        atomic_bytes(config.data_id_file, (data_id + "\n").encode("ascii"))
        return inspect_database(config.database, data_id, full=True)


def restic_environment(config):
    repository = config.restic_repository_file.read_text(encoding="utf-8").strip()
    if not repository or "UNCONFIGURED" in repository or "REPLACE_ME" in repository:
        raise RuntimeError("Configure an encrypted backup repository first")
    if not config.allow_local_repository and not repository.startswith(("s3:https://", "sftp:", "rest:https://")):
        raise RuntimeError("Production backup requires an independent HTTPS/SFTP repository")
    if not config.restic_password_file.is_file() or config.restic_password_file.stat().st_size < 20:
        raise RuntimeError("A private Restic password file of at least 20 bytes is required")
    if os.name != "nt":
        for path in (config.restic_repository_file, config.restic_password_file):
            if path.stat().st_mode & 0o007:
                raise RuntimeError("Backup configuration must not be readable by other users")
    env = dict(os.environ)
    for key in ("RESTIC_REPOSITORY", "RESTIC_PASSWORD", "RESTIC_PASSWORD_COMMAND", "RESTIC_REPOSITORY_FILE", "RESTIC_PASSWORD_FILE"):
        env.pop(key, None)
    credentials = {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_DEFAULT_REGION", "AWS_REGION", "RESTIC_REST_USERNAME", "RESTIC_REST_PASSWORD"}
    for key in credentials:
        env.pop(key, None)
    if config.backup_credentials_file is not None:
        if os.name != "nt" and config.backup_credentials_file.stat().st_mode & 0o007:
            raise RuntimeError("Backup credentials must not be readable by other users")
        values = json.loads(config.backup_credentials_file.read_text(encoding="utf-8"))
        if (not isinstance(values, dict) or set(values) - credentials or
                any(not isinstance(value, str) or any(c in value for c in "\r\n\x00") for value in values.values())):
            raise RuntimeError("Invalid backup credential fields")
        env.update(values)
    return env


def restic(config, *arguments, timeout=600, cache=True):
    private_directory(config.backup_dir)
    command = [config.restic_executable, "--repository-file", str(config.restic_repository_file),
               "--password-file", str(config.restic_password_file)]
    command += ["--cache-dir", str(config.backup_dir / "restic-cache")] if cache else ["--no-cache"]
    result = subprocess.run(command + list(arguments), env=restic_environment(config),
                            capture_output=True, timeout=timeout, check=False)
    if result.returncode:
        # Restic stderr can contain backend URLs. Keep credentials out of logs.
        raise ResticFailure(arguments[0], result)
    return result.stdout


def tags(data_id):
    return "kif-mmo,data-id=" + data_id


def remove_staging(path, parent):
    """Only remove our named, immediate staging children, never a computed root."""
    path, parent = Path(path), Path(parent).resolve()
    if path.is_symlink() or path.resolve().parent != parent or not re.fullmatch(r"(?:pending|restore|snapshot)-[a-f0-9]{32}", path.name):
        raise RuntimeError("Refusing unsafe staging cleanup")
    shutil.rmtree(path)


def prune_local(config, data_id):
    previous = sorted(config.backup_dir.glob("snapshot-*"), key=lambda path: path.stat().st_mtime, reverse=True)
    for path in previous[2:]:
        meta = json.loads((path / "manifest.json").read_text(encoding="utf-8"))
        if meta.get("data_id") == data_id:
            remove_staging(path, config.backup_dir)


def backup(config):
    data_id = config.data_id()
    private_directory(config.backup_dir)
    status_path = config.data_dir / "backup-status.json"
    with database_instance_lock(config.data_dir / "maintenance"):
        try:
            inspect_database(config.database, data_id)
            pending = config.backup_dir / ("pending-" + uuid.uuid4().hex)
            private_directory(pending)
            database = pending / "multiplayer.sqlite3"
            snapshot(config.database, database)
            details = inspect_database(database, data_id, full=True)
            release_path = config.release_dir / "release.json"
            release = json.loads(release_path.read_text(encoding="utf-8")) if release_path.is_file() else {"version": "local-validation"}
            manifest = {"format": "kif-mmo-backup-v1", "created_at": datetime.now(timezone.utc).isoformat(),
                        **details, "database_sha256": sha256(database), "release": release}
            atomic_json(pending / "manifest.json", manifest)
            current = config.backup_dir / "current"
            if current.exists():
                if current.is_symlink() or current.resolve().parent != config.backup_dir:
                    raise RuntimeError("Invalid current backup staging directory")
                os.replace(current, config.backup_dir / ("snapshot-" + uuid.uuid4().hex))
            os.replace(pending, current)
            # Keep local disk usage bounded even while the offsite repository
            # is unavailable. Remote success timestamps still never advance.
            prune_local(config, data_id)
            output = restic(config, "backup", str(current), "--host", config.domain,
                            "--tag", "kif-mmo", "--tag", "data-id=" + data_id, "--json")
            summaries = [json.loads(line) for line in output.decode("utf-8").splitlines() if line.strip()]
            receipt = next((item for item in summaries if item.get("message_type") == "summary"), {})
            snapshot_id = receipt.get("snapshot_id", "")
            if not re.fullmatch(r"[a-f0-9]{64}", snapshot_id):
                raise RuntimeError("Encrypted backup did not return a snapshot receipt")
            status = {"ok": True, "last_success": time.time(), "snapshot_id": snapshot_id, "data_id": data_id}
            atomic_json(status_path, status)
            return status
        except Exception:
            last = json.loads(status_path.read_text()) if status_path.is_file() else {}
            atomic_json(status_path, {**last, "ok": False, "last_failure": time.time()})
            raise


def restore(config, snapshot_id):
    if not re.fullmatch(r"[a-f0-9]{64}", snapshot_id):
        raise ValueError("Use a complete, explicit Restic snapshot ID")
    data_id = config.data_id()
    private_directory(config.data_dir)
    private_directory(config.backup_dir)
    with database_instance_lock(config.data_dir / "maintenance"), database_instance_lock(config.database):
        available = json.loads(restic(config, "snapshots", "--json", "--tag", tags(data_id), cache=False))
        selected = next((item for item in available if item["id"] == snapshot_id), None)
        if selected is None:
            raise RuntimeError("Snapshot does not belong to this server data identity")
        paths = selected.get("paths")
        if not isinstance(paths, list) or len(paths) != 1 or not isinstance(paths[0], str):
            raise RuntimeError("Backup must have exactly one source directory")
        source_path = paths[0].replace("\\", "/")
        # Restic stores a Windows D:/... source as /D/... in its tree. Restore
        # only the recorded backup subtree: ancestors such as /D/Users carry
        # protected machine ACLs and have no place inside database staging.
        if re.match(r"^[A-Za-z]:/", source_path):
            source_path = "/" + source_path[0] + source_path[2:]
        if (not source_path.startswith("/") or not source_path.endswith("/current") or
                any(part in (".", "..") for part in source_path.split("/"))):
            raise RuntimeError("Unexpected backup source directory")
        staging = config.backup_dir / ("restore-" + uuid.uuid4().hex)
        private_directory(staging)
        restic(config, "restore", snapshot_id + ":" + source_path, "--target", str(staging), "--verify", cache=False)
        manifests = list(staging.rglob("manifest.json"))
        if len(manifests) != 1:
            raise RuntimeError("Backup must contain exactly one database manifest")
        if manifests[0].is_symlink() or not manifests[0].resolve().is_relative_to(staging.resolve()):
            raise RuntimeError("Invalid backup manifest path")
        manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
        source = manifests[0].parent / "multiplayer.sqlite3"
        if source.is_symlink() or not source.resolve().is_relative_to(staging.resolve()):
            raise RuntimeError("Invalid backup database path")
        if (manifest.get("format") != "kif-mmo-backup-v1" or manifest.get("data_id") != data_id or
                manifest.get("schema_version") != SCHEMA_VERSION or sha256(source) != manifest.get("database_sha256")):
            raise RuntimeError("Backup identity, format or checksum verification failed")
        inspect_database(source, data_id, full=True)
        current_revision = 0
        preserved = None
        if config.database.exists():
            inspect_database(config.database, data_id, full=True)
            preserved = config.backup_dir / ("pre-restore-" + uuid.uuid4().hex)
            private_directory(preserved)
            snapshot(config.database, preserved / "multiplayer.sqlite3")
            atomic_json(preserved / "manifest.json", {"format": "kif-mmo-pre-restore-v1", "data_id": data_id})
            connection = sqlite3.connect(config.database, timeout=10)
            try:
                current_revision = connection.execute("SELECT coalesce(max(revision),0) FROM cloud_saves").fetchone()[0]
                busy, _, _ = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
                if busy:
                    raise RuntimeError("Another database connection is using the restore target")
            finally:
                connection.close()
        for suffix in ("-wal", "-shm"):
            if Path(str(config.database) + suffix).exists():
                raise RuntimeError("Database sidecars are still active; close all database connections before restore")
        candidate = config.data_dir / (".restored-" + uuid.uuid4().hex + ".sqlite3")
        snapshot(source, candidate)
        connection = sqlite3.connect(candidate)
        try:
            connection.execute("PRAGMA synchronous=FULL")
            restored_revision = connection.execute("SELECT coalesce(max(revision),0) FROM cloud_saves").fetchone()[0]
            fence = max(current_revision, restored_revision, int(time.time() * 1000)) + 1
            if fence >= 2 ** 53:
                raise RuntimeError("Cloud revision fence would exceed protocol range")
            # Revoke sessions and fence stale client outboxes. Old pending
            # uploads must not silently overwrite the operator's recovery point.
            connection.execute("DELETE FROM account_sessions")
            connection.execute("DELETE FROM cloud_leases")
            connection.execute("DELETE FROM world_presence")
            for (owner,) in connection.execute("SELECT id FROM identities").fetchall():
                connection.execute("UPDATE identities SET token_hash=? WHERE id=?", (secrets.token_hex(32), owner))
            connection.execute("UPDATE cloud_saves SET revision=?", (fence,))
            connection.execute("INSERT OR REPLACE INTO deployment_meta VALUES('last_restore',?)", (str(time.time()),))
            connection.commit()
        finally:
            connection.close()
        inspect_database(candidate, data_id, full=True)
        os.replace(candidate, config.database)
        # Sync the replaced directory entry too, using the same durable writer.
        atomic_json(config.data_dir / "restore-status.json", {"snapshot_id": snapshot_id, "revision_fence": fence, "restored_at": time.time()})
        remove_staging(staging, config.backup_dir)
        return {"ok": True, "data_id": data_id, "revision_fence": fence,
                "pre_restore_copy": str(preserved) if preserved else None, "requires_login": True}


def run(config, command, snapshot_id=None, source=None):
    if command == "init-db":
        return initialize(config, source)
    if command == "verify":
        return inspect_database(config.database, config.data_id(), full=True)
    if command == "repo-init":
        restic(config, "init")
        return {"ok": True}
    if command == "backup":
        return backup(config)
    if command == "restore":
        return restore(config, snapshot_id)
    if command == "backup-status":
        value = json.loads((config.data_dir / "backup-status.json").read_text())
        if not value.get("ok") or time.time() - value.get("last_success", 0) > 1800:
            raise RuntimeError("Encrypted backup is missing, failed or older than 30 minutes")
        return value
    data_id = config.data_id()
    if command == "snapshots":
        return json.loads(restic(config, "snapshots", "--json", "--host", config.domain, "--tag", tags(data_id)))
    with database_instance_lock(config.data_dir / "maintenance"):
        if command == "retention":
            restic(config, "forget", "--host", config.domain, "--tag", tags(data_id), "--group-by", "host,tags",
                   "--keep-within", "24h", "--keep-daily", "30", "--keep-monthly", "6")
        elif command == "repo-check":
            restic(config, "check", "--read-data")
        elif command == "repo-prune":
            restic(config, "prune")
            restic(config, "check")
        else:
            raise ValueError("Unknown operation")
    return {"ok": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=os.environ.get("KIF_CONFIG", "/etc/kif-mmo/production.json"))
    parser.add_argument("--release-dir", type=Path)
    parser.add_argument("command", choices=("init-db", "verify", "repo-init", "backup", "restore", "snapshots", "retention", "repo-check", "repo-prune", "backup-status"))
    parser.add_argument("--snapshot")
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    try:
        config = Config.load(args.config)
        if args.release_dir:
            if not args.release_dir.is_absolute():
                raise ValueError("Release directory must be absolute")
            config = replace(config, release_dir=args.release_dir.resolve())
        result = run(config, args.command, args.snapshot, args.source)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    except Exception as error:
        # Configuration paths are operational metadata; secrets/backend stderr
        # are intentionally not emitted by the underlying Restic wrapper.
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
