"""Trading transactions, cross-feature locks, races, HTTP and restart recovery."""
import copy
import json
import secrets
import threading
import unittest
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from service import Store, make_server, PROTOCOL, RULES
from test_service import FakeClock, pokemon


class TradingTests(unittest.TestCase):
    def setUp(self):
        self.database = Path(__file__).parent / 'data/tests' / ('trading_' + secrets.token_hex(12) + '.sqlite3')
        self.clock = FakeClock()
        self.store = Store(self.database, clock=self.clock, synchronous='FULL')
        self.compat = dict(protocol=PROTOCOL, game_version='test', data_hash='trading-test', mods_hash='none', rules_version=RULES)
        self.catalog_path = self.database.with_suffix('.catalog.json')
        templates = [pokemon(species) for species in ('PIKACHU', 'EEVEE', 'B25H133', 'B133H25') * 3]
        for i, snapshot in enumerate(templates):
            snapshot['personal_id'] += i
            snapshot['level'] = 20 + i
        self.catalog_path.write_text(json.dumps(dict(version=1, compatibility=self.compat, pokemon=templates)), encoding='utf-8')
        self.store.catalog_path = self.catalog_path
        self.people = []
        for name in ('alice', 'bob', 'eve'):
            status, person = self.store.request('POST', '/v1/auth/register', dict(username=name, password='testpassword123', protocol=PROTOCOL))
            self.assertEqual(status, 201, person)
            self.people.append(person)
        self.a, self.b, self.e = self.people
        for i, person in enumerate(self.people):
            with self.store.lock, self.store.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                self.store.trading_grant(db, person['identity']['id'], 200000, [i, i + 3, i + 6], 'fixture_grant_' + str(i))

    def tearDown(self):
        with self.store.connect() as db:
            self.assertTrue(self.store.economy_audit(db)['ok'])
        self.store.close()
        for suffix in ('', '-wal', '-shm'):
            Path(str(self.database) + suffix).unlink(missing_ok=True)
        self.catalog_path.unlink(missing_ok=True)

    def call(self, person, method, path, body=None, status=200):
        body = copy.deepcopy(body or {})
        if method == 'POST' and path != '/v1/market/search':
            body.setdefault('request_id', 'trading_' + secrets.token_hex(16))
        result_status, result = self.store.request(method, path, body, person['token'])
        self.assertEqual(result_status, status, result)
        return result

    def assets(self, person):
        return self.call(person, 'GET', '/v1/collections')['assets']

    def wallet(self, person):
        return self.call(person, 'GET', '/v1/wallet')['wallet']

    def listing(self, person=None, price=50000, asset=None):
        person = person or self.a
        return self.call(person, 'POST', '/v1/market/listings', dict(asset_id=(asset or self.assets(person)[0])['id'], price=price, compatibility=self.compat), 201)['listing']

    def buy(self, listing, person=None, **extra):
        return self.call(person or self.b, 'POST', '/v1/market/listings/' + listing['id'] + '/buy', dict(price=listing['price'], revision=listing['revision'], compatibility=self.compat, **extra))

    def exchange(self):
        session = self.call(self.a, 'POST', '/v1/exchanges', dict(friend_code=self.b['identity']['friend_code'], compatibility=self.compat), 201)['exchange']
        return self.call(self.b, 'POST', '/v1/exchanges/' + session['id'] + '/accept', dict(compatibility=self.compat))['exchange']

    def action(self, person, session, action, **extra):
        payload = dict(revision=session['revision'], offer_hash=session['offer_hash']) if action in ('lock', 'confirm') else {}
        payload.update(extra)
        return self.call(person, 'POST', '/v1/exchanges/' + session['id'] + '/' + action, payload)['exchange']

    def offer(self, person, session, assets=(), amount=0):
        return self.action(person, session, 'offer', revision=session['revision'], asset_ids=[asset['id'] for asset in assets], amount=amount)

    def locked(self, session):
        session = self.action(self.a, session, 'lock')
        return self.action(self.b, session, 'lock')

    def test_listing_buy_claim_and_old_receipt_after_transfer(self):
        original = self.assets(self.a)[0]
        listing = self.listing(asset=original)
        self.assertEqual(self.wallet(self.a)['balance'], 199000)
        result = self.buy(listing)
        self.assertEqual(self.wallet(self.a)['balance'], 249000)
        self.assertEqual(self.wallet(self.b)['balance'], 150000)
        received = next(a for a in self.assets(self.b) if a['id'] == original['id'])
        self.assertTrue(received['locked'])
        self.assertEqual(received['snapshot'], original['snapshot'])
        claim_path = '/v1/deliveries/' + result['delivery']['id'] + '/claim'
        self.call(self.b, 'POST', claim_path)
        relisted = self.listing(self.b, asset=received)
        self.buy(relisted, self.e)
        self.call(self.b, 'POST', claim_path)
        self.assertNotIn(original['id'], [a['id'] for a in self.assets(self.b)])
        self.assertIn(original['id'], [a['id'] for a in self.assets(self.e)])
        self.assertEqual(self.call(self.a, 'GET', '/v1/deliveries')['deliveries'], [])

    def test_same_purchase_request_recovery_and_payload_conflict(self):
        listing = self.listing()
        before = self.wallet(self.b)['balance']
        first = self.buy(listing, request_id='lost_purchase_response')
        second = self.buy(listing, request_id='lost_purchase_response')
        self.assertEqual(first, second)
        self.assertEqual(before - self.wallet(self.b)['balance'], listing['price'])
        recovered = self.call(self.b, 'GET', '/v1/operations/lost_purchase_response')['response']
        self.assertEqual(recovered, first)
        self.call(self.b, 'POST', '/v1/market/listings/' + listing['id'] + '/buy', dict(price=1, revision=1, compatibility=self.compat, request_id='lost_purchase_response'), 409)

    def test_insufficient_funds_and_failed_fee_leave_no_locks(self):
        self.call(self.a, 'POST', '/v1/market/listings', dict(asset_id=self.assets(self.a)[0]['id'], price=True, compatibility=self.compat), 400)
        listing = self.listing(price=300000)
        before = self.wallet(self.b)
        self.call(self.b, 'POST', '/v1/market/listings/' + listing['id'] + '/buy', dict(price=300000, revision=1, compatibility=self.compat), 409)
        self.assertEqual(before, self.wallet(self.b))
        self.assertEqual(self.call(self.a, 'GET', '/v1/market/listings/' + listing['id'])['listing']['status'], 'active')

    def test_cancel_expiry_and_duplicate_returns(self):
        listing = self.listing()
        path = '/v1/market/listings/' + listing['id'] + '/cancel'
        first = self.call(self.a, 'POST', path)['listing']
        self.call(self.a, 'POST', path)
        self.call(self.e, 'POST', path, status=403)
        self.assertEqual(len(self.call(self.a, 'GET', '/v1/deliveries')['deliveries']), 1)
        self.call(self.a, 'POST', '/v1/deliveries/' + first['delivery_id'] + '/claim')
        another = self.listing(asset=self.assets(self.a)[1])
        self.clock.advance(7 * 86400 + 1)
        status, refreshed = self.store.request('POST', '/v1/auth/login', dict(username='alice', password='testpassword123', protocol=PROTOCOL))
        self.assertEqual(status, 200)
        self.a['token'] = refreshed['token']
        self.assertEqual(self.call(self.a, 'GET', '/v1/market/listings/' + another['id'])['listing']['status'], 'expired')
        self.assertEqual(self.call(self.a, 'GET', '/v1/market/listings')['listings'], [])
        self.assertEqual(self.wallet(self.a)['balance'], 198000)

    def test_two_buyers_race(self):
        listing = self.listing()
        body = dict(price=listing['price'], revision=1, compatibility=self.compat)
        def buy(person):
            return self.store.request('POST', '/v1/market/listings/' + listing['id'] + '/buy', dict(body, request_id='race_' + person['identity']['id']), person['token'])
        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(buy, [self.b, self.e]))
        self.assertEqual(sorted(r[0] for r in results), [200, 409])
        self.assertEqual(self.wallet(self.b)['balance'] + self.wallet(self.e)['balance'], 350000)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM market_orders').fetchone()[0], 1)

    def test_buy_cancel_race_has_single_destination(self):
        listing = self.listing()
        def run(action):
            owner, endpoint, payload = (self.a, 'cancel', {}) if action == 'cancel' else (self.b, 'buy', dict(price=50000, revision=1, compatibility=self.compat))
            return self.store.request('POST', '/v1/market/listings/' + listing['id'] + '/' + endpoint, dict(payload, request_id='race_' + endpoint), owner['token'])
        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(run, ['cancel', 'buy']))
        self.assertEqual(sorted(r[0] for r in results), [200, 409])
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM trading_deliveries').fetchone()[0], 1)

    def test_atomic_rollback_after_money_and_asset_transfer(self):
        listing = self.listing()
        original = self.store.new_delivery
        def fail(*args):
            original(*args)
            raise RuntimeError('fault after transfer and delivery write')
        self.store.new_delivery = fail
        with self.assertRaisesRegex(RuntimeError, 'fault after'):
            self.buy(listing, request_id='retry_atomic_purchase')
        self.store.new_delivery = original
        self.assertEqual(self.wallet(self.b)['balance'], 200000)
        self.assertIn(listing['asset_id'], [a['id'] for a in self.assets(self.a)])
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM market_orders').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM trading_deliveries').fetchone()[0], 0)
        self.buy(listing, request_id='retry_atomic_purchase')

    def test_cross_feature_asset_locks(self):
        asset = self.assets(self.a)[0]
        self.listing(asset=asset)
        self.call(self.a, 'POST', '/v1/pool/deposits', dict(deposit_id='pool_' + secrets.token_hex(16), offer_id='test_offer', source='server_managed', compatibility=self.compat, asset_id=asset['id']), 409)
        session = self.exchange()
        self.call(self.a, 'POST', '/v1/exchanges/' + session['id'] + '/offer', dict(revision=session['revision'], asset_ids=[asset['id']], amount=0), 409)
        self.assertEqual(self.wallet(self.a)['reserved'], 0)

    def test_direct_exchange_two_step_holds_and_atomic_settlement(self):
        a, b = self.assets(self.a)[:2], self.assets(self.b)[:1]
        session = self.exchange()
        session = self.offer(self.a, session, a, 25000)
        self.assertEqual(self.wallet(self.a)['available'], 175000)
        session = self.offer(self.b, session, b, 5000)
        session = self.locked(session)
        self.call(self.a, 'POST', '/v1/exchanges/' + session['id'] + '/confirm', dict(revision=session['revision'], offer_hash=session['offer_hash']), 409)
        self.clock.advance(3)
        session = self.action(self.a, session, 'confirm')
        session = self.action(self.b, session, 'confirm')
        self.assertEqual(session['status'], 'committed')
        self.assertEqual(self.wallet(self.a)['balance'], 180000)
        self.assertEqual(self.wallet(self.b)['balance'], 220000)
        self.assertEqual(self.wallet(self.a)['reserved'], 0)
        self.assertTrue(set(x['id'] for x in a) <= set(x['id'] for x in self.assets(self.b)))
        self.assertTrue(set(x['id'] for x in b) <= set(x['id'] for x in self.assets(self.a)))

    def test_offer_change_clears_both_locks_and_rejects_stale_confirmation(self):
        session = self.offer(self.a, self.exchange(), self.assets(self.a)[:1])
        old = self.locked(session)
        changed = self.offer(self.b, old, self.assets(self.b)[:1])
        self.assertEqual(changed['locked'], [])
        self.assertEqual(changed['confirmed'], [])
        self.call(self.a, 'POST', '/v1/exchanges/' + old['id'] + '/confirm', dict(revision=old['revision'], offer_hash=old['offer_hash']), 409)
        self.call(self.e, 'GET', '/v1/exchanges/' + old['id'], status=403)

    def test_expired_exchange_releases_money_and_assets_after_restart(self):
        session = self.offer(self.a, self.exchange(), self.assets(self.a)[:1], 100000)
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.store.catalog_path = self.catalog_path
        self.assertEqual(self.wallet(self.a)['reserved'], 100000)
        self.clock.advance(181)
        self.assertEqual(self.wallet(self.a)['reserved'], 0)
        result = self.call(self.a, 'GET', '/v1/exchanges/' + session['id'])['exchange']
        self.assertEqual(result['status'], 'expired')
        self.assertFalse(any(a['locked'] for a in self.assets(self.a)))

    def test_restart_retains_pending_delivery_and_unique_grant(self):
        result = self.buy(self.listing())
        self.store.close()
        self.store = Store(self.database, clock=self.clock)
        self.store.catalog_path = self.catalog_path
        self.assertEqual(self.call(self.b, 'GET', '/v1/deliveries')['deliveries'][0]['id'], result['delivery']['id'])
        with self.store.lock, self.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            grant = self.store.trading_grant(db, self.a['identity']['id'], 200000, [0, 3, 6], 'fixture_grant_0')
            self.assertEqual(len(grant['asset_ids']), 3)
        self.assertEqual(self.wallet(self.a)['balance'], 249000)

    def test_search_ivs_fusion_filters_and_price_order(self):
        for person in self.people:
            for i, asset in enumerate(self.assets(person)):
                self.listing(person, 1000 + i * 500, asset)
        result = self.call(self.b, 'POST', '/v1/market/search', dict(filters=dict(iv_exact={'ATTACK': 31}, min_perfect=6), sort='price_desc'))
        self.assertEqual([x['price'] for x in result['listings']], sorted([x['price'] for x in result['listings']], reverse=True))
        self.assertEqual(len(result['listings']), 9)
        fused = self.call(self.b, 'POST', '/v1/market/search', dict(filters=dict(head=133, body=25)))['listings']
        self.assertTrue(fused and all(x['snapshot']['species'] == 'B25H133' for x in fused))
        self.assertEqual(self.call(self.b, 'POST', '/v1/market/search', dict(filters=dict(iv_exact={'ATTACK': 0})))['listings'], [])
        self.call(self.b, 'POST', '/v1/market/search', dict(filters=dict(iv_min={'UNKNOWN': 31})), 400)

    def test_account_required_and_no_public_mint(self):
        status, anonymous = self.store.request('POST', '/v1/identities', dict(nickname='guest', protocol=PROTOCOL))
        self.assertEqual(status, 201)
        self.call(anonymous, 'GET', '/v1/wallet', status=403)
        self.call(self.a, 'POST', '/v1/wallet', dict(amount=999999), 404)
        self.call(self.a, 'POST', '/v1/market/grant', dict(amount=999999), 404)
        self.call(self.a, 'POST', '/v1/market/listings', dict(asset_id=self.assets(self.a)[0]['id'], price=1000, compatibility=self.compat, snapshot=pokemon()), 400)

    def test_paused_market_preserves_claim_and_cancel(self):
        listing = self.listing()
        with self.store.connect() as db:
            db.execute("UPDATE economy_meta SET value='false' WHERE name='enabled'")
        self.call(self.b, 'POST', '/v1/market/listings/' + listing['id'] + '/buy', dict(price=50000, revision=1, compatibility=self.compat), 503)
        result = self.call(self.a, 'POST', '/v1/market/listings/' + listing['id'] + '/cancel')['listing']
        self.call(self.a, 'POST', '/v1/deliveries/' + result['delivery_id'] + '/claim')

    def test_real_http_search_and_operation_recovery(self):
        listing = self.listing()
        server = make_server('127.0.0.1', 0, self.store)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            payload = dict(price=50000, revision=1, compatibility=self.compat, request_id='http_purchase_recovery')
            request = urllib.request.Request('http://127.0.0.1:%d/v1/market/listings/%s/buy' % (server.server_port, listing['id']), data=json.dumps(payload).encode(), headers={'Authorization': 'Bearer ' + self.b['token'], 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=10) as response:
                first = json.load(response)
            request = urllib.request.Request('http://127.0.0.1:%d/v1/operations/http_purchase_recovery' % server.server_port, headers={'Authorization': 'Bearer ' + self.b['token']})
            with urllib.request.urlopen(request, timeout=10) as response:
                recovered = json.load(response)
            self.assertEqual(recovered['response'], first)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(5)

    def test_production_migration_keeps_data_and_consistent_backup(self):
        import sqlite3
        from contextlib import closing
        from production_data import inspect_database
        from trading_admin import migrate
        data_id = 'b' * 32
        with self.store.connect() as db:
            db.execute('CREATE TABLE deployment_meta(name TEXT PRIMARY KEY,value TEXT NOT NULL)')
            db.executemany('INSERT INTO deployment_meta VALUES(?,?)', [('schema_version', '1'), ('data_id', data_id)])
        old_assets = [asset['id'] for asset in self.assets(self.a)]
        self.store.close()
        backup = self.database.with_suffix('.pre-trading.sqlite3')
        try:
            result = migrate(self.database, backup)
            self.assertTrue(result['ok'])
            from production_data import SCHEMA_VERSION
            self.assertEqual(inspect_database(self.database, data_id)['schema_version'], SCHEMA_VERSION)
            with closing(sqlite3.connect(backup)) as db:
                self.assertEqual(db.execute("SELECT value FROM deployment_meta WHERE name='schema_version'").fetchone()[0], '1')
            self.store = Store(self.database, clock=self.clock)
            self.store.catalog_path = self.catalog_path
            self.assertEqual(old_assets, [asset['id'] for asset in self.assets(self.a)])
            self.assertEqual(self.wallet(self.a)['balance'], 200000)
        finally:
            backup.unlink(missing_ok=True)

    def test_old_pending_delivery_is_never_hidden_by_claimed_history(self):
        result = self.buy(self.listing())
        pending_id = result['delivery']['id']
        owner = self.b['identity']['id']
        with self.store.connect() as db:
            for i in range(205):
                document = dict(id='historical_%03d' % i, owner_id=owner, event_id='past_event_%03d' % i, asset_id='past_asset_%03d' % i, status='claimed')
                db.execute('INSERT INTO trading_deliveries VALUES(?,?,?,?,?,?,?)', (document['id'], owner, document['event_id'], document['asset_id'], 'claimed', json.dumps(document), self.clock() + i + 1))
        values = self.call(self.b, 'GET', '/v1/deliveries')['deliveries']
        self.assertEqual(len(values), 200)
        self.assertEqual(values[0]['id'], pending_id)


if __name__ == '__main__':
    unittest.main()
