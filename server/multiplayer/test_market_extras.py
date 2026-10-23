"""Real Store transactions: partial fills, discovery, attachment mail and replay."""
import copy,json,secrets,unittest
from concurrent.futures import ThreadPoolExecutor
import test_inventory as base

class ExtrasTests(unittest.TestCase):
    call=base.InventoryTests.call
    assets=base.InventoryTests.assets
    wallet=base.InventoryTests.wallet
    inventory=base.InventoryTests.inventory
    ilisting=base.InventoryTests.ilisting
    listing=base.InventoryTests.listing
    buy=base.InventoryTests.buy
    def setUp(self):base.InventoryTests.setUp(self)
    def tearDown(self):base.InventoryTests.tearDown(self)
    def partial(self,listing,quantity,person=None,**extra):
        return self.call(person or self.b,'POST','/v1/market/listings/'+listing['id']+'/buy',dict(quantity=quantity,price=quantity*listing['unit_price'],revision=listing['revision'],compatibility=self.compat,**extra))
    def send(self,**extra):
        return self.call(self.a,'POST','/v1/market/mail',dict(friend_code=self.b['identity']['friend_code'],subject='礼物',text='测试正文',compatibility=self.compat,**extra),201)['mail']
    def saved(self,person=None,**extra):
        return self.call(person or self.b,'POST','/v1/market/saved-searches',dict(name='伤药降价',query=dict(filters=dict(category='item',item_id='POTION',max_price=1000)),alerts=True,**extra),201)['search']
    def test_partial_fills_and_remaining_cancel_conserve_quantities(self):
        listing=self.ilisting(quantity=10,unit_price=100);fee=self.wallet(self.a)['balance']
        order=self.partial(listing,3);self.assertEqual(order['order']['price'],300)
        current=self.call(self.b,'GET','/v1/market/listings/'+listing['id'])['listing']
        self.assertEqual((current['quantity'],current['price'],current['revision']),(7,700,2))
        self.assertEqual(self.inventory(self.a)['reserved'],7)
        self.assertEqual(self.call(self.e,'POST','/v1/market/search',dict(filters=dict(category='item',max_price=750)))['listings'][0]['id'],listing['id'])
        self.partial(current,2,self.e)
        returned=self.call(self.a,'POST','/v1/market/listings/'+listing['id']+'/cancel')['listing']
        self.assertEqual(returned['quantity'],5)
        self.assertEqual(self.wallet(self.a)['balance'],fee+500)
        self.assertEqual(self.inventory(self.a)['quantity'],15)
        self.assertEqual(self.inventory(self.b)['quantity'],23)
        self.assertEqual(self.inventory(self.e)['quantity'],22)
    def test_partial_fill_replay_and_stale_revision(self):
        listing=self.ilisting();request='partial_same_request'
        first=self.partial(listing,2,request_id=request)
        self.assertEqual(self.partial(listing,2,request_id=request),first)
        self.call(self.e,'POST','/v1/market/listings/'+listing['id']+'/buy',dict(quantity=1,price=400,revision=listing['revision'],compatibility=self.compat),409)
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM market_orders').fetchone()[0],1)
    def test_concurrent_buyers_do_not_oversell_partial_stock(self):
        listing=self.ilisting(quantity=5)
        def buy(person):return self.store.request('POST','/v1/market/listings/'+listing['id']+'/buy',dict(request_id=secrets.token_hex(16),quantity=4,price=1600,revision=listing['revision'],compatibility=self.compat),person['token'])[0]
        with ThreadPoolExecutor(2) as pool:self.assertEqual(sorted(pool.map(buy,[self.b,self.e])),[200,409])
        self.assertEqual(self.inventory(self.a)['quantity'],16)
    def test_saved_search_notifications_are_durable_deduplicated_and_private(self):
        saved=self.saved();listing=self.ilisting(quantity=1)
        notes=self.call(self.b,'GET','/v1/market/notifications')['notifications']
        self.assertEqual(notes[0]['data']['listing_id'],listing['id'])
        with self.store.connect() as db:self.store.market_alerts(db,listing)
        self.assertEqual(len(self.call(self.b,'GET','/v1/market/notifications')['notifications']),1)
        self.call(self.a,'POST','/v1/market/notifications/'+notes[0]['id'],{},404)
        self.call(self.b,'POST','/v1/market/notifications/'+notes[0]['id'])
        self.assertEqual(self.call(self.b,'GET','/v1/market/notifications')['unread'],0)
        self.call(self.b,'POST','/v1/market/saved-searches/'+saved['id'],{'alerts':False})
        self.ilisting(quantity=1)
        self.assertEqual(len(self.call(self.b,'GET','/v1/market/notifications')['notifications']),1)
    def test_saved_search_filters_are_validated_and_ownership_checked(self):
        self.call(self.b,'POST','/v1/market/saved-searches',dict(name='bad',query=dict(filters=dict(min_level=999)),alerts=True),400)
        saved=self.saved()
        self.call(self.e,'POST','/v1/market/saved-searches/'+saved['id'],{'delete':True},404)
        self.call(self.b,'POST','/v1/market/saved-searches/'+saved['id'],{'delete':True})
        self.assertEqual(self.call(self.b,'GET','/v1/market/saved-searches')['searches'],[])
    def test_history_counts_fills_as_executed_units_and_excludes_reciprocal_pairs(self):
        listing=self.ilisting(quantity=10,unit_price=100)
        self.partial(listing,2)
        current=self.call(self.b,'GET','/v1/market/listings/'+listing['id'])['listing']
        self.partial(current,3,self.e)
        history=self.call(self.b,'POST','/v1/market/history',dict(kind='item',key='POTION'))
        self.assertEqual(history['history'][0]['quantity'],5);self.assertFalse(history['sufficient_sample'])
        reverse=self.ilisting(self.b,quantity=1,unit_price=9999);self.buy(reverse,self.a)
        history=self.call(self.b,'POST','/v1/market/history',dict(kind='item',key='POTION'))
        self.assertEqual(history['trades'],1);self.assertEqual(history['history'][0]['quantity'],3)
    def test_mail_claim_is_atomic_and_historical_replay_does_not_duplicate(self):
        asset=self.assets(self.a)[0];mail=self.send(asset_ids=[asset['id']],items={'POTION':3},coins=700)
        self.assertEqual(self.wallet(self.a)['reserved'],700)
        path='/v1/market/mail/'+mail['id']+'/claim'
        first=self.call(self.b,'POST',path);self.call(self.b,'POST',path)
        self.assertEqual(self.wallet(self.b)['balance'],200700)
        self.assertEqual(self.inventory(self.b)['quantity'],23)
        self.assertIn(asset['id'],[a['id'] for a in self.assets(self.b)])
        self.assertEqual(len(first['mail']['delivery_ids']),2)
        self.call(self.a,'POST','/v1/market/mail/'+mail['id']+'/cancel',{},409)
    def test_mail_cancel_reject_expiry_and_foreign_access(self):
        asset=self.assets(self.a)[0];mail=self.send(asset_ids=[asset['id']],items={'POTION':2},coins=50)
        self.call(self.e,'POST','/v1/market/mail/'+mail['id']+'/claim',{},404)
        self.call(self.b,'POST','/v1/market/mail/'+mail['id']+'/reject')
        self.assertEqual(self.wallet(self.a)['reserved'],0)
        self.assertIn(asset['id'],[a['id'] for a in self.assets(self.a)])
        second=self.send(coins=70);self.clock.advance(31*86400)
        # Authentication tokens expire before this long activity window.
        with self.store.connect() as db:self.store.tick_market_extras(db)
        with self.store.connect() as db:
            value=json.loads(db.execute('SELECT document FROM market_mail WHERE id=?',(second['id'],)).fetchone()[0])
            self.assertEqual(value['status'],'expired');self.assertEqual(self.store.wallet(db,self.a['identity']['id'])['reserved'],0)
    def test_mail_competes_for_the_same_assets_and_funds(self):
        asset=self.assets(self.a)[0];mail=self.send(asset_ids=[asset['id']],coins=199999)
        self.call(self.a,'POST','/v1/market/listings',dict(asset_id=asset['id'],price=1000,compatibility=self.compat),409)
        self.call(self.a,'POST','/v1/market/mail',dict(friend_code=self.e['identity']['friend_code'],subject='重复',text='',coins=2,compatibility=self.compat),409)
        self.assertEqual(len(self.call(self.e,'GET','/v1/market/mail')['mail']),0)
    def test_partial_failure_after_debit_rolls_back_funds_stock_holds_and_order(self):
        listing=self.ilisting(quantity=5);before=self.wallet(self.b)['balance'];original=self.store.new_item_delivery
        def fail(*args,**kwargs):raise RuntimeError('injected delivery failure')
        self.store.new_item_delivery=fail
        try:
            with self.assertRaises(RuntimeError):self.partial(listing,2)
        finally:self.store.new_item_delivery=original
        self.assertEqual(self.wallet(self.b)['balance'],before);self.assertEqual(self.inventory(self.a)['reserved'],5)
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM market_orders').fetchone()[0],0)
        self.partial(listing,2)
    def test_history_sample_gate_requires_distinct_sellers_and_buyers(self):
        buyers=[]
        for index in range(3):
            status,person=self.store.request('POST','/v1/auth/register',dict(username='history_buyer_'+str(index),password='testpassword123',protocol=2))
            self.assertEqual(status,201);buyers.append(person)
            with self.store.connect() as db:self.store.trading_grant(db,person['identity']['id'],10000,[],'history_buyer_grant_'+str(index))
        for seller,buyer in [(self.a,buyers[0]),(self.b,buyers[1]),(self.e,buyers[2]),(self.a,buyers[1]),(self.b,buyers[2])]:
            self.buy(self.ilisting(seller,quantity=1,unit_price=500),buyer)
        result=self.call(self.a,'POST','/v1/market/history',dict(kind='item',key='POTION'))
        self.assertTrue(result['sufficient_sample']);self.assertEqual(result['trades'],5)
    def test_history_read_does_not_write_operation_and_read_all_is_owner_scoped(self):
        self.saved();self.ilisting(quantity=1)
        with self.store.connect() as db:before=db.execute('SELECT COUNT(*) FROM operations').fetchone()[0]
        self.call(self.b,'POST','/v1/market/history',dict(kind='item',key='POTION'))
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM operations').fetchone()[0],before)
        self.call(self.e,'POST','/v1/market/notifications/read-all')
        self.assertEqual(self.call(self.b,'GET','/v1/market/notifications')['unread'],1)
        self.call(self.b,'POST','/v1/market/notifications/read-all')
        self.assertEqual(self.call(self.b,'GET','/v1/market/notifications')['unread'],0)
    def test_pending_mail_capacity_keeps_every_accepted_attachment_reachable(self):
        mail=self.send()
        with self.store.connect() as db:
            for index in range(99):
                value=copy.deepcopy(mail);value.update(id='mail_capacity_'+str(index),created_at=self.clock()-3601)
                self.store.market_save_mail(db,value)
        self.call(self.a,'POST','/v1/market/mail',dict(friend_code=self.b['identity']['friend_code'],subject='满箱',text='',coins=1000,compatibility=self.compat),409)
        self.assertEqual(len(self.call(self.b,'GET','/v1/market/mail')['mail']),100)
        self.call(self.b,'POST','/v1/market/mail/'+mail['id']+'/claim')
        self.send()
        pending=[value for value in self.call(self.b,'GET','/v1/market/mail')['mail'] if value['status']=='pending']
        self.assertEqual(len(pending),100)

if __name__=='__main__':unittest.main()
