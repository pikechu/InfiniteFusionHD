"""Verify the applied region checkpoint and update human/machine recovery records."""
import ast
from pathlib import Path
from resume_p2_menu import ROOT,OUT,read,write,digest
from update_p2_progress import update_progress,self_check
W=OUT/'p2-region-work';E=OUT/'p2-evidence/region'
self_check()
for name in ('p2_region_work.py','prepare_p2_region.py','validate_p2_region.py','finish_p2_region.py','finalize_p2_region.py'):ast.parse((OUT/name).read_text(encoding='utf-8-sig'),filename=name)
p=update_progress();assert (p['completed_files'],p['applied_files'],p['preserved_files'],p['remaining_files'],p['next_batch'])==(985,15,970,1238,'batch-103')
inv=read(OUT/'inventory.json');assert (inv['applied'],inv['preserved'],inv['pending'])==(267,1064,17334)
completed={}
for n in range(58,103):
 receipt=read(OUT/f'batch-{n:03}/validation.json');assert receipt['status']=='completed'
 for e in receipt['entries']:
  h=e['after_sha256'] if e['status']=='applied' else e['sha256'];assert digest(ROOT/e['source'])==h,e['source'];completed[e['source']]=h
  if n>=94:
   assert digest(OUT/f'batch-{n:03}/delivery'/e['source'])==h
   assert digest(OUT/f'batch-{n:03}/originals'/e['source'])==e.get('before_sha256',e.get('sha256'))
audit=read(OUT/'p2-audit.json')
for row in audit['sources']:assert digest(ROOT/row['source'])==completed.get(row['source'],row['sha256']),row['source']
for n in (95,98,99,100):
 batch=OUT/f'batch-{n:03}'
 for e in read(batch/'manifest.json')['entries']:
  for folder,key in [('originals','before_sha256'),('ready','after_sha256'),('generated','generated_sha256')]:assert digest(batch/folder/e['source'])==e[key]
protected=read(W/'session-protected.json')['files'];external=[s for s,h in protected.items() if not (ROOT/s).exists() or digest(ROOT/s)!=h]
for source in ('Data/Scripts/050_Outfits/001_OutfitsMain/LayeredClothes.rb','Data/Scripts/015_Trainers and player/004_Player.rb'):assert digest(ROOT/source)==protected[source]
cleanup=[]
for phase in ('before','candidate'):
 for kind in ('region','region-outfits'):
  profile=f'texture-p2-dex-{kind}-{phase}-20261029';d=read(OUT/f'p2-evidence/dex/{profile}-cleanup.json')
  assert d['process_exited'] and not d['remaining_temporary_logs'];assert not list((ROOT/'temp/multiplayer'/profile).rglob('*.log'));cleanup.append(profile)
proof=read(E/'native-validation.json');assert proof['native_screen_pairs']==688 and proof['combined_loop_updates']==480
write(E/'checkpoint-verification.json',{'status':'passed','date':'2026-10-29','all_p2_source_hashes_verified':2223,'completed_source_hashes_verified':985,
 'new_sources_and_deliveries_verified':202,'new_applied':5,'new_preserved':197,'candidate_pending_review':0,'progress':p,
 'inventory':{s:inv[s] for s in ('total','applied','preserved','pending')},'concurrent_source_changes_preserved':external,
 'cleanup_profiles_checked':cleanup,'temporary_logs_remaining':0,'chinese_images_test':'CHINESE_IMAGES_PASS images=111 atlas_dimensions=preserved outside_text_regions=unchanged apk_inventory=covered'})
cv=read(W/'candidate-validation.json');cv.update(status='applied_verified',note='All five candidates passed native acceptance and match installed/delivery checksums.')
for row in cv['entries']:row['state']='applied'
write(W/'candidate-validation.json',cv)
for name in ('card-jobs.json','map-job.json'):
 d=read(W/name);d.update(status='applied_verified',native_validation='output/texture-hd/p2-evidence/region/native-validation.json');write(W/name,d)
