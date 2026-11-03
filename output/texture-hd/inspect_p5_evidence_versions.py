from collections import defaultdict
from resume_p2_menu import ROOT,OUT,read,digest
paths=['p5-evidence/batch-817/native-review.json','p5-evidence/batch-817/effects-review.json','p5-evidence/batch-818/native-review.json','p5-evidence/remaining/reference-native-review.json','p5-evidence/remaining/media-native-review.json']
values=defaultdict(dict)
for path in paths:
 proof=read(OUT/path)
 for field in ('script_sha256','data_sha256','inputs'):
  for name,sha in proof.get(field,{}).items():values[name][path]=sha
for name,versions in values.items():
 if len(set(versions.values()))>1:print(name,versions,'current',digest(ROOT/name))
raw=read(OUT/'p5-evidence/remaining/reference-audit.json')['scanned_file_sha256']
print('CURRENT_RAW_DIFFS',[p for p,sha in raw.items() if digest(ROOT/p)!=sha])