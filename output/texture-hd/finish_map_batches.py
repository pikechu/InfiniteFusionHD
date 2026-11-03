"""Apply validated P1 map textures and close their fixed batch records."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scripts/graphics'))
from texture_batch import install_or_verify, validate_image


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


audit = read(OUT / 'p1-evidence/map-scope-audit.json')
decisions = read(OUT / 'p1-evidence/map-review-decisions.json')
rows = [{**row, **decisions.get(row['source'], {})} for row in audit['entries']]
for path, expected in audit['map_data_sha256'].items():
    assert digest(ROOT / path) == expected, 'Map data changed since usage audit: ' + path
for phase in ('before', 'after'):
    log = (OUT / f'p1-evidence/native-maps/{phase}-result.txt').read_text()
    assert f'NATIVE_MAP_PASS phase={phase} maps=27' in log, log
auto_log = (OUT / 'p1-evidence/native-autotiles/result.txt').read_text()
assert 'NATIVE_AUTOTILE_PASS files=15 frames=269 patterns_per_frame=48' in auto_log, auto_log
tested_maps = read(OUT / 'p1-evidence/native-maps/after-inputs.json')
tested_auto = read(OUT / 'p1-evidence/native-autotiles/inputs.json')

manifests = {}
applied = {}
for number in range(14, 58):
    batch = OUT / f'batch-{number:03}'
    path = batch / 'manifest.json'
    if path.exists():
        manifest = read(path)
        manifests[batch.name] = manifest
        for entry in manifest['entries']:
            assert entry['source'] not in applied
            applied[entry['source']] = entry
            assert digest(batch / 'originals' / entry['source']) == entry['before_sha256']
            assert digest(batch / 'ready' / entry['source']) == entry['after_sha256']
            assert digest(batch / 'generated' / entry['source']) == entry['generated_sha256']
            validate_image(batch / 'originals' / entry['source'], batch / 'ready' / entry['source'])
            key = (ROOT / entry['source']).with_suffix('').as_posix().lower()
            assert tested_maps[key] == entry['after_sha256'], 'Native map test used a different candidate'
            if '/Autotiles/' in entry['source']:
                assert tested_auto[entry['source']]['after'] == entry['after_sha256']
            with Image.open(batch / 'originals' / entry['source']) as before, Image.open(batch / 'ready' / entry['source']) as after:
                assert before.convert('RGBA').tobytes() != after.convert('RGBA').tobytes(), 'No pixel change; review instead of counting as enhanced'
assert set(applied) == {row['source'] for row in rows if row['action'] == 'enhance'}
assert len(applied) == 24
for row in rows:
    source = ROOT / row['source']
    expected = applied[row['source']]['before_sha256'] if row['source'] in applied else row['source_sha256']
    assert digest(source) in ({expected, applied[row['source']]['after_sha256']} if row['source'] in applied else {expected})

if sys.argv[1] == 'apply':
    for name, manifest in manifests.items():
        current = [digest(ROOT / entry['source']) == entry['after_sha256'] for entry in manifest['entries']]
        assert all(current) or not any(current), 'Partially applied batch requires review: ' + name
        install_or_verify(OUT / name, 'verify' if all(current) else 'apply')
elif sys.argv[1] != 'verify':
    raise ValueError('Expected apply or verify')
for name in manifests:
    install_or_verify(OUT / name, 'verify')

plan_path = OUT / 'execution-plan/plan.json'
plan = read(plan_path)
index = {row['id']: row for row in plan['batch_index']}
for number in range(14, 58):
    name = f'batch-{number:03}'
    batch = OUT / name
    record_path = OUT / 'execution-plan/batches' / (name + '.json')
    record = read(record_path)
    assert all(index[dependency]['status'] == 'completed' for dependency in record['depends_on'])
    selected = [row for row in rows if row['batch'] == name]
    assert {row['source'] for row in selected} == {entry['source'] for entry in record['entries']}
    entries = []
    for row in selected:
        source = ROOT / row['source']
        if row['source'] in applied:
            entry = {'source': row['source'], 'status': 'applied', **applied[row['source']]}
        else:
            assert digest(source) == row['source_sha256']
            backup = batch / 'originals' / row['source']
            backup.parent.mkdir(parents=True, exist_ok=True)
            if not backup.exists():
                shutil.copy2(source, backup)
            assert digest(backup) == row['source_sha256']
            with Image.open(source) as image:
                image.load()
                assert list(image.size) == row['size']
            entry = {'source': row['source'], 'status': 'preserved', 'size': row['size'],
                     'sha256': row['source_sha256'], 'reason': row['reason']}
        entries.append({**entry, 'assigned_map_count': len(row['assigned_maps']), 'actual_map_count': len(row['actual_maps'])})
    receipt = {'batch': name, 'status': 'completed',
               'applied': sum(e['status'] == 'applied' for e in entries),
               'preserved': sum(e['status'] == 'preserved' for e in entries), 'entries': entries,
               'dimensions_unchanged': True, 'alpha_unchanged': True,
               'evidence': ['output/texture-hd/p1-evidence/map-scope-audit.json',
                            'output/texture-hd/p1-evidence/native-maps/after-result.txt',
                            'output/texture-hd/p1-evidence/native-autotiles/result.txt'],
               'validation_scope': 'Original-size visual comparison; 27 native map views; 15 autotile sources, 269 frames and 48 assembly patterns per frame. No complete gameplay or Android device regression.'}
    write(batch / 'validation.json', receipt)
    if name in manifests and record['method'] != 'tileset':
        jobs = [read(OUT / 'p1-autotile-work' / (task['key'] + '.json')) for task in read(OUT / 'p1-autotile-work/tasks.json') if task['batch'] == name]
        write(batch / 'jobs.json', {'batch': name[6:], 'method': 'built-in image_gen; fixed geometry and time-consistent luminance texture', 'entries': jobs})
    record.update(status='completed', result=(batch / 'validation.json').relative_to(ROOT).as_posix(),
                  applied_files=receipt['applied'], preserved_files=receipt['preserved'])
    write(record_path, record)
    index[name].update(status='completed', result=record['result'], applied_files=receipt['applied'], preserved_files=receipt['preserved'])

plan['status'] = 'in_progress'
plan['next_batch'] = next(row['id'] for row in plan['batch_index'] if row['status'] != 'completed')
write(plan_path, plan)
inventory_path = OUT / 'inventory.json'
inventory = read(inventory_path)
processed = {row['source']: row for row in rows}
for entry in inventory['assets']:
    if entry['path'] in processed:
        row = processed[entry['path']]
        entry['status'] = 'applied' if entry['path'] in applied else 'preserved'
        entry['batch'] = row['batch']
        if entry['status'] == 'preserved':
            entry['reason'] = row['reason']
for status in ('applied', 'preserved', 'pending'):
    inventory[status] = sum(row['status'] == status for row in inventory['assets'])
assert inventory['applied'] + inventory['preserved'] + inventory['pending'] == inventory['total']
write(inventory_path, inventory)
receipts = [read(OUT / f'batch-{number:03}/validation.json') for number in range(5, 58)]
progress = {'authorized_scope': 'P1 batches 005-057', 'status': 'completed', 'total_files': 260,
            'completed_batches': [receipt['batch'] for receipt in receipts], 'completed_files': 260,
            'applied_files': sum(receipt['applied'] for receipt in receipts),
            'preserved_files': sum(receipt.get('preserved', 0) for receipt in receipts),
            'remaining_files': 0, 'next_batch': plan['next_batch'], 'newly_applied_map_files': len(applied)}
assert progress['applied_files'] + progress['preserved_files'] == 260
write(OUT / 'p1-progress.json', progress)
write(OUT / 'p1-map-work/resume.json', {'status': 'completed', 'remaining_atlas_pages': [],
                                      'remaining_autotiles': [], 'result': 'output/texture-hd/p1-progress.json'})
index_path = OUT / 'execution-plan/batch-index.zh-CN.md'
lines = index_path.read_text(encoding='utf-8').splitlines()
for number in range(14, 58):
    lines = [line.replace('待执行', '已完成') if f'batches/batch-{number:03}.json' in line else line for line in lines]
index_path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
print(json.dumps(progress))
