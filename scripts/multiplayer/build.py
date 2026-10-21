"""Build and audit the multiplayer compatibility manifest; no rxdata replacement.

Game.ini's trusted local Scripts.rxdata recursively loads the source tree. This
manifest pins the actual source/data/Mods inputs so stale builds fail closed.
"""
from pathlib import Path
import argparse
import hashlib
import json
import time

ROOT = Path(__file__).resolve().parents[2]


def inputs(root=ROOT):
    scripts = sorted(p for p in (root / "Data/Scripts").rglob("*") if p.is_file())
    # Include all compiled root data except maps/animation-only data and backups.
    data = sorted(p for p in (root / "Data").iterdir() if p.is_file() and
                  p.suffix.lower() in (".dat", ".rxdata") and
                  not p.name.startswith(("Map", "Copy", "Editor", "Tilesets")) and
                  p.name not in ("Animations.rxdata", "PkmnAnimations.rxdata", "PluginScripts.rxdata") and
                  "backup" not in p.name.lower())
    mods = sorted((root / "Mods").glob("*.rb"))
    plugin = root / "Data/PluginScripts.rxdata"
    if plugin.exists():
        mods.append(plugin)
    return scripts + data, mods


def entry(path, root):
    return path.relative_to(root).as_posix(), {
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size}


def group_hash(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def build(root=ROOT):
    core, mods = inputs(root)
    core_files = dict(entry(p, root) for p in core)
    mod_files = dict(entry(p, root) for p in mods)
    return {"version": 1, "protocol": 2, "rules_version": "friendly-singles-v1",
            "source_loader": "Data/Scripts.rxdata -> Data/Scripts (files-first sorted)",
            "data_hash": group_hash(core_files), "mods_hash": group_hash(mod_files),
            "files": dict(sorted({**core_files, **mod_files}.items())),
            "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    build_root = args.root.resolve()
    output = build_root / "Data/multiplayer-build.json"
    manifest = build(build_root)
    if args.check:
        if not output.exists():
            raise SystemExit("Missing manifest: run build.py")
        saved = json.loads(output.read_text(encoding="utf-8"))
        if any(saved.get(key) != manifest[key] for key in ("version", "protocol", "rules_version", "source_loader", "data_hash", "mods_hash", "files")):
            raise SystemExit("STALE MULTIPLAYER BUILD: run build.py after editing scripts/data/Mods")
        print(f"BUILD_CHECK_PASS files={len(manifest['files'])} data={manifest['data_hash']}")
    else:
        temporary = output.with_suffix(".json.pending")
        temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary.replace(output)
        print(f"BUILD_PASS files={len(manifest['files'])} manifest={output}")
