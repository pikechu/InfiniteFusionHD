"""Real HTTP + server-owned native workers; all data belongs to this test run."""
from pathlib import Path
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from service import Store,make_server,PROTOCOL

run = root/'temp/multiplayer'/('mainline-http-'+secrets.token_hex(5))
run.mkdir(parents=True)
previous = os.environ.get('KIF_MAINLINE_GAME_ROOT')
os.environ['KIF_MAINLINE_GAME_ROOT'] = str(root)
store = Store(run/'service.sqlite3',synchronous='FULL')
server = make_server('127.0.0.1',0,store)
thread = threading.Thread(target=server.serve_forever,daemon=True)
thread.start()
checks = []
def call(person,method,path,body=None,expected=200):
    headers = {'Content-Type':'application/json'}
    if person:
        headers['Authorization'] = 'Bearer '+person['token']
    if method=='POST':
        body = dict(body or {})
        if not path.startswith('/v1/auth/'):
            body.setdefault('request_id','probe_'+secrets.token_hex(16))
    request = urllib.request.Request('http://127.0.0.1:%d%s'%(server.server_port,path),data=json.dumps(body).encode() if method=='POST' else None,headers=headers,method=method)
    try:
        with urllib.request.urlopen(request,timeout=15) as response:
            status,result = response.status,json.load(response)
    except urllib.error.HTTPError as error:
        status,result = error.code,json.load(error)
    assert status==expected,(status,result)
    return result
def check(value,message):
    assert value,message
    checks.append(message)
    print('MAINLINE_HTTP_PASS',message,flush=True)
def wait(person,job):
    deadline = time.monotonic()+90
    while time.monotonic()<deadline:
        value = call(person,'GET','/v1/mainline/jobs/'+job['id'])['job']
        if value['status'] in ('completed','failed'):
            assert value['status']=='completed',value
            return value
        time.sleep(.2)
    raise TimeoutError(job['id'])
def character(person,name,starter='BULBASAUR'):
    value = call(person,'POST','/v1/mainline/characters',dict(name=name,gender=0,starter=starter,compatibility=store.catalog()['compatibility']),201)
    if value['job']:
        wait(person,value['job'])
    return call(person,'GET','/v1/mainline/characters/'+value['character']['id'])['character']
def action(person,char,operation,ids,params=None):
    value = call(person,'POST','/v1/mainline/characters/'+char['id']+'/jobs',dict(operation=operation,asset_ids=ids,params=params or {},compatibility=store.catalog()['compatibility']),202)
    return wait(person,value['job'])
