"""Record reviewed, unchanged P2 menu resources, one recoverable batch at a time."""
from pathlib import Path
import json
import shutil
from PIL import Image
from resume_p2_menu import ROOT, OUT, read, write, digest
from update_p2_progress import update_progress, self_check


def main():
    self_check()
    bag_proof = read(OUT / 'p2-evidence/bag-native-validation.json')
    assert bag_proof['status'] == 'passed' and not bag_proof['candidate_accepted']
    native = OUT / 'p2-evidence/native-menu'
    assert 'MENUS_PASS languages=2 renders=96 menu_inputs=288' in (native / 'menus-result.txt').read_text()
    menus = read(native / 'menus-review.json')
    for document in (menus, read(native / 'bag-before-traces.json')):
        for source, expected in document['script_sha256'].items():
            assert digest(ROOT / source) == expected, 'Scene source changed after validation: ' + source
    assert len(menus['renders']) == 96
    assert all((native / (label + '.png')).exists() for label in menus['renders'])
    audit_path = OUT / 'p2-audit.json'
    audit = read(audit_path)
    rows = [row for row in audit['sources'] if 64 <= int(row['batch'][6:]) <= 76]
    assert len(rows) == 288
    candidates = {}
    for number in (64,68):
        batch = OUT / f'batch-{number:03}'
        path = batch / 'manifest.json'
        manifest = read(path if path.exists() else batch / 'candidate-manifest.json')
        for entry in manifest['entries']:
            for folder, key in [('originals','before_sha256'),('ready','after_sha256'),('generated','generated_sha256')]:
                assert digest(batch / folder / entry['source']) == entry[key]
            candidates[entry['source']] = entry
    assert len(candidates) == 32
    jobs = {alias: job for task, check, job in zip(read(OUT/'p2-work/bag-tasks.json'), read(OUT/'p2-work/bag-validation.json'), read(OUT/'p2-work/bag-jobs.json')['entries']) for alias in check['aliases']}
    assert set(jobs) == set(candidates)
    assert all(job['source'] == check['source'] == task['source'] for task, check, job in zip(read(OUT/'p2-work/bag-tasks.json'), read(OUT/'p2-work/bag-validation.json'), read(OUT/'p2-work/bag-jobs.json')['entries']))
    code = '\n'.join(p.read_text(encoding='utf-8',errors='replace') for folder in ('Data/Scripts','Mods') for p in (ROOT/folder).rglob('*.rb')).lower()
    events = '\n'.join(read(OUT/'p2-evidence/event-resource-references.json')).lower()
    loaded = {p.lower().replace('\\','/').removesuffix('.png') for p in menus['loaded_paths']}
    decisions = []
    for row in rows:
        source = ROOT / row['source']
        assert digest(source) == row['sha256'] == menus['input_sha256'][row['source']], 'External image change: ' + row['source']
        path = row['source'].lower()
        if row['source'] in candidates:
            reason = '复用已有内置 image_gen 结果完成原生前后验收；128×128 原尺寸的微小明暗没有提升轮廓或口袋辨识度，保留原图。32 份候选及提示词已归档，不计为已应用。'
            kind = 'bag_candidate_rejected'
        elif '/goldsilver menu/' in path or '/gs summary backgrounds/' in path or ('/bag/bag' in path and '/bag/bag_' not in path):
            reason = '兼容目录中的旧界面版本；当前队伍、摘要和背包场景使用 Party/、Summary/、bag_ 与 bg_ 命名。原有装饰与状态差异已复核，保留兼容源图，未生成新版本。'
            kind = 'legacy_compatibility'
        elif 'ball' in source.stem.lower() or 'pokerus' in path or 'markings' in path or '/universal/' in path:
            reason = '小型符号、标记、功能填充或明确的选中状态；原像素可辨识。新增纹理不能改善原尺寸识别，反而可能改变符号和状态对比，逐字节保留原图。'
            kind = 'functional_symbol_or_fill'
        elif any(token in source.stem.lower() for token in ('cursor','slider','register','pocket','overlay','hp','cancel','panel','button')):
            reason = '文字、血条、边框、切片或选中/交换/濒死状态表；核对原生对应状态后，现有边界与色块清晰，添加材质无明确收益，保留全部切片及状态像素。'
            kind = 'ui_state_or_slice'
        else:
            reason = '布局背景以纯色色块和文字留白区为主，边框及图标清晰；已核对界面显示或兼容路径，新增纹理无原尺寸清晰度收益，保留原图。'
            kind = 'flat_ui_background'
        stem = source.stem.lower()
        with Image.open(source) as image:
            image.load()
            assert list(image.size) == row['size'] and getattr(image,'n_frames',1) == 1
            channels = list(image.getbands())
        decisions.append({'source':row['source'],'batch':row['batch'],'status':'preserved','size':row['size'],
            'sha256':row['sha256'],'reason':reason,'review_kind':kind,'encoded_frames':1,'channels':channels,
            'layout_rule':'State sheets and sibling state files remain byte-identical; encoded frame count alone does not imply static usage.',
            'source_text_reference_count':code.count(stem),'event_snapshot_reference_count':events.count(stem),
            'observed_in_menu_scene':path.removesuffix('.png') in loaded})
    write(OUT/'p2-evidence/menu-review-decisions.json',{'status':'reviewed','entries':decisions,
          'visual_review':'18 original atlases; original-size bag before/candidate pairs; 96 production party/summary/ready snapshots. Legacy paths and tiny functional symbols retained unchanged.',
          'event_reference_scope':'Existing 809-map event snapshot is supplemental evidence; absence of a literal reference is not proof of non-use.'})
    for number in range(64,77):
        name = f'batch-{number:03}'
        batch = OUT/name
        plan_path = OUT/'execution-plan/plan.json'
        plan = read(plan_path)
        index = {row['id']:row for row in plan['batch_index']}
        record_path = OUT/'execution-plan/batches'/f'{name}.json'
        record = read(record_path)
        assert all(index[dep]['status']=='completed' for dep in record['depends_on'])
        entries = [row for row in decisions if row['batch']==name]
        assert {row['source'] for row in entries} == {row['source'] for row in record['entries']}
        for entry in entries:
            source = ROOT/entry['source']
            assert digest(source)==entry['sha256']
            for folder in ('originals','delivery'):
                destination = batch/folder/entry['source']
                destination.parent.mkdir(parents=True,exist_ok=True)
                if not destination.exists():shutil.copy2(source,destination)
                assert digest(destination)==entry['sha256']
        if (batch/'manifest.json').exists():
            candidate = read(batch/'manifest.json')
            candidate.update(status='rejected_no_visible_gain',applied=False,evidence='output/texture-hd/p2-evidence/bag-native-validation.json',
                             note='ready/ contains rejected candidates; delivery/ contains the unchanged accepted originals.')
            write(batch/'candidate-manifest.json',candidate)
            (batch/'manifest.json').unlink()
        job_entries=[]
        for entry in entries:
            job = jobs.get(entry['source'])
            job_entries.append({'source':entry['source'],'source_sha256':entry['sha256'],'decision':'preserved',
                'reason':entry['reason'],'prompt':job['prompt'] if job else None,
                'generated':job['generated'] if job else None,'candidate':candidates.get(entry['source']),
                'candidate_status':'rejected_no_visible_gain' if job else 'not_generated_no_expected_gain'})
        write(batch/'jobs.json',{'batch':name[6:],'method':'Original-size review; reuse existing built-in image_gen bag proposals; no new image generation.', 'entries':job_entries})
        receipt={'batch':name,'status':'completed','applied':0,'preserved':len(entries),'candidate_pending_review':0,
                 'rejected_candidates':sum(e['source'] in candidates for e in entries),'entries':entries,
                 'known_findings':['Existing Chinese summary move-learning text/sprite overlap; original resources retained. See menu-native-validation.json.'],
                 'dimensions_unchanged':True,'alpha_unchanged':True,'filenames_and_layout_unchanged':True,
                 'evidence':['output/texture-hd/p2-evidence/resume-20261028.json','output/texture-hd/p2-evidence/bag-native-validation.json',
                             'output/texture-hd/p2-evidence/native-menu/menus-review.json','output/texture-hd/p2-evidence/menu-review-decisions.json',
                             'output/texture-hd/p2-evidence/menu-native-validation.json'],
                 'validation_scope':'288 native image decodes, 4 bag input cases and 280 before/candidate screenshot pairs, complete arrow loops, 96 English/Chinese party/summary/ready scene renders. Preserved files and delivery copies are byte-identical. Legacy/universal resources received decode, layout and usage review, not exhaustive gameplay coverage. No body/clothing, full playthrough, Android device or release-package validation.'}
        write(batch/'validation.json',receipt)
        record.update(status='completed',result=(batch/'validation.json').relative_to(ROOT).as_posix(),applied_files=0,preserved_files=len(entries),candidate_files=0)
        write(record_path,record)
        index[name].update(status='completed',result=record['result'],applied_files=0,preserved_files=len(entries))
        plan['next_batch']=next((row['id'] for row in plan['batch_index'] if row['status']!='completed'),None)
        write(plan_path,plan)
        inventory_path=OUT/'inventory.json'
        inventory=read(inventory_path)
        by_source={row['source']:row for row in entries}
        for row in inventory['assets']:
            if row['path'] in by_source:
                decision=by_source[row['path']]
                row.update(status='preserved',batch=name,reason=decision['reason'])
        for state in ('applied','preserved','pending'):inventory[state]=sum(row['status']==state for row in inventory['assets'])
        assert sum(inventory[s] for s in ('applied','preserved','pending'))==inventory['total']
        write(inventory_path,inventory)
        for row in audit['sources']:
            if row['source'] in by_source:
                row.update(review_status='preserved',validation=record['result'],accepted_sha256=row['sha256'])
        write(audit_path,audit)
        progress=update_progress()
        write(OUT/'p2-work/resume.json',{'status':'in_progress','completed_through':name,'next_batch':progress['next_batch'],
              'bag_candidates':'reviewed and rejected for no visible gain; 0 applied; archived candidate-manifest.json in batches 064 and 068',
              'candidate_pending_review':[],'progress':'output/texture-hd/p2-progress.json'})
        index_path=OUT/'execution-plan/batch-index.zh-CN.md'
        lines=index_path.read_text(encoding='utf-8').splitlines()
        lines=[line.replace('待执行','已完成') if f'batches/{name}.json' in line else line for line in lines]
        index_path.write_text('\n'.join(lines)+'\n',encoding='utf-8')
        print(json.dumps({'batch':name,'preserved':len(entries),'p2_completed':progress['completed_files'],'next_batch':progress['next_batch']}),flush=True)
    print(json.dumps(progress))

if __name__=='__main__':
    main()
