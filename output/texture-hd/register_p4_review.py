"""Register only pages actually viewed in this resumed P4 session."""
import sys
from resume_p2_menu import OUT,read,write
from finish_p4_batches import main
visual=read(OUT/'p4-work/visual-review.json')
seen=read(OUT/'p4-work/visually-seen-resumed.json')
visual['reviewed_pages']=sorted(set(visual['reviewed_pages']+seen))
visual['notes']['655-686']='Reviewed 2026-11-03: PRAS elemental/status atlases, terrain backgrounds, absorption motes, fists/feet/eyes, shields, leaf/ice/flame cells and glow rings retain their original visual identities, tiny details, alpha ramps and grid gaps. Preserve original matched background/foreground color families and complete frame content; no added texture would improve native-size recognition.'
write(OUT/'p4-work/visual-review.json',visual)
if len(sys.argv)>1:main(list(range(int(sys.argv[1]),int(sys.argv[2])+1)))
