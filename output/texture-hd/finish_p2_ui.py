"""Apply the reviewed first P2 UI stage and maintain paired language records."""
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


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


audit = read(OUT / 'p2-audit.json')
rows = [row for row in audit['sources'] if 58 <= int(row['batch'][6:]) <= 63]
assert len(rows) == 121
proof = read(OUT / 'p2-evidence/ui-native-validation.json')
assert proof['status'] == 'passed' and proof['command_state_pairs'] == 120 and proof['hp_exp_traces_identical']
for phase in ('before', 'after'):
    assert f'P2_UI_PASS phase={phase} images=121 command_states=120 animation_cases=12' in (OUT / f'p2-evidence/native-ui/{phase}-result.txt').read_text()
manifest = read(OUT / 'batch-060/manifest.json')
applied = {entry['source']: entry for entry in manifest['entries']}
assert len(applied) == 6
tested = read(OUT / 'p2-evidence/native-ui/after-inputs.json')
for row in rows:
    entry = applied.get(row['source'])
    expected = {row['sha256'], entry['after_sha256']} if entry else {row['sha256']}
    assert digest(ROOT / row['source']) in expected, 'Source changed: ' + row['source']
    if entry:
        batch = OUT / row['batch']
        validate_image(batch / 'originals' / row['source'], batch / 'ready' / row['source'])
        assert digest(batch / 'originals' / row['source']) == entry['before_sha256']
        assert digest(batch / 'ready' / row['source']) == entry['after_sha256']
        assert digest(batch / 'generated' / row['source']) == entry['generated_sha256']
        assert tested[(ROOT / row['source']).with_suffix('').as_posix().lower()] == entry['after_sha256']

catalog_path = ROOT / 'Data/localization/zh-CN-images.json'
catalog_digest = digest(catalog_path)
catalog = read(catalog_path)
changes_path = OUT / 'batch-060/catalog-changes.json'
if changes_path.exists():
    changes = read(changes_path)
else:
    changes = {}
    for source, row in catalog['images'].items():
        if source not in applied:
            continue
        assert row['path'] in applied
        assert row['source_sha256'] == applied[source]['before_sha256']
        assert row['sha256'] == applied[row['path']]['before_sha256']
        after = {**row, 'source_sha256': applied[source]['after_sha256'], 'sha256': applied[row['path']]['after_sha256']}
        changes[source] = {'before': row, 'after': after}
    assert len(changes) == 3
    write(changes_path, changes)
for source, change in changes.items():
    assert catalog['images'][source] in (change['before'], change['after']), 'Paired image catalog changed externally'

installed = all(digest(ROOT / source) == entry['after_sha256'] for source, entry in applied.items())
install_or_verify(OUT / 'batch-060', 'verify' if installed else 'apply')
assert digest(catalog_path) == catalog_digest, 'Catalog changed during image application; preserve external changes'
for source, change in changes.items():
    catalog['images'][source] = change['after']
temporary = catalog_path.with_name(catalog_path.name + '.texture-hd.tmp')
write(temporary, catalog)
temporary.replace(catalog_path)
install_or_verify(OUT / 'batch-060', 'verify')

