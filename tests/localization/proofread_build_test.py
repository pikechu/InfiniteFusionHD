from pathlib import Path
import json
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"scripts/localization"))
from build_proofread_dex import build

(ROOT/"temp/localization").mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(dir=ROOT/"temp/localization") as temporary:
    assert Path(temporary).resolve().is_relative_to((ROOT/"temp/localization").resolve())
    root=Path(temporary)
    (root/"Data/pokedex").mkdir(parents=True)
    (root/"Data/localization/dex-proofread").mkdir(parents=True)
    source=[{"sprite":"1.1.png","entry":"First text.","author":"A"},
            {"sprite":"1.1.png","entry":"Second text.","author":9000},
            {"sprite":"2.2.png","entry":"First text.","author":"B"}]
    def write(path,value):(root/path).write_text(json.dumps(value,ensure_ascii=False),encoding="utf-8")
    write("Data/pokedex/dex.json",source)
    write("Data/localization/zh-CN-dex-entry-overrides.json",{"First text.":"第一段。"})
    write("Data/localization/zh-CN-dex-review-overrides.json",{})
    original=(root/"Data/pokedex/dex.json").read_bytes()
    try:build(root)
    except ValueError:pass
    else:raise AssertionError("An incomplete review was published")
    assert not (root/"Data/pokedex/dex_zh.json").exists()
    write("Data/localization/dex-proofread/a.json",{"Second text.":"第二段。"})
    rows=build(root)
    assert [r["entry"] for r in rows]==["第一段。","第二段。","第一段。"]
    assert [r["author"] for r in rows]==["A",9000,"B"]
    assert [r["source"] for r in rows]==[r["entry"] for r in source]
    assert (root/"Data/pokedex/dex.json").read_bytes()==original
    assert not (root/"Data/pokedex/dex_zh.json.pending").exists()
    write("Data/localization/zh-CN-dex-source.json", source)
    write("Data/pokedex/dex.json", source + [
        {"sprite":"3.3.png","entry":"Unreviewed upstream text.","author":"C"},
        {"sprite":"4.4.png","entry":"First text.","author":"D"}])
    updated=build(root)
    assert len(updated)==4 and updated[-1]["author"]=="D"
    assert all(row["source"]!="Unreviewed upstream text." for row in updated)
print("PROOFREAD_BUILD_TEST_PASS complete_coverage_required=true source_and_authors=preserved offline=true")
