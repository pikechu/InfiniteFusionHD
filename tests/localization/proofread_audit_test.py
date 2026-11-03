"""Coverage must come from explicit reviewed source keys, never row counts."""
from pathlib import Path
import importlib.util
import json
import tempfile

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location("audit",ROOT/"scripts/localization/audit_dex_proofread.py")
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
(ROOT/"temp/localization").mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(dir=ROOT/"temp/localization") as temporary:
    assert Path(temporary).resolve().is_relative_to((ROOT/"temp/localization").resolve())
    base=Path(temporary);audit.ROOT=base
    (base/"Data/pokedex").mkdir(parents=True)
    (base/"Data/localization/dex-proofread").mkdir(parents=True)
    def write(relative,value):(base/relative).write_text(json.dumps(value,ensure_ascii=False),encoding="utf-8")
    write("Data/pokedex/dex.json",[{"entry":"First."},{"entry":"POKENAME guards its nest."},{"entry":"First."}])
    write("Data/localization/zh-CN-dex-entry-overrides.json",{"First.":"第一条。"})
    write("Data/localization/zh-CN-dex-review-overrides.json",{})
    report=audit.audit()
    assert report["reviewed_records"]==2 and report["remaining_sources"]==1 and not report["complete"]
    try:audit.audit(True)
    except ValueError:pass
    else:raise AssertionError("Incomplete coverage passed as complete")
    write("Data/localization/dex-proofread/a.json",{"POKENAME guards its nest.":"POKENAME守护自己的巢。"})
    assert audit.audit(True)["complete"]
    write("Data/localization/dex-proofread/b.json",{"First.":"另一条。"})
    try:audit.audit()
    except ValueError:pass
    else:raise AssertionError("An overlapping shard passed")
    (base/"Data/localization/dex-proofread/b.json").unlink()
    write("Data/localization/dex-proofread/a.json",{"POKENAME guards its nest.":"它守护巢。"})
    try:audit.audit()
    except ValueError:pass
    else:raise AssertionError("A missing name placeholder passed")
print("PROOFREAD_AUDIT_PASS source_identity=true duplicate_assignments=rejected partial_is_not_complete=true")
