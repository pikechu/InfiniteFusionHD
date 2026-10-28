"""Check final hashes/cleanup and update P2 checkpoint documentation."""
from pathlib import Path
import json,sys,ast
from PIL import Image
from resume_p2_menu import ROOT,OUT,read,write,digest
from update_p2_progress import update_progress,self_check
E=OUT/'p2-evidence/dex';W=OUT/'p2-dex-work'
self_check()
for name in ('p2_dex_work.py','run_p2_native.py','prepare_p2_wallpapers.py','validate_p2_storage.py','finish_p2_dex.py','finalize_p2_dex.py'):
 ast.parse((OUT/name).read_text(encoding='utf-8-sig'),filename=name)
p=update_progress()
assert (p['completed_files'],p['applied_files'],p['preserved_files'],p['remaining_files'],p['next_batch'])==(783,10,773,1440,'batch-094')
inv=read(OUT/'inventory.json')
assert (inv['applied'],inv['preserved'],inv['pending'])==(262,867,17536)
known={}
for n in range(58,94):
 d=read(OUT/f'batch-{n:03}/validation.json')
 assert d['status']=='completed'
 for entry in d['entries']:
  expected=entry['after_sha256'] if entry['status']=='applied' else entry['sha256']
  assert digest(ROOT/entry['source'])==expected,entry['source']
  known[entry['source']]=expected
  if n>=77:
   assert digest(OUT/f'batch-{n:03}/delivery'/entry['source'])==expected
   assert digest(OUT/f'batch-{n:03}/originals'/entry['source'])==entry.get('before_sha256',entry.get('sha256'))
audit=read(OUT/'p2-audit.json')
for row in audit['sources']:
 assert digest(ROOT/row['source'])==known.get(row['source'],row['sha256']),row['source']
for n in (77,85):
 batch=OUT/f'batch-{n:03}'
 for entry in read(batch/'manifest.json')['entries']:
  for folder,key in [('originals','before_sha256'),('ready','after_sha256'),('generated','generated_sha256')]:assert digest(batch/folder/entry['source'])==entry[key]
for n in (77,83):
 d=read(OUT/f'batch-{n:03}/candidate-manifest.json')
 assert d['applied'] is False and d['status']=='rejected_no_visible_gain'
for profile in ('storage-before-final','storage-candidate-final','naming-verified'):
 cleanup=read(E/f'texture-p2-dex-{profile}-cleanup.json')
 assert cleanup['process_exited'] and not cleanup['remaining_temporary_logs']
 stage=ROOT/'temp/multiplayer'/f'texture-p2-dex-{profile}'
 assert not list(stage.rglob('*.log'))
protected=read(W/'session-protected.json')['files']
external=[source for source,h in protected.items() if digest(ROOT/source)!=h]
# Concurrent work is reported, never rolled back. Verified consumer hashes are checked separately.
for doc in (read(E/'storage-candidate-review.json'),read(E/'dex-naming-review.json')):
 for source,h in doc['script_sha256'].items():assert digest(ROOT/source)==h,'Verified consumer changed: '+source
for key in ('storage-before-review.json','storage-candidate-review.json'):
 doc=read(E/key);assert len(doc['renders'])==498
with Image.open(E/'storage-cursor-loop-comparison.gif') as im:
 duration=0
 for frame in range(im.n_frames):im.seek(frame);duration+=im.info['duration']
 assert duration==1000
write(E/'checkpoint-verification.json',{'status':'passed','all_p2_source_hashes_verified':2223,'completed_sources_verified':783,
 'new_stage_sources_and_delivery_copies_verified':374,'newly_applied':4,'newly_preserved':370,'rejected_candidate_files':2,
 'candidate_pending_review':0,'progress':p,'global_inventory':{key:inv[key] for key in ('total','applied','preserved','pending')},
 'external_source_changes_during_work_preserved':external,'scenes_consumer_hashes_current':True,
 'cleanup':'Every native run used hidden isolated saves, discarded stdout/stderr, bounded runtime and immediate finally cleanup. No temporary raw logs remain for this task.',
 'chinese_images_test':'CHINESE_IMAGES_PASS images=111 atlas_dimensions=preserved outside_text_regions=unchanged apk_inventory=covered'})
