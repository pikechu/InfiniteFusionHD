"""Lossless, deterministic payload v2; all logical paths survive content deduplication."""
import hashlib
import json
import re
import zipfile


def validate_name(name):
    if (not isinstance(name, str) or not name or "\\" in name or ":" in name or "\0" in name
            or name.startswith("/") or any(part in ("", ".", "..") for part in name.split("/"))):
        raise ValueError(f"Unsafe payload path: {name!r}")


def content_identity(files):
    # The content version is independent of ZIP compression or dedup layout. Existing
    # fully installed v1 content can be reused when the logical bytes are unchanged.
    logical = {name: {"size": item["size"], "sha256": item["sha256"]} for name, item in files.items()}
    return hashlib.sha256(json.dumps(logical, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:24]


class PayloadWriter:
    def __init__(self, archive):
        self.archive = archive
        self.files = {}
        self.folded = set()
        self.canonical = {}
        self.total = self.archive_bytes = 0

    def add(self, name, data):
        validate_name(name)
        if name.casefold() in self.folded:
            raise ValueError(f"Duplicate/case-colliding payload path: {name}")
        self.folded.add(name.casefold())
        size, sha = len(data), hashlib.sha256(data).hexdigest()
        expected = {"size": size, "sha256": sha}
        self.files[name] = expected
        self.total += size
        key = size, sha
        if key in self.canonical:
            expected["source"] = self.canonical[key]
            return
        self.canonical[key] = name
        self.archive_bytes += size
        entry = zipfile.ZipInfo(name, date_time=(2026, 10, 16, 0, 0, 0))
        entry.external_attr = 0o100644 << 16
        # Real complete-payload experiments saved 31 MB over storing PNG/audio.
        # Level 9 saved only another 436 KiB, so keep the measured level 6 default.
        self.archive.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)

    def manifest(self, runtime_only):
        return {"id": content_identity(self.files), "bytes": self.total, "files": self.files,
                "runtimeOnly": runtime_only, "archiveFormat": 2,
                "archiveFiles": len(self.canonical), "archiveBytes": self.archive_bytes}


def validate_manifest(manifest):
    version = manifest.get("archiveFormat", 1)
    if type(version) is not int or version not in (1, 2):
        raise ValueError("Unsupported payload archive format")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("Missing payload files")
    folded, total, canonical_bytes = set(), 0, 0
    canonical = {}
    for name, item in files.items():
        validate_name(name)
        if name.casefold() in folded:
            raise ValueError(f"Payload case collision: {name}")
        folded.add(name.casefold())
        if (not isinstance(item, dict) or type(item.get("size")) is not int or item["size"] < 0
                or not isinstance(item.get("sha256"), str) or not re.fullmatch("[a-f0-9]{64}", item["sha256"])):
            raise ValueError(f"Invalid payload metadata: {name}")
        total += item["size"]
        if "source" not in item:
            canonical[name] = item
            canonical_bytes += item["size"]
            continue
        if version != 2:
            raise ValueError("Legacy manifest cannot contain aliases")
        source = item["source"]
        validate_name(source)
        other = files.get(source)
        if (source == name or not isinstance(other, dict) or "source" in other
                or other.get("size") != item["size"] or other.get("sha256") != item["sha256"]):
            raise ValueError(f"Invalid single-hop payload alias: {name}")
    if type(manifest.get("bytes")) is not int or manifest["bytes"] != total:
        raise ValueError("Payload logical byte total mismatch")
    if manifest.get("id") != content_identity(files):
        raise ValueError("Payload content identity mismatch")
    if version == 2 and (manifest.get("archiveFiles") != len(canonical)
                         or manifest.get("archiveBytes") != canonical_bytes):
        raise ValueError("Payload canonical inventory mismatch")
    return canonical


def validate_payload(path, manifest, verify_hashes=False):
    canonical = validate_manifest(manifest)
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        names = [item.filename for item in members]
        if len(names) != len(set(names)) or set(names) != set(canonical):
            raise ValueError("Payload ZIP has duplicate/missing/unlisted canonical members; repackage")
        for item in members:
            expected = canonical[item.filename]
            if item.is_dir() or item.file_size != expected["size"]:
                raise ValueError(f"Payload manifest mismatch: {item.filename}")
            if verify_hashes and hashlib.sha256(archive.read(item)).hexdigest() != expected["sha256"]:
                raise ValueError(f"Payload hash mismatch: {item.filename}")
    return canonical


def read_payload_file(archive, manifest, name):
    expected = manifest["files"][name]
    data = archive.read(expected.get("source", name))
    if len(data) != expected["size"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
        raise ValueError(f"Corrupt staged asset: {name}")
    return data
