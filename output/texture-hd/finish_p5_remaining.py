"""Checkpoint each reviewed P5 batch against shared native and reference evidence."""
import hashlib
import sys
from collections import Counter
from PIL import Image
from resume_p2_menu import ROOT, OUT, read, write, digest
from update_p2_progress import self_check, update_progress


def preservation_reason(row, references, issue):
    source=row['source'];size=row['size'];stage=row['stage']
    if issue:
        reason='原有兼容问题：'+issue+'。保留原文件名、编码、透明度及源像素；显式大小写加载与默认解析结果分开记录，不把回退到默认图计为该来源的正确绑定。'
    elif source=='Graphics/Pictures/Battle/debug_message.png':
        reason='精灵定位编辑器仍使用此消息底图。已有规则斜线、色带及功能区域清楚；保留像素，实际 SpritePositioner 中英文构建和物种选择显示通过，未编辑或保存物种度量。'
    elif '/playerbase_orig/' in source:
        reason='旧地台完整画布，透明留白和尺寸不同于现用裁切地台。实际合成器的显式覆盖保留底部/中心锚点；未找到该备用目录的普通选择，不将旧画布替换进现用目录。'
    elif '/Battlebacks/unused/' in source:
        reason='旧背景/地台的独立颜色、裂纹、草缘和昼夜渐变版本。实际合成器按背景或敌我地台角色显式显示并核对适用锚点；未在普通解析路径发现 unused 目录选择。保留历史内容，不凭目录名删除或覆盖。'
    elif stage=='source96':
        if size==[96,96]:
            reason='作者署名的 96×96 源精灵，细小轮廓、物种特征和原配色已有清晰像素。真实自定义文件工厂与前后面组件已检查，并逐像素核对原生 3 倍最近邻输出；这是运行时像素缩放，不是 AI 高清化，也不证明作者源目录被默认物种解析选中。保留原始源稿。'
        elif size==[288,288]:
            reason='署名或变体的方形源精灵，保留各自身份、姿态、画风和原配色。真实自定义文件前后面显示、镜像、底部/中心锚点和完整选择/目标周期已检查；显式兼容物种使用固定基线，不虚构该来源的正式物种绑定。'
        else:
            reason='源素材集合中的独立尺寸画稿、部件或图集，不能当作标准 96×96 单帧精灵。保留完整画布、署名、全部图格/部件和透明边界；通用兼容加载及适用的阶段样本另列，不猜测动画帧宽、时钟或物种绑定。'
    elif source.startswith('Graphics/Animated Sprites/'):
        reason='未绑定或非标准几何的 PNG 动态供体条/蛋素材。保留整个编码、画格内容与透明边界；通用加载为兼容位图，空间样本不等于正式动画帧定义或播放时长。'
    elif source.startswith('Graphics/Tilesets/') or (source.startswith('Graphics/Autotiles/') and row['format']=='JPEG'):
        reason='旧图块源图或保留在自动图块目录中的大型 JPEG 图集；实际现用 Tilesets/Autotile 声明未选择本批来源。保留全部原始坐标、纹理与尺寸；高图集阶段样本和全图像素哈希另存，未宣称整个图集的地图拼接/遮挡验收。'
    elif '/oldDataBox/' in source or '_old.' in source or '.old.' in source or '-dev.' in source:
        reason='旧界面/开发标记版本，保留文字、图标、条带、边框和精确切片。未发现普通消费路径选择；本地化映射表中的对应关系不等于界面已使用此旧版本，未改写现用界面。'
    elif '/Misc/' in source:
        reason='署名杂项或素材集合，保留球帧、图标、建筑、粒子、字体/界面及独立创意内容。未发现 Misc 目录的普通消费入口；可见轮廓与原尺寸色块清楚，兼容加载、精确重复及适用的整数缩放关系分开归档，不按相似名称改写或合并。'
    else:
        reason='独立备用、复制或测试版本。保留原画、文字及完整布局；只有明确的路径选择才计为运行引用，短名称/编号命中或本地化登记不等于实际使用。兼容加载不冒称完整交互流程。'
    if row['pixel_matches']:reason+=' 已记录其他文件/历史原图的精确 RGBA 与同尺寸匹配，保留各自用途。'
    if row['nearest_neighbor_3x_matches']:reason+=' 已记录与现有文件逐像素一致的 3 倍最近邻关系，未计为新增高清化。'
    return reason


