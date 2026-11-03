"""Resolve P1 map assets against production map records and actual tile cells."""
from collections import defaultdict
from pathlib import Path
import hashlib
import json

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


usage = json.loads((OUT / 'p1-evidence/map-usage.json').read_text())
planned = json.loads((OUT / 'p1-evidence/planned-map-usage.json').read_text())
sources = {row['source']: row for row in json.loads((OUT / 'p1-audit.json').read_text(encoding='utf-8'))['sources']}
actual = defaultdict(set)
assigned = defaultdict(set)
for tileset in usage:
    for map_record in tileset['maps']:
        assigned[('Tilesets', tileset['tileset_name'].casefold())].add(map_record['path'])
        for name in tileset['autotile_names']:
            if name:
                assigned[('Autotiles', name.casefold())].add(map_record['path'])
        for slot in {tile_id // 48 - 1 for tile_id in map_record['used_tile_ids'] if 48 <= tile_id < 384}:
            name = tileset['autotile_names'][slot]
            if name:
                actual[name.casefold()].add(map_record['path'])

rows = []
for item in planned:
    source = ROOT / item['source']
    assert digest(source) == sources[item['source']]['sha256'], source
    category = source.parent.name
    maps = sorted(assigned[(category, source.stem.casefold())])
    visible_maps = sorted(actual[source.stem.casefold()]) if category == 'Autotiles' else maps
    action = 'enhance'
    reason = 'Referenced by production maps; preserve original geometry and validate in engine.'
    if not maps:
        action = 'preserve'
        reason = 'No reference in any of the 809 production maps. Preserve this inactive source; no visible gameplay clarity benefit.'
    elif not visible_maps:
        action = 'preserve'
        reason = 'Assigned to a tileset record, but no production map cell uses its autotile slot. Preserve the unused animation source.'
    with Image.open(source) as image:
        assert list(image.size) == item['size']
        unique = len(image.convert('RGBA').getcolors(image.width * image.height) or [])
        if unique <= 2:
            action = 'preserve'
            reason = 'Functional flat fill with at most two colors; generated texture would change its intended masking/background function.'
    rows.append({**item, 'source_sha256': digest(source), 'assigned_maps': maps,
                 'actual_maps': visible_maps, 'action': action, 'reason': reason})

assert len(rows) == 91
assert len({row['source'] for row in rows}) == 91
assert sum(len(row['maps']) for row in usage) == 809
report = {'map_count': 809, 'tileset_records': len(usage), 'source_count': len(rows),
          'enhance': sum(row['action'] == 'enhance' for row in rows),
          'preserve': sum(row['action'] == 'preserve' for row in rows),
          'reference_evidence': 'output/texture-hd/p1-evidence/map-usage.json',
          'loader_evidence': 'Data/Scripts/004_Game classes/004_Game_Map.rb:94-95; map renderer resolves names from these records; no production script reassigns tileset_name or autotile_names.',
          'map_data_sha256': {path.relative_to(ROOT).as_posix(): digest(path)
                              for path in [ROOT / 'Data/Tilesets.rxdata', *sorted((ROOT / 'Data').glob('Map[0-9]*.rxdata'))]},
          'entries': rows}
(OUT / 'p1-evidence/map-scope-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({key: report[key] for key in ('map_count', 'source_count', 'enhance', 'preserve')}))
