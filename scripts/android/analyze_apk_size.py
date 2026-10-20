"""Measure actual APK composition and lossless payload compression experiments.

This never changes an APK, game asset or build staging directory. Experiments are
written beneath an explicitly selected output directory, normally temp/size-audit.
"""
from collections import defaultdict
from pathlib import Path
import argparse
import hashlib
import json
import time
import zipfile


def bucket():
    return {"files": 0, "uncompressed": 0, "compressed": 0}


def add(group, key, item):
    value = group[key]
    value["files"] += 1
    value["uncompressed"] += item.file_size
    value["compressed"] += item.compress_size


def ordered(group):
    return dict(sorted(group.items(), key=lambda entry: entry[1]["uncompressed"], reverse=True))


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def analyze(apk_path, payload_path, manifest_path, output, levels):
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    report = {"apk": {"path": str(apk_path.resolve()), "bytes": apk_path.stat().st_size,
                       "sha256": digest(apk_path)},
              "payload": {"path": str(payload_path.resolve()), "bytes": payload_path.stat().st_size,
                           "sha256": digest(payload_path), "id": manifest["id"]},
              "experiments": []}
    with zipfile.ZipFile(apk_path) as archive:
        groups = defaultdict(bucket)
        for item in archive.infolist():
            add(groups, "payload ZIP" if item.filename == "assets/payload.zip" else
                "payload manifest" if item.filename == "assets/payload-manifest.json" else
                "native libraries" if item.filename.startswith("lib/") else "other shell", item)
        report["apk"]["groups"] = ordered(groups)
        packaged_payload = archive.getinfo("assets/payload.zip")
        report["apk"]["payloadStoredInApk"] = packaged_payload.compress_type == zipfile.ZIP_STORED
        report["apk"]["payloadBytesMatchStaging"] = packaged_payload.file_size == payload_path.stat().st_size
    with zipfile.ZipFile(payload_path) as archive:
        by_extension, by_top, by_graphics = defaultdict(bucket), defaultdict(bucket), defaultdict(bucket)
        for item in archive.infolist():
            add(by_extension, Path(item.filename).suffix.lower() or "(none)", item)
            add(by_top, item.filename.split("/", 1)[0], item)
            if item.filename.startswith("Graphics/"):
                add(by_graphics, "/".join(item.filename.split("/")[:2]), item)
        report["payload"]["byExtension"] = ordered(by_extension)
        report["payload"]["byDirectory"] = ordered(by_top)
        report["payload"]["byGraphicsDirectory"] = ordered(by_graphics)
        report["payload"]["files"] = len(archive.infolist())
        report["payload"]["uncompressed"] = sum(item.file_size for item in archive.infolist())
        duplicates = defaultdict(list)
        for name, item in manifest["files"].items():
            duplicates[(item["size"], item["sha256"])].append(name)
        duplicate_groups = [{"bytesEach": size, "sha256": sha, "copies": len(names),
                             "avoidableUncompressed": size * (len(names) - 1), "paths": names}
                            for (size, sha), names in duplicates.items() if len(names) > 1]
        duplicate_groups.sort(key=lambda item: item["avoidableUncompressed"], reverse=True)
        report["duplicates"] = {"groups": len(duplicate_groups),
                                "avoidableUncompressed": sum(item["avoidableUncompressed"] for item in duplicate_groups),
                                "topGroups": duplicate_groups[:30],
                                "note": "Manifest hashes identify candidates; every byte is checked during compression experiments."}
        for level in levels:
            started = time.perf_counter()
            destination = output / f"payload-all-deflate-{level}.zip"
            extension_results = defaultdict(lambda: {"files": 0, "uncompressed": 0, "before": 0, "after": 0,
                                                       "nonGrowingAfter": 0, "growingFiles": 0})
            # Build a real ZIP, not an estimate from concatenated zlib streams.
            with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=level) as trial:
                for index, item in enumerate(archive.infolist()):
                    data = archive.read(item)
                    expected = manifest["files"][item.filename]
                    if len(data) != expected["size"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
                        raise ValueError(f"Source payload does not match manifest: {item.filename}")
                    entry = zipfile.ZipInfo(item.filename, date_time=item.date_time)
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    entry.external_attr = item.external_attr
                    trial.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=level)
                    compressed = trial.getinfo(item.filename).compress_size
                    result = extension_results[Path(item.filename).suffix.lower() or "(none)"]
                    result["files"] += 1
                    result["uncompressed"] += item.file_size
                    result["before"] += item.compress_size
                    result["after"] += compressed
                    result["nonGrowingAfter"] += min(item.file_size, compressed)
                    result["growingFiles"] += int(compressed > item.file_size)
                    if index % 6000 == 0:
                        print(f"Deflate {level}: {index}/{report['payload']['files']}", flush=True)
            build_seconds = time.perf_counter() - started
            verification_started = time.perf_counter()
            with zipfile.ZipFile(destination) as trial:
                for item in trial.infolist():
                    if hashlib.sha256(trial.read(item)).hexdigest() != manifest["files"][item.filename]["sha256"]:
                        raise ValueError(f"Trial payload changed asset bytes: {item.filename}")
            experiment = {"strategy": "all-deflate", "level": level, "path": str(destination.resolve()),
                          "bytes": destination.stat().st_size, "sha256": digest(destination),
                          "savedBytes": payload_path.stat().st_size - destination.stat().st_size,
                          "buildSeconds": build_seconds, "verifySeconds": time.perf_counter() - verification_started,
                          "manifestSha256EveryEntryVerified": True,
                          "byExtension": dict(sorted(extension_results.items(), key=lambda pair: pair[1]["before"] - pair[1]["after"], reverse=True))}
            report["experiments"].append(experiment)
            (output / "size-report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
            print(f"Deflate {level}: {experiment['bytes']} bytes, saved {experiment['savedBytes']}, built in {build_seconds:.3f}s; all asset hashes match", flush=True)
    (output / "size-report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--levels", type=int, nargs="*", default=[6, 9])
    options = parser.parse_args()
    if any(level < 0 or level > 9 for level in options.levels):
        parser.error("ZIP deflate levels must be between 0 and 9")
    analyze(options.apk, options.payload, options.manifest, options.output, options.levels)
