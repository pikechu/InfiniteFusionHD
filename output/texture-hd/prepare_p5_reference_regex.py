from resume_p2_menu import OUT,read
from audit_p5_remaining import literal_regex
rows=read(OUT/'p5-work/remaining-reference-tokens.json')
(OUT/'p5-work/remaining-reference-regex.txt').write_bytes(literal_regex([r['pattern'].encode('utf-8') for r in rows]).pattern)