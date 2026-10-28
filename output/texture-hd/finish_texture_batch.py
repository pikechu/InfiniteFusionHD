"""Record a verified image batch after native engine evidence has been produced."""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "scripts/graphics"))
from texture_batch import install_or_verify

number = int(sys.argv[1])
batch_id = f"batch-{number:03}"
batch = OUT / batch_id
install_or_verify(batch, "verify")
manifest = json.loads((batch / "manifest.json").read_text())
plan_path = OUT / "execution-plan/plan.json"
plan = json.loads(plan_path.read_text(encoding="utf-8"))
record_path = OUT / "execution-plan/batches" / (batch_id + ".json")
record = json.loads(record_path.read_text(encoding="utf-8"))
assert {e["source"] for e in record["entries"]} == {e["source"] for e in manifest["entries"]}
statuses = {row["id"]: row["status"] for row in plan["batch_index"]}
assert all(statuses[dep] == "completed" for dep in record["depends_on"])
native = (OUT / "engine-check/result.txt").read_text()
match = re.search(r"TEXTURE_ENGINE_PASS images=(\d+) renders=(\d+)", native)
assert match, native
all_entries = [e for p in OUT.glob("batch-*/manifest.json") for e in json.loads(p.read_text())["entries"]]
assert int(match[1]) == len(all_entries), "Native evidence does not cover the current applied batches"
for entry in all_entries:
    assert hashlib.sha256((ROOT / entry["source"]).read_bytes()).hexdigest() == entry["after_sha256"]
receipt = {"status": "completed", "batch": batch_id, "applied": len(manifest["entries"]),
           "dimensions_unchanged": True, "alpha_unchanged": True, "native_result": native.strip(),
           "validation_scope": "image decoding and native background/ground scene composition; not full battle gameplay"}
(batch / "validation.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
record["status"] = "completed"
record["result"] = str((batch / "validation.json").relative_to(ROOT)).replace("\\", "/")
record_path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
for row in plan["batch_index"]:
    if row["id"] == batch_id:
        row["status"] = "completed"
        row["result"] = record["result"]
plan["status"] = "in_progress"
plan["next_batch"] = next((r["id"] for r in plan["batch_index"] if r["status"] != "completed"), None)
plan_path.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
inventory_path = OUT / "inventory.json"
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
applied = {e["source"] for e in all_entries}
for entry in inventory["assets"]:
    if entry["path"] in applied:
        entry["status"] = "applied"
inventory["applied"] = sum(e["status"] == "applied" for e in inventory["assets"])
inventory["preserved"] = sum(e["status"] == "preserved" for e in inventory["assets"])
inventory["pending"] = sum(e["status"] == "pending" for e in inventory["assets"])
inventory_path.write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
index_path = OUT / "execution-plan/batch-index.zh-CN.md"
lines = index_path.read_text(encoding="utf-8").splitlines()
lines = [line.replace("待执行", "已完成") if f"batches/{batch_id}.json" in line else line for line in lines]
index_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
p1 = [row for row in plan["batch_index"] if row["priority"] == "P1"]
progress = {"authorized_scope": "P1 batches 005-057", "status": "in_progress",
            "total_files": sum(r["file_count"] for r in p1), "completed_batches": [r["id"] for r in p1 if r["status"] == "completed"],
            "completed_files": sum(r["file_count"] for r in p1 if r["status"] == "completed"), "next_batch": plan["next_batch"]}
(OUT / "p1-progress.json").write_text(json.dumps(progress, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(progress))
