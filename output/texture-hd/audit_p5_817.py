"""Bounded source/data reference scan for the fixed archive batch."""
from pathlib import Path
import sys
from resume_p2_menu import ROOT, OUT, read, write, digest


def main(number=817):
    assert 817 <= number <= 824
    name = f'batch-{number:03}'
    scope = read(OUT / f'p5-work/{name}-scope.json')
    rows = scope['entries']
    tokens = {}
    for row in rows:
        source = row['source'];stem = source.removesuffix('.png').lower()
        patterns = {stem, stem.removeprefix('graphics/')}
        archive = next((part for part in ('backup', 'playerbase_orig') if f'/{part}/' in source), None)
        patterns.add(archive + '/' + Path(stem).name if archive else Path(stem).name)
        tokens[source] = {p.encode('utf-8') for p in patterns}
    paths = [p for directory in ('Data', 'Mods', 'scripts') for p in (ROOT / directory).rglob('*')
             if p.is_file() and '__pycache__' not in p.parts and p.suffix.lower() in ('.rb', '.json', '.dat', '.rxdata', '.ini', '.txt', '.ps1', '.py')]
    paths += [ROOT / name for name in ('Game.ini', 'mkxp.json') if (ROOT / name).exists()]
    hashes = {};counts = {r['source']: 0 for r in rows};hits = {r['source']: [] for r in rows}
    backup_mentions = []
    for path in sorted(set(paths)):
        raw = path.read_bytes();relative = path.relative_to(ROOT).as_posix();hashes[relative] = digest(path)
        normalized = raw.lower().replace(b'\\', b'/')
        for source, patterns in tokens.items():
            matched = [p for p in patterns if p in normalized]
            if not matched:continue
            counts[source] += 1
            if len(hits[source]) < 20:
                record = {'path': relative, 'tokens': [p.decode('utf-8') for p in sorted(matched)]}
                if path.suffix.lower() not in ('.dat', '.rxdata'):
                    record['line_numbers'] = [i for i, line in enumerate(normalized.splitlines(), 1) if any(p in line for p in matched)][:20]
                hits[source].append(record)
        if b'battlebg/backup' in normalized or b'backups/' in normalized:
            backup_mentions.append(relative)
    report = {'batch': name, 'source_files_scanned': len(hashes), 'scanned_file_sha256': hashes,
              'entries': [{'source': r['source'], 'matched_file_count': counts[r['source']], 'hits': hits[r['source']]} for r in rows],
              'backup_directory_mentions': backup_mentions,
              'scope': 'Case-insensitive slash-normalized literal scan of repository game scripts, mods, data streams and task-independent source tooling. Complete serialized-string inspection and actual resource declarations are separate native evidence. Generated texture archives, asset shipping indexes and this task output are excluded because listing an asset is not ordinary runtime selection. Absence of literal matches alone does not exclude arbitrary external scripts or custom override paths.'}
    write(OUT / f'p5-evidence/{name}/reference-audit.json', report)
    print({'files_scanned': len(hashes), 'sources_with_hits': {s: n for s, n in counts.items() if n}, 'backup_directory_mentions': backup_mentions})


if __name__ == '__main__':main(int(sys.argv[1]) if len(sys.argv)>1 else 817)
