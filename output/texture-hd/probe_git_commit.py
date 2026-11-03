"""Bounded Git commit diagnostics; preserve reports and remove each raw trace immediately."""
from pathlib import Path
import json,os,subprocess,tempfile,time,shutil
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
GIT='D:/Users/meikun.zhang/AppData/Local/Programs/Git/mingw64/bin/git.exe'
REPORT=OUT/'git-commit-diagnostics.json'

def main():
 results=[]
 probes=[('hash_read',['hash-object','--no-filters','scripts/graphics/texture_batch.py']),
         ('hash_write',['hash-object','-w','--no-filters','scripts/graphics/texture_batch.py']),
         ('hash_write_png',['hash-object','-w','--no-filters','Graphics/Pictures/box16.png'])]
 for name,args in probes:
  directory=Path(tempfile.mkdtemp(prefix='texture-git-probe-',dir=ROOT/'temp')).resolve()
  assert directory.is_relative_to(ROOT/'temp')
  trace=directory/'trace.jsonl'
  env=os.environ.copy();env.update(GIT_TERMINAL_PROMPT='0',GIT_TRACE2_EVENT=str(trace),GIT_OPTIONAL_LOCKS='0')
  start=time.monotonic();status='unknown';code=None;stdout='';stderr=''
  try:
   try:
    r=subprocess.run([GIT,'-c','core.multiPackIndex=false',*args],cwd=ROOT,env=env,input=b'',stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=12)
    code=r.returncode;stdout=r.stdout.decode('utf-8',errors='replace')[-4000:];stderr=r.stderr.decode('utf-8',errors='replace')[-6000:];status='completed'
   except subprocess.TimeoutExpired as error:
    status='timeout';stdout=(error.stdout or b'').decode('utf-8',errors='replace')[-4000:];stderr=(error.stderr or b'').decode('utf-8',errors='replace')[-6000:]
   tail=[]
   if trace.exists():
    assert trace.stat().st_size<50*1024*1024
    for line in trace.read_text(encoding='utf-8',errors='replace').splitlines()[-15:]:
     try:tail.append(json.loads(line))
     except json.JSONDecodeError:tail.append(line[:500])
   result={'probe':name,'status':status,'exit_code':code,'elapsed_seconds':round(time.monotonic()-start,3),'stdout':stdout,'stderr':stderr,'trace_tail':tail}
   results.append(result)
   print(json.dumps({k:v for k,v in result.items() if k!='trace_tail'}),flush=True)
  finally:
   assert directory.is_relative_to(ROOT/'temp');shutil.rmtree(directory);assert not directory.exists()
   REPORT.write_text(json.dumps({'results':results,'raw_trace_cleanup':'completed after each probe'},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':main()
