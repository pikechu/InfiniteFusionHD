"""Finish the validated dex/storage/naming stage and save every fixed batch."""
from pathlib import Path
import sys,shutil,re
from PIL import Image
from resume_p2_menu import ROOT,OUT,read,write,digest
from update_p2_progress import update_progress,self_check
sys.path.insert(0,str(ROOT/'scripts/graphics'))
from texture_batch import install_or_verify,validate_image
E=OUT/'p2-evidence/dex';W=OUT/'p2-dex-work'


def main():
 self_check()
 proof=read(E/'storage-native-validation.json')
 assert proof['status']=='passed' and proof['accepted_files']==4 and proof['screenshot_pairs']==498
 assert 'DEX_NAMING_PASS languages=2 renders=146 naming_tab_states=16' in (E/'dex-naming-result.txt').read_text()
 naming=read(E/'dex-naming-review.json')
 assert len(naming['renders'])==146
 for label in naming['renders']:
  with Image.open(E/f'{label}.png') as im:im.load();assert im.size==(512,384)
 for label in {r['label'] for r in naming['traces']}:
  rows=[r for r in naming['traces'] if r['label']==label]
  assert rows[-1]['bottom']==[22,162],label
 for doc in (naming,read(E/'storage-candidate-review.json')):
  for source,h in doc['script_sha256'].items():assert digest(ROOT/source)==h,'Consumer changed after native test: '+source
 for profile in ('storage-before-final','storage-candidate-final','naming-verified'):
  cleanup=read(E/f'texture-p2-dex-{profile}-cleanup.json')
  assert cleanup['process_exited'] and not cleanup['remaining_temporary_logs']
 scope=read(W/'scope.json')['entries'];assert len(scope)==374
 manifests={f'batch-{n:03}':read(OUT/f'batch-{n:03}/manifest.json') for n in (77,85)}
 accepted={e['source']:e for m in manifests.values() for e in m['entries']}
 assert len(accepted)==4
 proposals={r['source']:r for r in read(W/'wallpaper-validation.json')}
 jobs={}
 for number in (0,16,17):
  job=read(W/f'box{number}-job.json')
  for alias in proposals[job['source']]['aliases']:jobs[alias]=job
 catalog=read(ROOT/'Data/localization/zh-CN-images.json')['images']
 mapped=set(catalog)|{row['path'] for row in catalog.values()}
 assert not (set(accepted)&mapped),'A translated paired asset requires a catalog update'
 for row in scope:
  current=digest(ROOT/row['source']);entry=accepted.get(row['source'])
  assert current in ({entry['before_sha256'],entry['after_sha256']} if entry else {row['sha256']}),row['source']
  if entry:
   batch=OUT/row['batch'];validate_image(batch/'originals'/row['source'],batch/'ready'/row['source'])
   assert digest(batch/'generated'/row['source'])==entry['generated_sha256']
 code='\n'.join(p.read_text(encoding='utf-8',errors='replace') for directory in ('Data/Scripts','Mods') for p in (ROOT/directory).rglob('*.rb')).lower()
 decisions=[]
 for row in scope:
  path=row['source'].lower();stem=Path(row['source']).stem.lower()
  if row['source'] in accepted:
   status='applied';reason='内置 image_gen 补绘提案仅提取主体内部明暗；原轮廓、姿态、配色、气泡/星点、标题和按钮保持。原生前后对比有可见的柔和层次收益；像素相同的旧目录/在用副本同步应用。'
  elif row['source'] in jobs:
   status='preserved';reason='草地纹理原本清晰，候选主要改变整体亮度，未增加有效辨识细节；生成图和提示词归档，保留原图。'
  elif '/storage/box_' in path:
   status='preserved';reason='逐张复核仓库场景中的原尺寸壁纸：原有细致画作、图案、标识或低对比像素背景已清晰。受图标覆盖区和原风格约束，继续叠加微纹理无明确收益；保留原图及全部文字/装饰。'
  elif any(x in stem for x in ('cursor','point','grab','fist','slider','shadow','marking','gender','overlay','controls','mode','splicer','seen','owned','icon_')):
   status='preserved';reason='功能符号、文字、透明遮罩、光标状态或切片表；原边界和状态对比清晰，添加纹理无原尺寸收益。保留逐像素内容、切片网格和原生动画时序。'
  elif '/pokedex/' in path or '/naming/' in path:
   status='preserved';reason='图鉴/命名布局以文字留白、纯色色块及清晰边框为主。中英文和对应选中/切页显示已检查，增加背景细纹理无辨识度收益，保留原图。'
  else:
   status='preserved';reason='旧目录、兼容主题或已有细节充足的布局/壁纸；复核与当前消费路径的关系后保留，未宣称全部旧主题均由当前场景加载。'
  decisions.append({'source':row['source'],'batch':row['batch'],'status':status,'size':row['size'],'reason':reason,
   **(accepted[row['source']] if status=='applied' else {'sha256':row['sha256']}),
   'source_literal_reference_count':code.count(stem),'encoded_frames':row['encoded_frames'],
   'animation_note':'PNG state layouts retained. Native cursor, grab/place, box slides and naming tab transitions tested; original byte content retained for all non-applied sheets.'})
 write(E/'review-decisions.json',{'status':'reviewed','entries':decisions,'applied':4,'preserved':370,
  'scope':'200 wallpapers in English/Chinese storage scene; naming/dex production states; 32 overview sheets and original-size candidate comparisons. Legacy dark theme/area/r cursor variants are retained, not claimed as current active scenes.'})
 for number in range(77,94):
  name=f'batch-{number:03}';batch=OUT/name
  plan_path=OUT/'execution-plan/plan.json';plan=read(plan_path);index={r['id']:r for r in plan['batch_index']}
  record_path=OUT/f'execution-plan/batches/{name}.json';record=read(record_path)
  assert all(index[dep]['status']=='completed' for dep in record['depends_on'])
  entries=[e for e in decisions if e['batch']==name]
  assert {e['source'] for e in entries}=={e['source'] for e in record['entries']}
  if name in manifests:
   flags=[digest(ROOT/e['source'])==e['after_sha256'] for e in manifests[name]['entries']]
   assert all(flags) or not any(flags),'Partially installed batch requires review'
   install_or_verify(batch,'verify' if all(flags) else 'apply')
  for entry in entries:
   source=ROOT/entry['source'];original_hash=entry.get('before_sha256',entry.get('sha256'))
   expected=entry['after_sha256'] if entry['status']=='applied' else original_hash
   assert digest(source)==expected
   backup=batch/'originals'/entry['source'];backup.parent.mkdir(parents=True,exist_ok=True)
   if not backup.exists():shutil.copy2(source,backup)
   assert digest(backup)==original_hash
   delivered=batch/'delivery'/entry['source'];delivered.parent.mkdir(parents=True,exist_ok=True)
   if delivered.exists():assert digest(delivered)==expected
   else:shutil.copy2(source,delivered)
   assert digest(delivered)==expected
  job_entries=[]
  for entry in entries:
   job=jobs.get(entry['source'])
   job_entries.append({'source':entry['source'],'decision':entry['status'],'reason':entry['reason'],
    'prompt':job['prompt'] if job else None,'generated':job['generated'] if job else None,
    'generation_state':'accepted' if entry['status']=='applied' else 'rejected_no_visible_gain' if job else 'not_generated_no_expected_gain'})
  write(batch/'jobs.json',{'batch':name[6:],'method':'Built-in image_gen on three source wallpapers; protected interior-luminance fitting; exact pixel aliases share proposals.', 'entries':job_entries})
  receipt={'batch':name,'status':'completed','applied':sum(e['status']=='applied' for e in entries),
   'preserved':sum(e['status']=='preserved' for e in entries),'candidate_pending_review':0,'entries':entries,
   'dimensions_unchanged':True,'alpha_unchanged':True,'layout_unchanged':True,
   'evidence':['output/texture-hd/p2-evidence/dex/storage-native-validation.json','output/texture-hd/p2-evidence/dex/dex-naming-review.json','output/texture-hd/p2-evidence/dex/review-decisions.json'],
   'validation_scope':'374 image decodes; 200 storage wallpapers in both languages; 498 native before/candidate screen pairs with identical interaction traces; 146 naming/dex screenshots; cursor loops and grab/place/box/tab transitions. Legacy dark-theme/area assets received decode/layout review and remain unchanged. No full gameplay, character/clothing layering, Android device or release package tests.'}
  write(batch/'validation.json',receipt)
  if name in manifests:
   installed=read(batch/'manifest.json');installed['status']='applied_verified';write(batch/'manifest.json',installed)
  record.update(status='completed',result=(batch/'validation.json').relative_to(ROOT).as_posix(),applied_files=receipt['applied'],preserved_files=receipt['preserved'])
  write(record_path,record);index[name].update(status='completed',result=record['result'],applied_files=receipt['applied'],preserved_files=receipt['preserved'])
  plan['next_batch']=next((r['id'] for r in plan['batch_index'] if r['status']!='completed'),None);write(plan_path,plan)
  inventory_path=OUT/'inventory.json';inventory=read(inventory_path);selected={e['source']:e for e in entries}
  for row in inventory['assets']:
   if row['path'] in selected:
    d=selected[row['path']];row.update(status=d['status'],batch=name,reason=d['reason'])
  for state in ('applied','preserved','pending'):inventory[state]=sum(r['status']==state for r in inventory['assets'])
  assert sum(inventory[s] for s in ('applied','preserved','pending'))==inventory['total'];write(inventory_path,inventory)
  audit_path=OUT/'p2-audit.json';audit=read(audit_path)
  for row in audit['sources']:
   if row['source'] in selected:
    d=selected[row['source']];row.update(review_status=d['status'],validation=record['result'],accepted_sha256=d.get('after_sha256',d.get('sha256')))
  write(audit_path,audit)
  progress=update_progress()
  resume=read(OUT/'p2-work/resume.json');resume.update(completed_through=name,next_batch=progress['next_batch'],candidate_pending_review=[])
  write(OUT/'p2-work/resume.json',resume)
  write(W/'resume.json',{'status':'in_progress','completed_through':name,'next_batch':progress['next_batch'],'candidate_pending_review':[],'accepted_wallpaper_files':4,'rejected_wallpaper_files':2})
  index_path=OUT/'execution-plan/batch-index.zh-CN.md';lines=index_path.read_text(encoding='utf-8').splitlines()
  index_path.write_text('\n'.join(line.replace('待执行','已完成') if f'batches/{name}.json' in line else line for line in lines)+'\n',encoding='utf-8')
  print(f"{name} applied={receipt['applied']} preserved={receipt['preserved']} next={progress['next_batch']}",flush=True)
 assert (progress['completed_files'],progress['applied_files'],progress['preserved_files'],progress['remaining_files'])==(783,10,773,1440)
 write(E/'dex-naming-validation.json',{'status':'passed','screenshots':146,'languages':[0,2],'naming_tab_states':16,
  'naming_traces':len(naming['traces']),'names_and_cursor_anchors_preserved':True,'source_sheets_unchanged':True,
  'area_page_scope':naming['dex_area_page'],'validation_scope':'Production methods with deterministic test input; legacy themes retained unchanged, no claims of complete gameplay.'})
 print(progress)

if __name__=='__main__':main()
