"""Compact full P3 traces losslessly while retaining small recovery summaries."""
import gzip,hashlib
from resume_p2_menu import OUT,ROOT,read,write,digest
E=OUT/'p3-evidence/remaining'
records=[]
for name,keys in [('characters',['poses','decoded','resource_switches']),('outfits',['poses']),('battle-art',['selection_states','cases']),('ui',[])]:
 path=E/f'{name}-review.json';raw=path.read_bytes();doc=read(path)
 if 'full_trace_archive' in doc:continue
 archive=E/f'{name}-full.json.gz';archive.write_bytes(gzip.compress(raw,compresslevel=9,mtime=0));assert gzip.decompress(archive.read_bytes())==raw
 doc['full_trace_archive']={'path':archive.relative_to(ROOT).as_posix(),'raw_sha256':hashlib.sha256(raw).hexdigest(),'archive_sha256':digest(archive)}
 for key in keys:doc[key+'_count']=len(doc[key]);del doc[key]
 write(path,doc)
 records.append({'name':name,'original_bytes':len(raw),'archive_bytes':archive.stat().st_size,'summary_bytes':path.stat().st_size})
 p=E/'periodic-cache-cleanup.json';previous=read(p) if p.exists() else {'records':[],'images_deleted':0,'temporary_logs_remaining':0}
 previous['records']+=records;previous['bytes_reclaimed_losslessly']=sum(r['original_bytes']-r['archive_bytes']-r['summary_bytes'] for r in previous['records']);write(p,previous)
 records=[]
print(read(E/'periodic-cache-cleanup.json'))
