"""Deterministic, allowlisted APK game payload; never includes saves, installers or temp."""
from pathlib import Path
import argparse
import hashlib
import json
import zipfile
from concurrent.futures import ThreadPoolExecutor
from collections import deque

ROOT = Path(__file__).resolve().parents[2]
BASE_CONFIG = {
    "rgssVersion": 1, "defScreenW": 512, "defScreenH": 384,
    "fixedFramerate": 40, "fixedAspectRatio": True, "fullscreen": True,
    "pathCache": True, "allowSymlinks": True, "winResizable": False,
    "enableReset": False, "enableSettings": False, "displayFPS": False,
    "printFPS": True, "dataPathOrg": "Kuray", "dataPathApp": "KIFAndroid",
    "preloadScript": ["kif_android_preload.rb"],
    "fontSub": ["Arial>Liberation Sans"],
}

def write_payload(output: Path, runtime_only=False):
    output.mkdir(parents=True, exist_ok=True)
    sources = {}
    for folder in (() if runtime_only else ("Audio", "Data", "Graphics", "Fonts")):
        for file in sorted((ROOT / folder).rglob("*")):
            if not file.is_file() or any(p.startswith(".") for p in file.relative_to(ROOT).parts):
                continue
            name = file.relative_to(ROOT).as_posix()
            if file.suffix.lower() in (".exe", ".dll", ".lnk", ".bat", ".log"):
                continue
            if name.startswith("Data/Scripts/") and file.suffix != ".rb":
                raise ValueError(f"Non-Ruby file in unscreened script loader: {name}")
            if file.suffix.lower() in (".sav", ".bak"):
                raise ValueError(f"Save/backup in payload: {name}")
            sources[name] = file
    sources["Game.ini"] = ROOT / "Game.ini"
    sources["kif_android_preload.rb"] = ROOT / "android/ruby/kif_android_preload.rb"
    sources["android-runtime-smoke.rb"] = ROOT / "android/ruby/android-runtime-smoke.rb"
    if not runtime_only:
        sources["android-game-smoke.rb"] = ROOT / "android/ruby/android-game-smoke.rb"
    duplicates = {}
    for name in sources:
        folded = name.casefold()
        if folded in duplicates:
            raise ValueError(f"Case collision: {name} and {duplicates[folded]}")
        duplicates[folded] = name
    files = {}
    total = 0
    staging = output / "payload.zip.pending"
    ordered = iter(sorted(sources.items()))
    # Bounded parallel read-ahead avoids serial per-file antivirus latency on Windows.
    # ZIP entry order and timestamps remain deterministic; at most 32 files are buffered.
    with ThreadPoolExecutor(max_workers=8) as pool, zipfile.ZipFile(staging, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        pending = deque()
        for _ in range(32):
            item = next(ordered, None)
            if item:
                pending.append((item[0], pool.submit(item[1].read_bytes)))
        index = 0
        while pending:
            name, future = pending.popleft()
            data = future.result()
            files[name] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            total += len(data)
            entry = zipfile.ZipInfo(name, date_time=(2026, 10, 16, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_STORED if Path(name).suffix.lower() in (".ogg", ".mp3", ".png", ".jpg") else zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data)
            if index % 3000 == 0:
                print(f"Payload: {index}/{len(sources)} files, {total // 1048576} MiB", flush=True)
            index += 1
            item = next(ordered, None)
            if item:
                pending.append((item[0], pool.submit(item[1].read_bytes)))
    identity = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:24]
    staging.replace(output / "payload.zip")
    manifest = {"id": identity, "bytes": total, "files": files, "runtimeOnly": runtime_only}
    (output / "payload-manifest.json").write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    config = dict(BASE_CONFIG)
    if runtime_only:
        config["customScript"] = "android-runtime-smoke.rb"
    (output / "mkxp-base.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
    print(f"Payload ready: {len(files)} files, {total} bytes, id={identity}", flush=True)
    return manifest

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "temp/android-build/assets")
    parser.add_argument("--runtime-only", action="store_true")
    args = parser.parse_args()
    write_payload(args.output, args.runtime_only)
