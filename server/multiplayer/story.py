"""Server-owned special encounters and bounded Safari/contest resources."""
import copy,json,secrets

def bind_api(api):
    for name in ('obj','require','integer','boolean','dumps','digest','validate_trade_snapshot'):
        globals()[name]=api[name]

class StoryFeatures:
    STORY_OPERATIONS=('safari_enter','contest_enter','contest_finish','partner_register')
    def init_story(self,db):
        db.executescript('''
          CREATE TABLE IF NOT EXISTS ml_story_sessions(id TEXT PRIMARY KEY,owner TEXT NOT NULL,character_id TEXT NOT NULL,kind TEXT NOT NULL,status TEXT NOT NULL,document TEXT NOT NULL,expires REAL NOT NULL);
          CREATE INDEX IF NOT EXISTS ml_story_owner ON ml_story_sessions(owner,status);
          CREATE TABLE IF NOT EXISTS ml_roamers(character_id TEXT NOT NULL,roamer_index INTEGER NOT NULL,document TEXT NOT NULL,PRIMARY KEY(character_id,roamer_index));
        ''')
    def story_session(self,db,owner,session_id=None,character_id=None):
        if session_id:
            row=db.execute('SELECT document FROM ml_story_sessions WHERE id=? AND owner=?',(session_id,owner)).fetchone()
        else:
            row=db.execute("SELECT document FROM ml_story_sessions WHERE owner=? AND status IN ('active','judging') ORDER BY expires DESC LIMIT 1",(owner,)).fetchone()
        require(row is not None,'story_not_found','No active special encounter session',404)
        value=json.loads(row[0])
        require(character_id is None or value['character_id']==character_id,'story_character_changed','Return to the character that entered this activity',409)
        return value
    def save_story_session(self,db,value):
        db.execute('INSERT OR REPLACE INTO ml_story_sessions VALUES(?,?,?,?,?,?,?)',(value['id'],value['owner_id'],value['character_id'],value['kind'],value['status'],dumps(value),value['expires_at']))
    def story_view(self,value):
        public={key:copy.deepcopy(item) for key,item in value.items() if key not in ('candidate','pending_candidate')}
        for key in ('candidate','pending_candidate'):
            public[key]=copy.deepcopy(value[key]['pokemon']) if value.get(key) else None
        return public
    def story_presence(self,db,owner,map_id):
        integer(map_id,1,999999,'map_id')
        row=db.execute('SELECT document,updated FROM world_presence WHERE owner=?',(owner,)).fetchone()
        require(row and row['updated']>self.clock()-20 and json.loads(row['document']).get('map_id')==map_id,'map_changed','Enter the current online map before starting this encounter',409)
    def prepare_story_operation(self,db,owner,character,operation,assets,params):
        require([value['id'] for value in assets]==[row[0] for row in db.execute('SELECT asset_id FROM ml_party WHERE character_id=? ORDER BY slot',(character['id'],))],'party_changed','Refresh the authoritative party',409)
        if operation=='partner_register':
            obj(params,{'map_id','partner'},{'map_id','partner'})
            self.story_presence(db,owner,params['map_id'])
            partner=params['partner'];obj(partner,{'trainer_type','trainer_name','trainer_version'},{'trainer_type','trainer_name','trainer_version'})
            require(type(partner['trainer_type']) is str and len(partner['trainer_type'])<=80 and type(partner['trainer_name']) is str and 1<=len(partner['trainer_name'])<=80,'invalid_partner','Choose an installed story partner')
            integer(partner['trainer_version'],0,999,'trainer_version')
            params=dict(params,level_cap=min(100,20+len(character.get('badges',[]))*10));cost=0
        elif operation in ('safari_enter','contest_enter'):
            obj(params,{'map_id','selected_index'},{'map_id'})
            self.story_presence(db,owner,params['map_id'])
            require(not db.execute("SELECT 1 FROM ml_story_sessions WHERE owner=? AND status IN ('active','judging')",(owner,)).fetchone(),'story_pending','Finish the active Safari or contest first',409)
            selected=integer(params.get('selected_index',0),0,len(assets)-1,'selected_index')
            if operation=='contest_enter':
                row=db.execute("SELECT document FROM ml_claims WHERE owner=? AND scope=?",(owner,'contest_cooldown:'+character['id'])).fetchone()
                require(not row or json.loads(row[0])['started_at']+86400<=self.clock(),'contest_cooldown','This character may enter one contest per 24 hours',409)
            params=dict(params,selected_index=selected,mode_id='story_'+secrets.token_hex(16),level_cap=min(100,20+len(character.get('badges',[]))*10))
            cost=500 if operation=='safari_enter' else 0
        else:
            obj(params,{'session_id'},{'session_id'})
            session=self.story_session(db,owner,params['session_id'],character['id'])
            require(session['kind']=='contest' and session['status'] in ('active','judging'),'story_closed','Contest has already ended',409)
            params=dict(params,candidate=session.get('candidate'),pending_candidate=session.get('pending_candidate'),map_id=session['map_id'])
            session['status']='judging';self.save_story_session(db,session);cost=0
        return self.enqueue_mainline_job(db,owner,character,operation,assets,params,cost)
    def settle_story_operation(self,db,job,result):
        owner=job['owner_id'];character=self.mainline_character(db,job['character_id'],owner)
        params=job['native']['params'];operation=job['operation'];metadata=result.get('story')
        require(type(metadata) is dict,'native_result_invalid','Native story metadata missing',500)
        for asset_id in job['asset_ids']:
            asset=self.asset(db,asset_id,owner);lock=db.execute('SELECT reference FROM asset_locks WHERE asset_id=?',(asset_id,)).fetchone()
            require(lock and lock[0]=='mainline:'+job['id'] and digest(dumps(asset.get('full',asset['snapshot'])))==job['input_hashes'][asset_id],'native_input_changed','Story input changed',409)
        self.release_mainline_job(db,job)
        cost=job['coin_cost']
        self.post_money(db,job['id'],'story_'+operation,{owner:-cost,'system:story':cost},{'character_id':character['id']})
        if operation=='partner_register':
            require(metadata.get('partner')==params['partner'],'native_result_invalid','Native partner differs from installed declaration',500)
            character['partner']=metadata['partner'];character['revision']+=1;self.save_mainline_character(db,character)
            job.update(status='completed',result={'partner':metadata['partner'],'character_revision':character['revision']})
            self.save_mainline_job(db,job);self.trading_event(db,job['id'],[owner],'story_partner',job['result']);return
        if operation in ('safari_enter','contest_enter'):
            kind='safari' if operation=='safari_enter' else 'contest'
            require(metadata.get('kind')==kind and metadata.get('entry_fee')==cost and metadata.get('map_id')==params['map_id'],'native_result_invalid','Native entry differs from approved request',500)
            count=30 if kind=='safari' else 20;item='SAFARIBALL' if kind=='safari' else 'SPORTBALL'
            session={'id':params['mode_id'],'owner_id':owner,'character_id':character['id'],'kind':kind,'status':'active','map_id':params['map_id'],'allowed_maps':metadata['allowed_maps'],'remaining':count,'ball_item':item,'selected_asset_id':job['asset_ids'][params['selected_index']],'created_at':self.clock(),'expires_at':self.clock()+(1800 if kind=='safari' else metadata['duration']),'candidate':None,'pending_candidate':None}
            self.post_items(db,'entry_'+job['id'],'story_ball_allocation',{('story:'+session['id'],item):count,('system:issuer',item):-count},{'session_id':session['id']})
            self.save_story_session(db,session)
            if kind=='contest':db.execute('INSERT OR REPLACE INTO ml_claims VALUES(?,?,?)',(owner,'contest_cooldown:'+character['id'],dumps({'started_at':self.clock()})))
        else:
            session=self.story_session(db,owner,params['session_id'],character['id'])
            require(session['status']=='judging','story_closed','Contest already settled',409)
            chosen=metadata.get('candidate');asset_ids=[]
            if chosen:
                full=validate_trade_snapshot(chosen)
                candidates=[value for value in (session.get('candidate'),session.get('pending_candidate')) if value]
                require(full in candidates,'native_result_invalid','Judged candidate differs from certified captures',500)
                asset=self.new_mainline_asset(db,owner,full,job,'contest_capture');asset_ids=[asset['id']]
            prize=metadata.get('prize')
            if prize:
                require(prize in ('SUNSTONE','EVERSTONE','GOLDBERRY','ORANBERRY'),'native_result_invalid','Unknown native contest prize',500)
                self.post_items(db,'prize_'+job['id'],'contest_prize',{(owner,prize):1,('system:issuer',prize):-1},{'session_id':session['id']})
            session.update(status='completed',asset_ids=asset_ids,place=metadata['place'],places=metadata['places'],score=metadata['score'],prize=prize)
            self.retire_story_balls(db,session,job['id']);self.save_story_session(db,session)
        character['revision']+=1;self.save_mainline_character(db,character)
        job.update(status='completed',result={'story':self.story_view(session),'character_revision':character['revision']})
        self.save_mainline_job(db,job);self.trading_event(db,job['id'],[owner],'story_'+operation,job['result'])
    def retire_story_balls(self,db,session,event_id):
        quantity=session['remaining']
        if quantity:self.post_items(db,'retire_'+session['id']+'_'+event_id,'story_ball_retirement',{('story:'+session['id'],session['ball_item']):-quantity,('system:expired',session['ball_item']):quantity},{'session_id':session['id']})
        session['remaining']=0
    def prepare_special_battle(self,db,owner,character,params):
        kind=params['kind']
        if kind in ('safari','contest'):
            session=self.story_session(db,owner,params.get('session_id'),character['id'])
            require(session['kind']==kind and session['status']=='active' and session['remaining']>0 and session['expires_at']>self.clock(),'story_closed','This activity has ended',409)
            require(params['map_id'] in session['allowed_maps'],'story_map_changed','Return to an allowed activity map',409)
            ids=[row[0] for row in db.execute('SELECT asset_id FROM ml_party WHERE character_id=? ORDER BY slot',(character['id'],))]
            require(session['selected_asset_id'] in ids,'party_changed','Restore the contest entrant to the party',409)
            params.update(session_id=session['id'],story_ball_count=session['remaining'],story_expires_at=session['expires_at'],selected_index=ids.index(session['selected_asset_id']),belt={},reward_enabled=False)
        elif kind=='story':
            context=params.get('story');obj(context,{'event_id','page','command_index','occurrence'},{'event_id','page','command_index'})
            context['occurrence']=context.get('occurrence',0)
            for key,high in [('event_id',99999),('page',99),('command_index',99999),('occurrence',99)]:
                if key in context:integer(context[key],0,high,key)
            scope='story:'+character['id']+':'+digest(dumps([params['map_id'],context]))
            require(not db.execute('SELECT 1 FROM ml_claims WHERE owner=? AND scope=?',(owner,scope)).fetchone(),'story_already_completed','This story encounter was already completed',409)
            params['reward_scope']=scope
        elif kind=='roamer':
            index=integer(params.get('roamer_index'),0,99,'roamer_index')
            row=db.execute('SELECT document FROM ml_roamers WHERE character_id=? AND roamer_index=?',(character['id'],index)).fetchone()
            value=json.loads(row[0]) if row else {}
            require(not value.get('finished'),'roamer_finished','This roamer was already caught or defeated',409)
            params['roamer_state']=value.get('pokemon')
            params['reward_scope']='roamer:'+character['id']+':'+str(index)
    def settle_special_battle(self,db,job,character,result,caught):
        params=job['native']['params'];kind=params['kind'];extra={}
        if kind in ('safari','contest'):
            session=self.story_session(db,job['owner_id'],params['session_id'],character['id'])
            remaining=integer(result.get('story_ball_remaining'),0,session['remaining'],'remaining')
            consumed=session['remaining']-remaining
            if consumed:self.post_items(db,'balls_'+job['id'],'story_ball_use',{('story:'+session['id'],session['ball_item']):-consumed,('system:consumed',session['ball_item']):consumed},{'session_id':session['id']})
            session['remaining']=remaining
            if kind=='contest':
                require(len(caught)<=1,'native_result_invalid','Contest can offer one candidate per battle',500)
                if caught:
                    key='pending_candidate' if session.get('candidate') else 'candidate';session[key]=caught[0]
                caught=[]
            self.save_story_session(db,session);extra['story']=self.story_view(session)
        elif kind=='roamer':
            document={'finished':result['decision'] in (1,4),'pokemon':result.get('roamer_state')}
            if document['pokemon']:document['pokemon']=validate_trade_snapshot(document['pokemon'])
            db.execute('INSERT OR REPLACE INTO ml_roamers VALUES(?,?,?)',(character['id'],params['roamer_index'],dumps(document)))
        return caught,extra
    def reset_story_job(self,db,job):
        if job['operation']=='contest_finish':
            row=db.execute('SELECT document FROM ml_story_sessions WHERE id=?',(job['native']['params'].get('session_id'),)).fetchone()
            if row:
                session=json.loads(row[0])
                if session['status']=='judging':session['status']='active';self.save_story_session(db,session)
    def dispatch_story(self,db,owner,method,parts,body):
        if len(parts)==6 and parts[:3]==['v1','mainline','characters'] and parts[4:]==['partner','leave'] and method=='POST':
            obj(body,{'request_id'},{'request_id'});self.require_mainline_idle(db,owner)
            character=self.mainline_character(db,parts[3],owner);character['partner']=None;character['revision']+=1;self.save_mainline_character(db,character)
            return 200,{'ok':True,'character':self.mainline_character_view(db,character)}
        if parts==['v1','mainline','story'] and method=='GET':
            rows=db.execute('SELECT document FROM ml_story_sessions WHERE owner=? ORDER BY expires DESC LIMIT 30',(owner,)).fetchall()
            return 200,{'ok':True,'sessions':[self.story_view(json.loads(row[0])) for row in rows]}
        if len(parts)==5 and parts[:3]==['v1','mainline','story'] and method=='POST':
            session=self.story_session(db,owner,parts[3])
            self.require_mainline_idle(db,owner)
            if parts[4]=='candidate':
                obj(body,{'request_id','replace'},{'request_id','replace'});boolean(body['replace'],'replace')
                require(session['kind']=='contest' and session['status']=='active','story_closed','Contest is not active',409)
                if session.get('pending_candidate'):
                    if body['replace']:session['candidate']=session['pending_candidate']
                    session['pending_candidate']=None;self.save_story_session(db,session)
            elif parts[4]=='leave':
                obj(body,{'request_id'},{'request_id'})
                require(session['kind']=='safari','contest_judging_required','Judge the contest to collect the certified candidate',409)
                if session['status']=='active':
                    session['status']='completed';self.retire_story_balls(db,session,'leave_'+body['request_id']);self.save_story_session(db,session)
            else:return None
            return 200,{'ok':True,'story':self.story_view(session)}
        return None
