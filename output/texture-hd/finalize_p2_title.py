"""Verify the batch checkpoint, document results, and clean task-local caches."""
import gzip
from resume_p2_menu import ROOT, OUT, read, write, digest

E=OUT/'p2-evidence/titles';W=OUT/'p2-title-work'


def main():
    progress=read(OUT/'p2-progress.json');assert progress['next_batch']=='batch-104'
    completed={}
    for n in range(58,104):
        receipt=read(OUT/f'batch-{n:03}/validation.json');assert receipt['status']=='completed'
        completed.update({e['source']:e for e in receipt['entries']})
    audit=read(OUT/'p2-audit.json')
    for row in audit['sources']:
        entry=completed.get(row['source']);expected=entry['after_sha256'] if entry and entry['status']=='applied' else row['sha256']
        assert digest(ROOT/row['source'])==expected,row['source']
    receipt=read(OUT/'batch-103/validation.json')
    for entry in receipt['entries']:
        for folder in ('originals','delivery'):assert digest(OUT/'batch-103'/folder/entry['source'])==entry['sha256']
    preserved_changes=[p for p,h in read(W/'session-protected.json')['files'].items() if digest(ROOT/p)!=h]
    for phase in ('before','candidate'):
        profile=f'texture-p2-dex-title-{phase}-20261030';cleanup=read(OUT/f'p2-evidence/dex/{profile}-cleanup.json')
        assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
        stage=ROOT/'temp/multiplayer'/profile;assert not list(stage.rglob('*.log')) and not (stage/'mkxp.json').exists()
    archives=read(E/'trace-archives.json')['entries']
    for row in archives:
        assert digest(ROOT/row['path'])==row['archive_sha256']
        assert __import__('hashlib').sha256(gzip.decompress((ROOT/row['path']).read_bytes())).hexdigest()==row['raw_sha256']
    removed=[];cache=(OUT/'__pycache__').resolve();assert cache.is_relative_to(ROOT.resolve())
    if cache.exists():
        for p in cache.glob('*.pyc'):
            assert not p.is_symlink() and p.resolve().is_relative_to(cache)
            removed.append({'path':p.relative_to(ROOT).as_posix(),'bytes':p.stat().st_size});p.unlink()
    cache_report=read(E/'cache-cleanup.json');cache_report['final_sweep']=removed
    cache_report['lossless_trace_bytes_reclaimed']=sum(r['raw_bytes']-r['archive_bytes'] for r in archives)
    cache_report['policy']='Clean owned temporary logs/config after every run, sweep task bytecode between batches, archive full trace JSON losslessly. Preserve all unpushed originals/generated/delivery images and necessary native evidence. Never delete active game images.'
    write(E/'cache-cleanup.json',cache_report)
    proof=read(E/'native-validation.json')
    write(E/'checkpoint-verification.json',{'status':'passed','date':'2026-10-30',
        'all_p2_source_hashes_verified':2223,'completed_source_hashes_verified':len(completed),
        'new_sources_originals_and_deliveries_verified':20,'new_applied':0,'new_preserved':20,
        'progress':progress,'candidate_pending_review':0,'concurrent_source_changes_preserved':preserved_changes,
        'native_screen_pairs':proof['native_screen_pairs'],'temporary_logs_remaining':0,
        'cache_cleanup':'output/texture-hd/p2-evidence/titles/cache-cleanup.json'})
    readme=OUT/'README.zh-CN.md';text=readme.read_text(encoding='utf-8')
    text=text.replace('进度（2026-10-29）','进度（2026-10-30）',1)
    old='**P2 第 58～102 批已完成：985 / 2,223 张，15 张已应用、970 张保留原图，剩余 1,238 张；下一批为第 103 批。** 本轮第 94～102 批共 202 张，新增应用 5 张、保留 197 张。P1 及此前 P2 的已完成结果继续保留。'
    new='**P2 第 58～103 批已完成：1,005 / 2,223 张，15 张已应用、990 张保留原图，剩余 1,218 张；下一批为第 104 批。** 第 103 批 20 张全部保留原图；星云增强提案因原尺寸局部暗块、没有明确视觉收益被拒绝，未替换任何游戏图片。此前已完成结果继续保留。'
    assert old in text;text=text.replace(old,new,1)
    text=text.replace('| 合计 | 985 | 15 | 970 |','| 第 103 批：标题与片头分层素材 | 20 | 0 | 20 |\n| 合计 | 1,005 | 15 | 990 |',1)
    text=text.replace('267 张已应用、1,064 张保留、17,334 张待处理','267 张已应用、1,084 张保留、17,314 张待处理',1)
    text=text.replace('第 103～151 批及 P3～P5','第 104～151 批及 P3～P5',1)
    heading='本轮内置 `image_gen` 编辑了地图与金/银/铜三种卡面'
    detail=(f"第 103 批完成 {proof['native_screen_pairs']} 组原生前后截图、每阶段 {proof['native_frame_states_per_phase']} 个逐帧状态的比较。中英文当前 GenOne 标题的滑入、左右选择、融合停留、淡出与载入菜单构建一致；固定离线测试精灵对为 1/4。GenThree 为旧兼容风格，先记录其原有 Reset 阈值，再仅在测试夹具中延长上限以检查完整 768 更新组合循环（40fps 标称 19.2 秒）。片尾只覆盖前 160 更新的文字滚动与正常跳过，未声称完整片尾或五背景轮播。测试跳过版本联网查询、资源包启动、下载提示和键位写入。\n\n"
       '[第 103 批验收与限制](p2-evidence/titles/native-validation.json)、[原尺寸场景对比](p2-evidence/titles/title-native-comparison.png)、[完整提示词](p2-title-work/job.json)、[恢复点复核](p2-evidence/titles/checkpoint-verification.json)。完整原生状态记录无损压缩为 `p2-evidence/titles/*-review.json.gz`，解压后仍是原 JSON；所有原图、生成图和必要截图保留。每轮测试结束即清理临时日志及配置，本轮另外清理 6 个 Python 缓存。远程查询没有 `codex/texture-hd-p2` 分支，历史图片尚不能确认远程可恢复，因此未删除，见 [清理记录](p2-evidence/titles/cache-cleanup.json)。\n\n上一阶段内置 `image_gen` 编辑了地图与金/银/铜三种卡面')
    assert heading in text;text=text.replace(heading,detail,1)
    text=text.replace('[本轮恢复记录](p2-region-work/resume.json)','[本轮恢复记录](p2-title-work/resume.json)',1);readme.write_text(text,encoding='utf-8')
    p=OUT/'execution-plan/README.zh-CN.md';text=p.read_text(encoding='utf-8')
    text=text.replace('58～102','58～103').replace('985 / 2,223','1,005 / 2,223').replace('970 张','990 张').replace('1,238','1,218').replace('下一批为 103','下一批为 104').replace('下一批为第 103','下一批为第 104')
    text='\n'.join('**2026-10-30：P1 全部完成；P2 第 58～103 批完成 1,005 张（15 张应用、990 张保留），P2 尚余 1,218 张，下一批为第 104 批。** 全局 267 张应用、1,084 张保留、17,314 张待处理。本轮第 103 批 20 张全部保留；见[当前结果与对比](../README.zh-CN.md)和 [P2 机器进度](../p2-progress.json)。' if line.startswith('**2026-10-29：P1') else line for line in text.splitlines())+'\n'
    text+='\n2026-10-30：第 103 批 20 张已完成（0 应用、20 保留）。星云提案无明确收益，已归档为 candidate-manifest.json，未应用。标题运动/融合/中英文及载入菜单构建验收、兼容 GenThree 原有 Reset 阈值与测试夹具延长循环的区别见 ../p2-evidence/titles/native-validation.json。片尾仅测前 160 更新和跳过，未测完整启动联网流程。定期清理测试临时日志、配置、Python 缓存，原生全轨迹无损压缩；未经远程可恢复性核验的图片档案继续保留。\n';p.write_text(text,encoding='utf-8')
    p=OUT/'execution-plan/stage-summary.zh-CN.md';lines=p.read_text(encoding='utf-8').splitlines()
    lines[4]='2026-10-30：P1 全部完成；P2 第 58～103 批完成 1,005 张，15 张应用、990 张保留。本轮第 103 批 20 张全部保留，增强候选因无明确收益拒绝；下一批为 104，剩余 1,218 张。后续阶段及 P3～P5 未开始。'
    p.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print('TITLE_CHECKPOINT_PASS completed=1005 applied=15 preserved=990 next=batch-104 logs=0')


if __name__=='__main__':main()
