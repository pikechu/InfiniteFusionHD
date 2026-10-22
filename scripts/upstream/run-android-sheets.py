"""Native Android sheet backend diagnostic; backs up/restores the smoke entry.

Requires an installed debuggable KIF Android runtime. Uses no player saves.
--platform-source may point at a newer platform adapter for compatibility QA;
that external dependency is recorded and is never copied into tracked sources.
"""
import argparse
import hashlib
import json
import re
import struct
import subprocess
import time
import uuid
import zlib
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sheet(path, columns, index, rgb):
    width, height = columns * 96, (index // columns + 1) * 96
    blank = b"\0" * (width * 4)
    colored = bytearray(blank)
    start = index % columns * 96 * 4
    colored[start:start + 96 * 4] = bytes((*rgb, 255)) * 96
    rows = []
    for y in range(height):
        row = bytearray(colored) if index // columns * 96 <= y < index // columns * 96 + 96 else blank
        if y == index // columns * 96:
            row[start:start + 4] = b"\0" * 4
        rows.append(b"\0" + row)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--platform-source", type=Path)
    parser.add_argument("--full-game", action="store_true", help="Run the complete native U09 integration suite using this branch's sources")
    args = parser.parse_args()
    adb = [args.adb, "-s", args.serial]
    app = "org.kuray.kif"

    def command(*items, check=True):
        result = subprocess.run(adb + list(items), capture_output=True, timeout=30)
        if check and result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace")[:1000])
        return result.stdout.decode("utf-8", errors="replace").strip()

    if command("shell", "pidof", app + ":game", check=False):
        raise SystemExit("Close the existing game before running this isolated diagnostic")
    content = command("shell", "run-as", app, "cat", "files/active-content")
    if not re.fullmatch(r"[0-9a-f]{24}", content):
        raise SystemExit("No verified installed game content")
    run_id = uuid.uuid4().hex[:10]
    evidence = ROOT / "temp/multiplayer" / ("android-sheets-" + run_id)
    evidence.mkdir(parents=True)
    private = "/data/user/0/" + app + "/files/diagnostics/upstream-sheets"
    content_path = "/data/user/0/" + app + "/files/content/" + content
    backup = private + "/original-" + run_id
    fixture = "Graphics/CustomBattlers/spritesheets/probe-" + run_id
    command("shell", "run-as", app, "mkdir", "-p", backup)
    originals = {}
    for name in ("android-game-smoke.rb", "mkxp.json"):
        originals[name] = command("shell", "run-as", app, "sha256sum", content_path + "/" + name).split()[0]
        command("shell", "run-as", app, "cp", content_path + "/" + name, backup + "/" + name)
    source_root = "temp/upstream-full-" + run_id
    (evidence / "config.json").write_text(json.dumps({"fixture": fixture, "source_root": source_root}), encoding="utf-8")
    (evidence / "custom.txt").write_text("500.501a.png\n", encoding="utf-8")
    (evidence / "base.txt").write_text("500aa.png\n", encoding="utf-8")
    source = (ROOT / "Data/Scripts/049_Compatibility/MarinUtilities.rb").read_text(encoding="utf-8")
    (evidence / "png-writer.rb").write_text(source[source.index("class ByteWriter"):source.index("# Stand-alone methods")], encoding="utf-8")
    platform = args.platform_source or ROOT / "Data/Scripts/000_Platform.rb"
    sources = {"000_Platform.rb": platform, "SpriteAssets.rb": ROOT / "Data/Scripts/052_AddOns/SpriteAssets.rb",
               "SpriteSheets.rb": ROOT / "Data/Scripts/052_AddOns/SpriteSheets.rb", "probe.rb": ROOT / "tests/upstream/android_sheets.rb",
               "config.json": evidence / "config.json", "png-writer.rb": evidence / "png-writer.rb"}
    for name, columns, index, rgb in (("CustomBattlers/spritesheets/spritesheets_custom/500/500a.png", 20, 501, (240, 10, 20)),
                                     ("CustomBattlers/spritesheets/spritesheets_base/500.png", 10, 27, (10, 230, 20)),
                                     ("Battlers/spritesheets_autogen/500.png", 10, 501, (10, 20, 230))):
        path = evidence / name
        sheet(path, columns, index, rgb)
        sources["fixture/" + name] = path
    sources["fixture/custom.txt"], sources["fixture/base.txt"] = evidence / "custom.txt", evidence / "base.txt"
    if args.full_game:
        archive = evidence / "sources.zip"
        patterns = ("Data/Scripts/**/*.rb", "Mods/*.rb", "tests/upstream/*.rb", "tests/multiplayer/trade_game_test.rb", "scripts/multiplayer/test-bootstrap.rb", "scripts/multiplayer/runtime-preload.rb")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
            for pattern in patterns:
                for path in ROOT.glob(pattern):
                    zipped.write(path, path.relative_to(ROOT).as_posix())
        sources["sources.zip"] = archive
        sources["probe.rb"] = ROOT / "tests/upstream/android_full_task.rb"
    dependency = {"platform_source": str(platform), "platform_sha256": hashlib.sha256(platform.read_bytes()).hexdigest(), "serial": args.serial}
    (evidence / "dependency.json").write_text(json.dumps(dependency, indent=2), encoding="utf-8")
    replaced = False
    try:
        for index, (name, source) in enumerate(sources.items()):
            destination = (content_path + "/" + fixture + "/" + name[8:]) if name.startswith("fixture/") else private + "/" + name
            transfer = "/data/local/tmp/kif-sheets-" + run_id + "-" + str(index)
            command("push", str(source), transfer)
            command("shell", "run-as", app, "mkdir", "-p", str(Path(destination).parent).replace("\\", "/"))
            command("shell", "run-as", app, "cp", transfer, destination)
        if args.full_game:
            command("shell", "run-as", app, "mkdir", "-p", content_path + "/" + source_root)
            command("shell", "run-as", app, "unzip", "-q", private + "/sources.zip", "-d", content_path + "/" + source_root)
        command("shell", "run-as", app, "cp", private + "/probe.rb", content_path + "/android-game-smoke.rb")
        replaced = True
        command("shell", "run-as", app, "rm", "-f", private + "/result.json")
        start = time.monotonic()
        command("shell", "am", "start", "-W", "-n", app + "/.LauncherActivity", "--ez", "gameSmoke", "true")
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            raw = command("exec-out", "run-as", app, "cat", private + "/result.json", check=False)
            if raw.startswith("{"):
                result = json.loads(raw)
                result["launcher_to_result_seconds"] = time.monotonic() - start
                (evidence / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
                if args.full_game:
                    for name in ("sheets-storage.png", "sheets-dex.png"):
                        image = subprocess.run(adb + ["exec-out", "run-as", app, "cat", content_path + "/" + source_root + "/saves/" + name], capture_output=True, timeout=30)
                        if image.returncode == 0 and image.stdout.startswith(b"\x89PNG\r\n\x1a\n"):
                            (evidence / name).write_bytes(image.stdout)
                display = dict(result)
                if "native_log" in display:
                    log = display.pop("native_log")
                    display["native_summary"] = [line for line in log.splitlines() if any(marker in line for marker in ("U09_READY", "BENCHMARK", "_TEST_PASS", "U09_PASS", "UPSTREAM_FAIL"))]
                print(json.dumps(display, ensure_ascii=False, indent=2), flush=True)
                if not result.get("passed"):
                    raise RuntimeError("Android sheet diagnostic failed")
                print("ANDROID_SHEETS_PASS evidence=" + str(evidence), flush=True)
                break
            time.sleep(1)
        else:
            raise RuntimeError("Android sheet diagnostic timed out; inspect logcat")
    finally:
        if replaced:
            command("shell", "am", "force-stop", app, check=False)
        for name, digest in originals.items():
            command("shell", "run-as", app, "cp", backup + "/" + name, content_path + "/" + name)
            restored = command("shell", "run-as", app, "sha256sum", content_path + "/" + name).split()[0]
            if restored != digest:
                raise RuntimeError("Diagnostic restore failed for " + name)
        print("ANDROID_ORIGINALS_RESTORED", flush=True)


if __name__ == "__main__":
    main()
