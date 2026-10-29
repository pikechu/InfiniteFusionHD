"""Prepare protected material details and a common water field for state variants."""
import shutil
import numpy as np
from PIL import Image,ImageDraw,ImageFilter
from resume_p2_menu import ROOT,OUT,read,write,digest
W=OUT/'p2-region-work';rows=read(W/'scope.json')['entries'];audit={r['source']:r for r in rows}
reports=[]

def fitted(source,generated):
 before=Image.open(ROOT/source).convert('RGBA');proposal=Image.open(ROOT/generated).convert('RGBA')
 bounds=before.getchannel('A').getbbox();gb=proposal.getchannel('A').point(lambda v:255 if v>=128 else 0).getbbox()
 assert bounds and gb
 size=(bounds[2]-bounds[0],bounds[3]-bounds[1]);crop=proposal.crop(gb)
 assert abs(crop.width/crop.height/(size[0]/size[1])-1)<.08
 layer=before.copy();layer.paste(crop.resize(size,Image.Resampling.LANCZOS),bounds[:2])
 return before,layer

def protected_edges(frames):
 rgb=frames[:,:,:,:3];mask=np.any(frames[:,:,:,3]<255,axis=0)
 dx=np.any(np.max(np.abs(rgb[:,:,1:]-rgb[:,:,:-1]),axis=3)>16,axis=0)
 dy=np.any(np.max(np.abs(rgb[:,1:]-rgb[:,:-1]),axis=3)>16,axis=0)
 mask[:,1:]|=dx;mask[:,:-1]|=dx;mask[1:]|=dy;mask[:-1]|=dy
 return np.asarray(Image.fromarray(mask.astype(np.uint8)*255).filter(ImageFilter.MaxFilter(7)))>0

def save(source,result,job,mask,kind):
 row=audit[source];batch=OUT/row['batch'];assert digest(ROOT/source)==row['sha256']
 before=Image.open(ROOT/source).convert('RGBA');base=np.asarray(before,dtype=np.int16)
 assert np.array_equal(base[:,:,3],result[:,:,3]) and np.array_equal(base[mask],result[mask])
 assert result.min()>=0 and result.max()<=255
 for folder in ('originals','ready','generated'):(batch/folder/source).parent.mkdir(parents=True,exist_ok=True)
 original=batch/'originals'/source;ready=batch/'ready'/source;raw=batch/'generated'/source
 if not original.exists():shutil.copy2(ROOT/source,original)
 assert digest(original)==row['sha256']
 after=Image.fromarray(result.astype(np.uint8));after.save(ready,optimize=True);shutil.copy2(ROOT/job['generated'],raw)
 record={'source':source,'size':row['size'],'before_sha256':row['sha256'],'after_sha256':digest(ready),'generated_sha256':digest(raw)}
 p=batch/'manifest.json';manifest=read(p) if p.exists() else {'batch':batch.name[6:],'status':'candidate_pending_review','entries':[]}
 manifest['entries']=[e for e in manifest['entries'] if e['source']!=source]+[record];write(p,manifest)
 key=source.rsplit('/',1)[1].rsplit('.',1)[0]
 contact=Image.new('RGB',(before.width*2,before.height+22),'#303a45');draw=ImageDraw.Draw(contact)
 draw.text((3,3),'ORIGINAL',fill='white');draw.text((before.width+3,3),'CANDIDATE',fill='white')
 contact.paste(before,(0,22),before);contact.paste(after,(before.width,22),after);contact.save(W/f'{key}-comparison.png')
 Image.fromarray(mask.astype(np.uint8)*255).save(W/f'{key}-protected-mask.png')
 reports.append({'source':source,'batch':row['batch'],'kind':kind,'state':'candidate_pending_review','alpha_unchanged':True,'protected_pixels_unchanged':True,
                 'changed_pixels':int(np.count_nonzero(np.any(result!=base,axis=2))),'max_rgb_delta':int(np.max(np.abs(result-base)))})

