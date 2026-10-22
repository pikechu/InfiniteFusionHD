"""Authenticated public HTTP command/outbox path with real native combat."""
from pathlib import Path
import json,os,secrets,sys,threading,time,urllib.request,urllib.error
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from service import Store,make_server,PROTOCOL
run=root/'temp/multiplayer'/('public-native-battle-'+secrets.token_hex(5));run.mkdir(parents=True)
os.environ['KIF_MAINLINE_GAME_ROOT']=str(root)
store=Store(run/'service.sqlite3',synchronous='FULL')
server=make_server('127.0.0.1',0,store);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
checks=[]
def call(person,method,path,body=None,status=200):
    headers={'Content-Type':'application/json'}
    if person: headers['Authorization']='Bearer '+person['token']
    if method=='POST':
        body=dict(body or {})
        if not path.startswith(('/v1/auth/','/v1/world/')):body.setdefault('request_id','probe_'+secrets.token_hex(16))
    req=urllib.request.Request('http://127.0.0.1:%d%s'%(server.server_port,path),data=json.dumps(body).encode() if method=='POST' else None,headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=15) as response:actual,value=response.status,json.load(response)
    except urllib.error.HTTPError as error:actual,value=error.code,json.load(error)
    assert actual==status,(actual,value)
    return value
def wait_job(person,job,catch=False):
    deadline=time.monotonic()+120;sent=set()
    while time.monotonic()<deadline:
        current=call(person,'GET','/v1/mainline/jobs/'+job['id'])['job']
        if current['status'] in ('completed','failed'):
            assert current['status']=='completed',current
            return current
        prompt=current.get('prompt')
        if prompt and prompt['sequence'] not in sent:
            state=prompt['state']
            if state['kind']=='switch':command={'action':'switch','party_index':state['switches'][0]['party_index']}
            elif catch and prompt['sequence']==0 and state.get('medicine'):command={'action':'item','item_id':state['medicine'][0]['id'],'party_index':0}
            elif catch and state['balls']:command={'action':'catch','item_id':state['balls'][0]['id']}
            elif state['moves']:command={'action':'move','move_index':state['moves'][0]['index']}
            else:command={'action':'forced'}
            body={'request_id':'battle_cmd_'+secrets.token_hex(10),'sequence':prompt['sequence'],'command':command}
            first=call(person,'POST','/v1/mainline/jobs/'+job['id']+'/commands',body,202)
            repeated=call(person,'POST','/v1/mainline/jobs/'+job['id']+'/commands',body,202)
            assert first==repeated
            sent.add(prompt['sequence'])
        time.sleep(.1)
    raise TimeoutError(job['id'])
def check(value,message):
    assert value,message
    checks.append(message);print('PUBLIC_BATTLE_PASS',message,flush=True)
try:
    person=call(None,'POST','/v1/auth/register',{'username':'native_battle','password':'SyntheticNativeProbe123','protocol':PROTOCOL},201)
    comp=store.catalog()['compatibility']
    created=call(person,'POST','/v1/mainline/characters',dict(name='原生对战',gender=0,starter='BULBASAUR',compatibility=comp),201)
    wait_job(person,created['job']);cid=created['character']['id']
    character=call(person,'GET','/v1/mainline/characters/'+cid)['character'];ids=[a['id'] for a in character['party']]
    with store.lock,store.connect() as db:
        store.trading_grant(db,person['identity']['id'],0,[],'native_masterball',{'MASTERBALL':1})
    position=dict(map_id=42,map_hash='a'*64,width=32,height=32,x=4,y=4,direction=2,character_id=0,moving=False)
    session='native_world_session_'+secrets.token_hex(8)
    call(person,'POST','/v1/world/join',dict(session_id=session,compatibility=comp))
    call(person,'POST','/v1/world/sync',dict(session_id=session,seq=1,after=0,position=position))
    result=call(person,'POST','/v1/mainline/characters/'+cid+'/jobs',dict(operation='battle',asset_ids=ids,params={'kind':'wild','map_id':42,'belt':{'MASTERBALL':1,'POTION':1}},compatibility=comp),202)
    captured=wait_job(person,result['job'],True)
    check(captured['result']['decision']==4 and len(captured['result']['captured_asset_ids'])==1,'public command path captures one native-generated Pokemon')
    inventory=call(person,'GET','/v1/inventory')['inventory']['items']
    check(not any(x['item_id']=='MASTERBALL' for x in inventory),'capture consumes the reserved ball once')
    check(next(x['quantity'] for x in inventory if x['item_id']=='POTION')==5,'native battle returns medicine when used on a full-health target')
    character=call(person,'GET','/v1/mainline/characters/'+cid)['character']
    check(len(character['party'])==2,'captured identity joins the server party')
    again=call(person,'GET','/v1/mainline/jobs/'+result['job']['id'])['job']
    check(again==captured,'re-reading completed battle does not create another capture')
    with store.connect() as db:
        check(store.economy_audit(db)['ok'],'native outcome keeps currency and item ledgers balanced')
        check(db.execute('SELECT COUNT(*) FROM asset_locks').fetchone()[0]==0,'battle releases every asset lock')
    record={'passed':True,'checks':checks,'directory':run.relative_to(root).as_posix(),'data_hash':comp['data_hash']}
    (root/'docs/multiplayer-trading-evidence/mainline-public-battle.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
finally:
    server.shutdown();server.server_close();thread.join(5);store.close()
