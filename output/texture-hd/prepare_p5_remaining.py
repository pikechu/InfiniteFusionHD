"""Freeze authorized remaining P5 batches and build one exact-pixel reference index."""
from collections import Counter, defaultdict
import hashlib
import shutil
from PIL import Image, ImageDraw
from resume_p2_menu import ROOT, OUT, read, write, digest


def signature(image):
    rgba = image.convert('RGBA')
    return (rgba.size, hashlib.sha256(rgba.tobytes()).hexdigest())


def main():
    plan = read(OUT / 'execution-plan/plan.json')
    batches = [b for b in plan['batch_index'] if b['priority'] == 'P5' and b['status'] != 'completed']
    assert batches[0]['id'] == 'batch-819' and len(batches) == 39 and sum(b['file_count'] for b in batches) == 1754
    work = OUT / 'p5-work';evidence = OUT / 'p5-evidence/remaining';evidence.mkdir(parents=True, exist_ok=True)
    protected = {p.relative_to(ROOT).as_posix(): digest(p) for folder in ('Data/Scripts', 'Mods', 'Data/localization')
                 for p in (ROOT / folder).rglob('*') if p.is_file()}
    protected.update({f'output/texture-hd/p{n}-progress.json': digest(OUT / f'p{n}-progress.json') for n in (1, 2, 3, 4)})
    checkpoint = work / 'remaining-protected.json'
    if not checkpoint.exists():write(checkpoint, {'files': protected})
    else:assert all(digest(ROOT / p) == sha for p, sha in read(checkpoint)['files'].items())
    rows = [];wanted = set();scaled_wanted = set()
    for batch in batches:
        fixed = read(OUT / f"execution-plan/batches/{batch['id']}.json")
        for entry in fixed['entries']:
            source = ROOT / entry['source'];backup = OUT / batch['id'] / 'originals' / entry['source']
            backup.parent.mkdir(parents=True, exist_ok=True)
            if not backup.exists():shutil.copy2(source, backup)
            assert digest(source) == digest(backup)
            with Image.open(source) as im:
                assert list(im.size) == entry['size']
                frames = []
                for index in range(getattr(im, 'n_frames', 1)):
                    im.seek(index);rgba = im.convert('RGBA')
                    frames.append({'rgba_sha256': signature(rgba)[1], 'alpha_sha256': hashlib.sha256(rgba.getchannel('A').tobytes()).hexdigest(),
                                   'duration_ms': im.info.get('duration'), 'disposal': getattr(im, 'disposal_method', None)})
                im.seek(0)
                row = {**entry, 'batch': batch['id'], 'stage': batch['stage'], 'sha256': digest(source),
                       'format': im.format, 'mode': im.mode, 'encoded_frames': len(frames), 'encoded_loop': im.info.get('loop'),
                       'frames': frames, 'rgba_sha256': frames[0]['rgba_sha256'], 'alpha_sha256': frames[0]['alpha_sha256'],
                       'current_bytes': source.stat().st_size, 'current_mtime_ns': source.stat().st_mtime_ns}
                wanted.add((im.size, row['rgba_sha256']))
                if im.size == (96, 96) and len(frames) == 1:
                    row['nearest_neighbor_3x_rgba_sha256'] = signature(im.convert('RGBA').resize((288, 288), Image.Resampling.NEAREST))[1]
                    scaled_wanted.add(((288, 288), row['nearest_neighbor_3x_rgba_sha256']))
            rows.append(row)
        print(f"FROZEN {batch['id']} files={len(rows)}", flush=True)
    write(work / 'remaining-native-index.json', [{k: r[k] for k in ('source', 'batch', 'stage', 'size', 'sha256', 'format', 'encoded_frames')} for r in rows])
    by_source = {r['source']: r for r in rows};sizes = {s[0] for s in wanted | scaled_wanted};matches = defaultdict(list)
    all_wanted = wanted | scaled_wanted
    inventory = read(OUT / 'inventory.json')
    for index, entry in enumerate(inventory['assets']):
        if tuple(entry['size']) not in sizes:continue
        source = ROOT / entry['path']
        if entry['path'] in by_source:
            row = by_source[entry['path']];key = (tuple(row['size']), row['rgba_sha256'])
        else:
            with Image.open(source) as im:key = signature(im)
        if key in all_wanted:
            matches[key].append({'kind': 'current_file', 'source': entry['path'], 'status': entry['status'], 'sha256': digest(source)})
        if index % 2500 == 0:print(f'PIXEL_INDEX {index}/{len(inventory["assets"])}', flush=True)
    for number in range(1, 819):
        path = OUT / f'batch-{number:03}/manifest.json'
        if not path.exists():continue
        for entry in read(path)['entries']:
            original = OUT / f'batch-{number:03}/originals' / entry['source']
            if not original.exists():continue
            with Image.open(original) as im:
                if im.size not in sizes:continue
                key = signature(im)
            if key in all_wanted:matches[key].append({'kind': 'historical_original', 'source': entry['source'], 'archive': original.relative_to(ROOT).as_posix(), 'sha256': digest(original)})
    for row in rows:
        row['pixel_matches'] = [r for r in matches[(tuple(row['size']), row['rgba_sha256'])] if r['source'] != row['source'] or r['kind'] == 'historical_original']
        row['nearest_neighbor_3x_matches'] = matches.get(((288, 288), row.get('nearest_neighbor_3x_rgba_sha256')), [])
    pages = []
    for batch in batches:
        selected = [r for r in rows if r['batch'] == batch['id']]
        folder = OUT / 'p5-evidence' / batch['id'];folder.mkdir(parents=True, exist_ok=True)
        source96 = batch['stage'] == 'source96'
        cols, cw, ch, count = (8, 160, 164, 48) if source96 else (4, 320, 300, 8)
        batch_pages = []
        for start in range(0, len(selected), count):
            part = selected[start:start+count];sheet = Image.new('RGB', (cols*cw, ((len(part)+cols-1)//cols)*ch), '#353c46');draw = ImageDraw.Draw(sheet)
            for offset, row in enumerate(part):
                x=offset%cols*cw;y=offset//cols*ch
                draw.text((x+2,y+2), row['source'].split('/')[-1][-int(cw/6):], fill='white')
                draw.text((x+2,y+17), f"{row['size']} {row['format']} dup={len(row['pixel_matches'])}", fill='white')
                with Image.open(ROOT / row['source']) as im:
                    rgba=im.convert('RGBA')
                    if rgba.height>4096:
                        sample=rgba.crop((0,0,rgba.width,min(rgba.width*2,rgba.height)))
                        row['review_thumbnail_scope']='Top of tall atlas; separate phase samples and byte/pixel identities retained, no seam or map-use certification'
                    else:sample=rgba
                    sample.thumbnail((cw-8,ch-38), Image.Resampling.NEAREST)
                    sheet.paste(sample,(x+(cw-sample.width)//2,y+34),sample)
            page=(folder/f'review-{start//count+1:02}.png').relative_to(ROOT).as_posix();sheet.save(ROOT/page)
            batch_pages.append(page);pages.append({'path': page, 'batch': batch['id'], 'sources': [r['source'] for r in part]})
        write(work / f"{batch['id']}-scope.json", {'batch': batch['id'], 'entries': selected, 'review_pages': batch_pages,
              'duplicate_rule': 'Exact decoded RGBA/dimensions; separately labeled exact integer-3x nearest-neighbor matches do not imply automatic runtime binding.'})
    write(work / 'remaining-scope.json', {'entries': rows, 'review_pages': pages, 'authorized_scope': 'Complete P5 batches 819-857'})
    print({'files': len(rows), 'pages': len(pages), 'exact_match_sources': sum(bool(r['pixel_matches']) for r in rows),
           'nearest_neighbor_3x_sources': sum(bool(r['nearest_neighbor_3x_matches']) for r in rows), 'formats': dict(Counter(r['format'] for r in rows)),
           'multiple_encoded_frames': [r['source'] for r in rows if r['encoded_frames']>1]}, flush=True)


if __name__ == '__main__':main()
