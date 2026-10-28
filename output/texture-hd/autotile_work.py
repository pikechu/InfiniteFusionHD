"""Prepare AI frame sheets and transfer bounded texture consistently across time."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

import numpy as np
from PIL import Image, ImageFilter, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
WORK = OUT / 'p1-autotile-work'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare():
    WORK.mkdir(exist_ok=True)
    tasks = []
    audit = json.loads((OUT / 'p1-evidence/map-scope-audit.json').read_text(encoding='utf-8'))
    for row in audit['entries']:
        if row['action'] != 'enhance' or '/Autotiles/' not in row['source']:
            continue
        source = ROOT / row['source']
        assert digest(source) == row['source_sha256']
        with Image.open(source) as original:
            original = original.convert('RGBA')
            frame_width = 32 if original.height == 32 else 96
            assert original.height in (32, 128) and original.width % frame_width == 0
            count = original.width // frame_width
            columns = min(4 if original.height == 32 else 8, count) if count > 4 else (2 if count == 4 else 1)
            rows = (count + columns - 1) // columns
            native = Image.new('RGBA', (columns * frame_width, rows * original.height))
            for frame in range(count):
                native.paste(original.crop((frame * frame_width, 0, (frame + 1) * frame_width, original.height)),
                             (frame % columns * frame_width, frame // columns * original.height))
            scale = max(1, (1024 + max(native.size) - 1) // max(native.size))
            page = native.resize((native.width * scale, native.height * scale), Image.Resampling.NEAREST)
            key = row['batch'] + '-' + source.stem.lower().replace(' ', '-').replace('_', '-')
            path = WORK / (key + '-source.png')
            page.save(path)
            tasks.append({'key': key, 'batch': row['batch'], 'source': row['source'],
                          'source_sha256': row['source_sha256'], 'size': list(original.size),
                          'page_source': path.relative_to(ROOT).as_posix(), 'page_size': list(page.size),
                          'native_page_size': list(native.size), 'frame_width': frame_width,
                          'frame_height': original.height, 'frames': count, 'columns': columns})
    assert len(tasks) == sum(row['action'] == 'enhance' and '/Autotiles/' in row['source'] for row in audit['entries'])
    (WORK / 'tasks.json').write_text(json.dumps(tasks, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'files': len(tasks), 'animation_frames': sum(t['frames'] for t in tasks)}))


def build(task):
    source = ROOT / task['source']
    assert digest(source) == task['source_sha256']
    job = json.loads((WORK / (task['key'] + '.json')).read_text(encoding='utf-8'))
    with Image.open(source) as image:
        original = image.convert('RGBA')
    with Image.open(ROOT / job['generated']) as image:
        assert abs((image.width / image.height) / (task['page_size'][0] / task['page_size'][1]) - 1) < .025
        page = image.convert('RGBA').resize(tuple(task['native_page_size']), Image.Resampling.LANCZOS)
    width, height = task['frame_width'], task['frame_height']
    frames = np.stack([np.asarray(original.crop((i * width, 0, (i + 1) * width, height)), dtype=np.int16)
                       for i in range(task['frames'])])
    high = []
    for i in range(task['frames']):
        x, y = i % task['columns'] * width, i // task['columns'] * height
        gray = page.crop((x, y, x + width, y + height)).convert('L')
        high.append(np.asarray(gray, dtype=np.float32) - np.asarray(gray.filter(ImageFilter.GaussianBlur(1)), dtype=np.float32))
    rgb = frames[:, :, :, :3]
    frame_edges = np.zeros((task['frames'], height, width), dtype=bool)
    horizontal = np.max(np.abs(rgb[:, :, 1:] - rgb[:, :, :-1]), axis=3) > 20
    vertical = np.max(np.abs(rgb[:, 1:] - rgb[:, :-1]), axis=3) > 20
    frame_edges[:, :, 1:] |= horizontal
    frame_edges[:, :, :-1] |= horizontal
    frame_edges[:, 1:] |= vertical
    frame_edges[:, :-1] |= vertical
    edges = np.all(frame_edges, axis=0)
    edges |= np.any(frames[:, :, :, 3] < 255, axis=0)
    protected = np.asarray(Image.fromarray(edges.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(3))) > 0
    yy, xx = np.indices((height, width))
    cell = 16 if height == 128 else 32
    distance = np.minimum.reduce([xx % cell, cell - 1 - xx % cell, yy % cell, cell - 1 - yy % cell])
    protected |= distance < 2
    protected |= np.any((rgb <= 6) | (rgb >= 249), axis=(0, 3))
    # A shared luminance delta in every frame cannot introduce extra frame flicker.
    delta = np.rint(np.clip(high[0] * .65, -6, 6)).astype(np.int16)
    delta[protected] = 0
    after = frames.copy()
    after[:, :, :, :3] += delta[None, :, :, None]
    assert np.min(after) >= 0 and np.max(after) <= 255
    assert np.array_equal(after[:, :, :, 3], frames[:, :, :, 3])
    assert np.array_equal(after[:, protected], frames[:, protected])
    assert np.array_equal(np.diff(after[:, :, :, :3], axis=0), np.diff(rgb, axis=0))
    assert np.max(np.abs(after - frames)) <= 6
    for axis in (1, 2):
        old_edges = np.diff(rgb, axis=axis).astype(np.int32)
        new_edges = np.diff(after[:, :, :, :3], axis=axis).astype(np.int32)
        assert np.all((old_edges * new_edges)[np.abs(old_edges) > 20] > 0)
    result = Image.new('RGBA', original.size)
    for i in range(task['frames']):
        result.paste(Image.fromarray(after[i].astype(np.uint8)), (i * width, 0))
    batch = OUT / task['batch']
    backup, ready, raw = [batch / folder / task['source'] for folder in ('originals', 'ready', 'generated')]
    for path in (backup, ready, raw):
        path.parent.mkdir(parents=True, exist_ok=True)
    if backup.exists():
        assert digest(backup) == task['source_sha256']
    else:
        shutil.copy2(source, backup)
    result.save(ready, optimize=True)
    shutil.copy2(ROOT / job['generated'], raw)
    manifest_path = batch / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {'batch': task['batch'][6:], 'entries': []}
    entry = {'source': task['source'], 'size': list(original.size), 'before_sha256': task['source_sha256'],
             'after_sha256': digest(ready), 'generated_sha256': digest(raw)}
    manifest['entries'] = [row for row in manifest['entries'] if row['source'] != task['source']] + [entry]
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    report = {'source': task['source'], 'status': 'candidate', 'frames': task['frames'],
              'size_unchanged': True, 'alpha_unchanged': True, 'quarter_tile_borders_unchanged': True,
              'static_outlines_unchanged': True, 'dynamic_edge_contrast_polarity_unchanged': True,
              'max_rgb_change': int(np.max(np.abs(after - frames))),
              'changed_pixels': int(np.count_nonzero(np.any(after != frames, axis=3))),
              'temporal_frame_differences_unchanged': True, 'loop_difference_unchanged': True,
              'frame_count_and_order_unchanged': True, 'native_animation_validation_required': True}
    (WORK / (task['key'] + '-validation.json')).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    preview = Image.new('RGB', (512, 288), '#353c45')
    draw = ImageDraw.Draw(preview)
    draw.text((8, 4), 'ORIGINAL / GUARDED AI DETAIL - FIRST FRAME', fill='white')
    for x, image in ((8, original), (264, result)):
        crop = image.crop((0, 0, width, height)).resize((width * 2, height * 2), Image.Resampling.NEAREST)
        preview.paste(crop, (x, 24), crop)
    preview.save(WORK / (task['key'] + '-comparison.png'))
    print(json.dumps(report))


if sys.argv[1] == 'prepare':
    prepare()
elif sys.argv[1] == 'build':
    for task in json.loads((WORK / 'tasks.json').read_text()):
        if len(sys.argv) == 2 or task['key'] in sys.argv[2:]:
            build(task)
else:
    raise ValueError('Expected prepare or build')
