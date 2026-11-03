"""Pack source atlas strips for AI detail proposals without changing game assets."""
from pathlib import Path
from PIL import Image
import hashlib
import json

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
WORK = OUT / "p1-map-work"
WORK.mkdir(exist_ok=True)
usage = json.loads((OUT / "p1-evidence/planned-map-usage.json").read_text())
audit = {row["source"]: row for row in json.loads((OUT / "p1-audit.json").read_text(encoding="utf-8"))["sources"]}
tasks = []
for row in usage:
    if "/Tilesets/" not in row["source"] or row["maps_using_tileset_record"] == 0:
        continue
    source = ROOT / row["source"]
    assert hashlib.sha256(source.read_bytes()).hexdigest() == audit[row["source"]]["sha256"]
    folder = WORK / row["batch"]
    folder.mkdir(exist_ok=True)
    with Image.open(source) as image:
        image = image.convert("RGBA")
        assert image.width == 256
        page_count = (image.height + 6143) // 6144
        for page_index in range(page_count):
            canvas = Image.new("RGBA", (1536,1024))
            regions = []
            for column in range(6):
                top = (page_index*6+column)*1024
                if top >= image.height:
                    break
                height = min(1024,image.height-top)
                box = (0,top,256,top+height)
                canvas.paste(image.crop(box),(column*256,0))
                regions.append({"source_box":list(box),"page_box":[column*256,0,column*256+256,height]})
            key = f"{row['batch']}-page-{page_index+1:02}"
            path = folder / f"page-{page_index+1:02}-source.png"
            canvas.save(path)
            tasks.append({"key":key,"batch":row["batch"],"source":row["source"],
                          "page_source":path.relative_to(ROOT).as_posix(),"regions":regions,
                          "page_size":[1536,1024],"source_sha256":audit[row["source"]]["sha256"]})
(WORK/"tasks.json").write_text(json.dumps(tasks,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(json.dumps({"atlas_files":len(set(t['source'] for t in tasks)),"pages":len(tasks),
                  "tasks":[{"key":t['key'],"page_source":t['page_source']} for t in tasks]}))
