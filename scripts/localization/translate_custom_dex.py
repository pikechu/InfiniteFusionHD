"""Build the Chinese community dex without changing source records or credits.

Requires the pinned OPUS model and CTranslate2 runtime in temp/localization.
Translations are checkpointed per sentence; game terminology stays protected.
"""
from pathlib import Path
import argparse
import collections
import hashlib
import json
import re
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "temp/localization"
sys.path.insert(0, str(WORK / "mt-runtime"))


def prepare():
    official = json.loads((WORK / "pokeapi-glossary/terms.json").read_text(encoding="utf-8"))
    game = json.loads((WORK / "game-glossary.json").read_text(encoding="utf-8"))
    terms = {key: value for key, value in official.items() if len(key) >= 3}
    terms.update(game["terms"])
    terms = {key: value for key, value in terms.items() if not key.islower()}
    terms.update({"Pokémon": "宝可梦", "Pokemon": "宝可梦", "Pokemons": "宝可梦", "Pokémons": "宝可梦",
                  "Kanto": "关都", "Johto": "城都", "Hoenn": "丰缘", "Sinnoh": "神奥", "Unova": "合众",
                  "Kalos": "卡洛斯", "Alola": "阿罗拉", "Galar": "伽勒尔", "Paldea": "帕底亚",
                  "Team Rocket": "火箭队", "Poké Ball": "精灵球", "Pokeball": "精灵球", "POKENAME": "POKENAME"})
    # A move called Return or a species called Golem must not replace ordinary
    # lowercase prose. Existing names in title case are unambiguous here.
    pattern = re.compile(r"(?<![\w])(?:" + "|".join(re.escape(key) for key in sorted(terms, key=len, reverse=True)) + r")(?![\w])")
    records = json.loads((ROOT / "Data/pokedex/dex.json").read_text(encoding="utf-8-sig"))
    fragments = {}
    prepared = []
    for record in records:
        values = []
        def protect(match):
            value = match.group(0)
            values.append(terms[value])
            return f"<p{len(values)-1}>"
        text = pattern.sub(protect, record["entry"])
        fusion = game["fusions"].get(record["sprite"])
        if fusion and len(fusion[0]) >= 4:
            def protect_fusion(match):
                values.append(fusion[1])
                return f"<p{len(values)-1}>"
            text = re.sub(r"(?<![\w])" + re.escape(fusion[0]) + r"(?![\w])", protect_fusion, text)
        parts = []
        # Translate sentences separately: the small model sometimes drops an
        # entire opening sentence when given a multi-sentence paragraph.
        for sentence in re.split(r"(?<=[.!?])\s+(?=[\"'A-Z<\d])|[\r\n]+", text):
            if not sentence.strip():
                continue
            local = []
            def canonical(match):
                local.append(values[int(match.group(1))])
                return f"<x{len(local)-1}>"
            key = re.sub(r"<p(\d+)>", canonical, sentence.strip())
            fragments[key] = True
            parts.append([key, local])
        prepared.append(parts)
    return records, prepared, list(fragments)


def normalize_tags(text):
    return re.sub(r'''(?<!\w)(?:[<\["“‘']\s*)?[xXＸ]\s*(\d+)(?:\s*[>\]"”’'])?(?!\w)''',
                  lambda match: "<x"+match.group(1)+">", text)


