from resume_p2_menu import ROOT,OUT,read,digest
for label,path,field in [('protected','p5-work/remaining-protected.json','files'),('raw','p5-evidence/remaining/reference-audit.json','scanned_file_sha256')]:
 snapshot=read(OUT/path)[field]
 changed=[p for p,sha in snapshot.items() if digest(ROOT/p)!=sha]
 print(label,changed)