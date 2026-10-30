"""Commit reviewed texture bytes in one pack without touching shared HEAD/index."""
from pathlib import Path
from collections import deque
import hashlib,json,os,shutil,subprocess,sys,tempfile,threading,time
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
def read(path):return json.loads(path.read_text(encoding='utf-8-sig'))
def write(path,value):path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
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
 report=read(OUT/'commit-scope.json');progress=read(OUT/'p2-progress.json');inventory=read(OUT/'inventory.json')
 last=max(int(name[6:]) for name in progress['completed_batches'])
 existing=git('for-each-ref','--format=%(objectname)',f'refs/heads/{BRANCH}').decode().strip()
 base=existing or report['base_commit']
 assert git('rev-parse',base).decode().strip()==base
 shared_branch=git('branch','--show-current').decode().strip();shared_index=digest(ROOT/'.git/index')
 applied=[e for n in range(1,last+1) if (p:=OUT/f'batch-{n:03}/manifest.json').exists() for e in read(p)['entries']]
 assert len(applied)==inventory['applied']
 for e in applied:assert digest(ROOT/e['source'])==e['after_sha256'],e['source']
 parent_blobs={e.split(b'\t',1)[1].decode('utf-8'):e.split(b'\t',1)[0].split()[2].decode() for e in git('ls-tree','-r','-z',base).split(b'\0') if e}
 parent_time=int(git('show','-s','--format=%ct',base).decode().strip())
 # Previous archive folders are inherited; inspect new stage folders and the saved path journal only.
 prior=json.loads(git('show',base+':output/texture-hd/p2-progress.json').decode('utf-8')) if existing else {'completed_batches':[]}
 first=max([int(n[6:]) for n in prior['completed_batches']]+[0])+1
 candidates={p for p in (OUT/'commit-paths.txt').read_text(encoding='utf-8').splitlines() if p not in parent_blobs}
 roots=[OUT/f'batch-{n:03}' for n in range(first,last+1)]
 roots += [OUT/'p2-region-work',OUT/'p2-evidence/region',OUT/'p2-title-work',OUT/'p2-evidence/titles']
 for folder in roots:
  assert folder.is_relative_to(OUT)
  if folder.exists():candidates.update(p.relative_to(ROOT).as_posix() for p in folder.rglob('*') if p.is_file() and '__pycache__' not in p.parts)
 candidates.update(p.relative_to(ROOT).as_posix() for p in OUT.glob('*region*.py'))
 candidates.update(p.relative_to(ROOT).as_posix() for p in OUT.glob('*region*.rb'))
 candidates.update(p.relative_to(ROOT).as_posix() for p in OUT.glob('*title*.py'))
 candidates.update(p.relative_to(ROOT).as_posix() for p in OUT.glob('*title*.rb'))
 candidates.update(p.relative_to(ROOT).as_posix() for p in (OUT/'p2-evidence/dex').glob('texture-p2-dex-region-*20261029-cleanup.json'))
 candidates.update(p.relative_to(ROOT).as_posix() for p in (OUT/'p2-evidence/dex').glob('texture-p2-dex-title-*20261030-cleanup.json'))
 candidates.update(f'output/texture-hd/execution-plan/batches/batch-{n:03}.json' for n in range(first,last+1))
 core={'README.zh-CN.md','inventory.json','p2-audit.json','p2-progress.json','commit-scope.json','commit-paths.txt','save_texture_branch.py','git-incremental-save-recovery.json',
       'p2-work/resume.json','execution-plan/plan.json','execution-plan/README.zh-CN.md','execution-plan/stage-summary.zh-CN.md','execution-plan/batch-index.zh-CN.md'}
 paths=sorted(candidates|{e['source'] for e in applied}|{'scripts/graphics/texture_batch.py'}|{'output/texture-hd/'+p for p in core})
 allowed={e['source'] for e in applied}
 assert all(p.startswith('output/texture-hd/') or p=='scripts/graphics/texture_batch.py' or p in allowed for p in paths)
 report.update(branch=BRANCH,base_commit=base,total_files=len(paths),record_files=len(paths)-len(applied)-1,paths=paths,
               staging='Incremental Git packed import; reuse existing verified blobs; no shared index.',
               bytes=sum((ROOT/p).stat().st_size for p in paths))
 write(OUT/'commit-scope.json',report);(OUT/'commit-paths.txt').write_text('\n'.join(paths)+'\n',encoding='utf-8')
 author=git('var','GIT_AUTHOR_IDENT').strip();committer=git('var','GIT_COMMITTER_IDENT').strip()
 print(f'VERIFYING_BYTES files={len(paths)}',flush=True)
 hashes=git('hash-object','--no-filters','--stdin-paths',data=('\n'.join(paths)+'\n').encode(),timeout=60).decode().splitlines()
 assert len(hashes)==len(paths)
 expected=dict(zip(paths,hashes))
 changes=[path for path in paths if parent_blobs.get(path)!=expected[path]]
 assert changes and set(changes)<=set(paths)
 ids=sorted({expected[path] for path in changes})
 known=set(parent_blobs.values())
 for line in git('cat-file','--batch-check=%(objectname) %(objecttype)',data=('\n'.join(ids)+'\n').encode()).decode().splitlines():
  oid,kind=line.split()
  if kind=='blob':known.add(oid)
 print(f'INCREMENTAL changed={len(changes)} verified={len(paths)} existing_objects={len(set(ids)&known)}',flush=True)

 message=(f'feat(graphics): checkpoint HD textures through P2 batch {last:03}\n\n'
  f'Save {len(applied)} applied textures with originals, generated proposals, prompts, delivery hashes and native engine evidence.\n'
  f"P2 reviewed {progress['completed_files']}/2223 files ({progress['applied_files']} applied, {progress['preserved_files']} preserved).\n"
  'Only texture-owned paths; preserve concurrent source/localization/build edits.\n').encode('utf-8')
 temporary=Path(tempfile.mkdtemp(prefix='texture-packed-commit-',dir=ROOT/'temp')).resolve()
 assert temporary.is_relative_to(ROOT/'temp')
 process=None;timer=None;reader=None;errors=deque(maxlen=16);start=time.monotonic()
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
  for number,path in enumerate(changes,1):
   full=ROOT/path
   oid=expected[path]
   if oid in known:
    process.stdin.write(modify_header(path).replace(b' inline ',b' '+oid.encode()+b' ',1))
   else:
    content=full.read_bytes();assert blob_id(content)==oid
    process.stdin.write(modify_header(path)+f'data {len(content)}\n'.encode()+content+b'\n')
    known.add(oid);sent+=len(content)
   if number%300==0:print(f'PACKED {number}/{len(changes)} new_bytes={sent} elapsed={time.monotonic()-start:.1f}s',flush=True)
  process.stdin.write(b'\ndone\n');process.stdin.close();process.wait(timeout=300);timer.cancel();reader.join(timeout=5)
  if process.returncode:raise RuntimeError(b''.join(errors).decode('utf-8',errors='replace')[-8000:])
  commit=git('rev-parse',f'refs/heads/{BRANCH}').decode().strip()
  assert (temporary/'marks').read_text().split()[1]==commit
  blobs={entry.split(b'\t',1)[1].decode('utf-8'):entry.split(b'\t',1)[0].split()[2].decode() for entry in git('ls-tree','-r','-z',commit).split(b'\0') if entry}
  fresh=git('hash-object','--no-filters','--stdin-paths',data=('\n'.join(paths)+'\n').encode(),timeout=60).decode().splitlines()
  assert len(fresh)==len(paths)
  for path,h in zip(paths,fresh):assert blobs[path]==h==expected[path],'Committed bytes differ: '+path
  changed={p.decode('utf-8') for p in git('diff-tree','--no-commit-id','-r','--name-only','-z',base,commit).split(b'\0') if p}
  assert changed==set(changes)
  assert changed<=set(paths)
  assert git('rev-parse',commit+'^').decode().strip()==base
  result={'status':'committed','branch':BRANCH,'commit':commit,'base':base,'changed_paths':len(changed),
   'runtime_images':len(applied),'archive_scope':'New paths and modified records verified; older archived records inherited unchanged from the parent commit.','files_byte_verified':len(paths),'shared_worktree_branch_before':shared_branch,
   'shared_worktree_branch_after':git('branch','--show-current').decode().strip(),
   'shared_index_unchanged':digest(ROOT/'.git/index')==shared_index,'shared_index_used':False,
   'elapsed_seconds':round(time.monotonic()-start,2),'pushed':False,'new_bytes_streamed':sent,'method':'Incremental Git packed import; reuse verified existing blob IDs; exact byte and scope verification'}
  write(OUT/'commit-receipt.json',result);print(json.dumps(result),flush=True)
 finally:
  if timer:timer.cancel()
  if process:
   if process.poll() is None:process.kill();process.wait(timeout=10)
   if process.stdin and not process.stdin.closed:
    try:process.stdin.close()
    except OSError:pass
   if reader:reader.join(timeout=5)
   if process.stderr:process.stderr.close()
  assert temporary.is_relative_to(ROOT/'temp');shutil.rmtree(temporary);assert not temporary.exists()

if __name__=='__main__':
 self_check()
 if '--self-check' in sys.argv:print('PACKED_COMMIT_SELF_CHECK_PASS')
 else:main()
