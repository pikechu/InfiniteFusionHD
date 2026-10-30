"""Audit the remaining fixed P2 batches and prepare original-sized review sheets."""
from pathlib import Path
import hashlib, math, shutil
from PIL import Image,ImageDraw
from resume_p2_menu import ROOT,OUT,read,write,digest

W=OUT/'p2-remaining-work';E=OUT/'p2-evidence/remaining'


def main():
    W.mkdir(exist_ok=True);E.mkdir(parents=True,exist_ok=True)
    audit=read(OUT/'p2-audit.json');done={}
    for n in range(58,104):
        receipt=read(OUT/f'batch-{n:03}/validation.json');assert receipt['status']=='completed'
        done.update({e['source']:e for e in receipt['entries']})
    assert len(done)==1005
    for row in audit['sources']:
        entry=done.get(row['source']);expected=entry['after_sha256'] if entry and entry['status']=='applied' else row['sha256']
        assert digest(ROOT/row['source'])==expected,'Concurrent asset change: '+row['source']
    rows=[];sheets=[]
    for n in range(104,152):
        plan=read(OUT/f'execution-plan/batches/batch-{n:03}.json');assert plan['status']=='planned'
        unique={}
        for item in plan['entries']:
            row=next(r for r in audit['sources'] if r['source']==item['source']);source=ROOT/row['source']
            with Image.open(source) as im:
                im.load();a=im.convert('RGBA');assert list(im.size)==row['size']
                alpha=a.getchannel('A');pixel=hashlib.sha256(a.tobytes()).hexdigest()
                meta={**row,'encoded_frames':getattr(im,'n_frames',1),'mode':im.mode,'format':im.format,
                      'alpha_sha256':hashlib.sha256(alpha.tobytes()).hexdigest(),'bounds':alpha.getbbox()}
                if n in range(108,116) and im.size==(320,320):
                    meta['grid']=[4,4];meta['cell_size']=[80,80]
                    meta['cell_alpha_bounds']=[alpha.crop((x*80,y*80,(x+1)*80,(y+1)*80)).getbbox() for y in range(4) for x in range(4)]
                elif row['source'].endswith('_back.png') and '/Trainers/' in row['source']:
                    assert a.width%5==0;meta['grid']=[5,1];meta['cell_size']=[a.width//5,a.height]
                unique.setdefault(pixel,meta)
            backup=OUT/f'batch-{n:03}/originals'/row['source'];backup.parent.mkdir(parents=True,exist_ok=True)
            if not backup.exists():shutil.copy2(source,backup)
            assert digest(backup)==row['sha256'];rows.append(meta)
        review=list(unique.values())
        for start in range(0,len(review),12):
            sheet=Image.new('RGB',(1200,math.ceil(len(review[start:start+12])/4)*284),'#30343c');draw=ImageDraw.Draw(sheet)
            for i,row in enumerate(review[start:start+12]):
                with Image.open(ROOT/row['source']) as im:
                    a=im.convert('RGBA');a.thumbnail((296,256))
                x=i%4*300;y=i//4*284;sheet.paste(a,(x,y+24),a)
                draw.text((x+2,y+3),row['source'].replace('Graphics/','')[-45:],fill='white')
            target=E/f'originals-{n:03}-{start//12+1:02}.png';sheet.save(target);sheets.append(target.relative_to(ROOT).as_posix())
    assert len(rows)==1218 and len({r['source'] for r in rows})==1218
    write(W/'scope.json',{'status':'audited','date':'2026-10-30','all_p2_hashes_checked':2223,'completed_sources_checked':1005,'entries':rows,'review_sheets':sheets})
    write(W/'session-protected.json',{'files':{p.relative_to(ROOT).as_posix():digest(p) for folder in ('Data/Scripts','Mods','Data/localization') for p in (ROOT/folder).rglob('*') if p.is_file()}})
    write(W/'resume.json',{'status':'in_progress','next_batch':'batch-104','candidate_pending_review':[]})
    print({'audited':len(rows),'review_sheets':len(sheets),'encoded_animations':[r['source'] for r in rows if r['encoded_frames']>1]})


if __name__=='__main__':main()