def main():
    import ctranslate2
    import sentencepiece as spm
    from sacremoses import MosesPunctNormalizer
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--repair", action="store_true")
    args = parser.parse_args()
    records, prepared, keys = prepare()
    checkpoint = WORK / "custom-dex-sentences.jsonl"
    done = {}
    if checkpoint.exists():
        for line in checkpoint.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            done[row["source"]] = row
    for row in done.values():
        row["translation"] = normalize_tags(row["translation"])
    pending = [key for key in keys if key not in done]
    if args.limit:
        pending = pending[:args.limit]
    model = WORK / "mt-model"
    source = spm.SentencePieceProcessor(model_file=str(model / "source.spm"))
    target = spm.SentencePieceProcessor(model_file=str(model / "target.spm"))
    translator = ctranslate2.Translator(str(model), device="cpu", compute_type="int8", intra_threads=4, inter_threads=2)
    normalizer = MosesPunctNormalizer(lang="en")
    start = time.monotonic()
    print("DEX_SENTENCES", len(keys), "CACHED", len(done), "PENDING", len(pending), flush=True)
    with checkpoint.open("a", encoding="utf-8") as stream:
        for offset in range(0, len(pending), 128):
            batch = pending[offset:offset+128]
            inputs = [[">>cmn_Hans<<"] + source.encode(normalizer.normalize(text), out_type=str) + ["</s>"] for text in batch]
            results = translator.translate_batch(inputs, beam_size=4, max_batch_size=32, max_decoding_length=240, return_scores=True)
            for key, result in zip(batch, results):
                translated = target.decode(result.hypotheses[0])
                row = {"source": key, "translation": translated, "score": round(result.scores[0], 5)}
                done[key] = row
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
            stream.flush()
            print("DEX_PROGRESS", min(offset+128, len(pending)), "/", len(pending), "SECONDS", round(time.monotonic()-start, 1), flush=True)
        if args.repair:
            retry = [key for key in keys if key in done and collections.Counter(re.findall(r"<x(\d+)>", key)) != collections.Counter(re.findall(r"<x(\d+)>", done[key]["translation"]))]
            print("DEX_REPAIR", len(retry), flush=True)
            for offset in range(0, len(retry), 64):
                batch = retry[offset:offset+64]
                numeric = [re.sub(r"<x(\d+)>", lambda match: str(971230+int(match.group(1))), text) for text in batch]
                inputs = [[">>cmn_Hans<<"] + source.encode(normalizer.normalize(text), out_type=str) + ["</s>"] for text in numeric]
                results = translator.translate_batch(inputs, beam_size=8, max_batch_size=32, max_decoding_length=240, return_scores=True)
                for key, result in zip(batch, results):
                    text = target.decode(result.hypotheses[0])
                    text = re.sub(r"(?<!\d)97(?:[ ,]*\d){4}(?!\d)", lambda match: "<x"+str(int(re.sub(r"\D", "", match.group(0)))-971230)+">", text)
                    row = {"source": key, "translation": normalize_tags(text), "score": round(result.scores[0],5), "repair": "numeric-copy"}
                    if collections.Counter(re.findall(r"<x(\d+)>", key)) != collections.Counter(re.findall(r"<x(\d+)>", row["translation"])):
                        continue
                    done[key] = row
                    stream.write(json.dumps(row,ensure_ascii=False)+"\n")
                stream.flush()
                print("DEX_REPAIR_PROGRESS", min(offset+64,len(retry)), "/", len(retry), flush=True)
    if any(key not in done for key in keys):
        print("PREVIEW_SAVED", len(done), flush=True)
        return
    output = []
    flags = []
    override_path = ROOT / "Data/localization/zh-CN-dex-overrides.json"
    overrides = json.loads(override_path.read_text(encoding="utf-8")) if override_path.exists() else {}
    residual = json.loads((ROOT / "Data/localization/zh-CN-dex-fusions.json").read_text(encoding="utf-8"))
    official = json.loads((WORK / "pokeapi-glossary/terms.json").read_text(encoding="utf-8"))
    residual.update(official)
    residual.update({word+"s": text for word,text in official.items()})
    residual.update(json.loads((ROOT / "Data/localization/zh-CN-dex-terms.json").read_text(encoding="utf-8")))
    residual_pattern = re.compile(r"(?<![A-Za-z])(?:"+"|".join(re.escape(word) for word in sorted(residual,key=len,reverse=True))+r")(?![A-Za-z])")
    entry_overrides_path = ROOT / "Data/localization/zh-CN-dex-entry-overrides.json"
    entry_overrides = json.loads(entry_overrides_path.read_text(encoding="utf-8")) if entry_overrides_path.exists() else {}
    for record, parts in zip(records, prepared):
        sentences = []
        for key, values in parts:
            text = normalize_tags(overrides.get(key, done[key]["translation"]))
            found = re.findall(r"<\s*x\s*(\d+)\s*>", text)
            expected = re.findall(r"<x(\d+)>", key)
            if collections.Counter(found) != collections.Counter(expected):
                flags.append({"sprite": record["sprite"], "source": key, "translation": text, "reason": "term tags"})
            text = re.sub(r"<\s*x\s*(\d+)\s*>", lambda match: values[int(match.group(1))] if int(match.group(1)) < len(values) else match.group(0), text)
            text = text.replace("<", "").replace(">", "")
            if not re.search(r"[\[\]]", key):
                text = text.replace("[", "").replace("]", "")
            if re.search(r"[A-Za-z]", text.replace("POKENAME", "").replace("DNA", "")):
                text = residual_pattern.sub(lambda match:residual[match.group(0)], text)
            text = text.replace("聚变", "融合").replace("神奇宝贝", "宝可梦").replace("口袋妖怪", "宝可梦").replace("宠物小精灵", "宝可梦")
            text = text.replace("核融合", "融合").replace("培训员", "训练家").replace("训练员", "训练家")
            if re.search(r"\bbulbs?\b", key, re.I):
                text = text.replace("灯泡", "鳞茎")
            if re.search(r"\bevol", key, re.I):
                text = text.replace("演变", "进化")
            text = text.replace("他们", "它们").replace("她们", "它们")
            if "unmatched" in key:
                text = text.replace("不匹配", "无与伦比").replace("不相匹配", "无与伦比")
            if "maws" in key:
                text = text.replace("野马", "巨口")
            if "fallen Trainers" in key:
                text = text.replace("堕落的", "逝去的").replace("后世", "来世")
            if "staff" in key:
                text = text.replace("工作人员", "法杖")
            if "Trainers" in key:
                text = text.replace("教练", "训练家")
            text = re.sub(r"(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff，。！？；：、])|(?<=[，。！？；：、])\s+", "", text)
            text = re.sub(r"(?<![A-Za-z])(?:a|A)(?![A-Za-z])", "", text)
            text = re.sub(r"(?<=\d)\s+(?=\d)", "", text)
            text = text.translate(str.maketrans({",": "，", ";": "；", ":": "：", "?": "？", "!": "！"}))
            text = re.sub(r"(?<!\d)\.(?!\d)", "。", text).strip()
            if not text.endswith(tuple("。！？…\"”'’")):
                text += "。"
            sentences.append(text)
        translated = entry_overrides.get(record["entry"], "".join(sentences))
        translated = re.sub(r"\s+", "", translated)
        # Preserve source identity so an upstream update cannot attach an old
        # translation to a new entry with the same sprite or author.
        output.append({**record, "source": record["entry"], "entry": translated})
        if re.search(r"[A-Za-z]{3,}", translated.replace("POKENAME", "").replace("DNA", "")):
            flags.append({"sprite": record["sprite"], "source": record["entry"], "translation": translated, "reason": "Latin text"})
    (WORK / "custom-dex-review.json").write_text(json.dumps(flags, ensure_ascii=False, indent=2), encoding="utf-8")
    (ROOT / "Data/pokedex/dex_zh.json").write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print("DEX_COMPLETE", len(output), "REVIEW", len(flags), flush=True)


if __name__ == "__main__":
    main()
