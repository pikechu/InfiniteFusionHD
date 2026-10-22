"""Exercise the production WSGI app behind real, loopback-only Caddy HTTPS.

The Windows host uses a stdlib WSGI test host (not a Gunicorn substitute for
deployment). The proxy, TLS, SQLite and encrypted Restic operations are real.
Neither public DNS nor the public if.pikastairs.cc endpoint is contacted.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from socketserver import ThreadingMixIn
from wsgiref.simple_server import WSGIServer, WSGIRequestHandler, make_server

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server/multiplayer"))
from production import Application
from production_data import Config, atomic_bytes, atomic_json
from production_ops import initialize, backup, restore, run
from service import PROTOCOL, RULES


class QuietHandler(WSGIRequestHandler):
    def log_message(self, *_args):
        pass


class ThreadedHost(ThreadingMixIn, WSGIServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools", type=Path, default=ROOT / "temp/tools/multiplayer-production")
    args = parser.parse_args()
    evidence = ROOT / "temp/multiplayer" / ("production-local-" + uuid.uuid4().hex[:10])
    evidence.mkdir(parents=True)
    caddy = args.tools / ("caddy.exe" if os.name == "nt" else "caddy")
    restic = args.tools / ("restic.exe" if os.name == "nt" else "restic")
    for name, executable in (("caddy", caddy), ("restic", restic)):
        provenance = json.loads((args.tools / (name + "-provenance.json")).read_text())
        if hashlib.sha256(executable.read_bytes()).hexdigest() != provenance["binarySha256"]:
            raise RuntimeError("Local tool hash differs from verified official download")
    values = {"domain": "if.pikastairs.cc", "data_dir": str(evidence / "data"),
              "data_id_file": str(evidence / "expected-data-id"), "backup_dir": str(evidence / "backup-staging"),
              "restic_repository_file": str(evidence / "repository-file"), "restic_password_file": str(evidence / "password-file"),
              "restic_executable": str(restic), "release_dir": str(evidence / "release"),
              "backup_credentials_file": str(evidence / "backup-credentials.json"), "allow_local_repository": True}
    atomic_json(evidence / "production.json", values)
    config = Config.load(evidence / "production.json")
    atomic_bytes(config.restic_repository_file, str(evidence / "encrypted-repository").encode())
    atomic_bytes(config.restic_password_file, uuid.uuid4().hex.encode() + uuid.uuid4().hex.encode())
    atomic_json(config.backup_credentials_file, {})
    initialize(config)
    run(config, "repo-init")
    application = Application(config)
    slot = {"application": application}
    def gateway(environ, start_response):
        if slot["application"] is None:
            start_response("503 Service Unavailable", [("Content-Type", "text/plain"), ("Content-Length", "0")])
            return [b""]
        return slot["application"](environ, start_response)
    server = make_server("127.0.0.1", 0, gateway, server_class=ThreadedHost, handler_class=QuietHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with socket.socket() as available:
        available.bind(("127.0.0.1", 0))
        tls_port = available.getsockname()[1]
    source = (ROOT / "server/multiplayer/deploy/Caddyfile").read_text(encoding="utf-8")
    local = source.replace("admin 127.0.0.1:2020", "admin off\n    auto_https disable_redirects\n    skip_install_trust")
    local = local.replace("if.pikastairs.cc {", "https://localhost:" + str(tls_port) + " {\n    bind 127.0.0.1\n    tls internal")
    local = local.replace("127.0.0.1:8765", "127.0.0.1:" + str(server.server_port))
    proxy_config = evidence / "Caddyfile"
    proxy_config.write_text(local, encoding="utf-8")
    env = dict(os.environ, XDG_DATA_HOME=str(evidence / "caddy-data"), XDG_CONFIG_HOME=str(evidence / "caddy-config"),
               APPDATA=str(evidence / "caddy-appdata"), LOCALAPPDATA=str(evidence / "caddy-local"))
    process = subprocess.Popen([str(caddy), "run", "--config", str(proxy_config), "--adapter", "caddyfile"],
                               env=env, stdin=subprocess.DEVNULL, stdout=(evidence / "caddy.stdout.log").open("wb"),
                               stderr=(evidence / "caddy.stderr.log").open("wb"),
                               creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    checks = []
    def check(value, label):
        if not value:
            raise AssertionError(label)
        checks.append(label)
        print("PASS " + label, flush=True)
    try:
        ca = None
        for _ in range(100):
            candidates = list((evidence / "caddy-data").rglob("root.crt")) if (evidence / "caddy-data").exists() else []
            if candidates:
                ca = candidates[0]
                break
            if process.poll() is not None:
                raise RuntimeError("Local Caddy stopped; inspect its private test log")
            time.sleep(0.1)
        if ca is None:
            raise RuntimeError("Local-only Caddy CA did not initialize")
        context = ssl.create_default_context(cafile=str(ca))
        origin = "https://localhost:" + str(tls_port)
        def request(path, body=None, token=None, expected=200, headers=None, host=None):
            metadata = {"Content-Type": "application/json", **(headers or {})}
            if token:
                metadata["Authorization"] = "Bearer " + token
            raw = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
            message = urllib.request.Request((host or origin) + path, data=raw, headers=metadata)
            try:
                with urllib.request.urlopen(message, context=context, timeout=20) as response:
                    status, result = response.status, response.read()
            except urllib.error.HTTPError as error:
                status, result = error.code, error.read()
            if status != expected:
                raise AssertionError("Unexpected status for " + path + ": " + str(status))
            return json.loads(result) if result else None
        for _ in range(50):
            try:
                request("/v1/health")
                break
            except (urllib.error.URLError, ConnectionError):
                time.sleep(0.1)
        else:
            raise RuntimeError("Local HTTPS proxy did not become ready")
        check(True, "real HTTPS proxy verifies hostname and isolated CA")
        try:
            urllib.request.urlopen(origin + "/v1/health", context=ssl.create_default_context(), timeout=5)
        except urllib.error.URLError:
            check(True, "test CA was not installed into global trust")
        else:
            raise AssertionError("Isolated CA unexpectedly entered global trust")
        request("/v1/health", headers={"X-KIF-Client-IP": "malicious,forged", "X-Forwarded-For": "malicious"})
        check(True, "proxy replaces spoofed client-IP headers")
        request("/v1/health", host="http://127.0.0.1:" + str(server.server_port), expected=400)
        check(True, "backend rejects connections without proxy identity")
        def authenticate(action, name, expected=200):
            return request("/v1/auth/" + action, {"username": name, "password": "LocalProductionFixture9", "protocol": PROTOCOL}, expected=expected)
        clients = [authenticate("register", name, 201) for name in ("windows_fixture", "android_fixture")]
        compatibility = {"protocol": PROTOCOL, "game_version": "fixture", "data_hash": "same-build", "mods_hash": "same-mods", "rules_version": RULES}
        sessions = [uuid.uuid4().hex for _ in clients]
        position = {"map_id": 1, "map_hash": "a" * 64, "width": 20, "height": 20, "x": 4, "y": 4, "direction": 2, "character_id": 0, "moving": False}
        for client, session in zip(clients, sessions):
            request("/v1/cloud/open", {"session_id": session, "compatibility": compatibility}, client["token"])
            request("/v1/world/join", {"session_id": session, "compatibility": compatibility}, client["token"])
            request("/v1/world/sync", {"session_id": session, "seq": 1, "after": 0, "position": position}, client["token"])
        world = request("/v1/world/sync", {"session_id": sessions[0], "seq": 2, "after": 0, "position": position}, clients[0]["token"])["world"]
        check(len(world["players"]) == 1, "authenticated same-map peers through HTTPS")
        for channel in ("map", "world"):
            request("/v1/chat/send", {"session_id": sessions[0], "client_id": uuid.uuid4().hex, "channel": channel, "text": "公网准备验证 " + channel + " 😀"}, clients[0]["token"], expected=201)
        messages = request("/v1/world/sync", {"session_id": sessions[1], "seq": 2, "after": 0, "position": position}, clients[1]["token"])["world"]["messages"]
        check({message["channel"] for message in messages} == {"map", "world"}, "Unicode map and world chat through HTTPS")
        import base64
        payload = "云存档 HTTPS → 备份 → 恢复".encode()
        save = {"format": "kif-save-json-v1", "game_version": "fixture", "payload": base64.b64encode(payload).decode(), "sha256": hashlib.sha256(payload).hexdigest()}
        upload = {"session_id": sessions[0], "slot": "file-a", "revision": 0, "upload_id": uuid.uuid4().hex, "save": save}
        request("/v1/cloud/upload", upload, clients[0]["token"])
        repeated = request("/v1/cloud/upload", upload, clients[0]["token"])
        check(repeated["revision"] == 1, "cloud upload retry commits exactly once")
        # A short local workload checks concurrency and contention; it is not
        # advertised as a public-network player-capacity certification.
        identities = [authenticate("register", "load_" + str(i), 201) for i in range(20)]
        latencies = []
        def poll(client):
            started = time.monotonic()
            request("/v1/identity", token=client["token"])
            return (time.monotonic() - started) * 1000
        with ThreadPoolExecutor(max_workers=4) as pool:
            for _ in range(5):
                latencies.extend(pool.map(poll, identities))
        check(len(latencies) == 100, "20 identities / 100 concurrent HTTPS identity polls")
        receipt = backup(config)
        check(True, "online consistent SQLite snapshot encrypted by real Restic")
        slot["application"] = None
        application.close()
        restored = restore(config, receipt["snapshot_id"])
        application = Application(config)
        slot["application"] = application
        request("/v1/identity", token=clients[0]["token"], expected=401)
        fresh = authenticate("login", "windows_fixture")
        request("/v1/cloud/open", {"session_id": sessions[0], "compatibility": compatibility}, fresh["token"])
        downloaded = request("/v1/cloud/download", {"session_id": sessions[0], "slot": "file-a"}, fresh["token"])
        check(downloaded["save"] == save, "account login and cloud payload survive encrypted restore")
        request("/v1/cloud/upload", {**upload, "revision": 1, "upload_id": uuid.uuid4().hex}, fresh["token"], expected=409)
        check(True, "restore revokes old tokens and fences stale upload outboxes")
        run(config, "repo-check")
        result = {"passed": True, "domain_default": config.domain, "checks": checks,
                  "local_https_only": True, "global_trust_unchanged": True,
                  "wsgi_host": "Windows stdlib test host; Linux Gunicorn/systemd execution remains platform-specific",
                  "identity_poll_samples": len(latencies), "identity_poll_p95_ms": round(sorted(latencies)[94], 2),
                  "identity_poll_max_ms": round(max(latencies), 2), "restore_revision_fence": restored["revision_fence"],
                  "tools": {name: json.loads((args.tools / (name + "-provenance.json")).read_text())["version"] for name in ("caddy", "restic")}}
        atomic_json(evidence / "result.json", result)
        print("PRODUCTION_LOCAL_PASS evidence=" + str(evidence), flush=True)
    finally:
        slot["application"] = None
        server.shutdown()
        server.server_close()
        application.close()
        process.terminate()
        process.wait(timeout=10)


if __name__ == "__main__":
    main()
