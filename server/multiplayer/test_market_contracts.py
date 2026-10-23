"""Contract funding, racing actions, custody restrictions and expiry recovery."""
import copy,json,secrets,unittest
from concurrent.futures import ThreadPoolExecutor
from service import Store
import test_inventory as base
import test_mainline as mainline_tests

class ContractTests(unittest.TestCase):
    call=base.InventoryTests.call
    assets=base.InventoryTests.assets
    wallet=base.InventoryTests.wallet
    inventory=base.InventoryTests.inventory
    create=mainline_tests.MainlineTests.create
    def setUp(self):base.InventoryTests.setUp(self)
    def tearDown(self):base.InventoryTests.tearDown(self)
    def contract(self,kind,terms,person=None):
        return self.call(person or self.a,'POST','/v1/market/contracts',dict(kind=kind,terms=terms,compatibility=self.compat),201)['contract']
    def action(self,value,action,person=None,status=200,**extra):
        return self.call(person or self.b,'POST','/v1/market/contracts/'+value['id']+'/'+action,dict(revision=value['revision'],compatibility=self.compat,**extra),status)
    def get(self,value,person=None):return self.call(person or self.a,'GET','/v1/market/contracts/'+value['id'])['contract']
    def prepared(self):
        self.store.native_engine=mainline_tests.RecordedEngine();character=self.create(self.a)
        asset=character['party'][0]
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/party',dict(asset_ids=[],revision=character['revision']))
        return asset
    def auction(self,**extra):return self.contract('auction',dict(asset_id=self.assets(self.a)[0]['id'],start_price=1000,increment=100,offer_seconds=120,**extra))
    def loan(self):return self.contract('loan',dict(principal=1000,repayment=1100,duration=3600,filters={'species':'EEVEE'}))
    def test_outbid_releases_only_old_hold_and_expiry_sells_once(self):
        value=self.auction();asset_id=value['bundle']['asset_ids'][0]
        value=self.action(value,'bid',amount=1000)['contract'];self.assertEqual(self.wallet(self.b)['reserved'],1000)
        value=self.action(value,'bid',self.e,amount=1200)['contract']
        self.assertEqual(self.wallet(self.b)['reserved'],0);self.assertEqual(self.wallet(self.e)['reserved'],1200)
        self.action(value,'cancel',self.a,409)
        self.clock.advance(121);closed=self.get(value)
        self.assertEqual(closed['status'],'completed');self.assertEqual(self.wallet(self.e)['balance'],198800)
        self.assertIn(asset_id,[a['id'] for a in self.assets(self.e)])
        self.get(value)
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM market_orders').fetchone()[0],1)
    def test_bid_race_uses_revision_and_anti_sniping_has_hard_deadline(self):
        value=self.auction();self.clock.advance(110)
        def bid(person):return self.store.request('POST','/v1/market/contracts/'+value['id']+'/bid',dict(request_id=secrets.token_hex(16),revision=1,compatibility=self.compat,amount=1000),person['token'])[0]
        with ThreadPoolExecutor(2) as pool:self.assertEqual(sorted(pool.map(bid,[self.b,self.e])),[200,409])
        current=self.get(value);self.assertEqual(current['expires_at'],self.clock()+60)
        self.assertLessEqual(current['expires_at'],value['hard_end'])
    def test_item_auction_and_no_bid_return_keep_stock_reserved(self):
        value=self.contract('auction',dict(item_id='POTION',quantity=3,start_price=600,increment=1,offer_seconds=60))
        self.assertEqual(self.inventory(self.a)['reserved'],3)
        self.action(value,'bid',amount=600);self.clock.advance(61);self.get(value)
        self.assertEqual(self.inventory(self.a)['quantity'],17);self.assertEqual(self.inventory(self.b)['quantity'],23)
        no_bid=self.auction();self.clock.advance(121)
        self.assertEqual(self.get(no_bid)['status'],'expired')
    def test_item_buy_order_is_funded_fills_partially_and_refunds_remainder(self):
        value=self.contract('buy_order',dict(category='item',item_id='POTION',quantity=10,unit_price=200))
        self.assertEqual(self.wallet(self.a)['reserved'],2000)
        value=self.action(value,'fill',quantity=3)['contract']
        self.assertEqual(value['remaining'],7);self.assertEqual(self.wallet(self.a)['reserved'],1400)
        self.assertEqual(self.inventory(self.a)['quantity'],23)
        self.action(value,'cancel',self.a)
        self.assertEqual(self.wallet(self.a)['reserved'],0);self.assertEqual(self.wallet(self.a)['balance'],199300)
    def test_pokemon_order_checks_actual_iv_and_species_not_uploaded_claims(self):
        asset=self.assets(self.b)[0]
        value=self.contract('buy_order',dict(category='pokemon',quantity=1,unit_price=1000,filters=dict(species=asset['snapshot']['species'],iv_exact={'ATTACK':0})))
        self.action(value,'fill',status=409,asset_id=asset['id'])
        self.action(value,'cancel',self.a)
        value=self.contract('buy_order',dict(category='pokemon',quantity=1,unit_price=1000,filters=dict(species=asset['snapshot']['species'],iv_exact={'ATTACK':asset['snapshot']['iv']['ATTACK']})))
        closed=self.action(value,'fill',asset_id=asset['id'])['contract'];self.assertEqual(closed['status'],'completed')
        self.assertIn(asset['id'],[a['id'] for a in self.assets(self.a)])
    def test_loan_repayment_returns_same_collateral_and_default_transfers_it(self):
        value=self.loan();asset=next(a for a in self.assets(self.b) if a['snapshot']['species']=='EEVEE')
        value=self.action(value,'accept',asset_id=asset['id'])['contract']
        self.assertEqual(self.wallet(self.b)['balance'],201000)
        self.action(value,'repay')
        self.assertEqual(self.wallet(self.b)['balance'],199900);self.assertIn(asset['id'],[a['id'] for a in self.assets(self.b)])
    def test_loan_default_uses_preagreed_collateral_without_copying(self):
        value=self.loan();asset=next(a for a in self.assets(self.b) if a['snapshot']['species']=='EEVEE')
        value=self.action(value,'accept',asset_id=asset['id'])['contract'];self.clock.advance(3601)
        self.assertEqual(self.get(value)['status'],'defaulted')
        self.assertIn(asset['id'],[a['id'] for a in self.assets(self.a)]);self.assertNotIn(asset['id'],[a['id'] for a in self.assets(self.b)])
    def test_training_reward_requires_native_attributes_and_returned_identity(self):
        asset=self.prepared();value=self.contract('training',dict(asset_id=asset['id'],duration=3600,bond=500,reward=3000,level=16))
        value=self.action(value,'accept')['contract'];self.action(value,'finish',status=409)
        character=self.create(self.b)
        with self.store.connect() as db:self.store.trading_grant(db,self.b['identity']['id'],0,[],'training_candies',{'RARECANDY':20})
        before=self.wallet(self.b)['balance']
        queued=self.call(self.b,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation='train',asset_ids=[asset['id']],params={'count':11},compatibility=self.compat),202)['job']
        job=self.call(self.b,'GET','/v1/mainline/jobs/'+queued['id'])['job'];self.assertEqual(job['status'],'completed')
        closed=self.action(value,'finish')['contract'];self.assertEqual(closed['status'],'completed')
        self.assertEqual(self.wallet(self.b)['balance'],before+3000);self.assertEqual(self.wallet(self.b)['reserved'],0)
        returned=next(a for a in self.assets(self.a) if a['id']==asset['id']);self.assertEqual(returned['snapshot']['level'],16)
    def test_rental_is_playable_but_cannot_be_sold_released_or_transformed(self):
        asset=self.prepared();value=self.contract('rental',dict(asset_id=asset['id'],duration=3600,bond=500,fee=1000))
        value=self.action(value,'accept')['contract'];character=self.create(self.b)
        self.call(self.b,'POST','/v1/mainline/characters/'+character['id']+'/party',dict(asset_ids=[asset['id']],revision=character['revision']))
        self.call(self.b,'POST','/v1/market/listings',dict(asset_id=asset['id'],price=1000,compatibility=self.compat),409)
        for operation,params in [('train',{'count':1}),('equip',{'item_id':'POTION'}),('breed',{})]:
            self.call(self.b,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation=operation,asset_ids=[asset['id']],params=params,compatibility=self.compat),409)
        self.action(value,'return')
        self.assertEqual(self.wallet(self.b)['reserved'],0)
        current=self.call(self.b,'GET','/v1/mainline/characters/'+character['id'])['character'];self.assertEqual(current['party'],[])
        self.assertIn(asset['id'],[a['id'] for a in self.assets(self.a)])
    def test_expiry_cancels_unsettled_native_job_before_return(self):
        asset=self.prepared();value=self.contract('training',dict(asset_id=asset['id'],duration=3600,bond=500,reward=3000,level=16))
        value=self.action(value,'accept')['contract'];character=self.create(self.b)
        queued=self.call(self.b,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation='train',asset_ids=[asset['id']],params={'count':1},compatibility=self.compat),202)['job']
        self.clock.advance(3601);self.get(value)
        job=self.call(self.b,'GET','/v1/mainline/jobs/'+queued['id'])['job']
        self.assertEqual(job['status'],'failed');self.assertEqual(job['error_code'],'contract_ended')
        self.assertIn(asset['id'],[a['id'] for a in self.assets(self.a)])
    def test_contract_holds_and_highest_bid_survive_restart(self):
        value=self.auction();value=self.action(value,'bid',amount=1500)['contract']
        self.store.close();self.store=Store(self.database,clock=self.clock,synchronous='FULL');self.store.catalog_path=self.catalog_path;self.store.item_catalog_path=self.item_catalog
        self.assertEqual(self.wallet(self.b)['reserved'],1500);self.assertEqual(self.get(value)['bid'],1500)
        self.clock.advance(121);self.assertEqual(self.get(value)['status'],'completed')
    def test_auction_overflow_is_payable_and_claim_is_capacity_bounded(self):
        value=self.auction();value=self.action(value,'bid',amount=1000)['contract']
        with self.store.connect() as db:self.store.trading_grant(db,self.a['identity']['id'],9_999_999_999-self.wallet(self.a)['balance'],[],'fill_wallet_before_auction')
        self.clock.advance(121);self.get(value)
        self.assertEqual(self.call(self.a,'GET','/v1/market/cash')['cash'],1000)
        base.InventoryTests.ilisting(self,quantity=1,unit_price=100)
        result=self.call(self.a,'POST','/v1/market/cash')
        self.assertEqual(result['cash'],900);self.assertEqual(result['wallet']['balance'],9_999_999_999)
    def test_training_timeout_penalty_and_funded_order_cancel_survive_restart(self):
        asset=self.prepared();value=self.contract('training',dict(asset_id=asset['id'],duration=3600,bond=500,reward=3000,level=16))
        value=self.action(value,'accept')['contract'];before=self.wallet(self.b)['balance']
        self.store.close();self.store=Store(self.database,clock=self.clock,synchronous='FULL');self.store.catalog_path=self.catalog_path;self.store.item_catalog_path=self.item_catalog
        self.clock.advance(3601);self.get(value)
        self.assertEqual(self.wallet(self.b)['balance'],before-500);self.assertEqual(self.wallet(self.a)['reserved'],0)
        self.assertIn(asset['id'],[a['id'] for a in self.assets(self.a)])
    def test_foreign_contract_mutations_and_forged_results_are_rejected(self):
        value=self.auction();self.action(value,'cancel',self.b,409)
        self.call(self.b,'POST','/v1/market/contracts/'+value['id']+'/bid',dict(revision=1,compatibility=self.compat,amount=1000,result={'won':True}),400)
        loan=self.loan();self.action(loan,'accept',status=400,asset_id=self.assets(self.b)[0]['id'],principal=999999)
    def test_nonobject_native_parameters_are_rejected_before_custody_checks(self):
        asset=self.prepared();character=self.call(self.a,'GET','/v1/mainline/characters')['characters'][0]
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation='ev',asset_ids=[asset['id']],params=[],compatibility=self.compat),400)
    def test_custody_publication_and_acceptance_require_native_runtime(self):
        asset=self.prepared();value=self.contract('rental',dict(asset_id=asset['id'],duration=3600,bond=500,fee=1000))
        engine=self.store.native_engine;self.store.native_engine=None
        try:
            self.action(value,'accept',status=409)
            self.call(self.a,'POST','/v1/market/contracts',dict(kind='training',terms=dict(asset_id=asset['id'],duration=3600,bond=500,reward=1000,level=6),compatibility=self.compat),409)
            self.assertEqual(self.wallet(self.b)['reserved'],0)
            self.action(value,'cancel',self.a)
        finally:self.store.native_engine=engine

if __name__=='__main__':unittest.main()
