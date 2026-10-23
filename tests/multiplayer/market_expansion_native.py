"""Two real Windows clients, authoritative native mechanics and isolated HTTP."""
from pathlib import Path
import argparse,json,os,re,secrets,subprocess,sys,threading,time,urllib.request,urllib.error
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from service import Store,Handler,ExclusiveHTTPServer,PROTOCOL
parser=argparse.ArgumentParser();parser.add_argument('--adb',type=Path);parser.add_argument('--serial',default='emulator-5558');args=parser.parse_args()

class ControlledClock:
    offset=0
    def __call__(self):return time.time()+self.offset

run_id=secrets.token_hex(5);run=root/'temp/multiplayer'/('market-extension-'+run_id);run.mkdir(parents=True)
os.environ['KIF_MAINLINE_GAME_ROOT']=str(root)
class Fixture(Handler):
    def send_fixture(self,value):
        raw=json.dumps(dict(ok=True,value=value)).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
    def fixture_name(self):
        name=self.path[9:]
        if not re.fullmatch('[A-Za-z0-9_-]{1,80}',name):raise ValueError('Invalid fixture marker')
        return name
    def do_GET(self):
        if not self.path.startswith('/fixture/'):return super().do_GET()
        self.send_fixture(read(self.fixture_name()))
    def do_POST(self):
        if not self.path.startswith('/fixture/'):return super().do_POST()
        length=int(self.headers.get('Content-Length','0'));assert 0<length<=65536
        value=json.loads(self.rfile.read(length));marker(self.fixture_name(),value);self.send_fixture(value)
    def log_message(self,*_args):pass
clock=ControlledClock();store=Store(run/'service.sqlite3',clock=clock,synchronous='FULL');server=ExclusiveHTTPServer(('127.0.0.1',0),Fixture);server.store=store;server.daemon_threads=True
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();url='http://127.0.0.1:'+str(server.server_port)
processes={};stages={};all_processes=[];android=None
def call(person,method,path,body=None):
    headers={'Content-Type':'application/json'}
    if person:headers['Authorization']='Bearer '+person['token']
    if method=='POST':
        body=dict(body or {})
        if not path.startswith('/v1/auth/'):body.setdefault('request_id','fixture_'+secrets.token_hex(16))
    request=urllib.request.Request(url+path,data=json.dumps(body).encode() if method=='POST' else None,headers=headers,method=method)
    with urllib.request.urlopen(request,timeout=30) as response:return json.load(response)
def marker(name,value):
    target=run/(name+'.json');temp=target.with_suffix('.tmp');temp.write_text(json.dumps(value),encoding='utf-8');temp.replace(target)
def read(name):
    path=run/(name+'.json');return json.loads(path.read_text(encoding='utf-8')) if path.exists() else None
def launch(role):
    if role=='guest' and android:
        android.start();print('MARKET_ANDROID_CLIENT_START',flush=True);return
    if role not in stages:
        profile='market-extra-'+role+'-'+run_id
        prepared=subprocess.run(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(root/'scripts/multiplayer/prepare-runtime.ps1'),'-Profile',profile,'-CustomScript',str(root/'tests/multiplayer/market_expansion_game.rb')],cwd=root,capture_output=True,text=True,check=True)
        stage=Path(prepared.stdout.strip().splitlines()[-1]);stages[role]=stage
        configuration=stage/'mkxp.json';configuration.write_text(configuration.read_text(encoding='utf-8-sig'),encoding='utf-8')
        (run/(role+'.json')).write_text(json.dumps(dict(role=role,directory=run.as_posix())),encoding='utf-8')
    stage=stages[role];profile=stage.name
    env=dict(os.environ,KIF_MULTIPLAYER_PROFILE=profile,KIF_MULTIPLAYER_SAVE_DIR=str(stage/'saves'),KIF_MULTIPLAYER_SERVER=url,KIF_MULTIPLAYER_SCENARIO=str(run/(role+'.json')))
    startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
    with open(stage/'stdout.log','ab') as out,open(stage/'stderr.log','ab') as err:
        process=subprocess.Popen([str(stage/'Game.exe')],cwd=stage,env=env,stdout=out,stderr=err,startupinfo=startup,creationflags=subprocess.CREATE_NO_WINDOW)
    processes[role]=process;all_processes.append(process);print('MARKET_NATIVE_CLIENT',role,process.pid,flush=True)
