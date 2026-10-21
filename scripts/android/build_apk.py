"""Build the standalone test APK with portable SDK tools, without an online Gradle resolution.

Native code is the SHA256-pinned prototype input from prepare-runtime.ps1. This does
not claim that the native source toolchain or gameplay acceptance has passed.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import zipfile
import sys
sys.dont_write_bytecode = True
from package_game import ROOT, write_payload

def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--jdk", type=Path)
    parser.add_argument("--sdk", type=Path, default=ROOT / "temp/tools/android-sdk")
    parser.add_argument("--skip-payload", action="store_true")
    parser.add_argument("--runtime-only", action="store_true", help="Build a clearly labeled runtime probe without the game")
    args = parser.parse_args()
    jdk = args.jdk or next((ROOT / "temp/tools").glob("jdk-17*"), None)
    if jdk is None or not (jdk / "bin/javac.exe").is_file():
        raise SystemExit("Portable JDK17 missing; run bootstrap-tools.ps1 or pass --jdk")
    sdk = args.sdk
    tools = sdk / "build-tools/35.0.0"
    platform = sdk / "platforms/android-35/android.jar"
    generated = ROOT / "temp/android-generated"
    if not (generated / "jniLibs/arm64-v8a/libmkxp-z.so").is_file():
        raise SystemExit("Pinned runtime missing; run scripts/android/prepare-runtime.ps1")
    if not (generated / "jniLibs/arm64-v8a/libkif_android_bridge.so").is_file():
        raise SystemExit("Verified Android HTTPS bridge missing; run scripts/android/build_bridge.ps1")
    bridge_dir = generated / "jniLibs/arm64-v8a"
    record_path = bridge_dir / "kif_android_bridge.provenance.json"
    if not record_path.is_file():
        raise SystemExit("Async HTTPS bridge provenance missing; run scripts/android/build_bridge.ps1")
    bridge_record = json.loads(record_path.read_text(encoding="utf-8-sig"))
    if (bridge_record.get("httpAsync", {}).get("version") != 1 or
        bridge_record.get("sourceSha256") != hashlib.sha256((ROOT / "android/native/kif_android_bridge.c").read_bytes()).hexdigest() or
        bridge_record.get("outputSha256") != hashlib.sha256((bridge_dir / "libkif_android_bridge.so").read_bytes()).hexdigest()):
        raise SystemExit("Async HTTPS bridge is stale; rebuild it before packaging")
    work = ROOT / ("temp/android-smoke-build" if args.runtime_only else "temp/android-build")
    work.mkdir(parents=True, exist_ok=True)
    classes, dex = work / "classes", work / "dex"
    for directory in (classes, dex):
        # Delete only the verified, dedicated build directory.
        if directory.exists():
            assert directory.resolve().parent == work.resolve()
            shutil.rmtree(directory)
        directory.mkdir()
    assets = work / "assets"
    if not args.skip_payload:
        write_payload(assets, args.runtime_only)
    if not all((assets / name).is_file() for name in ("payload.zip", "payload-manifest.json", "mkxp-base.json")):
        raise SystemExit("No staged payload")
    manifest = json.loads((assets / "payload-manifest.json").read_text())
    # Refresh the public collector settings even when reusing a large payload.
    # Never place Matomo reporting/download-server tokens in this client file.
    analytics_path = ROOT / "Data/analytics.json"
    analytics = json.loads(analytics_path.read_text(encoding="utf-8")) if analytics_path.is_file() else {"enabled": False}
    if set(analytics) - {"enabled", "endpoint", "site_id", "app_url", "channel", "heartbeat_seconds", "dimensions"}:
        raise SystemExit("Analytics config contains unsupported fields; never bundle server tokens")
    if manifest.get("runtimeOnly", False):
        analytics["enabled"] = False
    (assets / "analytics.json").write_text(json.dumps(analytics, indent=2), encoding="utf-8")
    # Refuse a mixed payload/manifest pair left by an interrupted packaging pass.
    with zipfile.ZipFile(assets / "payload.zip") as payload:
        members = payload.infolist()
        if len(members) != len(manifest["files"]) or len(set(item.filename for item in members)) != len(members):
            raise SystemExit("Payload ZIP has duplicate/missing members; repackage")
        for item in members:
            expected = manifest["files"].get(item.filename)
            if expected is None or item.file_size != expected["size"]:
                raise SystemExit(f"Payload manifest mismatch: {item.filename}")
        if args.skip_payload:
            print("Verifying staged payload hashes", flush=True)
            for item in members:
                if hashlib.sha256(payload.read(item)).hexdigest() != manifest["files"][item.filename]["sha256"]:
                    raise SystemExit(f"Payload hash mismatch: {item.filename}")
    if not args.runtime_only:
        required = ["Data/Scripts/000_Platform.rb", "Data/multiplayer-build.json"]
        required += ["Data/Scripts/054_Multiplayer/" + name for name in
                     ("001_Client.rb", "015_Transport.rb", "016_CloudCodec.rb", "017_OnlineClient.rb", "018_World.rb", "019_OnlineMode.rb", "020_AndroidNetwork.rb")]
        for name in required:
            item = manifest["files"].get(name)
            source = ROOT / name
            if item is None or not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != item["sha256"]:
                raise SystemExit(f"Android online source missing/stale in payload: {name}; rebuild payload")
    sources = sorted((ROOT / "android/app/src/main/java").rglob("*.java")) + sorted((generated / "java").rglob("*.java"))
    source_list = work / "sources.txt"
    source_list.write_text("\n".join('"' + str(f).replace("\\", "/") + '"' for f in sources), encoding="utf-8")
    print("Compiling Java shell and pinned SDL bootstrap", flush=True)
    run([jdk / "bin/javac.exe", "-J-Duser.language=en", "-encoding", "UTF-8", "--release", "8", "-classpath", platform, "-d", classes, "@" + str(source_list)])
    jar = work / "classes.jar"
    run([jdk / "bin/jar.exe", "cf", jar, "-C", classes, "."])
    run([jdk / "bin/java.exe", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "30", "--lib", platform, "--output", dex, jar])
    unsigned = work / "kif-unsigned.apk"
    run([tools / "aapt2.exe", "link", "-I", platform, "--manifest", ROOT / "android/app/src/main/AndroidManifest.xml", "-A", assets, "-0", "zip", "-o", unsigned])
    with zipfile.ZipFile(unsigned, "a", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as apk:
        apk.write(dex / "classes.dex", "classes.dex")
        for library in sorted((generated / "jniLibs").rglob("*.so")):
            apk.write(library, "lib/" + library.relative_to(generated / "jniLibs").as_posix())
    aligned = work / "kif-aligned.apk"
    run([tools / "zipalign.exe", "-f", "-p", "4", unsigned, aligned])
    keys = ROOT / "temp/android-signing"
    keys.mkdir(exist_ok=True)
    key = keys / "kif-debug.keystore"
    # A standard local development key, never a release key. No private key or password is printed.
    env = dict(os.environ, KIF_TEST_KEY_PASSWORD="android")
    if not key.is_file():
        run([jdk / "bin/keytool.exe", "-genkeypair", "-noprompt", "-keystore", key, "-storepass:env", "KIF_TEST_KEY_PASSWORD", "-keypass:env", "KIF_TEST_KEY_PASSWORD", "-alias", "androiddebugkey", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-dname", "CN=KIF Local Test,O=Kuray,C=CN"], env=env)
    output = ROOT / "temp/artifacts"
    output.mkdir(exist_ok=True)
    final = output / ("KIF-runtime-probe-arm64-test.apk" if args.runtime_only else "KIF-0.20.7-android.1-arm64-test.apk")
    signer = [jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar"]
    run(signer + ["sign", "--ks", key, "--ks-key-alias", "androiddebugkey", "--ks-pass", "env:KIF_TEST_KEY_PASSWORD", "--key-pass", "env:KIF_TEST_KEY_PASSWORD", "--out", final, aligned], env=env)
    run(signer + ["verify", "--verbose", final])
    run([tools / "aapt2.exe", "dump", "badging", final], stdout=(work / "apk-badging.txt").open("w", encoding="utf-8"))
    sha = hashlib.file_digest(final.open("rb"), "sha256").hexdigest()
    (output / (final.name + ".sha256")).write_text(sha + "  " + final.name + "\n", encoding="utf-8")
    source_paths = sorted((ROOT / "android").rglob("*.java")) + sorted((ROOT / "android").rglob("*.rb")) + sorted((ROOT / "scripts/android").glob("*.py")) + sorted((ROOT / "android/native").glob("*.c"))
    source_hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths}
    record = {"apk": final.name, "sha256": sha, "bytes": final.stat().st_size, "runtime": json.loads((ROOT / "android/runtime.lock.json").read_text()), "networkBridge": bridge_record, "payload": manifest["id"], "runtimeOnly": manifest.get("runtimeOnly", False), "sources": source_hashes, "compileSdk": 35, "buildTools": "35.0.0", "status": "built; gameplay validation pending"}
    (output / (final.stem + "-build-record.json")).write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(f"Built {final} ({final.stat().st_size} bytes), SHA256={sha}", flush=True)

if __name__ == "__main__":
    main()
