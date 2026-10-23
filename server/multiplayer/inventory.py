"""Server-owned fungible items, reservations and quantity-conserving transfers."""
import json
import secrets
from pathlib import Path

MAX_ITEMS = 999_999_999


def bind_api(api):
    for name in ('obj', 'require', 'string', 'integer', 'dumps', 'digest'):
        globals()[name] = api[name]


class InventoryFeatures:
    def init_inventory(self, db):
        self.item_catalog_path = Path(__file__).parent / 'catalog-trading-items-v1.json'
        db.executescript('''
            CREATE TABLE IF NOT EXISTS inventory_accounts(owner TEXT PRIMARY KEY,version INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS item_balances(owner TEXT NOT NULL,item_id TEXT NOT NULL,quantity INTEGER NOT NULL CHECK(quantity>=0 AND quantity<=999999999),PRIMARY KEY(owner,item_id));
            CREATE TABLE IF NOT EXISTS item_holds(owner TEXT NOT NULL,reference TEXT NOT NULL,item_id TEXT NOT NULL,quantity INTEGER NOT NULL CHECK(quantity>=0),PRIMARY KEY(owner,reference,item_id));
            CREATE INDEX IF NOT EXISTS item_hold_reference ON item_holds(reference,owner);
            CREATE TABLE IF NOT EXISTS item_ledger_transactions(id TEXT PRIMARY KEY,kind TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS item_ledger_entries(transaction_id TEXT NOT NULL,owner TEXT NOT NULL,item_id TEXT NOT NULL,quantity INTEGER NOT NULL,PRIMARY KEY(transaction_id,owner,item_id));
        ''')

    def item_catalog(self, compatibility=None):
        require(self.item_catalog_path.is_file(), 'item_catalog_unavailable', 'Install the native-validated trading item catalog', 503)
        catalog = json.loads(self.item_catalog_path.read_text(encoding='utf-8-sig'))
        require(catalog.get('version') == 1 and type(catalog.get('items')) is list and 1 <= len(catalog['items']) <= 128, 'item_catalog_invalid', 'Invalid trading item catalog', 503)
        if compatibility is not None:
            require(catalog.get('compatibility') == compatibility, 'item_catalog_incompatible', 'Item catalog and client versions differ', 409)
        ids = set()
        for item in catalog['items']:
            obj(item, {'id','name','tradeable','price','pocket'}, {'id','name','tradeable','price','pocket'})
            string(item['id'], 1, 80, 'item_id', r'[A-Z0-9_]+')
            string(item['name'], 1, 100, 'item_name')
            integer(item['price'], 0, 9_999_999_999, 'item_price')
            integer(item['pocket'], 0, 20, 'pocket')
            require(item['tradeable'] is True and item['id'] not in ids, 'item_catalog_invalid', 'Catalog contains a bound or duplicate item', 503)
            ids.add(item['id'])
        return catalog

    def inventory_item(self, item_id, compatibility=None):
        string(item_id, 1, 80, 'item_id', r'[A-Z0-9_]+')
        item = next((i for i in self.item_catalog(compatibility)['items'] if i['id'] == item_id), None)
        require(item is not None, 'item_not_tradeable', 'This item is not approved for online trading', 409)
        return item

    def item_balance(self, db, owner, item_id):
        row = db.execute('SELECT quantity FROM item_balances WHERE owner=? AND item_id=?', (owner,item_id)).fetchone()
        quantity = row[0] if row else 0
        reserved = db.execute('SELECT COALESCE(SUM(quantity),0) FROM item_holds WHERE owner=? AND item_id=?', (owner,item_id)).fetchone()[0]
        require(0 <= reserved <= quantity, 'item_invariant', 'Item reservations need operator inspection', 503)
        return {'item_id':item_id, 'quantity':quantity, 'reserved':reserved, 'available':quantity-reserved}

    def touch_inventory(self, db, owner):
        db.execute('INSERT OR IGNORE INTO inventory_accounts(owner) VALUES(?)', (owner,))
        db.execute('UPDATE inventory_accounts SET version=version+1 WHERE owner=?', (owner,))

    def hold_items(self, db, owner, reference, items, validate=True):
        require(type(items) is dict and len(items) <= 8, 'invalid_items', 'At most eight item types per offer')
        for item_id, quantity in items.items():
            string(item_id,1,80,'item_id',r'[A-Z0-9_]+')
            integer(quantity,1,MAX_ITEMS,'quantity')
            if validate:
                self.inventory_item(item_id)
            balance = self.item_balance(db,owner,item_id)
            old = db.execute('SELECT quantity FROM item_holds WHERE owner=? AND reference=? AND item_id=?', (owner,reference,item_id)).fetchone()
            require(quantity <= balance['available']+(old[0] if old else 0), 'insufficient_items', 'Not enough available server items', 409)
        db.execute('DELETE FROM item_holds WHERE owner=? AND reference=?', (owner,reference))
        for item_id, quantity in items.items():
            db.execute('INSERT INTO item_holds VALUES(?,?,?,?)', (owner,reference,item_id,quantity))
        self.touch_inventory(db,owner)

    def post_items(self, db, transaction_id, kind, changes, document):
        totals = {}
        for (owner,item_id), delta in changes.items():
            require(type(delta) is int, 'invalid_item_delta', 'Item changes must be integers', 500)
            totals[item_id] = totals.get(item_id,0)+delta
            if owner.startswith('system:'):
                continue
            balance = self.item_balance(db,owner,item_id)
            require(0 <= balance['quantity']+delta <= MAX_ITEMS and balance['available']+delta >= 0, 'insufficient_items', 'Item balance or capacity exceeded', 409)
        require(all(value == 0 for value in totals.values()), 'item_ledger_unbalanced', 'Item entries must balance by type', 500)
        require(not db.execute('SELECT 1 FROM item_ledger_transactions WHERE id=?', (transaction_id,)).fetchone(), 'item_settlement_duplicate', 'Item settlement already exists', 409)
        db.execute('INSERT INTO item_ledger_transactions VALUES(?,?,?,?)', (transaction_id,kind,dumps(document),self.clock()))
        for (owner,item_id), delta in changes.items():
            db.execute('INSERT INTO item_ledger_entries VALUES(?,?,?,?)', (transaction_id,owner,item_id,delta))
            if not owner.startswith('system:'):
                db.execute('INSERT OR IGNORE INTO item_balances VALUES(?,?,0)', (owner,item_id))
                db.execute('UPDATE item_balances SET quantity=quantity+? WHERE owner=? AND item_id=?', (delta,owner,item_id))
                self.touch_inventory(db,owner)

    def inventory_view(self, db, owner):
        rows = db.execute('SELECT item_id FROM item_balances WHERE owner=? AND quantity>0 ORDER BY item_id', (owner,)).fetchall()
        catalog = {item['id']:item for item in self.item_catalog()['items']}
        values = []
        for row in rows:
            value = self.item_balance(db,owner,row[0])
            value['item'] = catalog.get(row[0],{'id':row[0],'name':row[0],'tradeable':False})
            values.append(value)
        version = db.execute('SELECT version FROM inventory_accounts WHERE owner=?', (owner,)).fetchone()
        return {'owner_id':owner,'version':version[0] if version else 0,'items':values,'catalog_ids':sorted(catalog)}

    def new_item_delivery(self, db, owner, item_id, quantity, event_id, reason):
        delivery_id = 'del_' + secrets.token_hex(16)
        document = {'id':delivery_id,'kind':'item','owner_id':owner,'event_id':event_id,'item_id':item_id,'quantity':quantity,'asset_id':'itm_'+item_id,'status':'pending','reason':reason,'created_at':self.clock()}
        self.hold_items(db,owner,'delivery:'+delivery_id,{item_id:quantity},validate=False)
        db.execute('INSERT INTO trading_deliveries VALUES(?,?,?,?,?,?,?)', (delivery_id,owner,event_id,document['asset_id'],'pending',dumps(document),self.clock()))
        return document

    def claim_item_delivery(self, db, owner, delivery):
        if delivery['status'] == 'pending':
            row = db.execute('SELECT quantity FROM item_holds WHERE owner=? AND reference=? AND item_id=?', (owner,'delivery:'+delivery['id'],delivery['item_id'])).fetchone()
            require(row and row[0] == delivery['quantity'], 'item_hold_lost', 'Delivery quantity reservation differs', 409)
            db.execute('DELETE FROM item_holds WHERE owner=? AND reference=?', (owner,'delivery:'+delivery['id']))
            self.touch_inventory(db,owner)
            delivery.update(status='claimed',claimed_at=self.clock())
            db.execute("UPDATE trading_deliveries SET status='claimed',document=? WHERE id=?", (dumps(delivery),delivery['id']))
            self.trading_event(db,'claimed_'+delivery['id'],[owner],'claimed',delivery)
        return 200, {'ok':True,'delivery':delivery}

    def create_item_listing(self, db, owner, body):
        obj(body,{'request_id','kind','item_id','quantity','unit_price','compatibility'},{'request_id','kind','item_id','quantity','unit_price','compatibility'})
        require(body['kind'] == 'item','invalid_kind','Choose an item listing')
        compatibility = self.trading_compatibility(body['compatibility'])
        item = self.inventory_item(body['item_id'],compatibility)
        quantity = integer(body['quantity'],1,9999,'quantity')
        unit_price = integer(body['unit_price'],1,9_999_999_999,'unit_price')
        total = integer(quantity*unit_price,1,9_999_999_999,'total_price')
        require(db.execute("SELECT COUNT(*) FROM market_listings WHERE seller=? AND status='active'",(owner,)).fetchone()[0]<10,'listing_limit','At most ten active listings',409)
        listing_id = 'lst_'+secrets.token_hex(16)
        self.hold_items(db,owner,'market:'+listing_id,{item['id']:quantity})
        fee = min(25000,max(100,(total*2+99)//100))
        self.post_money(db,'fee_'+listing_id,'listing_fee',{owner:-fee,'system:fees':fee},{'listing_id':listing_id})
        listing = {'id':listing_id,'kind':'item','seller_id':owner,'asset_id':'itm_'+item['id'],'asset_rules_hash':self.asset_contract(self.catalog()),'item_id':item['id'],'item':item,'quantity':quantity,'unit_price':unit_price,'price':total,'fee':fee,'currency':'LINK','status':'active','revision':1,'created_at':self.clock(),'expires_at':self.clock()+7*86400,'snapshot':{},'compatibility':compatibility}
        db.execute('INSERT INTO market_listings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(listing_id,owner,listing['asset_id'],'active',total,fee,1,self.clock(),listing['expires_at'],item['id'],0,'',0,0,'{}',dumps(listing)))
        self.trading_event(db,'listed_'+listing_id,[owner],'listed',listing)
        self.market_alerts(db,listing)
        return 201, {'ok':True,'listing':listing,'wallet':self.wallet(db,owner)}

    def close_item_listing(self, db, listing, status):
        reference = 'market:'+listing['id']
        row = db.execute('SELECT quantity FROM item_holds WHERE owner=? AND reference=? AND item_id=?',(listing['seller_id'],reference,listing['item_id'])).fetchone()
        require(row and row[0] == listing['quantity'],'item_hold_lost','Listing item reservation differs',409)
        db.execute('DELETE FROM item_holds WHERE owner=? AND reference=?',(listing['seller_id'],reference))
        delivery = self.new_item_delivery(db,listing['seller_id'],listing['item_id'],listing['quantity'],status+'_'+listing['id'],status)
        listing.update(status=status,revision=listing['revision']+1,delivery_id=delivery['id'])
        self.save_listing(db,listing)
        self.trading_event(db,status+'_'+listing['id'],[listing['seller_id']],status,listing)
        return listing

    def buy_item_listing(self, db, owner, listing, order_id,quantity=None):
        self.inventory_item(listing['item_id'],listing['compatibility'])
        reference = 'market:'+listing['id']
        row = db.execute('SELECT quantity FROM item_holds WHERE owner=? AND reference=? AND item_id=?',(listing['seller_id'],reference,listing['item_id'])).fetchone()
        require(row and row[0] == listing['quantity'],'item_hold_lost','Listing item reservation differs',409)
        quantity=listing['quantity'] if quantity is None else quantity
        integer(quantity,1,listing['quantity'],'quantity')
        db.execute('DELETE FROM item_holds WHERE owner=? AND reference=?',(listing['seller_id'],reference))
        if quantity<listing['quantity']:
            db.execute('INSERT INTO item_holds VALUES(?,?,?,?)',(listing['seller_id'],reference,listing['item_id'],listing['quantity']-quantity))
        self.post_items(db,order_id,'market_purchase',{(listing['seller_id'],listing['item_id']):-quantity,(owner,listing['item_id']):quantity},{'listing_id':listing['id']})
        return self.new_item_delivery(db,owner,listing['item_id'],quantity,order_id,'purchase')

    def inventory_audit(self, db):
        unbalanced = db.execute('SELECT transaction_id,item_id FROM item_ledger_entries GROUP BY transaction_id,item_id HAVING SUM(quantity)<>0').fetchall()
        drift = db.execute('SELECT b.owner,b.item_id FROM item_balances b LEFT JOIN item_ledger_entries e ON e.owner=b.owner AND e.item_id=b.item_id GROUP BY b.owner,b.item_id HAVING b.quantity<>COALESCE(SUM(e.quantity),0)').fetchall()
        holds = db.execute('SELECT h.owner,h.item_id FROM item_holds h LEFT JOIN item_balances b ON b.owner=h.owner AND b.item_id=h.item_id GROUP BY h.owner,h.item_id HAVING SUM(h.quantity)>COALESCE(b.quantity,0)').fetchall()
        return {'ok':not(unbalanced or drift or holds),'unbalanced':[list(r) for r in unbalanced],'quantity_drift':[list(r) for r in drift],'overreserved':[list(r) for r in holds]}
