"""Build an isolated diagnostic APK; never installs, launches, or invokes native compilers.

Only Ruby/OpenSSL are source-built overrides. mkxp/SDL/codecs remain pinned
prebuilt inputs. This is component integration evidence, not a full runtime rebuild.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

sys.dont_write_bytecode = True
from build_apk import select_runtime, require_input_bridge

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "android/native-probe"
OUTPUT = ROOT / "temp/native-probe"
APP_ID = "org.kuray.kif.nativeprobe"
OVERRIDES = {"libruby.so", "libssl.so", "libcrypto.so"}
ANDROID = "{http://schemas.android.com/apk/res/android}"
STDLIB_FILES = {"openssl.rb", "socket.rb", "ipaddr.rb", "digest.rb"}
DEFAULT_FONT_SHA256 = "ee009e30695cc6d365c1fb835a8a4a30c9f69c1e84eef30ab496540b77b1f799"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def run_logged(args, log):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, encoding="utf-8", errors="replace")
    log.write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Build step failed ({result.returncode}); see {log}")
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def safe_output(path):
    path = path.resolve()
    if not path.is_relative_to(OUTPUT.resolve()) or path == OUTPUT.resolve():
        raise ValueError(f"Output must be inside dedicated temp/native-probe: {path}")
    return path


def reset_directory(path):
    path = safe_output(path)
    if path.exists():
        if path.is_symlink():
            raise ValueError(f"Refusing symlink build directory: {path}")
        shutil.rmtree(path)
    path.mkdir(parents=True)


def source_record(path, data=None):
    data = path.read_bytes() if data is None else data
    return {"path": str(path.resolve()), "sha256": sha(data), "bytes": len(data)}


def elf(data):
    """Read ELF64 AArch64 metadata without loading or executing target code."""
    if data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != 183:
        raise ValueError("Expected little-endian ELF64 AArch64 shared library")
    if struct.unpack_from("<H", data, 16)[0] != 3:
        raise ValueError("Expected ET_DYN library")
    phoff, shoff = struct.unpack_from("<QQ", data, 32)
    phsize, phnum, shsize, shnum = struct.unpack_from("<HHHH", data, 54)
    loads = []
    for i in range(phnum):
        header = struct.unpack_from("<IIQQQQQQ", data, phoff + i * phsize)
        if header[0] == 1:
            loads.append(header[7])
    if not loads:
        raise ValueError("ELF lacks PT_LOAD")
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shsize) for i in range(shnum)]
    needed, soname, runpaths = [], None, []
    defined, undefined = set(), set()
    for section in sections:
        kind, offset, size, link, entsize = section[1], section[4], section[5], section[6], section[9]
        if kind not in (6, 11):  # SHT_DYNAMIC and SHT_DYNSYM
            continue
        strings_header = sections[link]
        strings = data[strings_header[4]:strings_header[4] + strings_header[5]]
        def string(index):
            end = strings.find(b"\0", index)
            if end < 0:
                raise ValueError("Unterminated ELF string")
            return strings[index:end].decode("utf-8")
        for entry in range(offset, offset + size, entsize):
            if kind == 6:
                tag, value = struct.unpack_from("<qQ", data, entry)
                if tag == 1:
                    needed.append(string(value))
                elif tag == 14:
                    soname = string(value)
                elif tag in (15, 29):
                    runpaths.append(string(value))
            else:
                name, info, other, index, value, length = struct.unpack_from("<IBBHQQ", data, entry)
                if name and info >> 4 in (1, 2) and (other & 3) in (0, 3):
                    (undefined if index == 0 else defined).add(string(name))
    return {"machine": 183, "soname": soname, "needed": needed, "runpaths": runpaths,
            "loadAlignments": loads, "defined": defined, "undefined": undefined}


def manifest_safety():
    root = ET.parse(FIXTURE / "AndroidManifest.xml").getroot()
    if root.get("package") != APP_ID or root.get(ANDROID + "sharedUserId"):
        raise ValueError("Probe manifest application identity is not isolated")
    app = root.find("application")
    if app.get(ANDROID + "label") != "Native Ruby Probe" or app.get(ANDROID + "allowBackup") != "false":
        raise ValueError("Probe application label/backup policy mismatch")
    if list(app.findall("provider")) or list(app.findall("service")) or list(app.findall("receiver")):
        raise ValueError("Probe must not expose services/providers/receivers")
    activities = {a.get(ANDROID + "name"): a for a in app.findall("activity")}
    expected = {"org.kuray.kif.NativeProbeLauncherActivity", "org.kuray.kif.GameActivity"}
    if set(activities) != expected:
        raise ValueError("Probe activities must use explicit JNI-compatible FQCNs")
    if activities["org.kuray.kif.GameActivity"].get(ANDROID + "exported") != "false":
        raise ValueError("Probe native Activity must be private")
    if activities["org.kuray.kif.GameActivity"].get(ANDROID + "process") != ":probe":
        raise ValueError("MRI must run in the separate private probe process")
    if activities["org.kuray.kif.NativeProbeLauncherActivity"].get(ANDROID + "exported") != "true":
        raise ValueError("Only the explicit probe launcher may be launched externally")
    permissions = {p.get(ANDROID + "name") for p in root.findall("uses-permission")}
    if permissions != {"android.permission.VIBRATE"}:
        raise ValueError("Unexpected probe permission; no network/storage permission is allowed")
    return {"applicationId": APP_ID, "applicationLabel": "Native Ruby Probe",
            "jniJavaPackage": "org.kuray.kif", "gameActivityExported": False,
            "sharedUserId": None, "externalStorageAccess": False,
            "privateRoot": f"/data/user/0/{APP_ID}/files/native-probe",
            "playerSaveCodePackaged": False}


def payload(work, prefix, font):
    stdlib = prefix / "lib/ruby/3.4.0"
    sources = {name: FIXTURE / name for name in ("Game.ini", "runtime-smoke.rb", "native-ruby-probe.rb")}
    for name in STDLIB_FILES:
        sources["Ruby/3.4.0/" + name] = stdlib / name
    for directory in ("openssl", "digest"):
        for path in sorted((stdlib / directory).rglob("*.rb")):
            sources["Ruby/3.4.0/" + path.relative_to(stdlib).as_posix()] = path
    sources["Fonts/power green.ttf"] = font
    sources["LICENSES/mkxp-z-COPYING.txt"] = ROOT / "temp/android-generated/licenses/mkxp-z-COPYING.txt"
    sources["LICENSES/Ruby-COPYING.txt"] = ROOT / "temp/windows-native/sources/ruby-3.4.10/COPYING"
    sources["LICENSES/Ruby-BSDL.txt"] = ROOT / "temp/windows-native/sources/ruby-3.4.10/BSDL"
    sources["LICENSES/OpenSSL-LICENSE.txt"] = ROOT / "temp/windows-native/sources/openssl/LICENSE.txt"
    files, origins = {}, {}
    assets = work / "assets"
    reset_directory(assets)
    with zipfile.ZipFile(assets / "probe-payload.zip", "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, path in sorted(sources.items()):
            if not path.is_file():
                raise ValueError(f"Missing fixed probe payload input: {path}")
            data = path.read_bytes()
            item = zipfile.ZipInfo(name, date_time=(2026, 10, 20, 0, 0, 0))
            item.external_attr = 0o100644 << 16
            archive.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
            files[name] = {"size": len(data), "sha256": sha(data)}
            origins[name] = source_record(path, data)
    content_id = sha(json.dumps(files, sort_keys=True, separators=(",", ":")).encode())[:24]
    manifest = {"schemaVersion": 1, "id": content_id, "runtimeOnly": True, "files": files,
                "fullGameIncluded": False, "playerSavesIncluded": False}
    write_json(assets / "probe-manifest.json", manifest)
    config = {"rgssVersion": 1, "defScreenW": 512, "defScreenH": 384, "fixedFramerate": 40,
              "fixedAspectRatio": True, "fullscreen": True, "pathCache": False,
              "enableReset": False, "enableSettings": False, "displayFPS": False,
              "printFPS": False, "dataPathOrg": "Kuray", "dataPathApp": "NativeRubyProbe",
              "fontHeightReporting": 1, "rubyLoadpath": [".", "Ruby/3.4.0"],
              "customScript": "native-ruby-probe.rb"}
    # The engine reads this directly from its private content working directory.
    config_bytes = (json.dumps(config, indent=2) + "\n").encode()
    with zipfile.ZipFile(assets / "probe-payload.zip", "a", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        entry = zipfile.ZipInfo("mkxp.json", date_time=(2026, 10, 20, 0, 0, 0))
        entry.external_attr = 0o100644 << 16
        archive.writestr(entry, config_bytes, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
    files["mkxp.json"] = {"size": len(config_bytes), "sha256": sha(config_bytes)}
    manifest["id"] = sha(json.dumps(files, sort_keys=True, separators=(",", ":")).encode())[:24]
    write_json(assets / "probe-manifest.json", manifest)
    return manifest, origins


def compile_shell(work, jdk, sdk):
    generated = ROOT / "temp/android-generated"
    provenance = json.loads((generated / "runtime-provenance.json").read_text(encoding="utf-8-sig"))
    sources = list(sorted((FIXTURE / "java").rglob("*.java")))
    sources.append(ROOT / "android/app/src/main/java/org/kuray/kif/NetworkBridge.java")
    for item in provenance["sdlJava"]:
        path = generated / item["path"]
        if sha(path.read_bytes()) != item["sha256"]:
            raise ValueError(f"SDL Java differs from fixed runtime source: {path}")
        sources.append(path)
    # Copy only this allowlist into the probe project. Main game Activities/installers are excluded.
    source_dir = work / "java"
    reset_directory(source_dir)
    records, staged = {}, []
    for path in sources:
        data = path.read_bytes()
        if path.name in ("GameActivity.java", "NativeProbeLauncherActivity.java", "NetworkBridge.java"):
            relative = Path("org/kuray/kif") / path.name
        else:
            relative = Path("org/libsdl/app") / path.name
        dest = source_dir / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        staged.append(dest)
        records[relative.as_posix()] = source_record(path, data)
    classes, dex = work / "classes", work / "dex"
    reset_directory(classes)
    reset_directory(dex)
    source_list = work / "sources.txt"
    source_list.write_text("\n".join('"' + str(p).replace("\\", "/") + '"' for p in staged), encoding="utf-8")
    platform, tools = sdk / "platforms/android-35/android.jar", sdk / "build-tools/35.0.0"
    print("Compiling isolated Java probe shell and fixed SDL Java", flush=True)
    run_logged([jdk / "bin/javac.exe", "-J-Duser.language=en", "-encoding", "UTF-8", "--release", "8", "-classpath", platform, "-d", classes, "@" + str(source_list)], work / "javac.log")
    jar = work / "classes.jar"
    run_logged([jdk / "bin/jar.exe", "cf", jar, "-C", classes, "."], work / "jar.log")
    run_logged([jdk / "bin/java.exe", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "30", "--lib", platform, "--output", dex, jar], work / "d8.log")
    return records


def native_libraries(expected, emulator):
    generated = ROOT / "temp/android-generated"
    runtime, original_hash, emulator_record = select_runtime(generated, emulator)
    bridge_record = require_input_bridge(generated)
    provenance = json.loads((generated / "runtime-provenance.json").read_text(encoding="utf-8-sig"))
    blobs, old, records = {}, {}, {}
    for item in provenance["libraries"]:
        path = generated / item["path"]
        data = path.read_bytes()
        if sha(data) != item["sha256"]:
            raise ValueError(f"Original runtime input differs from pinned provenance: {path}")
        old[path.name] = data
        blobs[path.name] = data
        records[path.name] = {**source_record(path, data), "origin": "pinned-prebuilt"}
    if emulator:
        data = runtime.read_bytes()
        if sha(data) != emulator_record["patchedSha256"]:
            raise ValueError("Emulator runtime changed during probe build")
        blobs[runtime.name] = data
        records[runtime.name] = {**source_record(runtime, data), "origin": "pinned-prebuilt-with-explicit-emulator-workaround"}
    bridge = generated / "jniLibs/arm64-v8a/libkif_android_bridge.so"
    data = bridge.read_bytes()
    if sha(data) != bridge_record["sha256"]:
        raise ValueError("Input bridge changed during probe build")
    blobs[bridge.name] = data
    records[bridge.name] = {**source_record(bridge, data), "origin": "existing-source-built-jni-helper"}
    for name, path in expected.items():
        source, digest = path
        data = source.read_bytes()
        if sha(data) != digest:
            raise ValueError(f"Explicit source-built override hash mismatch: {name}")
        blobs[name] = data
        records[name] = {**source_record(source, data), "origin": "source-built-component-override"}
    validation_path = ROOT / "temp/windows-native/ruby-module-validation.json"
    validation = json.loads(validation_path.read_text(encoding="utf-8-sig"))
    if validation.get("sha256") != expected["libruby.so"][1] or validation.get("targetExecuted") is not False:
        raise ValueError("Ruby validation must describe this exact source-built library without claiming target execution")
    metadata = {name: elf(data) for name, data in blobs.items()}
    component_abi = {}
    for name in OVERRIDES:
        current = metadata[name]
        if current["soname"] != name or any(a < 16384 for a in current["loadAlignments"]) or any(current["runpaths"]):
            raise ValueError(f"Override must have matching SONAME, >=16 KiB LOADs, and no host RUNPATH: {name}")
        required = set()
        previous = elf(old[name])
        for consumer, consumer_elf in metadata.items():
            if consumer != name:
                required |= consumer_elf["undefined"] & previous["defined"]
        missing = sorted(required - current["defined"])
        if missing:
            raise ValueError(f"Override {name} lacks original ABI symbols required by packaged libraries: {missing[:12]}")
        component_abi[name] = {"requiredOriginalAbiSymbols": sorted(required), "missingSymbols": missing}
    system_libs = {"libc.so", "libdl.so", "libm.so", "libz.so", "liblog.so", "libandroid.so", "libEGL.so", "libGLESv1_CM.so", "libGLESv2.so", "libOpenSLES.so", "libvulkan.so", "libjnigraphics.so"}
    for name, item in metadata.items():
        unresolved = set(item["needed"]) - set(blobs) - system_libs
        if unresolved:
            raise ValueError(f"Unpackaged non-system DT_NEEDED for {name}: {sorted(unresolved)}")
        records[name]["elf"] = {k: v for k, v in item.items() if k not in ("defined", "undefined")}
    return blobs, records, {"emulatorOnly": emulator, "emulatorCompatibility": emulator_record,
                           "originalMkxpSha256": original_hash, "helperBridge": bridge_record,
                           "sourceBuildLock": json.loads((ROOT / "scripts/android/windows-native-lock.json").read_text(encoding="utf-8")),
                           "rubyComponentValidation": {"record": validation, **source_record(validation_path)},
                           "componentAbi": component_abi, "nativeRuntimeRebuiltFromSource": False}


def audit_apk(apk_path, work, tools, blobs, manifest):
    badging = subprocess.check_output([str(tools / "aapt2.exe"), "dump", "badging", str(apk_path)], text=True, encoding="utf-8")
    (work / "apk-badging.txt").write_text(badging, encoding="utf-8")
    if not re.search(r"^package: name='org\.kuray\.kif\.nativeprobe' ", badging, re.M):
        raise ValueError("Signed APK has wrong applicationId")
    label_matches = (re.search(r"^application-label:'Native Ruby Probe'$", badging, re.M)
                     or re.search(r"^application: label='Native Ruby Probe' ", badging, re.M))
    if not label_matches or "launchable-activity: name='org.kuray.kif.NativeProbeLauncherActivity'" not in badging:
        raise ValueError("Signed APK launcher/label mismatch")
    if re.findall(r"^uses-permission: name='([^']+)'", badging, re.M) != ["android.permission.VIBRATE"]:
        raise ValueError("Signed APK has unexpected permissions")
    xmltree = subprocess.check_output([str(tools / "aapt2.exe"), "dump", "xmltree", str(apk_path), "--file", "AndroidManifest.xml"], text=True, encoding="utf-8")
    (work / "apk-manifest-tree.txt").write_text(xmltree, encoding="utf-8")
    with zipfile.ZipFile(apk_path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate signed APK entries")
        actual_libs = {name for name in names if name.startswith("lib/")}
        expected_libs = {"lib/arm64-v8a/" + name for name in blobs}
        if actual_libs != expected_libs:
            raise ValueError("Unexpected APK library/ABI inventory")
        for name, data in blobs.items():
            if sha(archive.read("lib/arm64-v8a/" + name)) != sha(data):
                raise ValueError(f"Signed APK native library differs: {name}")
        expected_assets = {"assets/probe-payload.zip", "assets/probe-manifest.json"}
        if {name for name in names if name.startswith("assets/")} != expected_assets:
            raise ValueError("Unexpected signed APK assets")
        import io
        with zipfile.ZipFile(io.BytesIO(archive.read("assets/probe-payload.zip"))) as payload_zip:
            if len(payload_zip.namelist()) != len(set(payload_zip.namelist())) or set(payload_zip.namelist()) != set(manifest["files"]):
                raise ValueError("Unexpected nested probe payload inventory")
            for name, item in manifest["files"].items():
                if any(part.casefold() in {"data", "graphics", "audio", "pbs", "saves", "backups", "exportedpokemons"} for part in Path(name).parts) or name.lower().endswith((".sav", ".bak", ".rxdata")):
                    raise ValueError("Game data or save in diagnostic APK")
                data = payload_zip.read(name)
                if len(data) != item["size"] or sha(data) != item["sha256"]:
                    raise ValueError(f"Packaged fixture hash differs: {name}")
    return {"signedApkIdentityVerified": True, "nativeLibraryHashesVerified": True,
            "privateFixturePayloadVerified": True, "playerSavesIncluded": False,
            "libraries": len(blobs), "payloadFiles": len(manifest["files"]),
            "installed": False, "deviceExecuted": False, "gameplayValidated": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jdk", type=Path)
    parser.add_argument("--sdk", type=Path, default=ROOT / "temp/tools/android-sdk")
    parser.add_argument("--prefix", type=Path, default=ROOT / "temp/windows-native/prefix/arm64-v8a")
    parser.add_argument("--font", type=Path)
    parser.add_argument("--prepare-only", action="store_true", help="Stage minimal fixtures and compile Java/Dex; produce no APK or native library selection")
    parser.add_argument("--emulator-compatible", action="store_true", help="Explicitly select the separately pinned old ARM-translation mkxp workaround")
    parser.add_argument("--override-sha256", action="append", default=[], metavar="LIBRARY=SHA256", help="Required exact digest for each of libruby.so/libssl.so/libcrypto.so")
    args = parser.parse_args()
    isolation = manifest_safety()
    expected = {}
    for value in args.override_sha256:
        name, separator, digest = value.partition("=")
        if name not in OVERRIDES or name in expected or not separator or not re.fullmatch("[a-f0-9]{64}", digest):
            parser.error("Each override must be a unique library name and lowercase SHA256")
        expected[name] = (args.prefix / "lib" / name, digest)
    if not args.prepare_only and set(expected) != OVERRIDES:
        parser.error("Final APK requires all three explicit --override-sha256 values; do not select mutable current hashes automatically")
    if args.prepare_only and expected:
        parser.error("--prepare-only does not select native overrides")
    jdk = args.jdk or next((ROOT / "temp/tools").glob("jdk-17*"), None)
    if jdk is None or not (jdk / "bin/javac.exe").is_file():
        parser.error("Portable JDK17 missing; pass --jdk")
    font = args.font or ROOT / "Fonts/power green.ttf"
    if args.font is None and not font.is_file():
        font = ROOT.parent.parent / "Fonts/power green.ttf"
    if not font.is_file() or sha(font.read_bytes()) != DEFAULT_FONT_SHA256:
        parser.error("Probe needs the fixed KIF Power Green font; pass its location with --font")
    work = OUTPUT / ("emulator" if args.emulator_compatible else "arm64")
    work.mkdir(parents=True, exist_ok=True)
    manifest, origins = payload(work, args.prefix, font)
    java_sources = compile_shell(work, jdk, args.sdk)
    fixture_sources = {p.relative_to(FIXTURE).as_posix(): source_record(p) for p in sorted(FIXTURE.rglob("*")) if p.is_file()}
    preparation = {"status": "prepared; no APK or Android execution", "isolation": isolation,
                   "payload": manifest, "payloadOrigins": origins, "javaSources": java_sources,
                   "fixtureSources": fixture_sources, "builder": source_record(Path(__file__)),
                   "compileSdk": 35, "buildTools": "35.0.0", "emulatorOnlyRequested": args.emulator_compatible,
                   "nativeRuntimeRebuiltFromSource": False, "nativeCompilerInvoked": False}
    write_json(work / "preparation.json", preparation)
    if args.prepare_only:
        print(f"Prepared isolated Java/Dex and {len(manifest['files'])}-file fixture payload: {work}", flush=True)
        return
    blobs, native_records, native_details = native_libraries(expected, args.emulator_compatible)
    tools, platform = args.sdk / "build-tools/35.0.0", args.sdk / "platforms/android-35/android.jar"
    unsigned, aligned = work / "probe-unsigned.apk", work / "probe-aligned.apk"
    run([tools / "aapt2.exe", "link", "-I", platform, "--manifest", FIXTURE / "AndroidManifest.xml", "-A", work / "assets", "-0", "zip", "-o", unsigned])
    with zipfile.ZipFile(unsigned, "a", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.write(work / "dex/classes.dex", "classes.dex")
        for name, data in sorted(blobs.items()):
            archive.writestr("lib/arm64-v8a/" + name, data)
    run([tools / "zipalign.exe", "-f", "-p", "4", unsigned, aligned])
    key = ROOT / "temp/android-signing/kif-debug.keystore"
    if not key.is_file():
        raise ValueError("Existing local test signing key missing; no signing key is generated by this builder")
    env = dict(os.environ, KIF_TEST_KEY_PASSWORD="android")
    final = OUTPUT / ("Native-Ruby-Probe-arm64" + ("-emulator" if args.emulator_compatible else "") + "-test.apk")
    signer = [jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar"]
    run(signer + ["sign", "--ks", key, "--ks-key-alias", "androiddebugkey", "--ks-pass", "env:KIF_TEST_KEY_PASSWORD", "--key-pass", "env:KIF_TEST_KEY_PASSWORD", "--out", final, aligned], env=env)
    verify = run(signer + ["verify", "--verbose", final], capture_output=True, text=True, encoding="utf-8")
    (work / "signature-verification.txt").write_text(verify.stdout + verify.stderr, encoding="utf-8")
    audit = audit_apk(final, work, tools, blobs, manifest)
    # Verify mutable input files again; an in-progress rebuild must not be silently mixed.
    for item in list(origins.values()) + list(java_sources.values()) + list(fixture_sources.values()) + list(native_records.values()):
        if sha(Path(item["path"]).read_bytes()) != item["sha256"]:
            raise ValueError(f"Source input changed during probe build: {item['path']}")
    final_record = source_record(final)
    record = {**preparation, "status": "built and statically audited; Android execution pending",
              "apk": final_record, "nativeLibraries": native_records,
              "nativeDetails": native_details, "audit": audit,
              "sourceBuiltOverrides": sorted(OVERRIDES),
              "fullRuntimeSourceBuild": False, "gameplayValidated": False}
    write_json(OUTPUT / (final.stem + "-build-record.json"), record)
    (OUTPUT / (final.name + ".sha256")).write_text(final_record["sha256"] + "  " + final.name + "\n", encoding="ascii")
    print(f"Built isolated {final} ({final_record['bytes']} bytes), SHA256={final_record['sha256']}", flush=True)


if __name__ == "__main__":
    main()
