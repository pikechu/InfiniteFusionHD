"""Use one stable material field across each bag's eight pocket states."""
from pathlib import Path
import hashlib
import json
import shutil

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
WORK = OUT / 'p2-work'
audit = json.loads((OUT / 'p2-audit.json').read_text(encoding='utf-8'))['sources']
tasks = json.loads((WORK / 'bag-tasks.json').read_text())
reports = []
jobs = []


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


for gender in ('male', 'female'):
    group = [task for task in tasks if task['gender'] == gender]
    frames, highs = [], []
    for task in group:
        assert digest(ROOT / task['source']) == task['source_sha256']
        with Image.open(ROOT / task['source']) as image:
            frames.append(np.asarray(image.convert('RGBA'), dtype=np.int16))
        job = json.loads((WORK / (task['key'] + '.json')).read_text())
        with Image.open(ROOT / job['generated']) as generated:
            assert abs(generated.width / generated.height - 1) < .025
            gray = generated.convert('L').resize((128,128),Image.Resampling.LANCZOS)
        highs.append(np.asarray(gray,dtype=np.float32)-np.asarray(gray.filter(ImageFilter.GaussianBlur(1)),dtype=np.float32))
        jobs.append(job)
    frames = np.stack(frames)
    assert frames.shape == (8,128,128,4)
    assert all(np.array_equal(frame[:,:,3],frames[0,:,:,3]) for frame in frames)
    rgb = frames[:,:,:,:3]
    edges = np.any(frames[:,:,:,3] < 255,axis=0)
    horizontal = np.any(np.max(np.abs(rgb[:,:,1:]-rgb[:,:,:-1]),axis=3)>20,axis=0)
    vertical = np.any(np.max(np.abs(rgb[:,1:]-rgb[:,:-1]),axis=3)>20,axis=0)
    edges[:,1:] |= horizontal
    edges[:,:-1] |= horizontal
    edges[1:] |= vertical
    edges[:-1] |= vertical
    protected = np.asarray(Image.fromarray(edges.astype(np.uint8)*255).filter(ImageFilter.MaxFilter(3)))>0
    protected |= np.any((rgb < 6) | (rgb > 249),axis=(0,3))
    protected[118:] = True
    delta = np.rint(np.clip(np.median(highs,axis=0)*.8,-6,6)).astype(np.int16)
    delta[protected] = 0
    result = frames.copy()
    result[:,:,:,:3] += delta[None,:,:,None]
    assert result.min()>=0 and result.max()<=255
    assert np.array_equal(result[:,:,:,3],frames[:,:,:,3])
    assert np.array_equal(result[:,protected],frames[:,protected])
    assert np.array_equal(np.diff(result,axis=0),np.diff(frames,axis=0))
    assert np.array_equal(result[-1]-result[0],frames[-1]-frames[0])
    contact = Image.new('RGB',(1024,280),'#303a45')
    draw = ImageDraw.Draw(contact)
    for index, task in enumerate(group):
        row = next(row for row in audit if row['source'] == task['source'])
        aliases = [entry for entry in audit if entry['pixel_sha256'] == row['pixel_sha256'] and entry['size'] == row['size']]
        after = Image.fromarray(result[index].astype(np.uint8))
        for entry in aliases:
            source = ROOT / entry['source']
            assert digest(source) == entry['sha256']
            batch = OUT / entry['batch']
            backup, ready, raw = [batch / folder / entry['source'] for folder in ('originals','ready','generated')]
            for path in (backup,ready,raw):
                path.parent.mkdir(parents=True,exist_ok=True)
            if backup.exists():
                assert digest(backup) == entry['sha256']
            else:
                shutil.copy2(source,backup)
            after.save(ready,optimize=True)
            job = json.loads((WORK / (task['key'] + '.json')).read_text())
            shutil.copy2(ROOT / job['generated'],raw)
            path = batch / 'manifest.json'
            manifest = json.loads(path.read_text()) if path.exists() else {'batch':entry['batch'][6:],'entries':[]}
            record = {'source':entry['source'],'size':entry['size'],'before_sha256':entry['sha256'],
                      'after_sha256':digest(ready),'generated_sha256':digest(raw)}
            manifest['entries'] = [old for old in manifest['entries'] if old['source'] != entry['source']]+[record]
            path.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
        report = {'source':task['source'],'aliases':[entry['source'] for entry in aliases],
                  'size_unchanged':True,'alpha_unchanged':True,'original_strong_edges_unchanged':True,
                  'pocket_state_differences_unchanged':True,'loop_difference_unchanged':True,
                  'changed_pixels':int(np.count_nonzero(np.any(result[index]!=frames[index],axis=2))),
                  'max_rgb_change':int(np.max(np.abs(result[index]-frames[index])))}
        reports.append(report)
        before = Image.fromarray(frames[index].astype(np.uint8))
        contact.paste(before,(index*128,20),before)
        contact.paste(after,(index*128,152),after)
        draw.text((index*128+3,3),f'STATE {index+1}',fill='white')
    contact.save(WORK/f'bag-{gender}-comparison.png')
(WORK/'bag-validation.json').write_text(json.dumps(reports,indent=2)+'\n',encoding='utf-8')
(WORK/'bag-jobs.json').write_text(json.dumps({'method':'built-in image_gen; shared bounded texture across pocket states','entries':jobs},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'state_files':len(reports),'delivery_files':sum(len(row['aliases']) for row in reports),'changed_pixels_per_state':[row['changed_pixels'] for row in reports]}))
