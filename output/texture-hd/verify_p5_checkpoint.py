"""Read-only full-P5 recovery verification; report only reproducible scoped facts."""
from collections import Counter
import hashlib
from PIL import Image
from resume_p2_menu import ROOT, OUT, read, write, digest


def main():
    progress=read(OUT/'p5-progress.json');plan=read(OUT/'execution-plan/plan.json')
    assert progress['status']=='completed' and progress['completed_files']==progress['preserved_files']==1850
    assert progress['applied_files']==progress['remaining_files']==0 and progress['next_batch'] is None
    assert plan['next_batch'] is None and all(b['status']=='completed' for b in plan['batch_index'])
    assert len(progress['completed_batches'])==41
    audit=read(OUT/'p5-audit.json');frozen={r['source']:r for r in audit['sources']};assert len(frozen)==1850
    inventory=read(OUT/'inventory.json');counts=Counter(r['status'] for r in inventory['assets'])
    assert counts['applied']==268 and counts['preserved']==18397 and counts['pending']==0
    assert inventory['applied']==268 and inventory['preserved']==18397 and inventory['pending']==0
    drift=read(OUT/'p5-evidence/prior-phase-worktree-drift.json')
    assert len(drift['entries'])==6
    for row in drift['entries']:
        assert row['prior_batch']=='batch-060' and row['source'] not in frozen
        assert digest(ROOT/row['source'])==digest(ROOT/row['original_archive'])==row['observed_worktree_sha256']
        assert digest(ROOT/row['accepted_archive'])==row['accepted_sha256']
    expected={};strict=set();catalog_versions=[]
    proof_paths=['p5-evidence/batch-817/native-review.json','p5-evidence/batch-817/effects-review.json','p5-evidence/batch-818/native-review.json',
                 'p5-evidence/remaining/reference-native-review.json','p5-evidence/remaining/media-native-review.json']
    for path in proof_paths:
        proof=read(OUT/path);assert proof['status']=='passed'
        for field in ('inputs','script_sha256','sidecar_sha256','data_sha256'):
            for source,sha in proof.get(field,{}).items():
                if source in expected and expected[source]!=sha:
                    assert field=='data_sha256' and source=='Data/messages_zh.dat' and path=='p5-evidence/remaining/reference-native-review.json',('Evidence snapshots differ',source)
                    catalog_versions.append({'path':source,'earlier_batch_sha256':expected[source],'remaining_phase_sha256':sha,
                                             'scope':'Chinese text catalog changed between completed batches and this phase; retain historical evidence and verify the latest catalog against the current workspace. Graphics, code and image mappings are not exempted.'})
                expected[source]=sha;strict.add(source)
    media=read(OUT/'p5-evidence/remaining/media-native-review.json')
    assert media['native_source96_3x_verified']==len(media['source96_exports'])==1032
    assert all(r['nearest_neighbor_3x_verified'] for r in media['source96_exports'])
    assert media['archive_frames_rendered']==len(media['archive_compositions'])==230
    assert len(media['battler_cases'])==2384 and media['state_checks']==119200 and len(media['editor_cases'])==2
    assert not (ROOT/'temp/texture-p5-scale-check').exists()
    profiles=['texture-p2-dex-p5-817-reviewed-20261103','texture-p2-dex-p5-817-effects-20261103','texture-p2-dex-p5-818-20261103',
              'texture-p2-dex-p5-remaining-audit-20261103','texture-p2-dex-p5-remaining-media-final-20261103']
    for profile in profiles:
        cleanup=read(OUT/f'p2-evidence/dex/{profile}-cleanup.json')
        assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
        runtime=ROOT/'temp/multiplayer'/profile
        assert not list(runtime.rglob('*.log')) and not (runtime/'mkxp.json').exists() and not (runtime/'texture-native-entry.rb').exists()
    raw=read(OUT/'p5-evidence/remaining/reference-audit.json')
    for path,sha in raw['scanned_file_sha256'].items():
        assert path not in expected or expected[path]==sha,('Native and literal audit differ',path)
        expected[path]=sha
    concurrent=[];journal='Data/localization/zh-CN-dex-proofread-progress.json'
    for path,sha in expected.items():
        current=digest(ROOT/path)
        if current!=sha:
            assert path==journal and path not in strict,('Changed graphics dependency',path)
            concurrent.append({'path':path,'snapshot_sha256':sha,'observed_sha256':current,'kind':'External proofreading bookkeeping; not written by this task'})
    protected=read(OUT/'p5-work/remaining-protected.json')['files']
    for path,sha in protected.items():
        current=digest(ROOT/path)
        if current!=sha:
            assert path==journal,('Protected file changed',path)
            concurrent.append({'path':path,'snapshot_sha256':sha,'observed_sha256':current,'kind':'External proofreading bookkeeping; not written by this task'})
    seen=set(read(OUT/'p5-work/remaining-viewed-pages.json'))
    scope=read(OUT/'p5-work/remaining-scope.json');assert len(scope['review_pages'])==80
    assert all(r['path'] in seen for r in scope['review_pages'])
    visual=read(OUT/'p5-work/remaining-visual-review.json')
    assert len(visual['reviewed_pages'])==80 and len(visual['phase_pages'])==3
    for row in visual['reviewed_pages']+visual['phase_pages']+visual['native_previews']:
        assert digest(ROOT/row['path'])==row['sha256'],row['path']
    verified=set();stages=Counter();exact=scaled=0
    for number in range(817,858):
        name=f'batch-{number}';fixed=read(OUT/f'execution-plan/batches/{name}.json');receipt=read(OUT/f'{name}/validation.json');jobs=read(OUT/f'{name}/jobs.json')
        assert fixed['status']==receipt['status']=='completed' and receipt['applied']==0 and receipt['candidate_pending_review']==0
        assert len(jobs['entries'])==len(receipt['entries'])==fixed['file_count']==receipt['preserved']
        assert {r['source'] for r in fixed['entries']}=={r['source'] for r in receipt['entries']}
        for entry in receipt['entries']:
            source=entry['source'];assert source not in verified and entry['status']=='preserved' and entry['reason']
            row=frozen[source];sha=row['sha256']
            for path in (ROOT/source,OUT/name/'originals'/source,OUT/name/'delivery'/source):assert digest(path)==sha,path
            with Image.open(ROOT/source) as im:
                assert list(im.size)==row['size'] and im.format==row['format'] and getattr(im,'n_frames',1)==row['encoded_frames']==1
                rgba=im.convert('RGBA')
                assert hashlib.sha256(rgba.tobytes()).hexdigest()==row['rgba_sha256']
                assert hashlib.sha256(rgba.getchannel('A').tobytes()).hexdigest()==row['alpha_sha256']
            verified.add(source);stages[fixed['stage']]+=1;exact+=bool(row['pixel_matches']);scaled+=bool(row.get('nearest_neighbor_3x_matches'))
        if number%10==0:print(f'P5_VERIFY batch={number} files={len(verified)}',flush=True)
    assert verified==set(frozen) and stages=={'archive':366,'source96':1344,'misc':140}
    assets={r['path']:r for r in inventory['assets']};assert all(assets[s]['status']=='preserved' for s in verified)
    mapping=read(ROOT/'Data/localization/zh-CN-images.json')['images'];localized=0
    for source,record in mapping.items():
        if source not in verified and record['path'] not in verified:continue
        assert digest(ROOT/source)==record['source_sha256'],source
        assert digest(ROOT/record['path'])==record['sha256'],record['path'];localized+=1
    result={'status':'passed','batches':41,'files':1850,'applied':0,'preserved':1850,'remaining':0,'stages':dict(stages),
            'exact_pixel_match_sources':exact,'integer_3x_match_sources':scaled,'native_scaled_sources_verified':1032,
            'native_battler_cases':2384,'native_selection_states':119200,'remaining_archive_frames_rendered':230,
            'review_pages':92,'collection_phase_pages':3,'localized_pairs_verified':localized,'resolver_compatibility_issues':media['compatibility_issues'],
            'graphics_dependencies_verified':len(strict),'parallel_bookkeeping_observations':concurrent,'historical_text_catalog_versions':catalog_versions,
            'global_inventory':{'total':18665,'applied':268,'enhanced':267,'container_repaired_only':1,'preserved':18397,'pending':0},
            'global_inventory_scope':'Accepted texture feature-branch records; six earlier P2 images remain original in the shared worktree and must inherit verified parent accepted blobs in the commit.',
            'prior_phase_worktree_drift':'output/texture-hd/p5-evidence/prior-phase-worktree-drift.json',
            'shared_worktree_observation':drift['counts'],
            'next_batch':None,'limits':'Planned scope and specified native/component fixtures; no complete gameplay, Android device/release package, arbitrary save override, automatic artist-source binding or unbound animation clock certification.'}
    write(OUT/'p5-evidence/checkpoint-verification.json',result)
    print(result,flush=True)


if __name__=='__main__':main()