try:
    actors={}
    for role in ('host','guest','rival'):
        person=call(None,'POST','/v1/auth/register',dict(username='extras_'+role,password='IsolatedMarketFixture123',protocol=PROTOCOL));actors[role]=person
        with store.lock,store.connect() as db:store.trading_grant(db,person['identity']['id'],200000,[0,1,2] if role=='host' else [3,4,5] if role=='guest' else [],'native_extension_'+role,{'POTION':30,'RARECANDY':20} if role!='rival' else {})
    if args.adb:
        from market_expansion_android import AndroidGuest
        android=AndroidGuest(root,args.adb,args.serial,server.server_port,run)
    launch('host');launch('guest');restarted=False;outbid=False;auction_clock=False;default_clock=False
    deadline=time.monotonic()+1200
    while time.monotonic()<deadline:
        if android:
            error=android.error()
            assert error is None,error
            if read('guest-restart') and not restarted:restarted=True;launch('guest')
        for role,process in list(processes.items()):
            if process.poll() is not None:
                if role=='guest' and process.returncode==23 and read('guest-restart') and not restarted:
                    restarted=True;launch('guest');continue
                assert process.returncode==0 and read(role+'-pass'),(role,process.returncode,stages[role])
        if read('auction-first-bid') and not outbid:
            value=read('auction-first-bid')
            call(actors['rival'],'POST','/v1/market/contracts/'+value['id']+'/bid',dict(revision=value['revision'],amount=1200,compatibility=store.catalog()['compatibility']))
            marker('auction-outbid',dict(passed=True));outbid=True
        if read('auction-close-ready') and not auction_clock:
            with store.lock:clock.offset+=61
            auction_clock=True
        if read('default-ready') and not default_clock:
            with store.lock:clock.offset+=3601
            marker('default-clock-advanced',dict(passed=True));default_clock=True
        if read('host-pass') and read('guest-pass'):break
        time.sleep(.1)
    assert read('host-pass') and read('guest-pass'),'Native clients timed out'
    for process in processes.values():assert process.wait(timeout=15)==0
    with store.lock,store.connect() as db:
        audit=store.economy_audit(db);assert audit['ok'],audit
        counts={name:db.execute('SELECT COUNT(*) FROM '+name).fetchone()[0] for name in ('hosted_assets','market_orders','market_contracts','market_custody','market_contract_bids','asset_locks','wallet_holds','item_holds')}
        assert counts['hosted_assets']==8 and counts['market_custody']==0 and counts['asset_locks']==0 and counts['wallet_holds']==0 and counts['item_holds']==0,counts
        assert db.execute("SELECT COUNT(*) FROM market_contracts WHERE status IN ('open','active')").fetchone()[0]==0
        wallets={role:store.wallet(db,p['identity']['id']) for role,p in actors.items()}
    report=dict(passed=True,host=read('host-pass'),guest=read('guest-pass'),restarted_after_committed_partial_purchase=restarted,counts=counts,wallets=wallets,audit=audit,data_hash=store.catalog()['compatibility']['data_hash'],directory=run.relative_to(root).as_posix(),scope='Two actual Windows Game.exe clients and real server-native training/battle; third bidder uses actual HTTP. Deadlines advanced only by this isolated server clock; no public/physical-device claim.')
    if android:
        report['android']=android.metadata
        report['scope']='Actual Windows host and full Android APK guest with real native cultivation/battle; third bidder uses HTTP; deadline offsets limited to the isolated server. No public or physical-phone claim.'
    name='market-expansion-android.json' if android else 'market-expansion-native.json'
    (root/'docs/multiplayer-trading-evidence'/name).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('MARKET_EXPANSION_NATIVE_PASS',json.dumps(report,ensure_ascii=False),flush=True)
finally:
    if android:android.close()
    for process in all_processes:
        if process.poll() is None:process.terminate();process.wait(10)
    server.shutdown();server.server_close();thread.join(5);store.close()
