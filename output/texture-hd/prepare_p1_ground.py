"""Prepare one frozen P1 ground batch from generated jobs and audited duplicates."""
import json
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "scripts/graphics"))
from texture_batch import prepare

number = int(sys.argv[1])
assert 5 <= number <= 11
audit = json.loads((OUT / "p1-audit.json").read_text(encoding="utf-8"))
plan = json.loads((OUT / "execution-plan/batches" / f"batch-{number:03}.json").read_text(encoding="utf-8"))
sources = {row["source"]: row for row in audit["sources"]}
jobs = {row["source"]: row["reuse_job"] for row in audit["ground_reuse"]}
generated = {job["source"]: job for path in (OUT / "p1-generated").glob("*.json") for job in [json.loads(path.read_text(encoding="utf-8"))]}
for group in audit["ground_groups"]:
    representative = group[0]["source"]
    if representative in generated:
        for row in group:
            jobs[row["source"]] = {**generated[representative], "identical_pixels_source": representative}
entries = []
for entry in plan["entries"]:
    source = entry["source"]
    assert hashlib.sha256((ROOT / source).read_bytes()).hexdigest() == sources[source]["sha256"], source
    assert source in jobs, "Generation missing: " + source
    entries.append({**jobs[source], "source": source, "audited_source_sha256": sources[source]["sha256"]})
batch = OUT / plan["id"]
batch.mkdir(exist_ok=True)
jobfile = {"batch": f"{number:03}", "method": "built-in image_gen with pixel-identical reuse", "entries": entries}
(batch / "jobs.json").write_text(json.dumps(jobfile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
prepare(batch, jobfile)