audit.update(progress_snapshot=p,latest_review='output/texture-hd/p2-evidence/region/checkpoint-verification.json');write(OUT/'p2-audit.json',audit)
current='''**P2 第 58～102 批已完成：985 / 2,223 张，15 张已应用、970 张保留原图，剩余 1,238 张；下一批为第 103 批。** 本轮第 94～102 批共 202 张，新增应用 5 张、保留 197 张。P1 及此前 P2 的已完成结果继续保留。

| P2 范围 | 完成数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 58～63 批：战斗界面 | 121 | 6 | 115 |
| 第 64～76 批：队伍、背包、摘要与通用菜单 | 288 | 0 | 288 |
| 第 77～93 批：图鉴、仓库与命名界面 | 374 | 4 | 370 |
| 第 94～102 批：地区地图、导航、帮助与训练师卡 | 202 | 5 | 197 |
| 合计 | 985 | 15 | 970 |

全局 18,665 张：**267 张已应用、1,064 张保留、17,334 张待处理**。候选待验收为 0；第 103～151 批及 P3～P5 保留在后续计划。没有后台生成或定时任务。

本轮内置 `image_gen` 编辑了地图与金/银/铜三种卡面，共 4 份原始生成图。地图结果制作成通关前、通关后两张交付图；仅增加海水内部细节，路线、城市、地形和海岸像素受保护，两状态的有符号像素差值完全保持。三种卡面共用细微材质明暗，并保护圆形水印、文字区、徽章区和透明边界；三种原配色之间的差值保持。交付仍为原尺寸，地图单通道变化最多 8/255，卡面最多 12/255。

已应用文件为 `Graphics/Pictures/map/map.png`、`map_postgame.png`，以及 `Graphics/Pictures/Trainer Card/backgrounds/BRONZE.png`、`GOLD.png`、`SILVER.png`。本轮五张均没有中文图片映射，关联表无需改写。其余 197 张保留理由见逐批 `validation.json` 和 [审查决定](p2-evidence/region/review-decisions.json)。

- [原生场景验收](p2-evidence/region/native-validation.json)：688 组原图/候选画面对比，保护区域像素完全一致；覆盖 93 种卡面、中英文、男女、通关前后、16 枚徽章、导航选中与循环、帮助四页及 Tutor.net 四种样式。
- [真实人物叠穿对比](p2-evidence/region/trainer-card-native-comparison.png)：48 组画面、16 组实际外观组合，包含 Red/Leaf 与初始睡衣。身体、服装、头发合成的肖像像素及锚点前后一致。主场景测试的新游戏默认临时服装另外由此补测覆盖；未将其当作完整换装动作验收。
- [地图原尺寸对比](p2-evidence/region/map-native-comparison.png)：四组地图运行，每组 802 次更新。完整组合动画循环为 480 次更新（按 40fps 标称 12 秒）；光标 24 次/600ms、飞行点 40 次/1,000ms、边缘箭头 32 次/800ms。前后帧序、周期、滚动与锚点轨迹一致，详见 `before-review.json` / `candidate-review.json`。这份完整循环证据是原生轨迹记录，不是 480 张逐帧截图。
- 15 组旧地图进度资源及中英文版本逐字节保留。Tutor.net 的四格 PNG 在当前界面中只绘制第一格，不伪称已播放四帧动画。旧申请表、旧地图和其他兼容布局按用途/原尺寸复核并保留，未宣称完成全部事件流程。
- 111 张中文图片校验通过。[最终恢复点复核](p2-evidence/region/checkpoint-verification.json)核对全部 2,223 张 P2 源文件、985 张已完成项及本轮 202 张交付副本。每轮隐藏原生测试均已退出，临时原始日志和配置由 `finally` 清理；必要截图与有界失败摘要保留。

完整提示词和生成来源见 [卡面记录](p2-region-work/card-jobs.json)、[地图记录](p2-region-work/map-job.json)。各批原图在 `originals/`、生成提案在 `generated/`、应用候选在 `ready/`、交付副本在 `delivery/`；`manifest.json` 记录已应用文件。逐批 `jobs.json` 也明确记录未生成素材的保留原因。

此前第 77～93 批的 498 组仓库画面对比、200 种壁纸和图鉴/命名记录在 [上一阶段验收](p2-evidence/dex/checkpoint-verification.json)。背包 32 份候选因无可见收益仍未应用，见 [背包验收](p2-evidence/bag-native-validation.json)；战斗 UI 的 120 种状态及 12 组 HP/EXP 动画证据见 [战斗验收](p2-evidence/ui-native-validation.json)。中文摘要学习招式页的原有文字/精灵区域重叠记录继续保留。

**完整游玩、人物/服装全部地图动作与叠穿、Android 实机及发布包验证尚未完成。** 当前恢复点为 [p2-progress.json](p2-progress.json)、[p2-work/resume.json](p2-work/resume.json)及 [本轮恢复记录](p2-region-work/resume.json)。Git 保存记录见 [commit-receipt.json](commit-receipt.json)。

'''
path=OUT/'README.zh-CN.md';text=path.read_text(encoding='utf-8');start=text.index('## 当前进度\n\n')+len('## 当前进度\n\n');end=text.index('## P1 第 5～57 批（已完成）')
text=text[:start]+current+text[end:];text=text.replace('# 游戏贴图高清化进度（2026-10-28）','# 游戏贴图高清化进度（2026-10-29）',1);path.write_text(text,encoding='utf-8')
path=OUT/'execution-plan/README.zh-CN.md';lines=path.read_text(encoding='utf-8').splitlines()
for i,line in enumerate(lines):
 if line.startswith('**2026-10-28') or line.startswith('**2026-10-29'):
  lines[i]='**2026-10-29：P1 全部完成；P2 第 58～102 批完成 985 张（15 张应用、970 张保留），P2 尚余 1,238 张，下一批为第 103 批。** 全局 267 张应用、1,064 张保留、17,334 张待处理。本轮第 94～102 批新增 5 张，197 张保留；见[当前结果与对比](../README.zh-CN.md)和 [P2 机器进度](../p2-progress.json)。'
text='\n'.join(lines)+'\n';text=text.replace('说“执行第 94 批”：读取 [第 94 批清单](batches/batch-094.json)','说“执行第 103 批”：读取 [第 103 批清单](batches/batch-103.json)').replace('P2 第 58～93 批状态为','P2 第 58～102 批状态为');path.write_text(text,encoding='utf-8')
path=OUT/'execution-plan/stage-summary.zh-CN.md';lines=path.read_text(encoding='utf-8').splitlines()
for i,line in enumerate(lines):
 if line.startswith('2026-10-28：') or line.startswith('2026-10-29：'):lines[i]='2026-10-29：P1 全部完成；P2 前四阶段（58～102）完成 985 张，15 张应用、970 张保留。本轮地区地图/导航/帮助/训练师卡 202 张，应用 5 张，保留 197 张。下一批为 103，P2 剩余 1,238 张；后续阶段和 P3～P5 未开始。'
path.write_text('\n'.join(lines)+'\n',encoding='utf-8')
print({'status':'checkpoint_verified','completed':985,'applied':15,'preserved':970,'remaining':1238,'next':'batch-103','external_source_changes_preserved':external})
