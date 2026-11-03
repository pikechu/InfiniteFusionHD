"""Run an isolated native preview with a deadline and immediate log cleanup."""
from pathlib import Path
import os,re,subprocess,sys,time,json
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
PWSH=Path('D:/Users/meikun.zhang/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe')

def run(script,profile,timeout=240):
 assert re.fullmatch(r'texture-p2-dex-[a-z0-9-]+',profile),profile
 script=(ROOT/script).resolve();assert script.is_relative_to(OUT) and script.suffix=='.rb'
 stage=(ROOT/'temp/multiplayer'/profile).resolve();assert stage.is_relative_to(ROOT/'temp/multiplayer')
 entry=stage/'texture-native-entry.rb'
 process=None;exitcode=None;error=None;removed=[]
 try:
  stage.mkdir(parents=True,exist_ok=True)
  diagnostic=OUT/'p2-evidence/dex'/f'{profile}-entry-error.txt';diagnostic.parent.mkdir(parents=True,exist_ok=True)
  entry.write_text('begin\n load '+json.dumps(script.as_posix(),ensure_ascii=False)+'\nrescue Exception => error\n File.write('+json.dumps(diagnostic.as_posix(),ensure_ascii=False)+', "#{error.class}: #{error.message.to_s[0,1600]}\\n#{(error.backtrace || []).first(8).join("\\n")}")\n exit!(1)\nend\n',encoding='utf-8')
  subprocess.run([str(PWSH),'-NoProfile','-File',str(ROOT/'scripts/multiplayer/prepare-runtime.ps1'),'-Profile',profile,'-CustomScript',str(entry)],cwd=ROOT,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60,creationflags=subprocess.CREATE_NO_WINDOW)
  env=os.environ.copy();env.pop('ANDROID_VERBOSE',None)
  env.update(KIF_MULTIPLAYER_SAVE_DIR=str(stage/'saves'),KIF_MULTIPLAYER_PROFILE=profile,PYTHONDONTWRITEBYTECODE='1')
  process=subprocess.Popen([str(stage/'Game.exe')],cwd=stage,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
  deadline=time.monotonic()+timeout
  while process.poll() is None:
   if time.monotonic()>deadline:raise TimeoutError(f'Native preview exceeded {timeout}s')
   if any(p.stat().st_size>49*1024*1024 for p in stage.rglob('*.log')):raise RuntimeError('Native log reached size cap')
   time.sleep(.2)
  exitcode=process.returncode
  if exitcode:raise RuntimeError(f'Native preview exited {exitcode}; inspect the bounded result in output/texture-hd/p2-evidence/dex/')
 except BaseException as exc:
  error=f'{type(exc).__name__}: {exc}'
  raise
 finally:
  if process and process.poll() is None:
   process.kill();process.wait(timeout=10)
  if stage.exists():
   for p in stage.rglob('*.log'):
    assert p.resolve().is_relative_to(stage)
    p.unlink();removed.append(str(p.relative_to(ROOT)))
   # Reuse immutable runtime links across previews; remove only transient config.
   for p in stage.iterdir():
    if p.is_file() and p.name in ('mkxp.json','texture-native-entry.rb'):
     assert p.resolve().is_relative_to(stage)
     p.unlink()
   time.sleep(.1)
   assert not list(stage.rglob('*.log')),'Temporary logs regenerated'
  result={'profile':profile,'script':str(script.relative_to(ROOT)),'exit_code':exitcode,'error':error,
   'process_exited':process is None or process.poll() is not None,'raw_stdout_stderr':'discarded; no raw log files',
   'removed_temporary_logs':removed,'remaining_temporary_logs':[],'timeout_seconds':timeout,'log_size_cap_bytes':49*1024*1024}
  evidence=OUT/'p2-evidence/dex';evidence.mkdir(parents=True,exist_ok=True)
  (evidence/f'{profile}-cleanup.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
  print(json.dumps(result),flush=True)

if __name__=='__main__':run(Path(sys.argv[1]),sys.argv[2],int(sys.argv[3]) if len(sys.argv)>3 else 240)

