"""Scan remaining P5 paths once, preserving the distinction between paths and hints."""
from collections import defaultdict
from pathlib import Path
import re
from resume_p2_menu import ROOT, OUT, read, write, digest


def literal_regex(patterns):
    trie = {}
    for pattern in patterns:
        node = trie
        for value in pattern:node = node.setdefault(value, {})
        node[None] = True
    def expression(node):
        branches = [re.escape(bytes([value])) + expression(child) for value, child in node.items() if value is not None]
        body = branches[0] if len(branches) == 1 else b'(?:' + b'|'.join(branches) + b')' if branches else b''
        return b'(?:' + body + b')?' if None in node and body else body
    return re.compile(expression(trie))


def main():
    probe = literal_regex([b'graphics/misc/a', b'graphics/misc/abc', b'misc/a'])
    assert probe.findall(b'x graphics/misc/abc y misc/a z') == [b'graphics/misc/abc', b'misc/a']
    rows = read(OUT / 'p5-work/remaining-native-index.json')
    mapping = defaultdict(list)
    for row in rows:
        source = row['source'];stem = str(Path(source).with_suffix('')).replace('\\', '/').lower()
        aliases = {stem, stem.removeprefix('graphics/')}
        archive = next((p for p in ('backup', 'playerbase_orig', 'unused', 'oldDataBox', '96x96 sprites + assets', 'Misc') if f'/{p}/' in source), None)
        if archive:aliases.add((archive + '/' + Path(stem).name).lower())
        else:
            name = Path(stem).name
            if len(name) > 3 and not name.isdigit():aliases.add(name)
        for pattern in aliases:
            role = 'qualified_path' if '/' in pattern else 'name_hint'
            mapping[pattern].append({'source': source, 'role': role})
    token_rows = [{'pattern': p, 'targets': mapping[p]} for p in sorted(mapping, key=lambda p: (-len(p), p))]
    write(OUT / 'p5-work/remaining-reference-tokens.json', token_rows)
    regex = literal_regex([r['pattern'].encode('utf-8') for r in token_rows])
    (OUT / 'p5-work/remaining-reference-regex.txt').write_bytes(regex.pattern)
    hits = defaultdict(list);counts = defaultdict(int);hashes = {};directory_mentions = defaultdict(list)
    paths = [p for folder in ('Data', 'Mods', 'scripts') for p in (ROOT / folder).rglob('*') if p.is_file()
             and '__pycache__' not in p.parts and p.suffix.lower() in ('.rb', '.json', '.dat', '.rxdata', '.ini', '.txt', '.ps1', '.py')]
    paths += [ROOT / name for name in ('Game.ini', 'mkxp.json') if (ROOT / name).exists()]
    directories = ['96x96 sprites + assets', 'graphics/misc', 'playerbase_orig', 'battlebacks/unused', 'olddatabox', 'animated sprites']
    for path in sorted(set(paths)):
        raw = path.read_bytes();relative = path.relative_to(ROOT).as_posix();hashes[relative] = digest(path)
        normalized = raw.lower().replace(b'\\', b'/');seen = set()
        kind = 'localization_mapping' if relative.startswith('Data/localization/') and path.suffix=='.json' else 'code_literal' if path.suffix.lower() in ('.rb', '.py', '.ps1', '.ini') else 'data_literal'
        for match in regex.finditer(normalized):
            token = match[0].decode('utf-8')
            for target in mapping[token]:
                key = (target['source'], target['role'])
                if key in seen:continue
                seen.add(key);counts[key] += 1
                if sum(h['role'] == target['role'] for h in hits[target['source']]) < 16:
                    record = {'path': relative, 'kind': kind, 'role': target['role'], 'token': token}
                    if kind=='code_literal':record['line'] = normalized.count(b'\n', 0, match.start()) + 1
                    hits[target['source']].append(record)
        for directory in directories:
            if directory.encode() in normalized:directory_mentions[directory].append(relative)
    entries = [{'source': r['source'], 'qualified_path_files': counts[(r['source'], 'qualified_path')],
                'name_hint_files': counts[(r['source'], 'name_hint')], 'hits': hits[r['source']]} for r in rows]
    report = {'files_scanned': len(hashes), 'scanned_file_sha256': hashes, 'entries': entries,
              'directory_mentions': dict(directory_mentions),
              'scope': 'Literal path and separately labeled filename-hint scan of code/data. Localization catalog mappings and data literals are not assumed to select an asset in ordinary gameplay. Numeric source names are not searched as unrestricted substrings. Raw streams supplement relevant native object/declaration inspection; arbitrary external scripts and existing save overrides are not excluded.'}
    write(OUT / 'p5-evidence/remaining/reference-audit.json', report)
    by_source = {r['source']: r for r in entries}
    for number in range(819, 858):
        name = f'batch-{number}';scope = read(OUT / f'p5-work/{name}-scope.json')
        write(OUT / f'p5-evidence/{name}/reference-audit.json', {'batch': name, 'entries': [by_source[r['source']] for r in scope['entries']],
              'shared_audit': 'output/texture-hd/p5-evidence/remaining/reference-audit.json'})
    print({'files_scanned': len(hashes), 'sources_with_path_hits': sum(bool(r['qualified_path_files']) for r in entries),
           'sources_with_name_hints': sum(bool(r['name_hint_files']) for r in entries), 'directory_mentions': dict(directory_mentions)}, flush=True)


if __name__ == '__main__':main()
