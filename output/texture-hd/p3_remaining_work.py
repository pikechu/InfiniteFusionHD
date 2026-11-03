"""Resume the fixed P3 scope, inspect image structure, and build review pages."""
from pathlib import Path
import hashlib,re,shutil,math
from collections import Counter
from PIL import Image,ImageDraw
from resume_p2_menu import ROOT,OUT,read,write,digest
W=OUT/'p3-work';E=OUT/'p3-evidence/remaining'


def structure(row,im):
 source=row['source'];name=Path(source).stem.lower();stage=row['stage'];w,h=im.size
 if stage in ('npc','follower'):
  if name.startswith('leagueform') or re.fullmatch(r'trainer\d+[a-z]?',name) or ('/Alternate Trainers/' in source and (name.startswith(('trainer','intro','vstrainer')) or '/Pictures/' in source or '/Transitions/' in source)):kind='static';grid=[1,1]
  elif name=='bw_giovanni_overworlds_by_segesi-d42c38v':kind='compatibility_sheet';grid=[3,3]
  elif w==h*5 and (name.startswith('trback') or name.endswith('_back')):kind='trainer_throw';grid=[5,1]
  else:kind='charset';grid=[4,4]
 elif stage=='outfit':
  if '/balls/' in source:kind='ball_overlay';grid=[1,1]
  elif name.startswith(('clothes_trainer_','hair_trainer_','hat_trainer_')):kind='portrait_layer';grid=[1,1]
  elif '/hat/' in source:kind='wearable';grid=[1,4]
  elif '/hair/' in source:kind='wearable';grid=[4,4]
  else:kind='clothing';grid=[4,4]
 elif stage in ('pokemon_alt','special'):kind='battle_bitmap';grid=[1,1]
 elif '/Pictures/Intro/INTRO-' in source:kind='movie_frame';grid=[1,1]
 else:kind='ui';grid=[1,1]
 return kind,grid,[w//grid[0],h//grid[1]]


def main():
 E.mkdir(parents=True,exist_ok=True);audit=read(OUT/'p3-audit.json');rows=[];seen={};pages=[];changes=[]
 for i,row in enumerate(audit['sources']):
  current=digest(ROOT/row['source'])
  if current!=row['sha256']:changes.append({'source':row['source'],'current':current,'baseline':row['sha256']})
 assert not changes,'Concurrent P3 image changes: '+str(changes[:10])
 for n in range(153,541):
  plan=read(OUT/f'execution-plan/batches/batch-{n:03}.json');assert plan['priority']=='P3' and plan['status']=='planned'
  batch=OUT/f'batch-{n:03}';review=[]
  for item in plan['entries']:
   row=next(r for r in audit['sources'] if r['source']==item['source']);source=ROOT/row['source']
   with Image.open(source) as im:
    im.load();assert list(im.size)==row['size'];rgba=im.convert('RGBA');kind,grid,cell=structure(row,im)
    pixel=hashlib.sha256(rgba.tobytes()).hexdigest();alpha=rgba.getchannel('A')
    frames=getattr(im,'n_frames',1)
    meta={**row,'kind':kind,'grid':grid,'cell_size':cell,'encoded_frames':frames,'pixel_sha256':pixel,
          'alpha_sha256':hashlib.sha256(alpha.tobytes()).hexdigest(),'bounds':alpha.getbbox(),'mode':im.mode,
          'grid_remainder':[im.width%grid[0],im.height%grid[1]]}
    if pixel in seen:meta['same_pixels_as']=seen[pixel]
    else:seen[pixel]=row['source'];review.append(meta)
    rows.append(meta)
   backup=batch/'originals'/row['source'];backup.parent.mkdir(parents=True,exist_ok=True)
   if not backup.exists():shutil.copy2(source,backup)
   assert digest(backup)==row['sha256']
  # Each original occurs on a review page unless its complete RGBA matches an
  # already displayed source; those links are kept individually in the scope.
  cells_per_page=24 if plan['stage']=='ui_other' else 32
  cols=6 if cells_per_page==24 else 8;cw=256 if cells_per_page==24 else 200;ch=224
  for start in range(0,len(review),cells_per_page):
   part=review[start:start+cells_per_page];sheet=Image.new('RGB',(cols*cw,math.ceil(len(part)/cols)*ch),'#353c46');draw=ImageDraw.Draw(sheet)
   for index,row in enumerate(part):
    with Image.open(ROOT/row['source']) as im:
     a=im.convert('RGBA')
     if row['kind'] in ('battle_bitmap','portrait_layer','static','ball_overlay') and a.getchannel('A').getbbox():a=a.crop(a.getchannel('A').getbbox())
     a.thumbnail((cw-4,ch-32))
    x=index%cols*cw;y=index//cols*ch;sheet.paste(a,(x+(cw-a.width)//2,y+30),a)
    draw.text((x+2,y+1),row['source'].replace('Graphics/','')[-31:],fill='white')
    draw.text((x+2,y+14),f"{row['kind']} {row['size'][0]}x{row['size'][1]}",fill='white')
   name=f'review-{n:03}-{start//cells_per_page+1:02}.png';sheet.save(E/name)
   pages.append({'path':(E/name).relative_to(ROOT).as_posix(),'batch':f'batch-{n:03}','sources':[r['source'] for r in part]})
  if n%25==0:print(f'AUDIT {n} sources={len(rows)} review_pages={len(pages)}',flush=True)
 assert len(rows)==9161
 write(W/'remaining-scope.json',{'date':'2026-10-30','status':'audited','entries':rows,'review_pages':pages,'unique_rgba_in_remaining':len(seen),'source_hashes_checked':9181})
 native={stage:[{k:r[k] for k in ('source','batch','size','kind','grid','cell_size','encoded_frames','sha256','grid_remainder')} for r in rows if r['stage']==stage] for stage in {r['stage'] for r in rows}}
 write(W/'remaining-native-index.json',native)
 protected=W/'remaining-session-protected.json';write(protected,{'files':{p.relative_to(ROOT).as_posix():digest(p) for folder in ('Data/Scripts','Mods','Data/localization') for p in (ROOT/folder).rglob('*') if p.is_file()}})
 print({'remaining':len(rows),'unique_rgba':len(seen),'pages':len(pages),'kinds':dict(Counter(r['kind'] for r in rows)),'encoded_animations':[r['source'] for r in rows if r['encoded_frames']>1]})


if __name__=='__main__':main()
