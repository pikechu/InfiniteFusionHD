"""Bundled localization coverage and source/credit integrity, no MT runtime needed."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[2]
original = json.loads((ROOT / "Data/pokedex/dex.json").read_text(encoding="utf-8"))
translated = json.loads((ROOT / "Data/pokedex/dex_zh.json").read_text(encoding="utf-8"))
review_source = json.loads((ROOT / "Data/localization/zh-CN-dex-source.json").read_text(encoding="utf-8"))
assert len(review_source) == len(original) == 82_207
reviewed = {row["entry"] for row in review_source}
expected = [row for row in original if row["entry"] in reviewed]
assert len(translated) == len(expected)
assert (ROOT / "Data/pokedex/dex_zh.json").stat().st_size <= 32 * 1024 * 1024
for index, (source, target) in enumerate(zip(expected, translated)):
    assert target["sprite"] == source["sprite"] and target["author"] == source["author"], index
    assert target["source"] == source["entry"], index
    text = target["entry"]
    assert re.search(r"[\u3400-\u9fff]", text), index
    latin_text = text.replace("POKENAME", "").replace("DNA", "")
    if "jeb_" in source["entry"]:
        latin_text = latin_text.replace("jeb_", "")
    assert not re.search("[A-Za-z]{3,}", latin_text), index
    assert not any(token in text for token in ("⁇", "�", "<x", "< x")), index
    assert not re.search(r"([\u3400-\u9fff]{2,12})\1\1", text), index
    # Author typos NAME/PKOENAME/POKÉNAME are repaired to the game's placeholder.
    expected = len(re.findall(r"POKENAME|PKOENAME|POKEMAME|POEKNAME|POKNEAME|POKÉNAME|POKNAME|POKENSME", source["entry"], re.I))
    expected += len(re.findall(r"\bNAME\b", source["entry"]))
    assert bool(text.count("POKENAME")) == bool(expected), (index, text)

# Keep formerly mistranslated context distinct when rebuilding the bundle.
by_source = {row["source"].strip(): row["entry"] for row in translated}
semantic_cases = [
    ("Tourists enjoy traveling to craggy mountains to watch wild POKENAME train. Their kicks can cause even stone to break in a fiery burst.", "修行", "列车"),
    ("POKENAME shed their skin regularly to maintain a glossy appearance. Researchers discovered they shed about 200 times a year, ensuring their skin stays smooth and healthy.", "蜕皮", "脱毛"),
    ("This fusion is perhaps one of the most haughty that this world knows; it considers all Pokémon as its court.", "臣属", "法庭"),
    ("POKENAME has a flickering purple flame atop its head that lights up whenever its happy and in a playful mood. It can ignite small sparks and flames, using its fire to spread its cheerful spirit.", "高兴", "心情不好"),
    ("POKENAME is rarely seen with the naked eye, even by Pokémon. It produces small icicles that it fires at prey from its long, hollow leek.", "小冰柱", "韭菜"),
    ("The staff there offers damaged equipment or leftover paints to POKENAME for use on its disguises.", "工人", "法杖"),
    ("POKENAME is capable of causing a mass extinction event by clogging the atmosphere with volcanic ash. Its plates are made of pure obsidian.", "甲片", "盘子"),
    ("Its body secretes aloe-like sap, which soothes and hydrates its spines. This natural gel protects it from harsh sunlight, keeping it healthy in dry, arid environments.", "尖刺", "脊椎"),
    ("Long thought extinct, paleontologists were stunned to discover POKENAME still living in small colonies on the ocean floor. With their slow and gentle habits, they can support tiny but thriving ancient ecosystems on their backs.", "以为POKENAME已经灭绝", "灭绝的古生物学家"),
]
for source, wanted, forbidden in semantic_cases:
    matches = [entry for original, entry in by_source.items() if source in original]
    assert len(matches) == 1, source
    assert wanted in matches[0] and forbidden not in matches[0], matches[0]
strength = by_source["The physical prowess of POKENAME is unmatched. However, its strength has made it sedentary and arrogant."]
bond = by_source["If two POKENAME meet, they'll battle until either one or both of them collapse from exhaustion. This is how they form bonds."]
assert strength != bond and "情谊" in bond
print(f"COMMUNITY_DATA_PASS reviewed_corpus={len(review_source)} translated_records={len(translated)} game_records={len(original)} source_and_credits=unchanged name_placeholders=preserved unknown_tokens=0")
