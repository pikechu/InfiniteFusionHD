"""Run map presentation regressions on the dedicated AVD, restoring staged files."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
APP = "org.kuray.kif"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-record", type=Path, default=ROOT / "temp/phone-apk/KIF-0.20.7-android.11-arm64-network-test-build-record.json")
    parser.add_argument("--verify-installed", action="store_true", help="Require the packaged game sources; never stage replacements for them")
    args = parser.parse_args()
    adb = [str(ROOT / "temp/tools/android-sdk/platform-tools/adb.exe"), "-s", "emulator-5560"]

    def command(*args, check=True):
        result = subprocess.run(adb + list(args), capture_output=True, timeout=45)
        if check and result.returncode:
            raise RuntimeError(result.stderr.decode("utf-8", errors="replace") + result.stdout.decode("utf-8", errors="replace"))
        return result

    def shell(*args, check=True):
        return command("shell", shlex.join(args), check=check)

    def read(path):
        return command("exec-out", shlex.join(["run-as", APP, "cat", path])).stdout

    if command("emu", "avd", "name").stdout.decode().splitlines()[0] != "kif_original_20261023":
        raise RuntimeError("Only the dedicated kif_original_20261023 AVD is allowed")
    record = json.loads(args.build_record.read_text())
    payload = record["payload"]
    if len(payload) != 24 or any(char not in "0123456789abcdef" for char in payload):
        raise RuntimeError("Invalid payload ID")
    content = f"/data/user/0/{APP}/files/content/{payload}"
    run_id = uuid.uuid4().hex[:10]
    evidence = ROOT / "temp/map-render-android" / run_id
    evidence.mkdir(parents=True)
    shell("am", "force-stop", APP)
    shell("run-as", APP, "test", "-f", content + "/.complete")
    shell("run-as", APP, "mkdir", "-p", content + "/tests/gameplay", content + "/scripts/multiplayer")
    files = ["Data/Scripts/004_Game classes/008_Game_Event.rb", "Data/Scripts/005_Sprites/003_Sprite_Character.rb", "Data/Scripts/005_Sprites/013_Sprite_Wearable.rb",
             "Data/Scripts/005_Sprites/016_Sprite_Player.rb", "scripts/multiplayer/test-bootstrap.rb",
             "scripts/multiplayer/runtime-preload.rb", "tests/gameplay/map_render_game.rb", "tests/gameplay/local_map_game.rb"]
    originals, hashes = {}, {}
    transfer = "/data/local/tmp/kif-map-render-" + run_id

    def push(source, name):
        command("push", str(source), transfer)
        shell("run-as", APP, "cp", transfer, content + "/" + name)

    def remember(name):
        exists = shell("run-as", APP, "test", "-e", content + "/" + name, check=False)
        if exists.returncode not in (0, 1):
            raise RuntimeError("Cannot inspect backup target: " + name)
        originals[name] = read(content + "/" + name) if exists.returncode == 0 else None

    print("MAP_RENDER_ANDROID_EVIDENCE=" + str(evidence), flush=True)
    try:
        for name in files:
            expected = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            if args.verify_installed and name.startswith("Data/Scripts/"):
                if hashlib.sha256(read(content + "/" + name)).hexdigest() != expected:
                    raise RuntimeError("Installed APK source differs: " + name)
                hashes[name] = expected
                continue
            remember(name)
            push(ROOT / name, name)
            actual = shell("run-as", APP, "sha256sum", content + "/" + name).stdout.decode().split()[0]
            if actual != expected:
                raise RuntimeError("Staged source mismatch: " + name)
            hashes[name] = expected
        remember("android-game-smoke.rb")
        for mode, marker in (("map_render", "MAP_RENDER_PASS"), ("local_map", "LOCAL_MAP_PASS")):
            directory = evidence / mode
            directory.mkdir()
            private = f"/data/user/0/{APP}/files/diagnostics/map-render-{run_id}-{mode}"
            shell("run-as", APP, "mkdir", "-p", private)
            values = {"KIF_SAVE_DIR": private, "KIF_MULTIPLAYER_SAVE_DIR": private,
                      "KIF_MULTIPLAYER_PROFILE": "map-render-" + run_id, "KIF_LOCAL_MAP_ASSERT": "1"}
            wrapper = directory / "entry.rb"
            wrapper.write_text("\n".join("ENV[" + json.dumps(key) + "]=" + json.dumps(value) for key, value in values.items()) +
                               '\nload "kif_android_preload.rb"\nload "tests/gameplay/' + mode + '_game.rb"\n', encoding="utf-8")
            push(wrapper, "android-game-smoke.rb")
            shell("am", "start", "-W", "-n", APP + "/.LauncherActivity", "--ez", "gameSmoke", "true")
            print("RUNNING " + mode, flush=True)
            deadline = time.monotonic() + 240
            while time.monotonic() < deadline:
                exists = shell("run-as", APP, "test", "-f", private + "/feature-smoke.log", check=False)
                if exists.returncode == 0:
                    data = read(private + "/feature-smoke.log")
                    (directory / "feature-smoke.log").write_bytes(data)
                    text = data.decode("utf-8", errors="replace")
                    if "MAP_RENDER_FAIL" in text or "LOCAL_MAP_FAIL" in text:
                        raise RuntimeError(text)
                    if marker in text:
                        break
                time.sleep(2)
            else:
                raise RuntimeError("Timed out waiting for " + mode)
            names = ("map-render-result.json", "roof-occlusion.png", "hat-layering.png", "viridian-render.png") if mode == "map_render" else (
                "local-map-result.json", "walking.png", "motion-42.png", "motion-79.png", "pallet-home.png", "hidden-player.png", "viridian-shop.png")
            for name in names:
                (directory / name).write_bytes(read(private + "/" + name))
            shell("am", "force-stop", APP)
            print("PASS " + mode, flush=True)
        (evidence / "source-hashes.json").write_text(json.dumps(hashes, indent=2), encoding="utf-8")
        (evidence / "build.json").write_text(json.dumps({"apk": record["apk"], "sha256": record["sha256"],
            "payload": payload, "verify_installed": args.verify_installed, "emulator_only": record.get("emulatorOnly", False)}, indent=2), encoding="utf-8")
        print("MAP_RENDER_ANDROID_PASS", flush=True)
    finally:
        shell("am", "force-stop", APP, check=False)
        for index, (name, data) in enumerate(originals.items()):
            if data is None:
                shell("run-as", APP, "rm", "-f", content + "/" + name)
            else:
                backup = evidence / ("restore-" + str(index) + ".rb")
                backup.write_bytes(data)
                push(backup, name)
                if hashlib.sha256(read(content + "/" + name)).digest() != hashlib.sha256(data).digest():
                    raise RuntimeError("Restored source differs: " + name)
        shell("rm", "-f", transfer, check=False)


if __name__ == "__main__":
    main()
