"""Build native render inputs from applied texture manifests, including ground variants."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
assets, originals, scenes, names = [], {}, [], set()
ground_names = set()
for manifest in sorted(OUT.glob("batch-*/manifest.json")):
    for entry in json.loads(manifest.read_text())["entries"]:
        source = entry["source"]
        assert hashlib.sha256((ROOT / source).read_bytes()).hexdigest() == entry["after_sha256"]
        assets.append([source, *entry["size"]])
        originals[source] = (manifest.parent / "originals" / source).relative_to(ROOT).as_posix()
        path = Path(source)
        if path.parent.name == "battlebg":
            name = path.stem
            scenes.append([name, source, "forest" if name == "foresteve" else re.sub(r"_(eve|night)$", "", name)])
            names.add(name)
        elif path.parent.name in {"enemybase", "playerbase"}:
            ground_names.add(path.stem)
aliases = {"grass": "field", "grasspuddle": "field", "ice": "caveice", "sand": "beach", "cave2": "cave"}
for name in sorted(ground_names - names):
    base = re.sub(r"_(eve|night)$", "", name).split("_")[0]
    base = aliases.get(base, base)
    time = name.rsplit("_", 1)[-1]
    candidates = [name, base + "_" + time, base, "indoora"]
    background = next("Graphics/Battlebacks/battlebg/" + candidate + ".png" for candidate in candidates if (ROOT / "Graphics/Battlebacks/battlebg" / (candidate + ".png")).is_file())
    scenes.append([name, background, base])
text = "TEXTURE_ENGINE_ASSETS = " + json.dumps(assets) + "\nTEXTURE_ENGINE_SCENES = " + json.dumps(scenes)
text += "\nTEXTURE_ENGINE_ORIGINALS = {\n" + ",\n".join(json.dumps(k) + " => " + json.dumps(v) for k, v in originals.items()) + "\n}\n"
(OUT / "engine-assets.rb").write_text(text, encoding="utf-8")
print(json.dumps({"native_assets": len(assets), "native_scenes": len(scenes), "renders": len(scenes)*2}))
