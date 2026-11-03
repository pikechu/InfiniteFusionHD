"""Reject inconsistent AI walk frames before any game replacement is allowed."""
from PIL import Image
import hashlib
from resume_p2_menu import ROOT,OUT,read,write,digest
W=OUT/'p2-remaining-work';E=OUT/'p2-evidence/remaining'
original=Image.open(ROOT/'Graphics/Characters/player/base/overworld/1/walk_1.png').convert('RGBA')
generated=Image.open(W/'body-walk-generated.png').convert('RGBA')
fitted=generated.resize((320,320),Image.Resampling.LANCZOS)
rows=[];duplicates=[]
for y in range(4):
    cells=[]
    for x in range(4):
        box=(x*80,y*80,(x+1)*80,(y+1)*80);a=original.crop(box);b=fitted.crop(box);cells.append((a,b))
        rows.append({'direction_row':y,'frame':x,'original_alpha_bounds':a.getchannel('A').getbbox(),
                     'generated_alpha_bounds':b.getchannel('A').point(lambda v:255 if v>=128 else 0).getbbox()})
    for x in range(4):
        for z in range(x+1,4):
            if cells[x][0].tobytes()==cells[z][0].tobytes():
                duplicates.append({'row':y,'frames':[x,z],'generated_equal':cells[x][1].tobytes()==cells[z][1].tobytes()})
assert any(r['original_alpha_bounds']!=r['generated_alpha_bounds'] for r in rows)
sheet=Image.new('RGBA',(640,320));sheet.paste(original,(0,0));sheet.paste(fitted,(320,0));sheet.save(E/'walk-pilot-comparison.png')
write(W/'pilot-validation.json',{'status':'rejected_before_application','source':'Graphics/Characters/player/base/overworld/1/walk_1.png',
    'original_sha256':digest(ROOT/'Graphics/Characters/player/base/overworld/1/walk_1.png'),'generated_sha256':digest(W/'body-walk-generated.png'),
    'cells':rows,'identical_original_frame_pairs':duplicates,
    'reason':'AI changes per-frame alpha bounds and foot/head anchors; fixed grid resampling does not restore the original clothing alignment. Original 80x80 cells contain only small flat-shaded base characters, with no useful room for additional detail. Preserve all original action sheets and layering.'})
doc=read(W/'pilot-jobs.json')
for row in doc['entries']:
    if row['key']=='body-walk':row.update(status='rejected_geometry_and_continuity',validation='output/texture-hd/p2-remaining-work/pilot-validation.json')
    if row['key']=='trainer-back':row.update(status='not_generated_legacy_unused',reason='Current pbCreateTrainerBackSprite renders the layered front portrait; the five-cell back strip is retained as a legacy asset. No expected clarity gain from adding fabric noise.')
write(W/'pilot-jobs.json',doc)
print({'pilot':'rejected','changed_cell_bounds':sum(r['original_alpha_bounds']!=r['generated_alpha_bounds'] for r in rows),'duplicate_pairs_checked':len(duplicates)})
