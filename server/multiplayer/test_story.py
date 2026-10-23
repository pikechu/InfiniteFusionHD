"""Special encounter ownership, resources, recovery and command boundaries."""
import copy,json,unittest
from service import Store
import test_mainline as base

class StoryEngine(base.RecordedEngine):
    def __init__(self):
        super().__init__();self.capture=True;self.prompt=False;self.commands=[]
    def command(self,*args):self.commands.append(args)
    def poll(self,job_id,nonce):
        request=self.requests[job_id];operation=request['operation'];params=request['params']
        if operation not in ('safari_enter','contest_enter','contest_finish','partner_register','battle'):
            return super().poll(job_id,nonce)
        if self.fail:return 'result',dict(job_id=job_id,nonce=nonce,ok=False)
        fulls=copy.deepcopy(request['inputs'])
        if operation=='partner_register':
            result=dict(pokemon=fulls,story=dict(partner=params['partner']))
        elif operation in ('safari_enter','contest_enter'):
            kind='safari' if operation=='safari_enter' else 'contest'
            result=dict(pokemon=fulls,story=dict(kind=kind,map_id=params['map_id'],allowed_maps=[42],entry_fee=500 if kind=='safari' else 0,duration=1200))
        elif operation=='contest_finish':
            result=dict(pokemon=fulls,story=dict(candidate=params.get('pending_candidate') or params.get('candidate'),place=0,places=[[-1,'BULBASAUR',500],[0,'CATERPIE',400],[1,'WEEDLE',300]],score=500,prize='SUNSTONE'))
        else:
            if self.prompt:
                state=dict(kind='command',active_index=2,moves=[dict(id='TACKLE',index=0,pp=20,targets=[1,3])],switches=[],balls=[],medicine=[],party=[])
                return 'prompt',dict(job_id=job_id,nonce=nonce,sequence=0,state=state,deadline=9999999999)
            caught=copy.deepcopy(self.fixtures['starter_bulbasaur']['pokemon'][0])
            caught['pokemon']['owner']=dict(request['owner'],language=0)
            result=dict(pokemon=fulls,captured=[caught] if self.capture else [],decision=4 if self.capture else 3,money_delta=0,bag_final=dict(params['belt']),events=[])
            if params['kind'] in ('safari','contest'):result['story_ball_remaining']=params['story_ball_count']-(1 if self.capture else 0)
            if params['kind']=='roamer' and not self.capture:result['roamer_state']=caught
        return 'result',dict(job_id=job_id,nonce=nonce,ok=True,result=result)

