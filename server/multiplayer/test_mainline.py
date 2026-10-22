"""Native job resource/ownership boundaries. Mechanics fixtures came from Game.exe."""
import copy
import json
from pathlib import Path
import unittest

from service import Store
import test_inventory as inventory_tests


class RecordedEngine:
    def __init__(self):
        path = Path(__file__).resolve().parents[2]/'tests/multiplayer/fixtures/mainline-native-pokemon.json'
        self.fixtures = json.loads(path.read_text(encoding='utf-8'))['fixtures']
        self.requests,self.processes = {},{}
        self.fail = False
        self.invalid = False
        self.cancelled=[]

    def cancel(self,job_id):
        self.cancelled.append(job_id)

    def close(self):
        pass

    def start(self,job_id,payload):
        self.requests[job_id] = copy.deepcopy(payload)

    def poll(self,job_id,nonce):
        request = self.requests[job_id]
        if self.fail:
            return 'result',{'job_id':job_id,'nonce':nonce,'ok':False}
        operation = request['operation']
        if operation=='starter':
            result = copy.deepcopy(self.fixtures['starter_bulbasaur'])
            result['pokemon'][0]['pokemon']['owner'] = dict(request['owner'],language=0)
            if self.invalid:
                result['pokemon'][0]['pokemon']['level'] = 100
        elif operation=='train':
            result = copy.deepcopy(self.fixtures['train'])
            result['pokemon'][0]['pokemon']['owner'] = request['inputs'][0]['pokemon']['owner']
        elif operation=='inspect':
            result = copy.deepcopy(self.fixtures['starter_bulbasaur'])
            result['pokemon'][0]['pokemon'] = copy.deepcopy(request['inputs'][0])
        elif operation in ('breed','equip','use_item','trade_evolve','preview_evolution'):
            full=copy.deepcopy(request['inputs'][0])
            if operation=='equip':full['pokemon']['item']=request['params']['item_id']
            result={'pokemon':[full]}
        else:
            raise RuntimeError('No recorded fixture for operation')
        return 'result',{'job_id':job_id,'nonce':nonce,'ok':True,'result':result}


