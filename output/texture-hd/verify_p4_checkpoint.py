"""Verify completed P4 receipts, unchanged pixels/timing and native evidence."""
import hashlib
import json
from collections import Counter
from PIL import Image
from resume_p2_menu import ROOT, OUT, read, write, digest


def main():
    progress = read(OUT / 'p4-progress.json')
    assert progress['status'] == 'completed' and progress['completed_files'] == 5065
    assert progress['remaining_files'] == progress['applied_files'] == 0
    assert progress['preserved_files'] == 5065 and progress['next_batch'] is None
    scope = read(OUT / 'p4-work/scope.json')
    sources = {r['source']: r for r in scope['entries']}
    assert len(sources) == 5065
    pages = {s: p['path'] for p in scope['review_pages'] for s in p['sources']}
    reviewed = set(read(OUT / 'p4-work/visual-review.json')['reviewed_pages'])
    assert all((ROOT / p['path']).name in reviewed for p in scope['review_pages'])
    plan = read(OUT / 'execution-plan/plan.json')
    index = {r['id']: r for r in plan['batch_index']}
    assert plan['next_batch'] == 'batch-817'
    assert all(r['status'] == 'needs_usage_audit' for r in index.values() if r['priority'] == 'P5')
    proof_paths = read(OUT / 'p4-work/native-proofs.json')
    proofs = {}
    for stage, record in proof_paths.items():
        proof = read(ROOT / record['review'])
        assert proof['status'] == 'passed'
        for field in ('script_sha256', 'sidecar_sha256', 'data_sha256'):
            for path, expected in proof.get(field, {}).items():
                assert digest(ROOT / path) == expected, ('Native consumer changed', path)
        cleanup = read(ROOT / record['cleanup'])
        assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
        runtime = ROOT / 'temp/multiplayer' / cleanup['profile']
        assert not list(runtime.rglob('*.log')) and not (runtime / 'mkxp.json').exists()
        proofs[stage] = proof
    balls = read(OUT / 'p4-evidence/balls-review.json')
    assert balls['status'] == 'passed' and len(balls['cases']) == 44
    for path, expected in {**balls['inputs'], **balls['script_sha256']}.items():
        assert digest(ROOT / path) == expected, path
    cleanup = read(OUT / 'p2-evidence/dex/texture-p2-dex-p4-balls-20261103-cleanup.json')
    assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
    animated = proofs['animated']
    assert animated['native_gif_frame_pixels_verified'] == sum(g['native_frames'] for g in animated['gifs']) == 191
    assert all(g['native_frames_pixel_verified'] == g['native_frames'] and g['wraps'] == 2 for g in animated['gifs'])
    assert not (ROOT / 'temp/texture-p4-gif-check').exists()
    phases = read(OUT / 'p4-evidence/animated-phase-review.json')
    assert {r['source'] for r in phases['sources']} == {r['source'] for r in sources.values() if r['stage'] == 'animated'}
    assert all(len(r['sha256_in_order']) == r['count'] for r in phases['sources'])
    verified = set()
    encoded_frames = 0
    for number in range(541, 817):
        name = f'batch-{number:03}'
        fixed = read(OUT / f'execution-plan/batches/{name}.json')
        receipt = read(OUT / f'{name}/validation.json')
        jobs = read(OUT / f'{name}/jobs.json')
        assert fixed['status'] == index[name]['status'] == receipt['status'] == 'completed'
        assert all(index[d]['status'] == 'completed' for d in fixed['depends_on'])
        assert receipt['applied'] == 0 and receipt['preserved'] == len(fixed['entries'])
        assert receipt['candidate_pending_review'] == 0 and len(jobs['entries']) == len(fixed['entries'])
        entries = {r['source']: r for r in receipt['entries']}
        assert set(entries) == {r['source'] for r in fixed['entries']}
        for source, entry in entries.items():
            assert source not in verified
            row = sources[source]
            expected = row['sha256']
            assert entry['status'] == 'preserved' and entry['reason']
            for path in (ROOT / source, OUT / name / 'originals' / source, OUT / name / 'delivery' / source):
                assert digest(path) == expected, path
            assert proofs[row['stage']]['inputs'][source] == expected
            page = pages[row.get('same_pixels_as', source)]
            assert (ROOT / page).name in reviewed and (ROOT / page).exists()
            with Image.open(ROOT / source) as image:
                assert image.format == row['format'] and list(image.size) == row['size']
                assert getattr(image, 'n_frames', 1) == row['encoded_frames']
                assert image.info.get('loop') == row['encoded_loop']
                for frame_index, before in enumerate(row['frames']):
                    image.seek(frame_index)
                    rgba = image.convert('RGBA')
                    assert hashlib.sha256(rgba.tobytes()).hexdigest() == before['rgba_sha256'], source
                    assert hashlib.sha256(rgba.getchannel('A').tobytes()).hexdigest() == before['alpha_sha256'], source
                    assert image.info.get('duration') == before['duration_ms'], source
                    assert getattr(image, 'disposal_method', None) == before['disposal'], source
                    encoded_frames += 1
            verified.add(source)
        if number % 50 == 0:
            print(f'P4_VERIFY batch={number} files={len(verified)}', flush=True)
    assert verified == set(sources)
    audit = read(OUT / 'p4-audit.json')
    assert all(r['review_status'] == 'preserved' and r['accepted_sha256'] == sources[r['source']]['sha256'] for r in audit['sources'])
    inventory = read(OUT / 'inventory.json')
    counts = Counter(r['status'] for r in inventory['assets'])
    assert counts == {'applied': 268, 'preserved': 16547, 'pending': 1850}
    assert all(r['status'] == 'preserved' for r in inventory['assets'] if r['path'] in sources)
    protected = read(OUT / 'p4-work/resumed-protected.json')['files']
    changed = [p for p, expected in protected.items() if digest(ROOT / p) != expected]
    assert not changed, ('Protected files changed since resume', changed)
    result = {'status': 'passed', 'batches': 276, 'files': len(verified), 'applied': 0, 'preserved': 5065,
              'encoded_frames_checked': encoded_frames, 'review_pages': len(scope['review_pages']),
              'native_gif_frames_pixel_verified': 191, 'native_ball_pairs': 44,
              'ordered_animated_units_archived': sum(r['count'] for r in phases['sources']),
              'protected_files_unchanged': len(protected), 'next_global_batch': 'batch-817',
              'limits': 'Preservation decisions and specified native component fixtures; no complete gameplay, Android device, release package or inactive donor binding certification.'}
    write(OUT / 'p4-evidence/checkpoint-verification.json', result)
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
