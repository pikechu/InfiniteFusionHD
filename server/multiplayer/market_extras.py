"""Durable market discovery, attachment mail and shared extension primitives.

All entry points run inside Store's serialized transaction and operation journal.
Attachments reference existing ownership and holds; nothing is imported or minted.
"""
import copy,json,secrets

MAX_COINS=9_999_999_999

def bind_api(api):
    for name in ('obj','require','string','integer','boolean','dumps','digest'):
        globals()[name]=api[name]

class MarketExtras:
    def market_extensions_audit(self,db):
        cash=[];issues=[]
        for row in db.execute("SELECT m.owner,m.amount,COALESCE(SUM(e.amount),0) AS actual FROM market_cash m LEFT JOIN ledger_entries e ON e.owner='system:market_cash:'||m.owner GROUP BY m.owner"):
            if row['amount']!=row['actual']:cash.append(row['owner'])
        for row in db.execute("SELECT e.owner FROM ledger_entries e LEFT JOIN market_cash m ON e.owner='system:market_cash:'||m.owner WHERE e.owner GLOB 'system:market_cash:*' AND m.owner IS NULL GROUP BY e.owner HAVING SUM(e.amount)<>0"):
            cash.append(row[0])
        for row in db.execute('SELECT u.*,a.owner AS actual,c.status,c.expires AS deadline,c.kind AS contract_kind FROM market_custody u LEFT JOIN hosted_assets a ON a.id=u.asset_id LEFT JOIN market_contracts c ON c.id=u.contract_id'):
            if row['actual']!=row['holder'] or row['status']!='active' or row['expires']!=row['deadline'] or row['kind']!=row['contract_kind']:issues.append('custody:'+row['asset_id'])
        def check_hold(owner,reference,amount,items,assets):
            held=db.execute('SELECT amount FROM wallet_holds WHERE owner=? AND reference=?',(owner,reference)).fetchone()
            if (held[0] if held else 0)!=amount:issues.append('money:'+reference)
            found={r[0]:r[1] for r in db.execute('SELECT item_id,quantity FROM item_holds WHERE owner=? AND reference=?',(owner,reference))}
            if found!=items:issues.append('items:'+reference)
            for asset_id in assets:
                row=db.execute('SELECT a.owner,l.reference FROM hosted_assets a LEFT JOIN asset_locks l ON l.asset_id=a.id WHERE a.id=?',(asset_id,)).fetchone()
                if not row or row[0]!=owner or row[1]!=reference:issues.append('asset:'+reference)
        for row in db.execute("SELECT document FROM market_mail WHERE status='pending'"):
            mail=json.loads(row[0]);bundle=mail['bundle'];check_hold(mail['sender_id'],'mail:'+mail['id'],bundle['coins'],bundle['items'],bundle['asset_ids'])
        for row in db.execute("SELECT document FROM market_contracts WHERE status IN ('open','active')"):
            value=json.loads(row[0]);ref='contract:'+value['id'];terms=value['terms']
            if value['status']=='open':
                bundle=value['bundle'];amount=value['remaining']*terms['unit_price'] if value['kind']=='buy_order' else bundle['coins']
                check_hold(value['owner_id'],ref,amount,bundle['items'],bundle['asset_ids'])
                if value.get('bidder_id'):check_hold(value['bidder_id'],'bid:'+value['id'],value['bid'],{},[])
            elif value['kind'] in ('training','rental'):
                check_hold(value['counterparty_id'],'bond:'+value['id'],terms['bond'],{},[])
                if value['kind']=='training':check_hold(value['owner_id'],ref,terms['reward'],{},[])
                asset_id=value['bundle']['asset_ids'][0]
                if not db.execute('SELECT 1 FROM market_custody WHERE asset_id=? AND contract_id=?',(asset_id,value['id'])).fetchone():issues.append('usage:'+value['id'])
            else:check_hold(value['counterparty_id'],ref,0,{},[value['collateral_id']])
        return dict(ok=not(cash or issues),cash_drift=cash,contract_issues=issues)

    def upgrade_market_orders(self,db):
        indexes=db.execute('PRAGMA index_list(market_orders)').fetchall()
        legacy=any(row['unique'] and [r['name'] for r in db.execute('PRAGMA index_info("'+row['name'].replace('"','""')+'")')]==['listing_id'] for row in indexes)
        if legacy:
            db.execute('SAVEPOINT market_orders_upgrade')
            try:
                db.execute('ALTER TABLE market_orders RENAME TO market_orders_v5')
                db.execute('CREATE TABLE market_orders(id TEXT PRIMARY KEY,listing_id TEXT NOT NULL,buyer TEXT NOT NULL,seller TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL)')
                db.execute('INSERT INTO market_orders SELECT * FROM market_orders_v5')
                db.execute('DROP TABLE market_orders_v5')
                db.execute('RELEASE market_orders_upgrade')
            except Exception:
                db.execute('ROLLBACK TO market_orders_upgrade');db.execute('RELEASE market_orders_upgrade');raise
        db.execute('CREATE INDEX IF NOT EXISTS market_order_listing ON market_orders(listing_id)')
        db.execute('CREATE INDEX IF NOT EXISTS market_order_created ON market_orders(created)')

    def init_market_extras(self,db):
        db.executescript('''
          CREATE TABLE IF NOT EXISTS market_saved_searches(id TEXT PRIMARY KEY,owner TEXT NOT NULL,document TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS market_saved_owner ON market_saved_searches(owner);
          CREATE TABLE IF NOT EXISTS market_notifications(id TEXT PRIMARY KEY,owner TEXT NOT NULL,source TEXT NOT NULL,read INTEGER NOT NULL DEFAULT 0,document TEXT NOT NULL,created REAL NOT NULL,UNIQUE(owner,source));
          CREATE INDEX IF NOT EXISTS market_notice_owner ON market_notifications(owner,read,created);
          CREATE TABLE IF NOT EXISTS market_mail(id TEXT PRIMARY KEY,sender TEXT NOT NULL,recipient TEXT NOT NULL,status TEXT NOT NULL,expires REAL NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
          CREATE INDEX IF NOT EXISTS market_mail_expiry ON market_mail(status,expires);
          CREATE TABLE IF NOT EXISTS market_cash(owner TEXT PRIMARY KEY,amount INTEGER NOT NULL CHECK(amount>=0));
        ''')

    def market_notice(self,db,owner,source,kind,data):
        notice=dict(id='ntf_'+secrets.token_hex(16),kind=kind,data=data,created_at=self.clock())
        db.execute('INSERT OR IGNORE INTO market_notifications VALUES(?,?,?,0,?,?)',(notice['id'],owner,source,dumps(notice),self.clock()))

    def market_alerts(self,db,listing):
        for row in db.execute('SELECT id,owner,document FROM market_saved_searches').fetchall():
            saved=json.loads(row['document'])
            if not saved['alerts'] or row['owner']==listing['seller_id']:continue
            if self.market_search(db,saved['query'],listing['id'])['listings']:
                self.market_notice(db,row['owner'],'search:'+row['id']+':'+listing['id'],'arrival',dict(search_id=row['id'],name=saved['name'],listing_id=listing['id']))

    def market_recipient(self,db,owner,code):
        code=string(code,8,8,'friend_code',r'[A-Fa-f0-9]+').upper()
        row=db.execute('SELECT i.id FROM identities i JOIN accounts a ON a.owner=i.id WHERE friend_code=?',(code,)).fetchone()
        require(row and row[0]!=owner,'invalid_recipient','Choose another registered trainer',404)
        require(owner not in self.trading_preferences(db,row[0])['blocked_ids'],'recipient_blocked','Recipient has blocked this trainer',403)
        return row[0]

    def market_bundle(self,db,owner,body,reference):
        ids=body.get('asset_ids',[]);items=body.get('items',{});coins=body.get('coins',0)
        require(type(ids) is list and len(ids)<=6 and all(type(a) is str for a in ids) and len(set(ids))==len(ids),'invalid_assets','Choose at most six distinct Pokemon')
        integer(coins,0,MAX_COINS,'coins')
        compatibility=self.trading_compatibility(body['compatibility'])
        for asset_id in ids:
            self.trading_asset(db,asset_id,owner,compatibility);self.lock_asset(db,asset_id,owner,reference)
        self.hold_items(db,owner,reference,items)
        self.reserve_money(db,owner,reference,coins)
        return dict(asset_ids=ids,items=copy.deepcopy(items),coins=coins,compatibility=compatibility)

    def market_release(self,db,owner,reference):
        db.execute('DELETE FROM wallet_holds WHERE owner=? AND reference=?',(owner,reference))
        db.execute('DELETE FROM item_holds WHERE owner=? AND reference=?',(owner,reference))
        self.touch_inventory(db,owner)

    def market_payment(self,db,event,kind,payer,recipient,amount,document):
        """Overflow remains a durable payable claim; automatic expiry cannot wedge."""
        if amount==0:return
        destination=recipient
        if self.wallet(db,recipient)['balance']+amount>MAX_COINS:
            destination='system:market_cash:'+recipient
            db.execute('INSERT INTO market_cash VALUES(?,?) ON CONFLICT(owner) DO UPDATE SET amount=amount+excluded.amount',(recipient,amount))
        self.post_money(db,event,kind,{payer:-amount,destination:amount},document)

    def market_deliver_bundle(self,db,sender,recipient,bundle,reference,event,reason):
        self.market_release(db,sender,reference)
        self.market_payment(db,event,reason,sender,recipient,bundle['coins'],{'reference':reference})
        deliveries=[]
        for asset_id in bundle['asset_ids']:
            self.transfer_asset(db,asset_id,sender,recipient,reference)
            deliveries.append(self.new_delivery(db,recipient,asset_id,event,reason)['id'])
        changes={}
        for item_id,count in bundle['items'].items():
            changes[sender,item_id]=-count;changes[recipient,item_id]=count
        if changes:self.post_items(db,event,reason,changes,{'reference':reference})
        for item_id,count in bundle['items'].items():
            deliveries.append(self.new_item_delivery(db,recipient,item_id,count,event,reason)['id'])
        return deliveries

    def market_return_bundle(self,db,owner,bundle,reference,event):
        self.market_release(db,owner,reference);deliveries=[]
        for asset_id in bundle['asset_ids']:
            lock=db.execute('SELECT reference FROM asset_locks WHERE asset_id=?',(asset_id,)).fetchone()
            require(lock and lock[0]==reference,'asset_lock_lost','Attachment lock differs',409)
            db.execute('DELETE FROM asset_locks WHERE asset_id=?',(asset_id,))
            deliveries.append(self.new_delivery(db,owner,asset_id,event,'returned')['id'])
        for item_id,count in bundle['items'].items():deliveries.append(self.new_item_delivery(db,owner,item_id,count,event,'returned')['id'])
        return deliveries

    def market_mail_view(self,value):
        return copy.deepcopy(value)

    def market_close_mail(self,db,mail,status):
        if mail['status']!='pending':return mail
        mail['delivery_ids']=self.market_return_bundle(db,mail['sender_id'],mail['bundle'],'mail:'+mail['id'],'return_'+mail['id'])
        mail['status']=status;self.market_save_mail(db,mail)
        self.market_notice(db,mail['sender_id'],'mail:'+mail['id']+':'+status,'mail_return',{'mail_id':mail['id'],'status':status})
        return mail

    def market_save_mail(self,db,mail):
        db.execute('INSERT OR REPLACE INTO market_mail VALUES(?,?,?,?,?,?,?)',(mail['id'],mail['sender_id'],mail['recipient_id'],mail['status'],mail['expires_at'],dumps(mail),mail['created_at']))

    def tick_market_extras(self,db):
        for row in db.execute("SELECT document FROM market_mail WHERE status='pending' AND expires<=? ORDER BY expires LIMIT 100",(self.clock(),)).fetchall():self.market_close_mail(db,json.loads(row[0]),'expired')

    def market_price_history(self,db,body):
        obj(body,{'request_id','kind','key','days'},{'kind','key'})
        require(body['kind'] in ('pokemon','item'),'invalid_kind','Choose Pokemon or items')
        string(body['key'],1,80,'key',r'[A-Za-z0-9_]+');days=integer(body.get('days',30),1,30,'days')
        rows=db.execute('SELECT o.document,l.document AS listing FROM market_orders o LEFT JOIN market_listings l ON l.id=o.listing_id WHERE o.created>=? ORDER BY o.created DESC,o.id DESC LIMIT 5001',(self.clock()-days*86400,)).fetchall()
        orders=[];pairs=set();current_rules=self.asset_contract(self.catalog())
        for row in rows[:5000]:
            order=json.loads(row['document']);listing=json.loads(row['listing']) if row['listing'] else {}
            pair=(order['buyer_id'],order['seller_id']);pairs.add(pair)
            kind=order.get('kind',listing.get('kind','pokemon'));snapshot=order.get('snapshot',listing.get('snapshot',{}))
            key=order.get('item_id') if kind=='item' else snapshot.get('species')
            rules=order.get('asset_rules_hash',listing.get('asset_rules_hash'))
            if kind==body['kind'] and key==body['key'] and rules==current_rules:orders.append(order)
        # Reciprocal account pairs in the window are excluded, without guessing
        # that an IP address or household proves shared ownership.
        orders=[o for o in orders if o['buyer_id']!=o['seller_id'] and (o['seller_id'],o['buyer_id']) not in pairs]
        buckets={}
        for order in reversed(orders):
            day=int(order['created_at']//86400);quantity=order.get('quantity',1);price=order.get('unit_price',order['price'])
            bucket=buckets.setdefault(day,dict(day=day,open=price,close=price,low=price,high=price,quantity=0,total=0,trades=0))
            bucket.update(close=price,low=min(bucket['low'],price),high=max(bucket['high'],price),quantity=bucket['quantity']+quantity,total=bucket['total']+order['price'],trades=bucket['trades']+1)
        for value in buckets.values():value['weighted_average']=value['total']//value['quantity']
        sufficient=len(orders)>=5 and len({o['buyer_id'] for o in orders})>=3 and len({o['seller_id'] for o in orders})>=3
        return dict(ok=True,history=list(buckets.values()),trades=len(orders),sufficient_sample=sufficient,truncated=len(rows)>5000,excluded='reciprocal pairs and incompatible rules; no market valuation')

    def dispatch_market_extras(self,db,owner,method,parts,body):
        if parts==['v1','market','history'] and method=='POST':return 200,self.market_price_history(db,body)
        if parts==['v1','market','saved-searches']:
            if method=='GET':return 200,dict(ok=True,searches=[json.loads(r[0]) for r in db.execute('SELECT document FROM market_saved_searches WHERE owner=? ORDER BY id LIMIT 20',(owner,))])
            self.trading_account(db,owner,True)
            obj(body,{'request_id','name','query','alerts'},{'request_id','name','query','alerts'})
            string(body['name'],1,40,'name');boolean(body['alerts'],'alerts')
            obj(body['query'],{'filters','sort'})
            self.market_search(db,body['query'])
            require(db.execute('SELECT COUNT(*) FROM market_saved_searches WHERE owner=?',(owner,)).fetchone()[0]<20,'search_limit','At most twenty saved searches',409)
            value=dict(id='srch_'+secrets.token_hex(16),name=body['name'],query=body['query'],alerts=body['alerts'])
            db.execute('INSERT INTO market_saved_searches VALUES(?,?,?)',(value['id'],owner,dumps(value)))
            return 201,dict(ok=True,search=value)
        if len(parts)==4 and parts[:3]==['v1','market','saved-searches'] and method=='POST':
            obj(body,{'request_id','alerts','delete'},{'request_id'})
            row=db.execute('SELECT document FROM market_saved_searches WHERE id=? AND owner=?',(parts[3],owner)).fetchone()
            require(row,'search_not_found','Saved search does not belong to this trainer',404)
            value=json.loads(row[0])
            if body.get('delete') is True:db.execute('DELETE FROM market_saved_searches WHERE id=?',(parts[3],))
            elif 'alerts' in body:
                boolean(body['alerts'],'alerts');value['alerts']=body['alerts'];db.execute('UPDATE market_saved_searches SET document=? WHERE id=?',(dumps(value),parts[3]))
            else:require(False,'invalid_search_action','Choose delete or alerts')
            return 200,dict(ok=True,search=value)
        if parts==['v1','market','notifications'] and method=='GET':
            rows=db.execute('SELECT document,read FROM market_notifications WHERE owner=? ORDER BY created DESC,id DESC LIMIT 100',(owner,)).fetchall()
            return 200,dict(ok=True,notifications=[dict(json.loads(row[0]),read=bool(row[1])) for row in rows],unread=db.execute('SELECT COUNT(*) FROM market_notifications WHERE owner=? AND read=0',(owner,)).fetchone()[0])
        if len(parts)==4 and parts[:3]==['v1','market','notifications'] and method=='POST':
            obj(body,{'request_id'},{'request_id'})
            if parts[3]=='read-all':
                db.execute('UPDATE market_notifications SET read=1 WHERE owner=?',(owner,));return 200,dict(ok=True)
            require(db.execute('SELECT 1 FROM market_notifications WHERE id=? AND owner=?',(parts[3],owner)).fetchone(),'notice_not_found','Notification belongs to another trainer',404)
            db.execute('UPDATE market_notifications SET read=1 WHERE id=?',(parts[3],));return 200,dict(ok=True)
        if parts==['v1','market','cash']:
            row=db.execute('SELECT amount FROM market_cash WHERE owner=?',(owner,)).fetchone();amount=row[0] if row else 0
            if method=='POST':
                obj(body,{'request_id'},{'request_id'});take=min(amount,MAX_COINS-self.wallet(db,owner)['balance'])
                if take:
                    self.post_money(db,'cash_'+digest(dumps([owner,body['request_id']])),'market_cash_claim',{'system:market_cash:'+owner:-take,owner:take},{})
                    db.execute('UPDATE market_cash SET amount=amount-? WHERE owner=?',(take,owner));amount-=take
            return 200,dict(ok=True,cash=amount,wallet=self.wallet(db,owner))
        if parts==['v1','market','mail']:
            if method=='GET':
                return 200,dict(ok=True,mail=[self.market_mail_view(json.loads(r[0])) for r in db.execute("SELECT document FROM market_mail WHERE sender=? OR recipient=? ORDER BY (status='pending') DESC,created DESC,id DESC LIMIT 100",(owner,owner))])
            self.trading_account(db,owner,True)
            obj(body,{'request_id','friend_code','subject','text','asset_ids','items','coins','compatibility'},{'request_id','friend_code','subject','text','compatibility'})
            recipient=self.market_recipient(db,owner,body['friend_code'])
            string(body['subject'],1,80,'subject');string(body['text'],0,500,'text')
            for participant in (owner,recipient):
                require(db.execute("SELECT COUNT(*) FROM market_mail WHERE status='pending' AND (sender=? OR recipient=?)",(participant,participant)).fetchone()[0]<100,'mailbox_full','Collect or return pending mail before adding more attachments',409)
            require(db.execute('SELECT COUNT(*) FROM market_mail WHERE sender=? AND created>?',(owner,self.clock()-3600)).fetchone()[0]<20,'mail_rate_limit','At most twenty messages per hour',409)
            mail=dict(id='mail_'+secrets.token_hex(16),sender_id=owner,recipient_id=recipient,subject=body['subject'],text=body['text'],status='pending',created_at=self.clock(),expires_at=self.clock()+30*86400)
            mail['bundle']=self.market_bundle(db,owner,body,'mail:'+mail['id']);self.market_save_mail(db,mail)
            self.market_notice(db,recipient,'mail:'+mail['id'],'mail',{'mail_id':mail['id'],'subject':mail['subject']})
            return 201,dict(ok=True,mail=mail)
        if len(parts)==5 and parts[:3]==['v1','market','mail'] and method=='POST':
            obj(body,{'request_id'},{'request_id'})
            row=db.execute('SELECT document FROM market_mail WHERE id=? AND (sender=? OR recipient=?)',(parts[3],owner,owner)).fetchone()
            require(row,'mail_not_found','Mail belongs to other trainers',404);mail=json.loads(row[0]);action=parts[4]
            if action=='claim':
                require(owner==mail['recipient_id'],'not_recipient','Only the recipient may collect',403)
                if mail['status']=='pending':
                    mail['delivery_ids']=self.market_deliver_bundle(db,mail['sender_id'],owner,mail['bundle'],'mail:'+mail['id'],'claim_'+mail['id'],'mail')
                    mail['status']='claimed';self.market_save_mail(db,mail)
                require(mail['status']=='claimed','mail_closed','Mail was returned or expired',409)
            else:
                require(action in ('cancel','reject'),'invalid_mail_action','Unknown mail action')
                require(owner==mail['sender_id' if action=='cancel' else 'recipient_id'],'not_member','Wrong mail participant',403)
                require(mail['status']!='claimed','mail_claimed','Collected attachments cannot be recalled',409)
                self.market_close_mail(db,mail,'returned')
            return 200,dict(ok=True,mail=mail)
        return None
