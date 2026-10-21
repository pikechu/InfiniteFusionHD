"""Copy only synthetic test logs/screenshots, never profile credentials or saves."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "docs/multiplayer-evidence/2026-10-16"


def copy(source, relative, manifest):
    if not source.is_file():
        return
    target = OUTPUT / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    manifest[relative] = {"sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "bytes": target.stat().st_size}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="append", required=True)
    args = parser.parse_args()
    manifest = {}
    for run in args.run:
        if not re.fullmatch(r"\d{8}-\d{6}", run):
            raise SystemExit("Invalid test run ID")
        for role in ("host", "guest"):
            source = ROOT / f"temp/multiplayer/verify-{role}-{run}/saves"
            copy(source / "game-smoke.log", f"{run}/{role}.log", manifest)
            for picture in sorted(source.glob("match-*-state-*.png")):
                copy(picture, f"{run}/{role}-{picture.name}", manifest)
        copy(ROOT / f"temp/multiplayer/verify-evidence-{run}.json", f"{run}/consistency.json", manifest)
        copy(ROOT / f"temp/multiplayer/restart-{run}-service-error.log", f"{run}/service-before-restart.log", manifest)
        copy(ROOT / f"temp/multiplayer/restart-{run}-service-error.log.restarted", f"{run}/service-after-restart.log", manifest)
    for source, target in (
        ("temp/multiplayer/runtime-probe/saves/runtime.log", "runtime-probe.log"),
        ("temp/multiplayer/production-load-check/saves/runtime.log", "production-loader.log"),
        ("temp/multiplayer/client-unit-native/saves/client-test.log", "client-native.log"),
        ("server/multiplayer/data/test-run-accepted.log", "service-tests.log"),
        ("Data/multiplayer-build.json", "final-build.json"),
    ):
        copy(ROOT / source, target, manifest)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    battle_log = OUTPUT / "battle-tests.log"
    if battle_log.is_file():
        manifest["battle-tests.log"] = {"sha256": hashlib.sha256(battle_log.read_bytes()).hexdigest(), "bytes": battle_log.stat().st_size}
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"EVIDENCE_SAVED files={len(manifest)} directory={OUTPUT}")
