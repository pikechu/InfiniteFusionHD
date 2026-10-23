"""Actual prior v5 database -> offline v6 migration, preserving business rows."""
from pathlib import Path
import hashlib,json,os,secrets,sqlite3,sys
root=Path(__file__).resolve().parents[2];sys.path.insert(0,str(root/'server/multiplayer'))
from service import Store,PROTOCOL
from trading_admin import migrate
old=json.loads((root/'docs/multiplayer-trading-evidence/android-trading.json').read_text(encoding='utf-8'))
source=root/old['directory']/'service.sqlite3'
run=root/'temp/multiplayer'/('market-v5-upgrade-'+secrets.token_hex(5));run.mkdir(parents=True)
database=run/'service.sqlite3';backup=run/'before.sqlite3'
assert source.is_file() and source.resolve()!=database.resolve()
original_hash=hashlib.sha256(source.read_bytes()).hexdigest()
origin=sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)
try:
    tables={r[0] for r in origin.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert 'market_contracts' not in tables,'Expected an actual prior v5 database'
    with sqlite3.connect(database) as target:origin.backup(target)
finally:origin.close()

def snapshot(db):
    result={}
    for row in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"):
        name=row[0]
        if name in ('world_presence','deployment_meta'):continue
        result[name]=sorted([tuple(value) for value in db.execute('SELECT * FROM "'+name.replace('"','""')+'"')],key=repr)
    return result

with sqlite3.connect(database) as db:
    before=snapshot(db)
    db.execute('CREATE TABLE IF NOT EXISTS deployment_meta(name TEXT PRIMARY KEY,value TEXT NOT NULL)')
    db.execute("INSERT OR REPLACE INTO deployment_meta VALUES('schema_version','5')")
result=migrate(database,backup);assert result['ok'] and result['schema_version']==6,result
with sqlite3.connect(backup) as db:
    assert snapshot(db)==before
    assert db.execute("SELECT value FROM deployment_meta WHERE name='schema_version'").fetchone()[0]=='5'
with sqlite3.connect(database) as db:
    after=snapshot(db)
    for table,rows in before.items():assert after[table]==rows,table
assert hashlib.sha256(source.read_bytes()).hexdigest()==original_hash,'Original database changed'
store=Store(database,synchronous='FULL',create=False)
try:
    def call(person,method,path,body=None):
        body=dict(body or {})
        if method=='POST' and not path.startswith('/v1/auth/'):body.setdefault('request_id','upgrade_'+secrets.token_hex(16))
        status,value=store.request(method,path,body,person['token'] if person else None)
        assert status in (200,201),value
        return value
    seller=call(None,'POST','/v1/auth/login',dict(username='trading_host',password='IsolatedNativeFixture123',protocol=PROTOCOL))
    buyer=call(None,'POST','/v1/auth/login',dict(username='trading_guest',password='IsolatedNativeFixture123',protocol=PROTOCOL))
    compatibility=store.catalog()['compatibility']
    listing=call(seller,'POST','/v1/market/listings',dict(kind='item',item_id='POTION',quantity=2,unit_price=100,compatibility=compatibility))['listing']
    orders=[]
    for _ in range(2):
        current=call(buyer,'GET','/v1/market/listings/'+listing['id'])['listing']
        order=call(buyer,'POST','/v1/market/listings/'+listing['id']+'/buy',dict(revision=current['revision'],price=100,quantity=1,compatibility=compatibility))['order'];orders.append(order['id'])
    assert len(set(orders))==2
    with store.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM market_orders WHERE listing_id=?',(listing['id'],)).fetchone()[0]==2
        audit=store.economy_audit(db);assert audit['ok'],audit
    record=dict(passed=True,source_schema=5,target_schema=6,preserved_tables=sorted(before),new_fills_on_same_listing=2,source_unchanged=True,backup_preserves_old_schema=True,audit=audit,directory=run.relative_to(root).as_posix(),scope='Readonly copy of previous actual Android/Windows trading database; world presence intentionally reset on restart; production marker added only to the disposable copy')
    (root/'docs/multiplayer-trading-evidence/market-expansion-upgrade.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('MARKET_EXPANSION_UPGRADE_PASS',json.dumps(record,ensure_ascii=False))
finally:store.close()
