"""Full Windows Game.exe + freshly installed Android APK acceptance on an owned AVD.

Only a diagnostic entry script is temporarily substituted, then restored. Production
source, maps, save codec, authentication, HTTP and renderer come from the APK.
The fixture routes exist only in this loopback server, never in the deployed service.
"""
import argparse
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
    parser.add_argument("--serial", default="emulator-5556")
    parser.add_argument("--adb", type=Path, help="ADB executable when SDK tools are outside this checkout")
    parser.add_argument("--port", type=int, default=18801)
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    adb = [str(args.adb or ROOT / "temp/tools/android-sdk/platform-tools/adb.exe"), "-s", args.serial]
    app = "org.kuray.kif"
    run_id = uuid.uuid4().hex[:10]
    evidence = ROOT / "temp/multiplayer" / ("mixed-world-" + run_id)
    evidence.mkdir(parents=True)
    markers = {}
    lock = threading.Lock()

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
            if self.path.startswith("/fixture/"):
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4096:
                    self.send_error(400)
                    return
                value = json.loads(self.rfile.read(length))
                with lock:
                    markers[self.path[9:]] = value
                    (evidence / "markers.json").write_text(json.dumps(markers, indent=2), encoding="utf-8")
                raw = b'{"ok":true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            else:
                super().do_POST()

        def log_message(self, *_args):
            pass

    def command(*items, check=True, timeout=30):
        result = subprocess.run(adb + list(items), capture_output=True, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(result.stdout.decode(errors="replace")[:1000] + result.stderr.decode(errors="replace")[:1000])
        return result.stdout.decode("utf-8", errors="replace").strip()

    if args.serial == "emulator-5554" or not command("emu", "avd", "name").startswith("kif_mixed_"):
        raise SystemExit("This harness requires its own kif_mixed_ AVD; existing player environments are excluded")
    content = command("shell", "run-as", app, "cat", "files/active-content")
    if not re.fullmatch(r"[0-9a-f]{24}", content):
        raise SystemExit("Install and extract the complete new APK first")
    build = json.loads((ROOT / "temp/artifacts/KIF-0.20.7-android.9-arm64-emulator-network-test-build-record.json").read_text(encoding="utf-8"))
    package_path = command("shell", "pm", "path", app).removeprefix("package:")
    if not re.fullmatch(r"/data/app/[A-Za-z0-9_./~+=-]+/base\.apk", package_path):
        raise SystemExit("Unexpected installed APK path")
    installed_sha = command("shell", "sha256sum", package_path).split()[0]
    if content != build["payload"] or installed_sha != build["sha256"]:
        raise SystemExit("Installed APK/content do not match the freshly built artifact")
    private = "/data/user/0/" + app + "/files/diagnostics/mixed-" + run_id
    content_path = "/data/user/0/" + app + "/files/content/" + content
    command("shell", "am", "force-stop", app)
    command("shell", "run-as", app, "mkdir", "-p", private, content_path + "/scripts/multiplayer")
    backups = []
    for name in ("android-game-smoke.rb", "mkxp.json"):
        exists = subprocess.run(adb + ["shell", "run-as", app, "test", "-f", content_path + "/" + name], capture_output=True, timeout=20)
        if exists.returncode == 0:
            command("shell", "run-as", app, "cp", content_path + "/" + name, private + "/original-" + name)
            backups.append(name)
    processes = []
    windows_profiles = {}
    store = Store(evidence / "service.sqlite3")
    service = ExclusiveHTTPServer(("127.0.0.1", args.port), FixtureHandler)
    service.store = store
    service.daemon_threads = True
    threading.Thread(target=service.serve_forever, daemon=True).start()

    def push(source, target):
        transfer = "/data/local/tmp/kif-mixed-" + run_id
        command("push", str(source), transfer)
        command("shell", "run-as", app, "cp", transfer, target)

    def start_windows(role, account):
        profile = "mixed-" + role + "-" + run_id
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/multiplayer/prepare-runtime.ps1"),
                                 "-Profile", profile, "-CustomScript", "tests/multiplayer/mixed_world_game.rb"],
                                cwd=ROOT, check=True, capture_output=True, timeout=120)
        stage = Path(result.stdout.decode("utf-8-sig").strip().splitlines()[-1])
        windows_profiles[role] = stage
        config = evidence / (role + ".json")
        config.write_text(json.dumps({"role": role, "username": "mixed_" + run_id + "_" + account}), encoding="utf-8")
        env = dict(os.environ, KIF_MULTIPLAYER_PROFILE=profile, KIF_MULTIPLAYER_SAVE_DIR=str(stage / "saves"),
                   KIF_MULTIPLAYER_SERVER="http://127.0.0.1:" + str(args.port), KIF_MULTIPLAYER_SCENARIO=str(config))
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        process = subprocess.Popen([str(stage / "Game.exe")], cwd=stage, env=env,
                                   stdout=(evidence / (role + ".stdout.log")).open("wb"),
                                   stderr=(evidence / (role + ".stderr.log")).open("wb"), creationflags=subprocess.CREATE_NO_WINDOW,
                                   startupinfo=startup)
        processes.append(process)
        print("Started Windows " + role + " pid=" + str(process.pid), flush=True)
        return process

    def start_android(role, account):
        command("shell", "am", "force-stop", app)
        # A first-boot Pixel Launcher ANR dialog can steal SDL focus in this
        # disposable AVD. Stop that stock home process before opening the game.
        command("shell", "am", "force-stop", "com.google.android.apps.nexuslauncher")
        save_dir = private + "/" + role
        command("shell", "run-as", app, "mkdir", "-p", save_dir)
        config = evidence / (role + ".json")
        config.write_text(json.dumps({"role": role, "username": "mixed_" + run_id + "_" + account}), encoding="utf-8")
        push(config, private + "/scenario.json")
        env = {"KIF_MULTIPLAYER_PROFILE": "mixed-" + role + "-" + run_id,
               "KIF_MULTIPLAYER_SAVE_DIR": save_dir, "KIF_MULTIPLAYER_SERVER": "http://10.0.2.2:" + str(args.port),
               "KIF_MULTIPLAYER_SCENARIO": private + "/scenario.json"}
        wrapper = evidence / "android-entry.rb"
        wrapper.write_text("\n".join("ENV[" + json.dumps(k) + "] = " + json.dumps(v) for k, v in env.items()) +
                           '\nload "kif_android_preload.rb" # customScript bypasses normal engine preloads\n'
                           'load "scripts/multiplayer/mixed_world_game.rb"\n', encoding="utf-8")
        push(wrapper, content_path + "/android-game-smoke.rb")
        command("shell", "am", "start", "-W", "-n", app + "/.LauncherActivity", "--ez", "gameSmoke", "true")
        print("Started Android " + role, flush=True)

    def collect_android(role):
        names = ["feature-smoke.log", "runtime.log", "world-map.png", "world-chat.png"]
        if role.startswith("restore"):
            names.append(role + ".png")
        for name in names:
            raw = subprocess.run(adb + ["exec-out", "run-as", app, "cat", private + "/" + role + "/" + name], capture_output=True, timeout=20)
            valid = raw.stdout.startswith(b"\x89PNG\r\n\x1a\n") if name.endswith(".png") else not raw.stdout.startswith(b"cat:")
            if raw.returncode == 0 and raw.stdout and valid:
                (evidence / ("android-" + role + "-" + name)).write_bytes(raw.stdout)

    def wait_phase(roles):
        end = time.monotonic() + args.timeout
        next_android_check = 0
        while time.monotonic() < end:
            with lock:
                if all(role + "-pass" in markers for role in roles):
                    return
            for process in processes:
                if process.poll() not in (None, 0):
                    raise RuntimeError("Windows diagnostic failed; inspect profile feature-smoke.log")
            if time.monotonic() >= next_android_check:
                next_android_check = time.monotonic() + 10
                for role in roles:
                    if role in ("guest", "restore-windows"):
                        log = command("exec-out", "run-as", app, "cat", private + "/" + role + "/feature-smoke.log", check=False)
                        if "MIXED_GAME_FAIL" in log:
                            raise RuntimeError(log[log.index("MIXED_GAME_FAIL"):][-3500:])
            time.sleep(1)
        raise RuntimeError("Mixed game timeout for " + ",".join(roles))

    try:
        for name, source in {"test-bootstrap.rb": ROOT / "scripts/multiplayer/test-bootstrap.rb",
                             "runtime-preload.rb": ROOT / "scripts/multiplayer/runtime-preload.rb",
                             "mixed_world_game.rb": ROOT / "tests/multiplayer/mixed_world_game.rb"}.items():
            push(source, content_path + "/scripts/multiplayer/" + name)
        start_android("guest", "guest")
        start_windows("host", "host")
        wait_phase(["host", "guest"])
        collect_android("guest")
        start_android("restore-windows", "host")
        wait_phase(["restore-windows"])
        collect_android("restore-windows")
        start_windows("restore-roundtrip", "host")
        wait_phase(["restore-roundtrip"])
        start_windows("restore-android", "guest")
        wait_phase(["restore-android"])
        if markers["host-render"]["map_key"] != markers["guest-render"]["map_key"]:
            raise RuntimeError("Cross-platform native map fingerprints differ")
        import sqlite3
        with sqlite3.connect(evidence / "service.sqlite3") as database:
            saves = [dict(zip(("owner", "slot", "revision", "document_bytes"), row)) for row in
                     database.execute("SELECT owner,slot,revision,length(document) FROM cloud_saves ORDER BY owner,slot")]
        result = {"passed": True, "content": content, "apk_sha256": installed_sha,
                  "markers": markers, "remote_saves": saves,
                  "scenario": "Windows and Android complete game; native map rendering; five fresh processes; cloud roundtrip"}
        (evidence / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        print("MIXED_GAME_PASS evidence=" + str(evidence), flush=True)
    finally:
        collect_android("guest")
        collect_android("restore-windows")
        (evidence / "logcat.txt").write_text(command("logcat", "-d", "-t", "1200", check=False), encoding="utf-8")
        command("shell", "am", "force-stop", app, check=False)
        for name in ("android-game-smoke.rb", "mkxp.json"):
            if name in backups:
                command("shell", "run-as", app, "cp", private + "/original-" + name, content_path + "/" + name)
            else:
                command("shell", "run-as", app, "rm", "-f", content_path + "/" + name)
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for role, stage in windows_profiles.items():
            for path in (stage / "saves").glob("*"):
                if path.suffix in (".log", ".png"):
                    (evidence / ("windows-" + role + "-" + path.name)).write_bytes(path.read_bytes())
        service.shutdown()
        service.server_close()
        store.close()
        print("Evidence: " + str(evidence), flush=True)


if __name__ == "__main__":
    main()
