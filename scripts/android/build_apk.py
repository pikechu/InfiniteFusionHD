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
from package_game import ROOT, write_payload, refresh_ruby_payload, validate_payload

ORIGINAL_RUNTIME_SHA256 = "6f90fabcb227eafa2a5b3a8967dbe34368cec06efab5cd3e709f538003186232"
EMULATOR_RUNTIME_SHA256 = "90bee3c7406d62ca903ffb64798bca3f6da009e4b94402a580cb37a8f7ae0d23"

def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def source_snapshot():
    paths = set((ROOT / "android/app/src/main").rglob("*.java"))
    paths.update((ROOT / "android/ruby").glob("*.rb"))
    paths.update((ROOT / "Data/Scripts").rglob("*.rb"))
    paths.update((ROOT / "temp/android-generated/java").rglob("*.java"))
    for name in ("Game.ini", "Data/multiplayer-build.json", "android/app/src/main/AndroidManifest.xml", "android/runtime.lock.json",
                 "android/native/kif_android_bridge.c", "scripts/android/build_bridge.ps1",
                 "scripts/android/build_apk.py", "scripts/android/package_game.py", "scripts/android/payload_format.py"):
        path = ROOT / name
        if path.is_file():
            paths.add(path)
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}

def assert_sources_unchanged(expected):
    current = source_snapshot()
    changed = sorted(name for name in set(expected) | set(current) if expected.get(name) != current.get(name))
    if changed:
        raise SystemExit("Source files changed during build; finish edits and rebuild: " + ", ".join(changed[:8]))

def validate_staged_scripts(manifest):
    for name, expected in manifest["files"].items():
        if name == "Game.ini" or name == "Data/multiplayer-build.json" or name.startswith("Data/Scripts/"):
            path = ROOT / name
        elif "/" not in name and name.endswith(".rb"):
            path = ROOT / "android/ruby" / name
        else:
            continue
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected["sha256"]:
            raise SystemExit("Staged game script differs from current source; use --refresh-ruby: " + name)

def validate_apk_assets(assets, with_network, require_payload=True):
    """Reject stale partials/unknown paths instead of silently bundling or deleting them."""
    required = {"payload.zip", "payload-manifest.json", "mkxp-base.json"}
    allowed = required | {"analytics.json"} | ({"network-enabled"} if with_network else set())
    if not assets.exists():
        if require_payload:
            raise ValueError(f"No staged assets: {assets}")
        return
    if not assets.is_dir() or assets.is_symlink():
        raise ValueError(f"APK assets must be a regular staging directory: {assets}")
    entries = {item.name: item for item in assets.iterdir()}
    unexpected = sorted(name for name, item in entries.items()
                        if name not in allowed or not item.is_file() or item.is_symlink())
    if unexpected:
        raise ValueError("Unexpected APK asset paths (preserved for inspection): " + ", ".join(unexpected))
    marker = entries.get("network-enabled")
    if marker is not None and marker.read_bytes() != b"1":
        raise ValueError("Invalid network-enabled marker; preserved for inspection")
    if require_payload:
        missing = sorted((required | ({"network-enabled"} if with_network else set())) - set(entries))
        if missing:
            raise ValueError("Missing staged APK assets: " + ", ".join(missing))

