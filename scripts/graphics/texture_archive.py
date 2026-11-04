"""Create, verify and restore byte-exact, content-deduplicated texture archives."""

import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import time
import zipfile

FORMAT = "infinitefusionhd-texture-archive-v1"


def file_hash(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_name(name):
    if (not isinstance(name, str) or not name or "\\" in name or ":" in name
            or "\0" in name or PurePosixPath(name).is_absolute()
            or any(part in ("", ".", "..") for part in name.split("/"))):
        raise ValueError(f"Unsafe archive path: {name!r}")
    return name


def inventory(source):
    files, directories = {}, []
    for path in sorted(source.rglob("*")):
        info = path.lstat()
        if path.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
            raise ValueError(f"Links/reparse points cannot be archived: {path}")
        name = safe_name(path.relative_to(source).as_posix())
        if stat.S_ISDIR(info.st_mode):
            directories.append(name)
        elif stat.S_ISREG(info.st_mode):
            files[name] = (info.st_size, info.st_mtime_ns)
        else:
            raise ValueError(f"Not a regular file: {path}")
    return files, directories


def create(source, destination, *, source_commit="", workers=8, timeout=1800):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    pending = destination.with_name(destination.name + ".pending")
    if not source.is_dir() or destination.is_relative_to(source):
        raise ValueError("Source must be a directory outside the destination")
    if destination.exists() or pending.exists():
        raise FileExistsError("Preserve existing archives; use a new destination")
    files, directories = inventory(source)
    if not files:
        raise ValueError("Refusing an empty archive")
    deadline = time.monotonic() + timeout

    def read(name):
        if time.monotonic() > deadline:
            raise TimeoutError("Archive creation exceeded its time limit")
        path = source / name
        data = path.read_bytes()
        info = path.stat()
        if (info.st_size, info.st_mtime_ns) != files[name] or len(data) != info.st_size:
            raise ValueError(f"Source changed during archive creation: {name}")
        return data, hashlib.sha256(data).hexdigest()

    destination.parent.mkdir(parents=True, exist_ok=True)
    manifest = {"format": FORMAT, "source_commit": source_commit,
                "source_directory": source.name, "directories": directories, "files": {}}
    canonical, logical_bytes, unique_bytes = set(), 0, 0
    owned_pending = False
    try:
        # Exclusive creation prevents replacing a previous run's partial archive.
        with pending.open("xb") as stream:
            owned_pending = True
            with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive, \
                    ThreadPoolExecutor(max_workers=workers) as pool:
                names = iter(files)
                queue = deque()
                for _ in range(workers * 2):
                    name = next(names, None)
                    if name is not None:
                        queue.append((name, pool.submit(read, name)))
                while queue:
                    name, future = queue.popleft()
                    data, sha = future.result()
                    manifest["files"][name] = {"size": len(data), "sha256": sha}
                    logical_bytes += len(data)
                    if sha not in canonical:
                        archive.writestr("objects/" + sha, data)
                        canonical.add(sha)
                        unique_bytes += len(data)
                    if len(manifest["files"]) % 2000 == 0:
                        print(f"Archived {len(manifest['files'])}/{len(files)} paths", flush=True)
                    name = next(names, None)
                    if name is not None:
                        queue.append((name, pool.submit(read, name)))
                if inventory(source) != (files, directories):
                    raise ValueError("Source inventory changed during archive creation")
                manifest.update(file_count=len(files), object_count=len(canonical),
                                logical_bytes=logical_bytes, unique_bytes=unique_bytes)
                archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=True,
                                                            separators=(",", ":")))
        verify(pending)
        pending.rename(destination)
        return {"archive": str(destination), "sha256": file_hash(destination),
                "archive_bytes": destination.stat().st_size,
                **{key: manifest[key] for key in ("format", "source_commit", "file_count",
                                                  "object_count", "logical_bytes", "unique_bytes")}}
    finally:
        if owned_pending and pending.exists():
            pending.unlink()


