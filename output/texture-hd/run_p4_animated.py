"""Run the native GIF check, compare all pixels, and immediately remove frame exports."""
import shutil
from pathlib import Path
from PIL import Image, ImageChops
from resume_p2_menu import ROOT, OUT, read, write
from run_p2_native import run

stage = (ROOT / 'temp/texture-p4-gif-check').resolve()
assert stage.is_relative_to((ROOT / 'temp').resolve()) and not stage.exists()
stage.mkdir()
(stage / 'frames').mkdir()
checked = 0
try:
    run(Path('output/texture-hd/native-p4-animated.rb'), 'texture-p2-dex-p4-animated-20261102', 120)
    path = OUT / 'p4-evidence/animated-review.json'
    proof = read(path)
    for record in proof['gifs']:
        with Image.open(ROOT / record['source']) as original:
            for index, name in enumerate(record['native_frames_exported']):
                original.seek(index)
                with Image.open(stage / 'frames' / name) as exported:
                    before, after = original.convert('RGBA'), exported.convert('RGBA')
                    assert before.size == after.size
                    assert before.getchannel('A').tobytes() == after.getchannel('A').tobytes(), (record['source'], index, 'alpha')
                    difference = ImageChops.difference(before.convert('RGB'), after.convert('RGB'))
                    assert not difference.getbbox(), (record['source'], index, 'RGB')
                checked += 1
        record['native_frames_pixel_verified'] = len(record.pop('native_frames_exported'))
    proof['native_gif_frame_pixels_verified'] = checked
    write(path, proof)
finally:
    assert stage.is_relative_to((ROOT / 'temp').resolve())
    shutil.rmtree(stage)
    assert not stage.exists()
    write(OUT / 'p4-evidence/gif-frame-cleanup.json', {'native_gif_frames_verified': checked, 'temporary_frames_remaining': 0})
print({'native_GIF_frames_pixel_verified': checked, 'temporary_frames_remaining': 0})
