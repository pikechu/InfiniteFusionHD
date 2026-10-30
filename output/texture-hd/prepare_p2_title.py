"""Fit AI nebula detail into protected original geometry, never replace the layout."""
from PIL import Image, ImageFilter
import numpy as np
import shutil
from resume_p2_menu import ROOT, OUT, read, write, digest


def main():
    work = OUT / 'p2-title-work'; batch = OUT / 'batch-103'
    job = read(work / 'job.json'); source = job['source']
    original = Image.open(batch / 'originals' / source).convert('RGBA')
    generated = Image.open(ROOT / job['generated']).convert('RGB').resize(original.size, Image.Resampling.LANCZOS)
    a = np.asarray(original).astype(np.int16)
    luma = generated.convert('L')
    detail = np.asarray(luma.filter(ImageFilter.GaussianBlur(1.2))).astype(float) - np.asarray(luma.filter(ImageFilter.GaussianBlur(7))).astype(float)
    detail = np.clip(np.rint(detail * 1.5), -14, 14).astype(np.int16)
    rgb = a[:,:,:3]; edge = np.zeros(a.shape[:2], dtype=bool)
    edge[1:] |= np.max(np.abs(rgb[1:]-rgb[:-1]),axis=2)>18
    edge[:,1:] |= np.max(np.abs(rgb[:,1:]-rgb[:,:-1]),axis=2)>18
    edge = np.asarray(Image.fromarray(edge.astype('uint8')*255).filter(ImageFilter.MaxFilter(7))) > 0
    y,x=np.indices(edge.shape)
    eligible=(y>44)&(y<276)&(~edge)&(((x-256)**2+(y-174)**2)>52**2)&(rgb.min(axis=2)>14)&(rgb.max(axis=2)<239)
    eligible &= ~((x<100)&(y<60))
    feather = Image.fromarray(eligible.astype('uint8')*255)
    weight = np.asarray(feather.filter(ImageFilter.GaussianBlur(3))).astype(float)/255
    delta=np.rint(detail*weight).astype(np.int16);delta[~eligible]=0
    assert delta.min()>=-14 and delta.max()<=14
    candidate=a.copy();candidate[:,:,:3]+=delta[:,:,None]
    assert candidate.min()>=0 and candidate.max()<=255
    assert np.array_equal(candidate[:,:,3],a[:,:,3])
    assert np.array_equal(candidate[276:],a[276:]) and np.array_equal(candidate[:60,:100],a[:60,:100])
    assert np.array_equal(candidate[edge],a[edge])
    target=batch/'ready'/source;target.parent.mkdir(parents=True,exist_ok=True)
    Image.fromarray(candidate.astype('uint8'),'RGBA').save(target)
    raw=batch/'generated'/source;raw.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/job['generated'],raw)
    mask=Image.fromarray((delta!=0).astype('uint8')*255);mask.save(work/'accepted-mask.png')
    comparison=Image.new('RGBA',(1024,384));comparison.paste(original,(0,0));comparison.paste(Image.fromarray(candidate.astype('uint8')),(512,0));comparison.save(work/'comparison.png')
    entry={'source':source,'size':list(original.size),'before_sha256':digest(batch/'originals'/source),
           'after_sha256':digest(target),'generated_sha256':digest(raw),'status':'candidate_pending_review'}
    write(batch/'manifest.json',{'batch':'103','status':'candidate_pending_review','method':'Built-in image_gen; protected bounded nebula luminance detail','entries':[entry]})
    write(work/'candidate-validation.json',{'status':'structure_passed_pending_native','entries':[entry],
          'changed_pixels':int((delta!=0).sum()),'max_channel_delta':int(np.abs(delta).max()),
          'alpha_identical':True,'grid_text_disc_and_strong_edges_identical':True,
          'geometry':'Original RGB plus one bounded common luminance delta; no resampling of original pixels.'})
    routes=read(work/'native-paths.json');key=str((ROOT/source).with_suffix('')).replace('\\','/').lower()
    routes['candidate'][key]=target.relative_to(ROOT).as_posix();write(work/'native-paths.json',routes)
    print(entry)


if __name__=='__main__':main()
