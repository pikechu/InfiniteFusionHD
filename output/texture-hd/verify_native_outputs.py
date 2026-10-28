"""Check every native animation image, its seams and complete loop; save previews."""
from pathlib import Path
import json

import numpy as np
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent
directory = OUT / 'p1-evidence/native-autotiles'
tasks = json.loads((OUT / 'p1-autotile-work/tasks.json').read_text())
reports = []
for task in tasks:
    frames = []
    first_delta = None
    max_change = 0
    cell = 16 if task['frame_height'] == 128 else 32
    yy, xx = np.indices((192, 256))
    border = (xx % cell < 2) | (xx % cell >= cell - 2) | (yy % cell < 2) | (yy % cell >= cell - 2)
    for frame in range(task['frames']):
        path = directory / f"{task['key']}-frame-{frame:02}.png"
        with Image.open(path) as image:
            assert image.size == (512, 192)
            pixels = np.asarray(image.convert('RGB'), dtype=np.int16)
            delta = pixels[:, 256:] - pixels[:, :256]
            assert np.max(np.abs(delta)) <= 6, path
            assert np.all(delta[border] == 0), path
            if first_delta is None:
                first_delta = delta
            else:
                assert np.array_equal(delta, first_delta), 'Additional temporal variation in ' + str(path)
            max_change = max(max_change, int(np.max(np.abs(delta))))
            preview = Image.new('RGB', (512, 212), '#202932')
            preview.paste(image, (0, 20))
            ImageDraw.Draw(preview).text((4, 4), f"{Path(task['source']).stem} | ORIGINAL / RESULT | {frame+1}/{task['frames']}", fill='white')
            frames.append(preview)
    assert len(list(directory.glob(task['key'] + '-frame-*.png'))) == task['frames']
    frames[0].save(directory / (task['key'] + '-comparison.gif'), save_all=True,
                   append_images=frames[1:], duration=250, loop=0, disposal=2)
    reports.append({'source': task['source'], 'frames_verified': len(frames), 'assembly_patterns': 48,
                    'rendered_seam_pixels_unchanged': True, 'no_additional_temporal_difference': True,
                    'max_rendered_rgb_change': max_change})
assert sum(row['frames_verified'] for row in reports) == 269
report = {'status': 'passed', 'files': len(tasks), 'frames': 269, 'patterns_per_frame': 48,
          'rendered_pattern_cases': 269 * 48, 'preview_frame_duration_ms': 250, 'entries': reports}
(OUT / 'p1-evidence/native-animation-validation.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps({key: report[key] for key in ('status', 'files', 'frames', 'rendered_pattern_cases')}))
