"""Unique native-test DB/account grants; never open a player's database."""
import json
from pathlib import Path
import sys

root, run = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
assert run.is_relative_to(root / 'temp/multiplayer') and not (run / 'service.sqlite3').exists()
sys.path.insert(0, str(root / 'server/multiplayer'))
from service import Store, PROTOCOL

store = Store(run / 'service.sqlite3', synchronous='FULL')
try:
    for role in ('host', 'guest'):
        status, response = store.request('POST', '/v1/auth/register', {'username': 'trading_' + role, 'password': 'IsolatedNativeFixture123', 'protocol': PROTOCOL})
        assert status == 201, response
        with store.lock, store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            store.trading_grant(db, response['identity']['id'], 200000, [0, 1, 2] if role == 'host' else [3, 4, 5], 'native_fixture_' + role, {'POTION':10 if role=='host' else 20,'RARECANDY':5})
    (run / 'scenario.json').write_text(json.dumps({'directory': str(run).replace('\\', '/')}), encoding='utf-8')
finally:
    store.close()
