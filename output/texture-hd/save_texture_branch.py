"""Commit reviewed texture bytes in one pack without touching shared HEAD/index."""
from pathlib import Path
from collections import deque
import hashlib,json,os,shutil,subprocess,sys,tempfile,threading,time
from resume_p2_menu import ROOT,OUT,read,write,digest
GIT='D:/Users/meikun.zhang/AppData/Local/Programs/Git/mingw64/bin/git.exe'
BRANCH='codex/texture-hd-p2'


def git(*args,data=b'',timeout=30):
 r=subprocess.run([GIT,'-c','core.multiPackIndex=false',*args],cwd=ROOT,input=data,capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError(r.stderr.decode('utf-8',errors='replace')[-4000:])
 return r.stdout


def modify_header(path):
 assert '\n' not in path and '\r' not in path and not path.startswith('/')
 assert all(part not in ('','..','.') for part in path.split('/'))
 return ('M 100644 inline '+json.dumps(path,ensure_ascii=False)+'\n').encode('utf-8')


def blob_id(content):
 return hashlib.sha1(f'blob {len(content)}\0'.encode()+content).hexdigest()


def self_check():
 assert modify_header('a b/x.png')==b'M 100644 inline "a b/x.png"\n'
 assert blob_id(b'')=='e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'
 try:modify_header('../outside')
 except AssertionError:pass
 else:raise AssertionError('Invalid path accepted')


def main():
 self_check()
 report=read(OUT/'commit-scope.json');base=report['base_commit']
 assert not git('for-each-ref',f'refs/heads/{BRANCH}').strip(),'Feature branch already exists; inspect it first'
 assert git('rev-parse',base).decode().strip()==base
 shared_branch=git('branch','--show-current').decode().strip();shared_index=digest(ROOT/'.git/index')
 applied=[e for n in range(1,94) if (p:=OUT/f'batch-{n:03}/manifest.json').exists() for e in read(p)['entries']]
 assert len(applied)==262
 for e in applied:assert digest(ROOT/e['source'])==e['after_sha256'],e['source']
 paths=sorted({p.relative_to(ROOT).as_posix() for p in OUT.rglob('*') if p.is_file() and '__pycache__' not in p.parts}
              | {e['source'] for e in applied} | {'scripts/graphics/texture_batch.py'})
 allowed={e['source'] for e in applied}
 assert all(p.startswith('output/texture-hd/') or p=='scripts/graphics/texture_batch.py' or p in allowed for p in paths)
 report.update(branch=BRANCH,total_files=len(paths),record_files=len(paths)-263,paths=paths,
               staging='Native Git fast-import, one packed stream; exact byte verification; no shared index.',
               bytes=sum((ROOT/p).stat().st_size for p in paths))
 write(OUT/'commit-scope.json',report);(OUT/'commit-paths.txt').write_text('\n'.join(paths)+'\n',encoding='utf-8')
 author=git('var','GIT_AUTHOR_IDENT').strip();committer=git('var','GIT_COMMITTER_IDENT').strip()
 message=(b'feat(graphics): save validated HD textures through P2 batch 093\n\n'
  b'Save 262 applied textures with originals, generated proposals, prompts, delivery hashes and native engine evidence.\n'
  b'P1 complete; P2 reviewed 783/2223 files (10 applied, 773 preserved).\n'
  b'Only texture-owned paths; keep concurrent source/localization/build edits separate.\n'
  b'Chinese image catalog row deltas: output/texture-hd/batch-060/catalog-changes.json.\n')
 temporary=Path(tempfile.mkdtemp(prefix='texture-packed-commit-',dir=ROOT/'temp')).resolve()
 assert temporary.is_relative_to(ROOT/'temp')
 process=None;timer=None;reader=None;errors=deque(maxlen=16);expected={};start=time.monotonic()
 try:
  env=os.environ.copy();env.update(GIT_TERMINAL_PROMPT='0');env.pop('GIT_INDEX_FILE',None)
  process=subprocess.Popen([GIT,'-c','core.multiPackIndex=false','fast-import','--quiet','--done','--export-marks='+str(temporary/'marks')],cwd=ROOT,env=env,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,creationflags=subprocess.CREATE_NO_WINDOW)
  def collect():
   while chunk:=process.stderr.read(4096):errors.append(chunk)
  reader=threading.Thread(target=collect,daemon=True);reader.start()
  timer=threading.Timer(300,process.kill);timer.start()
  process.stdin.write(f'commit refs/heads/{BRANCH}\nmark :1\n'.encode()+b'author '+author+b'\ncommitter '+committer+b'\n')
  process.stdin.write(f'data {len(message)}\n'.encode()+message+b'\nfrom '+base.encode()+b'\n')
  sent=0
  for number,path in enumerate(paths,1):
   full=ROOT/path;assert full.resolve().is_relative_to(ROOT)
   content=full.read_bytes();expected[path]=blob_id(content)
   process.stdin.write(modify_header(path)+f'data {len(content)}\n'.encode()+content+b'\n')
   sent+=len(content)
   if number%300==0:print(f'PACKED {number}/{len(paths)} bytes={sent} elapsed={time.monotonic()-start:.1f}s',flush=True)
  process.stdin.write(b'\ndone\n');process.stdin.close();process.wait(timeout=300);timer.cancel();reader.join(timeout=5)
  if process.returncode:raise RuntimeError(b''.join(errors).decode('utf-8',errors='replace')[-8000:])
  commit=git('rev-parse',f'refs/heads/{BRANCH}').decode().strip()
  assert (temporary/'marks').read_text().split()[1]==commit
  blobs={entry.split(b'\t',1)[1].decode('utf-8'):entry.split(b'\t',1)[0].split()[2].decode() for entry in git('ls-tree','-r','-z',commit).split(b'\0') if entry}
  for path,h in expected.items():assert blobs[path]==h==blob_id((ROOT/path).read_bytes()),'Committed bytes differ: '+path
  changed={p.decode('utf-8') for p in git('diff-tree','--no-commit-id','-r','--name-only','-z',base,commit).split(b'\0') if p}
  assert changed<=set(paths) and allowed<=changed
  assert git('rev-parse',commit+'^').decode().strip()==base
  result={'status':'committed','branch':BRANCH,'commit':commit,'base':base,'changed_paths':len(changed),
   'runtime_images':262,'files_byte_verified':len(paths),'shared_worktree_branch_before':shared_branch,
   'shared_worktree_branch_after':git('branch','--show-current').decode().strip(),
   'shared_index_unchanged':digest(ROOT/'.git/index')==shared_index,'shared_index_used':False,
   'elapsed_seconds':round(time.monotonic()-start,2),'pushed':False,'method':'Git native packed import; exact byte and path-scope verification'}
  write(OUT/'commit-receipt.json',result);print(json.dumps(result),flush=True)
 finally:
  if timer:timer.cancel()
  if process:
   if process.poll() is None:process.kill();process.wait(timeout=10)
   if process.stdin and not process.stdin.closed:process.stdin.close()
   if reader:reader.join(timeout=5)
   if process.stderr:process.stderr.close()
  assert temporary.is_relative_to(ROOT/'temp');shutil.rmtree(temporary);assert not temporary.exists()

if __name__=='__main__':
 self_check()
 if '--self-check' in sys.argv:print('PACKED_COMMIT_SELF_CHECK_PASS')
 else:main()
