from pathlib import Path
import hashlib
import importlib.util
import json
from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
manifest = json.loads((ROOT / "Data/localization/zh-CN-images.json").read_text(encoding="utf-8"))
edits = json.loads((ROOT / "Data/localization/zh-CN-image-edits.json").read_text(encoding="utf-8"))
checks = 0
for name, row in manifest["images"].items():
    source, target = ROOT / name, ROOT / row["path"]
    assert hashlib.sha256(source.read_bytes()).hexdigest() == row["source_sha256"], name
    assert hashlib.sha256(target.read_bytes()).hexdigest() == row["sha256"], name
    original, translated = Image.open(source).convert("RGBA"), Image.open(target).convert("RGBA")
    assert original.size == translated.size, name
    if name in edits:
        allowed = Image.new("L", original.size)
        draw = ImageDraw.Draw(allowed)
        for edit in edits[name]:
            x, y, w, h = edit["rect"]
            draw.rectangle((x, y, x+w-1, y+h-1), fill=255)
        differences = ImageChops.difference(original, translated)
        # Include RGB and alpha changes, even for transparent source pixels.
        for channel in differences.split():
            assert ImageChops.multiply(channel, ImageChops.invert(allowed)).getbbox() is None, name
    checks += 1
spec = importlib.util.spec_from_file_location("package_game", ROOT / "scripts/android/package_game.py")
import sys
sys.path.insert(0, str(ROOT / "scripts/android"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sources = {}
module.add_chinese_assets(sources)
assert all(row["path"] in sources for row in manifest["images"].values())
assert "Data/localization/zh-CN-images.json" in sources
assert "Data/pokedex/dex_zh.json" in sources
print(f"CHINESE_IMAGES_PASS images={checks} atlas_dimensions=preserved outside_text_regions=unchanged apk_inventory=covered")
