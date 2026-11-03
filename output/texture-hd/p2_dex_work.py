"""Inspect the fixed P2 dex/storage/naming stage and keep source hashes."""
from pathlib import Path
import json,hashlib,math
from PIL import Image,ImageDraw
from resume_p2_menu import ROOT,OUT,read,write,digest
WORK=OUT/'p2-dex-work'
EVIDENCE=OUT/'p2-evidence/dex'
WORK.mkdir(exist_ok=True)
EVIDENCE.mkdir(exist_ok=True)
audit=read(OUT/'p2-audit.json')
receipts={}
for p in OUT.glob('batch-*/validation.json'):
 d=read(p)
 if d.get('status')=='completed':
  for e in d.get('entries',[]):receipts[e['source']]=e
all_verified=0
for row in audit['sources']:
 d=receipts.get(row['source'])
 expected=d['after_sha256'] if d and d['status']=='applied' else row['sha256']
 assert digest(ROOT/row['source'])==expected,'External change: '+row['source']
 all_verified+=1
rows=[r for r in audit['sources'] if 77<=int(r['batch'][6:])<=93]
assert len(rows)==374
for row in rows:
 with Image.open(ROOT/row['source']) as im:
  im.load();assert list(im.size)==row['size']
  row['encoded_frames']=getattr(im,'n_frames',1)
  row['mode']=im.mode
  assert row['encoded_frames']==1
for start in range(0,len(rows),12):
 group=rows[start:start+12]
 sheet=Image.new('RGB',(1200,936),'#303a45');draw=ImageDraw.Draw(sheet)
 for index,row in enumerate(group):
  im=Image.open(ROOT/row['source']).convert('RGBA');im.thumbnail((292,282))
  x=(index%4)*300;y=(index//4)*312
  sheet.paste(im,(x,y+24),im)
  draw.text((x+2,y+2),f"{start+index} {row['batch'][6:]} {row['source'].replace('Graphics/','')}"[-48:],fill='white')
 sheet.save(EVIDENCE/f'originals-{start//12+1:02}.png')
write(WORK/'scope.json',{'status':'hashes_verified','all_p2_sources':all_verified,'files':len(rows),'entries':rows,
 'asset_rule':'PNG sibling state sets and frame sheets require consumer-level checks; encoded frame count alone is not animation validation.'})
write(WORK/'session-protected.json',{'files':{str(p.relative_to(ROOT)).replace('\\','/'):digest(p) for folder in ('Data/Scripts','Mods','Data/localization') for p in (ROOT/folder).rglob('*') if p.is_file()}})
print(json.dumps({'all_p2_verified':all_verified,'stage_files':len(rows),'preview_sheets':math.ceil(len(rows)/12)}))
