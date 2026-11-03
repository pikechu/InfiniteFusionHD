import json,hashlib
from pathlib import Path
root=Path.cwd();out=root/'output/texture-hd'
def read(p): return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
visual=read(out/'p4-work/visual-review.json')
visual['reviewed_pages']=sorted(set(visual['reviewed_pages']+["review-617-01.png","review-618-01.png","review-619-01.png","review-620-01.png","review-621-01.png","review-622-01.png","review-623-01.png","review-624-01.png","review-625-01.png","review-626-01.png","review-627-01.png","review-628-01.png","review-629-01.png","review-630-01.png"]))
visual['notes']['617-630']='Reviewed 2026-11-03: all remaining window skins preserve exact panel slicing, cursor and arrow geometry; early effect atlases preserve tiny particles, gradual alpha falloff, stars, rings, fire/ice/electric sequences and original cell gaps. Existing credits and distinct render styles retained.'
(out/'p4-work/visual-review.json').write_text(json.dumps(visual,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
for kind in ('icons','windows','effects','animated'):
 p=read(out/f'p4-evidence/{kind}-review.json');bad=[]
 for field in ('script_sha256','sidecar_sha256','data_sha256'):
  for path,expected in p.get(field,{}).items():
   if sha(root/path)!=expected: bad.append(path)
 print(json.dumps({'proof':kind,'status':p['status'],'changed_consumers':bad}))
protected={p.relative_to(root).as_posix():sha(p) for folder in ('Data/Scripts','Mods','Data/localization') for p in (root/folder).rglob('*') if p.is_file()}
protected.update({f'output/texture-hd/p{n}-progress.json':sha(out/f'p{n}-progress.json') for n in (1,2,3)})
p=out/'p4-work/resumed-protected.json'
if not p.exists():p.write_text(json.dumps({'files':protected},indent=2)+'\n',encoding='utf-8')