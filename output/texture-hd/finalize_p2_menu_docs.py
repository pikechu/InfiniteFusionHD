"""Maintain the verified P2 checkpoint documentation and final consistency checks."""
from pathlib import Path
import json
import py_compile
from PIL import Image
from resume_p2_menu import ROOT, OUT, read, write, digest
from update_p2_progress import update_progress, self_check

self_check()
for name in ('resume_p2_menu.py','finish_p2_menu.py','validate_p2_bag.py','update_p2_progress.py','finish_p2_ui.py'):
    py_compile.compile(str(OUT/name),doraise=True)
progress=update_progress()
assert (progress['completed_files'],progress['applied_files'],progress['preserved_files'],progress['remaining_files'],progress['next_batch'])==(409,6,403,1814,'batch-077')
inventory=read(OUT/'inventory.json')
assert (inventory['applied'],inventory['preserved'],inventory['pending'])==(258,497,17910)
by_path={row['path']:row for row in inventory['assets']}
for number in range(58,77):
    receipt=read(OUT/f'batch-{number:03}/validation.json')
    for entry in receipt['entries']:
        expected=entry['after_sha256'] if entry['status']=='applied' else entry['sha256']
        assert digest(ROOT/entry['source'])==expected
        assert by_path[entry['source']]['status']==entry['status']
        if number>=64:
            for folder in ('originals','delivery'):
                assert digest(OUT/f'batch-{number:03}'/folder/entry['source'])==expected
    if number>=64:
        receipt['known_findings']=['Existing Chinese summary move-learning text/sprite overlap; original resources retained. See menu-native-validation.json.']
        receipt['evidence']=list(dict.fromkeys(receipt['evidence']+['output/texture-hd/p2-evidence/menu-native-validation.json']))
        write(OUT/f'batch-{number:03}/validation.json',receipt)
for number in (64,68):
    batch=OUT/f'batch-{number:03}'
    assert not (batch/'manifest.json').exists()
    candidate=read(batch/'candidate-manifest.json')
    assert candidate['status']=='rejected_no_visible_gain' and candidate['applied'] is False
    for entry in candidate['entries']:
        for folder,key in [('originals','before_sha256'),('ready','after_sha256'),('generated','generated_sha256')]:
            assert digest(batch/folder/entry['source'])==entry[key]
proof=read(OUT/'p2-evidence/native-menu/menus-review.json')
for label in proof['renders']:
    with Image.open(OUT/'p2-evidence/native-menu'/f'{label}.png') as image:
        image.load()
        assert image.size==(512,384)
for path,expected in proof['script_sha256'].items():assert digest(ROOT/path)==expected
for path in (OUT/'p2-evidence/native-menu').glob('bag-*-loop-comparison.gif'):
    with Image.open(path) as image:
        duration=0
        for frame in range(image.n_frames):
            image.seek(frame);duration+=image.info['duration']
        assert duration==800,(path,duration)
findings=[{'status':'pre_existing','scene':'Chinese summary move-learning',
           'description':'Move detail text/type blocks overlap the existing Pokemon display region in the unmodified production scene. No image or game script changes were made to resolve this separate layout issue.',
           'evidence':'output/texture-hd/p2-evidence/native-menu/summary-2-move-1-3.png'}]
write(OUT/'p2-evidence/menu-native-validation.json',{'status':'passed_with_existing_layout_findings',
      'native_images_decoded':288,'party_summary_ready_renders':96,'languages':['English','zh-CN'],
      'party_states':['selected','unselected','fainted','fainted_selected','swap','swap_selected','swap_target','blank','cancel','multi_confirm'],
      'summary_states':['pages_1_to_4_and_reverse','move_details','learn_move','marking_cursor','egg'],
      'ready_menu_states':['item_selected','item_unselected','move_selected','move_unselected'],
      'preserved_assets':288,'newly_applied':0,'all_288_original_and_delivery_sha256_identical':True,
      'chinese_image_check':'CHINESE_IMAGES_PASS images=111 atlas_dimensions=preserved outside_text_regions=unchanged apk_inventory=covered',
      'known_findings':findings,'limitations':'Native rendering and targeted input checks, not full gameplay, exhaustive UI layout, body/clothing layering, Android device or release package validation.'})
