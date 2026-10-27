"""Pin the offline sprite pack and bundled data. No image downloads are needed.

Run before publishing a game/resource update; commit Data/offline-resources.json
alongside the data files. Runtime clients only fetch this checked manifest.
"""
from pathlib import Path
import argparse
import hashlib
import json
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = "infinitefusion/infinitefusion-e18"
REPOSITORY = "pikechu/InfiniteFusionHD"
DATA = ("Data/sprites/CUSTOM_SPRITES", "Data/sprites/BASE_SPRITES",
        "Data/sprites/Sprite Credits.csv", "Data/pokedex/dex.json",
        "Data/pokedex/all_entries.json", "Data/pokedex/dex_zh.json")


def api(path):
    request = urllib.request.Request("https://api.github.com/repos/" + UPSTREAM + "/" + path,
                                     headers={"User-Agent": "InfiniteFusionHD-resources"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def bundled_data():
    files = []
    for name in DATA:
        path = ROOT / name
        if not path.is_file():
            if name.endswith("dex_zh.json"):
                continue
            raise FileNotFoundError(path)
        # Git/raw URLs and release archives use LF even on a CRLF checkout.
        raw = path.read_bytes().replace(b"\r\n", b"\n")
        if not 0 < len(raw) <= 8 * 1024 * 1024:
            raise ValueError("Data exceeds the mobile download limit: " + name)
        files.append({"path": name, "url": "https://raw.githubusercontent.com/" + REPOSITORY +
                      "/main/" + urllib.parse.quote(name), "size": len(raw),
                      "sha256": hashlib.sha256(raw).hexdigest(), "kind": "data"})
    return files


def seal(commit, files):
    files.sort(key=lambda row: row["path"])
    names = [row["path"].casefold() for row in files]
    if len(names) != len(set(names)):
        raise ValueError("Case-insensitive resource collision")
    revision = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"format": 1, "revision": revision, "upstream_commit": commit, "files": files}


def build(ref="main"):
    commit = api("commits/" + urllib.parse.quote(ref, safe=""))["sha"]
    files = []
    # Include eggs, special forms and substitutes as well as all three sheet types.
    for folder in ("Graphics/Battlers", "Graphics/CustomBattlers/spritesheets"):
        listing = api("contents/" + folder + "?ref=" + commit)
        for child in listing:
            if child["type"] == "dir":
                tree = api("git/trees/" + child["sha"] + "?recursive=1")
                if tree.get("truncated"):
                    raise ValueError("Truncated GitHub tree: " + child["path"])
                rows = [dict(row, path=child["path"] + "/" + row["path"])
                        for row in tree["tree"] if row["type"] == "blob"]
            else:
                rows = [child]
            for row in rows:
                path = row["path"]
                if not path.lower().endswith(".png"):
                    continue
                if not 0 < row["size"] <= 8 * 1024 * 1024:
                    raise ValueError("Asset exceeds the mobile download limit: " + path)
                # The game's existing special sprite directory uses capital S.
                target = path.replace("Graphics/Battlers/special/", "Graphics/Battlers/Special/")
                files.append({"path": target, "url": "https://raw.githubusercontent.com/" + UPSTREAM +
                              "/" + commit + "/" + urllib.parse.quote(path), "size": row["size"],
                              "sha1": row["sha"], "kind": "image"})
    return seal(commit, files + bundled_data())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="main")
    parser.add_argument("--output", type=Path, default=ROOT / "Data/offline-resources.json")
    parser.add_argument("--refresh-data", action="store_true", help="Rehash local data without accessing the network")
    args = parser.parse_args()
    if args.refresh_data:
        previous = json.loads(args.output.read_text(encoding="utf-8"))
        manifest = seal(previous["upstream_commit"], [row for row in previous["files"] if row["kind"] == "image"] + bundled_data())
    else:
        manifest = build(args.ref)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".json.pending")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(args.output)
    print("RESOURCE_MANIFEST_PASS files=%d bytes=%d revision=%s" % (
        len(manifest["files"]), sum(row["size"] for row in manifest["files"]), manifest["revision"]))
