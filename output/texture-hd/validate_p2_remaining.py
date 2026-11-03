"""Validate native proofs and preserve their full trace records losslessly."""
from pathlib import Path
import gzip,hashlib,json
from collections import defaultdict
from PIL import Image
from resume_p2_menu import ROOT,OUT,read,write,digest
E=OUT/'p2-evidence/remaining';W=OUT/'p2-remaining-work'


def full(name):
 doc=read(E/f'{name}-review.json')
 if 'full_native_archive' in doc:
  archive=doc['full_native_archive'];p=ROOT/archive['path'];raw=gzip.decompress(p.read_bytes())
  assert digest(p)==archive['archive_sha256'] and hashlib.sha256(raw).hexdigest()==archive['raw_sha256']
  return json.loads(raw)
 return doc


def main():
 ui=full('ui');player=full('player');battle=full('battle');trainers=full('trainers')
 assert all(d['status']=='passed' for d in (ui,player,battle,trainers))
 assert len(ui['inputs'])==46 and len(ui['renders'])==92 and len({r['label'] for r in ui['renders']})==92
 assert len(ui['panorama_periods'])==34
 assert len(player['inputs'])==125 and player['appearance_cases']==138 and len(player['anchors'])==15456 and len(player['surf_cases'])==464
 by_pose={(r[0],r[1],r[2],r[3]):r[4] for r in player['anchors']}
 for case in range(138):
  for direction in (2,4,6,8):
   for frame in range(4):assert by_pose[case,0,direction,frame]==by_pose[case,6,direction,frame],'Walk loop anchor differs after action switches'
 periods=[]
 for row in player['timings']:
  s=row['frames'];period=next(p for p in range(4,97) if s[:-p]==s[p:]);assert set(s)=={0,1,2,3}
  periods.append({'move_speed':row['move_speed'],'period_updates':period,'nominal_ms_at_40fps':period*25})
 assert len(battle['inputs'])==1047 and battle['species_count']==470 and len(battle['battlers'])==940 and len(battle['states'])==47000
 grouped=defaultdict(list)
 for row in battle['states']:grouped[tuple(row[:3])].append(row)
 for key,rows in grouped.items():
  assert len(rows)==25 and rows[0][4:]==rows[-1][4:],'Incomplete selection cycle'
  if key[2]==1:assert {r[6] for r in rows}=={-2,0,2}
  else:assert {r[7] for r in rows}=={True,False}
 assert len(battle['trainer_throws'])==9 and all(r['frame_order']==[1,2,3,4,0] for r in battle['trainer_throws'])
 assert len(battle['trainer_renders'])==130 and len(trainers['captures'])==121 and len(battle['shiny_cases'])==12
 assert len({r['source'] for r in trainers['captures']})==121
 decoded={**ui['inputs'],**player['inputs'],**battle['inputs']};assert len(decoded)==1218
 for doc in (ui,player,battle,trainers):
  for path,h in doc['script_sha256'].items():assert digest(ROOT/path)==h,path
 for row in read(W/'scope.json')['entries']:
  source=row['source'];assert decoded[source]==row['sha256']==digest(ROOT/source)
  assert digest(OUT/row['batch']/'originals'/source)==row['sha256']
 visual=read(W/'visual-review.json');sheets=read(W/'scope.json')['review_sheets']
 assert len(visual['reviewed_sheets'])==len(set(visual['reviewed_sheets']))==91
 assert {Path(p).stem[10:] for p in sheets}==set(visual['reviewed_sheets'])
 for name in ('ui','player','battle','trainers'):
  profile=f'texture-p2-dex-remaining-{name}-20261030';cleanup=read(OUT/f'p2-evidence/dex/{profile}-cleanup.json')
  assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
  stage=ROOT/'temp/multiplayer'/profile;assert not list(stage.rglob('*.log')) and not (stage/'mkxp.json').exists()
 # Opaque preview avoids viewers exposing RGB values under zero alpha.
 preview=Image.new('RGB',(640,640),'#424952')
 for row,(case,action,direction) in enumerate(((0,0,2),(2,1,2),(4,2,2),(49,0,2))):
  with Image.open(E/f'player-{case}-{action}-{direction}.png') as image:preview.paste(image,(0,row*160),image)
 preview.save(E/'native-layering-preview.png')
 report={'status':'passed','retained_sources_byte_identical':1218,'reviewed_original_sheets':91,
   'title_panorama_renders':92,'panorama_offset_cases':204,'player_appearance_cases':138,
   'player_pose_states':15456,'surf_dive_states':464,'player_action_return_anchors_identical':True,
   'player_pattern_periods':periods,'species':470,'front_back_metric_cases':940,
   'battler_selection_states':47000,'battler_combined_cycle_updates':24,'battler_nominal_cycle_ms_at_40fps':600,
   'representative_shiny_cases':12,'trainer_static_battle_renders':121,'legacy_trainer_throw_sequences':9,
   'sources_changed_by_this_wave':0,'candidate_pending_review':0,
   'limitations':['Native fixed-input component/scene checks, not complete gameplay or all map/event state transitions.',
    'Current player-back snapshot only constructs the layered front sprite at its initial offscreen position; no full battle entrance claim.',
    'Legacy five-frame back strips are not the active current player sprite path.',
    'Shiny cases are representative; no exhaustive proof of every hue/hat/form combination.',
    'No Android physical-device or final release-package test.'],
   'generation':'One built-in walk proposal rejected for all 16 changed cell anchors. Two Pokemon pilot outputs rejected by the built-in tool; no API fallback used. All remaining originals retained after individual visual review, not labeled AI-enhanced.'}
 write(E/'native-validation.json',report)
 # Archive large local records after all comparisons; retain summary inputs for
 # batch recovery and exact uncompressed hashes for future trace inspection.
 for name,large_keys in (('battle',['states']),):
  path=E/f'{name}-review.json';raw=path.read_bytes();doc=json.loads(raw)
  if 'full_native_archive' not in doc:
   target=E/f'{name}-full.json.gz';target.write_bytes(gzip.compress(raw,compresslevel=9,mtime=0));assert gzip.decompress(target.read_bytes())==raw
   doc['full_native_archive']={'path':target.relative_to(ROOT).as_posix(),'raw_sha256':hashlib.sha256(raw).hexdigest(),'archive_sha256':digest(target)}
   for key in large_keys:doc[key+'_count']=len(doc[key]);del doc[key]
   write(path,doc)
   cleanup=read(E/'periodic-cache-cleanup.json');cleanup['lossless_archives'].append({'name':name,'original_bytes':len(raw),'archive_bytes':target.stat().st_size,'summary_bytes':path.stat().st_size});write(E/'periodic-cache-cleanup.json',cleanup)
 print(report)


if __name__=='__main__':main()
