"""Keep original labels and UI geometry while applying reviewed AI material detail."""
from pathlib import Path
import hashlib
import json
import shutil

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
WORK = OUT / 'p2-work'
audit = {row['source']: row for row in json.loads((OUT / 'p2-audit.json').read_text(encoding='utf-8'))['sources']}
translations = json.loads((ROOT / 'Data/localization/zh-CN-images.json').read_text(encoding='utf-8'))['images']
text_edits = json.loads((ROOT / 'Data/localization/zh-CN-image-edits.json').read_text(encoding='utf-8'))
records = []


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


for key in ('cursor_command', 'cursor_command_darkmode', 'cursor_mega'):
    job = json.loads((WORK / (key + '.json')).read_text(encoding='utf-8'))
    sources = [job['source'], translations[job['source']]['path']]
    images = []
    for name in sources:
        assert digest(ROOT / name) == audit[name]['sha256'], name
        with Image.open(ROOT / name) as image:
            images.append(image.convert('RGBA'))
    before = images[0]
    original = np.asarray(before, dtype=np.int16)
    protected = np.zeros(original.shape[:2], dtype=bool)
    for image in images:
        pixels = np.asarray(image, dtype=np.int16)
        rgb = pixels[:, :, :3]
        edge = pixels[:, :, 3] < 255
        horizontal = np.max(np.abs(rgb[:, 1:] - rgb[:, :-1]), axis=2) > 20
        vertical = np.max(np.abs(rgb[1:] - rgb[:-1]), axis=2) > 20
        edge[:, 1:] |= horizontal
        edge[:, :-1] |= horizontal
        edge[1:] |= vertical
        edge[:-1] |= vertical
        protected |= np.asarray(Image.fromarray(edge.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(3))) > 0
        protected |= np.max(rgb, axis=2) > 245
    labels = Image.new('L', before.size)
    draw = ImageDraw.Draw(labels)
    for item in text_edits[job['source']]:
        x, y, w, h = item['rect']
        draw.rectangle((x, y, x + w - 1, y + h - 1), fill=255)
    protected |= np.asarray(labels) > 0
    yy, xx = np.indices(original.shape[:2])
    frame_width = before.width // 2 if key != 'cursor_mega' else before.width
    protected |= (yy % 46 < 2) | (yy % 46 > 43)
    protected |= (xx % frame_width < 2) | (xx % frame_width >= frame_width - 2)
    with Image.open(ROOT / job['generated']) as generated:
        assert abs((generated.width / generated.height) / (before.width / before.height) - 1) < .025
        proposal = generated.convert('RGBA').resize(before.size, Image.Resampling.LANCZOS)
    gray = proposal.convert('L')
    high = np.asarray(gray, dtype=np.float32) - np.asarray(gray.filter(ImageFilter.GaussianBlur(1)), dtype=np.float32)
    delta = np.rint(np.clip(high * .65, -5, 5)).astype(np.int16)
    delta[protected] = 0
    batch = OUT / audit[job['source']]['batch']
    manifest_path = batch / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {'batch': batch.name[6:], 'entries': []}
    results = []
    for name, image in zip(sources, images):
        base = np.asarray(image, dtype=np.int16)
        result = base.copy()
        result[:, :, :3] = np.clip(base[:, :, :3] + delta[:, :, None], 0, 255)
        assert np.array_equal(result[protected], base[protected])
        assert np.array_equal(result[:, :, 3], base[:, :, 3])
        assert np.max(np.abs(result - base)) <= 5
        after = Image.fromarray(result.astype(np.uint8))
        backup, ready, raw = [batch / folder / name for folder in ('originals', 'ready', 'generated')]
        for path in (backup, ready, raw):
            path.parent.mkdir(parents=True, exist_ok=True)
        if backup.exists():
            assert digest(backup) == audit[name]['sha256']
        else:
            shutil.copy2(ROOT / name, backup)
        after.save(ready, optimize=True)
        shutil.copy2(ROOT / job['generated'], raw)
        entry = {'source': name, 'size': list(image.size), 'before_sha256': audit[name]['sha256'],
                 'after_sha256': digest(ready), 'generated_sha256': digest(raw)}
        manifest['entries'] = [e for e in manifest['entries'] if e['source'] != name] + [entry]
        results.append(after)
        records.append({'source': name, 'changed_pixels': int(np.count_nonzero(np.any(result != base, axis=2))),
                        'labels_unchanged': True, 'alpha_unchanged': True, 'geometry_and_state_grid_unchanged': True,
                        'max_rgb_change': int(np.max(np.abs(result - base))), 'frame_cell': [frame_width, 46]})
    original_difference = np.asarray(images[0], dtype=np.int16) - np.asarray(images[1], dtype=np.int16)
    result_difference = np.asarray(results[0], dtype=np.int16) - np.asarray(results[1], dtype=np.int16)
    assert np.array_equal(original_difference, result_difference), 'Language variants diverged'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    contact = Image.new('RGB', (before.width * 4 + 40, before.height + 32), '#303a45')
    draw = ImageDraw.Draw(contact)
    for index, (label, image) in enumerate(zip(('EN ORIGINAL', 'EN RESULT', 'ZH ORIGINAL', 'ZH RESULT'), (images[0], results[0], images[1], results[1]))):
        x = index * (before.width + 10)
        draw.text((x + 3, 3), label, fill='white')
        contact.paste(image, (x, 24), image)
    contact.save(WORK / (key + '-comparison.png'))
(WORK / 'ui-validation.json').write_text(json.dumps(records, indent=2) + '\n', encoding='utf-8')
print(json.dumps(records))