def select_runtime(generated, emulator_compatible):
    original = generated / "jniLibs/arm64-v8a/libmkxp-z.so"
    if not original.is_file():
        raise SystemExit("Pinned runtime missing; run scripts/android/prepare-runtime.ps1")
    original_sha = hashlib.sha256(original.read_bytes()).hexdigest()
    if original_sha != ORIGINAL_RUNTIME_SHA256:
        raise SystemExit("Shared runtime SHA256 mismatch; restore the pinned original with prepare-runtime.ps1. Emulator variants must stay in temp/android-emulator-native.")
    if not emulator_compatible:
        return original, original_sha, None
    variant_root = ROOT / "temp/android-emulator-native"
    patched = variant_root / "arm64-v8a/libmkxp-z.so"
    provenance_file = variant_root / "emulator-runtime-provenance.json"
    source_patch = ROOT / "android/native/emulator-coordinate-source.patch"
    instruction = "Run scripts/android/patch_emulator_runtime.py first; no fallback to the phone runtime is allowed."
    if not all(path.is_file() for path in (patched, provenance_file, source_patch)):
        raise SystemExit("Emulator runtime, provenance, or source patch missing. " + instruction)
    if patched.resolve() == original.resolve():
        raise SystemExit("Emulator runtime must be separate from the original shared input")
    if hashlib.sha256(patched.read_bytes()).hexdigest() != EMULATOR_RUNTIME_SHA256:
        raise SystemExit("Emulator runtime SHA256 mismatch. " + instruction)
    try:
        provenance = json.loads(provenance_file.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise SystemExit("Invalid emulator provenance. " + instruction) from error
    runtime_lock = json.loads((ROOT / "android/runtime.lock.json").read_text(encoding="utf-8"))
    expected = {"schemaVersion": 1, "variant": "emulator-only-old-arm-native-translation",
                "runtimeCommit": runtime_lock["commit"], "nativeRuntimeRebuiltFromSource": False,
                "originalInstructionIsLegalAArch64": True, "inputSha256": ORIGINAL_RUNTIME_SHA256,
                "outputSha256": EMULATOR_RUNTIME_SHA256, "changedByteCount": 16,
                "directBranchIntoSecondInstruction": False}
    if not isinstance(provenance, dict) or any(provenance.get(key) != value for key, value in expected.items()):
        raise SystemExit("Emulator provenance does not describe the pinned workaround. " + instruction)
    return patched, original_sha, {
        "originalSha256": original_sha, "patchedSha256": EMULATOR_RUNTIME_SHA256,
        "sourcePatch": {"path": source_patch.relative_to(ROOT).as_posix(),
                        "sha256": hashlib.sha256(source_patch.read_bytes()).hexdigest(),
                        "fullRuntimeSourceBuildValidated": False},
        "provenance": {"path": provenance_file.relative_to(ROOT).as_posix(),
                       "sha256": hashlib.sha256(provenance_file.read_bytes()).hexdigest(),
                       "record": provenance},
    }

def output_name(runtime_only, with_network, emulator_compatible):
    if runtime_only:
        stem = "InfiniteFusionHD-network-probe-arm64" if with_network else "InfiniteFusionHD-runtime-probe-arm64"
        return stem + ("-emulator" if emulator_compatible else "") + "-test.apk"
    stem = "InfiniteFusionHD-0.20.7-android.10-arm64"
    if emulator_compatible:
        stem += "-emulator"
    if with_network:
        stem += "-network"
    return stem + "-test.apk"

def require_input_bridge(generated):
    library = generated / "jniLibs/arm64-v8a/libkif_android_bridge.so"
    provenance_path = ROOT / "temp/android-bridge-build/arm64-v8a-api30/provenance.json"
    source = ROOT / "android/native/kif_android_bridge.c"
    instruction = "Build the required virtual input helper with scripts/android/build_bridge.ps1 first."
    if not all(path.is_file() for path in (library, provenance_path, source)):
        raise SystemExit(instruction)
    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8-sig"))
    except (ValueError, UnicodeError) as error:
        raise SystemExit("Invalid helper provenance. " + instruction) from error
    sha = hashlib.sha256(library.read_bytes()).hexdigest()
    required_exports = {"Java_org_kuray_kif_NetworkBridge_configure",
                        "Java_org_kuray_kif_NetworkBridge_setVirtualKey",
                        "Java_org_kuray_kif_NetworkBridge_clearVirtualKeys",
                        "Java_org_kuray_kif_NetworkBridge_setDisplayStretch",
                        "Init_libkif_android_bridge", "Init_kif_android_bridge"}
    if (not isinstance(provenance, dict) or provenance.get("inputBridge") is not True
            or provenance.get("httpAsync", {}).get("version") != 1
            or provenance.get("outputSha256") != sha
            or provenance.get("sourceSha256") != hashlib.sha256(source.read_bytes()).hexdigest()
            or not required_exports.issubset(provenance.get("definedExports", []))):
        raise SystemExit("Missing or stale virtual input helper. " + instruction)
    return {"path": "lib/arm64-v8a/libkif_android_bridge.so", "sha256": sha,
            "provenance": {"path": provenance_path.relative_to(ROOT).as_posix(),
                           "sha256": hashlib.sha256(provenance_path.read_bytes()).hexdigest(),
                           "record": provenance}}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--jdk", type=Path)
    parser.add_argument("--sdk", type=Path, default=ROOT / "temp/tools/android-sdk")
    parser.add_argument("--skip-payload", action="store_true")
    parser.add_argument("--refresh-ruby", action="store_true", help="Reuse the verified asset snapshot, refreshing Ruby and config only")
    parser.add_argument("--runtime-only", action="store_true", help="Build a clearly labeled runtime probe without the game")
    parser.add_argument("--asset-root", type=Path, help="Read tracked base assets from another checkout when using a sparse source worktree")
    parser.add_argument("--with-network", action="store_true", help="Enable the helper's optional Android TLS transport and INTERNET permission")
    parser.add_argument("--emulator-compatible", action="store_true", help="Opt into the separately SHA-pinned old ARM translator workaround; never use this variant for phone acceptance")
    args = parser.parse_args()
    source_hashes = source_snapshot()
    jdk = args.jdk or next((ROOT / "temp/tools").glob("jdk-17*"), None)
    if jdk is None or not (jdk / "bin/javac.exe").is_file():
        raise SystemExit("Portable JDK17 missing; run bootstrap-tools.ps1 or pass --jdk")
    sdk = args.sdk
    tools = sdk / "build-tools/35.0.0"
    platform = sdk / "platforms/android-35/android.jar"
    generated = ROOT / "temp/android-generated"
    runtime_library, original_runtime_sha, emulator_record = select_runtime(generated, args.emulator_compatible)
    input_bridge_record = require_input_bridge(generated)
    work = ROOT / ("temp/android-network-build" if args.runtime_only and args.with_network else "temp/android-smoke-build" if args.runtime_only else "temp/android-build-network" if args.with_network else "temp/android-build")
    if args.emulator_compatible:
        work = work.with_name(work.name + "-emulator")
    work.mkdir(parents=True, exist_ok=True)
    assets = work / "assets"
    # Check before reading/rebuilding a large payload or starting Java/D8 work.
    validate_apk_assets(assets, args.with_network, require_payload=False)
    classes, dex = work / "classes", work / "dex"
    for directory in (classes, dex):
        # Delete only the verified, dedicated build directory.
        if directory.exists():
            assert directory.resolve().parent == work.resolve()
            shutil.rmtree(directory)
        directory.mkdir()
    if args.refresh_ruby:
        refresh_ruby_payload(assets)
    elif not args.skip_payload:
        write_payload(assets, args.runtime_only, args.asset_root)
    if not all((assets / name).is_file() for name in ("payload.zip", "payload-manifest.json", "mkxp-base.json")):
        raise SystemExit("No staged payload")
    manifest = json.loads((assets / "payload-manifest.json").read_text())
    analytics_path = ROOT / "Data/analytics.json"
    analytics = json.loads(analytics_path.read_text(encoding="utf-8")) if analytics_path.is_file() else {"enabled": False}
    if set(analytics) - {"enabled", "endpoint", "site_id", "app_url", "channel", "heartbeat_seconds", "dimensions"}:
        raise SystemExit("Unsupported analytics fields; never bundle server tokens")
    if args.runtime_only:
        analytics["enabled"] = False
    (assets / "analytics.json").write_text(json.dumps(analytics, indent=2), encoding="utf-8")
    network_marker = assets / "network-enabled"
    if args.with_network:
        network_marker.write_text("1", encoding="ascii")
    validate_apk_assets(assets, args.with_network)
    # Refuse a mixed payload/manifest pair left by an interrupted packaging pass.
    if args.skip_payload:
        print("Verifying staged payload canonical hashes and alias inventory", flush=True)
    validate_payload(assets / "payload.zip", manifest, verify_hashes=args.skip_payload)
    if not args.runtime_only and "Data/multiplayer-build.json" not in manifest["files"]:
        raise SystemExit("Online build manifest missing; rebuild payload")
    validate_staged_scripts(manifest)
    assert_sources_unchanged(source_hashes)
    sources = sorted((ROOT / "android/app/src/main/java").rglob("*.java")) + sorted((generated / "java").rglob("*.java"))
    source_list = work / "sources.txt"
    source_list.write_text("\n".join('"' + str(f).replace("\\", "/") + '"' for f in sources), encoding="utf-8")
    print("Compiling Java shell and pinned SDL bootstrap", flush=True)
    run([jdk / "bin/javac.exe", "-J-Xmx256m", "-J-Duser.language=en", "-encoding", "UTF-8", "--release", "8", "-classpath", platform, "-d", classes, "@" + str(source_list)])
    jar = work / "classes.jar"
    run([jdk / "bin/jar.exe", "cf", jar, "-C", classes, "."])
    run([jdk / "bin/java.exe", "-Xmx256m", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "30", "--lib", platform, "--output", dex, jar])
    unsigned = work / "kif-unsigned.apk"
    app_manifest = work / "AndroidManifest.xml"
    app_xml = (ROOT / "android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
    if args.with_network:
        app_xml = app_xml.replace("    <uses-sdk", '    <uses-permission android:name="android.permission.INTERNET" />\n    <uses-sdk', 1)
    app_manifest.write_text(app_xml, encoding="utf-8")
    # Recheck immediately before aapt2's directory-wide asset collection as well.
    validate_apk_assets(assets, args.with_network)
    run([tools / "aapt2.exe", "link", "-I", platform, "--manifest", app_manifest, "-A", assets, "-0", "zip", "-o", unsigned])
    with zipfile.ZipFile(unsigned, "a", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as apk:
        apk.write(dex / "classes.dex", "classes.dex")
        for library in sorted((generated / "jniLibs").rglob("*.so")):
            archive_path = "lib/" + library.relative_to(generated / "jniLibs").as_posix()
            source = runtime_library if archive_path == "lib/arm64-v8a/libmkxp-z.so" else library
            apk.write(source, archive_path)
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
    final = output / output_name(args.runtime_only, args.with_network, args.emulator_compatible)
    signer = [jdk / "bin/java.exe", "-Xmx256m", "-jar", tools / "lib/apksigner.jar"]
    assert_sources_unchanged(source_hashes)
    run(signer + ["sign", "--ks", key, "--ks-key-alias", "androiddebugkey", "--ks-pass", "env:KIF_TEST_KEY_PASSWORD", "--key-pass", "env:KIF_TEST_KEY_PASSWORD", "--out", final, aligned], env=env)
    run(signer + ["verify", "--verbose", final])
    with zipfile.ZipFile(final) as apk:
        runtime_entry = "lib/arm64-v8a/libmkxp-z.so"
        if apk.namelist().count(runtime_entry) != 1:
            raise SystemExit("Signed APK must contain exactly one ARM64 mkxp runtime")
        packaged_runtime_sha = hashlib.sha256(apk.read(runtime_entry)).hexdigest()
        expected_sha = EMULATOR_RUNTIME_SHA256 if args.emulator_compatible else ORIGINAL_RUNTIME_SHA256
        if packaged_runtime_sha != expected_sha:
            raise SystemExit("Signed APK runtime hash does not match the selected variant")
        if (apk.namelist().count(input_bridge_record["path"]) != 1
                or hashlib.sha256(apk.read(input_bridge_record["path"])).hexdigest() != input_bridge_record["sha256"]):
            raise SystemExit("Signed APK is missing the required virtual input helper or its hash differs")
    run([tools / "aapt2.exe", "dump", "badging", final], stdout=(work / "apk-badging.txt").open("w", encoding="utf-8"))
    sha = hashlib.file_digest(final.open("rb"), "sha256").hexdigest()
    (output / (final.name + ".sha256")).write_text(sha + "  " + final.name + "\n", encoding="utf-8")
    assert_sources_unchanged(source_hashes)
    record = {"apk": final.name, "sha256": sha, "bytes": final.stat().st_size, "runtime": json.loads((ROOT / "android/runtime.lock.json").read_text()), "payload": manifest["id"], "runtimeOnly": manifest.get("runtimeOnly", False), "networkBridge": args.with_network, "sources": source_hashes, "compileSdk": 35, "buildTools": "35.0.0", "status": "built; gameplay validation pending"}
    record.update({"sourceSnapshotVerified": True, "stagedScriptHashesVerified": True,
                   "emulatorOnly": args.emulator_compatible, "inputBridge": True, "helperBridge": input_bridge_record,
                   "runtimeLibrary": {"path": runtime_entry, "originalSha256": original_runtime_sha,
                                      "packagedSha256": packaged_runtime_sha, "nativeRuntimeRebuiltFromSource": False},
                   "emulatorCompatibility": emulator_record})
    (output / (final.stem + "-build-record.json")).write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(f"Built {final} ({final.stat().st_size} bytes), SHA256={sha}", flush=True)

if __name__ == "__main__":
    main()
