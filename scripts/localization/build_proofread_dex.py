"""Build the fully reviewed community dex without a model, network or temp cache."""
from pathlib import Path
import hashlib
import json
from audit_dex_proofread import audit, read

ROOT=Path(__file__).resolve().parents[2]

def build(root=ROOT):
    root=Path(root)
    coverage=audit(complete=True,root=root)
    reviewed={}
    for name in ["zh-CN-dex-entry-overrides.json","zh-CN-dex-review-overrides.json"]:
        reviewed.update(read(root/"Data/localization"/name))
    for path in sorted((root/"Data/localization/dex-proofread").glob("*.json")):
        reviewed.update(read(path))
    source=root/"Data/pokedex/dex.json"
    records=read(source)
    # Upstream can add text outside the pinned review scope. Reuse only exact
    # reviewed prose, retaining every sprite/author identity in the current dex.
    rows=[{**row,"source":row["entry"],"entry":reviewed[row["entry"]].strip()} for row in records if row["entry"] in reviewed]
    body=json.dumps(rows,ensure_ascii=False,separators=(",",":"))
    if len(body.encode("utf-8"))>8*1024*1024:
        raise ValueError("Reviewed dex exceeds native parser size limit")
    target=root/"Data/pokedex/dex_zh.json"
    pending=target.with_suffix(".json.pending")
    pending.write_text(body,encoding="utf-8")
    pending.replace(target)
    digest=hashlib.sha256(target.read_bytes()).hexdigest()
    print(f"PROOFREAD_BUILD_PASS records={len(rows)} sources={coverage['reviewed_sources']} sha256={digest}")
    return rows

if __name__=="__main__":build()