try:
    a,b = [call(None,'POST','/v1/auth/register',dict(username='ml_'+name,password='IsolatedMainlineProbe123',protocol=PROTOCOL),201) for name in ('alice','bob')]
    first = character(a,'可信主线')
    asset = first['party'][0]
    check(asset['snapshot']['level']==5 and asset['source']=='server_managed','native starter enters the authoritative party once')
    duplicate = character(a,'第二角色')
    check(not duplicate['party'],'another save/character cannot repeat the starter grant')
    with store.lock,store.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        store.trading_grant(db,a['identity']['id'],0,[],'probe_candy_grant',{'RARECANDY':11})
        store.trading_grant(db,b['identity']['id'],2000,[],'probe_buyer_funds')
    action(a,first,'train',[asset['id']],{'count':11})
    first = call(a,'GET','/v1/mainline/characters/'+first['id'])['character']
    check(first['party'][0]['snapshot']['level']==16,'server-native training consumes the reserved candy and advances actual experience')
    action(a,first,'evolve',[asset['id']],{'method':'level'})
    first = call(a,'GET','/v1/mainline/characters/'+first['id'])['character']
    check(first['party'][0]['snapshot']['species']=='IVYSAUR','eligible evolution is computed on the trusted engine')
    call(a,'POST','/v1/market/listings',dict(asset_id=asset['id'],price=1000,compatibility=store.catalog()['compatibility']),409)
    check(True,'party member cannot be listed without depositing it first')
    first = call(a,'POST','/v1/mainline/characters/'+first['id']+'/party',dict(asset_ids=[],revision=first['revision']))['character']
    listed = call(a,'POST','/v1/market/listings',dict(asset_id=asset['id'],price=1000,compatibility=store.catalog()['compatibility']),201)['listing']
    bought = call(b,'POST','/v1/market/listings/'+listed['id']+'/buy',dict(price=1000,revision=listed['revision'],compatibility=store.catalog()['compatibility']))
    call(b,'POST','/v1/deliveries/'+bought['delivery']['id']+'/claim')
    call(a,'POST','/v1/mainline/characters/'+first['id']+'/party',dict(asset_ids=[asset['id']],revision=first['revision']),403)
    check(not call(a,'GET','/v1/mainline/characters/'+first['id'])['character']['party'],'old character references cannot restore an asset sold to another account')
    second = character(b,'融合验证')
    own = second['party'][0]
    action(b,second,'equip',[asset['id']],{'item_id':'POTION'})
    action(b,second,'equip',[own['id']],{'item_id':'POTION'})
    action(b,second,'fuse',[asset['id'],own['id']])
    second = call(b,'GET','/v1/mainline/characters/'+second['id'])['character']
    fused = second['party'][0]
    check(fused['snapshot']['species']=='B2H1' and len(fused['lineage_ids'])==2,'fusion consumes both parent ownerships and records authoritative lineage')
    with store.connect() as db:
        check(store.item_balance(db,'asset:'+fused['id'],'POTION')['quantity']==1 and store.item_balance(db,'asset:'+asset['id'],'POTION')['quantity']==0 and store.item_balance(db,'asset:'+own['id'],'POTION')['quantity']==1,'fusion moves body attachment and escrows head attachment without duplication')
    action(b,second,'equip',[fused['id']],{'item_id':None})
    action(b,second,'split',[fused['id']])
    second = call(b,'GET','/v1/mainline/characters/'+second['id'])['character']
    check(set(value['id'] for value in second['party'])=={asset['id'],own['id']},'split restores the original two identities rather than creating copies')
    with store.connect() as db:
        check(store.item_balance(db,'asset:'+asset['id'],'POTION')['quantity']==0 and store.item_balance(db,'asset:'+own['id'],'POTION')['quantity']==1 and store.item_balance(db,b['identity']['id'],'POTION')['quantity']==4,'split keeps changed body attachment and returns the original head attachment')
    second=call(b,'POST','/v1/mainline/characters/'+second['id']+'/party',dict(asset_ids=[],revision=second['revision']))['character']
    session=call(a,'POST','/v1/exchanges',dict(friend_code=b['identity']['friend_code'],compatibility=store.catalog()['compatibility']),201)['exchange']
    def exchange(person,kind,**params):
        global session
        session=call(person,'POST','/v1/exchanges/'+session['id']+'/'+kind,params)['exchange']
    exchange(b,'accept',compatibility=store.catalog()['compatibility'])
    exchange(b,'offer',revision=session['revision'],asset_ids=[asset['id']],amount=0)
    exchange(a,'lock',revision=session['revision'],offer_hash=session['offer_hash'])
    exchange(b,'lock',revision=session['revision'],offer_hash=session['offer_hash'])
    time.sleep(3.1)
    exchange(a,'confirm',revision=session['revision'],offer_hash=session['offer_hash'])
    final=dict(request_id='same_trade_confirmation',revision=session['revision'],offer_hash=session['offer_hash'])
    exchange(b,'confirm',**final)
    exchange(b,'confirm',**final)
    deadline=time.monotonic()+90
    while time.monotonic()<deadline:
        with store.lock,store.connect() as db:
            store.tick_mainline_jobs(db)
            event=db.execute('SELECT status FROM ml_trade_evolutions WHERE asset_id=?',(asset['id'],)).fetchone()
            if event and event[0]=='completed':break
        time.sleep(.1)
    check(event and event[0]=='completed','committed exchange triggers a completed native evolution event while recipient is offline')
    with store.connect() as db:
        check(db.execute('SELECT COUNT(*) FROM ml_trade_evolutions WHERE asset_id=?',(asset['id'],)).fetchone()[0]==1 and store.asset(db,asset['id'])['owner_id']==a['identity']['id'],'repeated confirmation retains one evolution event and the new owner')
    with store.connect() as db:
        check(store.economy_audit(db)['ok'],'currency and item ledgers remain balanced after native operations')
        check(db.execute('SELECT COUNT(*) FROM asset_locks').fetchone()[0]==0,'completed native operations leave no resource lock')
    record = {'passed':True,'checks':checks,'directory':run.relative_to(root).as_posix(),'data_hash':store.catalog()['compatibility']['data_hash'],'scope':'Authoritative HTTP character, cultivation, market and lineage integration; native client and combat have separate evidence.'}
    (root/'docs/multiplayer-trading-evidence/mainline-native-http.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,ensure_ascii=False))
finally:
    server.shutdown()
    server.server_close()
    thread.join(5)
    store.close()
    if previous is None:
        os.environ.pop('KIF_MAINLINE_GAME_ROOT',None)
    else:
        os.environ['KIF_MAINLINE_GAME_ROOT'] = previous
