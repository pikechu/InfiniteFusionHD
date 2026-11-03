from resume_p2_menu import OUT,read,write
proofs=read(OUT/'p4-work/native-proofs.json');proofs['weather']={'review':'output/texture-hd/p4-evidence/weather-review.json','cleanup':'output/texture-hd/p2-evidence/dex/texture-p2-dex-p4-weather-final-20261103-cleanup.json'};write(OUT/'p4-work/native-proofs.json',proofs)
p=read(OUT/'p4-evidence/effects-review.json')
p['compatibility_issues']=[{'source':s,'issue':f'Existing animation-data pattern indices {patterns} exceed this image atlas; native players completed with original source bytes. The atlas was not enlarged or rewritten to conceal the existing data mismatch.'} for s,patterns in p['out_of_sheet_patterns'].items()]
p['additional_evidence']=['output/texture-hd/p4-evidence/balls-review.json']
p['scope']+=' Supplementary balls-review.json checks actual named ball trajectory/tumbling and open/closed picture processes; it does not certify a complete capture battle.'
write(OUT/'p4-evidence/effects-review.json',p)
print({'weather_registered':True,'effect_pattern_issues':len(p['compatibility_issues'])})
