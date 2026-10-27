"""Synchronize compatible official resources; publish only after all checks pass."""
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import argparse
import csv
import gzip
import hashlib
import io
import json
import re
import struct
import time
import urllib.error
import urllib.parse
import urllib.request
import build_manifest as catalog

ROOT = catalog.ROOT
LIMIT = 8 * 1024 * 1024
DEX_LIMIT = 32 * 1024 * 1024
STATE = "Data/upstream-resource-state.json"
CDN = "https://infinitefusion.net/customsprites/"
PIF = "infinitefusion/pif-downloadables"
DEX = "infinitefusion/pokedex-entries"
OUTPUTS = ("Data/sprites/CUSTOM_SPRITES", "Data/sprites/BASE_SPRITES", "Data/sprites/Sprite Credits.csv",
           "Data/pokedex/dex.json", "Data/pokedex/dex.json.gz", "Data/offline-resources.json", STATE)


def download(url, limit, probe=False):
    """Range also works on the official CDN, where HEAD is not supported."""
    headers = {"User-Agent": "Mozilla/5.0 InfiniteFusionHD-resource-sync"}
    if url.startswith(CDN):
        headers["Range"] = "bytes=0-%d" % (23 if probe else limit - 1)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
                body = response.read((24 if probe else limit) + 1)
                if len(body) > (24 if probe else limit):
                    raise ValueError("Resource exceeds limit: " + url)
                content_range = response.headers.get("Content-Range", "")
                if not probe and content_range:
                    match = re.fullmatch(r"bytes 0-(\d+)/(\d+)", content_range)
                    if not match or int(match[1]) + 1 != len(body) or int(match[2]) != len(body):
                        raise ValueError("Incomplete range response: " + url)
                return body, response.headers.get("ETag", "")
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def index_names(raw, base, maximum):
    names = set()
    for line in raw.decode("utf-8-sig").splitlines():
        name = line.strip()
        pattern = r"([1-9]\d*)([a-z]{0,3})\.png" if base else r"([1-9]\d*)\.([1-9]\d*)([a-z]{0,3})\.png"
        match = re.fullmatch(pattern, name)
        if match and int(match[1]) <= maximum and (base or int(match[2]) <= maximum):
            names.add(name)
    if not names:
        raise ValueError("Upstream sprite index contains no supported entries")
    return names


def valid_dex(row, maximum=None):
    if not isinstance(row, dict) or not all(isinstance(k, str) for k in row):
        return False
    match = re.fullmatch(r"([1-9]\d*)(?:\.([1-9]\d*))?([a-z]{0,3})\.png", str(row.get("sprite", "")))
    author = row.get("author")
    if maximum is None:
        return isinstance(row.get("sprite"), str) and row["sprite"].endswith(".png") and isinstance(row.get("entry"), str) and not isinstance(author, bool) and isinstance(author, (str, int))
    return bool(match and int(match[1]) <= maximum and (not match[2] or int(match[2]) <= maximum) and
                isinstance(row.get("entry"), str) and not isinstance(author, bool) and isinstance(author, (str, int)))


def merge_dex(existing, incoming, maximum):
    if not isinstance(existing, list) or len(existing) > 100000 or not all(valid_dex(row) for row in existing):
        raise ValueError("Invalid local dex; refusing to discard local entries")
    if not isinstance(incoming, list) or len(incoming) > 150000:
        raise ValueError("Invalid upstream dex")
    compatible = [row for row in incoming if valid_dex(row, maximum)]
    if not compatible:
        raise ValueError("Upstream dex contains no compatible entries")
    result = list(existing)
    known = {json.dumps(row, sort_keys=True, ensure_ascii=False) for row in existing}
    for row in compatible:
        key = json.dumps(row, sort_keys=True, ensure_ascii=False)
        if key not in known:
            known.add(key)
            result.append(row)
    if len(result) > 100000 or len(json_bytes(result)) > DEX_LIMIT:
        raise ValueError("Merged dex exceeds client capacity")
    return result


def merge_credits(existing, incoming):
    def rows(raw):
        result = []
        for row in csv.reader(io.StringIO(raw.decode("utf-8-sig"))):
            if row and re.fullmatch(r"[0-9]+(?:[._][0-9]+)*[a-z]*(?:\.png)?", row[0]) and len(row) >= 2 and row[1].strip():
                result.append(row)
        if not result:
            raise ValueError("Invalid sprite credits CSV")
        return result
    upstream = rows(incoming)
    published = {row[0] for row in upstream}
    combined = upstream + [row for row in rows(existing) if row[0] not in published]
    stream = io.StringIO()
    csv.writer(stream, lineterminator="\n").writerows(combined)
    return stream.getvalue().encode()


def image_entry(request, previous, state, fetch=download):
    path, url, custom = request
    try:
        header, etag = fetch(url, LIMIT, True)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None, "" # The official index can precede a sheet's publication.
        raise
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError("Invalid sheet PNG: " + path)
    width, height = struct.unpack(">II", header[16:24])
    if width != (1920 if custom else 960) or height < 96 or height % 96 or width * height * 4 > 24 * 1024 * 1024:
        raise ValueError("Incompatible sheet dimensions: " + path)
    old = previous.get(path)
    if etag and old and old["url"] == url and state.get(path) == etag:
        return old, etag
    body, actual_etag = fetch(url, LIMIT)
    if actual_etag and etag and actual_etag != etag:
        raise ValueError("Sheet changed during synchronization: " + path)
    if body[:24] != header:
        raise ValueError("Sheet header changed during synchronization: " + path)
    row = {"path": path, "url": url, "size": len(body), "sha256": hashlib.sha256(body).hexdigest(), "kind": "image"}
    if old == row:
        row = old
    return row, actual_etag or etag


