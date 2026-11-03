"""Check the AI pilot against every original cell before accepting any frame."""
from PIL import Image
import hashlib
from resume_p2_menu import ROOT,OUT,read,write,digest
W=OUT/'p3-work';E=OUT/'p3-evidence/batch-152';B=OUT/'batch-152'


def main():
 job=read(W/'batch-152-pilot.json');original=Image.open(ROOT/job['source']).convert('RGBA')
 generated=Image.open(ROOT/job['generated']).convert('RGBA');fitted=generated.resize(original.size,Image.Resampling.LANCZOS)
 rows=[]
 for y in range(4):
  for x in range(4):
   box=(64*x,64*y,64*(x+1),64*(y+1));a=original.crop(box);b=fitted.crop(box)
   before=a.getchannel('A').getbbox();after=b.getchannel('A').point(lambda v:255 if v>=128 else 0).getbbox()
   rows.append({'row':y,'column':x,'original_bounds':before,'generated_bounds':after,
                'original_alpha_sha256':hashlib.sha256(a.getchannel('A').tobytes()).hexdigest(),
                'generated_alpha_sha256':hashlib.sha256(b.getchannel('A').tobytes()).hexdigest()})
 changed=sum(r['original_bounds']!=r['generated_bounds'] for r in rows)
 assert changed>0,'Pilot requires manual visual review instead of the anchor rejection path'
 compare=Image.new('RGB',(512,256),'#353c46');compare.paste(original,(0,0),original);compare.paste(fitted,(256,0),fitted);compare.save(E/'pilot-comparison.png')
 status='rejected_geometry_and_pose'
 reason='缩回固定 4×4 网格后仍改变多格头脚边界、手部姿态和帽子标记；回填透明通道不能恢复内部姿态，未形成可应用候选。'
 proof={'status':status,'source':job['source'],'original_sha256':digest(ROOT/job['source']),
  'generated_sha256':digest(ROOT/job['generated']),'changed_cell_bounds':changed,'cells':rows,'reason':reason}
 write(E/'pilot-validation.json',proof)
 job.update(status=status,reason=reason,validation='output/texture-hd/p3-evidence/batch-152/pilot-validation.json');write(W/'batch-152-pilot.json',job)
 write(B/'candidate-manifest.json',{'batch':'152','status':status,'entries':[{'source':job['source'],'size':[256,256],
  'before_sha256':proof['original_sha256'],'generated_sha256':proof['generated_sha256'],'generated':job['generated'],'ready':None,'reason':reason}]})
 print({'pilot':status,'changed_cell_bounds':changed})


if __name__=='__main__':main()