def load_manifest(archive):
    manifest = json.loads(archive.read("manifest.json"))
    if manifest.get("format") != FORMAT or not isinstance(manifest.get("files"), dict):
        raise ValueError("Unsupported archive manifest")
    directories = manifest.get("directories")
    if not isinstance(directories, list) or not manifest["files"]:
        raise ValueError("Invalid directory or file inventory")
    paths, objects = {}, {}
    for name in directories + list(manifest["files"]):
        safe_name(name)
        folded = name.casefold()
        if folded in paths:
            raise ValueError(f"Duplicate/case-colliding archive path: {name}")
        paths[folded] = name
    file_names = {name.casefold() for name in manifest["files"]}
    for name in paths.values():
        if any(parent.as_posix().casefold() in file_names for parent in PurePosixPath(name).parents):
            raise ValueError(f"File used as an archive directory: {name}")
    for name, entry in manifest["files"].items():
        if (not isinstance(entry, dict) or type(entry.get("size")) is not int
                or entry["size"] < 0 or not isinstance(entry.get("sha256"), str)
                or not re.fullmatch("[0-9a-f]{64}", entry["sha256"])):
            raise ValueError(f"Invalid file metadata: {name}")
        sha, size = entry["sha256"], entry["size"]
        if sha in objects and objects[sha] != size:
            raise ValueError("Inconsistent object sizes")
        objects[sha] = size
    expected = {"manifest.json"} | {"objects/" + sha for sha in objects}
    names = archive.namelist()
    if len(names) != len(set(names)) or set(names) != expected:
        raise ValueError("Duplicate, missing or unexpected archive members")
    totals = {"file_count": len(manifest["files"]), "object_count": len(objects),
              "logical_bytes": sum(e["size"] for e in manifest["files"].values()),
              "unique_bytes": sum(objects.values())}
    if any(manifest.get(key) != value for key, value in totals.items()):
        raise ValueError("Archive inventory totals do not match")
    return manifest, objects


def verify(path, expected_sha256=None):
    path = Path(path)
    if expected_sha256 is not None and file_hash(path) != expected_sha256:
        raise ValueError("Archive SHA-256 does not match")
    with zipfile.ZipFile(path) as archive:
        manifest, objects = load_manifest(archive)
        for sha, size in objects.items():
            info = archive.getinfo("objects/" + sha)
            if info.file_size != size:
                raise ValueError(f"Object size mismatch: {sha}")
            with archive.open(info) as stream:
                actual = hashlib.file_digest(stream, "sha256").hexdigest()
            if actual != sha:
                raise ValueError(f"Object checksum mismatch: {sha}")
    return manifest


def restore(path, destination, expected_sha256=None):
    # Validate every stored byte before creating the destination; never overwrite.
    manifest = verify(path, expected_sha256)
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    created_files, created_dirs = [], [destination]

    def mkdir(directory):
        if directory == destination or directory.exists():
            return
        mkdir(directory.parent)
        directory.mkdir()
        created_dirs.append(directory)

    try:
        with zipfile.ZipFile(path) as archive:
            for name in manifest["directories"]:
                mkdir(destination / name)
            for name, entry in manifest["files"].items():
                output = destination / name
                mkdir(output.parent)
                with output.open("xb") as stream:
                    created_files.append(output)
                    data = archive.read("objects/" + entry["sha256"])
                    stream.write(data)
                if file_hash(output) != entry["sha256"]:
                    raise ValueError(f"Restored file checksum mismatch: {name}")
        return {"restored_files": len(created_files), "destination": str(destination)}
    except BaseException:
        # Only remove paths created by this invocation, never a pre-existing tree.
        for output in reversed(created_files):
            output.unlink()
        for directory in reversed(created_dirs):
            directory.rmdir()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    build = commands.add_parser("create")
    build.add_argument("source", type=Path)
    build.add_argument("archive", type=Path)
    build.add_argument("--source-commit", default="")
    build.add_argument("--workers", type=int, choices=range(1, 17), default=8)
    build.add_argument("--timeout", type=int, default=1800)
    for action in ("verify", "restore"):
        command = commands.add_parser(action)
        command.add_argument("archive", type=Path)
        command.add_argument("--sha256")
        if action == "restore":
            command.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.action == "create":
        result = create(args.source, args.archive, source_commit=args.source_commit,
                        workers=args.workers, timeout=args.timeout)
    elif args.action == "restore":
        result = restore(args.archive, args.destination, args.sha256)
    else:
        manifest = verify(args.archive, args.sha256)
        result = {"verified_files": manifest["file_count"], "verified_objects": manifest["object_count"]}
    print(json.dumps(result, ensure_ascii=True, indent=2), flush=True)


if __name__ == "__main__":
    main()
