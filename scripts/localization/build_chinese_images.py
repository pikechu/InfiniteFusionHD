"""Replace reviewed text rectangles; retain source art and atlas dimensions."""
from pathlib import Path
import hashlib
import json
import sys
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FONT = ROOT / "Fonts/NotoSansSC-Regular.otf"


def replace(image, edit):
    x, y, width, height = edit["rect"]
    assert x >= 0 and y >= 0 and x + width <= image.width and y + height <= image.height
    background = edit.get("background")
    if background is not None:
        image.paste(tuple(background), (x, y, x+width, y+height))
    elif edit.get("erase") == "inpaint":
        sys.path.insert(0, str(ROOT / "temp/localization/ocr-runtime"))
        import cv2
        import numpy as np
        pixels = np.array(image)
        mask = np.zeros(pixels.shape[:2], dtype=np.uint8)
        mask[y:y+height, x:x+width] = 255
        restored = cv2.inpaint(pixels[:, :, :3], mask, 3, cv2.INPAINT_TELEA)
        pixels[y:y+height, x:x+width, :3] = restored[y:y+height, x:x+width]
        image.paste(Image.fromarray(pixels))
    else:
        # Sample the clean rows immediately above/below the lettering, keeping
        # the button's original horizontal gradient and surrounding frame.
        if "sample_x" in edit:
            for row in range(y, y+height):
                image.paste(image.getpixel((edit["sample_x"], row)), (x, row, x+width, row+1))
        else:
            top, bottom = max(0, y-2), min(image.height-1, y+height+1)
            for column in range(x, x+width):
                a, b = image.getpixel((column, top)), image.getpixel((column, bottom))
                for offset in range(height):
                    t = (offset+1)/(height+1)
                    image.putpixel((column, y+offset), tuple(round(a[k]*(1-t)+b[k]*t) for k in range(4)))
    text = edit["text"]
    if not text:
        return
    size = edit.get("size", height)
    stroke = edit.get("stroke", 0)
    while size >= 7:
        font = ImageFont.truetype(str(FONT), size)
        box = font.getbbox(text, stroke_width=stroke)
        if box[2]-box[0] <= width and box[3]-box[1] <= height:
            break
        size -= 1
    assert box[2]-box[0] <= width and box[3]-box[1] <= height, (text, edit)
    layer = Image.new("RGBA", (width, height))
    draw = ImageDraw.Draw(layer)
    left = (width-(box[2]-box[0]))/2-box[0]
    top = (height-(box[3]-box[1]))/2-box[1]
    draw.text((left, top), text, font=font, fill=tuple(edit.get("color", [255,255,255,255])),
              stroke_width=stroke, stroke_fill=tuple(edit.get("outline", [40,40,40,255])))
    image.alpha_composite(layer, (x, y))


def build():
    spec = json.loads((ROOT / "Data/localization/zh-CN-image-edits.json").read_text(encoding="utf-8"))
    manifest = {"version": 1, "images": {}}
    for name, edits in spec.items():
        source = ROOT / name
        target = ROOT / "Graphics/Chinese" / source.relative_to(ROOT / "Graphics").with_suffix(".png")
        image = Image.open(source).convert("RGBA")
        for edit in edits:
            try:
                replace(image, edit)
            except AssertionError as error:
                raise AssertionError((name, edit)) from error
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target, optimize=True)
        assert Image.open(target).size == Image.open(source).size
        manifest["images"][name] = {"path": target.relative_to(ROOT).as_posix(),
                                   "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                                   "sha256": hashlib.sha256(target.read_bytes()).hexdigest()}
    by_hash = {row["source_sha256"]: row for row in manifest["images"].values()}
    sizes = { (ROOT / name).stat().st_size for name in spec }
    for source in (ROOT / "Graphics").rglob("*"):
        if source.suffix.lower() != ".png" or source.is_relative_to(ROOT / "Graphics/Chinese") or source.stat().st_size not in sizes:
            continue
        name = source.relative_to(ROOT).as_posix()
        if name in manifest["images"]:
            continue
        row = by_hash.get(hashlib.sha256(source.read_bytes()).hexdigest())
        if row:
            manifest["images"][name] = row.copy()
    path = ROOT / "Data/localization/zh-CN-images.json"
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print("CHINESE_IMAGES", len(manifest["images"]), "REGIONS", sum(map(len, spec.values())), flush=True)


if __name__ == "__main__":
    build()
