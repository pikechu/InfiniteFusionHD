"""Deterministic, allowlisted APK game payload; never includes saves, installers or temp."""
from pathlib import Path
import argparse
import json
import zipfile
import subprocess
from concurrent.futures import ThreadPoolExecutor
from collections import deque
from payload_format import PayloadWriter, validate_payload, read_payload_file

ROOT = Path(__file__).resolve().parents[2]
BASE_CONFIG = {
    "rgssVersion": 1, "defScreenW": 512, "defScreenH": 384,
    "fixedFramerate": 40, "fixedAspectRatio": True, "fullscreen": True,
    # PhysicsFS' cached enumeration does not follow our writable Graphics symlink.
    # Ruby asset helpers resolve Windows case/slashes; direct native reads follow the link.
    "pathCache": False, "allowSymlinks": True, "winResizable": False,
    "enableReset": False, "enableSettings": False, "displayFPS": False,
    "printFPS": True, "dataPathOrg": "Kuray", "dataPathApp": "KIFAndroid",
    "preloadScript": ["kif_android_preload.rb"],
    # KIF's final Bitmap.draw_text wrapper uses text_size.height as its clip.
    # The bundled pixel fonts have smaller nominal than rendered metrics.
    "fontHeightReporting": 1,
    "fontSub": ["Arial>Liberation Sans"],
}

