"""Fit interior luminance refinement while locking every source UI edge."""
from pathlib import Path
import json,shutil
import numpy as np
from PIL import Image,ImageFilter,ImageDraw
from resume_p2_menu import ROOT,OUT,read,write,digest
WORK=OUT/'p2-dex-work'
audit=read(OUT/'p2-audit.json')['sources']
reports=[]
for number in (0,16,17):
 source=f'Graphics/Pictures/box{number}.png'
 row=next(r for r in audit if r['source']==source)
 job={'source':source,'generated':f'output/texture-hd/p2-dex-work/box{number}-generated.png',
      'prompt':(WORK/f'box{number}-prompt.txt').read_text(encoding='utf-8-sig').strip(),'tool':'built-in image_gen'}
 write(WORK/f'box{number}-job.json',job)
 before=Image.open(ROOT/source).convert('RGBA');base=np.asarray(before,dtype=np.int16);rgb=base[:,:,:3]
 proposal=Image.open(ROOT/job['generated']).convert('RGBA')
 assert abs(proposal.width/proposal.height-before.width/before.height)<.025
 proposal=proposal.resize(before.size,Image.Resampling.LANCZOS)
 protected=base[:,:,3]<255
 dx=np.max(np.abs(rgb[:,1:]-rgb[:,:-1]),axis=2)>16
 dy=np.max(np.abs(rgb[1:]-rgb[:-1]),axis=2)>16
 protected[:,1:]|=dx;protected[:,:-1]|=dx;protected[1:]|=dy;protected[:-1]|=dy
 protected=np.asarray(Image.fromarray(protected.astype(np.uint8)*255).filter(ImageFilter.MaxFilter(3)))>0
 protected[:56]=True;protected[-5:]=True;protected[:,:5]=True;protected[:,-5:]=True
 protected|=(rgb.min(axis=2)<13)|(rgb.max(axis=2)>242)
 original_gray=np.asarray(before.convert('L'),dtype=np.float32)
 proposed_gray=np.asarray(proposal.convert('L'),dtype=np.float32)
 delta=np.rint(np.clip((proposed_gray-original_gray)*.45,-12,12)).astype(np.int16)
 delta[protected]=0
 result=base.copy();result[:,:,:3]+=delta[:,:,None]
 assert result.min()>=0 and result.max()<=255
 assert np.array_equal(result[protected],base[protected])
 assert np.array_equal(result[:,:,3],base[:,:,3])
 assert np.max(np.abs(result-base))<=12
 after=Image.fromarray(result.astype(np.uint8))
 aliases=[r for r in audit if r['pixel_sha256']==row['pixel_sha256'] and r['size']==row['size']]
 for alias in aliases:
  assert digest(ROOT/alias['source'])==alias['sha256']
  batch=OUT/alias['batch']
  for folder in ('originals','ready','generated'):(batch/folder/alias['source']).parent.mkdir(parents=True,exist_ok=True)
  backup=batch/'originals'/alias['source'];ready=batch/'ready'/alias['source'];raw=batch/'generated'/alias['source']
  if not backup.exists():shutil.copy2(ROOT/alias['source'],backup)
  assert digest(backup)==alias['sha256']
  after.save(ready,optimize=True);shutil.copy2(ROOT/job['generated'],raw)
  path=batch/'manifest.json'
  manifest=read(path) if path.exists() else {'batch':batch.name[6:],'entries':[]}
  entry={'source':alias['source'],'size':alias['size'],'before_sha256':alias['sha256'],
         'after_sha256':digest(ready),'generated_sha256':digest(raw),'job':f'output/texture-hd/p2-dex-work/box{number}-job.json'}
  manifest['entries']=[e for e in manifest['entries'] if e['source']!=alias['source']]+[entry]
  write(path,manifest)
 sheet=Image.new('RGB',(before.width*2,before.height+20),'#303a45');draw=ImageDraw.Draw(sheet)
 draw.text((4,4),'ORIGINAL',fill='white');draw.text((before.width+4,4),'CANDIDATE',fill='white')
 sheet.paste(before,(0,20),before);sheet.paste(after,(before.width,20),after)
 sheet.save(WORK/f'box{number}-comparison.png')
 Image.fromarray((~protected).astype(np.uint8)*255).save(WORK/f'box{number}-editable-mask.png')
 reports.append({'source':source,'aliases':[a['source'] for a in aliases],'changed_pixels':int(np.count_nonzero(delta)),
  'max_rgb_delta':int(np.max(np.abs(delta))),'size_unchanged':True,'alpha_unchanged':True,'header_buttons_borders_and_strong_edges_unchanged':True,
  'state':'candidate_pending_native_review'})
write(WORK/'wallpaper-validation.json',reports)
print(json.dumps(reports))
