"""Summarize completed texture receipts by priority; candidates never count."""
from pathlib import Path
import json

OUT = Path(__file__).resolve().parent


def summarize(plan, receipts, priority='P2'):
    batches = [row for row in plan['batch_index'] if row['priority'] == priority]
    assert batches, 'Unknown priority: ' + priority
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
    scope = f"{priority} batches {batches[0]['id'].removeprefix('batch-')}-{batches[-1]['id'].removeprefix('batch-')}"
    return {'authorized_scope': scope, 'status': 'completed' if len(done) == len(batches) else 'in_progress',
            'total_files': total, 'completed_batches': [row['id'] for row in done],
            'completed_files': applied + preserved, 'applied_files': applied, 'preserved_files': preserved,
            'remaining_files': total - applied - preserved,
            'next_batch': next((row['id'] for row in batches if row['status'] != 'completed'), None),
            'animation_requirement': 'Preserve frame geometry, order, timing and alpha; validate complete loops before application.'}


def update_progress(priority='P2'):
    plan = json.loads((OUT / 'execution-plan/plan.json').read_text(encoding='utf-8'))
    receipts = {row['id']: json.loads((OUT / row['id'] / 'validation.json').read_text(encoding='utf-8'))
                for row in plan['batch_index'] if row['priority'] == priority and row['status'] == 'completed'}
    progress = summarize(plan, receipts, priority)
    destination = OUT / f'{priority.lower()}-progress.json'
    temporary = destination.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(progress, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(destination)
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
    plan['batch_index'].append({'id':'c','priority':'P3','status':'planned','file_count':3})
    third = summarize(plan, {}, 'P3')
    assert (third['completed_files'],third['remaining_files'],third['next_batch']) == (0,3,'c')
    receipts['b']['entries'][0]['status'] = 'preserved'
    assert summarize(plan,receipts)['completed_files'] == 3


if __name__ == '__main__':
    self_check()
    print(json.dumps(update_progress()))