audit.update(progress_snapshot=p,latest_review='output/texture-hd/p2-evidence/dex/checkpoint-verification.json');write(OUT/'p2-audit.json',audit)
for n in (0,16,17):
 job=read(W/f'box{n}-job.json');decision=read(W/f'box{n}-decision.json')
 job.update(status=decision['state'],reason=decision['reason'],validation='output/texture-hd/p2-evidence/dex/storage-native-validation.json');write(W/f'box{n}-job.json',job)
wallpapers=read(W/'wallpaper-validation.json')
for row in wallpapers:
 number=int(Path(row['source']).stem[3:])
 row.update(state='applied' if number in (16,17) else 'preserved',candidate_pending_review=False,validation='output/texture-hd/p2-evidence/dex/storage-native-validation.json')
write(W/'wallpaper-validation.json',wallpapers)
resume=read(W/'resume.json');resume.update(status='completed',completed_through='batch-093',next_batch='batch-094',candidate_pending_review=[]);write(W/'resume.json',resume)
text='''**P2 第 58～93 批已完成：783 / 2,223 张，10 张已应用、773 张保留原图，剩余 1,440 张；下一批为第 94 批。** 本轮完成第 77～93 批共 374 张，新增应用 4 张、保留 370 张。P1 和此前 P2 的已完成结果继续保留。

| P2 范围 | 完成数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 58～63 批：战斗界面 | 121 | 6 | 115 |
| 第 64～76 批：队伍、背包、摘要与通用菜单 | 288 | 0 | 288 |
| 第 77～93 批：图鉴、仓库与命名界面 | 374 | 4 | 370 |
| 合计 | 783 | 10 | 773 |

全局 18,665 张：**262 张已应用、867 张保留、17,536 张待处理**。候选待验收为 0；第 94～151 批及 P3～P5 保留在后续计划。没有后台生成或定时任务。

本轮使用内置 `image_gen` 编辑 3 张壁纸，原始提案、完整提示词、尺寸/透明通道/轮廓验证保存在 `p2-dex-work/box*-job.json`、`box*-generated.png` 和 [壁纸结构检查](p2-dex-work/wallpaper-validation.json)。火鸟和水系剪影只引入内部柔和明暗，标题、按钮、边框、姿态、强轮廓和气泡/星点原位保留。已应用 `Graphics/Pictures/box16.png`、`box17.png` 与逐像素同源的 `Graphics/Pictures/Storage/box_32.png`、`box_33.png`；对应第 77、85 批，单通道变化不超过 12/255。草地提案主要改变亮度，未改善辨识度，连同在用副本共 2 张保留原图，候选已归档。

- [仓库原生前后验收](p2-evidence/dex/storage-native-validation.json)：两种语言各显示 200 种壁纸，并断言实际加载编号；498 组前后截图和动画/交互轨迹比对通过。壁纸内部以外的像素完全一致，光标 40 次更新、1,000ms 完整循环；抓取/放置各 17 次更新，换箱、队伍面板开关和壁纸淡入淡出轨迹相同。
- [在用壁纸原尺寸对比](p2-evidence/dex/wallpaper-native-comparison.png)，左为原图、右为交付；[完整光标循环对比](p2-evidence/dex/storage-cursor-loop-comparison.gif)。
- [图鉴与命名验收](p2-evidence/dex/dex-naming-validation.json)：146 张中英文原生截图，包含 16 组命名标签状态、首尾返回、三种光标区域、仓库命名图标、图鉴列表、七类搜索参数、资料和形态页。当前引擎跳过图鉴分布页，旧深色主题/分布页/兼容图只做用途、解码和布局复核并保留原图，不宣称当前场景实际加载。
- 111 张中文图片校验通过，关联表未被本轮修改。新增的 4 张均无中文配套映射。其他保留素材的逐文件理由见 [审查决定](p2-evidence/dex/review-decisions.json)及第 77～93 批 `validation.json`。
- [恢复点复核](p2-evidence/dex/checkpoint-verification.json)：2,223 张 P2 源文件、783 张已完成项和本轮 374 张交付副本哈希核对通过。进度继续由已完成批次的 `validation.json` 汇总。

第 77、85 批 `manifest.json` 仅列已应用结果；原图在 `originals/`，生成图在 `generated/`，应用候选在 `ready/`，最终交付副本在 `delivery/`。第 77、83 批另有 `candidate-manifest.json` 保存已拒绝草地候选，不能计为已应用。其他批次 `jobs.json` 记录未生成的具体理由。

原生测试每轮使用独立 Profile、隐藏窗口和隔离存档，设置超时，stdout/stderr 直接丢弃；每轮 `finally` 清理临时日志和配置，保留可复用的只读运行文件与存档。早期壁纸验收因缓存未刷新作废，修正并加断言后重跑；仅最终带 `-final`/`-verified` 的清理及验收记录用于交付。正式证据保存在约定输出目录。

此前背包 32 份候选因无可见收益归档，仍未应用；[背包原生验收](p2-evidence/bag-native-validation.json)的 280 组对比、8 帧/800ms 箭头循环，以及 [战斗 UI 验收](p2-evidence/ui-native-validation.json)的 120 种指令状态和 12 组 HP/EXP 动画轨迹继续有效。中文摘要学习招式页原有的文字/精灵区域重叠记录继续保留。

**完整游玩、人物/服装叠穿、Android 实机与发布包验证尚未完成。** 当前恢复点为 [p2-progress.json](p2-progress.json)、[p2-work/resume.json](p2-work/resume.json)、[本阶段恢复记录](p2-dex-work/resume.json)。

'''
path=OUT/'README.zh-CN.md';old=path.read_text(encoding='utf-8');start=old.index('## 当前进度\n\n')+len('## 当前进度\n\n');end=old.index('## P1 第 5～57 批（已完成）');path.write_text(old[:start]+text+old[end:],encoding='utf-8')
path=OUT/'execution-plan/README.zh-CN.md';old=path.read_text(encoding='utf-8');lines=old.splitlines()
for index,line in enumerate(lines):
 if line.startswith('**2026-10-28 执行进度：'):
  lines[index]='**2026-10-28：P1 第 5～57 批全部完成；P2 第 58～93 批完成 783 张（10 张应用、773 张保留），P2 尚余 1,440 张，下一批为第 94 批。** 全局 262 张应用、867 张保留、17,536 张待处理。本轮第 77～93 批的 374 张中新增应用 4 张剪影壁纸及副本，其余 370 张保留。见[当前结果与对比](../README.zh-CN.md)和 [P2 机器进度](../p2-progress.json)。'