jobs=read(W/'card-jobs.json')['entries'];pairs=[fitted(j['source'],j['generated']) for j in jobs]
frames=np.stack([np.asarray(p[0],dtype=np.int16) for p in pairs]);mask=protected_edges(frames)
mask|=np.any((frames[:,:,:,:3]<19)|(frames[:,:,:,:3]>236),axis=(0,3))
labels=Image.new('L',(512,384));draw=ImageDraw.Draw(labels)
for rect in [(24,48,310,283),(326,48,480,90),(24,300,488,383)]:draw.rectangle(rect,fill=255)
mask|=np.asarray(labels)>0
fields=[]
for before,proposal in pairs:
 gray=np.asarray(proposal.convert('L'),dtype=np.float32);base=np.asarray(before.convert('L'),dtype=np.float32)
 residual=gray-base;residual-=np.median(residual[~mask]);fields.append(residual)
delta=np.rint(np.clip(np.median(fields,axis=0)*.65,-18,18)).astype(np.int16)
fade=np.zeros(mask.shape,dtype=np.float32);inside=(~mask).copy()
for step in range(24):
 fade+=inside/24
 shrunk=inside.copy();shrunk[1:]&=inside[:-1];shrunk[:-1]&=inside[1:];shrunk[:,1:]&=inside[:,:-1];shrunk[:,:-1]&=inside[:,1:]
 shrunk[[0,-1]]=False;shrunk[:,[0,-1]]=False;inside=shrunk
delta=np.rint(delta*fade).astype(np.int16);delta[mask]=0
results=frames.copy();results[:,:,:,:3]+=delta[None,:,:,None]
assert np.array_equal(np.diff(results,axis=0),np.diff(frames,axis=0))
for index,job in enumerate(jobs):save(job['source'],results[index],job,mask,'trainer_card_shared_material')
mapjob=read(W/'map-job.json');sources=['Graphics/Pictures/map/map.png','Graphics/Pictures/map/map_postgame.png']
mapframes=np.stack([np.asarray(Image.open(ROOT/s).convert('RGBA'),dtype=np.int16) for s in sources]);mask=protected_edges(mapframes)
rgb=mapframes[:,:,:,:3];water=(rgb[:,:,:,0]<120)&(rgb[:,:,:,1]>rgb[:,:,:,0]+30)&(rgb[:,:,:,2]>rgb[:,:,:,1]+12)
mask|=~np.all(water,axis=0);mask|=np.any((rgb<10)|(rgb>245),axis=(0,3))
_,proposal=fitted(sources[0],mapjob['generated']);gray=proposal.convert('L')
detail=np.asarray(gray,dtype=np.float32)-np.asarray(gray.filter(ImageFilter.GaussianBlur(3)),dtype=np.float32)
delta=np.rint(np.clip(detail*1.6,-8,8)).astype(np.int16);delta[mask]=0
mapresults=mapframes.copy();mapresults[:,:,:,:3]+=delta[None,:,:,None]
assert np.array_equal(mapresults[1]-mapresults[0],mapframes[1]-mapframes[0])
for i,source in enumerate(sources):save(source,mapresults[i],mapjob,mask,'region_map_common_water_detail')
write(W/'candidate-validation.json',{'status':'structural_checks_passed','entries':reports,'card_variant_signed_differences_identical':True,
 'map_pre_postgame_signed_differences_identical':True,'note':'No candidate is applied yet; native scene acceptance is still required.'})
paths={'before':{},'candidate':{}}
for row in rows:
 source=ROOT/row['source'];key=source.with_suffix('').as_posix().lower();paths['before'][key]=row['source']
 paths['candidate'][key]=(OUT/row['batch']/'ready'/row['source']).relative_to(ROOT).as_posix() if row['source'] in {r['source'] for r in reports} else row['source']
write(W/'native-paths.json',paths)
print(reports)

