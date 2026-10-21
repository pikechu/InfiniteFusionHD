"""Probe the production adapter in an installed Android mkxp runtime.

Backs up/restores the diagnostic script and config; never opens player saves.
This verifies networking, not a newly packaged APK or mixed-platform gameplay.
"""
import argparse
import json
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server/multiplayer"))
from service import Store, Handler, ExclusiveHTTPServer


class ProbeHandler(Handler):
    def do_GET(self):
        if self.path == "/probe/slow":
            time.sleep(2)
        super().do_GET()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--port", type=int, default=18798)
    parser.add_argument("--timeout", type=int, default=100)
    args = parser.parse_args()
    adb = [str(ROOT / "temp/tools/android-sdk/platform-tools/adb.exe"), "-s", args.serial]
    app = "org.kuray.kif"

    def command(*items, check=True):
        result = subprocess.run(adb + list(items), capture_output=True, timeout=20)
        if check and result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace")[:1000])
        return result.stdout.decode("utf-8", errors="replace").strip()

    if command("shell", "pidof", app + ":game", check=False):
        raise SystemExit("Game process is running; save and close it before this diagnostic")
    content = command("shell", "run-as", app, "cat", "files/active-content")
    if not re.fullmatch(r"[0-9a-f]{24}", content):
        raise SystemExit("No verified installed game content")
    run_id = uuid.uuid4().hex[:10]
    evidence = ROOT / "temp/multiplayer" / ("android-network-" + run_id)
    evidence.mkdir(parents=True)
    private = "/data/user/0/" + app + "/files/diagnostics/online-network"
    content_path = "/data/user/0/" + app + "/files/content/" + content
    backup = private + "/original-" + run_id
    command("shell", "run-as", app, "mkdir", "-p", backup)
    for name in ("android-game-smoke.rb", "mkxp.json"):
        command("shell", "run-as", app, "cp", content_path + "/" + name, backup + "/" + name)
    config = {"server": "http://10.0.2.2:" + str(args.port), "username": "android_" + run_id,
              "untrusted_https": "https://self-signed.badssl.com/"}
    (evidence / "config.json").write_text(json.dumps(config), encoding="utf-8")
    sources = {"000_Platform.rb": ROOT / "Data/Scripts/000_Platform.rb",
               "001_Client.rb": ROOT / "Data/Scripts/054_Multiplayer/001_Client.rb",
               "015_Transport.rb": ROOT / "Data/Scripts/054_Multiplayer/015_Transport.rb",
               "020_AndroidNetwork.rb": ROOT / "Data/Scripts/054_Multiplayer/020_AndroidNetwork.rb",
               "config.json": evidence / "config.json",
               "probe.rb": ROOT / "tests/multiplayer/android_network_native.rb"}
    store = Store(evidence / "service.sqlite3")
    service = ExclusiveHTTPServer(("127.0.0.1", args.port), ProbeHandler)
    service.store = store
    service.daemon_threads = True
    threading.Thread(target=service.serve_forever, daemon=True).start()
    replaced = False
    try:
        for name, source in sources.items():
            transfer = "/data/local/tmp/kif-online-" + run_id + "-" + name
            command("push", str(source), transfer)
            command("shell", "run-as", app, "cp", transfer, private + "/" + name)
        command("shell", "run-as", app, "cp", private + "/probe.rb", content_path + "/android-game-smoke.rb")
        replaced = True
        # Remove only a previous diagnostic result, never saves or profiles.
        command("shell", "run-as", app, "rm", "-f", private + "/result.json")
        command("shell", "am", "start", "-W", "-n", app + "/.LauncherActivity", "--ez", "gameSmoke", "true")
        deadline = time.monotonic() + args.timeout
        result = None
        while time.monotonic() < deadline:
            raw = command("exec-out", "run-as", app, "cat", private + "/result.json", check=False)
            if raw.startswith("{"):
                result = json.loads(raw)
                break
            time.sleep(1)
        if result is None:
            raise RuntimeError("Android network diagnostic timed out; inspect logcat")
        (evidence / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        if not result.get("passed"):
            raise RuntimeError("Android network diagnostic failed")
        print("ANDROID_NETWORK_DEVICE_PASS evidence=" + str(evidence), flush=True)
    finally:
        if replaced:
            command("shell", "am", "force-stop", app, check=False)
        for name in ("android-game-smoke.rb", "mkxp.json"):
            command("shell", "run-as", app, "cp", backup + "/" + name, content_path + "/" + name)
        service.shutdown()
        service.server_close()
        store.close()


if __name__ == "__main__":
    main()