class StoryTests(unittest.TestCase):
    call=base.MainlineTests.call
    assets=base.MainlineTests.assets
    wallet=base.MainlineTests.wallet
    inventory=base.MainlineTests.inventory
    create=base.MainlineTests.create
    operation=base.MainlineTests.operation
    def setUp(self):
        base.MainlineTests.setUp(self);self.engine=StoryEngine();self.store.native_engine=self.engine
        self.character=self.create()
        with self.store.connect() as db:
            db.execute('INSERT INTO world_presence VALUES(?,?,?,?,?,?,?)',(self.a['identity']['id'],'test_story_world',json.dumps(self.compat),None,json.dumps({'map_id':42}),1,self.clock()))
    def tearDown(self):base.MainlineTests.tearDown(self)
    def current(self):return self.call(self.a,'GET','/v1/mainline/characters/'+self.character['id'])['character']
    def enter(self,kind):return self.operation(self.current(),kind+'_enter',params={'map_id':42})['result']['story']
    def battle(self,kind,**extra):
        return self.operation(self.current(),'battle',params=dict(kind=kind,map_id=42,belt={},**extra))
    def test_safari_fee_and_tokens_are_accounted_outside_inventory(self):
        before=self.wallet(self.a)['balance'];mode=self.enter('safari')
        self.assertEqual(self.wallet(self.a)['balance'],before-500)
        self.assertEqual(self.inventory(self.a,'SAFARIBALL')['quantity'],0)
        with self.store.connect() as db:self.assertEqual(self.store.item_balance(db,'story:'+mode['id'],'SAFARIBALL')['quantity'],30)
        result=self.battle('safari',session_id=mode['id']);self.assertEqual(len(result['result']['captured_asset_ids']),1)
        self.assertEqual(self.current()['story']['remaining'],29)
        self.assertEqual(self.call(self.a,'GET','/v1/mainline/jobs/'+result['id'])['job'],result)
        with self.store.connect() as db:self.assertTrue(self.store.economy_audit(db)['ok'])
    def test_activity_ball_quota_cannot_be_uploaded_or_given_to_another_owner(self):
        mode=self.enter('safari');path='/v1/mainline/characters/'+self.character['id']+'/jobs'
        body=dict(operation='battle',asset_ids=[a['id'] for a in self.current()['party']],params=dict(kind='safari',map_id=42,belt={},session_id=mode['id'],story_ball_count=999),compatibility=self.compat)
        self.call(self.a,'POST',path,body,400)
        self.call(self.b,'POST','/v1/mainline/story/'+mode['id']+'/leave',{},404)
        self.assertEqual(self.current()['story']['remaining'],30)
    def test_contest_capture_remains_blueprint_until_single_final_claim(self):
        mode=self.enter('contest');before=len(self.assets(self.a))
        caught=self.battle('contest',session_id=mode['id'])
        self.assertEqual(caught['result']['captured_asset_ids'],[])
        self.assertEqual(len(self.assets(self.a)),before)
        self.assertIsNotNone(self.current()['story']['candidate'])
        body=dict(request_id='contest_final_once',operation='contest_finish',asset_ids=[a['id'] for a in self.current()['party']],params={'session_id':mode['id']},compatibility=self.compat)
        path='/v1/mainline/characters/'+self.character['id']+'/jobs'
        queued=self.call(self.a,'POST',path,body,202)
        finished=self.call(self.a,'GET','/v1/mainline/jobs/'+queued['job']['id'])['job']
        self.assertEqual(finished['status'],'completed')
        self.assertEqual(self.call(self.a,'POST',path,body,202),queued)
        self.assertEqual(len(self.assets(self.a)),before+1)
        self.assertEqual(self.inventory(self.a,'SUNSTONE')['quantity'],1)
        with self.store.connect() as db:
            self.assertEqual(self.store.item_balance(db,'story:'+mode['id'],'SPORTBALL')['quantity'],0)
            self.assertTrue(self.store.economy_audit(db)['ok'])
    def test_contest_cooldown_and_party_lock_survive_saves(self):
        mode=self.enter('contest');character=self.current()
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/party',dict(asset_ids=[],revision=character['revision']),409)
        self.operation(character,'contest_finish',params={'session_id':mode['id']})
        self.call(self.a,'POST','/v1/mainline/characters/'+character['id']+'/jobs',dict(operation='contest_enter',asset_ids=[a['id'] for a in self.current()['party']],params={'map_id':42},compatibility=self.compat),409)
    def test_safari_leave_retires_tokens_exactly_once(self):
        mode=self.enter('safari');path='/v1/mainline/story/'+mode['id']+'/leave'
        first=self.call(self.a,'POST',path,{})
        self.assertEqual(self.call(self.a,'POST',path,{})['story']['remaining'],0)
        self.assertIsNone(self.current()['story'])
        with self.store.connect() as db:self.assertTrue(self.store.economy_audit(db)['ok'])
    def test_roamer_state_is_private_and_final_capture_cannot_repeat(self):
        self.engine.capture=False;fled=self.battle('roamer',roamer_index=0)
        self.assertEqual(fled['result']['decision'],3)
        with self.store.connect() as db:self.assertIsNotNone(db.execute('SELECT document FROM ml_roamers').fetchone())
        self.engine.capture=True;self.battle('roamer',roamer_index=0)
        self.call(self.a,'POST','/v1/mainline/characters/'+self.character['id']+'/jobs',dict(operation='battle',asset_ids=[a['id'] for a in self.current()['party']],params=dict(kind='roamer',map_id=42,belt={},roamer_index=0),compatibility=self.compat),409)
    def test_omitted_and_explicit_story_occurrence_have_one_claim(self):
        context=dict(event_id=1,page=0,command_index=5)
        self.battle('story',story=context)
        context['occurrence']=0
        self.call(self.a,'POST','/v1/mainline/characters/'+self.character['id']+'/jobs',dict(operation='battle',asset_ids=[a['id'] for a in self.current()['party']],params=dict(kind='story',map_id=42,belt={},story=context),compatibility=self.compat),409)
    def test_multibattle_target_checked_against_current_prompt(self):
        self.engine.prompt=True
        body=dict(operation='battle',asset_ids=[a['id'] for a in self.current()['party']],params=dict(kind='wild',map_id=42,belt={}),compatibility=self.compat)
        job=self.call(self.a,'POST','/v1/mainline/characters/'+self.character['id']+'/jobs',body,202)['job']
        self.call(self.a,'GET','/v1/mainline/jobs/'+job['id'])
        path='/v1/mainline/jobs/'+job['id']+'/commands'
        self.call(self.a,'POST',path,dict(sequence=0,command=dict(action='move',move_index=0,target=0)),409)
        self.call(self.a,'POST',path,dict(sequence=0,command=dict(action='move',move_index=0,target=3)),202)
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM ml_commands WHERE job_id=?',(job['id'],)).fetchone()[0],1)
    def test_restart_returns_pending_judgement_to_recoverable_activity(self):
        mode=self.enter('contest')
        body=dict(operation='contest_finish',asset_ids=[a['id'] for a in self.current()['party']],params={'session_id':mode['id']},compatibility=self.compat)
        job=self.call(self.a,'POST','/v1/mainline/characters/'+self.character['id']+'/jobs',body,202)['job']
        self.store.close();self.store=Store(self.database,clock=self.clock)
        self.store.catalog_path,self.store.item_catalog_path=self.catalog_path,self.item_catalog
        self.assertEqual(self.current()['story']['status'],'active')
        self.assertEqual(self.call(self.a,'GET','/v1/mainline/jobs/'+job['id'])['job']['error_code'],'server_restart')
    def test_companion_is_server_stored_and_cannot_be_uploaded_in_battle(self):
        partner=dict(trainer_type='RIVAL1',trainer_name='Blue',trainer_version=12)
        self.operation(self.current(),'partner_register',params=dict(map_id=42,partner=partner))
        self.assertEqual(self.current()['partner'],partner)
        body=dict(operation='battle',asset_ids=[a['id'] for a in self.current()['party']],params=dict(kind='wild',map_id=42,belt={},partner=partner),compatibility=self.compat)
        self.call(self.a,'POST','/v1/mainline/characters/'+self.character['id']+'/jobs',body,400)
        job=self.battle('wild')
        self.assertEqual(self.engine.requests[job['id']]['params']['partner'],partner)
        self.call(self.a,'POST','/v1/mainline/characters/'+self.character['id']+'/partner/leave',{})
        self.assertIsNone(self.current()['partner'])

if __name__=='__main__':unittest.main()
