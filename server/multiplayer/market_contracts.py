"""Auctions, funded buy orders and bounded gameplay service contracts.

Borrowed custody is separate from ownership provenance and from tradeability.
Completion reads server assets; clients never submit training results or prices.
"""
import copy,json,re,secrets
MAX_COINS=9_999_999_999
KINDS=('auction','buy_order','training','rental','loan')
TERMINAL=('completed','cancelled','expired','defaulted','returned')

def bind_api(api):
    for name in ('obj','require','string','integer','dumps','digest','STATS'):
        globals()[name]=api[name]

class MarketContracts:
    def init_market_contracts(self,db):
        db.executescript('''
          CREATE TABLE IF NOT EXISTS market_contracts(id TEXT PRIMARY KEY,owner TEXT NOT NULL,kind TEXT NOT NULL,status TEXT NOT NULL,expires REAL NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
          CREATE INDEX IF NOT EXISTS market_contract_open ON market_contracts(status,kind,expires);
          CREATE INDEX IF NOT EXISTS market_contract_owner ON market_contracts(owner,created);
          CREATE TABLE IF NOT EXISTS market_custody(asset_id TEXT PRIMARY KEY,contract_id TEXT UNIQUE NOT NULL,holder TEXT NOT NULL,kind TEXT NOT NULL,expires REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS market_contract_bids(contract_id TEXT NOT NULL,bidder TEXT NOT NULL,amount INTEGER NOT NULL,created REAL NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(contract_id,revision));
          CREATE INDEX IF NOT EXISTS market_bidder ON market_contract_bids(bidder,contract_id);
        ''')

    def save_market_contract(self,db,value):
        db.execute('INSERT OR REPLACE INTO market_contracts VALUES(?,?,?,?,?,?,?)',(value['id'],value['owner_id'],value['kind'],value['status'],value['expires_at'],dumps(value),value['created_at']))

    def market_contract(self,db,contract_id):
        string(contract_id,1,80,'contract_id',r'[A-Za-z0-9_-]+')
        row=db.execute('SELECT document FROM market_contracts WHERE id=?',(contract_id,)).fetchone()
        require(row,'contract_not_found','Contract does not exist',404)
        value=json.loads(row[0]);self.refresh_market_contract(db,value);return value

    def market_contract_view(self,value,owner):
        public=copy.deepcopy(value)
        public['server_time']=self.clock()
        if owner not in (value['owner_id'],value.get('counterparty_id'),value.get('bidder_id')):
            for key in ('counterparty_id','bidder_id','delivery_ids'):public.pop(key,None)
        return public

    def market_custody_guard(self,db,asset_id,owner,operation):
        row=db.execute('SELECT * FROM market_custody WHERE asset_id=?',(asset_id,)).fetchone()
        if not row:return
        require(row['holder']==owner and row['expires']>self.clock(),'custody_expired','The temporary usage right has ended',409)
        allowed=('party','inspect','heal','battle')+ (('train','ev') if row['kind']=='training' else ())
        require(operation in allowed,'custody_restricted','Contract Pokemon cannot be transferred, released, evolved, bred, fused or equipped',409)

    def market_custody_info(self,db,asset_id):
        row=db.execute('SELECT contract_id,kind,expires FROM market_custody WHERE asset_id=?',(asset_id,)).fetchone()
        return dict(row) if row else None

    def market_match(self,snapshot,filters,price):
        for key in ('species','nature'):
            if key in filters and snapshot[key]!=filters[key].upper():return False
        for key in ('gender','shiny'):
            if key in filters and snapshot[key]!=filters[key]:return False
        for lo,hi,actual in [('min_level','max_level',snapshot['level']),('min_price','max_price',price)]:
            if filters.get(lo,actual)>actual or filters.get(hi,actual)<actual:return False
        if 'ability' in filters and filters['ability'].upper() not in (snapshot['ability'],snapshot.get('ability2')):return False
        for stat,value in filters.get('iv_min',{}).items():
            if snapshot['iv'][stat]<value:return False
        for stat,value in filters.get('iv_exact',{}).items():
            if snapshot['iv'][stat]!=value:return False
        if sum(value==31 for value in snapshot['iv'].values())<filters.get('min_perfect',0):return False
        fusion=re.fullmatch(r'B(\d+)H(\d+)',snapshot['species'])
        if 'fused' in filters and bool(fusion)!=filters['fused']:return False
        for key,index in [('body',1),('head',2)]:
            if key in filters and (not fusion or int(fusion[index])!=filters[key]):return False
        return True

    def market_contract_filters(self,db,filters):
        self.market_search(db,{'filters':filters})
        require(filters.get('category','pokemon')=='pokemon' and 'item_id' not in filters,'invalid_filters','Choose Pokemon conditions',400)
        return copy.deepcopy(filters)

    def create_market_contract(self,db,owner,body):
        self.trading_account(db,owner,True)
        obj(body,{'request_id','kind','terms','compatibility'},{'request_id','kind','terms','compatibility'})
        require(body['kind'] in KINDS,'invalid_contract','Unknown contract type')
        require(body['kind'] not in ('training','rental') or self.native_engine is not None,'native_unavailable','Training and rentals require the native gameplay service',409)
        compatibility=self.trading_compatibility(body['compatibility']);terms=copy.deepcopy(body['terms']);obj(terms)
        require(db.execute("SELECT COUNT(*) FROM market_contracts WHERE owner=? AND status IN ('open','active')",(owner,)).fetchone()[0]<20,'contract_limit','At most twenty open contracts',409)
        value=dict(id='ctr_'+secrets.token_hex(16),owner_id=owner,kind=body['kind'],status='open',revision=1,created_at=self.clock(),compatibility=compatibility,asset_rules_hash=self.asset_contract(self.catalog()),terms=terms)
        ref='contract:'+value['id'];bundle=dict(asset_ids=[],items={},coins=0,compatibility=compatibility)
        offer_seconds=terms.get('offer_seconds',86400);integer(offer_seconds,60,7*86400,'offer_seconds')
        value['expires_at']=self.clock()+offer_seconds
        if value['kind']=='auction':
            obj(terms,{'offer_seconds','asset_id','item_id','quantity','start_price','increment'},{'start_price','increment'})
            require(('asset_id' in terms)!=('item_id' in terms),'invalid_auction','Choose one Pokemon or one item stack')
            start=integer(terms['start_price'],1,MAX_COINS,'start_price');integer(terms['increment'],1,MAX_COINS,'increment')
            if 'asset_id' in terms:
                require('quantity' not in terms,'invalid_auction','Pokemon auctions contain exactly one Pokemon')
                asset=self.trading_asset(db,terms['asset_id'],owner,compatibility);value['snapshot']=asset['snapshot'];bundle['asset_ids']=[asset['id']]
            else:
                self.inventory_item(terms['item_id'],compatibility);bundle['items']={terms['item_id']:integer(terms.get('quantity'),1,9999,'quantity')}
            value.update(bid=0,hard_end=value['expires_at']+300)
            fee_base=start
        elif value['kind']=='buy_order':
            obj(terms,{'offer_seconds','category','item_id','quantity','unit_price','filters'},{'category','quantity','unit_price'})
            require(terms['category'] in ('pokemon','item'),'invalid_category','Choose Pokemon or items')
            quantity=integer(terms['quantity'],1,9999 if terms['category']=='item' else 100,'quantity')
            unit=integer(terms['unit_price'],1,MAX_COINS,'unit_price')
            bundle['coins']=integer(quantity*unit,1,MAX_COINS,'budget');fee_base=bundle['coins'];value['remaining']=quantity
            if terms['category']=='item':
                self.inventory_item(terms.get('item_id'),compatibility);require('filters' not in terms,'invalid_filters','Item orders use one approved item ID')
            else:
                require('item_id' not in terms,'invalid_filters','Pokemon orders use filters');terms['filters']=self.market_contract_filters(db,terms.get('filters',{}))
        elif value['kind'] in ('training','rental'):
            allowed={'offer_seconds','asset_id','duration','bond'}|({'reward','level','ev_min'} if value['kind']=='training' else {'fee'})
            obj(terms,allowed,{'asset_id','duration','bond'}|({'reward','level'} if value['kind']=='training' else {'fee'}))
            integer(terms['duration'],3600,7*86400 if value['kind']=='training' else 30*86400,'duration');integer(terms['bond'],0,MAX_COINS,'bond')
            asset=self.trading_asset(db,terms['asset_id'],owner,compatibility)
            require('full' in asset and not asset['snapshot'].get('item'),'asset_not_ready','Prepare the Pokemon and remove its held item first',409)
            bundle['asset_ids']=[asset['id']];value['snapshot']=asset['snapshot'];value['original_version']=asset.get('version',1)
            if value['kind']=='training':
                integer(terms['level'],asset['snapshot']['level'],100,'level');obj(terms.get('ev_min',{}),STATS)
                for stat,number in terms.get('ev_min',{}).items():integer(number,0,252,'ev_min.'+stat)
                require(sum(terms.get('ev_min',{}).values())<=510,'invalid_ev','EV goal exceeds 510')
                require(terms['level']>asset['snapshot']['level'] or any(asset['snapshot']['ev'][key]<number for key,number in terms.get('ev_min',{}).items()),'goal_already_met','Choose a goal above current attributes')
                bundle['coins']=integer(terms['reward'],1,MAX_COINS,'reward');fee_base=bundle['coins']
            else:fee_base=integer(terms['fee'],1,MAX_COINS,'fee')
        else:
            obj(terms,{'offer_seconds','principal','repayment','duration','filters'},{'principal','repayment','duration','filters'})
            principal=integer(terms['principal'],1,MAX_COINS,'principal')
            integer(terms['repayment'],principal,min(MAX_COINS,principal+principal//10),'repayment')
            integer(terms['duration'],3600,30*86400,'duration');terms['filters']=self.market_contract_filters(db,terms['filters'])
            require(not {'min_price','max_price'}.intersection(terms['filters']),'invalid_collateral_filters','Collateral conditions cannot imply a market valuation')
            bundle['coins']=principal;fee_base=principal
        value['bundle']=self.market_bundle(db,owner,bundle,ref)
        fee=min(25000,max(100,(fee_base*2+99)//100));value['listing_fee']=fee
        self.post_money(db,'fee_'+value['id'],'contract_fee',{owner:-fee,'system:fees':fee},{'contract_id':value['id']})
        self.save_market_contract(db,value);self.trading_event(db,'open_'+value['id'],[owner],'contract_open',value)
        return value

    def market_contract_sale(self,db,value,event,buyer,seller,price,delivery,asset=None,item_id=None,quantity=1):
        order=dict(id=event,listing_id=value['id'],buyer_id=buyer,seller_id=seller,asset_id=asset['id'] if asset else 'itm_'+item_id,price=price,currency='LINK',delivery_id=delivery['id'],created_at=self.clock(),kind='pokemon' if asset else 'item',snapshot=asset['snapshot'] if asset else {},asset_rules_hash=value['asset_rules_hash'])
        if item_id:order.update(item_id=item_id,quantity=quantity,unit_price=price//quantity)
        db.execute('INSERT INTO market_orders VALUES(?,?,?,?,?,?)',(event,value['id'],buyer,seller,dumps(order),self.clock()))
        self.trading_event(db,event,[buyer,seller],'contract_purchase',order)

    def bid_market_contract(self,db,owner,value,body):
        require(value['kind']=='auction' and value['status']=='open','auction_closed','Auction is not open',409)
        require(owner!=value['owner_id'],'own_contract','Cannot bid on your own auction',409)
        amount=integer(body.get('amount'),1,MAX_COINS,'amount')
        minimum=value['terms']['start_price'] if not value['bid'] else value['bid']+value['terms']['increment']
        require(amount>=minimum,'bid_too_low','Bid is below the current minimum',409)
        ref='bid:'+value['id'];self.reserve_money(db,owner,ref,amount)
        previous=value.get('bidder_id')
        if previous and previous!=owner:db.execute('DELETE FROM wallet_holds WHERE owner=? AND reference=?',(previous,ref))
        if previous and previous!=owner:self.market_notice(db,previous,'outbid:'+value['id']+':'+str(value['revision']),'outbid',{'contract_id':value['id'],'amount':amount})
        if value['expires_at']-self.clock()<60:value['expires_at']=min(value['hard_end'],self.clock()+60)
        value.update(bid=amount,bidder_id=owner,revision=value['revision']+1,bid_count=value.get('bid_count',0)+1);self.save_market_contract(db,value)
        db.execute('INSERT INTO market_contract_bids VALUES(?,?,?,?,?)',(value['id'],owner,amount,self.clock(),value['revision']))
        self.trading_event(db,'bid_'+value['id']+'_'+str(value['revision']),[owner],'auction_bid',{'contract_id':value['id'],'amount':amount})

    def fill_market_contract(self,db,owner,value,body):
        require(value['kind']=='buy_order' and value['status']=='open','order_closed','Buy order is not open',409)
        require(owner!=value['owner_id'],'own_contract','Cannot fill your own buy order',409)
        terms=value['terms'];buyer=value['owner_id'];ref='contract:'+value['id'];event='fill_'+secrets.token_hex(16)
        asset=None
        if terms['category']=='pokemon':
            require('quantity' not in body,'invalid_fill','Choose one Pokemon per fill')
            asset=self.trading_asset(db,body.get('asset_id'),owner,value['compatibility'])
            require(self.market_match(asset['snapshot'],terms['filters'],terms['unit_price']),'order_mismatch','Pokemon does not meet the posted conditions',409)
            self.lock_asset(db,asset['id'],owner,event);quantity=1
        else:
            require('asset_id' not in body,'invalid_fill','Choose an item quantity')
            quantity=integer(body.get('quantity'),1,value['remaining'],'quantity')
            self.hold_items(db,owner,event,{terms['item_id']:quantity})
        price=quantity*terms['unit_price'];remaining=value['remaining']-quantity
        self.reserve_money(db,buyer,ref,remaining*terms['unit_price'])
        self.market_payment(db,event,'buy_order_fill',buyer,owner,price,{'contract_id':value['id']})
        if asset:
            self.transfer_asset(db,asset['id'],owner,buyer,event);delivery=self.new_delivery(db,buyer,asset['id'],event,'buy_order')
        else:
            self.market_release(db,owner,event)
            self.post_items(db,event,'buy_order_fill',{(owner,terms['item_id']):-quantity,(buyer,terms['item_id']):quantity},{'contract_id':value['id']})
            delivery=self.new_item_delivery(db,buyer,terms['item_id'],quantity,event,'buy_order')
        self.market_contract_sale(db,value,event,buyer,owner,price,delivery,asset,None if asset else terms['item_id'],quantity)
        value.update(remaining=remaining,status='open' if remaining else 'completed',revision=value['revision']+1)
        if not remaining:self.market_release(db,buyer,ref)
        self.save_market_contract(db,value)

    def accept_market_contract(self,db,owner,value,body):
        require(value['kind'] in ('training','rental','loan') and value['status']=='open','contract_closed','Contract cannot be accepted',409)
        require(owner!=value['owner_id'],'own_contract','Cannot accept your own contract',409)
        require(value['kind']=='loan' or self.native_engine is not None,'native_unavailable','Training and rentals require the native gameplay service',409)
        terms=value['terms'];creator=value['owner_id'];ref='contract:'+value['id']
        if value['kind']=='loan':
            asset=self.trading_asset(db,body.get('asset_id'),owner,value['compatibility'])
            require(self.market_match(asset['snapshot'],terms['filters'],terms['principal']),'collateral_mismatch','Collateral does not meet the posted conditions',409)
            self.lock_asset(db,asset['id'],owner,ref);value.update(collateral_id=asset['id'],collateral_snapshot=asset['snapshot'])
            self.market_release(db,creator,ref)
            self.market_payment(db,'principal_'+value['id'],'loan_principal',creator,owner,terms['principal'],{'contract_id':value['id']})
        else:
            require('asset_id' not in body,'invalid_accept','This contract already identifies its Pokemon')
            self.reserve_money(db,owner,'bond:'+value['id'],terms['bond'])
            if value['kind']=='rental':self.market_payment(db,'rent_'+value['id'],'rental_fee',owner,creator,terms['fee'],{'contract_id':value['id']})
            asset_id=value['bundle']['asset_ids'][0]
            self.transfer_asset(db,asset_id,creator,owner,ref)
            db.execute('INSERT INTO market_custody VALUES(?,?,?,?,?)',(asset_id,value['id'],owner,value['kind'],self.clock()+terms['duration']))
        value.update(counterparty_id=owner,status='active',expires_at=self.clock()+terms['duration'],revision=value['revision']+1)
        self.save_market_contract(db,value)

    def market_training_done(self,db,value):
        asset=self.asset(db,value['bundle']['asset_ids'][0],value['counterparty_id']);terms=value['terms'];snapshot=asset['snapshot']
        return snapshot['species']==value['snapshot']['species'] and snapshot['level']>=terms['level'] and all(snapshot['ev'][key]>=number for key,number in terms.get('ev_min',{}).items())

    def return_market_custody(self,db,value):
        asset_id=value['bundle']['asset_ids'][0];holder=value['counterparty_id'];creator=value['owner_id']
        # Expiry cancels the owned job handle before removing a party reference;
        # a late native result can no longer mutate the returned Pokemon.
        for row in db.execute("SELECT document FROM ml_jobs WHERE owner=? AND status IN ('queued','running')",(holder,)).fetchall():
            job=json.loads(row[0])
            if asset_id in job['asset_ids']:self.fail_mainline_job(db,job,'contract_ended')
        assignment=self.mainline_assignment(db,asset_id)
        if assignment:
            db.execute('DELETE FROM ml_party WHERE asset_id=?',(asset_id,))
            character=self.mainline_character(db,assignment['character_id'],holder);character['revision']+=1;self.save_mainline_character(db,character)
        db.execute('DELETE FROM market_custody WHERE asset_id=? AND contract_id=?',(asset_id,value['id']))
        ref='contract:'+value['id'];self.lock_asset(db,asset_id,holder,ref)
        self.transfer_asset(db,asset_id,holder,creator,ref)
        value['delivery_ids']=[self.new_delivery(db,creator,asset_id,'return_'+value['id'],'contract_return')['id']]

    def close_market_contract(self,db,value,status):
        if value['status'] in TERMINAL:return
        creator=value['owner_id'];kind=value['kind'];ref='contract:'+value['id']
        if value['status']=='open':
            if kind=='auction' and value.get('bidder_id'):
                require(status=='completed','auction_has_bid','An auction with a bid cannot be cancelled',409)
                buyer=value['bidder_id'];bidref='bid:'+value['id'];self.market_release(db,buyer,bidref)
                deliveries=self.market_deliver_bundle(db,creator,buyer,value['bundle'],ref,'auction_assets_'+value['id'],'auction')
                self.market_payment(db,'auction_'+value['id'],'auction',buyer,creator,value['bid'],{'contract_id':value['id']})
                value['delivery_ids']=deliveries
                asset=self.asset(db,value['bundle']['asset_ids'][0],buyer) if value['bundle']['asset_ids'] else None
                item_id=next(iter(value['bundle']['items']),None);quantity=value['bundle']['items'].get(item_id,1)
                delivery={'id':deliveries[0]}
                self.market_contract_sale(db,value,'sale_'+value['id'],buyer,creator,value['bid'],delivery,asset,item_id,quantity)
            else:value['delivery_ids']=self.market_return_bundle(db,creator,value['bundle'],ref,'return_'+value['id'])
        elif kind in ('training','rental'):
            done=kind=='training' and self.market_training_done(db,value)
            holder=value['counterparty_id'];self.return_market_custody(db,value)
            self.market_release(db,holder,'bond:'+value['id']);self.market_release(db,creator,ref)
            if kind=='training':
                if done:
                    status='completed';self.market_payment(db,'reward_'+value['id'],'training_reward',creator,holder,value['terms']['reward'],{'contract_id':value['id']})
                else:self.market_payment(db,'penalty_'+value['id'],'training_bond',holder,creator,value['terms']['bond'],{'contract_id':value['id']})
        elif kind=='loan':
            borrower=value['counterparty_id'];asset_id=value['collateral_id']
            recipient=creator if status=='defaulted' else borrower
            if status!='defaulted':self.market_payment(db,'repay_'+value['id'],'loan_repayment',borrower,creator,value['terms']['repayment'],{'contract_id':value['id']})
            if recipient==borrower:
                lock=db.execute('SELECT reference FROM asset_locks WHERE asset_id=?',(asset_id,)).fetchone()
                require(lock and lock[0]==ref,'asset_lock_lost','Collateral lock differs',409)
                db.execute('DELETE FROM asset_locks WHERE asset_id=? AND reference=?',(asset_id,ref))
            else:self.transfer_asset(db,asset_id,borrower,creator,ref)
            value['delivery_ids']=[self.new_delivery(db,recipient,asset_id,'close_'+value['id'],'loan_collateral')['id']]
        value.update(status=status,revision=value['revision']+1,closed_at=self.clock());self.save_market_contract(db,value)
        members=[creator]+([value['counterparty_id']] if value.get('counterparty_id') else [])+([value['bidder_id']] if value.get('bidder_id') else [])
        self.trading_event(db,'close_'+value['id'],list(set(members)),'contract_'+status,{'contract_id':value['id'],'kind':kind,'status':status})
        for participant in set(members):self.market_notice(db,participant,'contract:'+value['id']+':closed','contract_closed',{'contract_id':value['id'],'status':status})

    def refresh_market_contract(self,db,value,current=None):
        if value['status'] in TERMINAL:return
        if value['status']=='open':
            current=current or self.catalog()
            if value['asset_rules_hash']!=self.asset_contract(current):
                if value.get('bidder_id'):
                    self.market_release(db,value['bidder_id'],'bid:'+value['id']);value.pop('bidder_id');value['bid']=0
                self.close_market_contract(db,value,'cancelled');return
            if value['compatibility']!=current['compatibility']:
                value.update(compatibility=current['compatibility'],revision=value['revision']+1);self.save_market_contract(db,value)
        if value['expires_at']<=self.clock():
            status='defaulted' if value['kind']=='loan' and value['status']=='active' else 'completed' if value['kind']=='auction' and value.get('bidder_id') else 'expired'
            self.close_market_contract(db,value,status)

    def tick_market_contracts(self,db):
        rows=db.execute("SELECT document FROM market_contracts WHERE status IN ('open','active') ORDER BY expires LIMIT 200").fetchall()
        current=self.catalog() if rows else None
        for row in rows:self.refresh_market_contract(db,json.loads(row[0]),current)

    def dispatch_market_contracts(self,db,owner,method,parts,body):
        if parts[:3]!=['v1','market','contracts']:return None
        if len(parts)==3:
            if method=='POST':return 201,dict(ok=True,contract=self.market_contract_view(self.create_market_contract(db,owner,body),owner))
            rows=db.execute("SELECT document FROM market_contracts WHERE owner=? OR json_extract(document,'$.counterparty_id')=? OR json_extract(document,'$.bidder_id')=? OR EXISTS(SELECT 1 FROM market_contract_bids b WHERE b.contract_id=market_contracts.id AND b.bidder=?) ORDER BY created DESC,id DESC LIMIT 100",(owner,owner,owner,owner)).fetchall()
            return 200,dict(ok=True,contracts=[self.market_contract_view(json.loads(row[0]),owner) for row in rows])
        if len(parts)==4 and parts[3]=='search' and method=='POST':
            obj(body,{'request_id','kind','cursor'},{'kind'});require(body['kind'] in KINDS,'invalid_contract','Choose a contract type')
            cursor=body.get('cursor');sql="kind=? AND status='open' AND expires>?";args=[body['kind'],self.clock()]
            if cursor:
                obj(cursor,{'created','id'},{'created','id'});require(type(cursor['created']) in (int,float),'invalid_cursor','Invalid cursor');string(cursor['id'],1,80,'id',r'[A-Za-z0-9_-]+')
                sql+=' AND (created<? OR (created=? AND id<?))';args.extend([cursor['created'],cursor['created'],cursor['id']])
            rows=db.execute('SELECT document FROM market_contracts WHERE '+sql+' ORDER BY created DESC,id DESC LIMIT 21',args).fetchall();page=[json.loads(row[0]) for row in rows[:20]]
            next_cursor={'created':page[-1]['created_at'],'id':page[-1]['id']} if len(rows)>20 else None
            for value in page:self.refresh_market_contract(db,value)
            return 200,dict(ok=True,contracts=[self.market_contract_view(v,owner) for v in page if v['status']=='open'],next_cursor=next_cursor)
        value=self.market_contract(db,parts[3])
        if len(parts)==4 and method=='GET':
            require(value['status']=='open' or owner in (value['owner_id'],value.get('counterparty_id'),value.get('bidder_id')) or db.execute('SELECT 1 FROM market_contract_bids WHERE contract_id=? AND bidder=?',(value['id'],owner)).fetchone(),'contract_private','Closed contract belongs to other trainers',403)
            return 200,dict(ok=True,contract=self.market_contract_view(value,owner))
        require(len(parts)==5 and method=='POST','not_found','Unknown contract endpoint',404)
        action=parts[4]
        fields={'bid':{'amount'},'accept':{'asset_id'},'fill':{'asset_id','quantity'},'cancel':set(),'return':set(),'finish':set(),'repay':set()}
        require(action in fields,'invalid_contract_action','Unknown contract action')
        obj(body,{'request_id','revision','compatibility'}|fields[action],{'request_id','revision'})
        require(type(body['revision']) is int and body['revision']==value['revision'],'contract_changed','Review the current contract terms',409)
        if action in ('bid','accept','fill'):
            self.trading_account(db,owner,True)
            require(self.trading_compatibility(body.get('compatibility'))==value['compatibility'],'asset_incompatible','Refresh this contract on the current build',409)
        if action=='bid':self.bid_market_contract(db,owner,value,body)
        elif action=='fill':self.fill_market_contract(db,owner,value,body)
        elif action=='accept':self.accept_market_contract(db,owner,value,body)
        elif action=='cancel':
            require(owner==value['owner_id'] and value['status']=='open','cannot_cancel','Only an unaccepted contract may be cancelled',409)
            self.close_market_contract(db,value,'cancelled')
        elif action=='repay':
            require(value['kind']=='loan' and value['status']=='active' and owner==value['counterparty_id'],'cannot_repay','Only the active borrower may repay',409)
            self.close_market_contract(db,value,'completed')
        elif action=='finish':
            require(value['kind']=='training' and value['status']=='active' and owner in (value['owner_id'],value['counterparty_id']),'cannot_finish','Not a training participant',409)
            require(self.market_training_done(db,value),'training_incomplete','Server attributes do not meet the posted goal',409)
            self.close_market_contract(db,value,'completed')
        else:
            require(value['kind'] in ('rental','training') and value['status']=='active' and owner==value['counterparty_id'],'cannot_return','Only the current holder may return',409)
            self.close_market_contract(db,value,'returned')
        return 200,dict(ok=True,contract=self.market_contract_view(value,owner))