old='\n'.join(lines)+'\n';old=old.replace('说“执行第 77 批”：读取 [第 77 批清单](batches/batch-077.json)','说“执行第 94 批”：读取 [第 94 批清单](batches/batch-094.json)').replace('P2 第 58～76 批状态为','P2 第 58～93 批状态为')
old+='\n第 77～93 批已逐项完成；第 77、85 批的 manifest 记录已应用 4 张，第 77、83 批 candidate-manifest 记录拒绝的 2 张草地提案。清理和动画证据见 p2-evidence/dex/。\n';path.write_text(old,encoding='utf-8')
path=OUT/'execution-plan/stage-summary.zh-CN.md';old=path.read_text(encoding='utf-8');lines=old.splitlines()
for index,line in enumerate(lines):
 if line.startswith('2026-10-28：'):
  lines[index]='2026-10-28：P1 全部完成；P2 前三阶段（58～93）完成 783 张，10 张应用、773 张保留。本轮图鉴/仓库/命名 374 张，应用 4 张，保留 370 张。下一批为 94，P2 剩余 1,440 张；后续阶段及 P3～P5 未开始。'
path.write_text('\n'.join(lines)+'\n',encoding='utf-8')
print(json.dumps({'status':'checkpoint_verified','completed_files':p['completed_files'],'new_applied':4,'new_preserved':370,'next_batch':p['next_batch'],'external_changes_preserved':external},ensure_ascii=False))
