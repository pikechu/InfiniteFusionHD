from pathlib import Path
import json
import secrets
import sys
import time

root = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'server/multiplayer'))
from native_engine import NativeEngine

run = root/'temp/multiplayer'/('native-authority-'+secrets.token_hex(5))
engine = NativeEngine(root,run)
compatibility = json.loads((root/'server/multiplayer/catalog-rental-v1.json').read_text())['compatibility']
records = []
def call(operation,inputs=(),params=None):
    job_id,nonce = 'job_'+secrets.token_hex(16),secrets.token_hex(16)
    payload = {'nonce':nonce,'operation':operation,'inputs':list(inputs),'params':params or {},'owner':{'id':12345,'name':'服务器测试','gender':0},'compatibility':compatibility}
    engine.start(job_id,payload)
    deadline = time.monotonic()+60
    while time.monotonic()<deadline:
        kind,value = engine.poll(job_id,nonce)
        if kind=='result':
            assert value['ok'],value
            records.append({'operation':operation,'job_id':job_id,'verified_signature':True})
            print('NATIVE_AUTHORITY_PASS',operation,flush=True)
            return value['result']
        time.sleep(0.1)
    raise TimeoutError(operation)
try:
    first = call('starter',params={'species':'BULBASAUR'})['pokemon'][0]
    assert first['pokemon']['level']==5 and first['pokemon']['owner']['name']=='服务器测试'
    trained = call('train',[first],{'count':11})['pokemon'][0]
    assert trained['pokemon']['level']==16
    evolved = call('evolve',[trained],{'method':'level'})['pokemon'][0]
    assert evolved['pokemon']['species']=='IVYSAUR'
    second = call('starter',params={'species':'SQUIRTLE'})['pokemon'][0]
    fusion = call('fuse',[first,second])
    assert fusion['pokemon'][0]['pokemon']['species']=='B1H7'
    split = call('split',fusion['pokemon'],{'lineage':fusion['lineage'],'fusion_base_exp':fusion['fusion_base_exp']})
    assert [value['pokemon']['species'] for value in split['pokemon']]==['BULBASAUR','SQUIRTLE']
    document = {'passed':True,'data_hash':compatibility['data_hash'],'native_ruby':'3.1.3','private_hmac_verified':True,'operations':records,'scope':'Native mechanics/IPC foundation; mainline database and client integration are still in development.','directory':run.relative_to(root).as_posix()}
    (root/'docs/multiplayer-trading-evidence/mainline-native-foundation.json').write_text(json.dumps(document,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(document,ensure_ascii=False))
finally:
    engine.close()
