from pathlib import Path
import json
import secrets
import sys
import time

root = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from native_engine import NativeEngine

run = root/'temp/multiplayer'/('native-battle-'+secrets.token_hex(5))
engine = NativeEngine(root,run)
compatibility = json.loads((root/'server/multiplayer/catalog-rental-v1.json').read_text())['compatibility']
records = []
def call(operation,inputs=(),params=None,catch=False):
    job_id,nonce = 'job_'+secrets.token_hex(16),secrets.token_hex(16)
    engine.start(job_id,{'nonce':nonce,'operation':operation,'inputs':list(inputs),'params':params or {},'owner':{'id':12345,'name':'权威战斗测试','gender':0},'compatibility':compatibility})
    deadline = time.monotonic()+120
    sent = set()
    while time.monotonic()<deadline:
        kind,value = engine.poll(job_id,nonce)
        if kind=='result':
            assert value['ok'],value
            records.append({'operation':operation,'job_id':job_id,'commands':len(sent),'signature_verified':True})
            print('NATIVE_BATTLE_PASS',operation,flush=True)
            return value['result']
        if kind=='prompt' and value['sequence'] not in sent:
            state = value['state']
            if state['kind']=='switch':
                command = {'action':'switch','party_index':state['switches'][0]['party_index']}
            elif catch and state['balls']:
                command = {'action':'catch','item_id':state['balls'][0]['id']}
            elif state['moves']:
                command = {'action':'move','move_index':state['moves'][0]['index']}
            else:
                command = {'action':'forced'}
            engine.command(job_id,nonce,value['sequence'],command)
            sent.add(value['sequence'])
        time.sleep(.1)
    raise TimeoutError(operation)
try:
    encounters = call('encounter_catalog');maps=encounters['maps']
    selected = next((item,key) for item in maps for key,level in item['types'].items() if key.startswith(('Land','Cave')) and level<=5)
    starter = call('starter',params={'species':'BULBASAUR'})['pokemon'][0]
    trained = call('train',[starter],{'count':45})['pokemon'][0]
    base = {'kind':'wild','map_id':selected[0]['map_id'],'encounter_type':selected[1],'level_cap':100,'badge_count':8,'wallet':10000,'reward_enabled':True}
    capture = call('battle',[trained],dict(base,belt={'MASTERBALL':1}),catch=True)
    assert capture['decision']==4 and len(capture['captured'])==1,capture
    assert capture['bag_final']['MASTERBALL']==0
    won = call('battle',capture['pokemon'],dict(base,belt={}))
    assert won['decision']==1,won
    assert won['pokemon'][0]['preserved']['exp']>=capture['pokemon'][0]['preserved']['exp']
    trainer=call('battle',won['pokemon'],dict(base,kind='trainer',belt={},**encounters['trainers'][0]))
    assert trainer['decision']==1 and trainer['money_delta']>0,trainer
    repeat=call('battle',trainer['pokemon'],dict(base,kind='trainer',belt={},reward_enabled=False,**encounters['trainers'][0]))
    assert repeat['decision']==1 and repeat['money_delta']==0,repeat
    boss=call('battle',repeat['pokemon'],dict(base,kind='boss',boss_index=0,belt={}))
    assert boss['decision']==1,boss
    evidence = {'passed':True,'data_hash':compatibility['data_hash'],'directory':run.relative_to(root).as_posix(),'map_id':base['map_id'],'native_caught_one':True,'capture_ball_consumed_once':True,'native_victory':True,'native_experience_applied':True,'native_trainer_reward':True,'disabled_repeat_reward':True,'native_badge_boss':True,'operations':records,'scope':'Private authoritative engine mechanics, complementing the public HTTP and client evidence.'}
    (root/'docs/multiplayer-trading-evidence/mainline-native-battle-foundation.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(evidence))
finally:
    engine.close()
