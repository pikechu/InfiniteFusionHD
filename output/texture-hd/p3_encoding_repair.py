"""Repair a falsely named image container without changing a single RGBA pixel."""
from PIL import Image
from resume_p2_menu import ROOT,OUT,read,write,digest
source='Graphics/Pictures/Constellations/295.130a.png'
row=next(r for r in read(OUT/'p3-work/remaining-scope.json')['entries'] if r['source']==source)
batch=OUT/row['batch'];before=batch/'originals'/source;ready=batch/'ready'/source
assert digest(before)==row['sha256']==digest(ROOT/source)
with Image.open(before) as original:
 assert original.format=='WEBP' and getattr(original,'n_frames',1)==1
 pixels=original.convert('RGBA');ready.parent.mkdir(parents=True,exist_ok=True);pixels.save(ready,format='PNG',compress_level=9)
with Image.open(ready) as repaired:
 assert repaired.format=='PNG' and repaired.size==pixels.size and repaired.convert('RGBA').tobytes()==pixels.tobytes()
entry={'source':source,'size':row['size'],'before_sha256':digest(before),'after_sha256':digest(ready),'generated_sha256':None,
       'method':'lossless_container_repair','reason':'WEBP payload under .png filename rejected by native SDL; encode identical decoded RGBA as a real PNG.'}
write(batch/'manifest.json',{'batch':row['batch'][6:],'status':'candidate_pending_native','method':'Lossless container correction, no redraw or AI pixel edit','entries':[entry]})
write(OUT/'p3-work/encoding-repair.json',{'status':'candidate_pending_native','batch':row['batch'],'entry':entry,'ready':ready.relative_to(ROOT).as_posix(),
 'rgba_identical':True,'alpha_identical':True,'size_identical':True,'original_format':'WEBP','ready_format':'PNG'})
print({'repair':source,'batch':row['batch'],'RGBA':'identical','status':'pending_native'})
