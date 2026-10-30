"""Checkpoint each fixed batch only after its native proof and visual review exist."""
import sys,shutil
from resume_p2_menu import ROOT,OUT,read,write,digest
from update_p2_progress import self_check,update_progress
W=OUT/'p2-remaining-work';E=OUT/'p2-evidence/remaining'


def main(numbers):
 self_check();scope=read(W/'scope.json');visual=read(W/'visual-review.json')
 for n in numbers:
  assert 104<=n<=151
  name=f'batch-{n:03}';batch=OUT/name;record_path=OUT/f'execution-plan/batches/{name}.json';record=read(record_path)
  proof_name='ui' if n<=107 else 'player' if n<=115 else 'battle'
  proof=read(E/f'{proof_name}-review.json');assert proof['status']=='passed'
  if n>=146:
   trainer_proof=read(E/'trainers-review.json');assert trainer_proof['status']=='passed' and len(trainer_proof['captures'])==121
   trainer_cleanup=read(OUT/'p2-evidence/dex/texture-p2-dex-remaining-trainers-20261030-cleanup.json')
   assert trainer_cleanup['process_exited'] and not trainer_cleanup['error'] and not trainer_cleanup['remaining_temporary_logs']
   for source,h in trainer_proof['inputs'].items():assert digest(ROOT/source)==h
  cleanup=read(OUT/f'p2-evidence/dex/texture-p2-dex-remaining-{proof_name}-20261030-cleanup.json')
  assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
  for source,h in proof['script_sha256'].items():assert digest(ROOT/source)==h,'Consumer changed: '+source
  sheets=[p for p in scope['review_sheets'] if f'originals-{n:03}-' in p]
  assert sheets and all(__import__('pathlib').Path(p).stem[10:] in visual['reviewed_sheets'] for p in sheets),'Unreviewed images: '+name
  rows=[r for r in scope['entries'] if r['batch']==name];assert len(rows)==record['file_count']
  entries=[]
  for row in rows:
   source=row['source'];path=source.lower();filename=source.rsplit('/',1)[-1]
   assert source in proof['inputs'] and digest(ROOT/source)==row['sha256']==proof['inputs'][source]
   assert digest(batch/'originals'/source)==row['sha256']
   if n<=105:
    reason='原尺寸文字、版权/署名、logo、选中指示或发光遮罩边界明确，增加纹理无辨识度收益。当前标题关联层有第 103 批交互证据，本轮原生中英文解码/显示补齐；备用图不冒充当前启动路径。原图和关联表逐字节保留。'
    if 'intro_presskey2' in path and '/chinese/' in path:reason+=' 中文图中原有 PA/E 残片已记录，保留原有文字不擅自改写。'
   elif n<=107:
    if any(t in path for t in ('black.','blank.','pb7wmme','leagueform')):reason='功能填充、空白或带文字表单必须保持原像素；表面细节不增加可读性。原生全景载入/平铺及中英文显示检查通过，保留原图。'
    elif 'kanto' in path:reason='现有大地图地形与建筑细节充足，地理布局不能被重新解释；本轮没有可证明的视觉收益，保留地标、道路、海岸与原图。'
    else:reason='现有天空、星点、草地/骷髅图案或场景插画已清楚；新增纹理易破坏平铺、条带渐变和星点位置。原生 AnimatedPlane 六偏移及完整宽/高重复位置已核对，保持原图。'
   elif n<=113:
    if '/surf_base/' in path:reason='冲浪/潜水底层是四方向四格的小型轮廓与水线，现有几何清楚；新增噪声无清晰度收益。经真实 Sprite_SurfBase 的全部方向/格位与叠合偏移检查，保留原图。'
    else:reason='80×80 动作格中的可见身体仅占少量像素，原有平涂、姿态与面部清楚；行走 AI 试制改变了 16 格锚点，拒绝推广。保留原身体全部动作、肤色、脚底和叠穿位置；当前加载器的缺失动作回退另列证据。'
   elif n<=115:
    reason='衣服/发型/帽子是按身体精确覆盖的小型分层，原有色块与边界明确；额外细纹理没有原尺寸收益且易改变遮挡。经真实 Sprite_Player 全方向、动作切换和 138 组外观检查，保留全部原像素和色变关系。'
   elif n<=145:
    reason=f"编号 {filename[:-4]} 的默认物种图已逐张查看；原尺寸有限调色像素画的轮廓、配色和姿态清楚。逐像素透明轮廓约束下，新增内部纹理不能消除原有像素边界，且可能产生错误物种细节，因此保留原图。实际前/后面加载、指标锚点、镜像及完整选择/闪烁周期见原生记录；两个目录分别记账，相同像素副本复用审查，不同像素版本分别查看。它们不被假定为正背面配对。"
    if filename in ('1.png','4.png'):reason+=' 该编号的一次内置图像提案被工具拒绝，失败状态单独保存；本项保留依据为原尺寸视觉审查，未把失败结果当作生成成功。'
   else:
    reason='训练师原姿态、服饰色块及轮廓在实际尺寸下明确，添加纹理无明确辨识度收益，保留原图。宽条图按五格及原有 PictureEx 投掷序列检查，保留顺序、时长和回到首格；当前主角战斗图实际使用叠穿正面肖像，不把旧背面条图当作当前播放路径。'
   entry={**row,'status':'preserved','reason':reason};entries.append(entry)
   target=batch/'delivery'/source;target.parent.mkdir(parents=True,exist_ok=True)
   if not target.exists():shutil.copy2(ROOT/source,target)
   assert digest(target)==row['sha256']
  write(batch/'jobs.json',{'batch':str(n),'method':'Original-sized visual review and source-specific native validation; preserve originals where no visible benefit.',
    'pilot_records':['output/texture-hd/p2-remaining-work/pilot-jobs.json','output/texture-hd/p2-remaining-work/charmander-job.json'],
    'entries':[{'source':e['source'],'decision':'preserved','reason':e['reason'],'generation_status':'rejected_pilot' if e['source'].endswith('/1/walk_1.png') else 'tool_rejected' if e['source'] in ('Graphics/BaseSprites/1.png','Graphics/BaseSprites/4.png') else 'not_generated_no_expected_gain'} for e in entries]})
  evidence=[f'output/texture-hd/p2-evidence/remaining/{proof_name}-review.json','output/texture-hd/p2-remaining-work/visual-review.json']
  if n>=146:evidence.append('output/texture-hd/p2-evidence/remaining/trainers-review.json')
  receipt={'batch':name,'status':'completed','applied':0,'preserved':len(entries),'candidate_pending_review':0,'entries':entries,
   'dimensions_unchanged':True,'alpha_unchanged':True,'layout_unchanged':True,'evidence':evidence,'validation_scope':proof['scope'],
   'byte_identity_guarantee':'Source and delivery equal the audited original. Therefore every frame, state, tint input and consumer output remains identical for the same engine inputs; native checks additionally inspect the relevant actual consumers. No accepted redraw in this batch.'}
  write(batch/'validation.json',receipt)
  plan_path=OUT/'execution-plan/plan.json';plan=read(plan_path);index={r['id']:r for r in plan['batch_index']}
  assert all(index[dep]['status']=='completed' for dep in record['depends_on'])
  record.update(status='completed',result=f'output/texture-hd/{name}/validation.json',applied_files=0,preserved_files=len(entries));write(record_path,record)
  index[name].update(status='completed',result=record['result'],applied_files=0,preserved_files=len(entries));plan['next_batch']=next((r['id'] for r in plan['batch_index'] if r['status']!='completed'),None);write(plan_path,plan)
  inventory=read(OUT/'inventory.json');selected={e['source']:e for e in entries}
  for row in inventory['assets']:
   if row['path'] in selected:row.update(status='preserved',batch=name,reason=selected[row['path']]['reason'])
  for state in ('applied','preserved','pending'):inventory[state]=sum(r['status']==state for r in inventory['assets'])
  assert sum(inventory[s] for s in ('applied','preserved','pending'))==inventory['total'];write(OUT/'inventory.json',inventory)
  audit=read(OUT/'p2-audit.json')
  for row in audit['sources']:
   if row['source'] in selected:row.update(review_status='preserved',validation=record['result'],accepted_sha256=row['sha256'])
  write(OUT/'p2-audit.json',audit);progress=update_progress()
  resume=read(OUT/'p2-work/resume.json');resume.update(completed_through=name,next_batch=progress['next_batch'],candidate_pending_review=[]);write(OUT/'p2-work/resume.json',resume)
  write(W/'resume.json',{'status':'completed' if progress['status']=='completed' else 'in_progress','completed_through':name,'next_batch':progress['next_batch'],'candidate_pending_review':[]})
  path=OUT/'execution-plan/batch-index.zh-CN.md';lines=path.read_text(encoding='utf-8').splitlines();path.write_text('\n'.join(line.replace('待执行','已完成') if f'batches/{name}.json' in line else line for line in lines)+'\n',encoding='utf-8')
  print(f"CHECKPOINT {name} preserved={len(entries)} completed={progress['completed_files']} next={progress['next_batch']}",flush=True)


if __name__=='__main__':main([int(n) for n in sys.argv[1:]])