write(OUT/'p2-evidence/menu-checkpoint-verification.json',{'status':'passed','p2_sources_checked_at_resume':2223,'completed_sources_rechecked':409,
      'menu_preserved_sources_and_copies_checked':288,'rejected_candidate_triples_checked':32,'candidate_pending_review':0,
      'progress':progress,'inventory_counts':{s:inventory[s] for s in ('total','applied','preserved','pending')},
      'progress_self_check':'Synthetic completed/partial receipts checked; unreviewed candidate rejected; actual progress remains 409 after refresh.'})
for name in ('bag-jobs.json','bag-validation.json','bag-tasks.json'):
    path=OUT/'p2-work'/name
    data=read(path)
    if isinstance(data,dict):data.update(status='reviewed_preserved',candidate_pending_review=0,newly_applied=0,native_validation='output/texture-hd/p2-evidence/bag-native-validation.json')
    else:
        for row in data:row.update(review_status='preserved_no_visible_gain',native_validation='output/texture-hd/p2-evidence/bag-native-validation.json')
    write(path,data)
audit=read(OUT/'p2-audit.json')
audit['progress_snapshot']=progress
audit['latest_review']='output/texture-hd/p2-evidence/menu-checkpoint-verification.json'
write(OUT/'p2-audit.json',audit)
current='''**P2 第 58～76 批已完成记录：409 / 2,223 张，6 张已应用、403 张保留原图，尚余 1,814 张；下一批为第 77 批。** 本次完成第 64～76 批共 288 张，新增应用 0 张、保留 288 张。P1 已完成的 260 张和第 60 批已应用的 6 张继续保留。

| P2 范围 | 完成数 | 已应用 | 保留原图 |
| --- | ---: | ---: | ---: |
| 第 58～63 批：战斗界面 | 121 | 6 | 115 |
| 第 64～76 批：队伍、背包、摘要与通用菜单 | 288 | 0 | 288 |
| 已完成合计 | 409 | 6 | 403 |

全项目清单 18,665 张：**258 张已应用、497 张保留、17,910 张待处理**。候选待验收为 0；第 77～151 批尚未开始。P3～P5 继续保留在后续计划，没有后台生成或定时任务。

本次复用已有内置 image_gen 的 16 份男女背包生成图及 32 份候选，没有重复生成。原生 128×128 图标与 512×384 场景中，受保护后的微小明暗没有可见清晰度收益，因此保留原图。其他素材以清晰的功能符号、状态表、纯色布局或兼容目录素材为主，逐文件理由见第 64～76 批 `validation.json` 和 [菜单审查决定](p2-evidence/menu-review-decisions.json)。保留不是已重绘或已应用。

- [原始断点哈希核对](p2-evidence/resume-20261028.json)：2,223 张 P2 当前文件核对通过；32 张候选原图、备份、生成图及 ready 哈希均核对，开始时均未应用。
- [背包原生验收](p2-evidence/bag-native-validation.json)：男女款×中英文共 4 组；八个口袋左右完整往返、列表滚动、排序/取消与锚点核对；280 组原图/候选画面对比，物品文字、选择框及背包外区域完全一致。箭头 8 帧、每轮 32 次更新、40fps，共 800ms。八状态差值和首尾差值保持一致。
- [背包原尺寸场景对比](p2-evidence/bag-native-comparison.png)，左为原图、右为未采用候选；[中文女款完整箭头循环](p2-evidence/native-menu/bag-2-1-loop-comparison.gif)。GIF 的相邻更新交替 20/30ms，保留 800ms 总周期。
- [队伍、摘要与快捷菜单记录](p2-evidence/menu-native-validation.json)：保存 96 张中英文原生截图，覆盖选中、濒死、交换、空位、多选、摘要往返、招式学习/详情、蛋与快捷按钮状态。中文摘要学习招式页有原有的文字/精灵区域重叠，已记录；未将运行成功解释为全部排版无问题。
- 111 张中文配套图校验通过。此前第 58～63 批的 120 种指令状态与 12 组 HP/EXP 轨迹证据继续保留在 [战斗 UI 验收](p2-evidence/ui-native-validation.json)。
- [最终恢复点校验](p2-evidence/menu-checkpoint-verification.json)：重新核对 409 张已完成源文件及 288 张原图/交付副本。进度改由 `update_p2_progress.py` 按已完成 `validation.json` 汇总，`finish_p2_ui.py` 不再将进度固定覆盖成 121 张。

每批原图在 `originals/`；本次保留的交付副本在 `delivery/`。第 64、68 批的旧 `manifest.json` 已归档为 `candidate-manifest.json` 并标明 rejected_no_visible_gain；`ready/` 和 `generated/` 留作候选证据，不能当成交付或已应用。提示词与生成来源在这两批的 `jobs.json` 及 `p2-work/bag-*.json`；其他批 `jobs.json` 明确记录未生成的原因。当前机器恢复点为 [p2-progress.json](p2-progress.json) 与 [p2-work/resume.json](p2-work/resume.json)。

尚未完成完整游玩、人物/服装叠穿、Android 实机与发布包验证；人物/服装属于后续第 108～115 批。

## P1 第 5～57 批（已完成）

'''
path=OUT/'README.zh-CN.md'
text=path.read_text(encoding='utf-8')
start=text.index('## 当前进度')
end=start+len('## 当前进度\n\n')
text=text[:start]+'## 当前进度\n\n'+current+text[end:]
old='连同第 1～4 批，全项目清单为 **18,665 张：252 张已应用、94 张保留、18,319 张待处理**。下一批为 **P2 第 58 批**；P2～P5 尚未开始，没有后台生成或定时任务。'
text=text.replace(old,'P1 完成时的历史快照为 252 张已应用、94 张保留；当前累计以本文开头的 P2 进度为准。')
path.write_text(text,encoding='utf-8')
path=OUT/'execution-plan/README.zh-CN.md'
text=path.read_text(encoding='utf-8')
old='**2026-10-28 执行进度：P1 第 5～57 批全部完成，260 张中 166 张已应用、94 张保留原图并记录理由。下一批为 P2 第 58 批。** 累计 252 张已应用、94 张保留、18,319 张待处理，见[当前结果与对比](../README.zh-CN.md)和 [P1 机器进度](../p1-progress.json)。'
new='**2026-10-28 执行进度：P1 第 5～57 批全部完成；P2 第 58～76 批完成 409 张（6 张已应用、403 张保留），P2 尚余 1,814 张，下一批为第 77 批。** 全局 258 张已应用、497 张保留、17,910 张待处理。第 64～76 批的 288 张已逐项保留原图；背包 32 份候选完成验收后因无可见收益归档，不计为已应用。见[当前结果与对比](../README.zh-CN.md)、[P2 机器进度](../p2-progress.json)和 [P1 机器进度](../p1-progress.json)。'
assert old in text
text=text.replace(old,new).replace('说“执行第 58 批”：读取 [第 58 批清单](batches/batch-058.json)','说“执行第 77 批”：读取 [第 77 批清单](batches/batch-077.json)')
text=text.replace('当前 P1 批次状态为 `completed`；其余普通批次为 `planned`','当前 P1 以及 P2 第 58～76 批状态为 `completed`；其余普通批次为 `planned`')
text+='\n恢复时以逐批 validation.json 和当前文件 SHA-256 为准；manifest.json 只描述候选并不证明应用。本次第 64、68 批候选已归档为 candidate-manifest.json，状态为 rejected_no_visible_gain；delivery/ 是通过验收的原图副本。P2 进度由 update_p2_progress.py 从实际完成批次汇总。\n'
path.write_text(text,encoding='utf-8')
path=OUT/'execution-plan/stage-summary.zh-CN.md'
text=path.read_text(encoding='utf-8')
text=text.replace('每个编号都对应固定文件清单；文件数量包含同批的中文配套素材。','每个编号都对应固定文件清单；文件数量包含同批的中文配套素材。\n\n2026-10-28：P1 全部完成；P2 前两阶段（58～76）已完成 409 张，6 张应用、403 张保留。队伍/背包/摘要的 288 张均保留原图，32 份背包候选因无可见收益归档。下一批为 77，剩余 P2 为 1,814 张；后续阶段及 P3～P5 未开始。')
path.write_text(text,encoding='utf-8')
print(json.dumps({'status':'checkpoint_verified','progress':progress,'global':{s:inventory[s] for s in ('applied','preserved','pending')}}))
