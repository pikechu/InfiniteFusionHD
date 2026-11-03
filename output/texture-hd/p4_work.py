"""Freeze P4 sources, back up originals, and prepare fixed-batch review pages."""
import hashlib
import math
import re
import shutil
import subprocess
from collections import Counter

from PIL import Image, ImageDraw
from resume_p2_menu import ROOT, OUT, read, write, digest
from update_p2_progress import self_check, update_progress

W = OUT / 'p4-work'
E = OUT / 'p4-evidence'
GIT = 'D:/Users/meikun.zhang/AppData/Local/Programs/Git/mingw64/bin/git.exe'


def main():
    self_check()
    W.mkdir(exist_ok=True)
    E.mkdir(exist_ok=True)
    assert read(OUT / 'p3-progress.json')['status'] == 'completed'
    plan = read(OUT / 'execution-plan/plan.json')
    batches = [r for r in plan['batch_index'] if r['priority'] == 'P4']
    assert len(batches) == 276 and sum(r['file_count'] for r in batches) == 5065
    if not (W / 'session-protected.json').exists():
        files = {p.relative_to(ROOT).as_posix(): digest(p) for folder in ('Data/Scripts', 'Mods', 'Data/localization')
                 for p in (ROOT / folder).rglob('*') if p.is_file()}
        files.update({f'output/texture-hd/p{n}-progress.json': digest(OUT / f'p{n}-progress.json') for n in (1, 2, 3)})
        write(W / 'session-protected.json', {'files': files})
    if not (OUT / 'p4-audit.json').exists():
        tree = subprocess.run([GIT, 'ls-tree', '-r', '-z', 'HEAD', '--', 'Graphics'], cwd=ROOT,
                              check=True, capture_output=True, timeout=30).stdout
        blobs = {r.split(b'\t', 1)[1].decode('utf-8'): r.split(b'\t', 1)[0].split()[2].decode()
                 for r in tree.split(b'\0') if r}
        rows = []
        for batch in batches:
            fixed = read(OUT / 'execution-plan/batches' / (batch['id'] + '.json'))
            for entry in fixed['entries']:
                raw = (ROOT / entry['source']).read_bytes()
                blob = hashlib.sha1(f'blob {len(raw)}\0'.encode() + raw).hexdigest()
                reference = blobs.get(entry['source'])
                rows.append({**entry, 'batch': batch['id'], 'stage': batch['stage'],
                             'sha256': hashlib.sha256(raw).hexdigest(), 'git_blob': blob,
                             'reference_blob': reference, 'external_change': reference is not None and reference != blob,
                             'review_status': 'not_started'})
        assert len(rows) == len({r['source'] for r in rows}) == 5065
        write(OUT / 'p4-audit.json', {'date': '2026-11-02', 'authorized_scope': 'P4 batches 541-816',
                                    'total': 5065, 'sources': rows})
    audit = read(OUT / 'p4-audit.json')
    rows = []
    seen_pixels = {}
    pages = []
    for batch in batches:
        parts = []
        for row in [r for r in audit['sources'] if r['batch'] == batch['id']]:
            path = ROOT / row['source']
            assert digest(path) == row['sha256'], 'Concurrent image change: ' + row['source']
            backup = OUT / row['batch'] / 'originals' / row['source']
            backup.parent.mkdir(parents=True, exist_ok=True)
            if not backup.exists():
                shutil.copy2(path, backup)
            assert digest(backup) == row['sha256']
            with Image.open(path) as im:
                assert list(im.size) == row['size']
                frames = []
                for i in range(getattr(im, 'n_frames', 1)):
                    im.seek(i)
                    rgba = im.convert('RGBA')
                    frames.append({'rgba_sha256': hashlib.sha256(rgba.tobytes()).hexdigest(),
                                   'alpha_sha256': hashlib.sha256(rgba.getchannel('A').tobytes()).hexdigest(),
                                   'duration_ms': im.info.get('duration'), 'disposal': getattr(im, 'disposal_method', None)})
                meta = {**row, 'format': im.format, 'mode': im.mode, 'encoded_frames': len(frames),
                        'encoded_loop': im.info.get('loop'), 'frames': frames}
                bracket = re.match(r'^\[(\d+)(?:,(\d+))?\]', path.name)
                meta['bracket_frames'] = int(bracket[1]) if bracket else None
                meta['bracket_delay'] = int(bracket[2] or 10) if bracket else None
                # Strip geometry is a donor-sheet hypothesis until its consumer is found.
                if row['stage'] == 'animated' and len(frames) == 1 and im.width % im.height == 0:
                    meta['donor_square_cells'] = im.width // im.height
                signature = (tuple(row['size']), tuple((f['rgba_sha256'], f['duration_ms']) for f in frames))
                if signature in seen_pixels:
                    meta['same_pixels_as'] = seen_pixels[signature]
                else:
                    seen_pixels[signature] = row['source']
                    parts.append(meta)
                rows.append(meta)
        stage = batch['stage']
        count, cols, cw, ch = (48, 8, 160, 150) if stage == 'icons' else (64, 8, 120, 110) if stage == 'footprint' else (16, 4, 320, 240) if stage == 'windows' else (8, 4, 360, 380)
        for start in range(0, len(parts), count):
            part = parts[start:start + count]
            sheet = Image.new('RGB', (cols * cw, math.ceil(len(part) / cols) * ch), '#353c46')
            draw = ImageDraw.Draw(sheet)
            for i, row in enumerate(part):
                with Image.open(ROOT / row['source']) as im:
                    im.seek(0)
                    image = im.convert('RGBA')
                    if stage == 'animated' and row.get('donor_square_cells', 1) > 1:
                        image = image.crop((0, 0, image.height, image.height))
                    image.thumbnail((cw - 8, ch - 40))
                x, y = i % cols * cw, i // cols * ch
                sheet.paste(image, (x + (cw - image.width) // 2, y + 38), image)
                draw.text((x + 3, y + 1), row['source'].replace('Graphics/', '')[-45:], fill='white')
                draw.text((x + 3, y + 15), f"{row['size']} {row['format']} encoded={row['encoded_frames']}", fill='white')
            name = f"review-{batch['id'][6:]}-{start // count + 1:02}.png"
            sheet.save(E / name)
            pages.append({'path': (E / name).relative_to(ROOT).as_posix(), 'batch': batch['id'],
                          'sources': [r['source'] for r in part]})
        if int(batch['id'][6:]) % 25 == 0:
            print(f"AUDIT {batch['id']} sources={len(rows)} pages={len(pages)}", flush=True)
    assert len(rows) == 5065
    write(W / 'scope.json', {'date': '2026-11-02', 'entries': rows, 'review_pages': pages,
                            'unique_visual_sources': len(seen_pixels)})
    write(W / 'native-index.json', [{k: r[k] for k in ('source', 'batch', 'stage', 'size', 'sha256', 'format',
                                                        'encoded_frames', 'bracket_frames', 'bracket_delay')} for r in rows])
    if not (W / 'visual-review.json').exists():
        write(W / 'visual-review.json', {'reviewed_pages': [], 'notes': {}})
    progress = update_progress('P4')
    write(W / 'resume.json', {'status': progress['status'], 'next_batch': progress['next_batch'], 'candidate_pending_review': []})
    print({'sources': len(rows), 'review_pages': len(pages), 'formats': dict(Counter(r['format'] for r in rows)),
           'encoded_animations': sum(r['encoded_frames'] > 1 for r in rows),
           'external_changes_preserved': [r['source'] for r in rows if r['external_change']]})


if __name__ == '__main__':
    main()
