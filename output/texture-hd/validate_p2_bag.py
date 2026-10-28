"""Compare native bag states, full arrow loops and protected screen regions."""
from pathlib import Path
import json
import hashlib
from PIL import Image, ImageChops, ImageDraw
OUT=Path(__file__).resolve().parent
ROOT=OUT.parents[1]
NATIVE=OUT/'p2-evidence/native-menu'
read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
before=read(NATIVE/'bag-before-traces.json')
after=read(NATIVE/'bag-candidate-traces.json')
assert before==after, 'Bag pocket/order/anchor/timing/list/description traces differ'
for source,digest in before['script_sha256'].items():assert sha(ROOT/source)==digest,source
for phase in ('before','candidate'):
 assert f'BAG_PASS phase={phase} images=288 cases=4 pocket_states=32' in (NATIVE/f'bag-{phase}-result.txt').read_text()
paths=read(OUT/'p2-work/menu-native-paths.json')
for phase in ('before','candidate'):
 tested=read(NATIVE/f'{phase}-inputs.json')
 assert all(tested[key]==sha(Path(value)) for key,value in paths[phase].items())
maxchange=0
changed=[]
for p in sorted(NATIVE.glob('bag-*-before.png')):
 q=p.with_name(p.name.replace('-before.png','-candidate.png'))
 assert q.exists(),q
 with Image.open(p) as a,Image.open(q) as b:
  assert a.size==b.size==(512,384)
  diff=ImageChops.difference(a.convert('RGB'),b.convert('RGB'))
  maxchange=max(maxchange,max(hi for lo,hi in diff.getextrema()))
  protected=diff.copy()
  protected.paste((0,0,0),(30,20,158,148))
  assert protected.getbbox() is None, 'Pixels outside bag changed: '+p.name
  mask=ImageChops.lighter(ImageChops.lighter(*diff.split()[:2]),diff.split()[2]).point(lambda v:255 if v else 0)
  changed.append(512*384-mask.histogram()[0])
assert maxchange<=6 and max(changed)>0
for gender in ('male','female'):
 tasks=[r for r in read(OUT/'p2-work/bag-tasks.json') if r['gender']==gender]
 # The same signed RGB delta must hold for every state, including the wrap.
 shared=None
 for task in tasks:
  original=Image.open(ROOT/task['source']).convert('RGBA')
  ready=Image.open(OUT/task['batch']/'ready'/task['source']).convert('RGBA')
  assert original.size==ready.size
  assert original.getchannel('A').tobytes()==ready.getchannel('A').tobytes()
  delta=bytes(y-x+128 for x,y in zip(original.tobytes(),ready.tobytes()))
  assert shared is None or delta==shared
  shared=delta
for language in (0,2):
 for gender in (0,1):
  files=sorted(NATIVE.glob(f'bag-{language}-{gender}-*-before.png'))
  frames=[]
  cycle=next(c for c in before['cases'] if c['language']==language and c['gender']==gender)['arrow_cycle_updates']
  for p in files[:cycle]:
   q=p.with_name(p.name.replace('-before.png','-candidate.png'))
   pair=Image.new('RGB',(1024,384))
   pair.paste(Image.open(p).convert('RGB'),(0,0));pair.paste(Image.open(q).convert('RGB'),(512,0))
   frames.append(pair)
  frames[0].save(NATIVE/f'bag-{language}-{gender}-loop-comparison.gif',save_all=True,append_images=frames[1:],duration=[20,30]*(cycle//2),loop=0)
preview=Image.new('RGB',(1024,1536),'#303a45')
for index,(language,gender) in enumerate([(0,0),(0,1),(2,0),(2,1)]):
 for side,phase in enumerate(('before','candidate')):
  preview.paste(Image.open(NATIVE/f'bag-{language}-{gender}-001-{phase}.png').convert('RGB'),(side*512,index*384))
preview.save(OUT/'p2-evidence/bag-native-comparison.png')
result={'status':'passed','candidate_accepted':False,'decision':'preserve_original_no_visible_gain',
 'reason':'At native 128x128 icon size and 512x384 scene size, bounded micro-shading does not improve shell/pocket readability; retain originals. Generated results remain archived.',
 'pocket_state_cases':32,'interaction_cases':4,'scene_image_pairs':len(changed),'unchanged_interaction_traces':True,
 'arrow_frame_count':8,'arrow_cycle_updates':[c['arrow_cycle_updates'] for c in before['cases']],
 'frame_rate':40,'arrow_cycle_ms':800,'max_rendered_rgb_change':maxchange,'max_changed_pixels_per_scene':max(changed),
 'item_text_cursor_and_pixels_outside_bag_identical':True,'state_and_wrap_signed_differences_identical':True,
 'evidence':['native-menu/bag-before-result.txt','native-menu/bag-candidate-result.txt','bag-native-comparison.png'],
 'scope':'Production PokemonBag_Scene with scripted input: both genders, English/Chinese, 1-8-1 and 1-8-1 reverse cycles, scrolling, sorting and cancel. Isolated hidden profiles; no player saves.'}
(OUT/'p2-evidence/bag-native-validation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps(result))
