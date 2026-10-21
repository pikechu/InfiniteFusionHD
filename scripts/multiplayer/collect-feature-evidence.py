"""Archive explicit synthetic evidence only; never profiles, databases or saves."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
PRIVATE_KEYS = {"token", "recovery_code", "recovery_hash", "token_hash", "authorization", "authority_id"}
ALLOWED_LOGS = {
    "runtime.log", "client-test.log", "transport-test.log", "feature-smoke.log",
    "pool-collections-native.log", "cards-native.log", "hall-native.log",
    "rental-native.log", "rental-game.log", "hall-game.log", "cards-game.log", "native-guest.log", "boss-disconnect.log",
    "http-gvl-probe.log", "rental-catalog.log", "game-smoke.log",
    "final-unit-tests-20261016.log",
    "final-board-replay-regression.log",
    "native-full-release.log", "native-full-final.log", "ruby-all-release.log", "ruby-all-release-retest.log",
    "server-cr-20261020-current148.log", "pixman-bitmap.log",
    "identity-recovery-test.log", "scene-after-menu-fix.log", "hall-invite-after-fix.log",
}


def check_json(value):
    if isinstance(value, dict):
        if any(str(key).lower() in PRIVATE_KEYS for key in value):
            raise ValueError("Evidence contains a private credential field")
        for child in value.values():
            check_json(child)
    elif isinstance(value, list):
        for child in value:
            check_json(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="docs/multiplayer-evidence/2026-10-16-all-features")
    parser.add_argument("--file", action="append", required=True, help="Explicit repo-relative test evidence file")
    args = parser.parse_args()
    output = (ROOT / args.output).resolve()
    if not output.is_relative_to((ROOT / "docs/multiplayer-evidence").resolve()):
        raise SystemExit("Output must remain inside docs/multiplayer-evidence")
    manifest = {}
    prepared = []
    for supplied in args.file:
        source = (ROOT / supplied).resolve()
        if not source.is_relative_to(ROOT):
            raise SystemExit("Evidence source must remain in this checkout")
        relative = source.relative_to(ROOT)
        if str(relative).replace("\\", "/").startswith("temp/multiplayer/"):
            if source.suffix == ".json":
                if not ("evidence" in source.name or source.name in ("native-guest-baseline.json", "cross-platform-audit.json")):
                    raise SystemExit("Only explicitly named evidence JSON may be archived")
            elif source.suffix == ".log":
                if source.name not in ALLOWED_LOGS:
                    raise SystemExit("Log file is not on the synthetic evidence allowlist")
            elif source.suffix.lower() != ".png":
                raise SystemExit("Only test JSON, allowlisted logs and PNGs may be archived")
        elif relative != Path("Data/multiplayer-build.json"):
            raise SystemExit("Only multiplayer test evidence or the build manifest is allowed")
        data = source.read_bytes()
        if source.suffix == ".json":
            check_json(json.loads(data.decode("utf-8-sig")))
        elif source.suffix == ".log" and re.search(rb'(?i)(?:"(?:token|recovery_code|authorization|authority_id)"\s*:|Authorization:\s*Bearer\s+)', data):
            raise SystemExit("Log may contain credentials; refusing to archive")
        prepared.append((source, relative, data))
    output.mkdir(parents=True, exist_ok=True)
    for source, relative, data in prepared:
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        manifest[relative.as_posix()] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"FEATURE_EVIDENCE_SAVED files={len(manifest)} directory={output}")


if __name__ == "__main__":
    main()
