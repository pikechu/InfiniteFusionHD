"""Summarize completed P2 receipts; prepared manifests never count as completion."""
from pathlib import Path
import json

OUT = Path(__file__).resolve().parent


def summarize(plan, receipts):
    batches = [row for row in plan['batch_index'] if row['priority'] == 'P2']
    done = [row for row in batches if row['status'] == 'completed']
    applied = preserved = 0
    for row in done:
        receipt = receipts[row['id']]
        assert receipt['status'] == 'completed'
        entries = receipt['entries']
        assert len(entries) == row['file_count'] == len({entry['source'] for entry in entries})
        assert all(entry['status'] in ('applied', 'preserved') for entry in entries)
        a = sum(entry['status'] == 'applied' for entry in entries)
        p = sum(entry['status'] == 'preserved' for entry in entries)
        assert a == receipt['applied'] and p == receipt['preserved']
        applied += a
        preserved += p
    total = sum(row['file_count'] for row in batches)
    return {'authorized_scope': 'P2 batches 058-151', 'status': 'completed' if len(done) == len(batches) else 'in_progress',
            'total_files': total, 'completed_batches': [row['id'] for row in done],
            'completed_files': applied + preserved, 'applied_files': applied, 'preserved_files': preserved,
            'remaining_files': total - applied - preserved,
            'next_batch': next((row['id'] for row in batches if row['status'] != 'completed'), None),
            'animation_requirement': 'Preserve frame geometry, order, timing and alpha; validate complete loops before application.'}


def update_progress():
    plan = json.loads((OUT / 'execution-plan/plan.json').read_text(encoding='utf-8'))
    receipts = {row['id']: json.loads((OUT / row['id'] / 'validation.json').read_text(encoding='utf-8'))
                for row in plan['batch_index'] if row['priority'] == 'P2' and row['status'] == 'completed'}
    progress = summarize(plan, receipts)
    temporary = OUT / 'p2-progress.json.tmp'
    temporary.write_text(json.dumps(progress, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(OUT / 'p2-progress.json')
    return progress


def self_check():
    plan = {'batch_index': [{'id': 'a', 'priority': 'P2', 'status': 'completed', 'file_count': 2},
                            {'id': 'b', 'priority': 'P2', 'status': 'planned', 'file_count': 1}]}
    receipts = {'a': {'status': 'completed', 'applied': 1, 'preserved': 1,
                      'entries': [{'source': 'x', 'status': 'applied'}, {'source': 'y', 'status': 'preserved'}]}}
    first = summarize(plan, receipts)
    assert (first['completed_files'], first['applied_files'], first['preserved_files'], first['remaining_files'], first['next_batch']) == (2,1,1,1,'b')
    plan['batch_index'][1]['status'] = 'completed'
    receipts['b'] = {'status': 'completed', 'applied': 0, 'preserved': 1, 'entries': [{'source': 'z', 'status': 'preserved'}]}
    second = summarize(plan, receipts)
    assert second['completed_files'] == 3 and second['status'] == 'completed'
    receipts['b']['entries'][0]['status'] = 'candidate_pending_review'
    try:
        summarize(plan, receipts)
    except AssertionError:
        pass
    else:
        raise AssertionError('An unreviewed candidate must not count as completed')


if __name__ == '__main__':
    self_check()
    print(json.dumps(update_progress()))
