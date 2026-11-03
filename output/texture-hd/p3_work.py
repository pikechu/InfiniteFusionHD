"""Freeze P3 hashes and review batch 152 before any source replacement."""
import hashlib,subprocess,shutil
from pathlib import Path
from PIL import Image,ImageDraw
from resume_p2_menu import ROOT,OUT,read,write,digest
from update_p2_progress import self_check,update_progress
W=OUT/'p3-work';E=OUT/'p3-evidence/batch-152'
GIT='D:/Users/meikun.zhang/AppData/Local/Programs/Git/mingw64/bin/git.exe'


def main():
 self_check();W.mkdir(exist_ok=True);E.mkdir(parents=True,exist_ok=True)
 assert read(OUT/'p2-progress.json')['status']=='completed'
 plan=read(OUT/'execution-plan/plan.json');batches=[r for r in plan['batch_index'] if r['priority']=='P3']
 tracked=subprocess.run([GIT,'ls-tree','-r','-z','codex/texture-hd-p2','--','Graphics'],cwd=ROOT,check=True,capture_output=True,timeout=30).stdout
 blobs={row.split(b'\t',1)[1].decode('utf-8'):row.split(b'\t',1)[0].split()[2].decode() for row in tracked.split(b'\0') if row}
 audit_path=OUT/'p3-audit.json'
 if not audit_path.exists():
  sources=[];changes=[]
  for batch in batches:
   record=read(OUT/f"execution-plan/batches/{batch['id']}.json")
   for entry in record['entries']:
    content=(ROOT/entry['source']).read_bytes();sha=hashlib.sha256(content).hexdigest();blob=hashlib.sha1(f'blob {len(content)}\0'.encode()+content).hexdigest()
    original=blobs.get(entry['source']);external=original is not None and original!=blob
    row={**entry,'batch':batch['id'],'stage':record['stage'],'method':record['method'],'sha256':sha,'git_blob':blob,
         'reference_blob':original,'external_change':external,'review_status':'not_started'}
    sources.append(row)
    if external:changes.append(entry['source'])
  assert len(sources)==9181 and len({r['source'] for r in sources})==9181
  write(audit_path,{'authorized_scope':'P3 batches 152-540','date':'2026-10-30','total':9181,'sources':sources,'external_changes_preserved':changes})
 audit=read(audit_path);scope=[]
 for row in audit['sources']:
  if row['batch']!='batch-152':continue
  assert not row['external_change'],'External change needs review: '+row['source']
  path=ROOT/row['source'];assert digest(path)==row['sha256']
  with Image.open(path) as im:
   im.load();assert list(im.size)==row['size'];rgba=im.convert('RGBA')
   filename=path.stem
   if filename.startswith(('trainer','vsTrainer','intro')):kind='static';grid=[1,1]
   elif filename.startswith('trback'):kind='trainer_throw';grid=[5,1]
   else:kind='charset';grid=[4,4]
   assert im.width%grid[0]==0 and im.height%grid[1]==0
   cell=[im.width//grid[0],im.height//grid[1]]
   cells=[rgba.crop((x*cell[0],y*cell[1],(x+1)*cell[0],(y+1)*cell[1])) for y in range(grid[1]) for x in range(grid[0])]
   scope.append({**row,'encoded_frames':getattr(im,'n_frames',1),'grid':grid,'cell_size':cell,'kind':kind,
    'alpha_sha256':hashlib.sha256(rgba.getchannel('A').tobytes()).hexdigest(),
    'cell_bounds':[c.getchannel('A').getbbox() for c in cells],'cell_rgba_sha256':[hashlib.sha256(c.tobytes()).hexdigest() for c in cells]})
  target=OUT/'batch-152/originals'/row['source'];target.parent.mkdir(parents=True,exist_ok=True)
  if not target.exists():shutil.copy2(path,target)
  assert digest(target)==row['sha256']
 assert len(scope)==20
 for start in (0,10):
  sheet=Image.new('RGB',(1400,940),'#353c46');draw=ImageDraw.Draw(sheet)
  for i,row in enumerate(scope[start:start+10]):
   with Image.open(ROOT/row['source']) as im:im=im.convert('RGBA');im.thumbnail((276,430))
   x=i%5*280;y=i//5*470;sheet.paste(im,(x,y+34),im)
   draw.text((x+2,y+2),row['source'].replace('Graphics/Alternate Trainers/','')[-44:],fill='white')
   draw.text((x+2,y+17),f"{row['kind']} grid={row['grid']} cell={row['cell_size']}",fill='white')
  sheet.save(E/f'originals-{start//10+1}.png')
 write(W/'batch-152-scope.json',{'status':'audited','entries':scope})
 protected=W/'session-protected.json'
 if not protected.exists():write(protected,{'files':{p.relative_to(ROOT).as_posix():digest(p) for folder in ('Data/Scripts','Mods','Data/localization') for p in (ROOT/folder).rglob('*') if p.is_file()}})
 progress=update_progress('P3');write(W/'resume.json',{'status':'in_progress','next_batch':progress['next_batch'],'candidate_pending_review':[]})
 print({'p3_baseline':9181,'external_changes':audit['external_changes_preserved'],'batch_scope':20,'kinds':{kind:sum(r['kind']==kind for r in scope) for kind in ('charset','static','trainer_throw')}})


if __name__=='__main__':main()
