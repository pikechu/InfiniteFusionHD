"""Inspect representative phases and archive every encoded/donor-cell hash."""
import hashlib,math
from PIL import Image,ImageDraw
from resume_p2_menu import ROOT,OUT,read,write
rows=[r for r in read(OUT/'p4-work/scope.json')['entries'] if r['stage']=='animated']
evidence=[];sheets=[]
for start in range(0,len(rows),24):
 part=rows[start:start+24];sheet=Image.new('RGB',(1080,math.ceil(len(part)/3)*170),'#353c46');draw=ImageDraw.Draw(sheet)
 for offset,row in enumerate(part):
  with Image.open(ROOT/row['source']) as im:
   encoded=im.n_frames if hasattr(im,'n_frames') else 1
   count=encoded if encoded>1 else row.get('donor_square_cells',1)
   hashes=[];selected=sorted(set([0,count//2,count-1]));images={}
   for index in range(count):
    if encoded>1:im.seek(index);frame=im.convert('RGBA')
    elif count>1:frame=im.crop((index*im.height,0,(index+1)*im.height,im.height)).convert('RGBA')
    else:frame=im.convert('RGBA')
    hashes.append(hashlib.sha256(frame.tobytes()).hexdigest())
    if index in selected:images[index]=frame.copy()
   evidence.append({'source':row['source'],'unit':'encoded GIF frame' if encoded>1 else 'unbound square donor cell','count':count,'sha256_in_order':hashes,'visually_sampled_indices':selected})
   x=offset%3*360;y=offset//3*170
   draw.text((x+2,y+2),row['source'].replace('Graphics/','')[-48:],fill='white')
   for j,index in enumerate(selected):
    frame=images[index];frame.thumbnail((112,135),Image.Resampling.NEAREST)
    sheet.paste(frame,(x+j*120+(112-frame.width)//2,y+32),frame)
    draw.text((x+j*120+2,y+17),f'{index}/{count-1}',fill='white')
 name=f'animated-phases-{start//24+1:02}.png';sheet.save(OUT/'p4-evidence'/name);sheets.append('output/texture-hd/p4-evidence/'+name)
write(OUT/'p4-evidence/animated-phase-review.json',{'scope':'First/middle/last visual samples plus ordered pixel hashes of all GIF frames and hypothetical square donor cells. Donor cells have no assigned active loader or duration. All game bytes are retained.','sources':evidence,'pages':sheets})
print({'sources':len(rows),'ordered_units':sum(e['count'] for e in evidence),'pages':sheets})