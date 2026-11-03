"""Audit explicit sentence-review coverage; never mark an unread entry done."""
from pathlib import Path
import argparse
import hashlib
import json
import re

ROOT=Path(__file__).resolve().parents[2]
def read(path):return json.loads(path.read_text(encoding="utf-8-sig"))

def audit(complete=False, root=None):
    root=ROOT if root is None else Path(root)
    original=read(root/"Data/pokedex/dex.json")
    expected={row["entry"] for row in original}
    baseline={}
    for name in ["zh-CN-dex-entry-overrides.json","zh-CN-dex-review-overrides.json"]:
        baseline.update(read(root/"Data/localization"/name))
    baseline={source:text for source,text in baseline.items() if source in expected}
    reviewed={};parts={};problems=[]
    for path in sorted((root/"Data/localization/dex-proofread").glob("*.json")):
        content=read(path)
        if not isinstance(content,dict):raise ValueError("Expected reviewed source/text mapping: "+str(path))
        parts[path.name]=len(content)
        for source,text in content.items():
            if source not in expected:problems.append([path.name,"unknown source",source]);continue
            if source in reviewed or source in baseline:problems.append([path.name,"duplicate assignment",source]);continue
            if not isinstance(text,str) or not re.search(r"[\u3400-\u9fff]",text):problems.append([path.name,"missing Chinese",source]);continue
            if re.search(r"[A-Za-z]{3,}",text.replace("POKENAME","").replace("DNA","")):problems.append([path.name,"English text",source])
            if any(t in text for t in ["⁇","�","<x","ZXQ"]):problems.append([path.name,"unknown marker",source])
            has_name=bool(re.search(r"POKENAME|PKOENAME|POKEMAME|POEKNAME|POKNEAME|POKÉNAME",source,re.I) or re.search(r"\bNAME\b",source))
            if ("POKENAME" in text)!=has_name:problems.append([path.name,"name placeholder",source])
            reviewed[source]=text
    all_reviewed=baseline|reviewed
    missing=sorted(expected-all_reviewed.keys())
    covered_records=sum(row["entry"] in all_reviewed for row in original)
    report={"format":1,"reviewer":"AI assistant sentence-by-sentence review, not human translator sign-off",
            "source_sha256":hashlib.sha256((root/"Data/pokedex/dex.json").read_bytes()).hexdigest(),
            "records":len(original),"unique_sources":len(expected),"previous_reviewed_sources":len(baseline),
            "new_reviewed_sources":len(reviewed),"reviewed_sources":len(all_reviewed),"reviewed_records":covered_records,
            "remaining_sources":len(missing),"shards":parts,"problems":problems,
            "complete":not missing and not problems}
    out=root/"Data/localization/zh-CN-dex-proofread-progress.json"
    out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({k:report[k] for k in ["reviewed_sources","remaining_sources","shards","complete"]},ensure_ascii=False))
    if problems:raise ValueError(json.dumps(problems[:8],ensure_ascii=False))
    if complete and missing:raise ValueError(f"{len(missing)} sources still need sentence review")
    return report

if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--complete",action="store_true")
    audit(parser.parse_args().complete)
