"""Close P2 only after every source/backup/delivery and native proof is verified."""
import gzip,hashlib,shutil
from pathlib import Path
from resume_p2_menu import ROOT,OUT,read,write,digest
W=OUT/'p2-remaining-work';E=OUT/'p2-evidence/remaining'


def main():
 progress=read(OUT/'p2-progress.json');assert progress['status']=='completed' and progress['completed_files']==2223 and progress['remaining_files']==0
 assert (progress['applied_files'],progress['preserved_files'],len(progress['completed_batches']))==(15,2208,94)
 proof=read(E/'native-validation.json');assert proof['status']=='passed' and proof['retained_sources_byte_identical']==1218
 audit=read(OUT/'p2-audit.json');completed={};repairs=[]
 for n in range(58,152):
  name=f'batch-{n:03}';batch=OUT/name;path=batch/'validation.json';receipt=read(path);assert receipt['status']=='completed'
  repaired=[]
  for entry in receipt['entries']:
   source=entry['source'];after=entry['after_sha256'] if entry['status']=='applied' else entry['sha256'];before=entry.get('before_sha256',entry.get('sha256'))
   assert digest(ROOT/source)==after
   original=batch/'originals'/source
   if not original.exists():
    assert entry['status']=='preserved';original.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/source,original);repaired.append(original.relative_to(ROOT).as_posix())
   assert digest(original)==before
   delivery=batch/'delivery'/source
   if not delivery.exists():
    delivery.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/source,delivery);repaired.append(delivery.relative_to(ROOT).as_posix())
   assert digest(delivery)==after
   completed[source]=entry
  if repaired:
   receipt['delivery_archive_completed_date']='2026-10-30';receipt['delivery_root']=f'output/texture-hd/{name}/delivery';write(path,receipt)
   repairs.append({'batch':name,'files':repaired,'reason':'Earlier UI batches stored accepted files in ready/ only. Create explicit delivery copies from verified current accepted bytes; no game-image change.'})
 assert len(completed)==2223
 for row in audit['sources']:
  entry=completed[row['source']];expected=entry['after_sha256'] if entry['status']=='applied' else row['sha256'];assert digest(ROOT/row['source'])==expected
 write(E/'archive-repairs.json',{'status':'verified','entries':repairs,'new_archive_copies':sum(len(r['files']) for r in repairs)})
 # Put the rejected generated sheet and exact prompt into its owning batch.
 pilots=read(W/'pilot-jobs.json');walk=next(r for r in pilots['entries'] if r['key']=='body-walk');source=walk['source']
 target=OUT/'batch-108/generated'/source;target.parent.mkdir(parents=True,exist_ok=True)
 if not target.exists():shutil.copy2(ROOT/walk['generated'],target)
 assert digest(target)==digest(ROOT/walk['generated'])
 write(OUT/'batch-108/candidate-manifest.json',{'batch':'108','status':'rejected_geometry_and_continuity',
  'entries':[{'source':source,'before_sha256':digest(ROOT/source),'generated_sha256':digest(target),'generated':target.relative_to(ROOT).as_posix(),
              'ready':None,'reason':'All 16 resized AI cells changed alpha bounds/anchors; no accepted delivery candidate.'}]})
 jobs=read(OUT/'batch-108/jobs.json')
 for entry in jobs['entries']:
  if entry['source']==source:entry.update(prompt=walk['prompt'],generated=target.relative_to(ROOT).as_posix(),generation_status='rejected_geometry_and_continuity')
 write(OUT/'batch-108/jobs.json',jobs)
 jobs=read(OUT/'batch-116/jobs.json');blocked={r['source']:r for r in pilots['entries'] if r['key']=='bulbasaur'};char=read(W/'charmander-job.json');blocked[char['source']]=char
 for entry in jobs['entries']:
  if entry['source'] in blocked:
   item=blocked[entry['source']];entry.update(prompt=item['prompt'],generated=None,error=item['error'],generation_status='tool_rejected_original_preserved_after_visual_review')
 write(OUT/'batch-116/jobs.json',jobs)
 for name in ('ui','player','battle','trainers'):
  profile=f'texture-p2-dex-remaining-{name}-20261030';cleanup=read(OUT/f'p2-evidence/dex/{profile}-cleanup.json')
  assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
  stage=ROOT/'temp/multiplayer'/profile;assert not list(stage.rglob('*.log')) and not (stage/'mkxp.json').exists()
 concurrent=[p for p,h in read(W/'session-protected.json')['files'].items() if digest(ROOT/p)!=h]
 assert not concurrent,'Concurrent source changes need a separate review: '+str(concurrent)
 inventory=read(OUT/'inventory.json');assert (inventory['applied'],inventory['preserved'],inventory['pending'])==(267,2302,16096)
 plan=read(OUT/'execution-plan/plan.json');index={r['id']:r for r in plan['batch_index']}
 assert all(index[f'batch-{n:03}']['status']=='completed' for n in range(58,152))
 assert all(index[f'batch-{n:03}']['status']!='completed' for n in range(152,858))
 for priority in plan['priorities']:
  if priority['priority']=='P2':priority.update(status='completed',applied_files=15,preserved_files=2208)
 for stage in plan['stages']:
  if stage['priority']=='P2':
   receipts=[read(OUT/b/'validation.json') for b in stage['batch_ids']]
   stage.update(status='completed',applied_files=sum(r['applied'] for r in receipts),preserved_files=sum(r['preserved'] for r in receipts))
 plan['completed_priorities']=['P1','P2'];plan['execution_updated_date']='2026-10-30';write(OUT/'execution-plan/plan.json',plan)
 resume=read(OUT/'p2-work/resume.json');resume.update(status='completed',completed_through='batch-151',next_batch=None,candidate_pending_review=[]);write(OUT/'p2-work/resume.json',resume)
 cleanup=read(E/'periodic-cache-cleanup.json');cache=(OUT/'__pycache__').resolve();assert cache.is_relative_to(ROOT.resolve());removed=[]
 if cache.exists():
  for p in cache.glob('*.pyc'):
   assert not p.is_symlink() and p.resolve().is_relative_to(cache);removed.append({'path':p.relative_to(ROOT).as_posix(),'bytes':p.stat().st_size});p.unlink()
 cleanup['final_bytecode_sweep']=removed;cleanup['bytes_reclaimed_losslessly']=sum(r['original_bytes']-r['archive_bytes']-r['summary_bytes'] for r in cleanup['lossless_archives'])
 write(E/'periodic-cache-cleanup.json',cleanup)
 write(E/'checkpoint-verification.json',{'status':'passed','date':'2026-10-30','all_p2_source_original_delivery_hashes_verified':2223,
  'completed_batches':94,'new_batches':48,'new_files_preserved':1218,'new_files_applied':0,'applied':15,'preserved':2208,
  'candidate_pending_review':0,'inventory':{k:inventory[k] for k in ('total','applied','preserved','pending')},
  'concurrent_source_changes':concurrent,'temporary_logs_remaining':0,'chinese_images_test':'CHINESE_IMAGES_PASS images=111',
  'scope':'P2 processing/review complete, including explicit preservation decisions. This is not a claim that all assets were redrawn or that full gameplay/device/release validation is complete.'})
 readme=OUT/'README.zh-CN.md';old=readme.read_text(encoding='utf-8');split=old.index('## P1 第 5～57 批')
 history=E/'progress-before-completion.zh-CN.md'
 if not history.exists():history.write_text('# 完成前的历史快照（截至第 103 批）\n\n'+old[:split],encoding='utf-8')
 header='''# 游戏贴图高清化进度（2026-10-30）

## P2 处理与验收已完成

**第 58～151 批全部完成：2,223 / 2,223 张，15 张已应用、2,208 张保留原图，待验收候选为 0。** “完成”包含逐项审查后保留原图，不表示所有图片均已重绘。第 104～151 批本轮 1,218 张全部保留；没有新的游戏图片替换，也没有修改其他会话的源码或本地化关联表。

| P2 范围 | 完成数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 58～63 批：战斗界面 | 121 | 6 | 115 |
| 第 64～76 批：队伍、背包、摘要与通用菜单 | 288 | 0 | 288 |
| 第 77～93 批：图鉴、仓库与命名界面 | 374 | 4 | 370 |
| 第 94～102 批：地图、导航、帮助与训练师卡 | 202 | 5 | 197 |
| 第 103～105 批：标题、载入与启动界面 | 49 | 0 | 49 |
| 第 106～107 批：全景与场景背景 | 17 | 0 | 17 |
| 第 108～113 批：主角身体与动作 | 82 | 0 | 82 |
| 第 114～115 批：初始服装、发型与帽子 | 43 | 0 | 43 |
| 第 116～145 批：默认宝可梦战斗图 | 917 | 0 | 917 |
| 第 146～151 批：训练师立绘与背面帧表 | 130 | 0 | 130 |
| 合计 | 2,223 | 15 | 2,208 |

全局 18,665 张：267 张已应用、2,302 张保留、16,096 张待处理。P1 与 P2 已完成；P3～P5 保留后续计划且未开始（下一整体计划批次为 152）。没有后台生成或定时任务。

本轮逐张审查了 91 张原尺寸素材总览。小型像素精灵、服装碎片、细窄肢体与功能图层已有清楚色块；严格保留逐像素透明轮廓时，内部纹理不能消除像素边界，容易改变身份、衣物遮挡或物种细节。每张具体理由、原图/交付哈希见各批 `validation.json` 与 `jobs.json`。两个目录中的同编号图可能有不同姿态，已分别检查，没有把它们当作正背面配对。

内置 image_gen 的一份行走试制图改变了全部 16 格的边界与锚点，已拒绝；原图、生成图、完整提示词与验收记录保存在第 108 批及 [试制记录](p2-remaining-work/pilot-jobs.json)。妙蛙种子和小火龙各一次提案被内置工具拒绝，错误及提示词保留在第 116 批和 [第二份试制记录](p2-remaining-work/charmander-job.json)，没有切换外部 API。保留决定依据逐项原尺寸审查，未把生成失败写成生成成功或已应用。

## 本轮原生验证证据

- [验收汇总](p2-evidence/remaining/native-validation.json)：1,218 张来源全部解码并核对原图哈希；中英文标题/载入/全景 92 组显示，全景 204 个偏移检查包含完整宽/高重复位置。
- [人物叠穿](p2-evidence/remaining/player-review.json)：138 组肤色/服装/发型/帽子外观、15,456 个方向/动作/格位状态和 464 个冲浪/潜水底层状态。实际 Sprite_Player、Sprite_Wearable 与 Sprite_SurfBase 的裁切、偏移、叠层及回到 walk 的锚点一致；[原生叠穿预览](p2-evidence/remaining/native-layering-preview.png)。Game_Character 四个速度的循环为 20/10/16/8 次更新，40fps 标称 500/250/400/200ms；这是固定输入部件测试，不是完整地图动作事件流程。
- [战斗图与旧帧表](p2-evidence/remaining/battle-review.json)：470 个物种、940 组实际前后面指标/镜像、47,000 个选择浮动/目标闪烁状态，完整组合周期 24 次更新（40fps 标称 600ms）。另有 12 组代表闪光变色，未穷尽全部色变/形态组合。
- [训练师场景](p2-evidence/remaining/trainers-review.json)：121 张静态图通过实际 pbCreateTrainerFrontSprite 的显式图片覆盖接口显示在对手战斗坐标；9 张五格旧背面条图通过实际 PictureEx 投掷序列，帧序为 1→2→3→4→0。旧条图属于兼容资源；当前主角使用叠穿正面肖像。当前主角构建截图还在初始屏外位置，不能当作完整战斗入场验收。
- [最终恢复点复核](p2-evidence/remaining/checkpoint-verification.json)：全部 2,223 张 P2 的当前文件、原图备份、交付副本一致；111 张中文图片校验通过。补齐第 58～63 批早期只保存在 ready/ 的正式 delivery/ 副本，见 [档案补齐记录](p2-evidence/remaining/archive-repairs.json)。

每轮测试都通过 finally 停止本轮进程并清理临时日志/配置；原始大轨迹无损压缩为 `*-full.json.gz`，JSON 汇总保留解压后哈希及归档位置。必要原图、生成图和截图继续保留；未确认可从远程恢复的图片没有删除。清理详情见 [缓存记录](p2-evidence/remaining/periodic-cache-cleanup.json)。

此前已应用的 15 张及原生证据继续保留：[战斗 UI](p2-evidence/ui-native-validation.json)、[背包拒绝候选](p2-evidence/bag-native-validation.json)、[图鉴/仓库/命名](p2-evidence/dex/checkpoint-verification.json)、[地图与训练师卡](p2-evidence/region/checkpoint-verification.json)、[标题](p2-evidence/titles/native-validation.json)。早期文字说明保存在 [历史快照](p2-evidence/remaining/progress-before-completion.zh-CN.md)。

**完整游玩、全部地图/动作事件与场景切换、全部色变组合、Android 实机及最终发布包验证尚未完成。** 当前恢复点为 [p2-progress.json](p2-progress.json)、[p2-work/resume.json](p2-work/resume.json)及 [最终阶段记录](p2-remaining-work/resume.json)。特性分支为 `codex/texture-hd-p2`，本地提交回执在 `commit-receipt.json`；是否推送以该回执及远程查询为准。

'''
 readme.write_text(header+old[split:],encoding='utf-8')
 path=OUT/'execution-plan/README.zh-CN.md';text=path.read_text(encoding='utf-8');lines=text.splitlines()
 lines=['**2026-10-30：P1、P2 全部处理与验收完成；P2 第 58～151 批共 2,223 张，15 张应用、2,208 张保留，无待验收候选。** 全局 267 张应用、2,302 张保留、16,096 张待处理；P3～P5 未开始，下一整体计划批次为 152。见[当前结果与证据](../README.zh-CN.md)及 [P2 机器进度](../p2-progress.json)。' if line.startswith('**2026-10-30：P1') else line for line in lines]
 text='\n'.join(lines)+'\n';text=text.replace('当前 P1 以及 P2 第 58～103 批状态为 `completed`','当前 P1 以及 P2 第 58～151 批状态为 `completed`')
 text+='\n2026-10-30 最终更新：第 104～151 批 1,218 张逐项保留，理由、失败试制和原生检查均已保存。P2.status=completed，next_batch=null；整体计划仍为 in_progress，下一批 152 属于未开始的 P3。原尺寸像素美术的保留不表示已重绘；完整游玩、所有事件动作、Android 实机与发布包未验证。每轮日志清理、无损轨迹压缩及远程可恢复性策略见 ../p2-evidence/remaining/periodic-cache-cleanup.json。\n';path.write_text(text,encoding='utf-8')
 path=OUT/'execution-plan/stage-summary.zh-CN.md';lines=path.read_text(encoding='utf-8').splitlines();lines[4]='2026-10-30：P1、P2 全部处理与验收完成。P2 第 58～151 批共 2,223 张：15 张应用、2,208 张保留，剩余 0。本轮第 104～151 批 1,218 张均有保留理由与原生证据；P3～P5 保留后续计划且未开始。完整游玩、全部事件动作、Android 实机和发布包仍未验证。';path.write_text('\n'.join(lines)+'\n',encoding='utf-8')
 print({'P2':'completed','files':2223,'applied':15,'preserved':2208,'delivery_archives_repaired':sum(len(r['files']) for r in repairs),'cache_bytes_reclaimed':cleanup['bytes_reclaimed_losslessly']})


if __name__=='__main__':main()
