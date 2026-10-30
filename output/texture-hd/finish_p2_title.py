"""Record the rejected title proposal and preserve each of batch 103's originals."""
import gzip, shutil
from resume_p2_menu import ROOT, OUT, read, write, digest
from update_p2_progress import self_check, update_progress

W=OUT/'p2-title-work';E=OUT/'p2-evidence/titles';B=OUT/'batch-103'


def main():
    self_check();proof=read(E/'native-validation.json')
    assert proof['status']=='passed' and proof['candidate_decision']=='rejected_no_visible_gain'
    rows=read(W/'scope.json')['entries'];assert len(rows)==20
    entries=[]
    for row in rows:
        source=row['source'];name=source.rsplit('/',1)[-1]
        assert digest(ROOT/source)==row['sha256']==digest(B/'originals'/source),source
        if name=='gen1_bg.png':
            reason='已用内置 image_gen 生成并完成原生前后验收。结构保护后的星云局部出现暗块，原尺寸清晰度没有改善；完整原始生成提案也新增细星点，因此拒绝候选并保留原图。'
        elif name=='credits1.png':
            reason='当前片尾背景为黑底与低对比装饰，文字由游戏滚动绘制；增加纹理会干扰片尾文字。实测前 160 次滚动更新和正常跳过，当前背景切换代码已禁用，不宣称五背景轮播。'
        elif name=='gen1_bars.png':
            reason='标题滑入横条包含署名文字与透明区域，原尺寸边界清楚；保留原图以保持横向移动、文字、锚点及遮挡。'
        elif name in ('gen1_effect.png','gen3_effect.png'):
            reason='平铺运动特效保持透明边界与接缝。Gen1 横向特效当前被设为隐藏，Gen3 为兼容风格；不为隐藏/已有清楚几何的功能层加纹理。'
        elif name.startswith('gen3_poke') or name=='gen1_poke.png':
            reason='现有角色层/剪影/面颊光亮属于分层素材，原轮廓和姿态清楚。Gen1 当前由物种加载器动态选择精灵，Gen3 两角色层用于叠合闪亮；重绘无明确收益，逐字节保留。'
        elif name=='gen3_bg.png':
            reason='兼容标题背景是平滑渐变并带署名，保持渐变与文字原像素；加纹理没有清晰度收益。原有 Reset 时刻另外记录，延长循环仅限测试夹具。'
        else:
            reason='备用色、发光、预合成 logo 或旧版背景未被当前 GenOne 标题加载；已有渐变/插画清楚，不用当前场景解码冒充这些备用画面的完整播放验收。保留原图及各版本的全部差值。'
        entry={**row,'status':'preserved','reason':reason};entries.append(entry)
        target=B/'delivery'/source;target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists():shutil.copy2(ROOT/source,target)
        assert digest(target)==row['sha256']
    manifest=read(B/'manifest.json');manifest['status']='rejected_no_visible_gain'
    for entry in manifest['entries']:entry['status']='rejected_no_visible_gain'
    write(B/'candidate-manifest.json',manifest);(B/'manifest.json').unlink()
    job=read(W/'job.json');job.update(status='rejected_no_visible_gain',reason=entries[2]['reason']);write(W/'job.json',job)
    candidate=read(W/'candidate-validation.json');candidate.update(status='rejected_no_visible_gain',native_validation='output/texture-hd/p2-evidence/titles/native-validation.json');write(W/'candidate-validation.json',candidate)
    write(B/'jobs.json',{'batch':'103','method':'Built-in image_gen; one proposal rejected after protected projection and native comparison.',
        'entries':[{'source':e['source'],'decision':'preserved','reason':e['reason'],
                    'prompt':job['prompt'] if e['source']==job['source'] else None,
                    'generated':job['generated'] if e['source']==job['source'] else None,
                    'generation_status':'rejected_no_visible_gain' if e['source']==job['source'] else 'not_generated_no_expected_gain'} for e in entries]})
    write(B/'validation.json',{'batch':'batch-103','status':'completed','applied':0,'preserved':20,'entries':entries,
        'candidate_pending_review':0,'dimensions_unchanged':True,'alpha_unchanged':True,'layout_unchanged':True,
        'evidence':['output/texture-hd/p2-evidence/titles/native-validation.json','output/texture-hd/p2-title-work/candidate-validation.json'],
        'validation_scope':proof['timing_scope']})
    write(E/'review-decisions.json',{'status':'reviewed','applied':0,'preserved':20,'entries':entries})
    record_path=OUT/'execution-plan/batches/batch-103.json';record=read(record_path)
    record.update(status='completed',result='output/texture-hd/batch-103/validation.json',applied_files=0,preserved_files=20);write(record_path,record)
    plan_path=OUT/'execution-plan/plan.json';plan=read(plan_path)
    row=next(r for r in plan['batch_index'] if r['id']=='batch-103');row.update(status='completed',result=record['result'],applied_files=0,preserved_files=20)
    plan['next_batch']=next(r['id'] for r in plan['batch_index'] if r['status']!='completed');write(plan_path,plan)
    selected={e['source']:e for e in entries};inventory=read(OUT/'inventory.json')
    for row in inventory['assets']:
        if row['path'] in selected:row.update(status='preserved',batch='batch-103',reason=selected[row['path']]['reason'])
    for state in ('applied','preserved','pending'):inventory[state]=sum(r['status']==state for r in inventory['assets'])
    assert sum(inventory[s] for s in ('applied','preserved','pending'))==inventory['total'];write(OUT/'inventory.json',inventory)
    audit=read(OUT/'p2-audit.json')
    for row in audit['sources']:
        if row['source'] in selected:row.update(review_status='preserved',validation=record['result'],accepted_sha256=row['sha256'])
    write(OUT/'p2-audit.json',audit);progress=update_progress()
    assert (progress['completed_files'],progress['applied_files'],progress['preserved_files'],progress['remaining_files'])==(1005,15,990,1218)
    resume=read(OUT/'p2-work/resume.json');resume.update(completed_through='batch-103',next_batch='batch-104',candidate_pending_review=[]);write(OUT/'p2-work/resume.json',resume)
    write(W/'resume.json',{'status':'completed','completed_through':'batch-103','next_batch':'batch-104','candidate_pending_review':[]})
    index_path=OUT/'execution-plan/batch-index.zh-CN.md';lines=index_path.read_text(encoding='utf-8').splitlines()
    index_path.write_text('\n'.join(line.replace('待执行','已完成') if 'batches/batch-103.json' in line else line for line in lines)+'\n',encoding='utf-8')
    # Preserve every trace losslessly while removing the bulky uncompressed copies.
    archived=[]
    for phase in ('before','candidate'):
        source=E/f'{phase}-review.json';raw=source.read_bytes();target=source.with_suffix('.json.gz')
        compressed=gzip.compress(raw,compresslevel=9,mtime=0);target.write_bytes(compressed)
        assert gzip.decompress(target.read_bytes())==raw
        archived.append({'path':target.relative_to(ROOT).as_posix(),'raw_bytes':len(raw),'archive_bytes':len(compressed),'raw_sha256':digest(source),'archive_sha256':digest(target)})
        source.unlink()
    write(E/'trace-archives.json',{'format':'lossless gzip JSON','entries':archived})
    print(progress)


if __name__=='__main__':main()
