"""Refine the community dex after explicit consent to send descriptions to Google.

Only English description text and temporary term/batch markers leave this
process. Sprite paths, authors, saved games and account data are never sent.
The game reads the resulting static JSON and never calls this service.
"""
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import argparse
import collections
import csv
import hashlib
import html
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "temp/localization"
CACHE = WORK / "google-dex.jsonl"
ENDPOINT = "https://translate.googleapis.com/translate_a/single"
TAG = re.compile(r"<\s*x\s*(\d+)\s*>", re.I)
CJK = re.compile(r"[\u3040-\u30ff\u3400-\u9fff]+")
PLACEHOLDER = re.compile(r"POKENAME|PKOENAME|POKEMAME|POEKNAME|POKNEAME|POKÉNAME", re.I)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def terminology():
    game = read_json(WORK / "game-glossary.json")
    official = read_json(WORK / "pokeapi-glossary/terms.json")
    names = {}
    with (WORK / "pokeapi-glossary/pokemon_species_names.csv").open(encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            if row["local_language_id"] == "9" and row["name"] in official:
                name = row["name"]
                names[name] = game["terms"].get(name, official[name])
    extras = read_json(ROOT / "Data/localization/zh-CN-dex-terms.json")
    for word in ["Kanto", "Johto", "Hoenn", "Sinnoh", "Unova", "Kalos", "Alola", "Galar", "Paldea"]:
        names[word] = dict(zip(["Kanto", "Johto", "Hoenn", "Sinnoh", "Unova", "Kalos", "Alola", "Galar", "Paldea"],
                              ["关都", "城都", "丰缘", "神奥", "合众", "卡洛斯", "阿罗拉", "伽勒尔", "帕底亚"]))[word]
    # Protect multiword proper names, and single-word moves only when the
    # original explicitly calls them a move/attack. Ordinary prose stays prose.
    contextual = {}
    for word, value in {**official, **game["terms"]}.items():
        if not word or word.islower() or not re.search(r"[A-Za-z]", word):
            continue
        if len(word.split()) > 1:
            names.setdefault(word, value)
        elif len(word) >= 3:
            contextual[word] = value
    # References to earlier fused forms use the game's established fragments.
    ambiguous = {"Magma", "Silver", "Gentle", "Castelia", "golems", "wyvern", "behemoth", "Marts", "Kinglers", "perior", "Grepa", "Aurora", "auropod"}
    for word, value in read_json(ROOT / "Data/localization/zh-CN-dex-fusions.json").items():
        if word not in ambiguous:
            names.setdefault(word, value)
    for word in ["Indigo Plateau", "Ecruteak", "Mossdeep", "Castelia", "Ballonlea", "Alto Mare", "Porta Vista", "Wintown", "Lumiose", "Fallarbor", "Sandgem", "Palmpona", "Florando", "Chocovine"]:
        if word in extras:
            names[word] = extras[word]
    pattern = re.compile(r"(?<![\w])(?:" + "|".join(re.escape(word) for word in sorted(names.keys() | contextual.keys(), key=len, reverse=True)) + r")(?![\w])")
    return game, names, contextual, pattern


def prepare_records(records):
    game, names, contextual, pattern = terminology()
    prepared = []
    for record in records:
        source = record["entry"]
        source = PLACEHOLDER.sub("POKENAME", source)
        source = re.sub(r"\bNAME\b", "POKENAME", source)
        source = re.sub(r"POKENAMES\b", "POKENAME", source, flags=re.I)
        values = []
        def tag(value):
            values.append(value)
            return f"<x{len(values)-1}>"
        def protect(match):
            word = match.group(0)
            if word in names:
                return tag(names[word])
            prefix = source[max(0,match.start()-45):match.start()]
            if re.search(r"\b(?:uses?|using|learns?|knows?|casts?|moves?|attacks?|techniques?|called|named)\b[^.!?]*$", prefix, re.I):
                return tag(contextual[word])
            return word
        query = pattern.sub(protect, source)
        fusion = game["fusions"].get(record["sprite"])
        if fusion and len(fusion[0]) >= 4 and fusion[0] not in names:
            query = re.sub(r"(?<!\w)"+re.escape(fusion[0])+r"(?!\w)", lambda _:tag(fusion[1]), query)
        # Original non-English quotations stay local as well.
        query = CJK.sub(lambda match: tag(match.group(0)), query)
        assert not CJK.search(query)
        prepared.append({"input":query,"values":values})
    return prepared


def request_translation(text):
    assert not CJK.search(text), "Only English source descriptions may be sent"
    url = ENDPOINT + "?" + urllib.parse.urlencode({"client":"gtx", "sl":"en", "tl":"zh-CN", "dt":"t", "q":text})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for attempt in range(3):
        try:
            with opener.open(url, timeout=60) as response:
                data = json.load(response)
            translated = "".join(row[0] for row in data[0] if row and row[0])
            if not translated.strip():
                raise ValueError("Empty translation response")
            return translated
        except urllib.error.HTTPError as error:
            if error.code == 429 or error.code < 500 or attempt == 2:
                raise
            time.sleep(2**attempt)
        except (TimeoutError, urllib.error.URLError):
            if attempt == 2:
                raise
            time.sleep(2**attempt)


def translate_batch(batch):
    # Unclosed XML-like term markers can make the provider treat the rest of
    # a sentence as protected markup. Use inert letter tokens on the wire.
    wire=[TAG.sub(lambda match:"ZXQ"+match.group(1)+"QXZ",text) for text in batch]
    payload = "\n\n".join(f"<p{i}>"+html.escape(text,quote=False)+f"</p{i}>" for i,text in enumerate(wire))
    translated = request_translation(payload)
    output = []
    for index, query in enumerate(batch):
        matches = re.findall(r"<\s*p\s*"+str(index)+r"\s*>(.*?)</\s*p\s*"+str(index)+r"\s*>",translated,re.S|re.I)
        text = html.unescape(matches[0]).strip() if len(matches)==1 else request_translation(wire[index])
        text=re.sub(r"Z\s*X\s*Q\s*(\d+)\s*Q\s*X\s*Z",lambda match:"<x"+match.group(1)+">",text,flags=re.I)
        output.append({"input":query,"translation":text,"provider":"Google Translate"})
    return output


def fetch(prepared, limit=0, retry_review=False):
    done = load_cache()
    pending = list(dict.fromkeys(row["input"] for row in prepared if row["input"] not in done))
    if retry_review:
        review=read_json(WORK/"google-dex-review.json")
        pending=list(dict.fromkeys(prepared[row["index"]]["input"] for row in review))
    if limit:
        pending = pending[:limit]
    batches, batch, length = [], [], 0
    for query in pending:
        if batch and length+len(query)+30>3200:
            batches.append(batch);batch=[];length=0
        batch.append(query);length+=len(query)+30
    if batch:
        batches.append(batch)
    print("GOOGLE_FETCH",len(pending),"descriptions",len(batches),"batches",flush=True)
    start = time.monotonic()
    with CACHE.open("a",encoding="utf-8") as stream, ThreadPoolExecutor(max_workers=2) as pool:
        iterator=iter(batches)
        pending_futures={pool.submit(translate_batch,batch) for batch in [next(iterator,None),next(iterator,None)] if batch}
        count=0
        while pending_futures:
            future=next(as_completed(pending_futures))
            pending_futures.remove(future)
            for row in future.result():
                stream.write(json.dumps(row,ensure_ascii=False)+"\n");count+=1
            stream.flush()
            if count%100<25 or not pending_futures:
                print("GOOGLE_PROGRESS",count,"/",len(pending),"seconds",round(time.monotonic()-start,1),flush=True)
            batch=next(iterator,None)
            if batch:
                pending_futures.add(pool.submit(translate_batch,batch))
    print("GOOGLE_FETCH_COMPLETE",len(pending),flush=True)


def load_cache():
    result = {}
    if CACHE.exists():
        for line in CACHE.read_text(encoding="utf-8").splitlines():
            row=json.loads(line);result[row["input"]]=row["translation"]
    return result


def normalize(text, source):
    text=html.unescape(text)
    for old,new in [("神奇宝贝","宝可梦"),("宠物小精灵","宝可梦"),("口袋妖怪","宝可梦"),("关东地区","关都地区"),("关东","关都"),("成都地区","城都地区"),("训练员","训练家"),("训练师","训练家"),("培训师","训练家"),("宝可梦球","精灵球")]:
        text=text.replace(old,new)
    if re.search(r"\bberr(?:y|ies)\b",source,re.I):
        text=text.replace("浆果","树果")
    human_words=r"human|people|person|man|men|woman|women|trainer|scientist|child|children|kid|owner|worker|farmer|gardener|villager|elder|sailor|hunter|poacher|travel|fisher|researcher|soldier|company|companies|team|factory|boss|settler|tribe|adult|youth|hero|priest|witch|wizard|visitor|friend|family|army|captain"
    if not re.search(r"\b(?:"+human_words+r")\w*\b",source,re.I):
        text=text.replace("他们","它们").replace("她们","它们")
    # Nuclear reactions are real in some entries; do not erase that distinction.
    if not re.search(r"nuclear|atomic|reactor|cold fusion",source,re.I):
        text=text.replace("核聚变","融合").replace("聚变","融合")
    text=re.sub(r"\s+","",text)
    text=re.sub(r"\.{3,}","……",text)
    text=text.translate(str.maketrans({",":"，",";":"；",":":"：","!":"！","?":"？"}))
    text=re.sub(r"(?<=\d)，(?=\d{3}(?!\d))",",",text)
    text=re.sub(r"(?<!\d)\.(?!\d)","。",text)
    if text and text[-1] not in "。！？…\"'”’":
        text+="。"
    return text


def build_candidate(records, prepared, publish=False):
    cache=load_cache()
    hand=read_json(ROOT/"Data/localization/zh-CN-dex-entry-overrides.json")
    improved_path=ROOT/"Data/localization/zh-CN-dex-review-overrides.json"
    improved=read_json(improved_path) if improved_path.exists() else {}
    # Each shard contains explicitly read, sentence-reviewed source paragraphs.
    proofread={}
    for path in sorted((ROOT/"Data/localization/dex-proofread").glob("*.json")):
        for source,text in read_json(path).items():
            if source in proofread:
                raise ValueError("Duplicate proofread assignment: "+source)
            proofread[source]=text
    rows,problems=[],[]
    for index,(record,query) in enumerate(zip(records,prepared)):
        source=record["entry"]
        text=cache.get(query["input"])
        if source in proofread:
            text=proofread[source]
        elif source in improved:
            text=improved[source]
        elif source in hand:
            text=hand[source]
        elif text is None:
            problems.append({"index":index,"reason":"not fetched","source":source});continue
        else:
            expected=collections.Counter(TAG.findall(query["input"]))
            if collections.Counter(TAG.findall(text))!=expected:
                problems.append({"index":index,"reason":"term markers","source":source,"translation":text});continue
            text=TAG.sub(lambda match:query["values"][int(match.group(1))],text)
        # Explicit sentence reviews are final prose. Do not run automatic
        # pronoun/terminology substitutions over an editor's contextual choice.
        text=text.strip() if source in proofread else normalize(text,source)
        row={**record,"source":source,"entry":text};rows.append(row)
        reason=[]
        if not CJK.search(text):reason.append("no Chinese")
        if re.search(r"[A-Za-z]{3}",text.replace("POKENAME","").replace("DNA","")):reason.append("Latin text")
        if any(token in text for token in ("⁇","�","<x","<p")):reason.append("unknown tokens")
        if re.search(r"([\u3400-\u9fff]{2,12})\1\1",text):reason.append("repetition")
        has_name=bool(PLACEHOLDER.search(source) or re.search(r"\bNAME\b",source))
        if ("POKENAME" in text)!=has_name:reason.append("name placeholder")
        if reason:problems.append({"index":index,"reason":reason,"source":source,"translation":text})
    (WORK/"google-dex-review.json").write_text(json.dumps(problems,ensure_ascii=False,indent=2),encoding="utf-8")
    body=json.dumps(rows,ensure_ascii=False,separators=(",",":"))
    (WORK/"google-dex-candidate.json").write_text(body,encoding="utf-8")
    print("GOOGLE_CANDIDATE",len(rows),"REVIEW",len(problems),flush=True)
    if publish:
        if problems or len(rows)!=len(records) or len(body.encode())>8*1024*1024:
            raise ValueError("Resolve the review report before publishing")
        target=ROOT/"Data/pokedex/dex_zh.json"
        pending=target.with_suffix(".json.pending")
        pending.write_text(body,encoding="utf-8");pending.replace(target)
        print("GOOGLE_REFINED_DEX_SAVED",hashlib.sha256(target.read_bytes()).hexdigest(),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode",choices=["fetch","build","publish"])
    parser.add_argument("--limit",type=int,default=0)
    parser.add_argument("--retry-review",action="store_true")
    args=parser.parse_args()
    records=read_json(ROOT/"Data/pokedex/dex.json")
    prepared=prepare_records(records)
    if args.mode=="fetch":fetch(prepared,args.limit,args.retry_review)
    else:build_candidate(records,prepared,args.mode=="publish")


if __name__=="__main__":main()
