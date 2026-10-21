"""Package the source-built Android runtime in the isolated diagnostic shell.

No native compiler, prebuilt runtime selection, binary translator patch, device,
or AVD command is invoked. Final packaging requires an explicit completed core SHA.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
import build_native_probe as probe

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "temp/native-full-probe"
probe.OUTPUT = OUTPUT  # Reuse only fixture/safe staging/audit functions in this process.
NDK_REVISION = "25.2.9519653"
NDK_CXX_SHA256 = "33f661fc80c90913fe365a2bb6ee0bb7ed4c01b9c797fcecf1e60070e00019d6"
SYSTEM_LIBRARIES = {
    "libc.so", "libdl.so", "libm.so", "libz.so", "liblog.so", "libandroid.so",
    "libEGL.so", "libGLESv1_CM.so", "libGLESv2.so", "libGLESv3.so",
    "libOpenSLES.so", "libaaudio.so", "libvulkan.so", "libjnigraphics.so",
}
COMPONENT_RESULTS = {
    name: name + "-build-result.json" for name in (
        "SDL2", "SDL2_image", "SDL2_sound", "SDL2_ttf", "libogg", "libvorbis",
        "libpng", "freetype", "physfs", "openal", "openssl", "ruby", "pixman", "uchardet", "libiconv")
}
COMPONENT_RESULTS["libtheora"] = "libtheora-ResumeBuild-result.json"
JAVA_LOAD_ROOTS = ["SDL2", "mkxp-z"]


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tracked_bytes(source, commit, relative):
    return subprocess.check_output(["git", "-C", str(source), "show", commit + ":" + relative])


def source_commit(source, expected):
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != expected:
        raise ValueError(f"Source commit differs from component lock: {source}")
    dirty = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"], text=True).strip()
    if dirty:
        raise ValueError(f"Source checkout is not clean: {source}")


def elf_symbols(data):
    """ELF64 symbols with GNU version definitions and per-import provider names."""
    result = probe.elf(data)
    shoff = struct.unpack_from("<Q", data, 40)[0]
    shsize, shnum = struct.unpack_from("<HH", data, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shsize) for i in range(shnum)]
    versions, requirements, definitions = {}, {}, {}
    def strings(section):
        other = sections[section[6]]
        table = data[other[4]:other[4] + other[5]]
        def get(index):
            end = table.find(b"\0", index)
            if end < 0:
                raise ValueError("Unterminated GNU version string")
            return table[index:end].decode("utf-8")
        return get
    for section in sections:
        kind, offset, size = section[1], section[4], section[5]
        if kind == 0x6FFFFFFF:  # SHT_GNU_versym
            versions = {i: struct.unpack_from("<H", data, offset + i * 2)[0] for i in range(size // 2)}
        elif kind == 0x6FFFFFFD:  # SHT_GNU_verdef
            get, cursor = strings(section), offset
            while cursor < offset + size:
                version, flags, index, count, digest, aux, following = struct.unpack_from("<HHHHIII", data, cursor)
                name_offset = struct.unpack_from("<I", data, cursor + aux)[0]
                definitions[index & 0x7FFF] = get(name_offset)
                if not following:
                    break
                cursor += following
        elif kind == 0x6FFFFFFE:  # SHT_GNU_verneed
            get, cursor = strings(section), offset
            while cursor < offset + size:
                version, count, filename, aux, following = struct.unpack_from("<HHIII", data, cursor)
                provider = get(filename)
                item = cursor + aux
                for _ in range(count):
                    digest, flags, index, name, next_aux = struct.unpack_from("<IHHII", data, item)
                    requirements[index & 0x7FFF] = (get(name), provider)
                    if not next_aux:
                        break
                    item += next_aux
                if not following:
                    break
                cursor += following
    exports, strong, weak = {}, [], []
    for section in sections:
        if section[1] != 11:
            continue
        get = strings(section)
        for ordinal, entry in enumerate(range(section[4], section[4] + section[5], section[9])):
            name, info, other, index, value, length = struct.unpack_from("<IBBHQQ", data, entry)
            binding = info >> 4
            if not name or binding not in (1, 2) or (other & 3) not in (0, 3):
                continue
            version = versions.get(ordinal, 1)
            version_index, hidden = version & 0x7FFF, bool(version & 0x8000)
            symbol = get(name)
            if index:
                exports.setdefault(symbol, []).append((definitions.get(version_index) if version_index > 1 else None, not hidden))
            else:
                needed_version, provider = requirements.get(version_index, (None, None))
                if version_index > 1 and needed_version is None:
                    raise ValueError(f"Unknown GNU import version for {symbol}")
                (strong if binding == 1 else weak).append((symbol, needed_version, provider))
    result.update(exports=exports, strongImports=strong, weakImports=weak)
    return result


def artifact_entries(result):
    if "artifacts" in result:
        entries = result["artifacts"]
    elif "artifact" in result and "sha256" in result:
        entries = [{"path": result["artifact"], "sha256": result["sha256"]}]
    else:
        raise ValueError("Completed component result lacks artifact hashes")
    for entry in entries:
        name = entry.get("name") or Path(entry.get("path", entry.get("source", ""))).name
        if not re.fullmatch(r"lib[\w+.-]+\.so", name) or not re.fullmatch(r"[a-f0-9]{64}", entry.get("sha256", "")):
            raise ValueError("Invalid component artifact identity/hash")
        yield name, entry


def components(prefix, ndk):
    lock_path = ROOT / "scripts/android/windows-native-lock.json"
    core_lock_path = ROOT / "scripts/android/windows-native-core.lock.json"
    lock, core_lock = read_json(lock_path), read_json(core_lock_path)
    evidence = {str(p): probe.source_record(p) for p in (lock_path, core_lock_path)}
    declared, results = {}, {}
    for component, filename in COMPONENT_RESULTS.items():
        path = ROOT / "temp/windows-native" / filename
        value = read_json(path)
        if value.get("abi") != "arm64-v8a" or value.get("api") != 30 or value.get("compiled") is False:
            raise ValueError(f"Not a completed ARM64/API30 component result: {component}")
        if value.get("ndkRevision", NDK_REVISION) != NDK_REVISION:
            raise ValueError(f"Component NDK differs: {component}")
        if component == "libiconv":
            if value.get("archiveSha256") != core_lock["libiconv"]["sha256"] or value.get("version") != core_lock["libiconv"]["version"]:
                raise ValueError("libiconv result does not match the fixed source archive")
        elif component == "ruby":
            ruby_lock = lock["dependencies"]["ruby"]
            if value.get("sourceArchiveSha256") != ruby_lock["sha256"] or value.get("patchSha256") != ruby_lock["patchSha256"] or value.get("hostPatchSha256") != ruby_lock["hostPatch"]["sha256"]:
                raise ValueError("Ruby source/patch result differs from the dependency lock")
        elif value.get("sourceCommit") != lock["dependencies"][component]["commit"]:
            raise ValueError(f"Component commit differs from lock: {component}")
        for name, entry in artifact_entries(value):
            if name in declared:
                raise ValueError(f"Ambiguous component result for {name}")
            declared[name] = (entry["sha256"], component)
        results[component] = {"record": value, **probe.source_record(path)}
        evidence[str(path)] = probe.source_record(path)
    blobs, records, metadata = {}, {}, {}
    prefix_libraries = sorted((prefix / "lib").glob("*.so"))
    for path in prefix_libraries:
        data = path.read_bytes()
        digest = sha(data)
        alias = None
        if path.name == "libpng.so":
            alias = "libpng16.so"
        key = alias or path.name
        if key not in declared or declared[key][0] != digest:
            raise ValueError(f"Unrecorded/mismatched common-prefix library: {path.name}")
        item = elf_symbols(data)
        if item["soname"] != key or any(item["runpaths"]) or min(item["loadAlignments"]) < 16384:
            raise ValueError(f"Prefix library SONAME/RUNPATH/16 KiB gate failed: {path.name}")
        records[path.name] = {**probe.source_record(path, data), "component": declared[key][1],
                              "origin": "local-source-build", "identicalAliasOf": alias,
                              "elf": public_elf(item)}
        if alias is None:
            blobs[path.name], metadata[path.name] = data, item
    if set(declared) - set(records):
        raise ValueError(f"Recorded component libraries missing in prefix: {sorted(set(declared) - set(records))}")
    properties = (ndk / "source.properties").read_text(encoding="utf-8")
    if not re.search(r"Pkg.Revision\s*=\s*25\.2\.9519653\s*$", properties, re.M):
        raise ValueError("NDK runtime/stubs must be r25c")
    cxx = ndk / "toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
    data = cxx.read_bytes()
    if sha(data) != NDK_CXX_SHA256:
        raise ValueError("NDK r25c libc++_shared hash differs from fixed toolchain exception")
    item = elf_symbols(data)
    if item["soname"] != cxx.name or any(item["runpaths"]):
        raise ValueError("Unexpected NDK libc++ SONAME/search path")
    blobs[cxx.name], metadata[cxx.name] = data, item
    records[cxx.name] = {**probe.source_record(cxx, data), "component": "NDK-r25c-libc++",
                         "origin": "fixed-toolchain-runtime-exception-not-built-here", "elf": public_elf(item)}
    validation_path = ROOT / "temp/windows-native/ruby-module-validation.json"
    validation = read_json(validation_path)
    if validation.get("sha256") != records["libruby.so"]["sha256"] or validation.get("runtimeSearchPath") != "none":
        raise ValueError("Ruby module validation does not describe the selected no-RUNPATH build")
    evidence[str(validation_path)] = probe.source_record(validation_path)
    return blobs, records, metadata, results, evidence, lock, core_lock


def public_elf(item):
    return {key: item[key] for key in ("machine", "soname", "needed", "runpaths", "loadAlignments")}


def source_sdl_java(prefix, lock):
    source = ROOT / "temp/windows-native/sources/SDL2"
    commit = lock["dependencies"]["SDL2"]["commit"]
    source_commit(source, commit)
    java_root = source / "android-project/app/src/main/java/org/libsdl/app"
    result = {}
    for path in sorted(java_root.glob("*.java")):
        relative = path.relative_to(source).as_posix()
        data = path.read_bytes()
        blob = tracked_bytes(source, commit, relative)
        if data.replace(b"\r\n", b"\n") != blob.replace(b"\r\n", b"\n"):
            raise ValueError(f"Source SDL Java differs from fixed Git blob: {path.name}")
        result[path.name] = {**probe.source_record(path, data), "gitCommit": commit, "gitPath": relative,
                             "gitBlobSha256": sha(blob), "gitCheckoutLineEndingsOnly": data != blob,
                             "normalizedSha256": sha(data.replace(b"\r\n", b"\n"))}
    if len(result) != 9:
        raise ValueError("Expected exactly nine Java files from the fixed SDL2 source")
    header = source / "include/SDL_version.h"
    header_text = header.read_text(encoding="utf-8")
    activity = (java_root / "SDLActivity.java").read_text(encoding="utf-8")
    c_version = tuple(int(re.search(r"#define SDL_" + name + r"\s+(\d+)", header_text)[1]) for name in ("MAJOR_VERSION", "MINOR_VERSION", "PATCHLEVEL"))
    j_version = tuple(int(re.search(r"SDL_" + name + r"\s*=\s*(\d+)", activity)[1]) for name in ("MAJOR_VERSION", "MINOR_VERSION", "MICRO_VERSION"))
    if c_version != j_version or c_version != (2, 28, 1):
        raise ValueError("SDL source C/Java version mismatch")
    return result, {"commit": commit, "nativeComponent": "SDL2", "version": list(c_version), "javaFiles": 9,
                    "sourceCheckoutClean": True, "allJavaMatchesFixedGitBlobsIgnoringCRLF": True,
                    "preparedPrebuiltJavaUsed": False, "header": probe.source_record(header)}


def compile_shell(work, jdk, sdk, sdl):
    sources = list(sorted((probe.FIXTURE / "java").rglob("*.java")))
    sources.append(ROOT / "android/app/src/main/java/org/kuray/kif/NetworkBridge.java")
    sources += [Path(value["path"]) for value in sdl.values()]
    directory = work / "java"
    probe.reset_directory(directory)
    origins, staged, changes = {}, [], []
    for path in sources:
        data = path.read_bytes()
        origin = probe.source_record(path, data)
        package = "org/libsdl/app" if path.name in sdl else "org/kuray/kif"
        if path.name == "GameActivity.java":
            marker = b"public final class GameActivity extends SDLActivity {"
            if data.count(marker) != 1:
                raise ValueError("GameActivity fixture changed; cannot safely apply the explicit full-runtime load roots")
            method = ('\n    @Override protected String[] getLibraries() { return new String[] {'
                      + ', '.join('"' + name + '"' for name in JAVA_LOAD_ROOTS) + '}; }\n').encode()
            data = data.replace(marker, marker + method, 1)
            changes.append({"source": origin, "derivedSha256": sha(data), "change": "explicit SDL2 and source core load roots; no game Activity source edited"})
        dest = directory / package / path.name
        probe.create_output_directory(dest.parent)
        probe.safe_output(dest).write_bytes(data)
        origins[str(path)] = origin
        staged.append(dest)
    classes, dex = work / "classes", work / "dex"
    probe.reset_directory(classes)
    probe.reset_directory(dex)
    source_list = work / "sources.txt"
    probe.safe_output(source_list).write_text("\n".join('"' + p.as_posix() + '"' for p in staged), encoding="utf-8")
    tools, platform = sdk / "build-tools/35.0.0", sdk / "platforms/android-35/android.jar"
    probe.run_logged([jdk / "bin/javac.exe", "-J-Duser.language=en", "-encoding", "UTF-8", "--release", "8", "-classpath", platform, "-d", classes, "@" + str(source_list)], work / "javac.log")
    jar = probe.safe_output(work / "classes.jar")
    probe.run_logged([jdk / "bin/jar.exe", "cf", jar, "-C", classes, "."], work / "jar.log")
    probe.run_logged([jdk / "bin/java.exe", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "30", "--lib", platform, "--output", dex, jar], work / "d8.log")
    return origins, changes


def helper_library(blobs, records, metadata, evidence):
    path = ROOT / "temp/android-bridge-build/arm64-v8a-api30/libkif_android_bridge.so"
    provenance_path = path.parent / "provenance.json"
    provenance = read_json(provenance_path)
    source = ROOT / "android/native/kif_android_bridge.c"
    data = path.read_bytes()
    if sha(data) != provenance.get("outputSha256") or sha(source.read_bytes()) != provenance.get("sourceSha256") or provenance.get("inputBridge") is not True:
        raise ValueError("Existing source-built JNI helper provenance mismatch")
    item = elf_symbols(data)
    required = {"Java_org_kuray_kif_NetworkBridge_configure", "Java_org_kuray_kif_NetworkBridge_clearVirtualKeys",
                "Java_org_kuray_kif_NetworkBridge_setVirtualKey", "Init_libkif_android_bridge", "Init_kif_android_bridge"}
    if not required.issubset(item["exports"]) or item["soname"] != path.name or any(item["runpaths"]) or min(item["loadAlignments"]) < 16384:
        raise ValueError("JNI helper required exports/ELF gate failed")
    blobs[path.name], metadata[path.name] = data, item
    records[path.name] = {**probe.source_record(path, data), "origin": "existing-local-source-built-jni-helper", "elf": public_elf(item), "sourceSha256": provenance["sourceSha256"]}
    evidence[str(source)] = probe.source_record(source)
    evidence[str(provenance_path)] = probe.source_record(provenance_path)


def core_library(args, prefix, blobs, records, metadata, evidence, core_lock):
    path = args.core_result.resolve()
    result = read_json(path)
    if result.get("coreBuilt") is not True or result.get("runtimeCommit") != core_lock["runtime"]["commit"] or result.get("sourceClean") is not True:
        raise ValueError("Core result must describe the completed fixed clean-source build")
    if Path(result.get("prefix", "")).resolve() != prefix.resolve() or result.get("abi") != "arm64-v8a" or result.get("api") != 30:
        raise ValueError("Core result prefix/target differs from selected source components")
    core = Path(result["core"]["path"])
    if core.resolve() != (path.parent / "packaged/libmkxp-z.so").resolve() or result["core"]["sha256"] != args.core_sha256:
        raise ValueError("Core artifact result does not match explicit final core SHA/path")
    data = core.read_bytes()
    if sha(data) != args.core_sha256:
        raise ValueError("Final source core SHA mismatch")
    packaging = result.get("packaging", {})
    raw_path = Path(packaging.get("rawPath", ""))
    if raw_path.resolve() != (path.parent / "build/libmkxp-z.so").resolve() or packaging.get("packagedSha256") != args.core_sha256:
        raise ValueError("Core result lacks the separate raw/packaged artifact proof")
    raw = raw_path.read_bytes()
    if sha(raw) != packaging.get("rawSha256") or len(raw) != len(data) or packaging.get("codeAndAllNonDynamicBytesUnchanged") is not True:
        raise ValueError("Core raw bytes do not match the completed packaging proof")
    shoff = struct.unpack_from("<Q", raw, 40)[0]
    shsize, shnum = struct.unpack_from("<HH", raw, 58)
    dynamic = []
    for i in range(shnum):
        section = struct.unpack_from("<IIQQQQIIQQ", raw, shoff + i * shsize)
        if section[1] == 6:
            dynamic.append((section[4], section[5]))
    if dynamic != [(packaging.get("dynamicOffset"), packaging.get("dynamicBytes"))]:
        raise ValueError("Core packaging dynamic span is not the actual ELF .dynamic section")
    offset, size = dynamic[0]
    if raw[:offset] != data[:offset] or raw[offset + size:] != data[offset + size:]:
        raise ValueError("Core packaging altered bytes outside .dynamic")
    depfixer = ROOT / "temp/core-tools/meson-1.9.1/mesonbuild/scripts/depfixer.py"
    if Path(packaging.get("depfixerPath", "")).resolve() != depfixer.resolve() or sha(depfixer.read_bytes()) != packaging.get("depfixerSha256") or packaging.get("depfixerSha256") != "4b48f133b31c6119ad9a26d1c735ae23b279b5d2024d0f23795d4e5d93b37513":
        raise ValueError("Core RPATH cleanup was not the fixed official Meson depfixer")
    raw_elf, packaged_elf = probe.elf(raw), probe.elf(data)
    if any(raw_elf[key] != packaged_elf[key] for key in ("soname", "needed", "loadAlignments")):
        raise ValueError("Core RPATH cleanup changed SONAME, dependencies or load alignment")
    evidence[str(raw_path)] = probe.source_record(raw_path, raw)
    evidence[str(depfixer)] = probe.source_record(depfixer)
    for name, expected in result["nativeInputSha256"].items():
        if name not in records or records[name]["sha256"] != expected:
            raise ValueError(f"Source component differs from actual core link inputs: {name}")
    for relative, expected in result["inputSources"].items():
        source = ROOT / relative
        if sha(source.read_bytes()) != expected:
            raise ValueError(f"Core builder input changed since core build: {relative}")
        evidence[str(source)] = probe.source_record(source)
    for name, expected in result["pkgConfigSha256"].items():
        pc = prefix / "lib/pkgconfig" / name
        if sha(pc.read_bytes()) != expected:
            raise ValueError(f"Core pkg-config input changed: {name}")
        evidence[str(pc)] = probe.source_record(pc)
    source_commit(Path(result["source"]), result["runtimeCommit"])
    item = elf_symbols(data)
    if item["soname"] != "libmkxp-z.so" or any(item["runpaths"]) or min(item["loadAlignments"]) < 16384 or "SDL_main" not in item["exports"]:
        raise ValueError("Source core SONAME/RUNPATH/16 KiB/entrypoint gate failed")
    blobs[core.name], metadata[core.name] = data, item
    records[core.name] = {**probe.source_record(core, data), "origin": "completed-local-source-core-build", "elf": public_elf(item),
                          "emulatorBinaryPatchApplied": False, "standardPostLinkRpathCleanup": packaging}
    evidence[str(path)] = probe.source_record(path)
    return result


def dependency_closure(blobs, metadata, ndk, roots):
    """Resolve only actual DT_NEEDED providers, then check versioned strong imports."""
    selected, system = set(), {}
    stub_root = ndk / "toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/aarch64-linux-android/30"
    pending = list(roots)
    while pending:
        name = pending.pop()
        if name in selected or name in system:
            continue
        if name in blobs:
            selected.add(name)
            item = metadata[name]
        elif name in SYSTEM_LIBRARIES:
            path = stub_root / name
            data = path.read_bytes()
            item = elf_symbols(data)
            if item["soname"] != name:
                raise ValueError(f"API30 system stub SONAME mismatch: {name}")
            system[name] = {**probe.source_record(path, data), "elf": item}
        else:
            raise ValueError(f"Unpackaged or non-whitelisted DT_NEEDED: {name}")
        pending.extend(item["needed"])
    all_meta = {name: metadata[name] for name in selected}
    all_meta.update({name: value["elf"] for name, value in system.items()})
    checks, missing = {}, []
    for name in sorted(selected):
        reachable, queue = set(), [name]
        while queue:
            other = queue.pop()
            if other not in reachable:
                reachable.add(other)
                queue.extend(all_meta[other]["needed"])
        resolved = []
        for symbol, version, provider in all_meta[name]["strongImports"]:
            found = []
            for candidate in sorted(reachable):
                if provider is not None and candidate != provider:
                    continue
                for exported_version, default in all_meta[candidate]["exports"].get(symbol, []):
                    if (version is None and (exported_version is None or default)) or version == exported_version:
                        found.append(candidate)
                        break
            if not found:
                missing.append({"consumer": name, "symbol": symbol, "version": version, "provider": provider})
            else:
                resolved.append({"symbol": symbol, "version": version, "requestedProvider": provider, "providers": found})
        checks[name] = {"reachableProviders": sorted(reachable), "strongImports": len(all_meta[name]["strongImports"]),
                        "weakImportsNotRequired": len(all_meta[name]["weakImports"]), "resolved": resolved}
    if missing:
        probe.write_json(OUTPUT / "unresolved-strong-imports.json", missing)
        raise ValueError(f"Unresolved/version-mismatched strong imports ({len(missing)}); see temp/native-full-probe/unresolved-strong-imports.json")
    system_records = {name: {key: value for key, value in record.items() if key != "elf"} for name, record in system.items()}
    return selected, {"roots": roots, "packagedLibraries": sorted(selected), "systemProviders": system_records,
                      "strongImportChecks": checks, "missingStrongImports": [], "gnuSymbolVersionsChecked": True,
                      "allSysrootExportsWereNotUsedAsFallback": True}


def prepare_payload(work, prefix, font, full_metadata):
    manifest, origins = probe.payload(work, prefix, font)
    # Replace only the copied diagnostic metadata. Committed fixtures remain untouched.
    path = probe.safe_output(work / "assets/probe-payload.zip")
    with zipfile.ZipFile(path) as archive:
        content = {name: archive.read(name) for name in archive.namelist()}
    changes = []
    if full_metadata:
        name = "native-ruby-probe.rb"
        before = content[name]
        marker = b'"fullRuntimeSourceBuild" => false'
        if before.count(marker) != 1:
            raise ValueError("Diagnostic fullRuntimeSourceBuild marker changed")
        content[name] = before.replace(marker,
            b'"fullRuntimeSourceBuild" => true, "allNonToolchainLibrariesSourceBuilt" => true, '
            b'"toolchainRuntimeException" => "NDK r25c libc++_shared.so", '
            b'"wholeApk16KiBCompatible" => false, "runtimeVariant" => "full-source", "emulatorBinaryPatch" => false', 1)
        changes.append({"entry": name, "originalSha256": sha(before), "derivedSha256": sha(content[name]),
                        "change": "diagnostic runtime provenance only; committed fixture untouched"})
    # Use the COPYING from the exact dedicated core source rather than a prebuilt extraction.
    license_path = ROOT / "temp/windows-native/sources/mkxp-z/COPYING"
    content["LICENSES/mkxp-z-COPYING.txt"] = license_path.read_bytes()
    origins["LICENSES/mkxp-z-COPYING.txt"] = probe.source_record(license_path)
    with zipfile.ZipFile(probe.safe_output(path), "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        files = {}
        for name, data in sorted(content.items()):
            item = zipfile.ZipInfo(name, date_time=(2026, 10, 20, 0, 0, 0))
            item.external_attr = 0o100644 << 16
            archive.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
            files[name] = {"size": len(data), "sha256": sha(data)}
    manifest["files"] = files
    manifest["id"] = sha(json.dumps(files, sort_keys=True, separators=(",", ":")).encode())[:24]
    manifest["runtimeVariant"] = "full-source" if full_metadata else "preparation-metadata-pending"
    probe.write_json(work / "assets/probe-manifest.json", manifest)
    return manifest, origins, changes


def add_component_licenses(work, selected, records, results, manifest, origins, ndk):
    source_root = ROOT / "temp/windows-native/sources"
    locations = {
        "SDL2": source_root / "SDL2/LICENSE.txt", "SDL2_image": source_root / "SDL2_image/LICENSE.txt",
        "SDL2_sound": source_root / "SDL2_sound/LICENSE.txt", "SDL2_ttf": source_root / "SDL2_ttf/LICENSE.txt",
        "libogg": source_root / "libogg/COPYING", "libvorbis": source_root / "libvorbis/COPYING",
        "libpng": source_root / "libpng/LICENSE", "pixman": source_root / "pixman/COPYING",
        "uchardet": source_root / "uchardet/COPYING", "libtheora": source_root / "libtheora/COPYING",
        "freetype": ROOT / "temp/windows-native-freetype/sources/freetype/docs/FTL.TXT",
        "physfs": ROOT / "temp/windows-native-physfs/sources/physfs/LICENSE.txt",
        "openal": ROOT / "temp/windows-native-openal/source/COPYING",
        "libiconv": Path(results["libiconv"]["record"]["run"]) / "source/libiconv-1.18/COPYING.LIB",
    }
    components_used = {records[name].get("component") for name in selected}
    additions = {}
    for component in sorted(components_used & locations.keys()):
        path = locations[component]
        if not path.is_file():
            raise ValueError(f"Selected component license input missing: {component}: {path}")
        name = "LICENSES/source-" + component + "-" + path.name + ".txt"
        additions[name] = path
    cxx_license = ndk / "sources/cxx-stl/llvm-libc++/LICENSE.TXT"
    if cxx_license.is_file():
        additions["LICENSES/NDK-r25c-libcxx-LICENSE.txt"] = cxx_license
    with zipfile.ZipFile(probe.safe_output(work / "assets/probe-payload.zip"), "a", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, path in sorted(additions.items()):
            data = path.read_bytes()
            if name in manifest["files"]:
                raise ValueError("Duplicate source license entry")
            item = zipfile.ZipInfo(name, date_time=(2026, 10, 20, 0, 0, 0))
            item.external_attr = 0o100644 << 16
            archive.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
            manifest["files"][name] = {"size": len(data), "sha256": sha(data)}
            origins[name] = probe.source_record(path, data)
    manifest["id"] = sha(json.dumps(manifest["files"], sort_keys=True, separators=(",", ":")).encode())[:24]
    probe.write_json(work / "assets/probe-manifest.json", manifest)
    return {"selectedSourceComponentLicenseFiles": sorted(additions), "originalFixtureChanged": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--core-sha256", help="Explicit final completed source core digest")
    parser.add_argument("--full-runtime-metadata", action="store_true", help="Use the coordinated full-source diagnostic metadata in a temporary payload copy")
    parser.add_argument("--core-result", type=Path, default=ROOT / "temp/windows-native-core/build-result.json")
    parser.add_argument("--prefix", type=Path, default=ROOT / "temp/windows-native/prefix/arm64-v8a")
    parser.add_argument("--ndk", type=Path, default=ROOT / "temp/tools/android-ndk-r25c")
    parser.add_argument("--jdk", type=Path)
    parser.add_argument("--sdk", type=Path, default=ROOT / "temp/tools/android-sdk")
    parser.add_argument("--font", type=Path)
    args = parser.parse_args()
    probe.OUTPUT = OUTPUT
    probe.validate_output_root(scan_tree=True)
    if not args.prepare_only and not re.fullmatch(r"[a-f0-9]{64}", args.core_sha256 or ""):
        parser.error("Final packaging requires --core-sha256 from the completed core build")
    if not args.prepare_only and not args.full_runtime_metadata:
        parser.error("Final full-source diagnostic requires explicit --full-runtime-metadata")
    work = OUTPUT / "build"
    probe.create_output_directory(work)
    isolation = probe.manifest_safety()
    jdk = args.jdk or next((ROOT / "temp/tools").glob("jdk-17*"), None)
    if jdk is None or not (jdk / "bin/javac.exe").is_file():
        parser.error("Existing portable JDK17 required")
    font = args.font or ROOT / "Fonts/power green.ttf"
    if args.font is None and not font.is_file():
        font = ROOT.parent.parent / "Fonts/power green.ttf"
    if not font.is_file() or sha(font.read_bytes()) != probe.DEFAULT_FONT_SHA256:
        parser.error("Fixed Power Green font required")
    blobs, records, metadata, results, evidence, lock, core_lock = components(args.prefix, args.ndk)
    helper_library(blobs, records, metadata, evidence)
    sdl, sdl_pairing = source_sdl_java(args.prefix, lock)
    manifest, origins, payload_changes = prepare_payload(work, args.prefix, font, args.full_runtime_metadata)
    print("Compiling isolated fixture against the exact source-built SDL2 Java", flush=True)
    java_sources, java_changes = compile_shell(work, jdk, args.sdk, sdl)
    preparation = {"status": "prepared; final core selection and APK packaging pending", "isolation": isolation,
                   "componentResults": results, "allCommonPrefixLibraries": records, "sdlJavaPairing": sdl_pairing,
                   "sdlJavaSources": sdl, "javaSources": java_sources, "javaTransformations": java_changes,
                   "payload": manifest, "payloadOrigins": origins, "payloadTransformations": payload_changes,
                   "builder": probe.source_record(Path(__file__)), "sharedFixtureBuilder": probe.source_record(Path(probe.__file__)),
                   "nativeCompilerInvoked": False, "deviceCommandsInvoked": False, "deviceExecuted": False,
                   "prebuiltRuntimeLibrariesUsed": False, "emulatorBinaryPatchApplied": False}
    probe.write_json(work / "preparation.json", preparation)
    if args.prepare_only:
        print(f"Prepared full-source probe shell; {len(records)} verified prefix/toolchain/helper libraries; no core selected or APK emitted", flush=True)
        return
    core_result = core_library(args, args.prefix, blobs, records, metadata, evidence, core_lock)
    roots = ["lib" + name + ".so" for name in JAVA_LOAD_ROOTS] + ["libkif_android_bridge.so"]
    selected, closure = dependency_closure(blobs, metadata, args.ndk, roots)
    licenses = add_component_licenses(work, selected, records, results, manifest, origins, args.ndk)
    selected_blobs = {name: blobs[name] for name in sorted(selected)}
    for item in closure["systemProviders"].values():
        evidence[item["path"]] = item
    tools, platform = args.sdk / "build-tools/35.0.0", args.sdk / "platforms/android-35/android.jar"
    unsigned, aligned = probe.safe_output(work / "probe-unsigned.apk"), probe.safe_output(work / "probe-aligned.apk")
    probe.run([tools / "aapt2.exe", "link", "-I", platform, "--manifest", probe.FIXTURE / "AndroidManifest.xml", "-A", work / "assets", "-0", "zip", "-o", unsigned])
    with zipfile.ZipFile(probe.safe_output(unsigned), "a", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.write(work / "dex/classes.dex", "classes.dex")
        for name, data in sorted(selected_blobs.items()):
            entry = zipfile.ZipInfo("lib/arm64-v8a/" + name, date_time=(2026, 10, 20, 0, 0, 0))
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
    probe.run([tools / "zipalign.exe", "-f", "-p", "4", unsigned, aligned])
    key = ROOT / "temp/android-signing/kif-debug.keystore"
    if not key.is_file():
        raise ValueError("Existing local test signing key required; no key is generated")
    final = probe.safe_output(OUTPUT / "Native-Full-Runtime-Probe-arm64-test.apk")
    signer = [jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar"]
    env = dict(os.environ, KIF_TEST_KEY_PASSWORD="android")
    probe.run(signer + ["sign", "--ks", key, "--ks-key-alias", "androiddebugkey", "--ks-pass", "env:KIF_TEST_KEY_PASSWORD", "--key-pass", "env:KIF_TEST_KEY_PASSWORD", "--out", final, aligned], env=env)
    probe.run_logged(signer + ["verify", "--verbose", final], work / "signature-verification.txt")
    audit = probe.audit_apk(final, work, tools, selected_blobs, manifest)
    for item in list(origins.values()) + list(java_sources.values()) + list(records.values()) + list(evidence.values()):
        if sha(Path(item["path"]).read_bytes()) != item["sha256"]:
            raise ValueError(f"Build input changed during packaging: {item['path']}")
    cxx_record = records["libc++_shared.so"]
    blockers_16k = {name: item["elf"]["loadAlignments"] for name, item in records.items() if name in selected and min(item["elf"]["loadAlignments"]) < 16384}
    result = {**preparation, "status": "built and statically audited; Android execution pending",
              "apk": probe.source_record(final), "coreBuildResult": core_result, "closure": closure,
              "packagedNativeLibraries": {name: records[name] for name in sorted(selected)},
              "omittedUnusedPrefixLibraries": sorted(set(records) - selected), "audit": audit,
              "runtimeCoreAndNonToolchainDependenciesBuiltFromSource": True,
              "toolchainRuntimeException": cxx_record, "overall16KiBCompatible": not blockers_16k,
              "alignment16KiBBlockers": blockers_16k, "sourceLicenses": licenses,
              "gameplayValidated": False, "installed": False}
    probe.write_json(OUTPUT / (final.stem + "-build-record.json"), result)
    probe.safe_output(OUTPUT / (final.name + ".sha256")).write_text(result["apk"]["sha256"] + "  " + final.name + "\n", encoding="ascii")
    print(f"Built {final} ({result['apk']['bytes']} bytes), SHA256={result['apk']['sha256']}; overall16KiBCompatible={result['overall16KiBCompatible']}", flush=True)


if __name__ == "__main__":
    main()
