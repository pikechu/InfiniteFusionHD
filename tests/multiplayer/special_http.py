"""Real HTTP special-event claims, mode resources and final candidate ownership."""
from pathlib import Path
import json,os,secrets,sys,threading,time,urllib.request,urllib.error
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from service import Store,make_server,PROTOCOL
run=root/'temp/multiplayer'/('public-story-'+secrets.token_hex(5));run.mkdir(parents=True)
os.environ['KIF_MAINLINE_GAME_ROOT']=str(root)
store=Store(run/'service.sqlite3',synchronous='FULL');server=make_server('127.0.0.1',0,store)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();checks=[]
def call(person,method,path,body=None,status=200):
    headers={'Content-Type':'application/json'}
    if person:headers['Authorization']='Bearer '+person['token']
    if method=='POST':
        body=dict(body or {})
        if not path.startswith(('/v1/auth/','/v1/world/')):body.setdefault('request_id','story_'+secrets.token_hex(16))
    req=urllib.request.Request('http://127.0.0.1:%d%s'%(server.server_port,path),data=json.dumps(body).encode() if method=='POST' else None,headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=20) as response:actual,value=response.status,json.load(response)
    except urllib.error.HTTPError as error:actual,value=error.code,json.load(error)
    assert actual==status,(actual,value)
    return value
def wait(job,style='attack',failed=False):
    sent=set();deadline=time.monotonic()+160
    while time.monotonic()<deadline:
        current=call(person,'GET','/v1/mainline/jobs/'+job['id'])['job']
        if current['status'] in ('completed','failed'):
            assert current['status']==('failed' if failed else 'completed'),current
            return current
        prompt=current.get('prompt')
        if prompt and prompt['sequence'] not in sent:
            state=prompt['state']
            if state['kind']=='safari':command={'action':'surrender'}
            elif state['kind']=='switch':command={'action':'switch','party_index':state['switches'][0]['party_index']}
            elif style=='catch' and state['balls']:command={'action':'catch','item_id':state['balls'][0]['id']}
            elif state['moves']:
                move=state['moves'][0];command={'action':'move','move_index':move['index'],'target':move['targets'][0]}
            else:command={'action':'forced'}
            body=dict(request_id='command_'+secrets.token_hex(12),sequence=prompt['sequence'],command=command)
            first=call(person,'POST','/v1/mainline/jobs/'+job['id']+'/commands',body,202)
            assert call(person,'POST','/v1/mainline/jobs/'+job['id']+'/commands',body,202)==first
            sent.add(prompt['sequence'])
        time.sleep(.1)
    raise TimeoutError(job['id'])
def check(value,name):
    assert value,name
    checks.append(name);print('PUBLIC_STORY_PASS',name,flush=True)
def current():return call(person,'GET','/v1/mainline/characters/'+cid)['character']
def action(operation,params,**kwargs):
    role=current()
    body=dict(operation=operation,asset_ids=[asset['id'] for asset in role['party']],params=params,compatibility=comp)
    return wait(call(person,'POST','/v1/mainline/characters/'+cid+'/jobs',body,202)['job'],**kwargs)
seq=0
def presence(map_id):
    global seq
    call(person,'POST','/v1/world/join',dict(session_id=world,compatibility=comp))
    seq+=1
    call(person,'POST','/v1/world/sync',dict(session_id=world,seq=seq,after=0,position=dict(map_id=map_id,map_hash='a'*64,width=64,height=64,x=4,y=4,direction=2,character_id=0,moving=False)))
