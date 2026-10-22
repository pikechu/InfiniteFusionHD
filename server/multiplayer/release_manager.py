"""Validate/extract offline releases and atomically switch only the code link."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import uuid

from production_data import Config, atomic_bytes

VERSION = re.compile(r"[a-f0-9]{12}-[a-f0-9]{12}")


def validate_inventory(root, metadata):
    if metadata.get("format") != "kif-mmo-release-v1" or not VERSION.fullmatch(metadata.get("version", "")):
        raise RuntimeError("Unsupported release manifest")
    files = metadata.get("files")
    if not isinstance(files, dict) or not 5 <= len(files) <= 256:
        raise RuntimeError("Invalid release inventory")
    fingerprint = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    if fingerprint != metadata.get("source_sha256") or not metadata["version"].endswith(fingerprint[:12]):
        raise RuntimeError("Release fingerprint differs from inventory")
    for name, item in files.items():
        parts = PurePosixPath(name).parts
        if (not parts or PurePosixPath(name).as_posix() != name or any(part in (".", "..") for part in parts) or "\\" in name or name.startswith("/") or
                not (name.startswith("server/multiplayer/") or name.startswith("wheels/"))):
            raise RuntimeError("Unsafe release member")
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or not path.is_file():
            raise RuntimeError("Missing or symlinked release file")
        if path.stat().st_size != item["size"] or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise RuntimeError("Release file hash mismatch: " + name)
    return metadata


def stage(archive_path, releases):
    releases = Path(releases).resolve()
    if releases.name != "releases" or releases.parent == releases:
        raise RuntimeError("Use a dedicated releases directory")
    releases.mkdir(parents=True, exist_ok=True)
    pending = releases / (".partial-" + uuid.uuid4().hex)
    pending.mkdir()
    names, total = set(), 0
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            parts = PurePosixPath(member.name).parts
            total += member.size
            if (not member.isfile() or member.name in names or len(names) >= 257 or total > 32 * 1024 * 1024 or
                    member.size < 0 or member.size > 10 * 1024 * 1024 or not parts or
                    PurePosixPath(member.name).as_posix() != member.name or any(part in (".", "..") for part in parts) or member.name.startswith("/") or "\\" in member.name or
                    not re.fullmatch(r"[A-Za-z0-9_./-]+", member.name)):
                raise RuntimeError("Unsafe or oversized release archive")
            if member.name != "release.json" and not member.name.startswith(("server/multiplayer/", "wheels/")):
                raise RuntimeError("Unexpected release archive path")
            names.add(member.name)
            target = pending / member.name
            if not target.resolve().is_relative_to(pending.resolve()):
                raise RuntimeError("Release path leaves staging directory")
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source:
                data = source.read(member.size + 1)
            if len(data) != member.size:
                raise RuntimeError("Truncated release archive")
            atomic_bytes(target, data)
            target.chmod(0o755 if member.name.endswith(".sh") else 0o644)
    metadata = json.loads((pending / "release.json").read_text(encoding="utf-8"))
    if names != set(metadata["files"]) | {"release.json"}:
        raise RuntimeError("Release inventory does not match archive")
    validate_inventory(pending, metadata)
    final = releases / metadata["version"]
    if final.exists():
        if final.is_symlink():
            raise RuntimeError("Release target is a symlink")
        if json.loads((final / "release.json").read_text()) != metadata:
            raise RuntimeError("Installed release metadata differs")
        validate_inventory(final, metadata)
        if pending.resolve().parent != releases or not re.fullmatch(r"\.partial-[a-f0-9]{32}", pending.name):
            raise RuntimeError("Unsafe partial cleanup target")
        shutil.rmtree(pending)
        return final
    os.replace(pending, final)
    return final


def activate(releases, version):
    releases = Path(releases).resolve()
    if releases.name != "releases" or not VERSION.fullmatch(version):
        raise RuntimeError("Invalid releases root/version")
    target = releases / version
    if target.is_symlink():
        raise RuntimeError("Refusing symlinked release")
    validate_inventory(target, json.loads((target / "release.json").read_text(encoding="utf-8")))
    current = releases.parent / "current"
    if current.exists() and (not current.is_symlink() or current.resolve().parent != releases):
        raise RuntimeError("Current code link is outside the managed releases directory")
    temporary = current.with_name(".current-" + uuid.uuid4().hex)
    os.symlink(target, temporary, target_is_directory=True)
    os.replace(temporary, current)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("stage", "activate", "verify", "render-proxy"))
    parser.add_argument("--releases", type=Path, default=Path("/opt/kif-mmo/releases"))
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--config", type=Path, default=Path("/etc/kif-mmo/production.json"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.action == "stage":
        print(stage(args.archive, args.releases))
    elif args.action == "activate":
        print(activate(args.releases, args.version))
    elif args.action == "verify":
        root = args.releases.resolve() / args.version
        validate_inventory(root, json.loads((root / "release.json").read_text()))
        print("RELEASE_VERIFIED")
    else:
        config = Config.load(args.config)
        template = Path(__file__).parent / "deploy/Caddyfile"
        atomic_bytes(args.output, template.read_bytes().replace(b"if.pikastairs.cc", config.domain.encode("ascii")))


if __name__ == "__main__":
    main()
