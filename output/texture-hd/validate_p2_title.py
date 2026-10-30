"""Compare every native capture and complete frame/state trace for batch 103."""
from PIL import Image
import numpy as np
from resume_p2_menu import ROOT, OUT, read, write, digest
import gzip,json

E=OUT/'p2-evidence/titles';W=OUT/'p2-title-work'


def main():
    def review(phase):
        path=E/f'{phase}-review.json'
        return read(path) if path.exists() else json.loads(gzip.decompress(path.with_suffix('.json.gz').read_bytes()))
    before=review('before');after=review('candidate')
    for key in ('frame_rate','decoded_images','traces','waits','fusions','legacy_resets','credits_traces','script_sha256','captures'):
        assert before[key]==after[key], 'Native state differs: '+key
    assert before['frame_rate']==40 and before['decoded_images']==20
    for source,h in before['script_sha256'].items():assert digest(ROOT/source)==h,source
    mask=np.asarray(Image.open(W/'accepted-mask.png'))>0
    decisions=[];maximum=0
    for row in before['captures']:
        label=row['label'];a=np.asarray(Image.open(E/f'{label}-before.png').convert('RGBA')).astype(np.int16)
        b=np.asarray(Image.open(E/f'{label}-candidate.png').convert('RGBA')).astype(np.int16)
        allowed=np.zeros((384,512),dtype=bool)
        if row['case'].startswith('gen1-') and 'trace_index' in row:
            state=before['traces'][row['trace_index']];bg=state['layers'].get('bg')
            if bg:
                x,y=map(int,bg['xy']);left=max(0,x);right=min(512,512+x);top=max(0,y);bottom=min(384,384+y)
                if left<right and top<bottom:allowed[top:bottom,left:right]=mask[top-y:bottom-y,left-x:right-x]
        assert np.array_equal(a[~allowed],b[~allowed]), 'Outside nebula mask differs: '+label
        assert np.array_equal(a[:,:,3],b[:,:,3])
        delta=int(np.abs(a-b).max());maximum=max(maximum,delta);assert delta<=14,(label,delta)
        decisions.append({'label':label,'maximum_delta':delta,'changed_pixels':int(np.any(a!=b,axis=2).sum()),
                          'before_sha256':digest(E/f'{label}-before.png'),'candidate_sha256':digest(E/f'{label}-candidate.png')})
    legacy=[]
    for language in (0,2):
        case=f'gen3-{language}'
        loop=[r for r in before['traces'] if r['case']==case and r['phase']=='extended-legacy-loop']
        assert len(loop)==769 and loop[0]['layers']==loop[-1]['layers'],'Incomplete legacy combined loop'
        legacy.append({'case':case,'combined_loop_updates':768,'nominal_seconds':19.2})
        primary=[r for r in before['traces'] if r['case']==f'gen1-{language}']
        assert any(r['layers'].get('selector',{}).get('opacity')==100 for r in primary)
        waits=[r for r in before['waits'] if r['case']==f'gen1-{language}' and r['requested']==150]
        assert len(waits)>=2 and all(not r['skipped'] for r in waits)
    keys={r['key'] for r in before['fusions']};assert len(keys)==2,'Both fusion directions must be exercised'
    for phase in ('before','candidate'):
        cleanup=read(OUT/f'p2-evidence/dex/texture-p2-dex-title-{phase}-20261030-cleanup.json')
        assert cleanup['process_exited'] and not cleanup['remaining_temporary_logs'] and not cleanup['error']
    sheet=Image.new('RGB',(1024,768))
    for i,label in enumerate(('gen1-0-200','gen1-2-200')):
        for j,phase in enumerate(('before','candidate')):
            with Image.open(E/f'{label}-{phase}.png') as im:sheet.paste(im,(512*j,384*i))
    sheet.save(E/'title-native-comparison.png')
    write(E/'native-validation.json',{'status':'passed','decoded_images':20,'native_screen_pairs':len(decisions),
        'native_frame_states_per_phase':len(before['traces']),'frame_order_timing_positions_and_layers_identical':True,
        'unchanged_pixels_outside_candidate_mask':True,'maximum_rendered_channel_delta':maximum,
        'legacy_combined_loops':legacy,'legacy_production_resets':before['legacy_resets'],
        'fusion_events':before['fusions'],'credits_updates_per_language':160,'load_transition_languages':[0,2],
        'timing_scope':'40fps nominal logic-update durations; instrumentation records frame order and waits, not real-time performance. Fixed offline 1/4 sprite pair; Gen3 is a legacy compatibility style, production reset recorded before fixture-only loop extension. Credits cover the first 160 scroll updates and normal skip, not the entire ending.',
        'candidate_decision':'rejected_no_visible_gain','candidate_reason':'Protected projection produces visible local dark cloud patches rather than improved legibility at native size; raw proposal changes fine stars. Keep original title art.',
        'screens':decisions})
    print({'native_pairs':len(decisions),'frame_states':len(before['traces']),'max_delta':maximum,'decision':'preserve_original'})


if __name__=='__main__':main()
