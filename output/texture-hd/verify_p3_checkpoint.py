"""Verify the completed P3 receipts, assets, native evidence and recovery point."""
import gzip
import hashlib
from pathlib import Path

from PIL import Image
from resume_p2_menu import ROOT, OUT, read, write, digest
from update_p2_progress import self_check, summarize


def main():
    self_check()
    plan = read(OUT / 'execution-plan/plan.json')
    batches = [r for r in plan['batch_index'] if r['priority'] == 'P3']
    assert [r['id'] for r in batches] == [f'batch-{n:03}' for n in range(152, 541)]
    assert all(r['status'] == 'completed' for r in batches)
    receipts = {r['id']: read(OUT / r['id'] / 'validation.json') for r in batches}
    progress = summarize(plan, receipts, 'P3')
    assert progress == read(OUT / 'p3-progress.json')
    assert (progress['completed_files'], progress['applied_files'], progress['preserved_files']) == (9181, 1, 9180)
    assert progress['remaining_files'] == 0 and progress['next_batch'] is None
    audit = {r['source']: r for r in read(OUT / 'p3-audit.json')['sources']}
    inventory = read(OUT / 'inventory.json')
    assets = {r['path']: r for r in inventory['assets']}
    scope = read(OUT / 'p3-work/remaining-scope.json')
    metadata = {r['source']: r for r in read(OUT / 'p3-work/batch-152-scope.json')['entries'] + scope['entries']}
    assert len(audit) == len(metadata) == 9181
    seen = set()
    for batch in batches:
        receipt = receipts[batch['id']]
        fixed = read(OUT / 'execution-plan/batches' / (batch['id'] + '.json'))
        assert fixed['status'] == 'completed'
        assert {r['source'] for r in fixed['entries']} == {r['source'] for r in receipt['entries']}
        jobs = {r['source']: r for r in read(OUT / batch['id'] / 'jobs.json')['entries']}
        for row in receipt['entries']:
            source = row['source']
            assert source not in seen
            seen.add(source)
            original_hash = audit[source]['sha256']
            expected = row['after_sha256'] if row['status'] == 'applied' else original_hash
            assert digest(ROOT / source) == expected == audit[source]['accepted_sha256']
            assert digest(OUT / batch['id'] / 'originals' / source) == original_hash
            assert digest(OUT / batch['id'] / 'delivery' / source) == expected
            assert assets[source]['status'] == audit[source]['review_status'] == row['status']
            assert assets[source]['batch'] == batch['id'] and row['reason'] and jobs[source]['reason']
            with Image.open(ROOT / source) as im:
                assert list(im.size) == row['size'] == metadata[source]['size']
                assert getattr(im, 'n_frames', 1) == metadata[source]['encoded_frames']
                pixels = im.convert('RGBA')
                assert hashlib.sha256(pixels.getchannel('A').tobytes()).hexdigest() == metadata[source]['alpha_sha256']
                if 'pixel_sha256' in metadata[source]:
                    assert hashlib.sha256(pixels.tobytes()).hexdigest() == metadata[source]['pixel_sha256']
    assert seen == set(audit)
    reviewed = read(OUT / 'p3-work/visual-review.json')['reviewed_pages']
    assert len(reviewed) == len(set(reviewed)) == len(scope['review_pages']) == 375
    assert set(reviewed) == {Path(p['path']).name for p in scope['review_pages']}
    assert all((ROOT / p['path']).is_file() for p in scope['review_pages'])
    proofs = {}
    native_inputs = {}
    for name in ('characters', 'outfits', 'battle-art', 'ui'):
        proof = read(OUT / f'p3-evidence/remaining/{name}-review.json')
        assert proof['status'] == 'passed'
        assert all(digest(ROOT / p) == sha for p, sha in proof['script_sha256'].items())
        assert all(audit[p]['sha256'] == sha for p, sha in proof['inputs'].items())
        native_inputs.update(proof['inputs'])
        archive = proof['full_trace_archive']
        data = (ROOT / archive['path']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == archive['archive_sha256']
        assert hashlib.sha256(gzip.decompress(data)).hexdigest() == archive['raw_sha256']
        proofs[name] = proof
    first = read(OUT / 'p3-evidence/batch-152/native-review.json')
    assert first['status'] == 'passed'
    assert all(digest(ROOT / p) == sha for p, sha in first['script_sha256'].items())
    archive = read(OUT / 'p3-evidence/batch-152/trace-archive.json')
    data = (ROOT / archive['archive']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == archive['archive_sha256']
    assert hashlib.sha256(gzip.decompress(data)).hexdigest() == archive['raw_sha256']
    native_inputs.update(first['inputs'])
    assert set(native_inputs) == seen
    assert all(audit[p]['sha256'] == sha for p, sha in native_inputs.items())
    repair = read(OUT / 'p3-work/encoding-repair.json')
    assert repair['status'] == 'applied_verified'
    source = repair['entry']['source']
    with Image.open(OUT / repair['batch'] / 'originals' / source) as old, Image.open(ROOT / source) as new:
        assert old.format == 'WEBP' and new.format == 'PNG'
        assert old.convert('RGBA').tobytes() == new.convert('RGBA').tobytes()
        native = Image.open(OUT / 'p3-evidence/remaining/encoding-native-pixels.png')
        try:
            assert native.convert('RGBA').tobytes() == new.convert('RGBA').tobytes()
        finally:
            native.close()
    direct = read(OUT / 'p3-evidence/remaining/encoding-native-review.json')
    assert direct['status'] == 'passed' and not direct['route_override']
    assert direct['sha256'] == digest(ROOT / source) == repair['entry']['after_sha256']
    assert proofs['ui']['candidate_inputs'][source]['sha256'] == direct['sha256']
    movie = proofs['ui']['movie']
    assert movie['finished'] and movie['frames'] == list(range(1, 231))
    assert movie['wait_updates'] == [2] * 230 and movie['graphics_updates'] == 460 and proofs['ui']['movie_skip']
    cleanups = list((OUT / 'p2-evidence/dex').glob('texture-p2-dex-p3-*-cleanup.json'))
    assert len(cleanups) >= 7
    for path in cleanups:
        cleanup = read(path)
        assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
        stage = ROOT / 'temp/multiplayer' / cleanup['profile']
        assert not list(stage.rglob('*.log')) and not (stage / 'mkxp.json').exists()
    protected = read(OUT / 'p3-work/remaining-session-protected.json')['files']
    assert all(digest(ROOT / p) == sha for p, sha in protected.items())
    p2 = {r['id']: read(OUT / r['id'] / 'validation.json') for r in plan['batch_index'] if r['priority'] == 'P2'}
    assert summarize(plan, p2, 'P2') == read(OUT / 'p2-progress.json')
    assert all(r['status'] != 'completed' for r in plan['batch_index'] if r['priority'] in ('P4', 'P5'))
    assert plan['next_batch'] == 'batch-541'
    for status in ('applied', 'preserved', 'pending'):
        assert inventory[status] == sum(r['status'] == status for r in inventory['assets'])
    result = {'date': '2026-11-02', 'status': 'passed', 'batches': 389, 'sources_originals_deliveries_verified': len(seen),
              'applied_encoding_repairs': 1, 'accepted_ai_redraws': 0, 'preserved': 9180, 'review_pages': len(reviewed),
              'dimensions_alpha_frame_layout_unchanged': True, 'native_consumer_hashes_unchanged': True,
              'source_code_and_localization_unchanged': True, 'p2_progress_unchanged': True, 'temporary_logs_remaining': 0,
              'native_trace_archives_verified': True, 'movie_frames': 230, 'compatibility_issues_retained': 34,
              'global': {k: inventory[k] for k in ('total', 'applied', 'preserved', 'pending')}, 'next_planned_batch': 'batch-541',
              'validation_scope': {k: v['scope'] for k, v in proofs.items()},
              'limitations': 'No complete gameplay/map-event regression, exhaustive clothing combinations, Android physical-device or release-package validation. P3 completion includes documented preservation; it is not a claim that every image was redrawn.'}
    write(OUT / 'p3-evidence/remaining/checkpoint-verification.json', result)
    print({k: v for k, v in result.items() if k not in ('validation_scope', 'limitations')})


if __name__ == '__main__':
    main()
