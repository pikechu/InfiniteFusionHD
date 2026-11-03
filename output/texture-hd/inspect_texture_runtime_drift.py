from pathlib import Path
from resume_p2_menu import ROOT,OUT,read,digest
changed=[]
for n in range(1,858):
 p=OUT/f'batch-{n:03}/manifest.json'
 if not p.exists():continue
 for e in read(p)['entries']:
  current=digest(ROOT/e['source'])
  if current!=e['after_sha256']:changed.append({'batch':n,'source':e['source'],'actual':current,'accepted':e['after_sha256'],'matches_original':current==e['before_sha256']})
print(changed)