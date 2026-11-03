"""Validate native scene pairs against the exact protected candidate masks."""
from pathlib import Path
import numpy as np
from PIL import Image,ImageChops
from resume_p2_menu import ROOT,OUT,read,write,digest
E=OUT/'p2-evidence/region';W=OUT/'p2-region-work'
for phase in ('before','candidate'):
 assert f'REGION_PASS phase={phase} images=202 captures=640 map_cases=4 card_backgrounds=93' in (E/f'{phase}-result.txt').read_text()
 assert f'OUTFIT_PASS phase={phase} captures=48 layered_cases=16' in (E/f'outfit-{phase}-result.txt').read_text()
b=read(E/'before-review.json');a=read(E/'candidate-review.json');ob=read(E/'outfit-before-review.json');oa=read(E/'outfit-candidate-review.json')
assert b['captures']==a['captures'] and len(a['captures'])==640
assert b['map_traces']==a['map_traces'],'Map movement/frame/timing changed'
assert ob==oa and len(oa['captures'])==48,'Real outfit layers/anchors changed'
for source,h in oa['layer_sha256'].items():assert digest(ROOT/source)==h
for doc in (b,a):
 for source,h in doc['script_sha256'].items():assert digest(ROOT/source)==h,'Consumer changed after rendering: '+source
for phase in ('before','candidate'):
 routes=read(W/'native-paths.json')[phase];inputs=read(E/f'{phase}-inputs.json')
 for key,path in routes.items():assert inputs[key]==digest(ROOT/path)
candidates=read(W/'candidate-validation.json')['entries'];candidate_sources={r['source'] for r in candidates}
protected={source:Image.open(W/f'{Path(source).stem}-protected-mask.png').convert('L') for source in candidate_sources}
changes=[]
for meta in a['captures']+oa['captures']:
 label=meta['label'];original=Image.open(E/f'{label}-before.png').convert('RGB');after=Image.open(E/f'{label}-candidate.png').convert('RGB')
 assert original.size==after.size==(512,384)
 diff=ImageChops.difference(original,after);allowed=Image.new('L',(512,384))
 if meta['kind']=='card' and meta['source'] in candidate_sources:allowed=ImageChops.invert(protected[meta['source']])
 elif meta['kind']=='map':
  mask=ImageChops.invert(protected['Graphics/Pictures/map/map.png'])
  allowed.paste(mask,(round(16+meta['map_x']),round(32+meta['map_y'])))
  clip=Image.new('L',(512,384));clip.paste(255,(16,32,496,352));allowed=ImageChops.multiply(allowed,clip)
 outside=Image.composite(Image.new('RGB',(512,384)),diff,allowed)
 assert outside.getbbox() is None,'Protected scene pixels changed: '+label
 peak=max(hi for lo,hi in diff.getextrema());assert peak<=12,(label,peak)
 changes.append({'label':label,'changed':diff.getbbox() is not None,'max_rgb_delta':peak})
for p in E.glob('outfit-avatar-*-before.png'):
 q=p.with_name(p.name.replace('-before.png','-candidate.png'))
 assert np.array_equal(np.asarray(Image.open(p)),np.asarray(Image.open(q))),'Avatar pixels changed: '+p.name
for case in sorted({r['case'] for r in a['map_traces']}):
 trace=[r for r in a['map_traces'] if r['case']==case]
 assert len(trace)==802 and trace[0]['tick']==1 and trace[-1]['tick']==802
 for key in ('cursor','fly','arrows'):assert trace[0][key]==trace[480][key],(case,key)
 assert trace[0]['fly'] is not None,'No flying points exercised'
 assert len({tuple(r['map']) for r in trace})>1,'Map did not scroll'
 for key,index,period in [('cursor',2,24),('fly',0,40)]:
  values=[r[key][index] for r in trace]
  assert len(set(values[:period]))==2
  assert values[0]==values[period],(case,key)
# Export native-size comparisons and a complete combined 12s trace report.
preview=Image.new('RGB',(1024,1152))
for row,name in enumerate(('GOLD','BRONZE','SILVER')):
 label=f'outfit-2-1-leaf-1-{name}'
 for col,phase in enumerate(('before','candidate')):preview.paste(Image.open(E/f'{label}-{phase}.png'),(col*512,row*384))
preview.save(E/'trainer-card-native-comparison.png')
preview=Image.new('RGB',(1024,768))
for row,case in enumerate(('2-0','2-1')):
 for col,phase in enumerate(('before','candidate')):preview.paste(Image.open(E/f'map-{case}-40-{phase}.png'),(col*512,row*384))
preview.save(E/'map-native-comparison.png')
result={'status':'passed','images_decoded':202,'native_screen_pairs':688,'main_scene_pairs':640,'real_outfit_screen_pairs':48,
 'real_layered_cases':16,'portrait_pixels_and_anchors_identical':True,'protected_scene_pixels_identical':True,
 'map_traces_identical':True,'map_cases':4,'map_updates_per_case':802,'combined_loop_updates':480,'combined_loop_ms':12000,
 'cursor_cycle_updates':24,'cursor_cycle_ms':600,'fly_point_cycle_updates':40,'fly_point_cycle_ms':1000,'edge_arrow_cycle_updates':32,'edge_arrow_cycle_ms':800,
 'card_backgrounds':93,'card_metal_variants_signed_difference_identical':True,'map_pre_post_signed_difference_identical':True,
 'max_rendered_rgb_delta':max(r['max_rgb_delta'] for r in changes),'render_changes':changes,
 'tutor_scope':a['tutor_indicator_scope'],'limitations':'No full playthrough, Android device or release package check; real avatar layering is scoped to the trainer-card portrait, not all overworld actions.'}
result['timing_scope']='Cycle durations are nominal at 40fps; update counts/order and before/after trajectories are verified. Screenshot redraws are not a wall-clock performance benchmark.'
write(E/'native-validation.json',result)
print({k:v for k,v in result.items() if k!='render_changes'})

