from resume_p2_menu import ROOT,OUT,read,write
from finish_p4_batches import main
proofs=read(OUT/'p4-work/native-proofs.json')
proofs['effects']={'review':'output/texture-hd/p4-evidence/effects-review.json','cleanup':'output/texture-hd/p2-evidence/dex/texture-p2-dex-p4-effects-20261102-cleanup.json'}
write(OUT/'p4-work/native-proofs.json',proofs)
main(list(range(578,617)))