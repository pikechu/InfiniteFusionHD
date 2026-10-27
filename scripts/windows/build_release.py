"""Package the committed Windows client without developer files or local saves."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CLIENT_DIRS = ("Audio", "Data", "Fonts", "Graphics", "Mods")
CLIENT_FILES = ("Game.exe", "Game-compatibility.exe", "Game.ini", "mkxp.json",
                "PIF_Credits.txt", "PIF_readme.txt", "README.md", "INSTALL_OR_UPDATE.bat")


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def cache_file(name):
    path = PurePosixPath(name)
    return (path.name.lower() in {"thumbs.db", "desktop.ini", ".ds_store"}
            or path.suffix.lower() in {".log", ".pyc", ".pyo"}
            or "__pycache__" in path.parts)


def build(output, ref):
    commit = git("rev-parse", "--verify", ref + "^{commit}").decode().strip()
    version = git("show", commit + ":Data/VERSION").decode().strip()
    if not version or any(c not in "0123456789.-abcdefghijklmnopqrstuvwxyz" for c in version):
        raise ValueError("Invalid committed game version")
    inventory = git("ls-tree", "--name-only", "-z", commit).decode().split("\0")
    required = list(CLIENT_DIRS + CLIENT_FILES)
    required += sorted(name for name in inventory if name.endswith(".dll"))
    required.append("REQUIRED_BY_INSTALLER_UPDATER")
    if any(name not in inventory for name in required):
        raise ValueError("Committed client inputs are incomplete")
    manifest = json.loads(git("show", commit + ":Data/multiplayer-build.json"))
    prefix = "InfiniteFusionHD-" + version + "-windows/"
    output.mkdir(parents=True, exist_ok=True)
    final = output / ("InfiniteFusionHD-" + version + "-windows-main-" + commit[:8] + ".zip")
    pending = final.with_suffix(".zip.pending")
    if final.exists() or pending.exists():
        raise FileExistsError("Preserve existing artifacts; choose a new output directory")
    files, excluded = {}, []
    process = subprocess.Popen(["git", "-C", str(ROOT), "archive", "--format=tar", commit, "--", *required],
                               stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|") as source, zipfile.ZipFile(
                pending, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for item in source:
                path = PurePosixPath(item.name)
                if path.is_absolute() or ".." in path.parts or "\\" in item.name:
                    raise ValueError("Unsafe client archive path")
                if item.isdir():
                    continue
                if not item.isfile():
                    raise ValueError("Client archive must contain regular files only")
                if cache_file(item.name):
                    excluded.append(item.name)
                    continue
                if (path.suffix.lower() in {".sav", ".bak", ".sqlite", ".sqlite3", ".keystore", ".jks"}
                        or any(p.lower() in {"saves", "onlinesaves", "backups", ".git"} for p in path.parts)):
                    raise ValueError("Save or private data in committed client: " + item.name)
                data = source.extractfile(item).read()
                if item.name.startswith("Data/Scripts/") and path.suffix != ".rb":
                    raise ValueError("Unexpected executable script-loader input")
                entry = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                files[item.name] = entry
                info = zipfile.ZipInfo(prefix + item.name, (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, data)
                if len(files) % 4000 == 0:
                    print("Windows client:", len(files), "files", flush=True)
            if process.wait() != 0:
                raise RuntimeError("Git client export failed")
            for name, expected in manifest["files"].items():
                if files.get(name) != expected:
                    raise ValueError("Committed multiplayer manifest differs from client: " + name)
            analytics = json.loads(git("show", commit + ":Data/analytics.json"))
            if analytics.get("enabled") is not False:
                raise ValueError("Review enabled telemetry before producing a client release")
            record = {"format": "kif-windows-client-v1", "source_commit": commit,
                      "version": version, "data_hash": manifest["data_hash"],
                      "mods_hash": manifest["mods_hash"], "files": files,
                      "excluded_caches": excluded, "native_runtime_rebuilt": False}
            archive.writestr(prefix + "client-build.json", json.dumps(record, indent=2) + "\n")
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            process.wait()
    with zipfile.ZipFile(pending) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError("Windows ZIP integrity check failed: " + bad)
    pending.replace(final)
    with final.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    summary = {key: value for key, value in record.items() if key != "files"}
    summary.update({"archive": final.name, "sha256": digest, "bytes": final.stat().st_size,
                    "file_count": len(files), "zip_integrity_verified": True})
    final.with_suffix(".zip.sha256").write_text(digest + "  " + final.name + "\n", encoding="utf-8")
    final.with_suffix(".json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "temp/artifacts")
    parser.add_argument("--ref", default="HEAD")
    args = parser.parse_args()
    build(args.output.resolve(), args.ref)
