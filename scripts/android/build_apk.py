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
from package_game import ROOT, write_payload, refresh_ruby_payload

ORIGINAL_RUNTIME_SHA256 = "6f90fabcb227eafa2a5b3a8967dbe34368cec06efab5cd3e709f538003186232"
EMULATOR_RUNTIME_SHA256 = "90bee3c7406d62ca903ffb64798bca3f6da009e4b94402a580cb37a8f7ae0d23"

def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

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
        stem = "KIF-network-probe-arm64" if with_network else "KIF-runtime-probe-arm64"
        return stem + ("-emulator" if emulator_compatible else "") + "-test.apk"
    stem = "KIF-0.20.7-android.1-arm64"
    if emulator_compatible:
        stem += "-emulator" + ("-network" if with_network else "")
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
                        "Init_libkif_android_bridge", "Init_kif_android_bridge"}
    if (not isinstance(provenance, dict) or provenance.get("inputBridge") is not True
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
    jdk = args.jdk or next((ROOT / "temp/tools").glob("jdk-17*"), None)
    if jdk is None or not (jdk / "bin/javac.exe").is_file():
        raise SystemExit("Portable JDK17 missing; run bootstrap-tools.ps1 or pass --jdk")
    sdk = args.sdk
    tools = sdk / "build-tools/35.0.0"
    platform = sdk / "platforms/android-35/android.jar"
    generated = ROOT / "temp/android-generated"
    runtime_library, original_runtime_sha, emulator_record = select_runtime(generated, args.emulator_compatible)
    input_bridge_record = require_input_bridge(generated)
    work = ROOT / ("temp/android-network-build" if args.runtime_only and args.with_network else "temp/android-smoke-build" if args.runtime_only else "temp/android-build")
    if args.emulator_compatible:
        work = work.with_name(work.name + "-emulator" + ("-network" if args.with_network and not args.runtime_only else ""))
    work.mkdir(parents=True, exist_ok=True)
    classes, dex = work / "classes", work / "dex"
    for directory in (classes, dex):
        # Delete only the verified, dedicated build directory.
        if directory.exists():
            assert directory.resolve().parent == work.resolve()
            shutil.rmtree(directory)
        directory.mkdir()
    assets = work / "assets"
    if args.refresh_ruby:
        refresh_ruby_payload(assets)
    elif not args.skip_payload:
        write_payload(assets, args.runtime_only, args.asset_root)
    if not all((assets / name).is_file() for name in ("payload.zip", "payload-manifest.json", "mkxp-base.json")):
        raise SystemExit("No staged payload")
    manifest = json.loads((assets / "payload-manifest.json").read_text())
    network_marker = assets / "network-enabled"
    if args.with_network:
        network_marker.write_text("1", encoding="ascii")
    elif network_marker.exists():
        network_marker.unlink()
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
    sources = sorted((ROOT / "android/app/src/main/java").rglob("*.java")) + sorted((generated / "java").rglob("*.java"))
    source_list = work / "sources.txt"
    source_list.write_text("\n".join('"' + str(f).replace("\\", "/") + '"' for f in sources), encoding="utf-8")
    print("Compiling Java shell and pinned SDL bootstrap", flush=True)
    run([jdk / "bin/javac.exe", "-J-Duser.language=en", "-encoding", "UTF-8", "--release", "8", "-classpath", platform, "-d", classes, "@" + str(source_list)])
    jar = work / "classes.jar"
    run([jdk / "bin/jar.exe", "cf", jar, "-C", classes, "."])
    run([jdk / "bin/java.exe", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "30", "--lib", platform, "--output", dex, jar])
    unsigned = work / "kif-unsigned.apk"
    app_manifest = work / "AndroidManifest.xml"
    app_xml = (ROOT / "android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
    if args.with_network:
        app_xml = app_xml.replace("    <uses-sdk", '    <uses-permission android:name="android.permission.INTERNET" />\n    <uses-sdk', 1)
    app_manifest.write_text(app_xml, encoding="utf-8")
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
    signer = [jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar"]
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
    source_paths = sorted((ROOT / "android").rglob("*.java")) + sorted((ROOT / "android").rglob("*.rb")) + sorted((ROOT / "scripts/android").glob("*.py")) + [ROOT / "android/native/kif_android_bridge.c", ROOT / "scripts/android/build_bridge.ps1"]
    source_hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths}
    record = {"apk": final.name, "sha256": sha, "bytes": final.stat().st_size, "runtime": json.loads((ROOT / "android/runtime.lock.json").read_text()), "payload": manifest["id"], "runtimeOnly": manifest.get("runtimeOnly", False), "networkBridge": args.with_network, "sources": source_hashes, "compileSdk": 35, "buildTools": "35.0.0", "status": "built; gameplay validation pending"}
    record.update({"emulatorOnly": args.emulator_compatible, "inputBridge": True, "helperBridge": input_bridge_record,
                   "runtimeLibrary": {"path": runtime_entry, "originalSha256": original_runtime_sha,
                                      "packagedSha256": packaged_runtime_sha, "nativeRuntimeRebuiltFromSource": False},
                   "emulatorCompatibility": emulator_record})
    (output / (final.stem + "-build-record.json")).write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(f"Built {final} ({final.stat().st_size} bytes), SHA256={sha}", flush=True)

if __name__ == "__main__":
    main()
