"""Run isolated emulator QA with private ADB, bounded output and unconditional cleanup."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,socket,subprocess,tarfile,time,uuid
ROOT=Path(__file__).resolve().parents[2]
QA=ROOT/'temp/android15-emulator-validation'
OUT=ROOT/'docs/gameplay-evidence/2026-10-28-android15-emulator'
SDK=ROOT/'temp/tools/android-sdk'
APP='org.kuray.kif';PORT=5057;SERIAL='emulator-5588'
ENV=dict(os.environ,ANDROID_HOME=str(SDK),ANDROID_SDK_ROOT=str(SDK),ANDROID_USER_HOME=str(QA/'android-home'),ANDROID_EMULATOR_HOME=str(QA/'android-home'),ANDROID_AVD_HOME=str(QA/'avd-home'),ANDROID_ADB_SERVER_PORT=str(PORT),ADB_SERVER_PORT=str(PORT),TMP=str(QA/'tmp'),TEMP=str(QA/'tmp'))
for key in ['ANDROID_VERBOSE','ADB_TRACE']:ENV.pop(key,None)
ENV['ANDROID_LOG_TAGS']='*:s'
HIDDEN=getattr(subprocess,'CREATE_NO_WINDOW',0)
def command(items,timeout=30,check=True,binary=False):
    r=subprocess.run([str(x) for x in items],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=ENV,timeout=timeout,creationflags=HIDDEN)
    if len(r.stdout)+len(r.stderr)>8*1024*1024:raise RuntimeError('Command output exceeded8MiB')
    if check and r.returncode:raise RuntimeError((r.stderr+r.stdout)[-4000:].decode('utf-8',errors='replace'))
    return r.stdout if binary else r.stdout.decode('utf-8',errors='replace').strip()
def adb(*args,**kwargs):return command([SDK/'platform-tools/adb.exe','-P',PORT,'-s',SERIAL,*args],**kwargs)
def app(*args,**kwargs):return adb('shell','run-as',APP,*args,**kwargs)
def write(path,value):path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes((json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode())
def free(port):
    with socket.socket() as s:s.settimeout(.2);return s.connect_ex(('127.0.0.1',port))!=0
WRAPPER=r'''qa = __PRIVATE__
$qa_stage=qa+"/stage.txt"
File.write($qa_stage,"before-preload")
ENV["KIF_SAVE_DIR"]=qa+"/saves"
ENV["KIF_MULTIPLAYER_SAVE_DIR"]=qa+"/saves"
ENV["KIF_MULTIPLAYER_PROFILE"]="android15-__PHASE__"
ENV["KIF_QA_SUPPORT"]=qa+"/support"
ENV["KIF_TEST_SOURCE_ROOT"]=["map14","legacy-write"].include?("__PHASE__") ? qa+"/support/baseline" : Dir.pwd
Dir.mkdir(qa+"/saves") unless File.directory?(qa+"/saves")
load "kif_android_preload.rb"
$qa_result=qa+"/result.json"
$qa_log=qa+"/saves/feature-smoke.log"
File.write($qa_stage,"before-json")
File.write($qa_result,HTTPLite::JSON.stringify({"started"=>true}))
File.write($qa_stage,"ruby-started")
module Kernel
  alias_method :qa_real_exit!, :exit!
  def exit!(status=false)
    log=File.file?($qa_log) ? File.read($qa_log) : ""
    rss=File.read("/proc/self/status")[/^VmRSS:\s+(\d+)/,1].to_i
    File.write($qa_result,HTTPLite::JSON.stringify({"complete"=>true,"passed"=>status==0,"phase"=>"__PHASE__","ruby"=>RUBY_VERSION,"rss_kib"=>rss,"events"=>log.byteslice(-65536,65536)||log}))
    qa_real_exit!(status)
  end
end
begin
__BODY__
rescue Exception => error
  File.write($qa_result,HTTPLite::JSON.stringify({"complete"=>true,"passed"=>false,"error"=>"#{error.class}: #{error.message}","backtrace"=>error.backtrace.first(12),"events"=>(File.file?($qa_log) ? File.read($qa_log).lines.last(20).map { |line| line[0,1000] }.join : "")}))
  qa_real_exit!(1)
end
'''
def make_support(folder):
    for name in ['scripts/multiplayer/runtime-preload.rb','scripts/multiplayer/test-bootstrap.rb','tests/localization/game_smoke.rb','tests/localization/quest_dialogue_game.rb','tests/localization/custom_dex_game.rb','tests/gameplay/map_transfer_game.rb','tests/localization/android_map_transfer_game.rb','tests/localization/android_legacy_write.rb','tests/localization/android_legacy_read.rb','tests/localization/android_scenarios.rb']:
        text=(ROOT/name).read_text(encoding='utf-8')
        text=text.replace('load "scripts/multiplayer/test-bootstrap.rb"','load File.join(ENV.fetch("KIF_QA_SUPPORT"),"scripts/multiplayer/test-bootstrap.rb")')
        text=text.replace('load "tests/localization/quest_dialogue_game.rb"','load File.join(ENV.fetch("KIF_QA_SUPPORT"),"tests/localization/quest_dialogue_game.rb")')
        if name.endswith('test-bootstrap.rb'):
            text=text.replace('load File.join(source_root, "scripts/multiplayer/runtime-preload.rb")','load File.join(ENV.fetch("KIF_QA_SUPPORT"),"scripts/multiplayer/runtime-preload.rb")')
            text=text.replace('    file.puts("#{Time.now.utc} #{message}")','    raise "QA log bound" if message.bytesize>65536 || file.size+message.bytesize>4*1024*1024\n    file.puts("#{Time.now.utc} #{message}")')
        target=folder/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(text.encode())
def main():
    p=argparse.ArgumentParser();p.add_argument('phase',choices=['original','runtime','ui','dex','map','map14','legacy-write','legacy-read','scenarios']);p.add_argument('--timeout',type=int,default=1200);a=p.parse_args()
    uid=datetime.datetime.now().strftime('%H%M%S')+'-'+uuid.uuid4().hex[:6];stage=OUT/(a.phase+'-'+uid);work=QA/('work-'+uid)
    stage.mkdir(parents=True);work.mkdir(parents=True);(QA/'tmp').mkdir(exist_ok=True)
    result={'phase':a.phase,'normal_avds_unchanged':True,'physical_phone':False};process=None;originals={};private=None;content=None;backup=None
    apk=ROOT/('temp/artifacts/InfiniteFusionHD-0.20.8-android.15-arm64-'+('network-test.apk' if a.phase=='original' else 'emulator-network-test.apk'))
    try:
        if not free(PORT) or not free(5588):raise RuntimeError('Private QA ports are occupied')
        command([SDK/'platform-tools/adb.exe','-P',PORT,'start-server'])
        process=subprocess.Popen([str(SDK/'emulator/emulator.exe'),'-avd','kif_zh15','-port','5588','-no-window','-no-audio','-no-snapshot','-no-boot-anim','-no-metrics','-gpu','swiftshader_indirect','-debug','-all','-logcat','*:s'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=ENV,creationflags=HIDDEN)
        write(QA/'active-run.json',{'pid':process.pid,'phase':a.phase,'serial':SERIAL,'avd':'kif_zh15','started':time.time()})
        deadline=time.monotonic()+240
        while time.monotonic()<deadline:
            if adb('shell','getprop','sys.boot_completed',check=False)=='1':break
            if process.poll() is not None:raise RuntimeError('Emulator exited during boot')
            time.sleep(2)
        else:raise TimeoutError('Emulator boot exceeded240s')
        assert adb('emu','avd','name').splitlines()[0]=='kif_zh15'
        result['device']={key:adb('shell','getprop',key) for key in ['ro.product.cpu.abilist','ro.build.version.release','ro.build.version.sdk','ro.dalvik.vm.native.bridge']}
        result['storage']=adb('shell','df','-Pk','/data');print('EMULATOR_BOOTED '+json.dumps(result['device']),flush=True)
        with apk.open('rb') as source:apk_sha=hashlib.file_digest(source,'sha256').hexdigest()
        installed=adb('shell','pm','path',APP,check=False)
        installed_path=next((line[8:] for line in installed.splitlines() if line.startswith('package:') and line.endswith('/base.apk')),None)
        old_sha=app('sha256sum',installed_path,check=False,timeout=90).split()[0] if installed_path else None
        result['apk_sha256']=apk_sha
        result['exact_installed_apk_reused']=old_sha==apk_sha
        if old_sha!=apk_sha:adb('install','-r',str(apk),timeout=240)

        prefs=work/'analytics.xml';prefs.write_bytes(b'<?xml version="1.0" encoding="utf-8"?><map><boolean name="usage_enabled" value="false"/></map>')
        adb('push',str(prefs),'/data/local/tmp/kif-qa-analytics.xml');app('mkdir','-p','shared_prefs');app('cp','/data/local/tmp/kif-qa-analytics.xml','shared_prefs/kif-analytics.xml');adb('shell','rm','-f','/data/local/tmp/kif-qa-analytics.xml')
        adb('shell','am','start','-W','-n',APP+'/.LauncherActivity','--ez','manageSaves','true',timeout=40)
        deadline=time.monotonic()+900
        while time.monotonic()<deadline:
            content=app('cat','files/active-content',check=False)
            if re.fullmatch('[0-9a-f]{24}',content):break
            time.sleep(2)
        else:raise TimeoutError('Content installation timeout')
        if a.phase=='legacy-read':
            control=adb('exec-out','run-as',APP,'cat','files/diagnostics/android15-fixtures/expected.json',binary=True)
            (stage/'legacy-expected.json').write_bytes(control)
            result['legacy_control']={'bytes':len(control),'head_hex':control[:80].hex()}
            json.loads(control)
        result['content_id']=content;content='/data/user/0/'+APP+'/files/content/'+content
        private='/data/user/0/'+APP+'/files/diagnostics/android15-'+a.phase+'-'+uid;backup=private+'/backup'
        adb('shell','am','force-stop',APP);app('mkdir','-p',backup,private+'/support',private+'/saves')
        for name in ['android-game-smoke.rb','mkxp.json']:
            text=app('sha256sum',content+'/'+name,check=False);digest=text.split()[0] if re.match('[0-9a-f]{64}',text) else None;originals[name]=digest
            if digest:app('cp',content+'/'+name,backup+'/'+name)
        source=work/'support';make_support(source);archive=work/'support.tar'
        result['test_source_sha256']={path.relative_to(source).as_posix():hashlib.sha256(path.read_bytes()).hexdigest() for path in source.rglob('*') if path.is_file()}
        with tarfile.open(archive,'w') as tar:
            for path in source.rglob('*'):
                if path.is_file():tar.add(path,arcname=path.relative_to(source).as_posix(),recursive=False)
        if a.phase in ['map14','legacy-write']:
            with tarfile.open(archive,'a') as target,tarfile.open(QA/'android14-source.tar') as baseline:
                for entry in baseline:
                    assert entry.isfile() and entry.name.startswith('baseline/Data/Scripts/') and '..' not in Path(entry.name).parts
                    target.addfile(entry,baseline.extractfile(entry))
        transfer='/data/local/tmp/kif-qa-'+uid+'.tar';adb('push',str(archive),transfer);app('tar','-xf',transfer,'-C',private+'/support');adb('shell','rm','-f',transfer)
        if a.phase in ['original','runtime']:body='Graphics.resize_screen(512,384)\nFile.write($qa_stage,"sprite-new")\nsprite=Sprite.new\nFile.write($qa_stage,"sprite-x")\nsprite.x=1\nFile.write($qa_stage,"sprite-y")\nsprite.y=1\nFile.write($qa_stage,"render-120")\n120.times { Graphics.update; Input.update }\nsprite.dispose\nexit!(0)'
        else:body='load File.join(ENV.fetch("KIF_QA_SUPPORT"),'+json.dumps({'ui':'tests/localization/game_smoke.rb','dex':'tests/localization/custom_dex_game.rb','map':'tests/localization/android_map_transfer_game.rb','map14':'tests/localization/android_map_transfer_game.rb','legacy-write':'tests/localization/android_legacy_write.rb','legacy-read':'tests/localization/android_legacy_read.rb','scenarios':'tests/localization/android_scenarios.rb'}[a.phase])+')'
        script=WRAPPER.replace('__PRIVATE__',json.dumps(private)).replace('__PHASE__',a.phase).replace('__BODY__',body)
        (work/'probe.rb').write_bytes(script.encode());result['probe_sha256']=hashlib.sha256(script.encode()).hexdigest();transfer='/data/local/tmp/kif-qa-'+uid+'.rb';adb('push',str(work/'probe.rb'),transfer);app('cp',transfer,content+'/android-game-smoke.rb');adb('shell','rm','-f',transfer)
        adb('logcat','-c');started=time.monotonic();adb('shell','am','start','-W','-n',APP+'/.LauncherActivity','--ez','gameSmoke','true',timeout=40)
        deadline=time.monotonic()+a.timeout;notice=0
        while time.monotonic()<deadline:
            text=adb('exec-out','run-as',APP,'cat',private+'/result.json',check=False);native=json.loads(text) if text.startswith('{') else {}
            if native.get('complete'):result['native']=native;result['passed']=native.get('passed');break
            if not adb('shell','pidof',APP+':game',check=False) and time.monotonic()-started>15:
                logs=adb('logcat','-d','-t','1000','-v','brief','*:W');lines=[line for line in logs.splitlines() if re.search('SIGILL|signal 4|libmkxp|Fatal signal|org.kuray.kif|native bridge',line,re.I)]
                result['native_failure_tail']=lines[-35:];result['passed']=False;result['expected_translator_limitation']=a.phase=='original' and any('signal 4' in line.lower() or 'sigill' in line.lower() for line in lines);break
            if time.monotonic()-notice>30:print('QA_RUNNING '+a.phase+' seconds='+str(round(time.monotonic()-started)),flush=True);notice=time.monotonic()
            time.sleep(2)
        else:raise TimeoutError('Android test timeout')
        result['elapsed_ms']=(time.monotonic()-started)*1000
        result['last_stage']=app('cat',private+'/stage.txt',check=False)
        for name in app('find',private,'-type','f',check=False).splitlines():
            if name.endswith(('.png','-result.json')):(stage/Path(name).name).write_bytes(adb('exec-out','run-as',APP,'cat',name,binary=True))
    except Exception as e:result['passed']=False;result['error']=str(e)[-4000:]
    finally:
        try:
            adb('shell','am','force-stop',APP,check=False)
            if backup:
                for name,digest in originals.items():
                    if digest:app('cp',backup+'/'+name,content+'/'+name);assert app('sha256sum',content+'/'+name).split()[0]==digest
                    else:app('rm','-f',content+'/'+name,check=False)
                result['installed_probe_files_restored']=True
            if private:
                for name in app('find',private,'-type','f',check=False).splitlines():
                    if name.endswith(('.log','.png')):app('rm','-f',name,check=False)
            adb('shell','sync',timeout=45,check=False)
            adb('emu','kill',check=False)
        except Exception as e:result['cleanup_note']=str(e)[-1000:]
        if process:
            try:process.wait(timeout=30)
            except subprocess.TimeoutExpired:command(['taskkill','/PID',process.pid,'/T','/F'],check=False);process.wait(timeout=20)
        try:command([SDK/'platform-tools/adb.exe','-P',PORT,'kill-server'],check=False)
        except Exception as e:result['adb_cleanup_note']=str(e)[-1000:]
        logs=[]
        for path in (QA/'tmp').rglob('*.log'):
            assert path.resolve().is_relative_to(QA.resolve());logs.append({'name':path.name,'bytes':path.stat().st_size});path.unlink()
        result['cleanup']={'emulator_exited':not process or process.poll() is not None,'console_port_free':free(5588),'adb_port_free':free(PORT),'temporary_logs_removed':logs,'stdout_stderr':'discarded; not redirected to files'}
        for path in sorted(work.rglob('*'),key=lambda x:len(x.parts),reverse=True):
            assert path.resolve().is_relative_to(QA.resolve())
            if path.is_file():path.unlink()
            elif path.is_dir():path.rmdir()
        work.rmdir();write(stage/'result.json',result);print(json.dumps({'phase':a.phase,'passed':result.get('passed'),'error':result.get('error') or result.get('native',{}).get('error'),'elapsed_ms':result.get('elapsed_ms'),'last_stage':result.get('last_stage'),'evidence':str(stage),'cleanup':result['cleanup']},ensure_ascii=False),flush=True)
    return 0 if result.get('passed') or result.get('expected_translator_limitation') else 1
if __name__=='__main__':raise SystemExit(main())