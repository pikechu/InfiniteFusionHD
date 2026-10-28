"""Use AI fine texture inside original atlas geometry; preserve seams and alpha."""
from pathlib import Path
from PIL import Image, ImageFilter, ImageDraw
import hashlib
import json
import sys
import shutil
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
WORK = OUT / "p1-map-work"
batch_id = f"batch-{int(sys.argv[1]):03}"
tasks = [t for t in json.loads((WORK/"tasks.json").read_text(encoding="utf-8")) if t["batch"] == batch_id]
assert tasks
source = ROOT / tasks[0]["source"]
assert hashlib.sha256(source.read_bytes()).hexdigest() == tasks[0]["source_sha256"]
with Image.open(source) as image:
    before = image.convert("RGBA")
proposal = before.copy()
jobs = []
for task in tasks:
    with Image.open(ROOT/task["page_source"]) as page:
        if page.getchannel("A").getbbox() is None or len(page.getcolors(page.width * page.height) or []) <= 2:
            jobs.append({**task,"status":"preserved_empty_or_flat_page"})
            continue
    job = json.loads((WORK/(task["key"]+".json")).read_text(encoding="utf-8"))
    with Image.open(ROOT/job["generated"]) as generated:
        assert abs(generated.width/generated.height-1.5)<.015, task["key"]
        page = generated.convert("RGBA").resize((1536,1024),Image.Resampling.LANCZOS)
    for region in task["regions"]:
        proposal.paste(page.crop(tuple(region["page_box"])),tuple(region["source_box"][:2]))
    jobs.append(job)

base = np.asarray(before,dtype=np.int16)
rgb = base[:,:,:3]
edge = np.zeros(base.shape[:2],dtype=bool)
horizontal = np.max(np.abs(rgb[:,1:]-rgb[:,:-1]),axis=2)>20
vertical = np.max(np.abs(rgb[1:]-rgb[:-1]),axis=2)>20
edge[:,1:] |= horizontal; edge[:,:-1] |= horizontal
edge[1:] |= vertical; edge[:-1] |= vertical
edge |= base[:,:,3] < 255
protected = np.asarray(Image.fromarray(edge.astype(np.uint8)*255).filter(ImageFilter.MaxFilter(5)))>0
height,width=base.shape[:2]
yy,xx=np.indices((height,width))
distance=np.minimum.reduce([xx%32,31-xx%32,yy%32,31-yy%32])
protected |= distance<2
if height % 32:
    protected[height - height % 32:] = True
light=(rgb[:,:,0]*.299+rgb[:,:,1]*.587+rgb[:,:,2]*.114)
protected |= (light<18)|(light>240)
reserved=[]
for y in range(0,height,32):
    for x in range(0,width,32):
        tile=base[y:y+32,x:x+32]
        red=(tile[:,:,0]>200)&(tile[:,:,1]<90)&(tile[:,:,2]<90)&(tile[:,:,3]>200)
        if np.count_nonzero(red)>20 or len(np.unique(tile.reshape(-1,4),axis=0))<=2:
            protected[y:y+32,x:x+32]=True
            reserved.append([x,y,min(32,width-x),min(32,height-y)])
# Only a bounded luminance texture is transferred. The AI proposal cannot replace
# any source geometry, color palette, label, transparent silhouette or tile border.
luma=proposal.convert("L")
high=np.asarray(luma,dtype=np.float32)-np.asarray(luma.filter(ImageFilter.GaussianBlur(1.2)),dtype=np.float32)
weight=np.clip((distance-1)/4,0,1)
delta=np.rint(np.clip(high*.65,-10,10)*weight).astype(np.int16)
delta[protected]=0
result=base.copy()
result[:,:,:3]=np.clip(rgb+delta[:,:,None],0,255)
after=Image.fromarray(result.astype(np.uint8),"RGBA")
cache={}
for y in range(0,height,32):
    for x in range(0,width,32):
        box=(x,y,min(x+32,width),min(y+32,height));tile=before.crop(box)
        key=(tile.size,tile.tobytes())
        mask=protected[y:box[3],x:box[2]]
        if key in cache:cache[key]['protected'] |= mask
        else:cache[key]={'pixels':np.array(after.crop(box)),'base':np.array(tile),'protected':mask.copy()}
for item in cache.values():
    item['pixels'][item['protected']]=item['base'][item['protected']]
    item['image']=Image.fromarray(item['pixels'],'RGBA')
for y in range(0,height,32):
    for x in range(0,width,32):
        box=(x,y,min(x+32,width),min(y+32,height));tile=before.crop(box)
        after.paste(cache[(tile.size,tile.tobytes())]['image'],(x,y))
final=np.asarray(after,dtype=np.int16)
assert np.array_equal(final[:,:,3],base[:,:,3])
assert np.array_equal(final[protected],base[protected])
assert np.max(np.abs(final[:,:,:3]-rgb))<=10
for x,y,w,h in reserved:assert before.crop((x,y,x+w,y+h)).tobytes()==after.crop((x,y,x+w,y+h)).tobytes()
batch=OUT/batch_id;backup=batch/'originals'/tasks[0]['source'];ready=batch/'ready'/tasks[0]['source'];raw=batch/'generated'/tasks[0]['source']
for path in (backup,ready,raw):path.parent.mkdir(parents=True,exist_ok=True)
if backup.exists():assert hashlib.sha256(backup.read_bytes()).hexdigest()==tasks[0]['source_sha256']
else:shutil.copy2(source,backup)
after.save(ready,optimize=True);proposal.save(raw,optimize=True)
entry={'source':tasks[0]['source'],'size':list(before.size),'before_sha256':tasks[0]['source_sha256'],
       'after_sha256':hashlib.sha256(ready.read_bytes()).hexdigest(),'generated_sha256':hashlib.sha256(raw.read_bytes()).hexdigest()}
(batch/'manifest.json').write_text(json.dumps({'batch':batch_id.split('-')[1],'entries':[entry]},indent=2)+'\n',encoding='utf-8')
(batch/'jobs.json').write_text(json.dumps({'batch':batch_id.split('-')[1],'method':'built-in image_gen fine-texture proposal, original geometry protected','entries':[{'source':tasks[0]['source'],'generated':raw.relative_to(ROOT).as_posix(),'pages':jobs}]},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
report={'status':'candidate','size':list(before.size),'tile_grid':[32,32],'tile_border_pixels_unchanged':2,'alpha_unchanged':True,
        'partial_tail_rows_unchanged':True,
        'source_strong_edges_unchanged':True,'max_rgb_change':int(np.max(np.abs(final[:,:,:3]-rgb))),
        'reserved_or_flat_cells':len(reserved),'changed_pixels':int(np.count_nonzero(np.any(final!=base,axis=2))),
        'identical_source_tiles_consistent':True,'requires_native_map_validation':True}
(batch/'grid-validation.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
contact=Image.new('RGB',(536,1060),'#353c45');draw=ImageDraw.Draw(contact)
draw.text((8,8),'ORIGINAL',fill='white');draw.text((272,8),'GUARDED AI DETAIL',fill='white')
contact.paste(before.crop((0,0,256,min(1024,height))),(8,28),before.crop((0,0,256,min(1024,height))))
contact.paste(after.crop((0,0,256,min(1024,height))),(272,28),after.crop((0,0,256,min(1024,height))))
contact.save(batch/'comparison-first-strip.png')
print(json.dumps(report))