def main(numbers):
    self_check();assert all(819<=n<=857 for n in numbers)
    scope=read(OUT/'p5-work/remaining-scope.json');sources={r['source']:r for r in scope['entries']}
    raw=read(OUT/'p5-evidence/remaining/reference-audit.json');references={r['source']:r for r in raw['entries']}
    native=read(OUT/'p5-evidence/remaining/reference-native-review.json');media=read(OUT/'p5-evidence/remaining/media-native-review.json')
    assert native['status']==media['status']=='passed' and media['native_source96_3x_verified']==1032
    assert not native['tileset_declarations'] and not native['battle_animation_declarations']
    assert len(media['decoded'])==1754 and len(media['archive_compositions'])==230 and len(media['editor_cases'])==2
    assert not (ROOT/'temp/texture-p5-scale-check').exists()
    reviewed=set(read(OUT/'p5-work/remaining-viewed-pages.json'))
    protected=read(OUT/'p5-work/remaining-protected.json')['files']
    # This parallel proofreading journal is not read by graphics consumers.
    concurrent_journal='Data/localization/zh-CN-dex-proofread-progress.json';concurrent=[]
    for path,sha in protected.items():
        current=digest(ROOT/path)
        if current!=sha:
            assert path==concurrent_journal,('Protected file changed',path)
            concurrent.append({'path':path,'before_sha256':sha,'observed_sha256':current,'scope':'Parallel proofreading bookkeeping preserved; no graphics/runtime image dependency'})
    expected=dict(raw['scanned_file_sha256'])
    strict=set()
    for proof in (native,media):
        for field in ('script_sha256','data_sha256','inputs'):
            for path,sha in proof.get(field,{}).items():
                if path in expected:assert expected[path]==sha,('Audit snapshots disagree',path)
                expected[path]=sha
                strict.add(path)
    for path,sha in expected.items():
        current=digest(ROOT/path)
        if current!=sha:
            assert path==concurrent_journal and path not in strict,('Audit input changed',path)
            concurrent.append({'path':path,'before_sha256':sha,'observed_sha256':current,'scope':'Bookkeeping updated after literal scan; retained source paths, native consumers and runtime image catalogs remain strict'})
    write(OUT/'p5-evidence/remaining/concurrent-file-observations.json',{'files':concurrent,'source_ownership':'No game script, localization file or prior P1-P4 progress file was written by this task.'})
    for source,row in references.items():
        assert all(h['path'].startswith('Data/localization/') or source=='Graphics/Pictures/Battle/debug_message.png'
                   for h in row['hits'] if h['role']=='qualified_path'),('Unreviewed qualified path',source)
    cleanup_paths=[]
    for profile in ('texture-p2-dex-p5-remaining-audit-20261103','texture-p2-dex-p5-remaining-media-final-20261103'):
        path=OUT/'p2-evidence/dex'/f'{profile}-cleanup.json';cleanup=read(path)
        assert cleanup['process_exited'] and not cleanup['error'] and not cleanup['remaining_temporary_logs']
        runtime=ROOT/'temp/multiplayer'/profile
        assert not list(runtime.rglob('*.log')) and not (runtime/'mkxp.json').exists()
        cleanup_paths.append(path.relative_to(ROOT).as_posix())
    issues={r['source']:r['issue'] for r in media['compatibility_issues']}
    plan=read(OUT/'execution-plan/plan.json');index={b['id']:b for b in plan['batch_index']}
    inventory=read(OUT/'inventory.json');audit=read(OUT/'p5-audit.json')
    verified_matches=set()
    for number in numbers:
        name=f'batch-{number}';batch=OUT/name;fixed_path=OUT/f'execution-plan/batches/{name}.json';fixed=read(fixed_path)
        assert fixed['status']=='needs_usage_audit' and all(index[d]['status']=='completed' for d in fixed['depends_on'])
        batch_scope=read(OUT/f'p5-work/{name}-scope.json');assert all(page in reviewed for page in batch_scope['review_pages'])
        entries=[]
        for item in fixed['entries']:
            row=sources[item['source']];source=row['source'];sha=row['sha256']
            assert digest(ROOT/source)==sha==digest(batch/'originals'/source)==native['inputs'][source]==media['inputs'][source]
            with Image.open(ROOT/source) as im:
                rgba=im.convert('RGBA');assert list(im.size)==row['size'] and im.format==row['format']
                assert hashlib.sha256(rgba.tobytes()).hexdigest()==row['rgba_sha256']
                assert hashlib.sha256(rgba.getchannel('A').tobytes()).hexdigest()==row['alpha_sha256']
            for match in row['pixel_matches']+row['nearest_neighbor_3x_matches']:
                path=match.get('archive',match['source'])
                if path not in verified_matches:assert digest(ROOT/path)==match['sha256'],path;verified_matches.add(path)
            reason=preservation_reason(row,references[source],issues.get(source))
            entry={**row,'status':'preserved','reason':reason,'reference_audit':references[source],
                   'native_compatibility_issue':issues.get(source),'validation_scope':media['scope']}
            entries.append(entry);delivery=batch/'delivery'/source;delivery.parent.mkdir(parents=True,exist_ok=True)
            if not delivery.exists():delivery.write_bytes((ROOT/source).read_bytes())
            assert digest(delivery)==sha
        count=len(entries);assert count==fixed['file_count']
        evidence=['output/texture-hd/p5-evidence/remaining/reference-audit.json','output/texture-hd/p5-evidence/remaining/reference-native-review.json',
                  'output/texture-hd/p5-evidence/remaining/media-native-review.json','output/texture-hd/p5-evidence/remaining/collection-phase-review.json']+batch_scope['review_pages']+cleanup_paths
        write(batch/'jobs.json',{'batch':name,'entries':[{'source':r['source'],'decision':'preserved','reason':r['reason'],
              'generation_status':'not_generated_archive_source_or_no_native_size_gain','prompt':None,'generated':None} for r in entries]})
        write(batch/'validation.json',{'batch':name,'status':'completed','applied':0,'preserved':count,'candidate_pending_review':0,
              'dimensions_unchanged':True,'alpha_unchanged':True,'layout_unchanged':True,'entries':entries,'evidence':evidence,
              'limits':'Retained original bytes and specified native/component compatibility only. No full gameplay, default species binding of author sources, arbitrary save override, unbound animation timing or unreferenced atlas seam certification.'})
        result=f'output/texture-hd/{name}/validation.json'
        fixed.update(status='completed',result=result,applied_files=0,preserved_files=count);write(fixed_path,fixed)
        index[name].update(status='completed',result=result,applied_files=0,preserved_files=count)
        done=[b for b in plan['batch_index'] if b['priority']=='P5' and b['status']=='completed'];completed=sum(b['file_count'] for b in done)
        for priority in plan['priorities']:
            if priority['priority']=='P5':priority.update(status='completed' if completed==1850 else 'in_progress',completed_files=completed,applied_files=0,preserved_files=completed,remaining_files=1850-completed)
        for stage in plan['stages']:
            if stage['priority']=='P5':
                ds=[index[b] for b in stage['batch_ids'] if index[b]['status']=='completed'];total=sum(b['file_count'] for b in ds)
                stage.update(status='completed' if len(ds)==len(stage['batch_ids']) else 'in_progress' if ds else 'needs_usage_audit',completed_files=total,applied_files=0,preserved_files=total)
        plan['next_batch']=next((b['id'] for b in plan['batch_index'] if b['status']!='completed'),None);write(OUT/'execution-plan/plan.json',plan)
        selected={r['source']:r for r in entries}
        for row in inventory['assets']:
            if row['path'] in selected:row.update(status='preserved',batch=name,reason=selected[row['path']]['reason'])
        counts=Counter(r['status'] for r in inventory['assets'])
        assert counts['applied']==268 and counts['preserved']==16547+completed and counts['pending']==1850-completed
        inventory.update({status:counts[status] for status in ('applied','preserved','pending')});write(OUT/'inventory.json',inventory)
        assert name not in audit['audited_batches'];audit['audited_batches'].append(name);audit['sources'].extend(entries)
        audit['scope']='Authorized full P5; completed batch records only.';write(OUT/'p5-audit.json',audit)
        progress=update_progress('P5')
        write(OUT/'p5-work/resume.json',{'status':progress['status'],'completed_through':name,'next_batch':progress['next_batch'],
              'candidate_pending_review':[],'ready_pending_application':[],'authorized_scope':'Complete P5 through batch-857'})
        path=OUT/'execution-plan/batch-index.zh-CN.md';lines=path.read_text(encoding='utf-8').splitlines()
        path.write_text('\n'.join(line.replace('先核查用途','已完成').replace('待执行','已完成') if f'batches/{name}.json' in line else line for line in lines)+'\n',encoding='utf-8')
        write(OUT/f'p5-evidence/{name}/checkpoint-verification.json',{'status':'passed','batch':name,'files':count,'applied':0,'preserved':count,
              'pixel_match_sources':sum(bool(r['pixel_matches']) for r in entries),'next_batch':progress['next_batch'],'shared_native_evidence':evidence[:4]})
        print(f"CHECKPOINT {name} preserved={count} P5={completed}/1850 next={progress['next_batch']}",flush=True)


if __name__=='__main__':main([int(n) for n in sys.argv[1:]])
