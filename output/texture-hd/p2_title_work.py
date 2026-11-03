"""Resume the fixed batch-103 scope without touching other sessions' work."""
from pathlib import Path
from PIL import Image, ImageDraw
from resume_p2_menu import ROOT, OUT, read, write, digest
import shutil

W = OUT / 'p2-title-work'
E = OUT / 'p2-evidence/titles'


def main():
    W.mkdir(exist_ok=True)
    E.mkdir(parents=True, exist_ok=True)
    audit = read(OUT / 'p2-audit.json')
    completed = {}
    for number in range(58, 103):
        receipt = read(OUT / f'batch-{number:03}/validation.json')
        assert receipt['status'] == 'completed'
        completed.update({entry['source']: entry for entry in receipt['entries']})
    assert len(completed) == 985
    changes = []
    for row in audit['sources']:
        entry = completed.get(row['source'])
        expected = entry['after_sha256'] if entry and entry['status'] == 'applied' else row['sha256']
        current = digest(ROOT / row['source'])
        if current != expected:
            changes.append({'source': row['source'], 'expected': expected, 'current': current})
    plan = read(OUT / 'execution-plan/batches/batch-103.json')
    assert plan['status'] == 'planned' and len(plan['entries']) == 20
    members = {entry['source'] for entry in plan['entries']}
    assert not any(row['source'] in members for row in changes), 'Concurrent source changes in this batch'
    rows = []
    for item in plan['entries']:
        row = next(row for row in audit['sources'] if row['source'] == item['source'])
        source = ROOT / row['source']
        with Image.open(source) as im:
            im.load()
            assert list(im.size) == row['size']
            rows.append({**row, 'encoded_frames': getattr(im, 'n_frames', 1),
                         'mode': im.mode, 'alpha_sha256': __import__('hashlib').sha256(im.convert('RGBA').getchannel('A').tobytes()).hexdigest()})
        backup = OUT / 'batch-103/originals' / row['source']
        backup.parent.mkdir(parents=True, exist_ok=True)
        if not backup.exists():
            shutil.copy2(source, backup)
        assert digest(backup) == row['sha256']
    for start in range(0, len(rows), 8):
        sheet = Image.new('RGB', (1024, 440), '#30343c')
        draw = ImageDraw.Draw(sheet)
        for i, row in enumerate(rows[start:start+8]):
            with Image.open(ROOT / row['source']) as original:
                im = original.convert('RGBA'); im.thumbnail((256,192))
            x = i % 4 * 256; y = i // 4 * 220
            sheet.paste(im, (x,y+24), im)
            draw.text((x+2,y+4), Path(row['source']).name, fill='white')
        sheet.save(E / f'originals-{start//8+1:02}.png')
    write(W / 'scope.json', {'date': '2026-10-30', 'status': 'audited', 'root': str(ROOT),
          'all_p2_source_hashes_checked': len(audit['sources']), 'completed_sources_checked': len(completed),
          'entries': rows, 'concurrent_changes_preserved': changes})
    write(W / 'session-protected.json', {'files': {
        path.relative_to(ROOT).as_posix(): digest(path)
        for directory in ('Data/Scripts','Mods','Data/localization')
        for path in (ROOT / directory).rglob('*') if path.is_file()}})
    routes = {str((ROOT / row['source']).with_suffix('')).replace('\\','/').lower(): row['source'] for row in rows}
    write(W / 'native-paths.json', {'before': routes, 'candidate': routes})
    write(W / 'resume.json', {'status': 'in_progress', 'batch': 'batch-103',
          'applied': 0, 'preserved': 0, 'candidate_pending_review': 0,
          'next_action': 'Review actual title/credits consumers and visual benefit before generating candidates.'})
    print({'audited': len(rows), 'all_p2_hashes_checked': 2223, 'external_changes': changes, 'original_sheets': 3})


if __name__ == '__main__':
    main()
