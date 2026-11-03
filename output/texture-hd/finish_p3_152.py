"""Verify and checkpoint the first P3 batch without altering game assets."""
import gzip,hashlib,shutil
from PIL import Image
from resume_p2_menu import ROOT,OUT,read,write,digest
from update_p2_progress import self_check,summarize,update_progress
W=OUT/'p3-work';E=OUT/'p3-evidence/batch-152';B=OUT/'batch-152'


def main():
 assert read(OUT/'execution-plan/batches/batch-152.json')['status']=='planned','Batch 152 is already completed; verify its receipt instead of finalizing again.'
 self_check();scope=read(W/'batch-152-scope.json')['entries'];native=read(E/'native-review.json');pilot=read(W/'batch-152-pilot.json')
 assert native['status']=='passed' and len(native['inputs'])==20 and len(native['charset_states'])==224 and len(native['action_switches'])==16
 assert len(native['static_renders'])==5 and len(native['trainer_throws'])==1
 assert not any(native['resource_references'].values()),'Usage references need separate review before preserving this compatibility set'
 assert pilot['status']=='rejected_geometry_and_pose' and read(E/'pilot-validation.json')['changed_cell_bounds']==16
 for source,h in native['script_sha256'].items():assert digest(ROOT/source)==h
 cleanup=read(OUT/'p2-evidence/dex/texture-p2-dex-p3-152-20261030-cleanup.json')
 assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
 stage=ROOT/'temp/multiplayer'/cleanup['profile'];assert not list(stage.rglob('*.log')) and not (stage/'mkxp.json').exists()
 write(E/'cleanup.json',cleanup)
 periods=[]
 for row in native['timings']:
  values=row['patterns'];period=next(p for p in range(4,81) if values[:-p]==values[p:]);assert set(values)=={0,1,2,3}
  periods.append({'speed':row['speed'],'period_updates':period,'nominal_ms_at_40fps':period*25})
 assert [r[1] for r in native['trainer_throws'][0]['trace']].count(0)>0
 assert list(dict.fromkeys(r[1] for r in native['trainer_throws'][0]['trace']))==[1,2,3,4,0]
 entries=[]
 for row in scope:
  source=row['source'];assert digest(ROOT/source)==row['sha256']==native['inputs'][source]==digest(B/'originals'/source)
  with Image.open(ROOT/source) as im:
   assert list(im.size)==row['size'] and getattr(im,'n_frames',1)==row['encoded_frames']
   assert hashlib.sha256(im.convert('RGBA').getchannel('A').tobytes()).hexdigest()==row['alpha_sha256']
  if source==pilot['source']:
   reason='内置 image_gen 试制的 16 格边界/头脚锚点均改变，帽子和手部细节偏离原图；缩回网格或回填透明通道不能恢复内部姿态，拒绝候选。现有小型像素画清楚，保留原图。'
  elif row['kind']=='charset':
   reason=f"旧版完整着装角色帧表，每格 {row['cell_size'][0]}×{row['cell_size'][1]}，原有轮廓、衣物和动作清楚；额外细纹理没有原尺寸收益。实际 Sprite_Character 全四方向/四格及动作切换已检查。当前代码/序列化地图与元数据未发现该备用路径的直接引用，保留原图。"
  elif row['kind']=='trainer_throw':
   reason='旧版备用五格背面条图，原有姿态和衣物清楚。实际 PictureEx 投掷帧序 1→2→3→4→0 已完整检查；当前主角仍使用现代换装系统，不把兼容预览当作当前入场流程。保留原图。'
  else:
   reason='备用训练师/开场/VS 静态图，现有姿态与服装色块清楚；未发现当前代码/序列化资源的直接路径引用，增加纹理无明确游戏内收益，保留原画和透明通道。'
  entry={**row,'status':'preserved','reason':reason};entries.append(entry)
  delivery=B/'delivery'/source;delivery.parent.mkdir(parents=True,exist_ok=True)
  if not delivery.exists():shutil.copy2(ROOT/source,delivery)
  assert digest(delivery)==row['sha256']
  job={'source':source,'decision':'preserved','reason':reason,'generation_status':'rejected_geometry_and_pose' if source==pilot['source'] else 'not_generated_no_expected_gain',
       'prompt':pilot['prompt'] if source==pilot['source'] else None,'generated':pilot['generated'] if source==pilot['source'] else None}
  entry['job']=job
 write(B/'jobs.json',{'batch':'152','method':'Built-in image_gen pilot plus original/native usage and layout review. No accepted replacements.',
                      'entries':[r.pop('job') for r in entries]})
 report={'status':'passed','sources':20,'charsets':14,'charset_pose_states':224,'action_switches':16,'static_renders':5,'trainer_throw_sequences':1,
  'animation_periods':periods,'alpha_dimensions_and_all_original_bytes_unchanged':True,'candidate_pending_review':0,
  'no_direct_usage_references_found':True,'layering_scope':'Legacy fully clothed 64x64/96x80 sprites are flat composites; modern 80x80 clothing overlays do not consume them. No replacement or clothing-layer change was made.',
  'limitations':'Compatibility fixtures with neutral lighting and shadowless test events. No complete gameplay, map-event movement/roof occlusion, current player costume selection, Android physical-device or release-package test.',
  'evidence':['output/texture-hd/p3-evidence/batch-152/native-review.json','output/texture-hd/p3-evidence/batch-152/pilot-validation.json']}
 write(E/'validation-summary.json',report)
 write(B/'validation.json',{'batch':'batch-152','status':'completed','applied':0,'preserved':20,'entries':entries,'candidate_pending_review':0,
  'evidence':['output/texture-hd/p3-evidence/batch-152/validation-summary.json'],'dimensions_unchanged':True,'alpha_unchanged':True,'layout_unchanged':True,
  'validation_scope':native['scope']})
 protected=read(W/'session-protected.json')['files'];assert all(digest(ROOT/path)==h for path,h in protected.items()),'Concurrent source changes need review'
 plan_path=OUT/'execution-plan/plan.json';plan=read(plan_path);index={r['id']:r for r in plan['batch_index']}
 record_path=OUT/'execution-plan/batches/batch-152.json';record=read(record_path);assert all(index[dep]['status']=='completed' for dep in record['depends_on'])
 result='output/texture-hd/batch-152/validation.json';record.update(status='completed',result=result,applied_files=0,preserved_files=20);write(record_path,record)
 index['batch-152'].update(status='completed',result=result,applied_files=0,preserved_files=20);plan['next_batch']='batch-153'
 for row in plan['priorities']:
  if row['priority']=='P3':row.update(status='in_progress',completed_files=20,applied_files=0,preserved_files=20,remaining_files=9161)
 for row in plan['stages']:
  if row['stage']=='npc':row.update(status='in_progress',completed_files=20,applied_files=0,preserved_files=20)
 write(plan_path,plan)
 selected={r['source']:r for r in entries};inventory=read(OUT/'inventory.json')
 for row in inventory['assets']:
  if row['path'] in selected:row.update(status='preserved',batch='batch-152',reason=selected[row['path']]['reason'])
 for status in ('applied','preserved','pending'):inventory[status]=sum(r['status']==status for r in inventory['assets'])
 assert (inventory['applied'],inventory['preserved'],inventory['pending'])==(267,2322,16076);write(OUT/'inventory.json',inventory)
 audit=read(OUT/'p3-audit.json')
 for row in audit['sources']:
  if row['source'] in selected:row.update(review_status='preserved',validation=result,accepted_sha256=row['sha256'])
 write(OUT/'p3-audit.json',audit);progress=update_progress('P3');assert (progress['completed_files'],progress['remaining_files'],progress['next_batch'])==(20,9161,'batch-153')
 p2_receipts={r['id']:read(OUT/r['id']/'validation.json') for r in plan['batch_index'] if r['priority']=='P2' and r['status']=='completed'}
 assert summarize(plan,p2_receipts)==read(OUT/'p2-progress.json'),'P2 progress changed while introducing P3'
 write(W/'resume.json',{'status':'in_progress','completed_through':'batch-152','next_batch':'batch-153','candidate_pending_review':[]})
 index_path=OUT/'execution-plan/batch-index.zh-CN.md';lines=index_path.read_text(encoding='utf-8').splitlines();index_path.write_text('\n'.join(line.replace('待执行','已完成') if 'batches/batch-152.json' in line else line for line in lines)+'\n',encoding='utf-8')
 # Save an opaque diagnostic so viewers cannot expose RGB hidden under alpha 0.
 preview=Image.new('RGB',(1280,1280),'#353c46')
 for i,name in enumerate(('charset-0.png','charset-2.png','charset-8.png','charset-10.png')):
  with Image.open(E/name) as im:preview.paste(im,(i%2*640,i//2*640),im)
 preview.save(E/'native-layout-preview.png')
 raw=(E/'native-review.json').read_bytes();archive=E/'native-review.json.gz';archive.write_bytes(gzip.compress(raw,compresslevel=9,mtime=0));assert gzip.decompress(archive.read_bytes())==raw
 write(E/'trace-archive.json',{'archive':archive.relative_to(ROOT).as_posix(),'raw_sha256':hashlib.sha256(raw).hexdigest(),'archive_sha256':digest(archive)})
 # Full trace stays in the lossless archive; the JSON summary keeps recovery inputs.
 compact={k:v for k,v in native.items() if k not in ('charset_states','timings','action_switches','map_sha256')};compact['full_trace_archive']='output/texture-hd/p3-evidence/batch-152/native-review.json.gz';write(E/'native-review.json',compact)
 reclaimed=len(raw)-archive.stat().st_size-(E/'native-review.json').stat().st_size
 cache=(OUT/'__pycache__').resolve();assert cache.is_relative_to(ROOT.resolve());removed=[]
 if cache.exists():
  for path in cache.glob('*.pyc'):
   assert not path.is_symlink() and path.resolve().is_relative_to(cache);removed.append(path.relative_to(ROOT).as_posix());path.unlink()
 write(E/'cache-cleanup.json',{'temporary_logs_remaining':0,'removed_bytecode':removed,'lossless_trace_bytes_reclaimed':reclaimed,
  'images_deleted':0,'reason':'Preserve unpushed originals/generated files and necessary previews; clean test logs/config immediately and compact full trace losslessly.'})
 write(E/'checkpoint-verification.json',{'status':'passed','p3_sources_baselined':9181,'new_sources_originals_deliveries_verified':20,
  'applied':0,'preserved':20,'p2_progress_unchanged':True,'source_code_and_localization_unchanged':True,'temporary_logs_remaining':0,'next_batch':'batch-153'})
 # Keep P2 history while showing the active P3 recovery point first.
 readme=OUT/'README.zh-CN.md';text=readme.read_text(encoding='utf-8');marker='## P2 处理与验收已完成'
 intro='''## P3 已开始

**第 152 批完成：20 / 9,181 张，0 张应用、20 张保留，下一批为 153。** 本批是旧版 base/Chase 完整着装备用资源。14 张动作表中，普通格为 64×64、钓鱼格为 96×80；另有 5 张静态图和 1 张五格背面条图。当前源码、809 张地图/公共事件、玩家元数据和训练师路径扫描未发现本批备用目录的直接引用，未据此断言永远不会使用。

内置 image_gen 的 Chase 行走试制改变全部 16 格的边界、帽子标记和手部姿态，已拒绝；原图、生成图、提示词和拒绝记录完整保存。本批实际 Sprite_Character 验证了 224 个方向/格位状态、16 次资源切换、四个速度的动画循环以及 PictureEx 1→2→3→4→0 投掷序列。旧版完整着装图不由现代 80×80 叠穿系统加载，未将兼容预览称作当前换装流程。

[P3 进度](p3-progress.json)、[本批验收](p3-evidence/batch-152/validation-summary.json)、[原生布局预览](p3-evidence/batch-152/native-layout-preview.png)、[AI 对比](p3-evidence/batch-152/pilot-comparison.png)、[完整提示词](p3-work/batch-152-pilot.json)、[恢复点复核](p3-evidence/batch-152/checkpoint-verification.json)。完整状态轨迹无损压缩，测试日志/配置已清理；源码、本地化和 P2 完成状态未改变。P3 尚余 9,161 张，P4/P5 未开始。

'''
 assert marker in text;text=text.replace(marker,intro+marker,1).replace('267 张已应用、2,302 张保留、16,096 张待处理','267 张已应用、2,322 张保留、16,076 张待处理',1)
 text=text.replace('P3～P5 保留后续计划且未开始（下一整体计划批次为 152）','P3 已从第 152 批开始，下一批 153；P4/P5 保留后续计划且未开始',1);readme.write_text(text,encoding='utf-8')
 path=OUT/'execution-plan/README.zh-CN.md';lines=path.read_text(encoding='utf-8').splitlines();lines=['**2026-10-30：P1、P2 已完成；P3 第 152 批完成 20 张，均保留原图，剩余 9,161 张，下一批为 153。** 全局 267 张应用、2,322 张保留、16,076 张待处理。P4/P5 未开始；见[当前结果与证据](../README.zh-CN.md)。' if line.startswith('**2026-10-30：P1') else line for line in lines]
 text='\n'.join(lines)+'\n';text=text.replace('当前 P1 以及 P2 第 58～151 批状态为 `completed`','当前 P1、P2 第 58～151 批以及 P3 第 152 批状态为 `completed`')
 text+='\nP3 恢复点：第 152 批的 base/Chase 备用图已完成，0 应用、20 保留。已冻结全部 9,181 张 P3 的 SHA-256/Git 对照，未发现外部图片变动；P3 与 P2 进度分别汇总，P2 完成记录不会被 P3 覆盖。下一批 153。原生兼容测试不等于完整游玩、全部事件动作、Android 实机或发布包验证。\n';path.write_text(text,encoding='utf-8')
 path=OUT/'execution-plan/stage-summary.zh-CN.md';lines=path.read_text(encoding='utf-8').splitlines();lines[4]='2026-10-30：P1、P2 已全部处理与验收完成。P3 第 152 批完成 20 张（0 应用、20 保留），剩余 9,161 张，下一批 153；P4/P5 未开始。完整游玩、全部事件动作、Android 实机和发布包未验证。';path.write_text('\n'.join(lines)+'\n',encoding='utf-8')
 print({'P3_completed':20,'applied':0,'preserved':20,'remaining':9161,'next_batch':'batch-153','P2_unchanged':True})


if __name__=='__main__':main()