try:
    person=call(None,'POST','/v1/auth/register',dict(username='public_story',password='IsolatedStoryFixture123',protocol=PROTOCOL),201)
    comp=store.catalog()['compatibility']
    created=call(person,'POST','/v1/mainline/characters',dict(name='剧情战接口',gender=0,starter='BULBASAUR',compatibility=comp),201)
    wait(created['job']);cid=created['character']['id'];owner=person['identity']['id']
    # Explicit operator-only synthetic test progress; public clients never set it.
    with store.lock,store.connect() as db:
        role=store.mainline_character(db,cid,owner);role['badges']=list(range(8));store.save_mainline_character(db,role)
        store.trading_grant(db,owner,10000,[],'story_operator_fixture',{'RARECANDY':95,'MASTERBALL':1})
    action('train',{'count':95})
    world='story_world_'+secrets.token_hex(8);call(person,'POST','/v1/world/join',dict(session_id=world,compatibility=comp))
    data=json.loads(max((root/'temp/multiplayer').glob('native-story-*/catalog.json'),key=lambda path:path.stat().st_ctime).read_text(encoding='utf-8'))
    declaration=next(entry for entry in data['entries'] if (entry['map_id'],entry['event_id'],entry['page'])==(491,21,0))
    presence(491);context=dict(event_id=21,page=0,command_index=declaration['battles'][0]['command_index'])
    caught=action('battle',dict(kind='story',map_id=491,story=context,belt={'MASTERBALL':1}),style='catch')
    check(caught['result']['decision']==4 and len(caught['result']['captured_asset_ids'])==1,'declared story capture creates one owned asset')
    before=len(current()['party']);context['occurrence']=0
    body=dict(operation='battle',asset_ids=[asset['id'] for asset in current()['party']],params=dict(kind='story',map_id=491,story=context,belt={}),compatibility=comp)
    call(person,'POST','/v1/mainline/characters/'+cid+'/jobs',body,409)
    check(len(current()['party'])==before,'equivalent story context cannot claim the capture again')
    context['command_index']=99999
    action('battle',dict(kind='story',map_id=491,story=context,belt={}),failed=True)
    check(len(current()['party'])==before,'forged command fails without creating assets')
    presence(473);before_money=current()['wallet']['balance']
    session=action('safari_enter',dict(map_id=473))['result']['story']
    check(session['remaining']==30 and current()['wallet']['balance']==before_money-500,'Safari entry allocates exactly 30 bound balls for one fee')
    presence(session['allowed_maps'][0]);result=action('battle',dict(kind='safari',map_id=session['allowed_maps'][0],session_id=session['id'],belt={}))
    check(result['result']['story']['remaining']==30,'native Safari surrender preserves unthrown ball quota')
    call(person,'POST','/v1/mainline/story/'+session['id']+'/leave',{})
    check(current()['story'] is None,'leaving Safari retires its quota and activity')
    contest_map=data['contest_maps'][0];presence(contest_map)
    session=action('contest_enter',dict(map_id=contest_map))['result']['story']
    with store.connect() as db:before_assets=db.execute('SELECT COUNT(*) FROM hosted_assets WHERE owner=?',(owner,)).fetchone()[0]
    for _ in range(5):
        presence(contest_map)
        result=action('battle',dict(kind='contest',map_id=contest_map,session_id=session['id'],belt={}),style='catch')
        session=result['result']['story']
        if session['candidate'] or session['remaining']==0:break
    check(bool(session['candidate']),'Sport Ball capture becomes a persisted contest candidate')
    with store.connect() as db:check(db.execute('SELECT COUNT(*) FROM hosted_assets WHERE owner=?',(owner,)).fetchone()[0]==before_assets,'contest candidate is not tradable before judging')
    finished=action('contest_finish',dict(session_id=session['id']))
    check(finished['result']['story']['status']=='completed' and len(finished['result']['story']['asset_ids'])==1,'judging creates one final asset from the original candidate')
    with store.connect() as db:
        check(store.economy_audit(db)['ok'],'special encounter money and item ledgers balance')
        check(db.execute('SELECT COUNT(*) FROM asset_locks').fetchone()[0]==0,'special activities leave no native asset locks')
    record=dict(passed=True,checks=checks,data_hash=comp['data_hash'],directory=run.relative_to(root).as_posix(),fixture='operator seeded badges/supplies; world presence is API fixture data, not a rendered cross-device test')
    (root/'docs/multiplayer-trading-evidence/special-http.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
finally:
    server.shutdown();server.server_close();thread.join(5);store.close()
