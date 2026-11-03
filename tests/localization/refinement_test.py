"""Translation transport and review safeguards, without external requests."""
from pathlib import Path
import importlib.util
import json
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("refine", ROOT/"scripts/localization/refine_custom_dex.py")
refine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refine)

records = [{"sprite":"PRIVATE_SPRITE.png", "entry":"Bulbasaur uses Vine Whip. POKENAME lives in Kanto.", "author":"PRIVATE_AUTHOR"},
           {"sprite":"PRIVATE_SPRITE_2.png", "entry":"NAME protects the forest. 守护森林", "author":"PRIVATE_AUTHOR_2"}]
prepared = refine.prepare_records(records)
assert "妙蛙种子" in prepared[0]["values"]
assert "关都" in prepared[0]["values"]
assert "PRIVATE" not in json.dumps(prepared,ensure_ascii=False)
assert "POKENAME" in prepared[1]["input"]
assert not refine.CJK.search(prepared[1]["input"])
assert "守护森林" in prepared[1]["values"]
calls = []
def request(text):
    calls.append(text)
    assert "PRIVATE" not in text and not refine.CJK.search(text)
    return "<p0>第一条。</p0><p1>第二条。</p1>"
refine.request_translation = request
translated = refine.translate_batch([row["input"] for row in prepared])
assert [row["translation"] for row in translated] == ["第一条。", "第二条。"]
assert len(calls)==1
assert "ZXQ0QXZ" in calls[0] and "<x0>" not in calls[0]
def split_request(text):
    return "missing batch markers" if text.startswith("<p") else "单条重试。"
refine.request_translation=split_request
assert refine.translate_batch(["A description."])[0]["translation"] == "单条重试。"
assert "核聚变" in refine.normalize("它能进行核聚变。", "It uses nuclear fusion.")
assert refine.normalize("聚变神奇宝贝在关东。", "A fusion Pokémon in Kanto.") == "融合宝可梦在关都。"
assert refine.normalize("<x0>背上的种子。", "The seed on its back.") == "<x0>背上的种子。"
assert refine.normalize("他们守着浆果。", "They guard Berries.") == "它们守着树果。"
assert refine.normalize("他们研究浆果。", "Scientists study Berries.") == "他们研究树果。"
assert refine.normalize("放出10,000伏电流。", "It releases 10,000 volts.") == "放出10,000伏电流。"
print("REFINEMENT_PASS consent_scope=descriptions_only batch_identity=preserved fallback=checked nuclear_context=preserved")
