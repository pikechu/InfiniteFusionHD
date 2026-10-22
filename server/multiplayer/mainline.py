"""Authoritative online characters and native mechanics job settlement.

Cloud saves are projections. They never set ownership, Pokemon attributes,
wallets or item balances in these tables.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import secrets
import time
import threading
import logging

try:
    from .native_engine import NativeEngine
except ImportError:
    from native_engine import NativeEngine


def bind_api(api):
    for name in ('obj','require','string','integer','boolean','dumps','digest','validate_trade_snapshot','validate_compatibility','APIError','STATS'):
        globals()[name] = api[name]


class MainlineFeatures:
    def start_mainline_maintenance(self):
        self.mainline_stop = threading.Event()
        self.mainline_thread = None
        if self.native_engine is None:
            return
        def maintain():
            while not self.mainline_stop.wait(0.25):
                try:
                    with self.lock:
                        if self.mainline_stop.is_set():
                            break
                        with self.connect() as database:
                            database.execute('BEGIN IMMEDIATE')
                            self.tick_mainline_jobs(database)
                except Exception:
                    logging.getLogger('multiplayer').exception('Native mainline maintenance failed')
                    self.mainline_stop.wait(1)
        self.mainline_thread = threading.Thread(target=maintain,name='mainline-native',daemon=True)
        self.mainline_thread.start()

    def stop_mainline_maintenance(self):
        if getattr(self,'mainline_stop',None):
            self.mainline_stop.set()
        thread = getattr(self,'mainline_thread',None)
        if thread and thread is not threading.current_thread():
            thread.join(timeout=5)
    def init_mainline(self,db):
        self.mainline_epoch = secrets.token_hex(16)
        db.executescript('''
            CREATE TABLE IF NOT EXISTS ml_characters(id TEXT PRIMARY KEY,owner TEXT NOT NULL,name TEXT NOT NULL,revision INTEGER NOT NULL,document TEXT NOT NULL,created REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS ml_character_owner ON ml_characters(owner,created);
            CREATE TABLE IF NOT EXISTS ml_party(character_id TEXT NOT NULL,slot INTEGER NOT NULL CHECK(slot>=0 AND slot<6),asset_id TEXT UNIQUE NOT NULL,PRIMARY KEY(character_id,slot));
            CREATE TABLE IF NOT EXISTS ml_jobs(id TEXT PRIMARY KEY,owner TEXT NOT NULL,character_id TEXT NOT NULL,operation TEXT NOT NULL,status TEXT NOT NULL,document TEXT NOT NULL,created REAL NOT NULL,expires REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS ml_job_owner ON ml_jobs(owner,status,created);
            CREATE TABLE IF NOT EXISTS ml_claims(owner TEXT NOT NULL,scope TEXT NOT NULL,document TEXT NOT NULL,PRIMARY KEY(owner,scope));
            CREATE TABLE IF NOT EXISTS ml_commands(job_id TEXT NOT NULL,sequence INTEGER NOT NULL,document TEXT NOT NULL,PRIMARY KEY(job_id,sequence));
            CREATE TABLE IF NOT EXISTS ml_credits(owner TEXT NOT NULL,event_id TEXT NOT NULL,amount INTEGER NOT NULL,PRIMARY KEY(owner,event_id));
            CREATE TABLE IF NOT EXISTS ml_eggs(id TEXT PRIMARY KEY,owner TEXT NOT NULL,character_id TEXT NOT NULL,status TEXT NOT NULL,ready REAL NOT NULL,document TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS ml_trade_evolutions(id TEXT PRIMARY KEY,owner TEXT NOT NULL,asset_id TEXT NOT NULL,status TEXT NOT NULL,document TEXT NOT NULL);
        ''')
        columns = {row[1] for row in db.execute('PRAGMA table_info(ml_commands)')}
        if 'dispatched' not in columns:
            db.execute('ALTER TABLE ml_commands ADD COLUMN dispatched INTEGER NOT NULL DEFAULT 0')
        self.native_engine = None
        self.native_engine_error = None
        runtime = os.environ.get('KIF_MAINLINE_GAME_ROOT')
        if runtime:
            try:
                self.native_engine = NativeEngine(runtime,Path(self.database).with_suffix('.engine'))
            except (ValueError,OSError) as error:
                self.native_engine_error = type(error).__name__
        # A service restart cannot infer completion from an old process/PID.
        # Queued/running operations have not settled any resource changes yet.
        for row in db.execute("SELECT document FROM ml_jobs WHERE status IN ('queued','running')").fetchall():
            job = json.loads(row[0])
            self.fail_mainline_job(db,job,'server_restart')

    def mainline_config(self):
        return {'enabled':self.native_engine is not None,'native_required':True,'currency':'LINK','max_party':6,'asset_source':'server_managed','supported_operations':['inspect','train','ev','learn','evolve','preview_evolution','heal','preview_fusion','fuse','split','breed','use_item','equip','battle'],'battle_authority':self.native_engine is not None,'costs':{'fuse':1000,'split':500,'learn':1000,'breed':2000,'ev_reduce_per_item':250},'starter_per_account':1,'egg_incubation_seconds':300}

    def mainline_character(self,db,character_id,owner):
        string(character_id,1,80,'character_id',r'[A-Za-z0-9_-]+')
        row = db.execute('SELECT * FROM ml_characters WHERE id=? AND owner=?',(character_id,owner)).fetchone()
        require(row is not None,'character_not_found','Online character does not belong to this account',404)
        return json.loads(row['document'])

    def save_mainline_character(self,db,character):
        db.execute('UPDATE ml_characters SET revision=?,document=? WHERE id=?',(character['revision'],dumps(character),character['id']))

    def mainline_character_view(self,db,character):
        value = copy.deepcopy(character)
        value['authority_epoch'] = self.mainline_epoch
        party = []
        for row in db.execute('SELECT asset_id FROM ml_party WHERE character_id=? ORDER BY slot',(character['id'],)):
            asset = self.asset(db,row[0],character['owner_id'])
            party.append(asset)
        value['party'] = party
        value['wallet'] = self.wallet(db,character['owner_id'])
        return value

    def mainline_assignment(self,db,asset_id):
        return db.execute('SELECT character_id,slot FROM ml_party WHERE asset_id=?',(asset_id,)).fetchone()

    def save_mainline_job(self,db,job):
        db.execute('INSERT OR REPLACE INTO ml_jobs VALUES(?,?,?,?,?,?,?,?)',(job['id'],job['owner_id'],job['character_id'],job['operation'],job['status'],dumps(job),job['created_at'],job['expires_at']))

    def mainline_job_view(self,job):
        keys = ('id','character_id','operation','status','created_at','expires_at','error_code','result','prompt','submitted_sequence')
        return {key:copy.deepcopy(job[key]) for key in keys if key in job}

    def release_mainline_job(self,db,job):
        reference = 'mainline:'+job['id']
        db.execute('DELETE FROM asset_locks WHERE reference=?',(reference,))
        db.execute('DELETE FROM wallet_holds WHERE reference=?',(reference,))
        db.execute('DELETE FROM item_holds WHERE reference=?',(reference,))
        self.touch_inventory(db,job['owner_id'])

    def fail_mainline_job(self,db,job,code):
        cancel=getattr(self.native_engine,'cancel',None)
        if cancel:cancel(job['id'])
        job.update(status='failed',error_code=code)
        self.release_mainline_job(db,job)
        self.save_mainline_job(db,job)

    def require_mainline_idle(self,db,owner):
        row = db.execute("SELECT 1 FROM ml_jobs WHERE owner=? AND status IN ('queued','running')",(owner,)).fetchone()
        require(row is None,'mainline_pending','Recover the active native operation first',409)

    def enqueue_mainline_job(self,db,owner,character,operation,assets,params,coins=0,items=None,extra_inputs=()):
        require(self.native_engine is not None,'native_unavailable','Server-native mainline engine is not configured',503)
        self.require_mainline_idle(db,owner)
        require(db.execute("SELECT COUNT(*) FROM ml_jobs WHERE status IN ('queued','running')").fetchone()[0]<16,'native_busy','Native engine queue is full',503)
        job_id = 'job_'+secrets.token_hex(16)
        reference = 'mainline:'+job_id
        inputs,hashes = [],{}
        compatibility = self.catalog()['compatibility']
        for asset in assets:
            self.trading_asset(db,asset['id'],owner,compatibility)
            assigned = self.mainline_assignment(db,asset['id'])
            require(assigned is None or assigned['character_id']==character['id'],'asset_assigned','Switch to the character currently using this asset',409)
            current = self.lock_asset(db,asset['id'],owner,reference)
            value = current.get('full',current['snapshot'])
            inputs.append(copy.deepcopy(value))
            hashes[asset['id']] = digest(dumps(value))
        self.reserve_money(db,owner,reference,coins)
        self.hold_items(db,owner,reference,items or {})
        nonce = secrets.token_hex(16)
        trainer_id = int(hashlib.sha256(owner.encode()).hexdigest()[:8],16)
        native = {'nonce':nonce,'operation':operation,'inputs':inputs+list(extra_inputs),'params':copy.deepcopy(params),'owner':{'id':trainer_id,'name':character['name'],'gender':character.get('gender',0)},'compatibility':compatibility}
        job = {'id':job_id,'owner_id':owner,'character_id':character['id'],'operation':operation,'status':'queued','asset_ids':[a['id'] for a in assets],'input_hashes':hashes,'native':native,'coin_cost':coins,'item_cost':items or {},'created_at':self.clock(),'expires_at':self.clock()+(1800 if operation=='battle' else 180)}
        self.save_mainline_job(db,job)
        return job

    def ensure_attachment_backing(self,db,asset):
        if asset.get('attachment_backed'):
            return
        item = asset['snapshot'].get('item')
        if item:
            self.post_items(db,'attachment_'+asset['id'],'legacy_attachment',{('asset:'+asset['id'],item):1,('system:issuer',item):-1},{'asset_id':asset['id']})
        asset['attachment_backed'] = True

    def reconcile_attachment(self,db,asset,before_item,after_item,transaction_id):
        if before_item==after_item:
            return
        changes = {}
        if before_item:
            changes['asset:'+asset['id'],before_item] = -1
            changes['system:consumed',before_item] = 1
        if after_item:
            changes['asset:'+asset['id'],after_item] = 1
            changes['system:issuer',after_item] = -1
        self.post_items(db,transaction_id,'native_attachment',changes,{'asset_id':asset['id']})

    def new_mainline_asset(self,db,owner,full,job,origin):
        full = validate_trade_snapshot(full)
        catalog = self.catalog()
        asset = {'id':'pkm_'+secrets.token_hex(16),'owner_id':owner,'snapshot':full['pokemon'],'full':full,'source':'server_managed','catalog_version':1,'catalog_hash':digest(dumps(catalog)),'asset_rules_hash':self.asset_contract(catalog),'compatibility':catalog['compatibility'],'version':1,'origin':{'kind':origin,'job_id':job['id']},'created_at':self.clock()}
        self.ensure_attachment_backing(db,asset)
        db.execute('INSERT INTO hosted_assets VALUES(?,?,?)',(asset['id'],owner,dumps(asset)))
        return asset

    def update_mainline_asset(self,db,asset,full,job):
        full = validate_trade_snapshot(full)
        self.ensure_attachment_backing(db,asset)
        self.reconcile_attachment(db,asset,asset['snapshot'].get('item'),full['pokemon'].get('item'),'attach_'+job['id']+'_'+asset['id'])
        asset.update(snapshot=full['pokemon'],full=full,version=asset.get('version',1)+1)
        db.execute('UPDATE hosted_assets SET document=? WHERE id=?',(dumps(asset),asset['id']))
        return asset

    def settle_mainline_job(self,db,job,result):
        owner = job['owner_id']
        character = self.mainline_character(db,job['character_id'],owner)
        operation = job['operation']
        if operation=='battle':
            return self.settle_mainline_battle(db,job,character,result)
        fulls = result.get('pokemon')
        require(type(fulls) is list and 1<=len(fulls)<=6,'native_result_invalid','Native result has an invalid roster',500)
        fulls = [validate_trade_snapshot(value) for value in fulls]
        assets = []
        reference = 'mainline:'+job['id']
        for asset_id in job['asset_ids']:
            asset = self.asset(db,asset_id,owner)
            lock = db.execute('SELECT reference FROM asset_locks WHERE asset_id=?',(asset_id,)).fetchone()
            require(lock and lock[0]==reference and digest(dumps(asset.get('full',asset['snapshot'])))==job['input_hashes'][asset_id],'native_input_changed','Native input is no longer current',409)
            assets.append(asset)
        expected = 2 if operation=='split' else (len(assets) if operation in ('inspect','heal') else 1)
        require(len(fulls)==expected,'native_result_invalid','Native result count differs',500)
        self.release_mainline_job(db,job)
        coins = job['coin_cost']
        self.post_money(db,job['id'],'mainline_'+operation,{owner:-coins,'system:services':coins},{'character_id':character['id']})
        if job['item_cost'] and operation!='equip':
            changes = {}
            for item_id,quantity in job['item_cost'].items():
                changes[owner,item_id],changes['system:consumed',item_id] = -quantity,quantity
            self.post_items(db,job['id'],'mainline_'+operation,changes,{'character_id':character['id']})
        output_ids = []
        if operation=='starter':
            expected_owner = job['native']['owner']
            require(fulls[0]['pokemon']['species']==job['native']['params']['species'] and fulls[0]['pokemon']['level']==5 and fulls[0]['pokemon']['item'] is None and fulls[0]['pokemon']['shiny'] is False and fulls[0]['pokemon']['owner']['id']==expected_owner['id'],'native_result_invalid','Starter result differs from the approved request',500)
            require(not db.execute("SELECT 1 FROM ml_claims WHERE owner=? AND scope='starter'",(owner,)).fetchone(),'starter_already_granted','Starter was already issued',409)
            asset = self.new_mainline_asset(db,owner,fulls[0],job,'starter')
            output_ids = [asset['id']]
            db.execute('INSERT INTO ml_party VALUES(?,?,?)',(character['id'],0,asset['id']))
            db.execute("INSERT INTO ml_claims VALUES(?,'starter',?)",(owner,dumps({'job_id':job['id'],'asset_id':asset['id']})))
            amount = min(1000,9_999_999_999-self.wallet(db,owner)['balance'])
            self.post_money(db,'starter_'+job['id'],'starter_funds',{owner:amount,'system:issuer':-amount},{'character_id':character['id']})
            self.post_items(db,'starter_'+job['id'],'starter_supplies',{(owner,'POTION'):5,('system:issuer','POTION'):-5,(owner,'POKEBALL'):10,('system:issuer','POKEBALL'):-10},{'character_id':character['id']})
            character['status'] = 'ready'
        elif operation in ('preview_fusion','preview_evolution'):
            job['result'] = {'preview':fulls[0]['pokemon'],'coin_cost':1000 if operation=='preview_fusion' else 0}
        elif operation=='breed':
            egg_id='egg_'+secrets.token_hex(16)
            ready=self.clock()+self.mainline_config()['egg_incubation_seconds']
            egg={'id':egg_id,'owner_id':owner,'character_id':character['id'],'status':'incubating','ready_at':ready,'parent_ids':job['asset_ids'],'full':fulls[0],'job_id':job['id']}
            db.execute('INSERT INTO ml_eggs VALUES(?,?,?,?,?,?)',(egg_id,owner,character['id'],'incubating',ready,dumps(egg)))
            job['result']={'egg_id':egg_id,'ready_at':ready}
        elif operation=='equip':
            asset=assets[0];self.ensure_attachment_backing(db,asset)
            before,after=asset['snapshot'].get('item'),fulls[0]['pokemon'].get('item')
            require(after==job['native']['params'].get('item_id'),'native_result_invalid','Held-item result differs',500)
            changes={}
            if before:
                changes['asset:'+asset['id'],before]=-1;changes[owner,before]=1
            if after:
                changes[owner,after]=changes.get((owner,after),0)-1
                changes['asset:'+asset['id'],after]=changes.get(('asset:'+asset['id'],after),0)+1
            if changes:self.post_items(db,job['id'],'native_equip',changes,{'asset_id':asset['id']})
            asset.update(snapshot=fulls[0]['pokemon'],full=fulls[0],version=asset.get('version',1)+1)
            db.execute('UPDATE hosted_assets SET document=? WHERE id=?',(dumps(asset),asset['id']))
            output_ids=[asset['id']]
        elif operation=='fuse':
            require(len(assets)==2 and len(result.get('lineage',[]))==2,'native_result_invalid','Fusion lineage is incomplete',500)
            assignments = [self.mainline_assignment(db,a['id']) for a in assets]
            for asset in assets:
                self.ensure_attachment_backing(db,asset)
            fused = self.new_mainline_asset(db,owner,fulls[0],job,'fusion')
            # Reconcile the newly created body attachment against its existing
            # original: moving it must not create a second circulation unit.
            if fused['snapshot'].get('item'):
                self.post_items(db,'fusion_attach_'+job['id'],'fusion_attachment',{('asset:'+assets[0]['id'],fused['snapshot']['item']):-1,('system:issuer',fused['snapshot']['item']):1},{'fusion_id':fused['id']})
            for asset in assets:
                self.ensure_attachment_backing(db,asset)
                asset['owner_id'] = 'system:fusion:'+fused['id']
                db.execute('DELETE FROM ml_party WHERE asset_id=?',(asset['id'],))
                db.execute('UPDATE hosted_assets SET owner=?,document=? WHERE id=?',(asset['owner_id'],dumps(asset),asset['id']))
                db.execute('UPDATE showcases SET active=0 WHERE owner=? AND document LIKE ?',(owner,'%'+asset['id']+'%'))
            fused['lineage_ids'] = [a['id'] for a in assets]
            fused['lineage'] = result['lineage']
            fused['fusion_base_exp'] = result['fusion_base_exp']
            db.execute('UPDATE hosted_assets SET document=? WHERE id=?',(dumps(fused),fused['id']))
            if any(a is not None for a in assignments):
                ids = [r[0] for r in db.execute('SELECT asset_id FROM ml_party WHERE character_id=? ORDER BY slot',(character['id'],))]
                ids.append(fused['id'])
                self.replace_mainline_party(db,character['id'],ids)
            output_ids = [fused['id']]
        elif operation=='split':
            fused = assets[0]
            ids = fused.get('lineage_ids',[])
            require(len(ids)==2,'native_result_invalid','Fusion has no authoritative lineage',500)
            assignment = self.mainline_assignment(db,fused['id'])
            parents = [self.asset(db,value,'system:fusion:'+fused['id']) for value in ids]
            for index,(parent,full) in enumerate(zip(parents,fulls)):
                parent.update(owner_id=owner,snapshot=full['pokemon'],full=full,version=parent.get('version',1)+1,attachment_backed=True)
                db.execute('UPDATE hosted_assets SET owner=?,document=? WHERE id=?',(owner,dumps(parent),parent['id']))
            item = fused['snapshot'].get('item')
            if item:
                self.post_items(db,'split_attach_'+job['id'],'split_attachment',{('asset:'+fused['id'],item):-1,('asset:'+parents[0]['id'],item):1},{'fusion_id':fused['id']})
            fused['owner_id'] = 'system:split:'+job['id']
            db.execute('UPDATE hosted_assets SET owner=?,document=? WHERE id=?',(fused['owner_id'],dumps(fused),fused['id']))
            db.execute('DELETE FROM ml_party WHERE asset_id=?',(fused['id'],))
            if assignment:
                roster = [r[0] for r in db.execute('SELECT asset_id FROM ml_party WHERE character_id=? ORDER BY slot',(character['id'],))]
                roster += ids[:max(0,6-len(roster))]
                self.replace_mainline_party(db,character['id'],roster)
            output_ids = ids
        else:
            for asset,full in zip(assets,fulls):
                if operation=='inspect':
                    require(asset['snapshot']==full['pokemon'],'native_result_invalid','Preparation must preserve the existing Pokemon attributes',500)
                self.update_mainline_asset(db,asset,full,job)
                output_ids.append(asset['id'])
        character['revision'] += 1
        self.save_mainline_character(db,character)
        job.update(status='completed',result=dict(job.get('result',{}),asset_ids=output_ids,character_revision=character['revision']))
        self.save_mainline_job(db,job)
        self.trading_event(db,job['id'],[owner],'mainline_'+operation,{'character_id':character['id'],'asset_ids':output_ids,'coin_cost':coins,'item_cost':job['item_cost']})

    def tick_mainline_jobs(self,db):
        self.tick_trade_evolutions(db)
        rows = db.execute("SELECT document FROM ml_jobs WHERE status IN ('queued','running') ORDER BY created LIMIT 16").fetchall()
        for row in rows:
            job = json.loads(row[0])
            if self.clock()>=job['expires_at']:
                self.fail_mainline_job(db,job,'native_timeout')
                continue
            if self.native_engine is None:
                continue
            db.execute('SAVEPOINT native_job')
            try:
                if job['status']=='queued':
                    active = sum(process.poll() is None for process in getattr(self.native_engine,'processes',{}).values())
                    if active>=2:
                        db.execute('RELEASE native_job')
                        continue
                    self.native_engine.start(job['id'],job['native'])
                    job['status'] = 'running'
                    self.save_mainline_job(db,job)
                kind,value = self.native_engine.poll(job['id'],job['native']['nonce'])
                for command in db.execute('SELECT sequence,document FROM ml_commands WHERE job_id=? AND dispatched=0 ORDER BY sequence',(job['id'],)).fetchall():
                    self.native_engine.command(job['id'],job['native']['nonce'],command['sequence'],json.loads(command['document']))
                    db.execute('UPDATE ml_commands SET dispatched=1 WHERE job_id=? AND sequence=?',(job['id'],command['sequence']))
                if kind=='result':
                    require(value.get('ok') is True,'native_validation','Native engine declined the operation',409)
                    self.settle_mainline_job(db,job,value['result'])
                elif kind=='prompt':
                    require(type(value.get('sequence')) is int and 0<=value['sequence']<1000 and type(value.get('state')) is dict,'native_prompt_invalid','Invalid native input prompt',500)
                    job['prompt'] = {'sequence':value['sequence'],'state':value['state'],'deadline':value['deadline']}
                    self.save_mainline_job(db,job)
                db.execute('RELEASE native_job')
            except (APIError,ValueError,RuntimeError,OSError,KeyError,TypeError):
                db.execute('ROLLBACK TO native_job')
                db.execute('RELEASE native_job')
                self.fail_mainline_job(db,job,'native_validation')

    def queue_trade_evolution(self,db,event_id,asset_id,owner,counterpart=None):
        if self.native_engine is None:
            return
        event='te_'+digest(dumps([event_id,asset_id]))
        asset=self.asset(db,asset_id,owner)
        document={'id':event,'owner':owner,'asset_id':asset_id,'event_id':event_id,'input_hash':digest(dumps(asset.get('full',asset['snapshot']))),'counterpart':counterpart,'status':'pending'}
        cursor=db.execute('INSERT OR IGNORE INTO ml_trade_evolutions VALUES(?,?,?,?,?)',(event,owner,asset_id,'pending',dumps(document)))
        if cursor.rowcount:
            db.execute('INSERT INTO asset_locks VALUES(?,?)',(asset_id,'trade_evolution:'+event))

    def tick_trade_evolutions(self,db):
        if self.native_engine is None:
            return
        for row in db.execute("SELECT document FROM ml_trade_evolutions WHERE status IN ('pending','running') LIMIT 32").fetchall():
            event=json.loads(row[0]);owner=event['owner'];reference='trade_evolution:'+event['id']
            if event['status']=='running':
                job_row=db.execute('SELECT document FROM ml_jobs WHERE id=?',(event['job_id'],)).fetchone()
                job=json.loads(job_row[0])
                if job['status'] in ('queued','running'):
                    continue
                if job['status']=='completed':event['status']='completed'
                elif job.get('error_code')=='server_restart':
                    event['status']='pending'
                    db.execute('INSERT OR IGNORE INTO asset_locks VALUES(?,?)',(event['asset_id'],reference))
                else:event['status']='failed'
            if event['status']=='pending':
                if db.execute("SELECT COUNT(*) FROM ml_jobs WHERE status IN ('queued','running')").fetchone()[0]>=16:break
                if db.execute("SELECT 1 FROM ml_jobs WHERE owner=? AND status IN ('queued','running')",(owner,)).fetchone():continue
                asset=self.asset(db,event['asset_id'])
                if asset['owner_id']!=owner or digest(dumps(asset.get('full',asset['snapshot'])))!=event['input_hash']:
                    event['status']='superseded'
                    db.execute('DELETE FROM asset_locks WHERE asset_id=? AND reference=?',(asset['id'],reference))
                else:
                    character_row=db.execute('SELECT document FROM ml_characters WHERE owner=? ORDER BY created LIMIT 1',(owner,)).fetchone()
                    if character_row:character=json.loads(character_row[0])
                    else:
                        character={'id':'chr_'+secrets.token_hex(16),'owner_id':owner,'name':'交易托管','gender':0,'revision':1,'status':'ready','service_only':True,'created_at':self.clock()}
                        db.execute('INSERT INTO ml_characters VALUES(?,?,?,?,?,?)',(character['id'],owner,character['name'],1,dumps(character),self.clock()))
                    db.execute('DELETE FROM asset_locks WHERE asset_id=? AND reference=?',(asset['id'],reference))
                    other=[event['counterpart']] if event['counterpart'] else []
                    job=self.enqueue_mainline_job(db,owner,character,'trade_evolve',[asset],{'method':'trade','optional':True},extra_inputs=other)
                    event.update(status='running',job_id=job['id'])
            db.execute('UPDATE ml_trade_evolutions SET status=?,document=? WHERE id=?',(event['status'],dumps(event),event['id']))

    def refresh_mainline_lock(self,db,reference):
        self.tick_mainline_jobs(db)

    def replace_mainline_party(self,db,character_id,asset_ids):
        db.execute('DELETE FROM ml_party WHERE character_id=?',(character_id,))
        for slot,asset_id in enumerate(asset_ids):
            db.execute('INSERT INTO ml_party VALUES(?,?,?)',(character_id,slot,asset_id))

    def settle_mainline_battle(self,db,job,character,result):
        owner = job['owner_id']
        decision = integer(result.get('decision'),1,5,'decision')
        fulls,caught = result.get('pokemon'),result.get('captured',[])
        require(type(fulls) is list and len(fulls)==len(job['asset_ids']) and type(caught) is list and len(caught)<=6,'native_result_invalid','Native battle roster differs',500)
        fulls = [validate_trade_snapshot(value) for value in fulls]
        caught = [validate_trade_snapshot(value) for value in caught]
        require(not caught or job['native']['params']['kind'] in ('wild','scripted'),'native_result_invalid','Trainer battles cannot create captures',500)
        assets = []
        for asset_id in job['asset_ids']:
            asset = self.asset(db,asset_id,owner)
            lock = db.execute('SELECT reference FROM asset_locks WHERE asset_id=?',(asset_id,)).fetchone()
            require(lock and lock[0]=='mainline:'+job['id'] and digest(dumps(asset.get('full',asset['snapshot'])))==job['input_hashes'][asset_id],'native_input_changed','Battle input changed',409)
            assets.append(asset)
        final_bag = result.get('bag_final')
        require(type(final_bag) is dict and set(final_bag)==set(job['item_cost']),'native_result_invalid','Native bag differs from reserved belt',500)
        changes = {}
        for item_id,quantity in job['item_cost'].items():
            remaining = integer(final_bag[item_id],0,quantity,'remaining')
            consumed = quantity-remaining
            changes[owner,item_id],changes['system:consumed',item_id] = -consumed,consumed
        delta = integer(result.get('money_delta'),-job['coin_cost'],1_000_000,'money_delta')
        if not job['native']['params'].get('reward_enabled',True):
            delta = min(delta,0)
        self.release_mainline_job(db,job)
        if delta>0:
            immediate = min(delta,9_999_999_999-self.wallet(db,owner)['balance'])
            pending = delta-immediate
            self.post_money(db,job['id'],'native_battle',{owner:immediate,'system:issuer':-delta,'system:pending':pending},{'character_id':character['id'],'decision':decision})
            if pending:
                db.execute('INSERT INTO ml_credits VALUES(?,?,?)',(owner,job['id'],pending))
        else:
            self.post_money(db,job['id'],'native_battle',{owner:delta,'system:battle':-delta},{'character_id':character['id'],'decision':decision})
        if changes:
            self.post_items(db,job['id'],'native_battle',changes,{'character_id':character['id']})
        for asset,full in zip(assets,fulls):
            self.update_mainline_asset(db,asset,full,job)
        captured_ids = []
        for full in caught:
            require(full['pokemon']['owner']['id']==job['native']['owner']['id'],'native_result_invalid','Captured original trainer differs',500)
            asset = self.new_mainline_asset(db,owner,full,job,'capture')
            captured_ids.append(asset['id'])
        roster = [row[0] for row in db.execute('SELECT asset_id FROM ml_party WHERE character_id=? ORDER BY slot',(character['id'],))]
        roster += captured_ids[:max(0,6-len(roster))]
        self.replace_mainline_party(db,character['id'],roster)
        params = job['native']['params']
        if decision==1 and params['kind']=='boss':
            badges = character.setdefault('badges',[])
            require(params['boss_index']==len(badges),'badge_changed','Badge progression changed',409)
            badges.append(params['boss_index'])
        scope = params.get('reward_scope')
        if (decision==1 or decision==4 and caught) and scope:
            db.execute('INSERT OR IGNORE INTO ml_claims VALUES(?,?,?)',(owner,scope,dumps({'job_id':job['id']})))
        character['revision']+=1
        self.save_mainline_character(db,character)
        job.update(status='completed',result={'decision':decision,'captured_asset_ids':captured_ids,'money_delta':delta,'events':result.get('events',[])[:30],'character_revision':character['revision']})
        job.pop('prompt',None)
        self.save_mainline_job(db,job)
        self.trading_event(db,job['id'],[owner],'native_battle',job['result'])

    def mainline_command(self,db,owner,job_id,body):
        obj(body,{'request_id','sequence','command'},{'request_id','sequence','command'})
        row = db.execute('SELECT document FROM ml_jobs WHERE id=? AND owner=?',(job_id,owner)).fetchone()
        require(row is not None,'job_not_found','Native job does not belong to this account',404)
        job = json.loads(row[0])
        sequence = integer(body['sequence'],0,999,'sequence')
        command = body['command']
        obj(command,{'action','move_index','party_index','item_id'},{'action'})
        old = db.execute('SELECT document FROM ml_commands WHERE job_id=? AND sequence=?',(job_id,sequence)).fetchone()
        if old:
            require(json.loads(old[0])==command,'command_changed','A different command is already recorded',409)
            return 200,{'ok':True,'job':self.mainline_job_view(job)}
        require(job['status']=='running' and job.get('prompt',{}).get('sequence')==sequence,'prompt_changed','Refresh the current native prompt',409)
        state = job['prompt']['state']
        action = command['action']
        require(state.get('kind')!='switch' or action=='switch','illegal_command','A legal replacement is required',409)
        if action=='move':
            require(type(command.get('move_index')) is int and any(value['index']==command['move_index'] for value in state.get('moves',[])),'illegal_move','Choose a current legal move',409)
        elif action=='switch':
            require(type(command.get('party_index')) is int and any(value['party_index']==command['party_index'] for value in state.get('switches',[])),'illegal_switch','Choose a current legal replacement',409)
        elif action=='catch':
            require(any(value['id']==command.get('item_id') and value['quantity']>0 for value in state.get('balls',[])),'illegal_capture','Choose a reserved legal capture item',409)
        elif action=='item':
            require(state.get('kind')=='command' and any(value['id']==command.get('item_id') and value['quantity']>0 for value in state.get('medicine',[])) and type(command.get('party_index')) is int and any(value['party_index']==command['party_index'] for value in state.get('party',[])),'illegal_item','Choose a reserved medicine and current party target',409)
        elif action=='forced':
            require(not state.get('moves') and state.get('kind')=='command','illegal_move','A forced action is not required',409)
        else:
            require(action=='surrender' and state.get('kind')=='command','illegal_command','Unknown native battle command')
        db.execute('INSERT INTO ml_commands(job_id,sequence,document,dispatched) VALUES(?,?,?,0)',(job_id,sequence,dumps(command)))
        job['submitted_sequence']=sequence
        self.save_mainline_job(db,job)
        return 202,{'ok':True,'job':self.mainline_job_view(job)}

    def mainline_job_request(self,db,owner,character,body):
        obj(body,{'request_id','operation','asset_ids','params','compatibility'},{'request_id','operation','asset_ids','params','compatibility'})
        self.trading_compatibility(body['compatibility'])
        operation,ids,params = body['operation'],body['asset_ids'],body['params']
        require(operation in self.mainline_config()['supported_operations'],'invalid_operation','Unsupported mainline operation')
        require(type(ids) is list and 1<=len(ids)<=6 and all(type(value) is str for value in ids) and len(set(ids))==len(ids),'invalid_assets','Choose distinct server assets')
        assets = [self.asset(db,value,owner) for value in ids]
        coins,items = 0,{}
        if operation in ('inspect','heal'):
            obj(params,set())
        elif operation=='train':
            obj(params,{'count'},{'count'})
            count = integer(params['count'],1,99,'count')
            require(len(ids)==1 and assets[0]['snapshot']['level']+count<=100,'level_cap','Level cap exceeded',409)
            items = {'RARECANDY':count}
        elif operation=='ev':
            obj(params,{'stat','count','reduce'},{'stat','count'})
            count = integer(params['count'],1,25,'count')
            require(params['stat'] in STATS and len(ids)==1,'invalid_stat','Choose one stat and asset')
            if 'reduce' in params:
                boolean(params['reduce'],'reduce')
            if params.get('reduce') is True:
                coins = count*250
            else:
                vitamin = dict(HP='HPUP',ATTACK='PROTEIN',DEFENSE='IRON',SPECIAL_ATTACK='CALCIUM',SPECIAL_DEFENSE='ZINC',SPEED='CARBOS')[params['stat']]
                items = {vitamin:count}
        elif operation=='learn':
            obj(params,{'move_id','slot'},{'move_id','slot'})
            string(params['move_id'],1,80,'move_id',r'[A-Z0-9_]+')
            integer(params['slot'],0,3,'slot')
            require(len(ids)==1,'invalid_assets','Choose one asset')
            coins = 1000
        elif operation in ('evolve','preview_evolution'):
            obj(params,{'method','item_id','branch'},{'method'})
            require(len(ids)==1 and params['method'] in ('level','item','trade') and (operation=='preview_evolution' or params['method']!='trade'),'invalid_evolution','Trade evolutions are triggered by committed exchanges')
            if params['method']=='trade':params['optional']=True
            if 'branch' in params:
                require(params['branch'] in ('body','head','both'),'invalid_evolution','Choose body, head or both')
            if params['method']=='item':
                self.inventory_item(params.get('item_id'))
                items = {params['item_id']:1} if operation=='evolve' else {}
        elif operation in ('fuse','preview_fusion'):
            obj(params,set())
            require(len(ids)==2,'invalid_assets','Fusion needs two assets')
            coins = 1000 if operation=='fuse' else 0
        elif operation=='breed':
            obj(params,set())
            require(len(ids)==2,'invalid_assets','Breeding needs two distinct owned parents')
            coins=2000
        elif operation in ('equip','use_item'):
            obj(params,{'item_id'},{'item_id'})
            require(len(ids)==1,'invalid_assets','Choose one owned Pokemon')
            item_id=params['item_id']
            if item_id is not None:
                self.inventory_item(item_id)
                items={item_id:1}
            require(operation=='equip' or item_id is not None,'invalid_item','Choose an item')
            if operation=='equip':
                require(assets[0]['snapshot'].get('item')!=item_id,'item_unchanged','This item is already held',409)
        elif operation=='split':
            obj(params,set())
            require(len(ids)==1 and len(assets[0].get('lineage_ids',[]))==2,'invalid_lineage','This asset has no supported fusion lineage')
            params = {'lineage':assets[0]['lineage'],'fusion_base_exp':assets[0]['fusion_base_exp']}
            coins = 500
        elif operation=='battle':
            obj(params,{'kind','map_id','encounter_type','species','level','trainer_type','trainer_name','trainer_version','boss_index','belt'},{'kind','belt'})
            require(ids==[row[0] for row in db.execute('SELECT asset_id FROM ml_party WHERE character_id=? ORDER BY slot',(character['id'],))],'party_changed','Battle uses the current authoritative party',409)
            require(all('full' in asset for asset in assets) and any(asset['full']['preserved']['hp']>0 for asset in assets),'no_able_pokemon','Choose an able server Pokemon',409)
            badges = len(character.get('badges',[]))
            cap = min(100,20+badges*10)
            require(all(asset['snapshot']['level']<=cap for asset in assets),'level_cap','Party exceeds current verified badge level cap',409)
            require(params['kind'] in ('wild','scripted','trainer','boss'),'invalid_battle','Choose a supported battle kind')
            if params['kind'] in ('wild','scripted','trainer'):
                map_id = integer(params.get('map_id'),1,999999,'map_id')
                presence = db.execute('SELECT document,updated FROM world_presence WHERE owner=?',(owner,)).fetchone()
                require(presence and presence['updated']>self.clock()-20 and json.loads(presence['document']).get('map_id')==map_id,'map_changed','Enter this online map before starting the battle',409)
            if params['kind']=='trainer':
                string(params.get('trainer_type'),1,80,'trainer_type',r'[A-Za-z0-9_]+')
                string(params.get('trainer_name'),1,80,'trainer_name')
                integer(params.get('trainer_version',0),0,999,'trainer_version')
                scope = 'trainer:'+character['id']+':'+digest(dumps([params['trainer_type'],params['trainer_name'],params.get('trainer_version',0)]))
                params['reward_scope']=scope
                params['reward_enabled']=not bool(db.execute('SELECT 1 FROM ml_claims WHERE owner=? AND scope=?',(owner,scope)).fetchone())
            else:
                params['reward_enabled']=True
            if params['kind']=='scripted':
                string(params.get('species'),1,80,'species',r'[A-Za-z0-9_]+')
                integer(params.get('level'),1,cap,'level')
                scope = 'scripted:'+character['id']+':'+digest(dumps([params['map_id'],params['species']]))
                require(not db.execute('SELECT 1 FROM ml_claims WHERE owner=? AND scope=?',(owner,scope)).fetchone(),'capture_already_claimed','This scripted capture was already claimed',409)
                params['reward_scope']=scope
            if params['kind']=='boss':
                require(type(params.get('boss_index')) is int and params['boss_index']==badges and badges<8,'badge_order','Challenge the next verified badge',409)
            if 'encounter_type' in params:
                string(params['encounter_type'],1,40,'encounter_type',r'[A-Za-z0-9_]+')
            belt = params['belt']
            require(type(belt) is dict and len(belt)<=8,'invalid_belt','Choose at most eight item types')
            for item_id,quantity in belt.items():
                self.inventory_item(item_id)
                integer(quantity,1,99,'quantity')
            coins = min(100000,self.wallet(db,owner)['available'])
            items = dict(belt)
            params.update(level_cap=cap,badge_count=badges,wallet=coins)
        job = self.enqueue_mainline_job(db,owner,character,operation,assets,params,coins,items)
        return 202,{'ok':True,'job':self.mainline_job_view(job)}

    def dispatch_mainline(self,db,identity,method,parts,body):
        if parts[:2]!=['v1','mainline']:
            return None
        owner = identity['id']
        self.trading_account(db,owner)
        self.tick_mainline_jobs(db)
        if parts==['v1','mainline','config'] and method=='GET':
            return 200,{'ok':True,'config':self.mainline_config()}
        if len(parts)==5 and parts[:3]==['v1','mainline','assets'] and parts[4]=='release' and method=='POST':
            obj(body,{'request_id','version'},{'request_id','version'})
            asset=self.asset(db,parts[3],owner)
            require(type(body['version']) is int and body['version']==asset.get('version',1),'asset_changed','Refresh the current asset',409)
            require(self.mainline_assignment(db,asset['id']) is None and self.refresh_asset_lock(db,asset['id']) is None,'asset_locked','Deposit the Pokemon in the online PC before releasing',409)
            self.ensure_attachment_backing(db,asset)
            item=asset['snapshot'].get('item')
            transaction='release_'+digest(dumps([owner,body['request_id']]))
            if item:self.post_items(db,transaction,'release_attachment',{('asset:'+asset['id'],item):-1,(owner,item):1},{'asset_id':asset['id']})
            asset.update(owner_id='system:released',released_at=self.clock(),released_by=owner)
            db.execute('UPDATE hosted_assets SET owner=?,document=? WHERE id=?',('system:released',dumps(asset),asset['id']))
            db.execute('UPDATE showcases SET active=0 WHERE owner=? AND document LIKE ?',(owner,'%'+asset['id']+'%'))
            self.trading_event(db,transaction,[owner],'native_release',{'asset_id':asset['id']})
            return 200,{'ok':True,'asset_id':asset['id'],'released':True}
        if parts==['v1','mainline','shop'] and method=='GET':
            allowed={'POTION','SUPERPOTION','HYPERPOTION','MAXPOTION','FULLRESTORE','ANTIDOTE','PARLYZHEAL','PARALYZEHEAL','BURNHEAL','ICEHEAL','AWAKENING','FULLHEAL','REVIVE','POKEBALL','GREATBALL','ULTRABALL','REPEL','SUPERREPEL','MAXREPEL','RARECANDY','HPUP','PROTEIN','IRON','CALCIUM','ZINC','CARBOS','FIRESTONE','WATERSTONE','THUNDERSTONE','LEAFSTONE','MOONSTONE','SUNSTONE'}
            return 200,{'ok':True,'items':[item for item in self.item_catalog()['items'] if item['id'] in allowed and item['price']>0]}
        if parts==['v1','mainline','shop','buy'] and method=='POST':
            obj(body,{'request_id','item_id','quantity','unit_price','compatibility'},{'request_id','item_id','quantity','unit_price','compatibility'})
            self.trading_compatibility(body['compatibility'])
            products=self.dispatch_mainline(db,identity,'GET',['v1','mainline','shop'],{})[1]['items']
            item=next((value for value in products if value['id']==body['item_id']),None)
            require(item is not None,'item_unavailable','This item is not sold by the online supplier',409)
            quantity=integer(body['quantity'],1,99,'quantity')
            require(type(body['unit_price']) is int and body['unit_price']==item['price'],'price_changed','Refresh the current supplier price',409)
            total=integer(quantity*item['price'],1,9_999_999_999,'total')
            transaction='shop_'+digest(dumps([owner,body['request_id']]))
            self.post_money(db,transaction,'mainline_shop',{owner:-total,'system:shop':total},{'item_id':item['id'],'quantity':quantity})
            self.post_items(db,transaction,'mainline_shop',{(owner,item['id']):quantity,('system:issuer',item['id']):-quantity},{'quantity':quantity})
            return 200,{'ok':True,'transaction_id':transaction,'wallet':self.wallet(db,owner),'inventory':self.inventory_view(db,owner)}
        if parts==['v1','mainline','inventory','consume'] and method=='POST':
            obj(body,{'request_id','item_id','quantity'},{'request_id','item_id','quantity'})
            item=self.inventory_item(body['item_id']);quantity=integer(body['quantity'],1,999,'quantity')
            self.post_items(db,'consume_'+digest(dumps([owner,body['request_id']])),'mainline_field_item',{(owner,item['id']):-quantity,('system:consumed',item['id']):quantity},{'item_id':item['id']})
            return 200,{'ok':True,'inventory':self.inventory_view(db,owner)}
        if parts==['v1','mainline','credits'] and method=='GET':
            return 200,{'ok':True,'pending':db.execute('SELECT COALESCE(SUM(amount),0) FROM ml_credits WHERE owner=?',(owner,)).fetchone()[0]}
        if parts==['v1','mainline','credits','claim'] and method=='POST':
            obj(body,{'request_id'},{'request_id'})
            remaining=9_999_999_999-self.wallet(db,owner)['balance']
            claimed=0
            for row in db.execute('SELECT event_id,amount FROM ml_credits WHERE owner=? AND amount>0 ORDER BY event_id',(owner,)).fetchall():
                take=min(remaining,row['amount'])
                if not take: break
                db.execute('UPDATE ml_credits SET amount=amount-? WHERE owner=? AND event_id=?',(take,owner,row['event_id']))
                claimed+=take;remaining-=take
            if claimed:
                self.post_money(db,'credit_'+digest(dumps([owner,body['request_id']])),'native_credit_claim',{owner:claimed,'system:pending':-claimed},{'amount':claimed})
            return 200,{'ok':True,'claimed':claimed,'wallet':self.wallet(db,owner)}
        if parts==['v1','mainline','eggs'] and method=='GET':
            eggs=[]
            for row in db.execute('SELECT document FROM ml_eggs WHERE owner=? ORDER BY ready DESC LIMIT 100',(owner,)):
                egg=json.loads(row[0]);egg.pop('full',None);egg['ready']=self.clock()>=egg['ready_at'];eggs.append(egg)
            return 200,{'ok':True,'eggs':eggs}
        if len(parts)==5 and parts[:3]==['v1','mainline','eggs'] and parts[4]=='hatch' and method=='POST':
            obj(body,{'request_id'},{'request_id'})
            row=db.execute('SELECT document FROM ml_eggs WHERE id=? AND owner=?',(parts[3],owner)).fetchone()
            require(row is not None,'egg_not_found','Egg does not belong to this account',404)
            egg=json.loads(row[0])
            if egg['status']=='incubating':
                require(self.clock()>=egg['ready_at'],'egg_not_ready','Server incubation is not complete',409)
                character=self.mainline_character(db,egg['character_id'],owner)
                asset=self.new_mainline_asset(db,owner,egg['full'],{'id':egg['job_id']},'hatch')
                egg.update(status='hatched',asset_id=asset['id'])
                db.execute("UPDATE ml_eggs SET status='hatched',document=? WHERE id=?",(dumps(egg),egg['id']))
                character['revision']+=1;self.save_mainline_character(db,character)
                self.trading_event(db,'hatch_'+egg['id'],[owner],'native_hatch',{'egg_id':egg['id'],'asset_id':asset['id']})
            public=dict(egg);public.pop('full',None)
            return 200,{'ok':True,'egg':public}
        if parts==['v1','mainline','characters']:
            if method=='GET':
                values = [self.mainline_character_view(db,json.loads(row[0])) for row in db.execute('SELECT document FROM ml_characters WHERE owner=? ORDER BY created',(owner,)) if not json.loads(row[0]).get('service_only')]
                return 200,{'ok':True,'characters':values}
            obj(body,{'request_id','name','gender','starter','compatibility'},{'request_id','name','gender','starter','compatibility'})
            self.trading_compatibility(body['compatibility'])
            require(self.native_engine is not None,'native_unavailable','Native mainline engine is not configured',503)
            self.require_mainline_idle(db,owner)
            name = string(body['name'],1,20,'name')
            gender = integer(body['gender'],0,2,'gender')
            require(body['starter'] in ('BULBASAUR','CHARMANDER','SQUIRTLE'),'invalid_starter','Choose an approved starter')
            require(db.execute('SELECT COUNT(*) FROM ml_characters WHERE owner=?',(owner,)).fetchone()[0]<8,'character_limit','At most eight online characters',409)
            character = {'id':'chr_'+secrets.token_hex(16),'owner_id':owner,'name':name,'gender':gender,'starter':body['starter'],'revision':1,'status':'ready','created_at':self.clock()}
            db.execute('INSERT INTO ml_characters VALUES(?,?,?,?,?,?)',(character['id'],owner,name,1,dumps(character),self.clock()))
            job = None
            if not db.execute("SELECT 1 FROM ml_claims WHERE owner=? AND scope='starter'",(owner,)).fetchone():
                character['status'] = 'creating'
                self.save_mainline_character(db,character)
                job = self.enqueue_mainline_job(db,owner,character,'starter',[],{'species':body['starter']})
            return 201,{'ok':True,'character':self.mainline_character_view(db,character),'job':self.mainline_job_view(job) if job else None}
        if len(parts)>=4 and parts[:3]==['v1','mainline','characters']:
            character = self.mainline_character(db,parts[3],owner)
            if len(parts)==4 and method=='GET':
                return 200,{'ok':True,'character':self.mainline_character_view(db,character),'inventory':self.inventory_view(db,owner)}
            if len(parts)==5 and parts[4]=='sync' and method=='POST':
                obj(body,{'compatibility'},{'compatibility'})
                self.trading_compatibility(body['compatibility'])
                return 200,{'ok':True,'character':self.mainline_character_view(db,character),'inventory':self.inventory_view(db,owner)}
            if len(parts)==5 and parts[4]=='jobs' and method=='POST':
                return self.mainline_job_request(db,owner,character,body)
            if len(parts)==6 and parts[4:]==['pc','search'] and method=='POST':
                obj(body,{'cursor'})
                cursor = body.get('cursor','')
                string(cursor,0,80,'cursor',r'[A-Za-z0-9_-]*')
                rows = db.execute('SELECT document FROM hosted_assets WHERE owner=? AND id>? ORDER BY id LIMIT 51',(owner,cursor)).fetchall()
                assets = []
                for row in rows[:50]:
                    asset = json.loads(row[0])
                    lock = self.refresh_asset_lock(db,asset['id'])
                    assigned = self.mainline_assignment(db,asset['id'])
                    asset['locked'] = bool(lock)
                    asset['lock_reference'] = lock[0] if lock else None
                    asset['assigned_character'] = assigned['character_id'] if assigned else None
                    # The selected asset's full object is fetched individually.
                    asset.pop('full',None)
                    asset.pop('lineage',None)
                    assets.append(asset)
                return 200,{'ok':True,'assets':assets,'next_cursor':assets[-1]['id'] if len(rows)>50 else None}
            if len(parts)==5 and parts[4]=='retry-starter' and method=='POST':
                obj(body,{'request_id'},{'request_id'})
                require(character['status']=='creating' and not db.execute("SELECT 1 FROM ml_claims WHERE owner=? AND scope='starter'",(owner,)).fetchone(),'starter_already_granted','Use the existing account starter',409)
                job = self.enqueue_mainline_job(db,owner,character,'starter',[],{'species':character['starter']})
                return 202,{'ok':True,'job':self.mainline_job_view(job)}
            if len(parts)==5 and parts[4]=='party' and method=='POST':
                obj(body,{'request_id','asset_ids','revision'},{'request_id','asset_ids','revision'})
                self.require_mainline_idle(db,owner)
                require(type(body['revision']) is int and body['revision']==character['revision'],'character_changed','Refresh the current character',409)
                ids = body['asset_ids']
                require(type(ids) is list and len(ids)<=6 and all(type(value) is str for value in ids) and len(set(ids))==len(ids),'invalid_party','Choose up to six different assets')
                for asset_id in ids:
                    asset = self.asset(db,asset_id,owner)
                    require('full' in asset,'asset_not_prepared','Prepare this legacy asset before using it',409)
                    require(self.refresh_asset_lock(db,asset_id) is None,'asset_locked','Asset is committed to another operation',409)
                    assigned = self.mainline_assignment(db,asset_id)
                    require(assigned is None or assigned['character_id']==character['id'],'asset_assigned','Asset belongs to another online character party',409)
                self.replace_mainline_party(db,character['id'],ids)
                if ids:
                    character['status']='ready'
                character['revision']+=1
                self.save_mainline_character(db,character)
                return 200,{'ok':True,'character':self.mainline_character_view(db,character)}
        if parts==['v1','mainline','jobs'] and method=='GET':
            rows = db.execute('SELECT document FROM ml_jobs WHERE owner=? ORDER BY created DESC LIMIT 100',(owner,))
            return 200,{'ok':True,'jobs':[self.mainline_job_view(json.loads(row[0])) for row in rows]}
        if len(parts)==4 and parts[:3]==['v1','mainline','jobs'] and method=='GET':
            row = db.execute('SELECT document FROM ml_jobs WHERE id=? AND owner=?',(parts[3],owner)).fetchone()
            require(row is not None,'job_not_found','Native job does not belong to this account',404)
            return 200,{'ok':True,'job':self.mainline_job_view(json.loads(row[0]))}
        if len(parts)==5 and parts[:3]==['v1','mainline','jobs'] and parts[4]=='commands' and method=='POST':
            return self.mainline_command(db,owner,parts[3],body)
        if len(parts)==4 and parts[:3]==['v1','mainline','assets'] and method=='GET':
            return 200,{'ok':True,'asset':self.asset(db,parts[3],owner)}
        raise APIError(404,'not_found','Unknown mainline endpoint')
