"""Freeze the next archive batch and compare pixels with current/historical assets."""
from collections import defaultdict
import hashlib
import shutil
from PIL import Image, ImageDraw
from resume_p2_menu import ROOT, OUT, read, write, digest


def pixels(path):
    with Image.open(path) as im:
        return (im.size, hashlib.sha256(im.convert('RGBA').tobytes()).hexdigest())


def main():
    batch = OUT / 'batch-817'
    fixed = read(OUT / 'execution-plan/batches/batch-817.json')
    assert fixed['status'] == 'needs_usage_audit' and len(fixed['entries']) == 48
    work = OUT / 'p5-work';evidence = OUT / 'p5-evidence/batch-817'
    work.mkdir(exist_ok=True);evidence.mkdir(parents=True, exist_ok=True)
    protected = {p.relative_to(ROOT).as_posix(): digest(p) for directory in ('Data/Scripts', 'Mods', 'Data/localization')
                 for p in (ROOT / directory).rglob('*') if p.is_file()}
    protected.update({f'output/texture-hd/p{n}-progress.json': digest(OUT / f'p{n}-progress.json') for n in (1, 2, 3, 4)})
    if not (work / 'session-protected.json').exists():write(work / 'session-protected.json', {'files': protected})
    rows = []
    for entry in fixed['entries']:
        source = ROOT / entry['source'];original = batch / 'originals' / entry['source']
        original.parent.mkdir(parents=True, exist_ok=True)
        if not original.exists():shutil.copy2(source, original)
        assert digest(source) == digest(original)
        with Image.open(source) as im:
            assert list(im.size) == entry['size']
            rgba = im.convert('RGBA')
            rows.append({**entry, 'sha256': digest(source), 'format': im.format, 'mode': im.mode,
                         'rgba_sha256': hashlib.sha256(rgba.tobytes()).hexdigest(),
                         'alpha_sha256': hashlib.sha256(rgba.getchannel('A').tobytes()).hexdigest(),
                         'current_bytes': source.stat().st_size, 'current_mtime_ns': source.stat().st_mtime_ns,
                         'encoded_frames': getattr(im, 'n_frames', 1)})
    sizes = {tuple(r['size']) for r in rows};targets = {r['source'] for r in rows}
    wanted = {(tuple(r['size']), r['rgba_sha256']) for r in rows};matches = defaultdict(list)
    inventory = read(OUT / 'inventory.json')
    for entry in inventory['assets']:
        if tuple(entry['size']) not in sizes or entry['path'] in targets:continue
        source = ROOT / entry['path'];signature = pixels(source)
        if signature in wanted:matches[signature].append({'kind': 'current_asset', 'source': entry['path'], 'status': entry['status'], 'sha256': digest(source)})
    for number in range(1, 817):
        path = OUT / f'batch-{number:03}/manifest.json'
        if not path.exists():continue
        for entry in read(path)['entries']:
            original = OUT / f'batch-{number:03}/originals' / entry['source']
            if not original.exists():continue
            signature = pixels(original)
            if signature in wanted:matches[signature].append({'kind': 'historical_original', 'source': entry['source'], 'archive': original.relative_to(ROOT).as_posix(), 'sha256': digest(original)})
    grouped = defaultdict(list)
    for row in rows:grouped[(tuple(row['size']), row['rgba_sha256'])].append(row['source'])
    for row in rows:
        signature = (tuple(row['size']), row['rgba_sha256'])
        row['pixel_matches'] = matches[signature]
        row['same_batch_matches'] = [s for s in grouped[signature] if s != row['source']]
        row['raw_bytes_changed_since_plan'] = row['current_bytes'] != row['source_bytes']
    pages = []
    for start in range(0, len(rows), 8):
        sheet = Image.new('RGB', (1280, 600), '#353c46');draw = ImageDraw.Draw(sheet)
        for i, row in enumerate(rows[start:start+8]):
            x=i%4*320;y=i//4*300
            draw.text((x+3,y+3), row['source'].replace('Graphics/','')[-49:], fill='white')
            draw.text((x+3,y+18), f"{row['size']} matches={len(row['pixel_matches'])}", fill='white')
            with Image.open(ROOT/row['source']) as im:
                rgba=im.convert('RGBA');rgba.thumbnail((312,264))
                sheet.paste(rgba,(x+(320-rgba.width)//2,y+34),rgba)
        name=f'review-{start//8+1:02}.png';sheet.save(evidence/name);pages.append((evidence/name).relative_to(ROOT).as_posix())
    write(work/'batch-817-scope.json', {'batch':'batch-817','entries':rows,'review_pages':pages,
          'duplicate_rule':'Exact decoded RGBA and dimensions; current assets and historical originals are distinguished. Same name alone is not duplicate evidence.'})
    print({'sources':len(rows),'pixel_match_sources':sum(bool(r['pixel_matches']) for r in rows),'plan_byte_size_changes':sum(r['raw_bytes_changed_since_plan'] for r in rows),'pages':pages})


if __name__ == '__main__':main()