def prepare(fetch=download, api=catalog.api, workers=8):
    settings = (ROOT / "Data/Scripts/001_Settings.rb").read_text(encoding="utf-8")
    maximum = int(re.search(r"NB_POKEMON\s*=\s*(\d+)", settings)[1])
    previous = json.loads((ROOT / "Data/offline-resources.json").read_text(encoding="utf-8"))
    previous_rows = {row["path"]: row for row in previous["files"]}
    state_path = ROOT / STATE
    state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.is_file() else {}
    pif_commit = api("commits/master", PIF)["sha"]
    dex_commit = api("commits/main", DEX)["sha"]
    if not all(re.fullmatch(r"[0-9a-f]{40}", sha) for sha in (pif_commit, dex_commit)):
        raise ValueError("Invalid upstream commit ID")
    outputs, indexes = {}, {}
    for name, base in (("CUSTOM_SPRITES", False), ("BASE_SPRITES", True)):
        target = "Data/sprites/" + name
        raw, _ = fetch("https://raw.githubusercontent.com/" + PIF + "/" + pif_commit + "/" + name, LIMIT)
        indexes[base] = index_names(raw, base, maximum)
        local = index_names((ROOT / target).read_bytes(), base, maximum)
        outputs[target] = ("\n".join(sorted(local | indexes[base])) + "\n").encode()
    raw, _ = fetch("https://raw.githubusercontent.com/" + DEX + "/" + dex_commit + "/dex.json", DEX_LIMIT)
    existing = json.loads((ROOT / "Data/pokedex/dex.json").read_text(encoding="utf-8"))
    combined = merge_dex(existing, json.loads(raw), maximum)
    outputs["Data/pokedex/dex.json"] = json_bytes(combined)
    outputs["Data/pokedex/dex.json.gz"] = gzip.compress(outputs["Data/pokedex/dex.json"], mtime=0)
    raw, _ = fetch(CDN + "Sprite_Credits.csv", LIMIT)
    outputs["Data/sprites/Sprite Credits.csv"] = merge_credits((ROOT / "Data/sprites/Sprite Credits.csv").read_bytes(), raw)
    requests = []
    for name in indexes[True]:
        head = re.match(r"\d+", name)[0]
        requests.append(("Graphics/CustomBattlers/spritesheets/spritesheets_base/" + head + ".png",
                         CDN + "spritesheets/spritesheets_base/" + head + ".png", False))
    custom = set()
    for name in indexes[False]:
        head, _, alt = re.fullmatch(r"(\d+)\.(\d+)([a-z]*)\.png", name).groups()
        custom.add((head, alt))
    for head, alt in custom:
        tail = head + "/" + head + alt + ".png"
        requests.append(("Graphics/CustomBattlers/spritesheets/spritesheets_custom/" + tail,
                         CDN + "spritesheets/spritesheets_custom/" + tail, True))
    requests = sorted(set(requests))
    github = catalog.build(previous=previous, data_overrides=outputs)
    rows = {row["path"]: row for row in github["files"] if row["kind"] == "image"}
    image_state, missing = {}, []
    pool = ThreadPoolExecutor(max_workers=workers)
    pending = [pool.submit(image_entry, request, previous_rows, state.get("images", {}), fetch) for request in requests]
    try:
        for count, future in enumerate(as_completed(pending), 1):
            row, etag = future.result()
            if row is not None:
                rows[row["path"]] = row
                image_state[row["path"]] = etag
            if count % 100 == 0:
                print("Checked official sheets: %d/%d" % (count, len(requests)), flush=True)
    finally:
        pool.shutdown(wait=True, cancel_futures=True)
    missing = sorted(request[0] for request in requests if request[0] not in image_state)
    for path, body in outputs.items():
        if path != "Data/pokedex/dex.json" and len(body) > LIMIT:
            raise ValueError("Resource exceeds download capacity: " + path)
    manifest = catalog.seal(github["upstream_commit"], list(rows.values()) + catalog.bundled_data(outputs))
    if manifest["revision"] == previous["revision"]:
        manifest["upstream_commit"] = previous["upstream_commit"]
    outputs["Data/offline-resources.json"] = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
    outputs[STATE] = json_bytes({"images": dict(sorted(image_state.items())), "pending_sheets": missing})
    summary = {"dex_entries": len(combined), "verified_sheets": len(image_state), "pending_sheets": len(missing), "revision": manifest["revision"]}
    if missing:
        print("Sheets awaiting upstream publication: %d; retaining available verified snapshots" % len(missing), flush=True)
    return outputs, summary


def apply(outputs):
    if set(outputs) != set(OUTPUTS):
        raise ValueError("Unexpected sync output paths")
    changed = []
    for name, body in outputs.items():
        target = ROOT / name
        if target.is_file() and target.read_bytes() == body:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        pending = target.with_name(target.name + ".sync-pending")
        pending.write_bytes(body)
        pending.replace(target)
        changed.append(name)
    return changed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=int, default=8, choices=range(1, 17))
    args = parser.parse_args()
    outputs, summary = prepare(workers=args.workers)
    summary["changed"] = apply(outputs)
    print(json.dumps(summary, ensure_ascii=False), flush=True)
