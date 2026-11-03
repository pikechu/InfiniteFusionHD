"""Create deterministic KIF shop uniforms with new palettes and woven highlights.

Extends the game's existing sprite system. Original free outfits are untouched.
The generated catalog pins every new sprite; both clients ship identical assets.
"""
import colorsys
import hashlib
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
PLAYER = ROOT / "Graphics/Characters/player"
PALETTES = [("azure", "苍蓝", (45, 130, 230)), ("jade", "翡翠", (30, 180, 135)),
            ("ember", "赤焰", (220, 75, 80)), ("violet", "星紫", (155, 100, 230))]


def main():
    assets, entitlements, products = {}, {}, []
    for index, (name, label, color) in enumerate(PALETTES):
        for folder, source, slot, price, suffix in [("clothes", "red", "clothes", 300, "织纹制服"),
                                                    ("hat", "ash", "hat", 100, "徽记帽"),
                                                    ("hair", "red", "hair", 100, "渐层发型")]:
            identifier = "shop" + name
            target = PLAYER / folder / identifier
            target.mkdir(parents=True, exist_ok=True)
            for original in sorted((PLAYER / folder / source).glob("*.png")):
                output = target / original.name.replace("_" + source, "_" + identifier)
                image = Image.open(original).convert("RGBA")
                pixels = image.load()
                for y in range(image.height):
                    for x in range(image.width):
                        r, g, b, a = pixels[x, y]
                        if not a:
                            continue
                        luminance = (r * .3 + g * .59 + b * .11) / 255
                        hue, sat, _ = colorsys.rgb_to_hsv(*(v / 255 for v in color))
                        # New two-tone weave, not a hue setting available on free clothes.
                        stripe = ((x + 2 * y) % 9 == index + 1) and luminance > .25
                        rgb = colorsys.hsv_to_rgb(hue, sat * (.25 if stripe else .9), min(1, luminance * 1.15 + (.15 if stripe else .03)))
                        pixels[x, y] = tuple(round(v * 255) for v in rgb) + (a,)
                image.save(output, optimize=True)
                assets[output.relative_to(ROOT).as_posix()] = hashlib.sha256(output.read_bytes()).hexdigest()
            key = slot + ":" + name
            resource = "3_" + identifier if slot == "hair" else identifier
            entitlements[key] = {"slot": slot, "resource": resource, "name": label + suffix, "value": price}
            products.append({"id": "shop-" + slot + "-" + name, "name": label + suffix, "category": slot,
                             "price": price, "grants": [key], "description": "商城专属织纹与渐层配色。永久使用，同账号共享，不可交易。", "enabled": True})
        bundle = [slot + ":" + name for slot in ("clothes", "hat", "hair")]
        products.append({"id": "bundle-" + name, "name": label + "研究员套装", "category": "bundle", "price": 400,
                         "grants": bundle, "discount_percent": 80, "description": "套装八折；只支付尚未拥有的部分。永久账号绑定。", "enabled": True})
    for slot, entries in {"frame": [("ocean", "海蓝名片边框", [50, 150, 235]), ("sunset", "落日名片边框", [235, 135, 70])],
                          "title": [("researcher", "融合研究员", [110, 210, 245]), ("explorer", "世界探索者", [110, 230, 150])],
                          "palette": [("midnight", "午夜商城主题", [95, 105, 210]), ("forest", "森林商城主题", [45, 145, 100])]}.items():
        for name, label, rgb in entries:
            key = slot + ":" + name
            price = 150 if slot == "frame" else 80
            entitlements[key] = {"slot": slot, "name": label, "color": rgb, "value": price}
            products.append({"id": "shop-" + slot + "-" + name, "name": label, "category": slot,
                             "price": price, "grants": [key], "description": "永久账号绑定的展示装饰。", "enabled": True})
    products.append({"id": "season-ember", "name": "秋日赤焰套装", "category": "seasonal", "price": 350,
                     "grants": ["clothes:ember", "hat:ember", "hair:ember"], "discount_percent": 70,
                     "starts_at": 0, "ends_at": 1793462400,
                     "description": "2026-11-01 00:00（北京时间）下架；购买后永久使用，已拥有部分不重复收费。", "enabled": True})
    base = {}
    for slot, filename in (("clothes", "clothes_data.json"), ("hat", "hats_data.json"), ("hair", "hairstyles_data.json")):
        entries = json.loads((ROOT / "Data/outfits" / filename).read_text(encoding="utf-8"))
        if slot == "hair":
            base[slot] = [f"{version}_{entry['id']}" for entry in entries for version in range(1, 5)
                          if (PLAYER / "hair" / entry["id"] / f"hair_{version}_{entry['id']}.png").is_file()]
        else:
            folder = "hat" if slot == "hat" else "clothes"
            base[slot] = [entry["id"] for entry in entries if (PLAYER / folder / entry["id"] /
                         (f"hat_{entry['id']}.png" if slot == "hat" else f"clothes_walk_{entry['id']}.png")).is_file()]
    for slot, default in (("clothes", "pikajamas"), ("hair", "3_red")):
        base[slot] = [default] + sorted(set(base[slot]) - {default})
    base["hat"] = [None] + sorted(set(base["hat"]))
    base["skin_tone"] = ["default"] + sorted(p.name for p in (PLAYER / "base/overworld").iterdir() if p.is_dir() and p.name != "default")
    catalog = {"version": 1, "currency": "RP", "base": base, "assets": assets, "entitlements": entitlements, "products": products}
    directory = ROOT / "Data/shop"
    directory.mkdir(exist_ok=True)
    (directory / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"SHOP_ASSETS_PASS products={len(products)} sprites={len(assets)}")


if __name__ == "__main__":
    main()
