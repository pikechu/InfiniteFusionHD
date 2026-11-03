"""Apply accepted region/UI candidates and checkpoint every fixed batch."""
from pathlib import Path
import sys,shutil
from PIL import Image
from resume_p2_menu import ROOT,OUT,read,write,digest
from update_p2_progress import update_progress,self_check
sys.path.insert(0,str(ROOT/'scripts/graphics'))
from texture_batch import install_or_verify,validate_image
W=OUT/'p2-region-work';E=OUT/'p2-evidence/region'


def main():
 self_check();proof=read(E/'native-validation.json')
 assert proof['status']=='passed' and proof['native_screen_pairs']==688 and proof['portrait_pixels_and_anchors_identical']
 for phase in ('before','candidate'):
  for kind in ('region','region-outfits'):
   cleanup=read(OUT/f'p2-evidence/dex/texture-p2-dex-{kind}-{phase}-20261029-cleanup.json')
   assert cleanup['process_exited'] and not cleanup['remaining_temporary_logs']
  doc=read(E/f'{phase}-review.json')
  for source,h in doc['script_sha256'].items():assert digest(ROOT/source)==h
 scope=read(W/'scope.json')['entries'];assert len(scope)==202
 manifests={f'batch-{n:03}':read(OUT/f'batch-{n:03}/manifest.json') for n in (95,98,99,100)}
 applied={entry['source']:entry for manifest in manifests.values() for entry in manifest['entries']};assert len(applied)==5
 catalog=read(ROOT/'Data/localization/zh-CN-images.json')['images'];mapped=set(catalog)|{row['path'] for row in catalog.values()}
 assert not set(applied)&mapped,'Paired translated candidates require separate validation and catalog synchronization'
 jobs={j['source']:j for j in read(W/'card-jobs.json')['entries']};map_job=read(W/'map-job.json')
 for source in ('Graphics/Pictures/map/map.png','Graphics/Pictures/map/map_postgame.png'):jobs[source]=map_job
 for row in scope:
  entry=applied.get(row['source']);expected={entry['before_sha256'],entry['after_sha256']} if entry else {row['sha256']}
  assert digest(ROOT/row['source']) in expected,'Concurrent source change: '+row['source']
  if entry:
   batch=OUT/row['batch'];validate_image(batch/'originals'/row['source'],batch/'ready'/row['source'])
   assert digest(batch/'originals'/row['source'])==entry['before_sha256']
   assert digest(batch/'ready'/row['source'])==entry['after_sha256']
   assert digest(batch/'generated'/row['source'])==entry['generated_sha256']
 decisions=[]
 for row in scope:
  source=row['source'];path=source.lower()
  if source in applied:
   reason='内置 image_gen 提案经过保护区回填及原生前后验收；水面仅增加海水内部细节，或卡面仅增加共同材质明暗。原尺寸、透明通道、路线/水印、文字覆盖区、人物和状态差值均保持。'
   entry={**applied[source],'status':'applied','reason':reason}
  else:
   if 'mapregion' in path:
    reason='已有地形、路线和地名细节清晰；中英文及 15 组地图进度版本属于关联状态资源。新增纹理不能改善地名与路线辨识，保留原图和全部状态差值。当前地图界面主要加载 map/map 或 map_postgame，不把兼容图解码当作完整游玩验收。'
   elif '/backgrounds/' in path:
    reason='原有卡面画作、精灵剪影、徽章、文字或旗帜图案清楚，原生卡面预览已复核；继续加纹理无明确清晰度收益，保留原像素及人物姿态。'
   elif any(t in path for t in ('cursor','icon_','button','compat','controls','overlay','badge')):
    reason='功能文字、按钮、切片、标记或指示状态需保持明确边界；原尺寸显示已清楚。逐字节保留，避免改变选中状态、图格或动画时序。'
   else:
    reason='纯色布局、文档/旧兼容界面或已有细节充足的素材；增加表面纹理无明确辨识度收益，保持原始文字、构图、颜色和布局。'
   entry={'source':source,'size':row['size'],'sha256':row['sha256'],'status':'preserved','reason':reason}
  decisions.append({**entry,'batch':row['batch'],'encoded_frames':row['encoded_frames']})
 write(E/'review-decisions.json',{'status':'reviewed','applied':5,'preserved':197,'entries':decisions,
  'scope':'Native current map/card/gear/help/Tutor.net rendering and targeted inputs; legacy forms/compatibility/state variants retained unchanged with usage/layout review.'})
 for n in range(94,103):
  name=f'batch-{n:03}';batch=OUT/name
  plan_path=OUT/'execution-plan/plan.json';plan=read(plan_path);index={r['id']:r for r in plan['batch_index']}
  record_path=OUT/f'execution-plan/batches/{name}.json';record=read(record_path)
  assert all(index[dep]['status']=='completed' for dep in record['depends_on'])
  entries=[e for e in decisions if e['batch']==name]
  assert {e['source'] for e in entries}=={e['source'] for e in record['entries']}
  if name in manifests:
   flags=[digest(ROOT/e['source'])==e['after_sha256'] for e in manifests[name]['entries']]
   assert all(flags) or not any(flags),'Partial application requires review: '+name
   install_or_verify(batch,'verify' if all(flags) else 'apply')
  for entry in entries:
   expected=entry['after_sha256'] if entry['status']=='applied' else entry['sha256'];source=ROOT/entry['source']
   assert digest(source)==expected
   original=batch/'originals'/entry['source'];original.parent.mkdir(parents=True,exist_ok=True)
   if not original.exists():shutil.copy2(source,original)
   assert digest(original)==entry.get('before_sha256',entry.get('sha256'))
   delivery=batch/'delivery'/entry['source'];delivery.parent.mkdir(parents=True,exist_ok=True)
   if not delivery.exists():shutil.copy2(source,delivery)
   assert digest(delivery)==expected
  write(batch/'jobs.json',{'batch':name[6:],'method':'Built-in image_gen; shared bounded material fields; protected text/geometry/alpha; native acceptance.',
   'entries':[{'source':e['source'],'decision':e['status'],'reason':e['reason'],
    'prompt':jobs[e['source']]['prompt'] if e['source'] in jobs else None,
    'generated':jobs[e['source']]['generated'] if e['source'] in jobs else None,
    'generation_status':'accepted_applied' if e['status']=='applied' else 'not_generated_no_expected_gain'} for e in entries]})
  receipt={'batch':name,'status':'completed','applied':sum(e['status']=='applied' for e in entries),
   'preserved':sum(e['status']=='preserved' for e in entries),'entries':entries,'candidate_pending_review':0,
   'dimensions_unchanged':True,'alpha_unchanged':True,'layout_unchanged':True,
   'evidence':['output/texture-hd/p2-evidence/region/native-validation.json','output/texture-hd/p2-region-work/candidate-validation.json','output/texture-hd/p2-evidence/region/review-decisions.json'],
   'validation_scope':'202 decodes; 688 native before/candidate screen pairs; 93 card backgrounds; four map runs with identical 802-update traces and full 480-update/12s combined animation loops; 16 real portrait layering cases. Legacy documents/state sheets retained unchanged. No full playthrough, all overworld clothing animations, Android device or release-package validation.'}
  write(batch/'validation.json',receipt)
  if name in manifests:
   manifest=read(batch/'manifest.json');manifest['status']='applied_verified';write(batch/'manifest.json',manifest)
  record.update(status='completed',result=(batch/'validation.json').relative_to(ROOT).as_posix(),applied_files=receipt['applied'],preserved_files=receipt['preserved']);write(record_path,record)
  index[name].update(status='completed',result=record['result'],applied_files=receipt['applied'],preserved_files=receipt['preserved'])
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
  write(audit_path,audit);progress=update_progress()
  resume=read(OUT/'p2-work/resume.json');resume.update(completed_through=name,next_batch=progress['next_batch'],candidate_pending_review=[]);write(OUT/'p2-work/resume.json',resume)
  write(W/'resume.json',{'status':'completed' if n==102 else 'in_progress','completed_through':name,'next_batch':progress['next_batch'],'candidate_pending_review':[]})
  index_path=OUT/'execution-plan/batch-index.zh-CN.md';lines=index_path.read_text(encoding='utf-8').splitlines()
  index_path.write_text('\n'.join(line.replace('待执行','已完成') if f'batches/{name}.json' in line else line for line in lines)+'\n',encoding='utf-8')
  print(f"{name} applied={receipt['applied']} preserved={receipt['preserved']} next={progress['next_batch']}",flush=True)
 assert (progress['completed_files'],progress['applied_files'],progress['preserved_files'],progress['remaining_files'])==(985,15,970,1238)
 print(progress)

if __name__=='__main__':main()
