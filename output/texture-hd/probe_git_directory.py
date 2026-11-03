"""Find which bounded, isolated Git index step stalls."""
from pathlib import Path
import json,os,subprocess,tempfile,time,shutil
ROOT=Path(__file__).resolve().parents[2];OUT=Path(__file__).resolve().parent
GIT='D:/Users/meikun.zhang/AppData/Local/Programs/Git/mingw64/bin/git.exe'
report=[];base=json.loads((OUT/'commit-scope.json').read_text(encoding='utf-8'))['base_commit']
runtime=[e['source'] for n in range(1,94) if (p:=OUT/f'batch-{n:03}/manifest.json').exists() for e in json.loads(p.read_text(encoding='utf-8'))['entries']]
probes=[('small_helper',['scripts/graphics/texture_batch.py']),('small_image',['Graphics/Pictures/box16.png']),
 ('large_generated',['output/texture-hd/batch-017/generated/Graphics/Tilesets/Outdoor.png']),('runtime_262',runtime),('record_directory',['output/texture-hd'])]
for name,paths in [probes[-1]]:
 directory=Path(tempfile.mkdtemp(prefix='texture-index-probe-',dir=ROOT/'temp')).resolve();assert directory.is_relative_to(ROOT/'temp')
 trace=directory/'trace.jsonl';listfile=directory/'paths.txt';listfile.write_bytes(b'\0'.join(p.encode('utf-8') for p in paths)+b'\0')
 env=os.environ.copy();env.update(GIT_INDEX_FILE=str(directory/'index'),GIT_LITERAL_PATHSPECS='1',GIT_TERMINAL_PROMPT='0',GIT_OPTIONAL_LOCKS='0')
 command=[GIT,'-c','core.multiPackIndex=false','-c','core.sparseCheckout=false','-c','core.autocrlf=false']
 status='unknown';error='';stdout='';result=None;start=time.monotonic()
 try:
  subprocess.run(command+['read-tree',base],cwd=ROOT,env=env,input=b'',capture_output=True,check=True,timeout=15)
  env['GIT_TRACE2_EVENT']=str(trace)
  try:
   result=subprocess.run(command+['add','--verbose','--sparse','--pathspec-from-file='+str(listfile),'--pathspec-file-nul'],cwd=ROOT,env=env,input=b'',capture_output=True,timeout=25)
   status='completed';stdout=result.stdout.decode('utf-8',errors='replace')[-10000:];error=result.stderr.decode('utf-8',errors='replace')[-5000:]
  except subprocess.TimeoutExpired as exc:
   status='timeout';stdout=(exc.stdout or b'').decode('utf-8',errors='replace')[-10000:];error=(exc.stderr or b'').decode('utf-8',errors='replace')[-5000:]
  tail=[]
  if trace.exists():
   assert trace.stat().st_size<50*1024*1024
   tail=[json.loads(line) for line in trace.read_text(encoding='utf-8').splitlines()[-20:]]
  row={'probe':name,'status':status,'exit_code':result.returncode if result else None,'elapsed_seconds':round(time.monotonic()-start,3),'stderr':error,'stdout_tail':stdout,'trace_tail':tail}
  report.append(row);print(json.dumps({k:v for k,v in row.items() if k!='trace_tail'}),flush=True)
 finally:
  assert directory.is_relative_to(ROOT/'temp');shutil.rmtree(directory);assert not directory.exists()
  (OUT/'git-directory-diagnostics.json').write_text(json.dumps({'results':report,'raw_trace_cleanup':'completed after each probe'},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

