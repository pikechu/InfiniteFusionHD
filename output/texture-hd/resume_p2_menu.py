"""Audit the menu checkpoint and prepare native before/candidate bitmap routes."""
from pathlib import Path
import hashlib
import json
from PIL import Image
ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    audit = read(OUT / 'p2-audit.json')
    completed = {}
    for number in range(58, 152):
        receipt = OUT / f'batch-{number:03}/validation.json'
        if receipt.exists():
            record = read(receipt)
            if record['status'] == 'completed':
                for entry in record['entries']:
                    completed[entry['source']] = entry
    candidates = {}
    for number in (64, 68):
        batch = OUT / f'batch-{number:03}'
        manifest_path = batch / 'manifest.json'
        manifest = read(manifest_path if manifest_path.exists() else batch / 'candidate-manifest.json')
        for entry in manifest['entries']:
            for folder, key in [('originals', 'before_sha256'), ('ready', 'after_sha256'), ('generated', 'generated_sha256')]:
                assert digest(batch / folder / entry['source']) == entry[key], (folder, entry['source'])
            candidates[entry['source']] = {**entry, 'batch': batch.name, 'candidate_status': manifest.get('status', 'pending')}
    assert len(candidates) == 32
    report, paths = [], {'before': {}, 'candidate': {}}
    for row in audit['sources']:
        source = ROOT / row['source']
        current = digest(source)
        decision = completed.get(row['source'])
        expected = decision['after_sha256'] if decision and decision['status'] == 'applied' else row['sha256']
        assert current == expected, 'External asset change: ' + row['source']
        entry = candidates.get(row['source'])
        state = decision['status'] if decision else 'not_started'
        if entry and not decision:
            assert current in (entry['before_sha256'], entry['after_sha256'])
            state = 'candidate_pending_review' if current == entry['before_sha256'] else 'applied_unregistered'
        report.append({'source': row['source'], 'batch': row['batch'], 'sha256': current, 'state': state})
        if 64 <= int(row['batch'][6:]) <= 76:
            with Image.open(source) as image:
                image.load()
                assert list(image.size) == row['size']
                assert getattr(image, 'n_frames', 1) == 1
            key = source.with_suffix('').as_posix().lower()
            paths['before'][key] = source.as_posix()
            paths['candidate'][key] = (OUT / entry['batch'] / 'ready' / row['source']).as_posix() if entry else source.as_posix()
    assert len(paths['before']) == 288
    latest = {'status': 'verified', 'sources': report,
          'candidate_files': len(candidates), 'candidate_game_files_still_original': all(digest(ROOT / e['source']) == e['before_sha256'] for e in candidates.values()),
          'completed_from_validation': len(completed), 'scope': 'All 2223 P2 source hashes checked against audit and completed validation receipts; candidate backup, ready and generated hashes checked.'}
    if not (OUT / 'p2-evidence/resume-20261028.json').exists():
        write(OUT / 'p2-evidence/resume-20261028.json', latest)
    write(OUT / 'p2-evidence/resume-latest.json', latest)
    write(OUT / 'p2-work/menu-native-paths.json', paths)
    print(json.dumps({'verified_p2_sources': len(report), 'completed': len(completed), 'candidate_files': len(candidates), 'native_menu_inputs': len(paths['before'])}))

if __name__ == '__main__':
    main()


