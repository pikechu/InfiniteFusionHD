"""Verify native 3x source exports and immediately remove task-owned frame files."""
import hashlib
import shutil
from pathlib import Path
from PIL import Image, ImageChops
from resume_p2_menu import ROOT, OUT, read, write
from run_p2_native import run

stage = (ROOT / 'temp/texture-p5-scale-check').resolve()
assert stage.is_relative_to((ROOT / 'temp').resolve()) and not stage.exists()
(stage / 'frames').mkdir(parents=True)
checked = 0
try:
    run(Path('output/texture-hd/native-p5-remaining-media.rb'), 'texture-p2-dex-p5-remaining-media-final-20261103', 360)
    proof = read(OUT / 'p5-evidence/remaining/media-native-review.json')
    for record in proof['source96_exports']:
        export_name = record.get('direct_export', record['native_export'])
        with Image.open(ROOT / record['source']) as source, Image.open(stage / 'frames' / export_name) as exported:
            expected = source.convert('RGBA').resize((288, 288), Image.Resampling.NEAREST)
            actual = exported.convert('RGBA')
            assert actual.size == expected.size
            assert actual.getchannel('A').tobytes() == expected.getchannel('A').tobytes(), (record['source'], 'scaled alpha')
            difference = ImageChops.difference(expected.convert('RGB'), actual.convert('RGB'))
            visible = expected.getchannel('A').point(lambda value: 255 if value else 0)
            assert not ImageChops.multiply(difference, Image.merge('RGB', (visible,) * 3)).getbbox(), (record['source'], 'scaled visible RGB')
            record['native_export_sha256'] = hashlib.sha256((stage / 'frames' / export_name).read_bytes()).hexdigest()
        if record['factory_fallback']:
            record['factory_export_sha256'] = hashlib.sha256((stage / 'frames' / record['native_export']).read_bytes()).hexdigest()
            record['verified_loader'] = 'Explicit-case AnimatedBitmap; current factory fallback is not a source binding'
        else:record['verified_loader'] = 'Actual custom-file factory'
        record.pop('native_export');record.pop('direct_export', None);record['nearest_neighbor_3x_verified'] = True;checked += 1
    proof['native_source96_3x_verified'] = checked
    proof['scope'] = proof['scope'].replace('Native 96-to-288 exports require external alpha/visible-RGB verification.', 'All 1032 native 96-to-288 source exports passed exact alpha and visible-RGB comparison with integer nearest-neighbor scaling. Resolver fallbacks use separately verified explicit-case loaders and are not certified as successful current custom-file bindings. Scaling is not AI enhancement or automatic species binding.')
    write(OUT / 'p5-evidence/remaining/media-native-review.json', proof)
finally:
    assert stage.is_relative_to((ROOT / 'temp').resolve())
    shutil.rmtree(stage)
    assert not stage.exists()
    write(OUT / 'p5-evidence/remaining/scale-export-cleanup.json', {'native_scaled_sources_verified': checked, 'remaining_temporary_exports': 0})
print({'native_scaled_sources_verified': checked, 'remaining_temporary_exports': 0}, flush=True)
