"""Own native client process against an isolated live native-authority service."""
from pathlib import Path
import json,os,secrets,subprocess,sys,threading,time,urllib.request,urllib.error
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from service import Store,make_server,PROTOCOL
run_id=secrets.token_hex(5);run=root/'temp/multiplayer'/('mainline-client-'+run_id);run.mkdir(parents=True)
os.environ['KIF_MAINLINE_GAME_ROOT']=str(root)
store=Store(run/'service.sqlite3',synchronous='FULL');server=make_server('127.0.0.1',0,store)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
url='http://127.0.0.1:'+str(server.server_port)
def call(token,method,path,body=None):
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    if method=='POST':
        body=dict(body or {})
        if not path.startswith('/v1/auth/'):body.setdefault('request_id','probe_'+secrets.token_hex(16))
    req=urllib.request.Request(url+path,data=json.dumps(body).encode() if method=='POST' else None,headers=headers,method=method)
    with urllib.request.urlopen(req,timeout=30) as response:return json.load(response)
process=None
try:
    buyer=call(None,'POST','/v1/auth/register',dict(username='buyer_'+run_id,password='NativeMainlineFixture123',protocol=PROTOCOL))
    with store.lock,store.connect() as db:store.trading_grant(db,buyer['identity']['id'],5000,[],'buyer_fixture')
    scenario=run/'scenario.json';scenario.write_text(json.dumps(dict(directory=run.as_posix(),username='role_'+run_id)),encoding='utf-8')
    profile='mainline-client-'+run_id
    prepared=subprocess.run(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(root/'scripts/multiplayer/prepare-runtime.ps1'),'-Profile',profile,'-CustomScript',str(root/'tests/multiplayer/mainline_game.rb')],cwd=root,capture_output=True,text=True,check=True)
    stage=Path(prepared.stdout.strip().splitlines()[-1])
    # Windows PowerShell 5 writes a BOM; mkxp's JSON parser requires UTF-8 data.
    configuration=stage/'mkxp.json'
    configuration.write_text(configuration.read_text(encoding='utf-8-sig'),encoding='utf-8')
    env=dict(os.environ,KIF_MULTIPLAYER_PROFILE=profile,KIF_MULTIPLAYER_SAVE_DIR=str(stage/'saves'),KIF_MULTIPLAYER_SERVER=url,KIF_MULTIPLAYER_SCENARIO=str(scenario))
    options={};startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
    options.update(startupinfo=startup,creationflags=subprocess.CREATE_NO_WINDOW)
    with open(stage/'stdout.log','wb') as out,open(stage/'stderr.log','wb') as err:process=subprocess.Popen([str(stage/'Game.exe')],cwd=stage,env=env,stdout=out,stderr=err,**options)
    deadline=time.monotonic()+90;sold=False
    while time.monotonic()<deadline:
        listed=run/'mainline-listed.json'
        if listed.exists() and not sold:
            data=json.loads(listed.read_text());listing=call(buyer['token'],'GET','/v1/market/listings/'+data['listing_id'])['listing']
            call(buyer['token'],'POST','/v1/market/listings/'+data['listing_id']+'/buy',dict(revision=listing['revision'],price=listing['price'],compatibility=store.catalog()['compatibility']))
            (run/'mainline-sold.json').write_text('{}');sold=True
        if process.poll() is not None:break
        time.sleep(.1)
    assert process.poll()==0,(process.poll(),stage,run)
    evidence=json.loads((run/'mainline-client-pass.json').read_text())
    profile='mainline-restore-'+run_id
    prepared=subprocess.run(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(root/'scripts/multiplayer/prepare-runtime.ps1'),'-Profile',profile,'-CustomScript',str(root/'tests/multiplayer/mainline_restore_game.rb')],cwd=root,capture_output=True,text=True,check=True)
    stage=Path(prepared.stdout.strip().splitlines()[-1]);configuration=stage/'mkxp.json'
    configuration.write_text(configuration.read_text(encoding='utf-8-sig'),encoding='utf-8')
    env=dict(os.environ,KIF_MULTIPLAYER_PROFILE=profile,KIF_MULTIPLAYER_SAVE_DIR=str(stage/'saves'),KIF_MULTIPLAYER_SERVER=url,KIF_MULTIPLAYER_SCENARIO=str(scenario))
    with open(stage/'stdout.log','wb') as out,open(stage/'stderr.log','wb') as err:process=subprocess.Popen([str(stage/'Game.exe')],cwd=stage,env=env,stdout=out,stderr=err,**options)
    assert process.wait(timeout=75)==0,stage
    evidence['fresh_device']=json.loads((run/'mainline-restore-pass.json').read_text())
    with store.connect() as db:assert store.economy_audit(db)['ok']
    evidence['directory']=run.relative_to(root).as_posix()
    (root/'docs/multiplayer-trading-evidence/mainline-client.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('MAINLINE_NATIVE_CLIENT_PASS',json.dumps(evidence,ensure_ascii=False))
finally:
    if process and process.poll() is None:process.terminate();process.wait(10)
    server.shutdown();server.server_close();thread.join(5);store.close()
