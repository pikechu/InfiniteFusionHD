"""Save and verify the reviewed archive batch; advance only batch 817."""
import hashlib
import sys
from collections import Counter
from PIL import Image
from resume_p2_menu import ROOT, OUT, read, write, digest
from update_p2_progress import self_check, update_progress


def main(number=817):
    assert number in (817, 818)
    name = f'batch-{number}'
    next_name = f'batch-{number+1}'
    self_check()
    batch = OUT / name;scope = read(OUT / f'p5-work/{name}-scope.json')
    fixed_path = OUT / f'execution-plan/batches/{name}.json';fixed = read(fixed_path)
    assert fixed['status'] == 'needs_usage_audit' and len(scope['entries']) == fixed['file_count'] == 48
    native_path = f'output/texture-hd/p5-evidence/{name}/native-review.json'
    effect_path = f'output/texture-hd/p5-evidence/{name}/effects-review.json'
    native = read(ROOT / native_path)
    effects = read(ROOT / effect_path) if number == 817 else None
    references = read(OUT / f'p5-evidence/{name}/reference-audit.json')
    assert native['status'] == 'passed' and len(native['decoded']) == 48
    assert len(native['compatibility_backgrounds']) == (41 if number == 817 else 48)
    if effects:
        assert effects['status'] == 'passed' and len(effects['cases']) == 4 and not effects['existing_animation_errors'] and effects['cell_checks'] == 0
    else:
        assert not native['battle_animation_references'] and not native['serialized_string_hits']
        assert all(r['matched_file_count'] == 0 for r in references['entries'])
        assert Counter(r['kind'] for r in native['compatibility_backgrounds']) == {'backup_background': 36, 'legacy_player_base': 12}
    expected = dict(references['scanned_file_sha256'])
    for proof in ([native, effects] if effects else [native]):
        for field in ('script_sha256', 'data_sha256', 'inputs'):
            for path, sha in proof[field].items():
                if path in expected:assert expected[path] == sha
                expected[path] = sha
    protected_path = OUT / f'p5-work/{name}-protected.json'
    if not protected_path.exists():protected_path = OUT / 'p5-work/session-protected.json'
    for path, sha in read(protected_path)['files'].items():
        assert digest(ROOT / path) == sha, ('Protected file changed', path)
    for path, sha in expected.items():assert digest(ROOT / path) == sha, ('Audit input changed', path)
    cleanup_paths = []
    profiles = ('texture-p2-dex-p5-817-reviewed-20261103', 'texture-p2-dex-p5-817-effects-20261103') if number == 817 else ('texture-p2-dex-p5-818-20261103',)
    for profile in profiles:
        path = OUT / 'p2-evidence/dex' / (profile + '-cleanup.json');cleanup = read(path)
        assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
        runtime = ROOT / 'temp/multiplayer' / profile
        assert not list(runtime.rglob('*.log')) and not (runtime / 'mkxp.json').exists()
        cleanup_paths.append(path.relative_to(ROOT).as_posix())
    entries = [];jobs = []
    for row in scope['entries']:
        source = row['source'];before = row['sha256'];assert digest(ROOT / source) == before == digest(batch / 'originals' / source)
        with Image.open(ROOT / source) as im:
            rgba = im.convert('RGBA')
            assert list(im.size) == row['size'] and im.format == row['format'] and getattr(im, 'n_frames', 1) == 1
            assert hashlib.sha256(rgba.tobytes()).hexdigest() == row['rgba_sha256']
            assert hashlib.sha256(rgba.getchannel('A').tobytes()).hexdigest() == row['alpha_sha256']
        for match in row['pixel_matches']:
            path = ROOT / match.get('archive', match['source'])
            assert digest(path) == match['sha256']
            with Image.open(path) as im:
                assert list(im.size) == row['size'] and hashlib.sha256(im.convert('RGBA').tobytes()).hexdigest() == row['rgba_sha256']
        declared = [r for r in native['battle_animation_references'] if r['source'] == source]
        if '/battlebg/backup/' in source:
            reason = '战斗背景历史备份，保留原画及原有渐变/纹理以供恢复和比较。审查范围内未发现 backup 路径选择；显式覆盖通过真实背景合成器显示，不等同于普通地图选用。'
            if row['pixel_matches']:reason += '与现有文件或已归档历史原图逐像素一致，匹配路径与哈希另列；不据此替换已经高清化的现用版本。'
        elif '/playerbase_orig/' in source:
            reason = '旧版地台完整画布，含原始透明留白及旧尺寸。现用地台解析目录为 playerbase，审查范围内未发现 playerbase_orig 路径选择。显式覆盖已核对原尺寸、底部/中心锚点和真实合成显示；这不表示可直接代替已裁切的现用地台。保留原始轮廓、留白及纹理作为历史来源。'
            if row['pixel_matches']:reason += '逐像素相同来源另列，不跨尺寸或仅凭相似名字合并。'
        elif declared:
            reason = '两条热风动画在图集字段声明了此来源；四组正向/反向原生播放均完整结束，但未使用非负图格索引（cell_checks=0），未证实这张图集有可见格位被使用。保留原图格、色块和透明度，不将声明引用当作实际可见使用或强行重绘。'
        elif source.startswith('Graphics/Autotiles/'):
            reason = '备用海岸自动图块与现有/历史来源逐像素相同；现用 Tilesets 声明未引用该 Copie 名称。保留完整原始横向帧表，避免改写备份或虚构现用拼接验收。'
        elif source.endswith('unused_message.png'):
            reason = '旧消息条渐变素材；当前普通背景解析和已审查数据未选择该文件。保留原渐变、透明度与尺寸，不以 unused 文件名单独判断用途，也不修改现用消息条。'
        elif '/BaseSprites/' in source:
            reason = '具名测试/源素材集合，含独立精灵或六格 Eevee 姿态；审查范围内未找到该完整路径或具名来源的现用选择。保留试验内容及原始布局，不赋予未确认的物种/动作绑定。'
        elif source.endswith('paya_test.png'):
            reason = '手写 Hello、爱心和猫头测试图，审查范围内未发现现用引用。保留原作者标记、文字和像素内容。'
        else:
            reason = '备用浪潮前景图，未在现用动画图集/时序声明或代码数据中发现此 Copie 名称；画面与相似命名图并不逐像素相同。保留独立版本、分片和透明边缘，不按文件名去重或替换。'
        delivery = batch / 'delivery' / source;delivery.parent.mkdir(parents=True, exist_ok=True)
        if not delivery.exists():delivery.write_bytes((ROOT / source).read_bytes())
        assert digest(delivery) == before
        entry = {**row, 'status': 'preserved', 'reason': reason, 'declared_animation_references': declared,
                 'reference_hits': next(r for r in references['entries'] if r['source'] == source)}
        entries.append(entry);jobs.append({'source': source, 'decision': 'preserved', 'reason': reason,
                                          'generation_status': 'not_generated_archive_or_no_visible_use', 'prompt': None, 'generated': None})
    evidence = [native_path, f'output/texture-hd/p5-evidence/{name}/reference-audit.json'] + ([effect_path] if effects else []) + scope['review_pages'] + cleanup_paths
    write(batch / 'jobs.json', {'batch': name, 'entries': jobs})
    write(batch / 'validation.json', {'batch': name, 'status': 'completed', 'applied': 0, 'preserved': 48,
          'candidate_pending_review': 0, 'dimensions_unchanged': True, 'alpha_unchanged': True, 'layout_unchanged': True,
          'entries': entries, 'evidence': evidence, 'validation_scope': native['scope'],
          'limits': 'No proof of ordinary archive selection, full gameplay, Android device behavior or autotile seams. Seven non-Marshal/legacy-class data files were covered by raw-byte scan rather than generic deserialization. Localized catalogs were raw-scanned; animation names use the actual API.'})
    plan = read(OUT / 'execution-plan/plan.json');index = {r['id']: r for r in plan['batch_index']}
    assert all(index[d]['status'] == 'completed' for d in fixed['depends_on'])
    result = f'output/texture-hd/{name}/validation.json'
    fixed.update(status='completed', result=result, applied_files=0, preserved_files=48);write(fixed_path, fixed)
    index[name].update(status='completed', result=result, applied_files=0, preserved_files=48)
    done = [r for r in plan['batch_index'] if r['priority'] == 'P5' and r['status'] == 'completed']
    completed = sum(r['file_count'] for r in done)
    for row in plan['priorities']:
        if row['priority'] == 'P5':row.update(status='in_progress', completed_files=completed, applied_files=0, preserved_files=completed, remaining_files=1850-completed)
    for row in plan['stages']:
        if row['priority'] == 'P5' and name in row['batch_ids']:
            stage_done = sum(index[b]['file_count'] for b in row['batch_ids'] if index[b]['status'] == 'completed')
            row.update(status='in_progress', completed_files=stage_done, applied_files=0, preserved_files=stage_done)
    plan['next_batch'] = next_name;write(OUT / 'execution-plan/plan.json', plan)
    inventory = read(OUT / 'inventory.json');selected = {r['source']: r for r in entries}
    for row in inventory['assets']:
        if row['path'] in selected:row.update(status='preserved', batch=name, reason=selected[row['path']]['reason'])
    counts = Counter(r['status'] for r in inventory['assets'])
    assert counts == {'applied': 268, 'preserved': 16547+completed, 'pending': 1850-completed}
    inventory.update(counts);write(OUT / 'inventory.json', inventory)
    audit = read(OUT / 'p5-audit.json') if (OUT / 'p5-audit.json').exists() else {'audited_batches': [], 'sources': []}
    assert name not in audit['audited_batches']
    audit['audited_batches'].append(name);audit['sources'].extend(entries)
    audit['scope'] = 'Only requested completed P5 batches audited; remaining batches await their own audit.'
    write(OUT / 'p5-audit.json', audit)
    progress = update_progress('P5');assert progress['completed_files'] == completed and progress['next_batch'] == next_name
    write(OUT / 'p5-work/resume.json', {'status': 'in_progress', 'completed_through': name, 'next_batch': next_name,
          'candidate_pending_review': [], 'ready_pending_application': [], 'authorized_batch_completed': name})
    index_path = OUT / 'execution-plan/batch-index.zh-CN.md';lines = index_path.read_text(encoding='utf-8').splitlines()
    lines = [line.replace('先核查用途', '已完成').replace('需核查用途', '已完成').replace('待核查用途', '已完成').replace('待执行', '已完成') if f'batches/{name}.json' in line else line for line in lines]
    index_path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    report = {'status': 'passed', 'batch': name, 'files': 48, 'applied': 0, 'preserved': 48,
              'pixel_match_sources': sum(bool(r['pixel_matches']) for r in entries), 'native_compositions': len(native['compatibility_backgrounds']),
              'declared_atlas_references': len(native['battle_animation_references']), 'animation_cases_completed': len(effects['cases']) if effects else 0,
              'raw_files_scanned': references['source_files_scanned'], 'serialized_files_inspected': len(native['serialized_files_inspected']),
              'scanned_inputs_unchanged': len(expected), 'next_batch': next_name, 'inventory': dict(counts), 'cleanup_receipts': cleanup_paths}
    write(OUT / f'p5-evidence/{name}/checkpoint-verification.json', report)
    print(report, flush=True)


if __name__ == '__main__':main(int(sys.argv[1]) if len(sys.argv)>1 else 817)
