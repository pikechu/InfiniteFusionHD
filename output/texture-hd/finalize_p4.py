"""Close P4 records while retaining explicit native compatibility limits."""
from resume_p2_menu import ROOT, OUT, read, write


def main():
    progress = read(OUT / 'p4-progress.json')
    assert progress['status'] == 'completed' and progress['completed_files'] == 5065
    visual = read(OUT / 'p4-work/visual-review.json')
    visual['notes'].update({
        '687-737': 'Reviewed 2026-11-03: remaining PRAS effects, credit marks, Ballburst colors, and complete named ball tumble/open sheets. Preserve fine pixels, gradients, original stylistic differences and cell gaps. Actual 44 paired ball processes separately checked; empty Ballburst methods are not claimed as rendered effects.',
        '738-769': 'Reviewed 2026-11-03: transparent battleback overlays, fog/noise masks, spotlights, grayscale transition masks, black geometric pieces, VS logos/bars/portraits, SunMoon layers and weather particles. Preserve masking luminance, alpha ramps, letterforms and exact panel geometry. Inactive/alternate resources remain compatibility assets.',
        '770-816': 'Reviewed 2026-11-03: all long PNG donor sources, paired Chinese meme text, GIFs, egg cracks and triple fusions. Also viewed all four animated-phases pages (first/middle/last of each source); source order, distinct pose/content changes, formulas, logos, variant imagery and donor cells retained. All 5074 encoded/donor units have ordered pixel hashes; only the 191 GIF frames have certified native frame playback. No invented donor timing or current battler binding.'})
    visual['additional_pages_reviewed'] = read(OUT / 'p4-evidence/animated-phase-review.json')['pages']
    write(OUT / 'p4-work/visual-review.json', visual)
    mappings = read(OUT / 'p4-work/native-proofs.json')
    exceptions = {r['source']: r['issue'] for record in mappings.values()
                  for r in read(ROOT / record['review']).get('compatibility_issues', []) if 'source' in r}
    reasons = {}
    for number in range(541, 817):
        batch = OUT / f'batch-{number:03}'
        receipt = read(batch / 'validation.json')
        jobs = read(batch / 'jobs.json')
        for entry in receipt['entries']:
            if entry['source'] in exceptions:
                entry['reason'] = '原有兼容问题：' + exceptions[entry['source']] + '。保留原文件全部字节，未通过修改图片掩盖既有逻辑或数据差异。'
            reasons[entry['source']] = entry['reason']
        for entry in jobs['entries']:
            entry['reason'] = reasons[entry['source']]
        if number in range(622, 738):
            receipt['evidence'] = sorted(set(receipt['evidence'] + ['output/texture-hd/p4-evidence/balls-review.json']))
            receipt['validation_scope'] = read(OUT / 'p4-evidence/effects-review.json')['scope']
        if number >= 770:
            receipt['evidence'] = sorted(set(receipt['evidence'] + ['output/texture-hd/p4-evidence/animated-phase-review.json']))
        write(batch / 'validation.json', receipt);write(batch / 'jobs.json', jobs)
    inventory = read(OUT / 'inventory.json')
    for row in inventory['assets']:
        if row['path'] in reasons: row['reason'] = reasons[row['path']]
    write(OUT / 'inventory.json', inventory)
    write(OUT / 'p4-work/resume.json', {
        'status': 'completed', 'completed_on': '2026-11-03', 'completed_through': 'batch-816',
        'next_batch': None, 'next_global_batch': 'batch-817', 'candidate_pending_review': [], 'ready_pending_application': [],
        'completed_files': 5065, 'applied_files': 0, 'preserved_files': 5065,
        'native_proofs': mappings, 'compatibility_findings': 'See each native review and per-file preservation reasons; no game logic repaired.',
        'verification': 'output/texture-hd/p4-evidence/checkpoint-verification.json',
        'scope_boundary': 'P5 remains planned. Full gameplay, Android devices, release packaging and inactive donor binding are not certified.'})
    summary = '''## P4 处理与验收已完成（2026-11-03）

**第 541～816 批全部完成：5,065 / 5,065 张，全部保留原图，待验收候选为 0。** 完成包含逐项审查后保留原图；本阶段没有获准应用的 AI 重绘。图标、功能遮罩、精确切片和连续帧的原有轮廓已清楚，添加纹理没有确定的原尺寸辨识收益。`item001` 试制改变比例和红色标记，已拒绝，提示词、生成图及对比继续归档。

| P4 范围 | 文件数 | 结果 |
| --- | ---: | --- |
| 第 541～604 批：图标 | 3,066 | 保留全部像素、双格和识别色 |
| 第 605～615 批：足迹与阴影 | 654 | 保留稀疏轮廓及功能透明度 |
| 第 616～621 批：窗口 | 83 | 保留边框切片、光标和侧车配置 |
| 第 622～737 批：招式与球特效 | 925 | 保留图格、渐隐及连续颜色 |
| 第 738～769 批：天气、雾和转场 | 243 | 保留粒子、渐变和功能遮罩 |
| 第 770～816 批：长条/GIF | 94 | 保留完整编码、帧序、原始延迟和文本 |

原生证据及边界：

- [图标与功能层](p4-evidence/icons-review.json)：3,720 张解码，13,720 个图标状态和 1,297 个道具图标检查；旧数字路径与当前命名解析器分开记录。
- [窗口](p4-evidence/windows-review.json)：83 张、996 组中英文/尺寸/开合及完整光标周期。原有全闭窗口异常和 `Windowskin.PNG` 扩展名解析差异保留，未修改游戏源码。
- [招式](p4-evidence/effects-review.json)：925 张解码，2,546 组正常/反向动画数据播放至结束、238,484 个图格检查；8 个原有越界图格来源已单列。音效调用被观察但不播放；未引用来源不冒称完整招式实战。
- [精灵球](p4-evidence/balls-review.json)：92 张球资源、44 组配对经过实际轨迹/翻滚/开合/复位组件；既有空 Ballburst 方法及兼容替代图未冒称完整捕获效果。
- [天气、雾和转场](p4-evidence/weather-review.json)：243 张解码，10 种天气、3 档强度、粒子再生、两轮平铺及淡入淡出；18 个雾层、14 个粒子类、13 组 HGSS 转场，共 551,640 个状态检查。`RisingSplash` 的 40 帧边界异常保留，实际调用的 50 帧完整结束。SunMoon、备用 VS 和未绑定层仅作兼容加载，未虚构现用播放入口。
- [长动画](p4-evidence/animated-review.json)：8 个 GIF 的 191 帧透明度及可见 RGB 一致，原生各播放两个完整循环；两份蛋裂纹通过实际格位及摇摆检查。[四页阶段审查及 5,074 个有序单元哈希](p4-evidence/animated-phase-review.json)保留长条的独立姿态、变体与文字。`164.267.gif` 的变帧延迟与原生固定 20fps 不一致，保留原文件并明确记录；未绑定长 PNG 不赋予虚构的正式时长或物种绑定。

全部 5,065 张的当前文件、原图和 delivery 副本与冻结哈希一致；尺寸、透明通道、画格、GIF 原始帧序/时长不变。见[最终复核](p4-evidence/checkpoint-verification.json)、[机器进度](p4-progress.json)和[恢复记录](p4-work/resume.json)。全局 18,665 张中：268 张已应用、16,547 张保留、1,850 张待处理。P1～P4 已完成，P5 第 817 批尚未开始。

本轮进程、原始日志、GIF 导出帧和临时验收工具已清理；原图、生成试制及正式证据保留。完整游玩、Android 实机和最终发布包尚未验证。

'''
    path = OUT / 'README.zh-CN.md';text = path.read_text(encoding='utf-8')
    title = '## P4 当前保存点（2026-11-03）' if '## P4 当前保存点（2026-11-03）' in text else '## P4 处理与验收已完成（2026-11-03）'
    start = text.index(title)
    end = text.index('\n## ', start + 4)
    path.write_text(text[:start] + summary.rstrip() + '\n' + text[end:], encoding='utf-8')
    line = '2026-11-03：P1～P4 已完成；P4 第 541～816 批共 5,065 张全部保留，候选为 0。全局 268 张应用、16,547 张保留、1,850 张待处理；P5 第 817 批未开始。证据与兼容问题见[当前报告](../README.zh-CN.md)。'
    for name in ('execution-plan/README.zh-CN.md', 'execution-plan/stage-summary.zh-CN.md'):
        path = OUT / name;lines = path.read_text(encoding='utf-8').splitlines()
        lines = [line if old.startswith('2026-11-03 保存点：') else old for old in lines]
        path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print({'P4': 'completed', 'files': 5065, 'next_global_batch': 'batch-817'})


if __name__ == '__main__': main()
