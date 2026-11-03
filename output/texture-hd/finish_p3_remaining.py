"""Checkpoint fixed P3 batches only after source, visual and native checks."""
import sys,shutil,gzip,json
from pathlib import Path
from resume_p2_menu import ROOT,OUT,read,write,digest
from update_p2_progress import self_check,update_progress
sys.path.insert(0,str(ROOT/'scripts/graphics'))
from texture_batch import install_or_verify
W=OUT/'p3-work';E=OUT/'p3-evidence/remaining'


def main(numbers):
 self_check();scope=read(W/'remaining-scope.json');by_source={r['source']:r for r in scope['entries']}
 reviewed=set(read(W/'visual-review.json')['reviewed_pages']);page_for={s:Path(p['path']).name for p in scope['review_pages'] for s in p['sources']}
 proofs={};inventory=read(OUT/'inventory.json');audit=read(OUT/'p3-audit.json');plan=read(OUT/'execution-plan/plan.json');index={r['id']:r for r in plan['batch_index']}
 for n in numbers:
  assert 153<=n<=540;name=f'batch-{n:03}';batch=OUT/name;record_path=OUT/f'execution-plan/batches/{name}.json';record=read(record_path)
  assert record['status']=='planned',name+' is already checkpointed'
  assert all(index[dep]['status']=='completed' for dep in record['depends_on'])
  proof_name={'npc':'characters','follower':'characters','outfit':'outfits','pokemon_alt':'battle-art','special':'battle-art','ui_other':'ui'}[record['stage']]
  if proof_name not in proofs:
   proof=read(E/f'{proof_name}-review.json');assert proof['status']=='passed'
   for source,h in proof['script_sha256'].items():assert digest(ROOT/source)==h,'Consumer changed: '+source
   cleanup=read(OUT/f'p2-evidence/dex/texture-p2-dex-p3-{proof_name}-20261030-cleanup.json')
   assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
   proofs[proof_name]=proof
  proof=proofs[proof_name];entries=[]
  repair_path=W/'encoding-repair.json';repair=read(repair_path) if repair_path.exists() else None
  if repair and repair['batch']==name:
   assert repair['status']=='ready_native_verified' and repair['native_decoded_rgba_identical']
   assert proof['candidate_inputs'][repair['entry']['source']]['sha256']==repair['entry']['after_sha256']
   install_or_verify(batch,'apply');repair['status']='applied_verified';write(repair_path,repair)
   manifest=read(batch/'manifest.json');manifest['status']='applied_verified';write(batch/'manifest.json',manifest)
  compatibility={r['source']:r for r in proof.get('compatibility_issues',[])}
  for item in record['entries']:
   row=by_source[item['source']];source=row['source'];canonical=row.get('same_pixels_as',source)
   assert page_for[canonical] in reviewed,'Visual review missing: '+canonical
   encoding=repair['entry'] if repair and repair['batch']==name and repair['entry']['source']==source else None
   expected=encoding['after_sha256'] if encoding else row['sha256']
   assert digest(ROOT/source)==expected and row['sha256']==proof['inputs'][source]==digest(batch/'originals'/source)
   kind=row['kind'];stage=row['stage']
   if encoding:
    reason='原文件后缀为 PNG、实际编码却是 WebP，原生 SDL 拒绝读取。已无损转为真正 PNG；解码 RGBA、透明通道、尺寸、主体位置完全相同，并通过无路由覆盖的原生直接加载。此项仅修复编码，不是 AI 重绘。'
   elif source in compatibility:
    reason='原有兼容素材：'+compatibility[source]['issue']+'。保留原文件名、尺寸与像素，不擅自修复路由或把已有不匹配计作新高清化结果。原生解码及适用的叠穿路径另列记录。'
   elif stage in ('npc','follower'):
    if kind=='compatibility_sheet':reason='原图是旧式 3×3 共九格的兼容来源，当前通用角色加载器按 4×4 裁切；保留原画格，不改尺寸或强行改为行走表。默认 4×4 诊断预览不计作该九格来源的正确动画验证，已单列原有布局差异。'
    elif kind=='charset':reason=f"原有角色/物件的加载器四方向四格布局（{row['cell_size'][0]}×{row['cell_size'][1]}），可见色块与透明/空白区域保持原样；细窄部件不适合额外纹理。真实 Sprite_Character 裁切、原点、资源切换和四速度动画计数已检查，兼容预览不冒充全部地图/跟随逻辑。"
    elif kind=='trainer_throw':reason='旧版五格背面条图的姿态/服饰清楚，实际 PictureEx 投掷及回到首格已检查；增加纹理无明确收益，保留原帧序和所有像素。'
    else:reason='目录中的静态训练师/开场/表单/VS 图，按单张图片保留，未误切成动作。现有线条、文字或构图清楚；新增表面细节没有辨识度收益。'
   elif stage=='outfit':
    reason='服装、发型、帽子或手持物属于精确覆盖的小型像素层；现有颜色边界清楚，额外纹理不改善原尺寸辨识。保留透明轮廓与所有动作；匹配当前命名的资源经过真实 Sprite_Player/Sprite_Wearable 或训练师肖像合成路径，所有路由/尺寸例外单独列明。未宣称穷尽全部衣柜笛卡尔组合。'
   elif stage in ('pokemon_alt','special'):
    reason='逐张审查的替换画法/融合/形态/蛋/替身等像素画已保持明确的物种部件、姿态与配色。保持原始透明轮廓时，添加内部噪声不能改善像素边界，可能混入错误身份细节，因此保留原图。实际自定义图片加载、前后面缩放/镜像与完整选择闪烁周期已检查；特殊/蛋图为显式兼容覆盖预览，不伪称其物种绑定或孵化事件均已验证。'
   elif kind=='movie_frame':
    reason='开场连续动画的一帧，必须与全部 230 帧保持一致；原有画面/运动清楚，单帧重绘无明确收益且会引入闪烁或内容漂移。全部原像素保留，真实 Movie 播放的帧序和逐帧等待/跳过另有整段记录。'
   else:
    reason='界面文字、功能图格、图标或已有细节的装饰图在原尺寸下清楚，继续加纹理无明确可读性收益。保留原图、切片和关联中英文；原生解码与相应小游戏场景/动画检查见证据，未将解码等同于所有事件流程。'
   entry={**row,'status':'applied' if encoding else 'preserved','reason':reason,'visual_review_page':page_for[canonical]}
   if encoding:entry.update(encoding)
   entries.append(entry)
   delivery=batch/'delivery'/source;delivery.parent.mkdir(parents=True,exist_ok=True)
   if not delivery.exists():shutil.copy2(ROOT/source,delivery)
   assert digest(delivery)==expected
  write(batch/'jobs.json',{'batch':str(n),'method':'Original-sized visual/structure review and corresponding native component/scene validation. No accepted AI replacement.',
   'entries':[{'source':e['source'],'decision':e['status'],'reason':e['reason'],'generation_status':'lossless_encoding_repair' if e['status']=='applied' else 'not_generated_no_expected_gain','prompt':None,'generated':None} for e in entries]})
  evidence=[f'output/texture-hd/p3-evidence/remaining/{proof_name}-review.json','output/texture-hd/p3-work/visual-review.json']
  applied=sum(e['status']=='applied' for e in entries);preserved=len(entries)-applied
  write(batch/'validation.json',{'batch':name,'status':'completed','applied':applied,'preserved':preserved,'entries':entries,'candidate_pending_review':0,
   'dimensions_unchanged':True,'alpha_unchanged':True,'layout_unchanged':True,'evidence':evidence,'validation_scope':proof['scope'],
   'byte_identity_guarantee':'Preserved sources/deliveries are byte-identical to the snapshot. Applied container repair is decoded-RGBA-identical and now natively readable; no pose, frame, alpha or timing change. No AI redraw claim.'})
  result=f'output/texture-hd/{name}/validation.json';record.update(status='completed',result=result,applied_files=applied,preserved_files=preserved);write(record_path,record)
  index[name].update(status='completed',result=result,applied_files=applied,preserved_files=preserved)
  p3_rows=[r for r in plan['batch_index'] if r['priority']=='P3'];done=[r for r in p3_rows if r['status']=='completed']
  for priority in plan['priorities']:
   if priority['priority']=='P3':priority.update(status='completed' if len(done)==len(p3_rows) else 'in_progress',
    completed_files=sum(r['file_count'] for r in done),applied_files=sum(r.get('applied_files',0) for r in done),
    preserved_files=sum(r.get('preserved_files',0) for r in done),remaining_files=sum(r['file_count'] for r in p3_rows if r['status']!='completed'))
  for stage in plan['stages']:
   if stage['priority']=='P3':
    stage_rows=[index[b] for b in stage['batch_ids']];stage_done=[r for r in stage_rows if r['status']=='completed']
    stage.update(status='completed' if len(stage_done)==len(stage_rows) else 'in_progress' if stage_done else 'planned',
     completed_files=sum(r['file_count'] for r in stage_done),applied_files=sum(r.get('applied_files',0) for r in stage_done),preserved_files=sum(r.get('preserved_files',0) for r in stage_done))
  plan['next_batch']=next((r['id'] for r in plan['batch_index'] if r['status']!='completed'),None);write(OUT/'execution-plan/plan.json',plan)
  selected={r['source']:r for r in entries}
  for row in inventory['assets']:
   if row['path'] in selected:row.update(status=selected[row['path']]['status'],batch=name,reason=selected[row['path']]['reason'])
  for status in ('applied','preserved','pending'):inventory[status]=sum(r['status']==status for r in inventory['assets'])
  write(OUT/'inventory.json',inventory)
  for row in audit['sources']:
   if row['source'] in selected:row.update(review_status=selected[row['source']]['status'],validation=result,accepted_sha256=selected[row['source']].get('after_sha256',row['sha256']))
  write(OUT/'p3-audit.json',audit);progress=update_progress('P3')
  write(W/'resume.json',{'status':progress['status'],'completed_through':name,'next_batch':progress['next_batch'],'candidate_pending_review':[],
   'ready_pending_application':[repair['entry']['source']] if repair and repair['status']=='ready_native_verified' else []})
  path=OUT/'execution-plan/batch-index.zh-CN.md';lines=path.read_text(encoding='utf-8').splitlines();path.write_text('\n'.join(line.replace('待执行','已完成') if f'batches/{name}.json' in line else line for line in lines)+'\n',encoding='utf-8')
  print(f"CHECKPOINT {name} applied={applied} preserved={preserved} completed={progress['completed_files']} next={progress['next_batch']}",flush=True)


if __name__=='__main__':main([int(n) for n in sys.argv[1:]])
