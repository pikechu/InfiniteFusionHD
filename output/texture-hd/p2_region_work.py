"""Audit P2 batches 094-102 and preserve the source snapshot."""
from pathlib import Path
import math
from PIL import Image,ImageDraw
from resume_p2_menu import ROOT,OUT,read,write,digest
W=OUT/'p2-region-work';E=OUT/'p2-evidence/region';W.mkdir(exist_ok=True);E.mkdir(exist_ok=True)
audit=read(OUT/'p2-audit.json');completed={}
for n in range(58,94):
 receipt=read(OUT/f'batch-{n:03}/validation.json');assert receipt['status']=='completed'
 for entry in receipt['entries']:completed[entry['source']]=entry
changes=[]
for row in audit['sources']:
 d=completed.get(row['source']);expected=d['after_sha256'] if d and d['status']=='applied' else row['sha256'];current=digest(ROOT/row['source'])
 if current!=expected:changes.append({'source':row['source'],'expected':expected,'current':current,'completed':bool(d)})
rows=[]
for n in range(94,103):
 plan=read(OUT/f'execution-plan/batches/batch-{n:03}.json');assert plan['status']=='planned'
 for entry in plan['entries']:
  row=next(r for r in audit['sources'] if r['source']==entry['source'])
  with Image.open(ROOT/row['source']) as im:im.load();assert list(im.size)==row['size'];frames=getattr(im,'n_frames',1)
  rows.append({**row,'encoded_frames':frames})
assert len(rows)==202
assert not any(c['source'] in {r['source'] for r in rows} for c in changes),'Concurrent changes in current scope'
for start in range(0,202,12):
 sheet=Image.new('RGB',(1200,936),'#303a45');draw=ImageDraw.Draw(sheet)
 for i,row in enumerate(rows[start:start+12]):
  im=Image.open(ROOT/row['source']).convert('RGBA');im.thumbnail((292,282));x=i%4*300;y=i//4*312;sheet.paste(im,(x,y+24),im)
  draw.text((x+2,y+2),f"{start+i} {row['batch'][6:]} {row['source'].replace('Graphics/','')}"[-49:],fill='white')
 sheet.save(E/f'originals-{start//12+1:02}.png')
write(W/'scope.json',{'status':'audited','date':'2026-10-29','entries':rows,'all_p2_sources_checked':2223,'concurrent_changes_preserved':changes})
write(W/'session-protected.json',{'files':{p.relative_to(ROOT).as_posix():digest(p) for directory in ('Data/Scripts','Mods','Data/localization') for p in (ROOT/directory).rglob('*') if p.is_file()}})
print({'scope':len(rows),'external_changes':changes,'preview_sheets':17})