def write_payload(output: Path, runtime_only=False, asset_root=None):
    output.mkdir(parents=True, exist_ok=True)
    asset_root = (asset_root or ROOT).resolve()
    sources = {}
    if not runtime_only:
        # Use Git's tracked inventory, so unrelated untracked features/downloads never
        # enter the payload. A sparse source worktree can reuse an existing asset checkout.
        tracked = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "--", "Audio", "Data", "Graphics", "Fonts"]).decode("utf-8").split("\0")
        for name in filter(None, tracked):
            file = (ROOT if name.startswith("Data/Scripts/") else asset_root) / name
            if any(p.startswith(".") for p in Path(name).parts) or file.suffix.lower() in (".exe", ".dll", ".lnk", ".bat", ".log"):
                continue
            if name.startswith("Data/Scripts/") and file.suffix != ".rb":
                raise ValueError(f"Non-Ruby file in unscreened script loader: {name}")
            if file.suffix.lower() in (".sav", ".bak"):
                raise ValueError(f"Save/backup in payload: {name}")
            if not file.is_file():
                raise ValueError(f"Missing tracked asset: {name}; pass --asset-root for a sparse checkout")
            sources[name] = file
        for file in (ROOT / "Data/Scripts").rglob("*.rb"):
            sources[file.relative_to(ROOT).as_posix()] = file
        for name in ("Data/multiplayer-build.json", "Data/analytics.json"):
            if (ROOT / name).is_file(): sources[name] = ROOT / name
    sources["Game.ini"] = ROOT / "Game.ini"
    sources["kif_android_preload.rb"] = ROOT / "android/ruby/kif_android_preload.rb"
    sources["android-runtime-smoke.rb"] = ROOT / "android/ruby/android-runtime-smoke.rb"
    sources["android-network-smoke.rb"] = ROOT / "android/ruby/android-network-smoke.rb"
    sources["android-font-smoke.rb"] = ROOT / "android/ruby/android-font-smoke.rb"
    if (ROOT / "android/ruby/kif_android_http.rb").is_file():
        sources["kif_android_http.rb"] = ROOT / "android/ruby/kif_android_http.rb"
    if (ROOT / "android/ruby/kif_android_input.rb").is_file():
        sources["kif_android_input.rb"] = ROOT / "android/ruby/kif_android_input.rb"
    if not runtime_only:
        sources["android-game-smoke.rb"] = ROOT / "android/ruby/android-game-smoke.rb"
    duplicates = {}
    for name in sources:
        folded = name.casefold()
        if folded in duplicates:
            raise ValueError(f"Case collision: {name} and {duplicates[folded]}")
        duplicates[folded] = name
    staging = output / "payload.zip.pending"
    ordered = iter(sorted(sources.items()))
    # Bounded parallel read-ahead avoids serial per-file antivirus latency on Windows.
    # ZIP entry order and timestamps remain deterministic; at most 32 files are buffered.
    with ThreadPoolExecutor(max_workers=8) as pool, zipfile.ZipFile(staging, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        writer = PayloadWriter(archive)
        pending = deque()
        for _ in range(32):
            item = next(ordered, None)
            if item:
                pending.append((item[0], pool.submit(item[1].read_bytes)))
        index = 0
        while pending:
            name, future = pending.popleft()
            data = future.result()
            writer.add(name, data)
            if index % 3000 == 0:
                print(f"Payload: {index}/{len(sources)} files, {writer.total // 1048576} MiB", flush=True)
            index += 1
            item = next(ordered, None)
            if item:
                pending.append((item[0], pool.submit(item[1].read_bytes)))
        manifest = writer.manifest(runtime_only)
    validate_payload(staging, manifest)
    staging.replace(output / "payload.zip")
    (output / "payload-manifest.json").write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    config = dict(BASE_CONFIG)
    if runtime_only:
        config["customScript"] = "android-runtime-smoke.rb"
    (output / "mkxp-base.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
    print(f"Payload ready: {len(manifest['files'])} logical files, {manifest['archiveFiles']} archived, {manifest['bytes']} bytes restored, id={manifest['id']}", flush=True)
    return manifest

def refresh_ruby_payload(output: Path):
    """Reuse a verified asset snapshot when only Ruby/config changes, avoiding 23k filesystem reads."""
    original = json.loads((output / "payload-manifest.json").read_text(encoding="utf-8"))
    if original.get("runtimeOnly"):
        return write_payload(output, True)
    tracked = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "--", "Data/Scripts"]).decode("utf-8").split("\0")
    scripts = {name: ROOT / name for name in filter(None, tracked)}
    scripts.update({p.relative_to(ROOT).as_posix(): p for p in (ROOT / "Data/Scripts").rglob("*.rb")})
    for name in ("Data/multiplayer-build.json", "Data/analytics.json"):
        if (ROOT / name).is_file(): scripts[name] = ROOT / name
    for name in ("kif_android_preload.rb", "android-runtime-smoke.rb", "android-game-smoke.rb", "android-network-smoke.rb", "android-font-smoke.rb"):
        scripts[name] = ROOT / "android/ruby" / name
    if (ROOT / "android/ruby/kif_android_http.rb").is_file():
        scripts["kif_android_http.rb"] = ROOT / "android/ruby/kif_android_http.rb"
    if (ROOT / "android/ruby/kif_android_input.rb").is_file():
        scripts["kif_android_input.rb"] = ROOT / "android/ruby/kif_android_input.rb"
    validate_payload(output / "payload.zip", original)
    staging = output / "payload.zip.pending"
    with zipfile.ZipFile(output / "payload.zip") as source, zipfile.ZipFile(staging, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as dest:
        writer = PayloadWriter(dest)
        names = set(original["files"]) | set(scripts)
        for index, name in enumerate(sorted(names)):
            if name.startswith("Data/Scripts/") and name not in scripts:
                continue
            data = scripts[name].read_bytes() if name in scripts else read_payload_file(source, original, name)
            writer.add(name, data)
            if index % 6000 == 0:
                print(f"Refreshing Ruby: {index}/{len(names)}", flush=True)
        manifest = writer.manifest(False)
    validate_payload(staging, manifest)
    staging.replace(output / "payload.zip")
    (output / "payload-manifest.json").write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    (output / "mkxp-base.json").write_text(json.dumps(BASE_CONFIG, indent=2), encoding="utf-8")
    print(f"Ruby/config snapshot refreshed: {len(manifest['files'])} logical / {manifest['archiveFiles']} archived, id={manifest['id']}", flush=True)
    return manifest

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "temp/android-build/assets")
    parser.add_argument("--runtime-only", action="store_true")
    parser.add_argument("--asset-root", type=Path)
    args = parser.parse_args()
    write_payload(args.output, args.runtime_only, args.asset_root)
