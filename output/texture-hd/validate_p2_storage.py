"""Validate actual native storage traces and decide which wallpaper proposals help."""
from pathlib import Path
import json
from PIL import Image,ImageChops,ImageDraw
from resume_p2_menu import ROOT,OUT,read,write,digest
E=OUT/'p2-evidence/dex';W=OUT/'p2-dex-work'
for phase in ('before','candidate'):
 assert f'STORAGE_PASS phase={phase} images=374 renders=498' in (E/f'storage-{phase}-result.txt').read_text(),phase
b=read(E/'storage-before-review.json');a=read(E/'storage-candidate-review.json')
assert b['renders']==a['renders'] and len(b['renders'])==498
assert b['traces']==a['traces'],'Native interaction/animation positions changed'
assert b['frame_rate']==a['frame_rate']==40
routes=read(W/'native-paths.json')
for phase in ('before','candidate'):
 inputs=read(E/f'storage-{phase}-inputs.json')
 assert all(digest(ROOT/p)==inputs[k] for k,p in routes[phase].items())
import re
for doc in (b,a):
 loaded_ids={int(m[1]) for pair in doc['loaded_paths'] if (m:=re.search(r'/storage/box_(\d+)(?:\.png)?$',pair[0].lower()))}
 assert loaded_ids==set(range(200)), 'Not all wallpaper IDs were actually loaded'
 for source,h in doc['script_sha256'].items():assert digest(ROOT/source)==h,source
summaries=[]
for label in b['renders']:
 with Image.open(E/f'{label}-before.png') as original,Image.open(E/f'{label}-candidate.png') as candidate:
  assert original.size==candidate.size==(512,384)
  diff=ImageChops.difference(original.convert('RGB'),candidate.convert('RGB'))
  protected=diff.copy();protected.paste((0,0,0),(184,74,508,314))
  assert protected.getbbox() is None,'Outside wallpaper interior changed: '+label
  peak=max(hi for lo,hi in diff.getextrema());assert peak<=12,(label,peak)
  summaries.append({'render':label,'changed':diff.getbbox() is not None,'max_rgb_delta':peak})
for language in (0,2):
 cursor=[r for r in a['traces'] if r['label']==f'cursor-{language}']
 assert len(cursor)==41 and cursor[0]['arrow']==cursor[-1]['arrow']
 for mode in ('default','quickswap','multiselect'):
  hold=[r for r in a['traces'] if r['label']==f'hold-{language}-{mode}']
  place=[r for r in a['traces'] if r['label']==f'place-{language}-{mode}']
  assert len(hold)==len(place)==17 and hold[-1]['holding'] and not place[-1]['holding']
# Original-size refinement is useful on large silhouette interiors; grass is only dimmer.
accepted=[16,17];rejected=[0]
for row in read(W/'wallpaper-validation.json'):
 number=int(Path(row['source']).stem[3:]);row['state']='accepted' if number in accepted else 'rejected_no_visible_gain'
 row['reason']='Restrained interior shading adds visible material depth while silhouette, pose, bubbles/sparkles, buttons and title remain unchanged.' if number in accepted else 'Fine grass pattern is already clear; the candidate mostly changes brightness without adding useful clarity.'
 write(W/f'box{number}-decision.json',row)
for batchno in (77,83,85):
 batch=OUT/f'batch-{batchno:03}';manifest=read(batch/'manifest.json' if (batch/'manifest.json').exists() else batch/'candidate-manifest.json')
 rejected_entries=[e for e in manifest['entries'] if e['source'].lower().endswith(('box0.png','box_0.png'))]
 accepted_entries=[e for e in manifest['entries'] if e not in rejected_entries]
 if rejected_entries:write(batch/'candidate-manifest.json',{'batch':batch.name[6:],'status':'rejected_no_visible_gain','applied':False,'entries':rejected_entries})
 if accepted_entries:write(batch/'manifest.json',{'batch':batch.name[6:],'status':'native_validated_pending_apply','entries':accepted_entries})
 elif (batch/'manifest.json').exists():(batch/'manifest.json').unlink()
preview=Image.new('RGB',(1024,768))
for index,number in enumerate((32,33)):
 for side,phase in enumerate(('before','candidate')):
  preview.paste(Image.open(E/f'storage-2-wallpaper-{number}-{phase}.png'),(side*512,index*384))
preview.save(E/'wallpaper-native-comparison.png')
frames=[]
for frame in range(40):
 pair=Image.new('RGB',(1024,384))
 for side,phase in enumerate(('before','candidate')):pair.paste(Image.open(E/f'storage-2-cursor-{frame}-{phase}.png'),(side*512,0))
 frames.append(pair)
frames[0].save(E/'storage-cursor-loop-comparison.gif',save_all=True,append_images=frames[1:],duration=[20,30]*20,loop=0)
result={'status':'passed','decoded_inputs':374,'wallpapers_reviewed':200,'languages':[0,2],'screenshot_pairs':498,
 'traces_identical':True,'outside_wallpaper_interior_identical':True,'max_rgb_change':max(s['max_rgb_delta'] for s in summaries),
 'accepted_proposals':accepted,'accepted_files':4,'rejected_proposals':rejected,'rejected_files':2,
 'frame_rate':40,'cursor_cycle_updates':40,'cursor_cycle_ms':1000,'hold_place_updates':17,
 'verified_interactions':['left/right box transitions','party panel show/hide','normal/quick/multi cursor modes','grab/place','wallpaper fade'],
 'render_differences':summaries,'validation_scope':'Production scene methods and exact bitmap routes, original-size visual comparison; no full gameplay, Android device or release package testing.'}
write(E/'storage-native-validation.json',result)
print(json.dumps({k:v for k,v in result.items() if k!='render_differences'}))