code = '\n'.join(path.read_text(encoding='utf-8', errors='replace') for folder in ('Data/Scripts', 'Mods') for path in (ROOT / folder).rglob('*.rb'))
event_strings = read(OUT / 'p2-evidence/event-resource-references.json')
event_text = '\n'.join(event_strings)
plan_path = OUT / 'execution-plan/plan.json'
plan = read(plan_path)
index = {row['id']: row for row in plan['batch_index']}
decisions = {}
for number in range(58,64):
    name = f'batch-{number:03}'
    batch = OUT / name
    record_path = OUT / 'execution-plan/batches' / (name + '.json')
    record = read(record_path)
    assert all(index[dependency]['status'] == 'completed' for dependency in record['depends_on'])
    entries = []
    for row in [row for row in rows if row['batch'] == name]:
        source = ROOT / row['source']
        if row['source'] in applied:
            entry = {**applied[row['source']], 'status': 'applied', 'reason': 'Reviewed AI fine-detail proposal; original labels, alpha and state boundaries retained; paired English/Chinese refinement kept identical.'}
        else:
            assert digest(source) == row['sha256']
            backup = batch / 'originals' / row['source']
            backup.parent.mkdir(parents=True, exist_ok=True)
            if not backup.exists():
                shutil.copy2(source, backup)
            assert digest(backup) == row['sha256']
            with Image.open(source) as image:
                image.load()
                assert list(image.size) == row['size']
            stem = source.stem
            literal_refs = code.lower().count(stem.lower())
            event_refs = event_text.lower().count(stem.lower())
            if literal_refs == 0 and event_refs == 0 and source.parent.as_posix().endswith('Graphics/Pictures') and stem.lower().startswith(('battle', 'abilitymessage', 'ballstatus', 'movesel', 'newbattle')):
                reason = 'Legacy UI has no filename reference in current source/event text; current battle scenes load the Battle/ graphics. Keep this compatibility source unchanged.'
            else:
                reason = 'Original-size visual review shows crisp text, small symbols, flat fills or functional bars. Added material grain offers no useful clarity improvement and can reduce readability/state contrast; retain the original.'
            entry = {'source': row['source'], 'size': row['size'], 'sha256': row['sha256'], 'status': 'preserved', 'reason': reason,
                     'source_text_reference_count': literal_refs, 'event_text_reference_count': event_refs}
        entries.append(entry)
        decisions[entry['source']] = {**entry, 'batch': name}
    receipt = {'batch': name, 'status': 'completed', 'applied': sum(e['status'] == 'applied' for e in entries),
               'preserved': sum(e['status'] == 'preserved' for e in entries), 'entries': entries,
               'evidence': ['output/texture-hd/p2-evidence/ui-native-validation.json', 'output/texture-hd/p2-work/ui-validation.json'],
               'validation_scope': 'Native image decoding; original-size atlas comparison; English/Chinese text regions; 120 command states; 12 HP/EXP animation cases with identical before/after traces. No full gameplay or Android device regression.'}
    write(batch / 'validation.json', receipt)
    record.update(status='completed', result=(batch / 'validation.json').relative_to(ROOT).as_posix(),
                  applied_files=receipt['applied'], preserved_files=receipt['preserved'])
    write(record_path, record)
    index[name].update(status='completed', result=record['result'], applied_files=receipt['applied'], preserved_files=receipt['preserved'])
write(OUT / 'batch-060/jobs.json', {'batch': '060', 'method': 'built-in image_gen; text/alpha/state-grid protected; shared English/Chinese refinement',
                                  'entries': [read(OUT / 'p2-work' / (key + '.json')) for key in ('cursor_command','cursor_command_darkmode','cursor_mega')]})
plan['next_batch'] = next(row['id'] for row in plan['batch_index'] if row['status'] != 'completed')
write(plan_path, plan)
inventory_path = OUT / 'inventory.json'
inventory = read(inventory_path)
for row in inventory['assets']:
    if row['path'] in decisions:
        decision = decisions[row['path']]
        row.update(status=decision['status'], batch=decision['batch'], reason=decision['reason'])
for status in ('applied','preserved','pending'):
    inventory[status] = sum(row['status'] == status for row in inventory['assets'])
assert sum(inventory[key] for key in ('applied','preserved','pending')) == inventory['total']
write(inventory_path, inventory)
from update_p2_progress import update_progress
progress = update_progress()
index_path = OUT / 'execution-plan/batch-index.zh-CN.md'
lines = index_path.read_text(encoding='utf-8').splitlines()
for number in range(58,64):
    lines = [line.replace('待执行','已完成') if f'batches/batch-{number:03}.json' in line else line for line in lines]
index_path.write_text('\n'.join(lines)+'\n',encoding='utf-8')
print(json.dumps(progress))
