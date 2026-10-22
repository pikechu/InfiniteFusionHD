"""Build an allowlisted, hash-verified offline server release (no player data)."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]


def build(output, wheel_dir):
    service = ROOT / "server/multiplayer"
    modules = ("service.py", "online.py", "backend_v3.py", "production.py", "production_data.py", "production_ops.py", "release_manager.py", "economy.py", "trading.py", "trading_admin.py")
    sources = {"server/multiplayer/" + name: service / name for name in modules}
    sources.update({path.relative_to(ROOT).as_posix(): path for path in service.glob("catalog-*.json")})
    templates = {"production.json", "gunicorn.conf.py", "Caddyfile", "manage.sh", "install-tools.py", "tools.lock.json", "backup-credentials.example.json", "README.md"}
    sources.update({path.relative_to(ROOT).as_posix(): path for path in (service / "deploy").iterdir()
                    if path.is_file() and (path.name in templates or path.name.startswith("kif-mmo-") and path.suffix in (".service", ".timer"))})
    if json.loads((service / "deploy/backup-credentials.example.json").read_text()) != {}:
        raise ValueError("Never bundle real backup credentials")
    sources["server/multiplayer/requirements-production.lock"] = service / "requirements-production.lock"
    for line in sources["server/multiplayer/requirements-production.lock"].read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        match = re.fullmatch(r"([a-z0-9_-]+)==([0-9.]+) --hash=sha256:([a-f0-9]{64})", line)
        if not match:
            raise ValueError("Only exact, hashed production dependencies can be packaged")
        package, version, expected = match.groups()
        candidates = list(wheel_dir.glob(package.replace("-", "_") + "-" + version + "-*.whl"))
        if len(candidates) != 1 or hashlib.sha256(candidates[0].read_bytes()).hexdigest() != expected:
            raise ValueError("Missing or mismatched locked wheel: " + package)
        sources["wheels/" + candidates[0].name] = candidates[0]
    contents = {name: path.read_bytes() for name, path in sorted(sources.items())}
    inventory = {name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)} for name, data in contents.items()}
    fingerprint = hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain", "--"] +
                                        [name for name in sources if name.startswith("server/")], cwd=ROOT).strip())
    version = commit[:12] + "-" + fingerprint[:12]
    release = {"format": "kif-mmo-release-v1", "version": version, "commit": commit,
               "source_worktree_dirty": dirty, "source_state": "content-hashed-working-tree-snapshot",
               "source_sha256": fingerprint, "files": inventory,
               "catalog_compatibility": json.loads(contents["server/multiplayer/catalog-rental-v1.json"])["compatibility"]}
    contents["release.json"] = (json.dumps(release, sort_keys=True, indent=2) + "\n").encode()
    output.mkdir(parents=True, exist_ok=True)
    destination = output / ("kif-mmo-" + version + ".tar.gz")
    with destination.open("wb") as file, gzip.GzipFile(fileobj=file, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for name, data in sorted(contents.items()):
                item = tarfile.TarInfo(name)
                item.size, item.mtime, item.uid, item.gid = len(data), 0, 0, 0
                item.mode = 0o755 if name.endswith(".sh") else 0o644
                archive.addfile(item, io.BytesIO(data))
    with destination.open("rb") as file:
        checksum = hashlib.file_digest(file, "sha256").hexdigest()
    destination.with_name(destination.name + ".sha256").write_text(checksum + "  " + destination.name + "\n", encoding="ascii")
    print(json.dumps({"archive": str(destination), "version": version, "sha256": checksum, "files": len(contents)}))
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "temp/artifacts")
    parser.add_argument("--wheel-dir", type=Path, default=ROOT / "temp/tools/multiplayer-production/wheels")
    arguments = parser.parse_args()
    build(arguments.output, arguments.wheel_dir)
