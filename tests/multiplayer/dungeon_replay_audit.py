"""Audit a completed full native dungeon/replay run; open its database read-only."""
from pathlib import Path
import argparse
import hashlib
import json
import sqlite3

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("evidence", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
evidence = json.loads(args.evidence.read_text(encoding="utf-8-sig"))
assert evidence["overall_pass"] and not evidence["fault_only"]
assert {entry["role"] for entry in evidence["client_processes"]} == {"host", "guest", "viewer"}
assert all(entry["exit_code"] == 0 for entry in evidence["client_processes"])
clients = evidence["clients"]
assert len({entry["player_id"] for entry in clients}) == 3
for entry in clients:
    assert entry["stage"] == "finished" and entry["actual_scene"] == "Scene_Map"
    assert entry["manual_replay_windows"] and all(count == 0 for count in entry["world_callbacks"].values())
    assert entry["original_digest"] == entry["final_digest"]
    assert hashlib.sha256(Path(entry["original_save_path"]).read_bytes()).hexdigest() == entry["original_save_sha256"]
database = Path(evidence["database"]).resolve()
with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as db:
    assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    battles = [json.loads(row[0]) for row in db.execute("SELECT document FROM battles")]
    routes = [json.loads(row[0]) for row in db.execute("SELECT document FROM dungeons")]
    rewards = db.execute("SELECT owner,scope FROM rewards").fetchall()
    replays = [json.loads(row[0]) for row in db.execute("SELECT document FROM replays")]
assert len(battles) == 5 and len({entry["id"] for entry in battles}) == 5
assert all(entry["status"] == "finished" and not entry["result"]["abnormal"] and entry["result"]["coop_outcome"] == "victory" for entry in battles)
assert len({entry["result"]["id"] for entry in battles}) == 5
assert len(routes) == 2 and sorted(entry["status"] for entry in routes) == ["abandoned", "completed"]
completed = next(entry for entry in routes if entry["status"] == "completed")
abandoned = next(entry for entry in routes if entry["status"] == "abandoned")
assert completed["node_index"] == 5 and abandoned["node_index"] == 1
assert not abandoned["retry_used"]
assert len(rewards) == 2 and len(set(rewards)) == 2 and len({owner for owner, _ in rewards}) == 2
assert len(replays) == 1 and replays[0]["status"] == "private"
summary = {"passed": True, "readonly_audit": True, "run_id": evidence["run_id"],
           "manifest_data_hash": evidence["manifest_data_hash"], "battle_count": 5,
           "unique_results": 5, "victories": 5, "reward_rows": 2,
           "route_statuses": [entry["status"] for entry in routes], "revoked_replays": 1,
           "native_checks": sum(entry["checks"] for entry in clients),
           "original_disk_and_global_digests_unchanged": True,
           "overworld_callbacks": 0, "all_native_exit_codes": [0, 0, 0]}
args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("DUNGEON_REPLAY_DB_AUDIT_PASS battles=5 results=5 victories=5 rewards=2 original_saves=unchanged")
