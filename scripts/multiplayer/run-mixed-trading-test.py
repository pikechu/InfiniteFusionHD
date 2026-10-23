"""Complete Windows/Android APK trading with real HTTP and durable crash recovery."""
import argparse,json,os,re,sqlite3,subprocess,sys,threading,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'server/multiplayer'))
from service import Store,Handler,ExclusiveHTTPServer,PROTOCOL

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--serial',default='emulator-5558')
    parser.add_argument('--adb',type=Path,required=True);parser.add_argument('--port',type=int,default=18821)
    parser.add_argument('--timeout',type=int,default=260);args=parser.parse_args()
    adb=[str(args.adb),'-s',args.serial];app='org.kuray.kif';run_id=uuid.uuid4().hex[:10]
    evidence=ROOT/'temp/multiplayer'/('mixed-trading-'+run_id);evidence.mkdir(parents=True)
    markers={};lock=threading.Lock();processes=[];profiles={};backups=[]
    def command(*items,check=True,timeout=30):
        result=subprocess.run(adb+list(items),capture_output=True,timeout=timeout)
        if check and result.returncode:raise RuntimeError((result.stdout+result.stderr).decode(errors='replace')[-1800:])
        return result.stdout.decode('utf-8',errors='replace').strip()
    assert args.serial!='emulator-5554' and command('emu','avd','name').startswith('kif_mixed_'),'Owned test AVD required'
    record=json.loads((ROOT/'temp/artifacts/KIF-0.20.7-android.9-arm64-emulator-network-test-build-record.json').read_text(encoding='utf-8'))
    content=command('shell','run-as',app,'cat','files/active-content')
    assert re.fullmatch('[0-9a-f]{24}',content)
    command('shell','am','force-stop',app)
    apk=command('shell','pm','path',app).removeprefix('package:')
    assert re.fullmatch(r'/data/app/[A-Za-z0-9_./~+=-]+/base\.apk',apk)
    installed=command('shell','sha256sum',apk,timeout=90).split()[0]
    assert installed==record['sha256'] and content==record['payload'],'Fresh APK build mismatch'
    private='/data/user/0/'+app+'/files/diagnostics/trading-'+run_id
    content_path='/data/user/0/'+app+'/files/content/'+content
    command('shell','am','force-stop',app)
    command('shell','run-as',app,'mkdir','-p',private,content_path+'/scripts/multiplayer')
    for name in ('android-game-smoke.rb','mkxp.json'):
        if subprocess.run(adb+['shell','run-as',app,'test','-f',content_path+'/'+name],capture_output=True).returncode==0:
            command('shell','run-as',app,'cp',content_path+'/'+name,private+'/original-'+name);backups.append(name)
    class Fixture(Handler):
        def do_GET(self):
            if not self.path.startswith('/fixture/'):return super().do_GET()
            with lock:raw=json.dumps(dict(ok=True,value=markers.get(self.path[9:]))).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
        def do_POST(self):
            if not self.path.startswith('/fixture/'):return super().do_POST()
            length=int(self.headers.get('Content-Length','0'))
            if not 0<length<=8192:return self.send_error(400)
            value=json.loads(self.rfile.read(length))
            with lock:
                markers[self.path[9:]]=value
                (evidence/'markers.json').write_text(json.dumps(markers,ensure_ascii=False,indent=2),encoding='utf-8')
            raw=b'{"ok":true}';self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
        def log_message(self,*_args):pass
    os.environ['KIF_MAINLINE_GAME_ROOT']=str(ROOT)
    store=Store(evidence/'service.sqlite3',synchronous='FULL')
    for role in ('host','guest'):
        status,person=store.request('POST','/v1/auth/register',dict(username='trading_'+role,password='IsolatedNativeFixture123',protocol=PROTOCOL));assert status==201,person
        with store.lock,store.connect() as db:
            store.trading_grant(db,person['identity']['id'],200000,[0,1,2] if role=='host' else [3,4,5],'mixed_fixture_'+role,{'POTION':10 if role=='host' else 20,'RARECANDY':5})
    server=ExclusiveHTTPServer(('127.0.0.1',args.port),Fixture);server.store=store;server.daemon_threads=True
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    def push(source,target):
        transfer='/data/local/tmp/kif-trading-'+run_id;command('push',str(source),transfer)
        command('shell','run-as',app,'cp',transfer,target)
    def start_windows():
        profile='mixed-trading-host-'+run_id
        result=subprocess.run(['pwsh','-NoProfile','-File',str(ROOT/'scripts/multiplayer/prepare-runtime.ps1'),'-Profile',profile,'-CustomScript','tests/multiplayer/trading_game.rb'],cwd=ROOT,capture_output=True,check=True)
        stage=Path(result.stdout.decode('utf-8-sig').strip().splitlines()[-1]);profiles['host']=stage
        config=evidence/'host.json';config.write_text(json.dumps(dict(directory=str(evidence),cross_device=True)),encoding='utf-8')
        env=dict(os.environ,KIF_MULTIPLAYER_PROFILE=profile,KIF_MULTIPLAYER_SAVE_DIR=str(stage/'saves'),KIF_MULTIPLAYER_SERVER='http://127.0.0.1:'+str(args.port),KIF_MULTIPLAYER_SCENARIO=str(config))
        startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
        with (evidence/'host.stdout.log').open('wb') as out,(evidence/'host.stderr.log').open('wb') as err:
            process=subprocess.Popen([str(stage/'Game.exe')],cwd=stage,env=env,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW,startupinfo=startup)
        processes.append(process);print('MIXED_TRADING_WINDOWS',process.pid,flush=True)
    def start_android():
        command('shell','am','force-stop',app)
        save_dir=private+'/guest';command('shell','run-as',app,'mkdir','-p',save_dir)
        config=evidence/'guest.json';config.write_text(json.dumps(dict(directory='unused-http-coordination',cross_device=True)),encoding='utf-8');push(config,private+'/scenario.json')
        env=dict(KIF_MULTIPLAYER_PROFILE='mixed-trading-guest-'+run_id,KIF_MULTIPLAYER_SAVE_DIR=save_dir,KIF_MULTIPLAYER_SERVER='http://10.0.2.2:'+str(args.port),KIF_MULTIPLAYER_SCENARIO=private+'/scenario.json')
        wrapper=evidence/'android-entry.rb';wrapper.write_text('\n'.join('ENV['+json.dumps(k)+']='+json.dumps(v) for k,v in env.items())+'\nload "kif_android_preload.rb"\nload "scripts/multiplayer/trading_game.rb"\n',encoding='utf-8')
        push(wrapper,content_path+'/android-game-smoke.rb')
        command('shell','am','start','-W','-n',app+'/.LauncherActivity','--ez','gameSmoke','true')
        print('MIXED_TRADING_ANDROID_START',flush=True)
    def wait_for(names):
        deadline=time.monotonic()+args.timeout
        while time.monotonic()<deadline:
            with lock:
                if all(name in markers for name in names):return
            if any(process.poll() not in (None,0) for process in processes):raise RuntimeError('Windows game failed; inspect profile log')
            log=command('exec-out','run-as',app,'cat',private+'/guest/feature-smoke.log',check=False)
            if 'TRADING_NATIVE_FAIL' in log:raise RuntimeError(log[-3000:])
            time.sleep(1)
        raise TimeoutError(names)
    try:
        for name,path in {'test-bootstrap.rb':ROOT/'scripts/multiplayer/test-bootstrap.rb','runtime-preload.rb':ROOT/'scripts/multiplayer/runtime-preload.rb','trading_game.rb':ROOT/'tests/multiplayer/trading_game.rb'}.items():push(path,content_path+'/scripts/multiplayer/'+name)
        start_windows();start_android();wait_for(['guest-restart-required'])
        command('shell','am','force-stop',app);start_android();wait_for(['host-complete','guest-complete'])
        for process in processes:assert process.wait(20)==0
        assert markers['host-render']['map_key']==markers['guest-render']['map_key'],'Real map fingerprints differ'
        with store.lock,store.connect() as db:
            deadline=time.monotonic()+90
            while db.execute("SELECT 1 FROM ml_jobs WHERE status IN ('queued','running')").fetchone() and time.monotonic()<deadline:
                store.tick_mainline_jobs(db);time.sleep(.1)
            assert store.economy_audit(db)['ok']
            counts={table:db.execute('SELECT COUNT(*) FROM '+table).fetchone()[0] for table in ('hosted_assets','market_orders','exchange_sessions','trading_deliveries','asset_locks')}
            assert counts['hosted_assets']==6 and counts['market_orders']==2 and counts['asset_locks']==0,counts
        result=dict(passed=True,scenario='Windows seller + Android emulator buyer, real complete APK, response-loss hard exit/restart, Pokemon/items/mixed barter/nearby/trade cards',apk_sha256=installed,content=content,data_hash=markers['host-complete']['data_hash'],markers=markers,counts=counts,directory=evidence.relative_to(ROOT).as_posix(),scope='Isolated Android 11 x86_64 emulator using ARM64 translation; no physical phone or public network claim')
        (evidence/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        (ROOT/'docs/multiplayer-trading-evidence/android-trading.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        print('MIXED_TRADING_PASS',evidence,flush=True)
    finally:
        for name in ('feature-smoke.log','trading-world.png','runtime.log'):
            raw=subprocess.run(adb+['exec-out','run-as',app,'cat',private+'/guest/'+name],capture_output=True,timeout=20)
            if raw.returncode==0 and raw.stdout:(evidence/('android-'+name)).write_bytes(raw.stdout)
        for role,stage in profiles.items():
            for path in (stage/'saves').glob('*'):
                if path.suffix in ('.log','.png'):(evidence/('windows-'+role+'-'+path.name)).write_bytes(path.read_bytes())
        command('shell','am','force-stop',app,check=False)
        for name in ('android-game-smoke.rb','mkxp.json'):
            if name in backups:command('shell','run-as',app,'cp',private+'/original-'+name,content_path+'/'+name,check=False)
            else:command('shell','run-as',app,'rm','-f',content_path+'/'+name,check=False)
        for process in processes:
            if process.poll() is None:process.terminate();process.wait(10)
        server.shutdown();server.server_close();thread.join(5);store.close()
if __name__=='__main__':main()
