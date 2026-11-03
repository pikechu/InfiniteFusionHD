"""Save one recovery point per reviewed P4 batch without changing retained assets."""
import sys
import shutil
from pathlib import Path
from resume_p2_menu import ROOT, OUT, read, write, digest
from update_p2_progress import self_check, update_progress

W = OUT / 'p4-work'


def main(numbers):
    self_check()
    scope = read(W / 'scope.json')
    sources = {r['source']: r for r in scope['entries']}
    pages = {s: Path(p['path']).name for p in scope['review_pages'] for s in p['sources']}
    reviewed = set(read(W / 'visual-review.json')['reviewed_pages'])
    proof_paths = read(W / 'native-proofs.json')
    plan = read(OUT / 'execution-plan/plan.json')
    index = {r['id']: r for r in plan['batch_index']}
    inventory = read(OUT / 'inventory.json')
    audit = read(OUT / 'p4-audit.json')
    proofs = {}
    pilot = read(W / 'icon-pilot.json')
    assert pilot['status'].startswith('rejected')
    for n in numbers:
        assert 541 <= n <= 816
        name = f'batch-{n:03}'
        batch = OUT / name
        path = OUT / f'execution-plan/batches/{name}.json'
        fixed = read(path)
        assert fixed['status'] == 'planned', name + ' already registered'
        assert all(index[d]['status'] == 'completed' for d in fixed['depends_on'])
        stage = fixed['stage']
        if stage not in proofs:
            evidence = proof_paths[stage]
            proof = read(ROOT / evidence['review'])
            assert proof['status'] == 'passed'
            for field in ('script_sha256', 'sidecar_sha256', 'data_sha256'):
                assert all(digest(ROOT / p) == sha for p, sha in proof.get(field, {}).items()), 'Native input changed'
            cleanup = read(ROOT / evidence['cleanup'])
            assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
            runtime = ROOT / 'temp/multiplayer' / cleanup['profile']
            assert not list(runtime.rglob('*.log')) and not (runtime / 'mkxp.json').exists()
            proofs[stage] = proof
        proof = proofs[stage]
        exceptions = {r['source']: r['issue'] for r in proof.get('compatibility_issues', []) if 'source' in r}
        entries = []
        for item in fixed['entries']:
            row = sources[item['source']]
            source = row['source']
            page = pages[row.get('same_pixels_as', source)]
            assert page in reviewed, 'Visual review missing: ' + source
            assert digest(ROOT / source) == row['sha256'] == proof['inputs'][source] == digest(batch / 'originals' / source)
            if source == pilot['source']:
                reason = '内置 image_gen 试制改变瓶身可见比例约 13.8%，红色标记变为粉色，拒绝应用；保留原尺寸清晰像素与原配色。原图属于旧数字命名道具目录，当前命名道具解析器不直接使用该路径。'
            elif source in exceptions:
                reason = '原有兼容素材：' + exceptions[source] + '。保留原始字节、布局和用途，不把原有加载差异计为新图像改动；验证边界见原生记录。'
            elif stage == 'icons':
                reason = '小型像素图标已有清楚的物种/道具轮廓、色块和识别标记；添加纹理不能改善原尺寸辨识，保留所有像素。适用的双格图标经过实际 HP 周期、选中偏移及原点检查，道具经过实际图标组件；旧命名、背包和蛋来源另列兼容检查，显式图片覆盖不证明全部物种/道具绑定。'
            elif stage == 'footprint':
                reason = '脚印是稀疏单色形状，阴影是透明功能层；额外纹理会改变形状或遮挡强度，保留原图。旧数字脚印目录与当前命名解析路径区别已记录，五张现用阴影经过真实合成路径；未把旧脚印静态兼容加载称作完整地图足迹事件验证。'
            elif stage == 'windows':
                reason = '窗口边框、光标、箭头、文字底色与重复切片已经清楚，保留原图及侧车配置。真实窗口组件按中英文、两种尺寸、非零开合及完整暂停/光标循环检查；原有全闭窗口异常单独记录，不修改游戏代码掩盖问题。'
            elif stage == 'effects':
                reason = '现有特效颜色、形状、透明渐隐和图格分隔清楚；独立重绘可能改变发光轮廓或帧间一致性，保留原图。实际动画数据、格位和适用原生播放记录见证据，未使用来源及已有兼容异常单列，未把解码等同于所有招式实战。'
            elif stage == 'weather':
                reason = '天气/雾效/转场的图格、功能遮罩、渐变及循环纹理按原样保留，添加细节无明确可读性收益。现用与兼容来源的消费路径及动画检查范围见证据，不以静态解码冒充完整转场或天气事件验证。'
            else:
                reason = '原有长条/GIF 的姿态、主体位置、透明边界与连续运动已保持清楚；逐帧新增纹理会增加闪烁和身份漂移风险，保留完整原始编码。已确认的原生播放与尚无现用条带加载入口的兼容来源分开记录，不猜测后者的正式播放时长。'
            entry = {**row, 'status': 'preserved', 'reason': reason, 'visual_review_page': page}
            entries.append(entry)
            delivery = batch / 'delivery' / source
            delivery.parent.mkdir(parents=True, exist_ok=True)
            if not delivery.exists():
                shutil.copy2(ROOT / source, delivery)
            assert digest(delivery) == row['sha256']
        jobs = [{'source': r['source'], 'decision': 'preserved', 'reason': r['reason'],
                 'generation_status': 'rejected_geometry_and_color' if r['source'] == pilot['source'] else 'not_generated_no_expected_gain',
                 'prompt': pilot['prompt'] if r['source'] == pilot['source'] else None,
                 'generated': pilot.get('generated') if r['source'] == pilot['source'] else None} for r in entries]
        write(batch / 'jobs.json', {'batch': name, 'method': 'Native-sized review and corresponding native/compatibility checks; no accepted AI replacement.', 'entries': jobs})
        write(batch / 'validation.json', {'batch': name, 'status': 'completed', 'applied': 0, 'preserved': len(entries), 'entries': entries,
              'candidate_pending_review': 0, 'dimensions_unchanged': True, 'alpha_unchanged': True, 'layout_unchanged': True,
              'evidence': [proof_paths[stage]['review'], 'output/texture-hd/p4-work/visual-review.json'],
              'validation_scope': proof['scope'], 'byte_identity_guarantee': 'All retained game images, backups and deliveries are byte-identical; no frame, alpha, timing or image content changes.'})
        result = f'output/texture-hd/{name}/validation.json'
        fixed.update(status='completed', result=result, applied_files=0, preserved_files=len(entries));write(path, fixed)
        index[name].update(status='completed', result=result, applied_files=0, preserved_files=len(entries))
        p4 = [r for r in plan['batch_index'] if r['priority'] == 'P4'];done = [r for r in p4 if r['status'] == 'completed']
        for r in plan['priorities']:
            if r['priority'] == 'P4':
                r.update(status='completed' if len(done) == len(p4) else 'in_progress', completed_files=sum(b['file_count'] for b in done),
                         applied_files=0, preserved_files=sum(b['file_count'] for b in done), remaining_files=sum(b['file_count'] for b in p4 if b['status'] != 'completed'))
        for r in plan['stages']:
            if r['priority'] == 'P4':
                stage_done = [index[b] for b in r['batch_ids'] if index[b]['status'] == 'completed']
                r.update(status='completed' if len(stage_done) == len(r['batch_ids']) else 'in_progress' if stage_done else 'planned',
                         completed_files=sum(b['file_count'] for b in stage_done), applied_files=0, preserved_files=sum(b['file_count'] for b in stage_done))
        plan['next_batch'] = next((r['id'] for r in plan['batch_index'] if r['status'] != 'completed'), None)
        write(OUT / 'execution-plan/plan.json', plan)
        selected = {r['source']: r for r in entries}
        for r in inventory['assets']:
            if r['path'] in selected:
                r.update(status='preserved', batch=name, reason=selected[r['path']]['reason'])
        for status in ('applied', 'preserved', 'pending'):
            inventory[status] = sum(r['status'] == status for r in inventory['assets'])
        write(OUT / 'inventory.json', inventory)
        for r in audit['sources']:
            if r['source'] in selected:
                r.update(review_status='preserved', validation=result, accepted_sha256=r['sha256'])
        write(OUT / 'p4-audit.json', audit)
        progress = update_progress('P4')
        write(W / 'resume.json', {'status': progress['status'], 'completed_through': name, 'next_batch': progress['next_batch'], 'candidate_pending_review': [], 'ready_pending_application': []})
        path = OUT / 'execution-plan/batch-index.zh-CN.md'
        lines = path.read_text(encoding='utf-8').splitlines()
        path.write_text('\n'.join(line.replace('待执行', '已完成') if f'batches/{name}.json' in line else line for line in lines) + '\n', encoding='utf-8')
        print(f"CHECKPOINT {name} applied=0 preserved={len(entries)} completed={progress['completed_files']} next={progress['next_batch']}", flush=True)


if __name__ == '__main__':
    main([int(n) for n in sys.argv[1:]])
