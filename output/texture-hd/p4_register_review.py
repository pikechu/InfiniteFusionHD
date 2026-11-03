from resume_p2_menu import ROOT,OUT,read,write
from PIL import Image
from finish_p4_batches import main
visual=read(OUT/'p4-work/visual-review.json')
visual['reviewed_pages']=sorted(set(visual['reviewed_pages']+["review-617-01.png","review-618-01.png","review-619-01.png","review-620-01.png","review-621-01.png","review-622-01.png","review-623-01.png","review-624-01.png","review-625-01.png","review-626-01.png","review-627-01.png","review-628-01.png","review-629-01.png","review-630-01.png","review-631-01.png","review-632-01.png","review-633-01.png","review-634-01.png","review-635-01.png","review-636-01.png","review-637-01.png","review-638-01.png","review-639-01.png","review-640-01.png","review-641-01.png","review-642-01.png","review-643-01.png","review-644-01.png","review-645-01.png","review-646-01.png","review-647-01.png","review-648-01.png","review-649-01.png","review-650-01.png","review-651-01.png","review-652-01.png","review-653-01.png","review-654-01.png"]))
visual['notes']['631-654']='Reviewed 2026-11-03: graded background bands, feet/fist silhouettes, tiny motes, multi-row flame and ice sequences, status marks and generation-eight effect atlases retain distinct identity, per-cell spacing, original edges and gradual opacity. Preserve these rendering styles and functional sprites without per-frame texture drift.'
write(OUT/'p4-work/visual-review.json',visual)
proof=read(OUT/'p4-evidence/animated-review.json')
assert proof['native_gif_frame_pixels_verified']==191
proof['compatibility_issues']=[]
for g in proof['gifs']:
 with Image.open(ROOT/g['source']) as im:
  delays=[]
  for frame in range(im.n_frames):
   im.seek(frame);delays.append(im.info.get('duration',0))
  g['source_frame_durations_ms']=delays;g['source_loop']=im.info.get('loop')
  g['source_timing_matches_native']=all(abs(d-1000/g['native_frame_rate'])<1 for d in delays)
  if not g['source_timing_matches_native']:
   proof['compatibility_issues'].append({'source':g['source'],'issue':f"Source frame delays {delays} ms differ from native Bitmap constant {g['native_frame_rate']} fps. Existing file is retained byte-for-byte; two observed native cycles do not prove source timing is honored."})
proof['pixel_comparison']='Exact alpha and exact RGB wherever source alpha is nonzero; hidden RGB at alpha zero is not rendered.'
proof['scope']=proof['scope'].replace('exported native frames require external pixel verification before checkpointing.','All 191 exported frames passed exact alpha and visible-RGB verification. Original variable delays are separately compared with native constant frame rates; inherited timing mismatches are not certified as matching.')
write(OUT/'p4-evidence/animated-review.json',proof)
proofs=read(OUT/'p4-work/native-proofs.json');proofs['animated']={'review':'output/texture-hd/p4-evidence/animated-review.json','cleanup':'output/texture-hd/p2-evidence/dex/texture-p2-dex-p4-animated-final-20261103-cleanup.json'};write(OUT/'p4-work/native-proofs.json',proofs)
print({'gif_frames_verified':191,'timing_issues':proof['compatibility_issues']})
main(list(range(617,655)))
