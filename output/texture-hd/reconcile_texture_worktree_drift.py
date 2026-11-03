"""Preserve concurrent P2 originals while anchoring P5 comparisons to saved archives."""
from datetime import datetime, timezone
from resume_p2_menu import ROOT, OUT, read, write, digest


def main():
    drift=[]
    for number in range(1,858):
        path=OUT/f'batch-{number:03}/manifest.json'
        if not path.exists():continue
        for entry in read(path)['entries']:
            current=digest(ROOT/entry['source'])
            if current==entry['after_sha256']:continue
            assert number==60 and current==entry['before_sha256'],('Unreviewed runtime difference',entry['source'])
            original=OUT/f'batch-{number:03}/originals'/entry['source'];assert digest(original)==current
            accepted=next((OUT/f'batch-{number:03}'/folder/entry['source'] for folder in ('ready','delivery')
                           if (OUT/f'batch-{number:03}'/folder/entry['source']).exists() and digest(OUT/f'batch-{number:03}'/folder/entry['source'])==entry['after_sha256']),None)
            assert accepted is not None,entry['source']
            drift.append({'source':entry['source'],'prior_batch':f'batch-{number:03}','observed_worktree_sha256':current,
                          'accepted_sha256':entry['after_sha256'],'original_archive':original.relative_to(ROOT).as_posix(),
                          'accepted_archive':accepted.relative_to(ROOT).as_posix(),'matches_original':True})
    assert len(drift)==6
    by_source={r['source']:r for r in drift};changed=0
    def convert(value):
        nonlocal changed
        if isinstance(value,list):
            for item in value:convert(item)
        elif isinstance(value,dict):
            for key,item in value.items():
                if key in ('pixel_matches','nearest_neighbor_3x_matches'):
                    for match in item:
                        record=by_source.get(match['source'])
                        if record and match.get('kind') in ('current_file','current_asset') and match['sha256']==record['observed_worktree_sha256']:
                            match.update(kind='historical_original',archive=record['original_archive'],
                                         provenance='Shared-worktree original observed during P5; compare the saved original independently of inherited feature-branch runtime images.')
                            match.pop('status',None);changed+=1
                else:convert(item)
    paths=[OUT/'p5-audit.json',OUT/'p5-work/remaining-scope.json']
    paths += list((OUT/'p5-work').glob('batch-*-scope.json'))
    paths += [OUT/f'batch-{number}/validation.json' for number in range(817,858)]
    for path in paths:
        value=read(path);before=changed;convert(value)
        if changed!=before:write(path,value)
    observation={'accepted_enhancements':267,'accepted_container_repairs':1,'accepted_preserved':18397,
                 'observed_worktree_enhancements_matching_acceptance':261,'observed_worktree_container_repairs':1,
                 'observed_worktree_originals':18403,'prior_phase_images_different_from_acceptance':6}
    report={'status':'recorded','observed_at':datetime.now(timezone.utc).isoformat(),'entries':drift,
            'policy':'Keep current worktree files untouched. The feature commit must inherit its parent accepted image blobs after verifying them against the saved accepted archives.',
            'comparison_references_anchored_to_archived_originals':changed,'counts':observation}
    write(OUT/'p5-evidence/prior-phase-worktree-drift.json',report)
    inventory=read(OUT/'inventory.json');inventory.update(status_scope='Accepted texture feature-branch records; current P5 bytes verified',shared_worktree_observation=observation)
    write(OUT/'inventory.json',inventory)
    plan=read(OUT/'execution-plan/plan.json');plan['execution_inventory_sha256']=digest(OUT/'inventory.json')
    plan['execution_summary']['scope']='Accepted texture feature-branch records; six prior P2 worktree originals are preserved separately'
    write(OUT/'execution-plan/plan.json',plan)
    path=OUT/'README.zh-CN.md';text=path.read_text(encoding='utf-8')
    text=text.replace('**既定 18,665 张计划已全部结项：267 张高清化并应用、1 张仅修复图片编码、18,397 张保留，待处理 0 张。**',
                      '**既定 18,665 张计划已全部结项；特性分支保存的验收记录为：267 张高清化应用、1 张仅修复图片编码、18,397 张保留，待处理 0 张。**')
    marker='P5 提交前的工作区差异'
    if marker not in text:
        paragraph='\n**P5 提交前的工作区差异：** 第 60 批的 6 张已验收图片当前为原图，P5 没有覆盖它们。特性分支继承并核对已有验收版本，P5 比较关系改以正式原图档案为锚点。观察时共享工作区有 261 张匹配验收的高清化图片、1 张编码修复、18,403 张原图；这与分支验收统计分开，见[差异记录](p5-evidence/prior-phase-worktree-drift.json)。\n'
        at=text.index('\n## P5 第 818 批历史保存点');text=text[:at]+paragraph+text[at:]
    path.write_text(text,encoding='utf-8')
    print({'prior_phase_worktree_originals_preserved':len(drift),'comparison_references_anchored':changed},flush=True)


if __name__=='__main__':main()
