"""Build/run an isolated Android APK with delayed, trusted local HTTPS fixtures.

Only this diagnostic APK trusts the generated fixture CA. Production TLS policy
and the existing game installation are unchanged. No game saves are opened.
"""
import argparse
import hashlib
import json
import os
import re
import ssl
import subprocess
import sys
import threading
import time
import uuid
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server/multiplayer"))
from service import Store, Handler, ExclusiveHTTPServer

APP = "org.kuray.kif.httpsasyncprobe"


class DelayedHandler(Handler):
    def do_GET(self):
        delays = {"/probe/slow": 4, "/probe/timeout": 4, "/probe/parallel": 2}
        if self.path not in delays:
            return super().do_GET()
        time.sleep(delays[self.path])
        body = b'{"ok":true}'
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            pass  # The timeout/cancel cases intentionally close their socket.


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--port", type=int, default=18801)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--run-built", type=Path, help="Reuse this probe's dedicated build/evidence directory")
    args = parser.parse_args()
    adb = [ROOT / "temp/tools/android-sdk/platform-tools/adb.exe", "-s", args.serial]

    def device(*items, check=True):
        result = subprocess.run([str(arg) for arg in adb + list(items)], capture_output=True, timeout=60)
        if check and result.returncode:
            raise RuntimeError((result.stdout + result.stderr).decode(errors="replace")[-1200:])
        return result.stdout.decode("utf-8", errors="replace").strip()

    if args.run_built:
        evidence = args.run_built.resolve()
        evidence.relative_to(ROOT / "temp/multiplayer")
        with zipfile.ZipFile(evidence / "assets/payload.zip") as archive:
            config = json.loads(archive.read("probe-config.json"))
        args.port = int(config["server"].rsplit(":", 1)[1])
        return run_device(evidence, args, device)

    if device("shell", "pidof", "org.kuray.kif:game", check=False):
        raise SystemExit("Save and close the regular game before running this isolated probe")
    run_id = uuid.uuid4().hex[:10]
    evidence = ROOT / "temp/multiplayer" / ("https-async-" + run_id)
    for name in ("assets", "classes", "dex", "res/raw", "res/xml"):
        (evidence / name).mkdir(parents=True, exist_ok=True)
    assets = evidence / "assets"
    # Generate short-lived test keys locally. Private keys stay under ignored temp.
    generator = evidence / "certificates.rb"
    generator.write_text('''require "openssl"
root = ARGV.fetch(0)
%w[trusted untrusted].each_with_index do |name, index|
  key = OpenSSL::PKey::RSA.new(2048)
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2; cert.serial = index + 1
  cert.subject = OpenSSL::X509::Name.parse("/CN=KIF local HTTPS probe")
  cert.issuer = cert.subject; cert.public_key = key.public_key
  cert.not_before = Time.now - 3600; cert.not_after = Time.now + 86400
  factory = OpenSSL::X509::ExtensionFactory.new
  factory.subject_certificate = cert; factory.issuer_certificate = cert
  cert.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
  cert.add_extension(factory.create_extension("keyUsage", "keyCertSign,digitalSignature,keyEncipherment", true))
  cert.add_extension(factory.create_extension("subjectAltName", "IP:10.0.2.2,IP:127.0.0.1,DNS:localhost"))
  cert.sign(key, OpenSSL::Digest.new("SHA256"))
  File.write(File.join(root, name + ".pem"), cert.to_pem)
  File.write(File.join(root, name + "-key.pem"), key.to_pem)
end
''', encoding="utf-8")
    run([ROOT / "temp/tools/ruby-3.2.9/rubyinstaller-3.2.9-1-x64/bin/ruby.exe", "--disable-gems", generator, evidence])
    (evidence / "res/raw/probe_ca.pem").write_bytes((evidence / "trusted.pem").read_bytes())
    (evidence / "res/xml/probe_network.xml").write_text('''<network-security-config>
<base-config cleartextTrafficPermitted="false"><trust-anchors><certificates src="system" /></trust-anchors></base-config>
<domain-config cleartextTrafficPermitted="false"><domain>10.0.2.2</domain><trust-anchors><certificates src="@raw/probe_ca" /></trust-anchors></domain-config>
</network-security-config>''', encoding="utf-8")
    config = {"server": "https://10.0.2.2:" + str(args.port), "untrusted": "https://10.0.2.2:" + str(args.port + 1) + "/v1/health"}
    payload = {"Game.ini": (ROOT / "Game.ini").read_bytes(),
               "kif_android_preload.rb": (ROOT / "android/ruby/kif_android_preload.rb").read_bytes(),
               "probe.rb": (ROOT / "tests/multiplayer/android_https_async_native.rb").read_bytes(),
               "probe-config.json": json.dumps(config).encode()}
    for name in ("001_Client.rb", "015_Transport.rb", "020_AndroidNetwork.rb"):
        payload[name] = (ROOT / "Data/Scripts/054_Multiplayer" / name).read_bytes()
    payload["000_Platform.rb"] = (ROOT / "Data/Scripts/000_Platform.rb").read_bytes()
    files = {name: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()} for name, data in payload.items()}
    with zipfile.ZipFile(assets / "payload.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in payload.items():
            archive.writestr(name, data)
    manifest = {"id": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()[:24], "bytes": sum(len(data) for data in payload.values()), "files": files, "runtimeOnly": True}
    (assets / "payload-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    (assets / "analytics.json").write_text('{"enabled":false}', encoding="utf-8")
    mkxp = {"rgssVersion": 1, "defScreenW": 512, "defScreenH": 384, "fixedFramerate": 40,
            "fixedAspectRatio": True, "fullscreen": True, "pathCache": False,
            "customScript": "probe.rb", "preloadScript": ["kif_android_preload.rb"]}
    (assets / "mkxp-base.json").write_text(json.dumps(mkxp), encoding="utf-8")
    app_manifest = '''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.kuray.kif.httpsasyncprobe" android:versionCode="1" android:versionName="1-test">
<uses-sdk android:minSdkVersion="30" android:targetSdkVersion="35"/><uses-permission android:name="android.permission.INTERNET"/><uses-permission android:name="android.permission.VIBRATE"/>
<application android:label="KIF Async HTTPS Probe" android:theme="@android:style/Theme.Material.NoActionBar" android:debuggable="true" android:allowBackup="false" android:extractNativeLibs="true" android:networkSecurityConfig="@xml/probe_network">
<activity android:name="org.kuray.kif.LauncherActivity" android:exported="true" android:screenOrientation="sensorLandscape"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity>
<activity android:name="org.kuray.kif.GameActivity" android:exported="false" android:process=":game" android:screenOrientation="sensorLandscape" android:configChanges="layoutDirection|locale|orientation|screenSize|keyboard|keyboardHidden|navigation"/>
</application></manifest>'''
    (evidence / "AndroidManifest.xml").write_text(app_manifest, encoding="utf-8")
    jdk = next((ROOT / "temp/tools").glob("jdk-17*"))
    sdk = ROOT / "temp/tools/android-sdk"
    tools = sdk / "build-tools/35.0.0"
    platform = sdk / "platforms/android-35/android.jar"
    generated = ROOT / "temp/android-generated"
    sources = sorted((ROOT / "android/app/src/main/java").rglob("*.java")) + sorted((generated / "java").rglob("*.java"))
    (evidence / "sources.txt").write_text("\n".join('"' + str(path).replace("\\", "/") + '"' for path in sources), encoding="utf-8")
    run([jdk / "bin/javac.exe", "-J-Xms16m", "-J-Xmx128m", "-encoding", "UTF-8", "--release", "8", "-classpath", platform, "-d", evidence / "classes", "@" + str(evidence / "sources.txt")])
    run([jdk / "bin/jar.exe", "cf", evidence / "classes.jar", "-C", evidence / "classes", "."])
    run([jdk / "bin/java.exe", "-Xms16m", "-Xmx256m", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "30", "--lib", platform, "--output", evidence / "dex", evidence / "classes.jar"])
    run([tools / "aapt2.exe", "compile", "--dir", evidence / "res", "-o", evidence / "resources.zip"])
    unsigned = evidence / "unsigned.apk"
    run([tools / "aapt2.exe", "link", "-I", platform, "--manifest", evidence / "AndroidManifest.xml", "-A", assets, "-0", "zip", "-o", unsigned, evidence / "resources.zip"])
    # Reuse the installed, known-working emulator renderer. It contains no user data.
    installed = device("shell", "pm", "path", "org.kuray.kif").splitlines()[0].removeprefix("package:")
    native_path = str(Path(installed).parent).replace("\\", "/") + "/lib/arm64/libmkxp-z.so"
    run([*adb, "pull", native_path, evidence / "libmkxp-z.so"], capture_output=True)
    with zipfile.ZipFile(unsigned, "a", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.write(evidence / "dex/classes.dex", "classes.dex")
        for library in sorted((generated / "jniLibs/arm64-v8a").glob("*.so")):
            source = evidence / "libmkxp-z.so" if library.name == "libmkxp-z.so" else library
            archive.write(source, "lib/arm64-v8a/" + library.name)
    aligned, apk = evidence / "aligned.apk", evidence / "KIF-async-https-probe.apk"
    run([tools / "zipalign.exe", "-f", "-p", "4", unsigned, aligned])
    signer = [jdk / "bin/java.exe", "-Xms16m", "-Xmx128m", "-jar", tools / "lib/apksigner.jar"]
    env = dict(os.environ, KIF_TEST_KEY_PASSWORD="android")
    run(signer + ["sign", "--ks", ROOT / "temp/android-signing/kif-debug.keystore", "--ks-key-alias", "androiddebugkey", "--ks-pass", "env:KIF_TEST_KEY_PASSWORD", "--key-pass", "env:KIF_TEST_KEY_PASSWORD", "--out", apk, aligned], env=env)
    run(signer + ["verify", apk])
    (evidence / "apk-sha256.txt").write_text(hashlib.sha256(apk.read_bytes()).hexdigest(), encoding="ascii")
    run_device(evidence, args, device)


def run_device(evidence, args, device):
    apk = evidence / "KIF-async-https-probe.apk"
    store = Store(evidence / "service.sqlite3")
    servers = []
    try:
        for offset, name in enumerate(("trusted", "untrusted")):
            server = ExclusiveHTTPServer(("127.0.0.1", args.port + offset), DelayedHandler)
            server.store = store
            server.daemon_threads = True
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(evidence / (name + ".pem"), evidence / (name + "-key.pem"))
            server.socket = context.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            servers.append(server)
        device("install", "--no-streaming", "-r", str(apk))
        device("shell", "run-as", APP, "rm", "-f", "files/https-async-result.json")
        device("shell", "am", "start", "-W", "-n", APP + "/org.kuray.kif.LauncherActivity")
        end = time.monotonic() + args.timeout
        report = None
        while time.monotonic() < end:
            raw = device("exec-out", "run-as", APP, "cat", "files/https-async-result.json", check=False)
            if raw.startswith("{"):
                report = json.loads(raw)
                break
            time.sleep(1)
        if report is None:
            raise RuntimeError("Probe timed out; inspect Android logcat and " + str(evidence))
        (evidence / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
        if not report.get("passed"):
            raise RuntimeError("Asynchronous HTTPS device probe failed")
        print("ANDROID_HTTPS_ASYNC_DEVICE_PASS evidence=" + str(evidence), flush=True)
    finally:
        device("shell", "am", "force-stop", APP, check=False)
        for server in servers:
            server.shutdown()
            server.server_close()
        store.close()


if __name__ == "__main__":
    main()
