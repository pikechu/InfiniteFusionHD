"""Native shop acceptance: two Windows games or Windows + owned Android AVD.

The fixture funds only freshly registered shop_<run> accounts. Test state and
saves are isolated; no fixture endpoint is installed in the production service.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server/multiplayer"))
from service import Store, Handler, ExclusiveHTTPServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", help="Dedicated shop AVD, omitted for Windows-only")
    parser.add_argument("--port", type=int, default=18837)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--apk-record", type=Path)
    args = parser.parse_args()
    run_id = uuid.uuid4().hex[:10]
    evidence = ROOT / "temp/multiplayer" / ("shop-native-" + run_id)
    evidence.mkdir(parents=True)
    markers, processes, stages = {}, [], {}
    lock = threading.Lock()
    store = Store(evidence / "service.sqlite3", synchronous="FULL")

    class FixtureHandler(Handler):
        def do_GET(self):
            if self.path.startswith("/fixture/"):
                with lock:
                    raw = json.dumps({"ok": True, "value": markers.get(self.path[9:])}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            else:
                super().do_GET()

        def do_POST(self):
            if not self.path.startswith("/fixture/"):
                return super().do_POST()
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096:
                return self.send_error(400)
            value = json.loads(self.rfile.read(length))
            name = self.path[9:]
            if name.startswith("fund-"):
                with store.connect() as db:
                    row = db.execute("SELECT username FROM accounts WHERE owner=?", (value["owner"],)).fetchone()
                if not row or not row[0].startswith("shop_" + run_id):
                    return self.send_error(403)
                for currency in ("RP", "MARKET"):
                    store.shop_admin("native-fixture", "credit", value["owner"] + currency, {"owner": value["owner"], "currency": currency, "amount": 2800 if currency == "RP" else 3000, "reason": "isolated native acceptance"})
                store.shop_admin("native-fixture", "code", value["owner"] + "code", {"code": "SHOP-FIXTURE-" + value["owner"][-16:], "currency": "RP", "amount": 200,
                    "expires": time.time() + 3600, "maximum": 1, "target": value["owner"], "batch": "native"})
            with lock:
                markers[name] = value
                (evidence / "markers.json").write_text(json.dumps(markers, indent=2), encoding="utf-8")
            raw = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *_args):
            pass

    server = ExclusiveHTTPServer(("127.0.0.1", args.port), FixtureHandler)
    server.store, server.daemon_threads = store, True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    adb = [str(ROOT / "temp/tools/android-sdk/platform-tools/adb.exe"), "-s", args.serial] if args.serial else None
    app, content_path, private, backups = "org.kuray.kif", None, None, []
    android_build = None

    def command(*items, check=True, timeout=40):
        result = subprocess.run(adb + list(items), capture_output=True, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(result.stdout.decode(errors="replace")[-1000:] + result.stderr.decode(errors="replace")[-1000:])
        return result.stdout.decode("utf-8", errors="replace").strip()

    def push(source, target):
        transfer = "/data/local/tmp/kif-shop-" + run_id
        command("push", str(source), transfer)
        command("shell", "run-as", app, "cp", transfer, target)

    def start_windows(role, account):
        profile = "shop-" + role + "-" + run_id
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/multiplayer/prepare-runtime.ps1"), "-Profile", profile,
                                 "-CustomScript", "tests/multiplayer/shop_world_game.rb"], cwd=ROOT, check=True, capture_output=True, timeout=120)
        stage = Path(result.stdout.decode("utf-8-sig").strip().splitlines()[-1])
        stages[role] = stage
        config = evidence / (role + ".json")
        config.write_text(json.dumps({"role": role, "username": "shop_" + run_id + "_" + account}), encoding="utf-8")
        env = dict(os.environ, KIF_MULTIPLAYER_PROFILE=profile, KIF_MULTIPLAYER_SAVE_DIR=str(stage / "saves"),
                   KIF_MULTIPLAYER_SERVER="http://127.0.0.1:" + str(args.port), KIF_MULTIPLAYER_SCENARIO=str(config))
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        process = subprocess.Popen([str(stage / "Game.exe")], cwd=stage, env=env, stdout=(evidence / (role + ".stdout.log")).open("wb"),
                                   stderr=(evidence / (role + ".stderr.log")).open("wb"), creationflags=subprocess.CREATE_NO_WINDOW, startupinfo=startup)
        processes.append(process)
        print("Started Windows " + role + " pid=" + str(process.pid), flush=True)

    def start_android(role, account):
        command("shell", "am", "force-stop", app)
        command("shell", "am", "force-stop", "com.google.android.apps.nexuslauncher", check=False)
        save_dir = private + "/" + role
        command("shell", "run-as", app, "mkdir", "-p", save_dir)
        config = evidence / (role + ".json")
        config.write_text(json.dumps({"role": role, "username": "shop_" + run_id + "_" + account}), encoding="utf-8")
        push(config, private + "/scenario.json")
        env = {"KIF_MULTIPLAYER_PROFILE": "shop-" + role + "-" + run_id, "KIF_MULTIPLAYER_SAVE_DIR": save_dir,
               "KIF_MULTIPLAYER_SERVER": "http://10.0.2.2:" + str(args.port), "KIF_MULTIPLAYER_SCENARIO": private + "/scenario.json"}
        wrapper = evidence / "android-entry.rb"
        wrapper.write_text("\n".join("ENV[" + json.dumps(k) + "] = " + json.dumps(v) for k, v in env.items()) +
                           '\nload "kif_android_preload.rb"\nload "scripts/multiplayer/shop_world_game.rb"\n', encoding="utf-8")
        push(wrapper, content_path + "/android-game-smoke.rb")
        command("shell", "am", "start", "-W", "-n", app + "/.LauncherActivity", "--ez", "gameSmoke", "true")
        print("Started Android " + role, flush=True)

    def collect_android(role):
        if not private:
            return
        for name in ("feature-smoke.log", "runtime.log", "shop-catalog.png", "shop-world.png", "shop-card.png", role + ".png"):
            raw = subprocess.run(adb + ["exec-out", "run-as", app, "cat", private + "/" + role + "/" + name], capture_output=True, timeout=20)
            if raw.returncode == 0 and raw.stdout and not raw.stdout.startswith(b"cat:"):
                (evidence / ("android-" + role + "-" + name)).write_bytes(raw.stdout)

    def wait_phase(roles):
        end = time.monotonic() + args.timeout
        while time.monotonic() < end:
            with lock:
                if all(role + "-pass" in markers for role in roles):
                    return
            for role, stage in stages.items():
                log = stage / "saves/feature-smoke.log"
                if log.is_file():
                    text = log.read_text(encoding="utf-8", errors="replace")
                    if "SHOP_GAME_FAIL" in text:
                        raise RuntimeError(text[text.index("SHOP_GAME_FAIL"):][-4000:])
            for process in processes:
                if process.poll() not in (None, 0):
                    raise RuntimeError("Native process exited with " + str(process.returncode))
            if args.serial:
                for role in roles:
                    if role in ("guest", "restore-windows"):
                        text = command("exec-out", "run-as", app, "cat", private + "/" + role + "/feature-smoke.log", check=False)
                        if "SHOP_GAME_FAIL" in text:
                            raise RuntimeError(text[text.index("SHOP_GAME_FAIL"):][-4000:])
            time.sleep(1)
        raise RuntimeError("Timeout: " + ",".join(roles))

    try:
        if args.serial:
            if not command("emu", "avd", "name").startswith("kif_shop_"):
                raise RuntimeError("Use a dedicated kif_shop_ AVD")
            content = command("shell", "run-as", app, "cat", "files/active-content")
            if not re.fullmatch(r"[0-9a-f]{24}", content):
                raise RuntimeError("Extract the complete shop APK before acceptance")
            record_path = args.apk_record or next((ROOT / "temp/artifacts/shop").glob("*-emulator-*-build-record.json"))
            android_build = json.loads(record_path.read_text(encoding="utf-8"))
            package_path = command("shell", "pm", "path", app).removeprefix("package:")
            if not re.fullmatch(r"/data/app/[A-Za-z0-9_./~+=-]+/base\.apk", package_path):
                raise RuntimeError("Unexpected installed APK path")
            installed_sha = command("shell", "sha256sum", package_path).split()[0]
            if content != android_build["payload"] or installed_sha != android_build["sha256"]:
                raise RuntimeError("Installed APK/content differ from the recorded shop build")
            content_path = "/data/user/0/" + app + "/files/content/" + content
            private = "/data/user/0/" + app + "/files/diagnostics/shop-" + run_id
            command("shell", "am", "force-stop", app)
            command("shell", "run-as", app, "mkdir", "-p", private, content_path + "/scripts/multiplayer")
            for name in ("android-game-smoke.rb", "mkxp.json"):
                exists = subprocess.run(adb + ["shell", "run-as", app, "test", "-f", content_path + "/" + name], capture_output=True, timeout=20)
                if exists.returncode == 0:
                    command("shell", "run-as", app, "cp", content_path + "/" + name, private + "/original-" + name)
                    backups.append(name)
            # Record each production file tested on the device, not just version text.
            manifest = json.loads((ROOT / "Data/multiplayer-build.json").read_text(encoding="utf-8"))
            pinned = {name: meta["sha256"] for name, meta in manifest["files"].items() if name.startswith("Data/Scripts/054_Multiplayer/") or name.startswith("Data/shop/") or "/shop" in name}
            if not all(re.fullmatch(r"[A-Za-z0-9_./-]+", name) and ".." not in name for name in pinned):
                raise RuntimeError("Unsafe source inventory")
            output = command("shell", "run-as", app, "sha256sum", *(content_path + "/" + name for name in pinned), timeout=90)
            actual_hashes = {}
            for line in output.splitlines():
                match = re.fullmatch(r"([a-f0-9]{64})\s+(.+)", line.strip())
                if match:
                    actual_hashes[match[2].removeprefix(content_path + "/")] = match[1]
            for name, expected in pinned.items():
                if actual_hashes.get(name) != expected:
                    raise RuntimeError("Android payload differs from current source: " + name)
            (evidence / "android-source-hashes.json").write_text(json.dumps(pinned, indent=2), encoding="utf-8")
            for name, source in {"test-bootstrap.rb": ROOT / "scripts/multiplayer/test-bootstrap.rb", "runtime-preload.rb": ROOT / "scripts/multiplayer/runtime-preload.rb", "shop_world_game.rb": ROOT / "tests/multiplayer/shop_world_game.rb"}.items():
                push(source, content_path + "/scripts/multiplayer/" + name)
            start_android("guest", "guest")
        else:
            start_windows("guest", "guest")
        start_windows("host", "host")
        wait_phase(["host", "guest"])
        if args.serial:
            collect_android("guest")
            start_android("restore-windows", "host")
            wait_phase(["restore-windows"])
            collect_android("restore-windows")
        else:
            start_windows("restore-windows", "host")
            wait_phase(["restore-windows"])
        start_windows("restore-android", "guest")
        wait_phase(["restore-android"])
        for process in processes:
            process.wait(timeout=20)
            if process.returncode:
                raise RuntimeError("Native process did not exit cleanly")
        with store.connect() as db:
            mismatch = db.execute("SELECT w.owner FROM shop_wallets w LEFT JOIN shop_ledger l ON w.owner=l.owner AND w.currency=l.currency GROUP BY w.owner,w.currency HAVING w.balance!=SUM(l.amount)").fetchall()
            if mismatch:
                raise RuntimeError("Economic ledger mismatch")
        result = {"passed": True, "platforms": ["Windows", "Android emulator"] if args.serial else ["Windows", "Windows"], "markers": markers,
                  "scenario": "production purchase, bundle proration, phase two, wardrobe, trial isolation, touch routing, native peer rendering, fresh-device recovery"}
        if android_build:
            result.update(apk_sha256=android_build["sha256"], payload=android_build["payload"], emulator_only=android_build["emulatorOnly"])
        (evidence / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        print("SHOP_NATIVE_PASS evidence=" + str(evidence), flush=True)
    finally:
        if args.serial and private:
            collect_android("guest")
            collect_android("restore-windows")
            command("shell", "am", "force-stop", app, check=False)
            for name in backups:
                command("shell", "run-as", app, "cp", private + "/original-" + name, content_path + "/" + name, check=False)
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for role, stage in stages.items():
            for path in (stage / "saves").glob("*"):
                if path.suffix in (".log", ".png"):
                    (evidence / ("windows-" + role + "-" + path.name)).write_bytes(path.read_bytes())
        server.shutdown()
        server.server_close()
        store.close()
        print("Evidence: " + str(evidence), flush=True)


if __name__ == "__main__":
    main()
