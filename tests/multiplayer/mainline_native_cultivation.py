"""Real installed engine breeding, healing and trade-held-item mechanics."""
from pathlib import Path
import copy,json,secrets,sys,time
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from native_engine import NativeEngine
run=root/'temp/multiplayer'/('native-cultivation-'+secrets.token_hex(5))
engine=NativeEngine(root,run)
compat=json.loads((root/'server/multiplayer/catalog-rental-v1.json').read_text())['compatibility']
checks=[]
def call(operation,inputs=(),params=None):
    job='job_'+secrets.token_hex(16);nonce=secrets.token_hex(16)
    engine.start(job,dict(nonce=nonce,operation=operation,inputs=list(inputs),params=params or {},owner=dict(id=12345,name='原生培育',gender=0),compatibility=compat))
    deadline=time.monotonic()+90
    while time.monotonic()<deadline:
        kind,value=engine.poll(job,nonce)
        if kind=='result':
            assert value['ok'],(job,value)
            print('NATIVE_CULTIVATION_RESULT',operation,flush=True)
            return value['result']
        time.sleep(.1)
    raise TimeoutError((operation,job))
def check(value,message):
    assert value,message
    checks.append(message);print('NATIVE_CULTIVATION_PASS',message,flush=True)
try:
    first=call('starter',params={'species':'BULBASAUR'})['pokemon'][0]
    female=copy.deepcopy(first['pokemon']);female['gender']=1
    male=copy.deepcopy(first['pokemon']);male['gender']=0;male['personal_id']=(male['personal_id']+1)%2**32
    egg=call('breed',[female,male])
    check(egg['pokemon'][0]['pokemon']['species']=='BULBASAUR' and egg['hatch_steps']>0,'native daycare genetics produce a valid incubatable egg')
    injured=copy.deepcopy(first);injured['preserved']['hp']=1
    healed=call('use_item',[injured],{'item_id':'POTION'})['pokemon'][0]
    check(healed['preserved']['hp']>1,'actual item handler restores health')
    held=call('equip',[first],{'item_id':'POTION'})['pokemon'][0]
    check(held['pokemon']['item']=='POTION','native held-item assignment round-trips')
    trade=copy.deepcopy(first['pokemon']);trade.update(species='POLIWHIRL',item='KINGSROCK')
    preview=call('preview_evolution',[trade],{'method':'trade','optional':True})['pokemon'][0]
    check(preview['pokemon']['species']=='POLITOED' and preview['pokemon']['item'] is None and trade['item']=='KINGSROCK','trade preview shows evolved species and consumed attachment without changing input')
    evolved=call('trade_evolve',[trade],{'method':'trade','optional':True})['pokemon'][0]
    check(evolved['pokemon']['species']=='POLITOED' and evolved['pokemon']['item'] is None,'trade evolution consumes Kings Rock on the old species callback')
    unchanged=call('trade_evolve',[first],{'method':'trade','optional':True})['pokemon'][0]
    check(unchanged['pokemon']['species']=='BULBASAUR','ineligible received Pokemon remains unchanged')
    record=dict(passed=True,checks=checks,data_hash=compat['data_hash'],directory=run.relative_to(root).as_posix())
    (root/'docs/multiplayer-trading-evidence/mainline-native-cultivation.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
finally:engine.close()
