"""Derive the proven native animation fixture for this batch's two effect sheets."""
from resume_p2_menu import OUT,read,write,digest
source=OUT/'native-p4-effects.rb'
text=source.read_text(encoding='utf-8')
text=text.replace("File.expand_path('output/texture-hd/p4-evidence')","File.expand_path('output/texture-hd/p5-evidence/batch-817')")
old="KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p4-work/native-index.json'),49*1024*1024,3000000).select { |r| r['stage']=='effects' }"
new="KIFMultiplayer::WireJSON.parse(File.binread('output/texture-hd/p5-work/batch-817-scope.json'),49*1024*1024,3000000)['entries'].select { |r| r['source'].start_with?('Graphics/Animations/') }"
assert text.count(old)==1
text=text.replace(old,new).replace('P4_EFFECTS','P5_817_EFFECTS').replace('P4EffectAudio','P5ArchiveEffectAudio')
text=text.replace("if id%120==0 && frame==animation.length/2","if frame==animation.length/2")
text=text.replace('All 925 effect sources directly decode at original dimensions. All animation-data entries referencing P4 main/background/foreground images','Both archive effect sheets decode at original dimensions. All animation-data entries referencing these main/background/foreground images')
(OUT/'native-p5-817-effects.rb').write_text(text,encoding='utf-8')
write(OUT/'p5-evidence/batch-817/effects-fixture-origin.json',{'template':'output/texture-hd/native-p4-effects.rb','template_sha256':digest(source),'derived':'output/texture-hd/native-p5-817-effects.rb','changes':'Only output folder, fixed batch inputs, evidence scope labels and representative screenshot selection; actual PBAnimationPlayerX checks retained.'})