class MainlineTests(unittest.TestCase):
    call = inventory_tests.InventoryTests.call
    assets = inventory_tests.InventoryTests.assets
    wallet = inventory_tests.InventoryTests.wallet
    inventory = inventory_tests.InventoryTests.inventory

    def setUp(self):
        inventory_tests.InventoryTests.setUp(self)
        self.engine = RecordedEngine()
        self.store.native_engine = self.engine

    def tearDown(self):
        inventory_tests.InventoryTests.tearDown(self)

    def create(self,person=None,name='Native role',finish=True):
        person = person or self.a
        value = self.call(person,'POST','/v1/mainline/characters',dict(name=name,gender=0,starter='BULBASAUR',compatibility=self.compat),201)
        if value['job'] and finish:
            job = self.call(person,'GET','/v1/mainline/jobs/'+value['job']['id'])['job']
            self.assertEqual(job['status'],'completed',job)
        return self.call(person,'GET','/v1/mainline/characters/'+value['character']['id'])['character'] if finish else value

    def candy(self):
        with self.store.connect() as db:
            self.store.trading_grant(db,self.a['identity']['id'],0,[],'extra_native_candy',{'RARECANDY':6})

    def queue_train(self,character):
        return self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation='train',asset_ids=[character['party'][0]['id']],params={'count':11},compatibility=self.compat),202)['job']

    def test_starter_and_supplies_are_once_per_account(self):
        first = self.create()
        self.assertEqual(first['party'][0]['snapshot']['level'],5)
        self.assertEqual(self.wallet(self.a)['balance'],201000)
        self.assertEqual(self.inventory(self.a)['quantity'],25)
        self.assertEqual(self.inventory(self.a,'POKEBALL')['quantity'],10)
        second = self.create(name='Another save')
        self.assertEqual(second['party'],[])
        self.assertEqual(self.wallet(self.a)['balance'],201000)

    def test_native_training_reserves_then_consumes_exact_items(self):
        character = self.create()
        self.candy()
        job = self.queue_train(character)
        with self.store.connect() as db:
            self.assertEqual(self.store.item_balance(db,self.a['identity']['id'],'RARECANDY')['reserved'],11)
        result = self.call(self.a,'GET','/v1/mainline/jobs/'+job['id'])['job']
        self.assertEqual(result['status'],'completed')
        current = self.call(self.a,'GET','/v1/mainline/characters/'+character['id'])['character']
        self.assertEqual(current['party'][0]['snapshot']['level'],16)
        self.assertEqual(self.inventory(self.a,'RARECANDY')['quantity'],0)
        again = self.call(self.a,'GET','/v1/mainline/jobs/'+job['id'])['job']
        self.assertEqual(again,result)

    def test_declined_native_result_returns_reservations_without_changes(self):
        character = self.create()
        self.candy()
        job = self.queue_train(character)
        self.engine.fail = True
        result = self.call(self.a,'GET','/v1/mainline/jobs/'+job['id'])['job']
        self.assertEqual(result['status'],'failed')
        self.assertIn(job['id'],self.engine.cancelled)
        self.assertEqual(self.inventory(self.a,'RARECANDY')['available'],11)
        self.assertEqual(self.call(self.a,'GET','/v1/mainline/characters/'+character['id'])['character']['party'][0]['snapshot']['level'],5)

    def test_party_assets_cannot_enter_market_or_exchange_pool(self):
        character = self.create()
        asset = character['party'][0]
        self.call(self.a,'POST','/v1/market/listings',dict(asset_id=asset['id'],price=1000,compatibility=self.compat),409)
        values = self.assets(self.a)
        selected = next(value for value in values if value['id']==asset['id'])
        self.assertTrue(selected['locked'])
        self.assertEqual(selected['assigned_character'],character['id'])
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/party',dict(asset_ids=[],revision=character['revision']))
        self.call(self.a,'POST','/v1/market/listings',dict(asset_id=asset['id'],price=1000,compatibility=self.compat),201)

    def test_character_and_job_results_are_owner_only(self):
        value = self.create(finish=False)
        self.call(self.b,'GET','/v1/mainline/characters/'+value['character']['id'],status=404)
        self.call(self.b,'GET','/v1/mainline/jobs/'+value['job']['id'],status=404)

    def test_client_cannot_upload_a_result_or_attributes(self):
        character = self.create()
        before = self.wallet(self.a)['balance']
        self.call(self.a,'POST','/v1/mainline/jobs/job_fake/result',dict(level=100),404)
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation='train',asset_ids=[character['party'][0]['id']],params={'count':1,'level':100},compatibility=self.compat),400)
        self.assertEqual(self.wallet(self.a)['balance'],before)

    def test_incorrect_starter_result_cannot_mint_assets(self):
        self.engine.invalid = True
        value = self.create(finish=False)
        result = self.call(self.a,'GET','/v1/mainline/jobs/'+value['job']['id'])['job']
        self.assertEqual(result['status'],'failed')
        self.assertEqual(len(self.assets(self.a)),3)
        self.assertEqual(self.wallet(self.a)['balance'],200000)

    def test_restart_releases_pending_native_costs(self):
        character = self.create()
        self.candy()
        job = self.queue_train(character)
        self.store.close()
        self.store = Store(self.database,clock=self.clock)
        self.store.catalog_path,self.store.item_catalog_path = self.catalog_path,self.item_catalog
        result = self.call(self.a,'GET','/v1/mainline/jobs/'+job['id'])['job']
        self.assertEqual(result['status'],'failed')
        self.assertEqual(result['error_code'],'server_restart')
        self.assertEqual(self.inventory(self.a,'RARECANDY')['available'],11)

    def test_pc_pagination_returns_refs_without_full_private_graph(self):
        character = self.create()
        status,value = self.store.request('POST','/v1/mainline/characters/'+character['id']+'/pc/search',{},self.a['token'])
        self.assertEqual(status,200,value)
        self.assertEqual(len(value['assets']),4)
        self.assertTrue(all('full' not in asset for asset in value['assets']))

    def operation(self,character,operation,ids=None,params=None):
        job=self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation=operation,asset_ids=ids or [character['party'][0]['id']],params=params or {},compatibility=self.compat),202)['job']
        result=self.call(self.a,'GET','/v1/mainline/jobs/'+job['id'])['job']
        self.assertEqual(result['status'],'completed',result)
        return result

    def test_supplier_price_quantity_and_idempotence(self):
        body=dict(request_id='supplier_repeat',item_id='POTION',quantity=3,unit_price=300,compatibility=self.compat)
        before=self.wallet(self.a)['balance']
        first=self.call(self.a,'POST','/v1/mainline/shop/buy',body)
        self.assertEqual(self.call(self.a,'POST','/v1/mainline/shop/buy',body),first)
        self.assertEqual(self.wallet(self.a)['balance'],before-900)
        self.assertEqual(self.inventory(self.a)['quantity'],23)
        self.call(self.b,'POST','/v1/mainline/shop/buy',body)
        self.assertEqual(self.inventory(self.b)['quantity'],23)
        self.call(self.a,'POST','/v1/mainline/shop/buy',dict(item_id='POTION',quantity=1,unit_price=1,compatibility=self.compat),409)
        self.call(self.a,'POST','/v1/mainline/shop/buy',dict(item_id='MASTERBALL',quantity=1,unit_price=1,compatibility=self.compat),409)

    def test_field_consumption_cannot_spend_reserved_items(self):
        character=self.create();self.candy();self.queue_train(character)
        # Keep the native response pending so the hold is authoritative.
        original=self.engine.poll;self.engine.poll=lambda *args:('waiting',None)
        self.call(self.a,'POST','/v1/mainline/inventory/consume',dict(item_id='RARECANDY',quantity=1),409)
        self.assertEqual(self.inventory(self.a,'RARECANDY')['quantity'],11)
        self.engine.poll=original

    def test_equipment_moves_one_inventory_unit_and_returns_it(self):
        character=self.create();asset=character['party'][0]['id']
        before=self.inventory(self.a)['quantity']
        self.operation(character,'equip',params={'item_id':'POTION'})
        self.assertEqual(self.inventory(self.a)['quantity'],before-1)
        with self.store.connect() as db:
            self.assertEqual(self.store.item_balance(db,'asset:'+asset,'POTION')['quantity'],1)
        self.operation(character,'equip',params={'item_id':None})
        self.assertEqual(self.inventory(self.a)['quantity'],before)
        with self.store.connect() as db:self.assertTrue(self.store.economy_audit(db)['ok'])

    def test_egg_is_private_and_hatches_only_once_after_server_time(self):
        character=self.create();first=character['party'][0]['id']
        second=next(asset['id'] for asset in self.assets(self.a) if asset['id']!=first)
        job=self.operation(character,'breed',[first,second])
        egg_id=job['result']['egg_id']
        eggs=self.call(self.a,'GET','/v1/mainline/eggs')['eggs']
        self.assertNotIn('full',eggs[0])
        self.call(self.a,'POST','/v1/mainline/eggs/'+egg_id+'/hatch',{},409)
        self.call(self.b,'POST','/v1/mainline/eggs/'+egg_id+'/hatch',{},404)
        count=len(self.assets(self.a));self.clock.advance(300)
        hatched=self.call(self.a,'POST','/v1/mainline/eggs/'+egg_id+'/hatch',{})['egg']
        again=self.call(self.a,'POST','/v1/mainline/eggs/'+egg_id+'/hatch',{})['egg']
        self.assertEqual(hatched,again);self.assertEqual(len(self.assets(self.a)),count+1)

    def test_pending_reward_credit_is_partial_bounded_and_once(self):
        owner=self.a['identity']['id']
        with self.store.connect() as db:
            amount=9_999_999_999-self.store.wallet(db,owner)['balance']-40
            self.store.post_money(db,'credit_cap','fixture',{owner:amount,'system:issuer':-amount},{})
            self.store.post_money(db,'pending_reward','fixture',{'system:pending':100,'system:issuer':-100},{})
            db.execute('INSERT INTO ml_credits VALUES(?,?,?)',(owner,'pending_reward',100))
        claimed=self.call(self.a,'POST','/v1/mainline/credits/claim',{})
        self.assertEqual(claimed['claimed'],40)
        self.assertEqual(self.call(self.a,'GET','/v1/mainline/credits')['pending'],60)
        self.assertEqual(self.call(self.a,'POST','/v1/mainline/credits/claim',{})['claimed'],0)

    def test_trade_evolution_event_is_unique_and_locks_received_asset(self):
        character=self.create();asset=character['party'][0]
        preview=self.operation(character,'preview_evolution',params={'method':'trade'})
        self.assertEqual(preview['result']['asset_ids'],[])
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation='evolve',asset_ids=[asset['id']],params={'method':'trade'},compatibility=self.compat),400)
        character=self.call(self.a,'GET','/v1/mainline/characters/'+character['id'])['character']
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/party',dict(asset_ids=[],revision=character['revision']))
        owner=self.a['identity']['id']
        with self.store.connect() as db:
            self.store.queue_trade_evolution(db,'unique_trade',asset['id'],owner)
            self.store.queue_trade_evolution(db,'unique_trade',asset['id'],owner)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM ml_trade_evolutions').fetchone()[0],1)
            self.assertTrue(self.store.refresh_asset_lock(db,asset['id']))
            self.store.tick_mainline_jobs(db);self.store.tick_mainline_jobs(db)
            self.assertEqual(db.execute('SELECT status FROM ml_trade_evolutions').fetchone()[0],'completed')
            self.assertEqual(db.execute("SELECT COUNT(*) FROM ml_jobs WHERE operation='trade_evolve'").fetchone()[0],1)
            self.assertFalse(self.store.refresh_asset_lock(db,asset['id']))

    def test_release_checks_current_version_party_and_returns_attachment(self):
        character=self.create();asset=character['party'][0]
        path='/v1/mainline/assets/'+asset['id']+'/release'
        self.call(self.a,'POST',path,{'version':1},409)
        self.call(self.b,'POST',path,{'version':1},403)
        self.operation(character,'equip',params={'item_id':'POTION'})
        character=self.call(self.a,'GET','/v1/mainline/characters/'+character['id'])['character']
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/party',dict(asset_ids=[],revision=character['revision']))
        self.call(self.a,'POST',path,{'version':1},409)
        body=dict(request_id='release_once',version=2)
        before=self.inventory(self.a)['quantity']
        first=self.call(self.a,'POST',path,body)
        self.assertEqual(first,self.call(self.a,'POST',path,body))
        self.assertEqual(self.inventory(self.a)['quantity'],before+1)
        self.assertFalse(any(value['id']==asset['id'] for value in self.assets(self.a)))
        with self.store.connect() as db:self.assertTrue(self.store.economy_audit(db)['ok'])


if __name__=='__main__':
    unittest.main()
