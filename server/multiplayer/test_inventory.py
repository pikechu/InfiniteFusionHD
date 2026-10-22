"""Item conservation, mixed barter, semantic upgrades and trade discovery."""
import copy
import json
import secrets
import unittest
from concurrent.futures import ThreadPoolExecutor

import test_trading as trading_tests


class InventoryTests(unittest.TestCase):
    call = trading_tests.TradingTests.call
    assets = trading_tests.TradingTests.assets
    wallet = trading_tests.TradingTests.wallet
    listing = trading_tests.TradingTests.listing
    buy = trading_tests.TradingTests.buy
    exchange = trading_tests.TradingTests.exchange
    action = trading_tests.TradingTests.action
    offer = trading_tests.TradingTests.offer
    locked = trading_tests.TradingTests.locked

    def setUp(self):
        trading_tests.TradingTests.setUp(self)
        self.item_catalog = self.database.with_suffix('.items.json')
        items = [dict(id=item_id,name=item_id,tradeable=True,price=price,pocket=1) for item_id,price in [('POTION',300),('RARECANDY',4800),('FIRESTONE',2100)]]
        self.item_catalog.write_text(json.dumps(dict(version=1,compatibility=self.compat,items=items)),encoding='utf-8')
        self.store.item_catalog_path = self.item_catalog
        for i,person in enumerate(self.people):
            with self.store.lock,self.store.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                self.store.trading_grant(db,person['identity']['id'],0,[],'items_fixture_%d'%i,{'POTION':20,'RARECANDY':5})

    def tearDown(self):
        try:
            trading_tests.TradingTests.tearDown(self)
        finally:
            self.item_catalog.unlink(missing_ok=True)
            self.database.with_suffix('.history.json').unlink(missing_ok=True)

    def inventory(self,person=None,item_id='POTION'):
        values = self.call(person or self.a,'GET','/v1/inventory')['inventory']['items']
        return next((v for v in values if v['item_id']==item_id),dict(quantity=0,reserved=0,available=0))

    def ilisting(self,person=None,quantity=5,unit_price=400,item_id='POTION'):
        return self.call(person or self.a,'POST','/v1/market/listings',dict(kind='item',item_id=item_id,quantity=quantity,unit_price=unit_price,compatibility=self.compat),201)['listing']

    def mixed_offer(self,person,session,items,assets=(),amount=0):
        return self.action(person,session,'offer',revision=session['revision'],asset_ids=[a['id'] for a in assets],amount=amount,items=items)

    def finish(self,session):
        session = self.locked(session)
        self.clock.advance(3)
        session = self.action(self.a,session,'confirm')
        return self.action(self.b,session,'confirm')

    def switch_build(self,mechanics=False):
        catalog = json.loads(self.catalog_path.read_text())
        self.compat = dict(self.compat,data_hash='updated-ui-build')
        catalog['compatibility'] = self.compat
        if mechanics:
            catalog['data_files'] = {'Data/species.dat':'f'*64}
        self.catalog_path.write_text(json.dumps(catalog),encoding='utf-8')
        items = json.loads(self.item_catalog.read_text())
        items['compatibility'] = self.compat
        self.item_catalog.write_text(json.dumps(items),encoding='utf-8')

    def test_item_listing_purchase_claim_and_conservation(self):
        listing = self.ilisting()
        self.assertEqual((listing['unit_price'],listing['quantity'],listing['price']),(400,5,2000))
        self.assertEqual(self.inventory()['available'],15)
        result = self.buy(listing)
        self.assertEqual(self.inventory()['quantity'],15)
        self.assertEqual(self.inventory(self.b)['quantity'],25)
        self.assertEqual(self.inventory(self.b)['available'],20)
        self.assertEqual(self.inventory(self.b)['reserved'],5)
        self.call(self.b,'POST','/v1/deliveries/'+result['delivery']['id']+'/claim')
        self.call(self.b,'POST','/v1/deliveries/'+result['delivery']['id']+'/claim')
        self.assertEqual(self.inventory(self.b)['available'],25)
        self.assertEqual(sum(self.inventory(p)['quantity'] for p in self.people),60)
        self.assertEqual(self.wallet(self.a)['balance'],201900)
        self.assertEqual(self.wallet(self.b)['balance'],198000)

    def test_item_search_is_separate_from_pokemon(self):
        item = self.ilisting()
        pokemon = self.listing()
        normal = self.call(self.b,'POST','/v1/market/search',{})['listings']
        self.assertEqual([v['id'] for v in normal],[pokemon['id']])
        values = self.call(self.b,'POST','/v1/market/search',dict(filters=dict(category='item',item_id='POTION')))['listings']
        self.assertEqual([v['id'] for v in values],[item['id']])

    def test_item_holds_block_parallel_listing_and_barter(self):
        self.ilisting(quantity=18)
        session = self.exchange()
        self.call(self.a,'POST','/v1/exchanges/'+session['id']+'/offer',dict(revision=session['revision'],asset_ids=[],amount=0,items={'POTION':3}),409)
        self.call(self.a,'POST','/v1/market/listings',dict(kind='item',item_id='POTION',quantity=3,unit_price=1,compatibility=self.compat),409)
        self.assertEqual(self.inventory()['reserved'],18)

    def test_mixed_assets_items_and_money_settle_once(self):
        first,second = self.assets(self.a)[0],self.assets(self.b)[0]
        session = self.mixed_offer(self.a,self.exchange(),{'POTION':7},[first],20000)
        session = self.mixed_offer(self.b,session,{'POTION':2,'RARECANDY':1},[second],5000)
        result = self.finish(session)
        self.assertEqual(result['status'],'committed')
        self.assertEqual(self.inventory()['quantity'],15)
        self.assertEqual(self.inventory(self.b)['quantity'],25)
        self.assertEqual(self.inventory(item_id='RARECANDY')['quantity'],6)
        self.assertEqual(self.wallet(self.a)['balance'],185000)
        self.assertEqual(self.wallet(self.b)['balance'],215000)
        self.assertEqual(self.inventory()['reserved'],0)
        self.assertIn(first['id'],[a['id'] for a in self.assets(self.b)])

    def test_item_only_gift_and_old_delivery_cannot_reissue_spent_items(self):
        result = self.buy(self.ilisting())
        claim = '/v1/deliveries/'+result['delivery']['id']+'/claim'
        self.call(self.b,'POST',claim)
        session = self.mixed_offer(self.b,self.exchange(),{'POTION':25})
        self.finish(session)
        self.assertEqual(self.inventory(self.b)['quantity'],0)
        self.call(self.b,'POST',claim)
        self.assertEqual(self.inventory(self.b)['quantity'],0)
        self.assertEqual(self.inventory()['quantity'],40)

    def test_cancel_removed_item_still_returns_existing_quantity(self):
        listing = self.ilisting(quantity=10)
        catalog = json.loads(self.item_catalog.read_text())
        catalog['items'] = [i for i in catalog['items'] if i['id']!='POTION']
        self.item_catalog.write_text(json.dumps(catalog),encoding='utf-8')
        returned = self.call(self.a,'POST','/v1/market/listings/'+listing['id']+'/cancel')['listing']
        self.call(self.a,'POST','/v1/deliveries/'+returned['delivery_id']+'/claim')
        value = self.inventory()
        self.assertEqual(value['available'],20)
        self.assertFalse(value['item']['tradeable'])

    def test_item_purchase_fault_rolls_back_coins_and_counts(self):
        listing = self.ilisting()
        original = self.store.new_item_delivery
        def fail(*args):
            original(*args)
            raise RuntimeError('item delivery fault')
        self.store.new_item_delivery = fail
        with self.assertRaisesRegex(RuntimeError,'item delivery fault'):
            self.buy(listing,request_id='retry_atomic_item_order')
        self.store.new_item_delivery = original
        self.assertEqual(self.inventory()['quantity'],20)
        self.assertEqual(self.inventory(self.b)['quantity'],20)
        self.assertEqual(self.wallet(self.b)['balance'],200000)
        self.buy(listing,request_id='retry_atomic_item_order')

    def test_two_item_buyers_create_one_order(self):
        listing = self.ilisting(quantity=20)
        def buy(person):
            return self.store.request('POST','/v1/market/listings/'+listing['id']+'/buy',dict(price=listing['price'],revision=1,compatibility=self.compat,request_id='item_race_'+person['identity']['id']),person['token'])
        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(buy,[self.b,self.e]))
        self.assertEqual(sorted(v[0] for v in results),[200,409])
        self.assertEqual(sum(self.inventory(p)['quantity'] for p in self.people),60)

    def test_item_changed_offer_resets_confirmations(self):
        session = self.mixed_offer(self.a,self.exchange(),{'POTION':2})
        locked = self.locked(session)
        changed = self.mixed_offer(self.a,locked,{'POTION':3})
        self.assertEqual(changed['locked'],[])
        self.assertEqual(self.inventory()['reserved'],3)
        self.action(self.a,changed,'cancel')
        self.assertEqual(self.inventory()['reserved'],0)

    def test_item_validation_and_no_local_bag_import(self):
        for quantity in (True,-1,0,1.5,10000):
            self.call(self.a,'POST','/v1/market/listings',dict(kind='item',item_id='POTION',quantity=quantity,unit_price=1,compatibility=self.compat),400)
        self.call(self.a,'POST','/v1/market/listings',dict(kind='item',item_id='BICYCLE',quantity=1,unit_price=1,compatibility=self.compat),409)
        self.call(self.a,'POST','/v1/inventory',dict(items={'POTION':9999}),404)
        self.assertEqual(self.inventory()['quantity'],20)

    def test_cosmetic_build_updates_preserve_existing_asset_and_listing(self):
        listing = self.listing()
        self.switch_build()
        current = self.call(self.a,'GET','/v1/market/listings/'+listing['id'])['listing']
        self.assertEqual(current['revision'],2)
        self.assertEqual(current['snapshot'],listing['snapshot'])
        self.buy(current)

    def test_legacy_asset_uses_trusted_catalog_history_for_rebinding(self):
        old_catalog = json.loads(self.catalog_path.read_text())
        history = self.database.with_suffix('.history.json')
        history.write_text(json.dumps(dict(version=1,catalogs=[old_catalog])),encoding='utf-8')
        self.store.catalog_history_path = history
        asset = self.assets(self.a)[0]
        with self.store.connect() as db:
            raw = self.store.asset(db,asset['id'])
            raw.pop('asset_rules_hash')
            db.execute('UPDATE hosted_assets SET document=? WHERE id=?',(json.dumps(raw),asset['id']))
        self.switch_build()
        listing = self.listing(asset=asset)
        self.assertEqual(listing['asset_id'],asset['id'])
        self.assertEqual(listing['snapshot'],asset['snapshot'])

    def test_mechanics_change_closes_listing_without_losing_asset(self):
        listing = self.listing()
        self.switch_build(mechanics=True)
        current = self.call(self.a,'GET','/v1/market/listings/'+listing['id'])['listing']
        self.assertEqual(current['status'],'cancelled')
        self.assertEqual(current['reason'],'asset_contract_changed')
        self.assertIn(listing['asset_id'],[a['id'] for a in self.assets(self.a)])

    def test_build_update_cancels_uncommitted_mixed_exchange(self):
        session = self.mixed_offer(self.a,self.exchange(),{'POTION':10},amount=20000)
        self.switch_build()
        current = self.call(self.a,'GET','/v1/exchanges/'+session['id'])['exchange']
        self.assertEqual(current['status'],'cancelled')
        self.assertEqual(self.inventory()['reserved'],0)
        self.assertEqual(self.wallet(self.a)['reserved'],0)

    def online(self,person,path,body,status=200):
        actual,response = self.store.request('POST',path,body,person['token'])
        self.assertEqual(actual,status,response)
        return response

    def world(self,person,session,map_id=1,x=4):
        self.online(person,'/v1/world/join',dict(session_id=session,compatibility=self.compat))
        position = dict(map_id=map_id,map_hash='a'*64,width=32,height=32,x=x,y=5,direction=2,character_id=0,moving=False)
        return self.online(person,'/v1/world/sync',dict(session_id=session,seq=1,after=0,position=position))['world']

    def test_nearby_invitation_validates_presence_map_and_distance(self):
        self.world(self.a,'world_session_alice_1234')
        self.world(self.b,'world_session_bob_12345',x=7)
        session = self.call(self.a,'POST','/v1/exchanges',dict(target_id=self.b['identity']['id'],compatibility=self.compat),201)['exchange']
        self.action(self.a,session,'cancel')
        self.clock.advance(21)
        self.call(self.a,'POST','/v1/exchanges',dict(target_id=self.b['identity']['id'],compatibility=self.compat),409)

    def test_trade_channel_crosses_maps_and_listing_card_rechecks_sale(self):
        self.world(self.a,'world_session_alice_1234')
        self.world(self.b,'world_session_bob_12345',map_id=2)
        listing = self.ilisting()
        message = dict(session_id='world_session_alice_1234',client_id='trade_card_'+secrets.token_hex(8),channel='trade',text='Selling Potion',listing_id=listing['id'])
        result = self.online(self.a,'/v1/chat/send',message,201)
        self.assertEqual(result['message']['listing']['id'],listing['id'])
        view = self.online(self.b,'/v1/world/sync',dict(session_id='world_session_bob_12345',seq=2,after=0,position=None))['world']
        self.assertTrue(any(m['channel']=='trade' and m.get('listing',{}).get('id')==listing['id'] for m in view['messages']))
        self.call(self.a,'POST','/v1/market/listings/'+listing['id']+'/cancel')
        self.assertEqual(self.online(self.a,'/v1/chat/send',message)['message']['id'],result['message']['id'])
        changed = dict(message,client_id='trade_card_'+secrets.token_hex(8))
        self.online(self.a,'/v1/chat/send',changed,409)

    def test_restart_keeps_item_purchase_and_claim_reservation(self):
        from service import Store
        result = self.buy(self.ilisting())
        self.store.close()
        self.store = Store(self.database,clock=self.clock)
        self.store.catalog_path,self.store.item_catalog_path = self.catalog_path,self.item_catalog
        self.assertEqual(self.inventory(self.b)['reserved'],5)
        self.call(self.b,'POST','/v1/deliveries/'+result['delivery']['id']+'/claim')
        self.assertEqual(self.inventory(self.b)['available'],25)

    def test_recipient_capacity_rejection_rolls_back_payment(self):
        with self.store.lock,self.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            self.store.trading_grant(db,self.b['identity']['id'],0,[],'capacity_fixture_grant',{'POTION':999_999_979})
        listing = self.ilisting(quantity=1)
        self.call(self.b,'POST','/v1/market/listings/'+listing['id']+'/buy',dict(price=400,revision=1,compatibility=self.compat),409)
        self.assertEqual(self.wallet(self.b)['balance'],200000)
        self.assertEqual(self.inventory(self.b)['quantity'],999_999_999)
        self.assertEqual(self.inventory()['reserved'],1)

    def test_invite_notification_and_blocking_are_recipient_scoped(self):
        self.world(self.a,'world_session_alice_1234')
        self.world(self.b,'world_session_bob_12345')
        invited = self.call(self.a,'POST','/v1/exchanges',dict(friend_code=self.b['identity']['friend_code'],compatibility=self.compat),201)['exchange']
        view = self.online(self.b,'/v1/world/sync',dict(session_id='world_session_bob_12345',seq=2,after=0,position=None))['world']
        self.assertEqual([i['id'] for i in view['trade_invites']],[invited['id']])
        settings = self.call(self.b,'POST','/v1/trading/preferences',dict(block_friend_code=self.a['identity']['friend_code']))['preferences']
        self.assertEqual(len(settings['blocked']),1)
        self.assertEqual(self.call(self.a,'GET','/v1/exchanges/'+invited['id'])['exchange']['status'],'cancelled')
        self.call(self.a,'POST','/v1/exchanges',dict(friend_code=self.b['identity']['friend_code'],compatibility=self.compat),403)
        self.call(self.b,'POST','/v1/trading/preferences',dict(unblock_friend_code=self.a['identity']['friend_code'],allow_friend=False))
        self.call(self.a,'POST','/v1/exchanges',dict(friend_code=self.b['identity']['friend_code'],compatibility=self.compat),403)

    def test_legacy_world_build_never_receives_unsupported_trade_messages(self):
        self.world(self.a,'world_session_alice_1234')
        old_compat = dict(self.compat,data_hash='legacy_world_client')
        self.online(self.b,'/v1/world/join',dict(session_id='legacy_world_session_1234',compatibility=old_compat))
        self.online(self.a,'/v1/chat/send',dict(session_id='world_session_alice_1234',client_id='new_trade_'+secrets.token_hex(8),channel='trade',text='current build trade'),201)
        self.online(self.a,'/v1/chat/send',dict(session_id='world_session_alice_1234',client_id='old_world_'+secrets.token_hex(8),channel='world',text='shared world chat'),201)
        view = self.online(self.b,'/v1/world/sync',dict(session_id='legacy_world_session_1234',seq=1,after=0,position=None))['world']
        self.assertEqual([m['channel'] for m in view['messages']],['world'])
        self.assertEqual(view['trade_invites'],[])


if __name__ == '__main__':
    unittest.main()
