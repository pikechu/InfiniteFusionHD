"""ADB evidence capture and repeatable launch controls. No commands touch Windows player saves."""
from pathlib import Path
import argparse
import datetime
import json
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
APP = "org.kuray.kif"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["capture", "launch", "runtime-smoke", "game-smoke", "network-smoke", "stop", "install"])
    parser.add_argument("--serial")
    parser.add_argument("--apk", type=Path, default=ROOT / "temp/artifacts/KIF-0.20.7-android.7-arm64-test.apk")
    parser.add_argument("--label", default="device")
    args = parser.parse_args()
    adb = [str(ROOT / "temp/tools/android-sdk/platform-tools/adb.exe")]
    if args.serial: adb += ["-s", args.serial]
    def command(*items, binary=False):
        result = subprocess.run(adb + list(items), capture_output=True)
        if result.returncode:
            print(result.stdout.decode("utf-8", errors="replace"), end="")
            print(result.stderr.decode("utf-8", errors="replace"), end="")
            result.check_returncode()
        return result.stdout if binary else result.stdout.decode("utf-8", errors="replace")
    if args.action == "install":
        print(command("install", "--no-incremental", "-r", str(args.apk))); return
    if args.action == "stop":
        print(command("shell", "am", "force-stop", APP)); return
    if args.action != "capture":
        command("shell", "am", "force-stop", APP)
        command("logcat", "-c")
        options = ["shell", "am", "start", "-W", "-n", APP + "/.LauncherActivity"]
        if args.action != "launch":
            option = {"runtime-smoke": "runtimeSmoke", "game-smoke": "gameSmoke", "network-smoke": "networkSmoke"}[args.action]
            options += ["--ez", option, "true"]
        print(command(*options)); return
    folder = ROOT / "temp/evidence" / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + args.label)
    folder.mkdir(parents=True, exist_ok=True)
    properties = {}
    for prop in ["ro.product.model", "ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abilist", "ro.dalvik.vm.native.bridge", "ro.build.fingerprint"]:
        properties[prop] = command("shell", "getprop", prop).strip()
    properties["page_size"] = command("shell", "getconf", "PAGE_SIZE").strip()
    (folder / "device.json").write_text(json.dumps(properties, indent=2), encoding="utf-8")
    (folder / "screen.png").write_bytes(command("exec-out", "screencap", "-p", binary=True))
    for name, items in {
        "logcat.txt": ["logcat", "-d", "-v", "threadtime"],
        "memory.txt": ["shell", "dumpsys", "meminfo", APP + ":game"],
        "activity.txt": ["shell", "dumpsys", "activity", "activities"],
        "saves.txt": ["shell", "run-as", APP, "ls", "-la", "files/saves"],
    }.items():
        try: text = command(*items)
        except subprocess.CalledProcessError as ex: text = ex.stderr.decode("utf-8", errors="replace")
        (folder / name).write_text(text, encoding="utf-8")
    print(folder)

if __name__ == "__main__": main()
