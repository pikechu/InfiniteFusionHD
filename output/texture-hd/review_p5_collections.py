"""Archive ordered donor-grid hashes and bounded phase samples of source collections."""
from collections import defaultdict
import hashlib
import math
from PIL import Image, ImageDraw
from resume_p2_menu import ROOT, OUT, read, write


def signature(image):return hashlib.sha256(image.convert('RGBA').tobytes()).hexdigest()


def main():
    rows = read(OUT / 'p5-work/remaining-scope.json')['entries']
    by_signature = defaultdict(list)
    for row in rows:by_signature[(tuple(row['size']), row['rgba_sha256'])].append(row['source'])
    scale_relationships = []
    for row in rows:
        w,h=row['size']
        if w>320 or h>320:continue
        for scale in (3,10):
            if scale==10 and (w,h)==(96,96):continue
            size=(w*scale,h*scale)
            if not any(s==size for s,_ in by_signature):continue
            if scale==3 and 'nearest_neighbor_3x_rgba_sha256' in row:key=row['nearest_neighbor_3x_rgba_sha256']
            else:
                with Image.open(ROOT/row['source']) as im:key=signature(im.convert('RGBA').resize(size,Image.Resampling.NEAREST))
            matches=by_signature.get((size,key),[])
            if matches:scale_relationships.append({'source':row['source'],'integer_scale':scale,'targets':matches,'rgba_sha256':key})
    selected=[r for r in rows if r['size'][1]>4096 or r['source'].startswith('Graphics/Animated Sprites/') or
              (r['stage']=='source96' and (r['size'][0]>288 or r['size'][1]>288))]
    records=[];pages=[]
    for start in range(0,len(selected),18):
        part=selected[start:start+18];sheet=Image.new('RGB',(1440,math.ceil(len(part)/3)*240),'#353c46');draw=ImageDraw.Draw(sheet)
        for offset,row in enumerate(part):
            x=offset%3*480;y=offset//3*240
            draw.text((x+2,y+2),row['source'].split('/')[-1][-68:],fill='white')
            w,h=row['size'];samples=[];hashes=[];unit='spatial bitmap sample'
            with Image.open(ROOT/row['source']) as im:
                rgba=im.convert('RGBA')
                if h>4096:
                    height=min(h,max(128,w*2));ys=[0,((h-height)//2//32)*32,((h-height)//32)*32]
                    boxes=[(0,yy,w,min(h,yy+height)) for yy in ys]
                elif w%96==0 and h%96==0:
                    unit='hypothetical 96px donor cell; no assigned timing'
                    cols=w//96;count=cols*(h//96);indices=sorted(set([0,count//2,count-1]))
                    boxes=[((i%cols)*96,(i//cols)*96,(i%cols+1)*96,(i//cols+1)*96) for i in indices]
                    for i in range(count):hashes.append(signature(rgba.crop(((i%cols)*96,(i//cols)*96,(i%cols+1)*96,(i//cols+1)*96))))
                elif w>h*2:
                    side=h;xs=[0,(w-side)//2,w-side];boxes=[(xx,0,xx+side,h) for xx in xs]
                else:
                    side=min(w,h);ys=[0,(h-side)//2,h-side];boxes=[(0,yy,w,min(h,yy+side)) for yy in ys]
                for j,box in enumerate(boxes):
                    sample=rgba.crop(box);samples.append({'box':box,'rgba_sha256':signature(sample)})
                    sample.thumbnail((152,202),Image.Resampling.NEAREST)
                    sheet.paste(sample,(x+j*160+(152-sample.width)//2,y+35),sample)
                    draw.text((x+j*160+2,y+18),str(box)[:25],fill='white')
            records.append({'source':row['source'],'unit':unit,'samples':samples,'ordered_donor_cell_sha256':hashes})
        path=f'output/texture-hd/p5-evidence/remaining/collection-phases-{start//18+1:02}.png';sheet.save(ROOT/path);pages.append(path)
    write(OUT/'p5-evidence/remaining/collection-phase-review.json',{'sources':records,'pages':pages,'scale_relationships':scale_relationships,
          'scope':'Spatial phase samples and ordered hypothetical donor-grid hashes supplement full-file pixel identity. These samples do not certify an unspecified animation clock, ordinary resource binding, every tile seam or every spatial region of an unbound tall source atlas.'})
    print({'phase_sources':len(records),'phase_pages':pages,'ordered_donor_cells':sum(len(r['ordered_donor_cell_sha256']) for r in records),'exact_scale_relationships':len(scale_relationships)},flush=True)


if __name__=='__main__':main()
