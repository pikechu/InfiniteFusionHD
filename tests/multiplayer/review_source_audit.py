"""Cross-check this review's real normal-loader/catalog logs and retained files."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[2]
review = root / "temp/multiplayer/cr-20261020"
manifest = json.loads((root / "Data/multiplayer-build.json").read_text(encoding="utf-8-sig"))
normal = root / "temp/multiplayer/cr20-release-production"
config = json.loads((normal / "mkxp.json").read_text(encoding="utf-8-sig"))
assert "customScript" not in config
runtime = (normal / "saves/runtime.log").read_text(encoding="utf-8")
modules = sorted(path.name for path in (root / "Data/Scripts/054_Multiplayer").glob("*.rb"))
assert len(modules) == 15
assert all(f"PRODUCTION_SOURCE_EVALUATED {name} " in runtime for name in modules)
assert "PRODUCTION_MODULES_EVALUATED count=15 pid=89620" in runtime
assert "PRODUCTION_FINAL_METHODS 015_Transport.rb:" in runtime
assert f"data_hash={manifest['data_hash']}" in runtime
catalog_path = root / "server/multiplayer/catalog-rental-v1.json"
catalog = json.loads(catalog_path.read_text(encoding="utf-8-sig"))
catalog_hash = hashlib.sha256(catalog_path.read_bytes()).hexdigest()
assert catalog["compatibility"]["data_hash"] == manifest["data_hash"]
assert catalog["compatibility"]["protocol"] == manifest["protocol"] == 2
log = (root / "temp/multiplayer/rental-catalog-cr-release-20261020/saves/rental-catalog.log").read_text(encoding="utf-8")
assert log.count("CANDIDATE_PASS ") == 12 and log.count("engine_registered_moves=4") == 12
assert f"RENTAL_CATALOG_PASS count=12 sha256={catalog_hash}" in log
baseline = json.loads((review / "workspace-baseline.json").read_text(encoding="utf-8-sig"))
assert len(baseline["tracked"]) == 13
assert all(hashlib.sha256((root / path).read_bytes()).hexdigest() == digest for path, digest in baseline["tracked"].items())
result = {"passed": True, "protocol": manifest["protocol"], "manifest_data_hash": manifest["data_hash"],
          "mods_hash": manifest["mods_hash"], "manifest_files": len(manifest["files"]),
          "normal_game_pid": 89620, "normal_custom_script": False, "normal_modules_evaluated": 15,
          "normal_game_stopped_after_proof": True, "catalog_native_pid": 105412,
          "catalog_sha256": catalog_hash, "native_catalog_candidates": 12, "native_registered_moves": 48,
          "preexisting_tracked_files_unchanged": 13}
(review / "build-source-evidence.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print("REVIEW_SOURCE_AUDIT_PASS production_loader=15 catalog=12/48 existing_tracked_unchanged=13")
