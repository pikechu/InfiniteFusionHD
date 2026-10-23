"""Real native special-battle mechanics against installed map declarations."""
from pathlib import Path
import copy,json,secrets,sys,time
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from native_engine import NativeEngine
run=root/'temp/multiplayer'/('native-story-'+secrets.token_hex(5));engine=NativeEngine(root,run)
catalog=json.loads((root/'server/multiplayer/catalog-rental-v1.json').read_text());comp=catalog['compatibility']
party=copy.deepcopy(catalog['pokemon'][:3])
for pokemon in party:pokemon['level']=100
checks=[]
def check(value,name):
    assert value,name
    checks.append(name);print('NATIVE_STORY_PASS',name,flush=True)
def call(operation,params,inputs=None,style='attack',expect_error=False):
    job='job_'+secrets.token_hex(16);nonce=secrets.token_hex(16)
    engine.start(job,dict(nonce=nonce,operation=operation,inputs=party if inputs is None else inputs,params=params,owner=dict(id=12345,name='特殊战验收',gender=0),compatibility=comp))
    deadline=time.monotonic()+180;sent=set();seen=[]
    while time.monotonic()<deadline:
        kind,value=engine.poll(job,nonce)
        if kind=='result':
            if expect_error:
                assert value['ok'] is False,value
                return value
            assert value['ok'],(job,value)
            print('NATIVE_STORY_RESULT',operation,params.get('kind'),len(sent),flush=True)
            return value['result'],seen
        if kind=='prompt' and value['sequence'] not in sent:
            state=value['state'];seen.append(state)
            if state['kind']=='safari':command={'action':'safari_ball'}
            elif state['kind']=='switch':command={'action':'switch','party_index':state['switches'][0]['party_index']}
            elif style=='catch' and state['balls']:command={'action':'catch','item_id':state['balls'][0]['id']}
            elif style=='surrender':command={'action':'surrender'}
            elif state['moves']:
                move=next((move for move in state['moves'] if move['id'] not in ('SWORDSDANCE','PROTECT','RECOVER','TOXIC','STEALTHROCK','DRAGONDANCE','CALMMIND','WISH','HEALBELL','THUNDERWAVE')),state['moves'][0])
                target=next((target for target in move['targets'] if target==-1 or target%2==1),move['targets'][0])
                command={'action':'move','move_index':move['index'],'target':target}
            else:command={'action':'forced'}
            engine.command(job,nonce,value['sequence'],command);sent.add(value['sequence'])
        time.sleep(.08)
    raise TimeoutError((job,operation,params))
try:
    data,_=call('story_catalog',{})
    (run/'catalog.json').write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
    check(bool(data['safari_maps']) and bool(data['contest_maps']),'compiled Safari and contest maps are available')
    base=dict(level_cap=100,badge_count=8,wallet=10000,belt={},reward_enabled=True)
    encounter_data,_=call('encounter_catalog',{})
    multi,states=call('battle',dict(base,kind='trainer',trainers=encounter_data['trainers'][:2]))
    check(multi['decision']==1 and len({state['active_index'] for state in states if state['kind']=='command'})==2,'two compiled trainers retain their parties and separate player commands')
    for map_id,event_id,page in [(240,14,1),(826,1,1),(436,16,0),(799,6,0)]:
        entry=next(entry for entry in data['entries'] if (entry['map_id'],entry['event_id'],entry['page'])==(map_id,event_id,page))
        declaration=entry['battles'][0]
        params=dict(base,kind='story',map_id=map_id,story=dict(event_id=event_id,page=page,command_index=declaration['command_index'],occurrence=0))
        result,states=call('battle',params)
        check(result['decision']==1,'compiled special event %d/%d wins using native mechanics'%(map_id,event_id))
        if map_id in (826,436):check(len({state['active_index'] for state in states if state['kind']=='command'})>=2,'multi battle requests each player position and legal targets')
    partner_entry=next(entry for entry in data['entries'] if entry.get('partners'))
    partner=partner_entry['partners'][0]
    certified,_=call('partner_register',dict(map_id=partner_entry['map_id'],partner=partner,level_cap=100))
    check(certified['story']['partner']==partner,'story companion is certified from installed map and trainer data')
    entry=next(entry for entry in data['entries'] if (entry['map_id'],entry['event_id'],entry['page'])==(826,1,1))
    result,states=call('battle',dict(base,kind='story',map_id=826,story=dict(event_id=1,page=1,command_index=entry['battles'][0]['command_index'],occurrence=0),partner=partner))
    check(result['decision']==1 and all(state['active_index']==0 for state in states if state['kind']=='command'),'certified companion is controlled by native AI without exposing ally assets')
    call('battle',dict(base,kind='story',map_id=240,story=dict(event_id=14,page=1,command_index=99999,occurrence=0)),expect_error=True)
    check(True,'invented event command cannot authorize a story encounter')
    map_id=data['safari_maps'][0]
    entry,_=call('safari_enter',dict(map_id=map_id,selected_index=0))
    remaining=30;caught=False
    for _ in range(10):
        result,_=call('battle',dict(base,kind='safari',map_id=map_id,story_ball_count=remaining,story_expires_at=time.time()+120),style='catch')
        check(0<=result['story_ball_remaining']<remaining,'Safari consumes original native ball quota')
        remaining=result['story_ball_remaining']
        if result['captured']:caught=True;break
        if remaining<=0:break
    check(caught,'original Safari engine produces a certified capture')
    roamer=data['roamers'][-1]
    roamer_map=next(map_id for map_id in roamer['maps'] if map_id not in data['safari_maps'])
    result,_=call('battle',dict(base,kind='roamer',map_id=roamer_map,roamer_index=roamer['index']),style='surrender')
    check(bool(result.get('roamer_state')),'roamer escape preserves native individual state')
    result,_=call('battle',dict(base,kind='roamer',map_id=roamer_map,roamer_index=roamer['index'],roamer_state=result['roamer_state'],belt={'MASTERBALL':1}),style='catch')
    check(result['decision']==4 and len(result['captured'])==1,'returning roamer can be captured with the existing identity')
    contest_map=data['contest_maps'][0];candidate=None;remaining=20
    for _ in range(10):
        result,_=call('battle',dict(base,kind='contest',map_id=contest_map,selected_index=0,story_ball_count=remaining,story_expires_at=time.time()+120),style='catch')
        remaining=result['story_ball_remaining']
        if result['captured']:candidate=result['captured'][0];break
        if remaining<=0:break
    check(candidate is not None,'contest produces a native candidate using Sport Balls')
    judged,_=call('contest_finish',dict(map_id=contest_map,candidate=candidate,pending_candidate=None))
    check(judged['story']['candidate']==candidate and 0<=judged['story']['place']<=3,'native contest judging retains the original candidate blueprint')
    record=dict(passed=True,checks=checks,data_hash=comp['data_hash'],directory=run.relative_to(root).as_posix())
    (root/'docs/multiplayer-trading-evidence/special-native.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
finally:engine.close()
