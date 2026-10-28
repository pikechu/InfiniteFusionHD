"""Fit the AI atlas candidate while retaining tile seams, placeholders and alpha."""
from pathlib import Path
from PIL import Image, ImageDraw
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[2]
BATCH = Path(__file__).resolve().parent / "batch-014"
job = json.loads((BATCH / "jobs.json").read_text())["entries"][0]
source = ROOT / job["source"]
audit = json.loads((BATCH.parent / "p1-audit.json").read_text(encoding="utf-8"))
expected = next(row["sha256"] for row in audit["sources"] if row["source"] == job["source"])
assert hashlib.sha256(source.read_bytes()).hexdigest() == expected
with Image.open(source) as original, Image.open(job["generated"]) as generated:
    assert original.size == (256, 576)
    assert abs((generated.width / generated.height) / (256 / 576) - 1) < .01
    before = original.convert("RGBA")
    detail = generated.convert("RGBA").resize(before.size, Image.Resampling.LANCZOS)
    after = before.copy()
    base, pixels, target = before.load(), detail.load(), after.load()
    reserved = []
    for top in range(0, before.height, 32):
        for left in range(0, before.width, 32):
            red = sum(base[x,y][0] > 200 and base[x,y][1] < 90 and base[x,y][2] < 90 and base[x,y][3] > 200
                      for y in range(top, min(top+32,before.height)) for x in range(left,min(left+32,before.width)))
            if red > 20:
                reserved.append([left, top, 32, 32])
                continue
            for y in range(top,min(top+32,before.height)):
                for x in range(left,min(left+32,before.width)):
                    edge = min(x-left,31-(x-left),y-top,31-(y-top))
                    if edge < 2 or base[x,y][3] == 0:
                        continue
                    weight = min(1.0,(edge-1)/4) * pixels[x,y][3]/255
                    target[x,y] = tuple(round(base[x,y][c]*(1-weight)+pixels[x,y][c]*weight) for c in range(3)) + (base[x,y][3],)
    # Identical source tiles must remain identical after enhancement, including floors.
    tile_cache = {}
    for top in range(0,before.height,32):
        for left in range(0,before.width,32):
            box = (left,top,min(left+32,before.width),min(top+32,before.height))
            key = before.crop(box).tobytes()
            if key in tile_cache:
                after.paste(tile_cache[key],(left,top))
            else:
                tile_cache[key] = after.crop(box)
    target = after.load()
    assert before.getchannel("A").tobytes() == after.getchannel("A").tobytes()
    for y in range(before.height):
        for x in range(before.width):
            if x%32<2 or x%32>=30 or y%32<2 or y%32>=30 or base[x,y][3]==0:
                assert base[x,y] == target[x,y]
    for x,y,w,h in reserved:
        assert before.crop((x,y,x+w,y+h)).tobytes()==after.crop((x,y,x+w,y+h)).tobytes()
    ready = BATCH / "ready" / job["source"]
    backup = BATCH / "originals" / job["source"]
    raw = BATCH / "generated" / job["source"]
    for path in (ready,backup,raw): path.parent.mkdir(parents=True,exist_ok=True)
    if backup.exists(): assert hashlib.sha256(backup.read_bytes()).hexdigest()==expected
    else: shutil.copy2(source,backup)
    shutil.copy2(job["generated"],raw)
    after.save(ready,format="PNG",optimize=True)
    contact=Image.new("RGB",(536,610),"#353c45"); draw=ImageDraw.Draw(contact)
    draw.text((8,8),"ORIGINAL 256 x 576",fill="white");draw.text((272,8),"AI DETAIL / PROTECTED GRID",fill="white")
    contact.paste(before,(8,26),before);contact.paste(after,(272,26),after);contact.save(BATCH/"comparison.png")
    changed=sum(base[x,y]!=target[x,y] for y in range(before.height) for x in range(before.width))
entry={"source":job["source"],"size":[256,576],"before_sha256":expected,
       "after_sha256":hashlib.sha256(ready.read_bytes()).hexdigest(),"generated_sha256":hashlib.sha256(raw.read_bytes()).hexdigest()}
(BATCH/"manifest.json").write_text(json.dumps({"batch":"014","entries":[entry]},indent=2)+"\n",encoding="utf-8")
(BATCH/"grid-validation.json").write_text(json.dumps({"status":"candidate","tile_grid":[32,32],"protected_border_pixels":2,
    "placeholder_cells":reserved,"alpha_unchanged":True,"all_tile_borders_unchanged":True,"changed_pixels":changed,
    "requires_native_map_validation":True},indent=2)+"\n",encoding="utf-8")
print(json.dumps({"candidate_size":[256,576],"protected_placeholder_cells":len(reserved),"changed_pixels":changed}))
