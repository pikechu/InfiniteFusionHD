passed=false
begin
  load 'scripts/multiplayer/test-bootstrap.rb'
  module PBDebug;def self.logonerr;yield;end;end
  test=KIFMultiplayerFeatureTest
  config=KIFMultiplayer::WireJSON.parse(File.read(ENV.fetch('KIF_MULTIPLAYER_SCENARIO')))
  directory=config.fetch('directory');role=config.fetch('role')
  client=KIFMultiplayer::Client.new
  client.recover_pending if client.profile.account['pending']
  client.authenticate('login','extras_'+role,'IsolatedMarketFixture123')
  trading=KIFMultiplayer::TradingClient.new(client);trading.recover
  sdk=KIFMultiplayer::TradingExtrasClient.new(client);mainline=KIFMultiplayer::MainlineClient.new(client)
  marker=lambda { |name,value| test.marker(File.join(directory,name+'.json'),value) }
  wait=lambda { |name| test.wait(client,name,360) { test.read(File.join(directory,name+'.json')) } }
  if config['cross_device']
    marker=lambda { |name,value| client.raw_request('POST','/fixture/'+name,value) }
    wait=lambda { |name| test.wait(client,name,360) { client.raw_request('GET','/fixture/'+name)['value'] } }
  end
  claim_all=lambda { trading.deliveries.each { |d| trading.claim(d['id']) if d['status']=='pending' } }
  marker.call(role+'-identity',client.identity)
  if role=='host'
    owned=trading.assets
    marker.call('host-pokemon-offer',{'species'=>owned[2]['snapshot']['species']})
    cancel_ui=KIFMultiplayer::TradingExtrasUI.new(client)
    cancel_ui.define_singleton_method(:choose) { |_title,choices| choices.length }
    cancel_ui.main;cancel_ui.contract_market('auction')
    test.check(true,'real game extension menus exit on their native cancel sentinel')
    watched=sdk.save_search('伤药到货',{'category'=>'item','item_id'=>'POTION','max_price'=>1000},'price_asc',true)
    initial=trading.sell_item('POTION',10,100);marker.call('partial-listing',initial)
    wait.call('partial-recovered')
    current=trading.listing(initial['id'])
    test.check(current['quantity']==7 && current['price']==700,'partial purchase leaves exactly seven units with current price')
    trading.cancel_listing(current['id']);claim_all.call
    reverse=wait.call('reverse-listing')
    test.check(sdk.notices.any? { |n| n['kind']=='arrival' && n['data']['listing_id']==reverse['id'] },'saved search produces a durable arrival notification')
    result=trading.buy(trading.listing(reverse['id']),3);trading.claim(result['delivery']['id'])
    history=sdk.history('item','POTION')
    test.check(history['trades']==0 && !history['sufficient_sample'],'actual reciprocal trades are excluded from public price samples')
    marker.call('reverse-bought',{'passed'=>true})
    peer=wait.call('guest-identity')
    mail=sdk.response('POST','mail',{'friend_code'=>peer['friend_code'],'subject'=>'原生客户端附件','text'=>'精灵、伤药和联机币','asset_ids'=>[owned[0]['id']],'items'=>{'POTION'=>2},'coins'=>500,'compatibility'=>client.compatibility})['mail']
    marker.call('mail-sent',mail);wait.call('mail-collected')
    test.check(trading.assets.none? { |a| a['id']==owned[0]['id'] },'mail transfers the existing Pokemon instead of copying it')
    auction=sdk.create_contract('auction',{'asset_id'=>owned[1]['id'],'start_price'=>1000,'increment'=>100,'offer_seconds'=>60})
    marker.call('auction-open',auction);wait.call('auction-final-bid')
    order=sdk.create_contract('buy_order',{'category'=>'item','item_id'=>'POTION','quantity'=>5,'unit_price'=>100,'offer_seconds'=>3600})
    marker.call('item-order',order);wait.call('item-order-filled')
    test.check(sdk.contract(order['id'])['status']=='completed','funded item order fills through two real client supplies')
    pokemon_order=wait.call('pokemon-order')
    sdk.contract_action(sdk.contract(pokemon_order['id']),'fill',{'asset_id'=>owned[2]['id']})
    marker.call('pokemon-order-filled',{'passed'=>true})
    character=mainline.create('扩展资产主人',0,'BULBASAUR');asset=character['party'][0]
    mainline.set_party(character,[])
    training=sdk.create_contract('training',{'asset_id'=>asset['id'],'duration'=>3600,'bond'=>500,'reward'=>3000,'level'=>6,'offer_seconds'=>3600})
    marker.call('training-open',training);wait.call('training-complete');claim_all.call
    current=mainline.asset(asset['id'])
    test.check(current['snapshot']['level']==6,'real server native cultivation raises the original training asset to its goal')
    rental=sdk.create_contract('rental',{'asset_id'=>asset['id'],'duration'=>3600,'bond'=>500,'fee'=>1000,'offer_seconds'=>3600})
    marker.call('rental-open',rental);wait.call('rental-returned');claim_all.call
    test.check(mainline.asset(asset['id'])['owner_id']==client.player_id,'rental returns the same original identity after native gameplay')
    collateral=wait.call('loan-collateral')
    terms={'principal'=>1000,'repayment'=>1100,'duration'=>3600,'filters'=>{'species'=>collateral['snapshot']['species']},'offer_seconds'=>3600}
    loan=sdk.create_contract('loan',terms);marker.call('loan-open',loan);wait.call('loan-repaid')
    test.check(sdk.contract(loan['id'])['status']=='completed','fixed repayment closes a real funded collateral loan')
    wait.call('auction-close-ready')
    finished=test.wait(client,'auction settlement',120) { value=sdk.contract(auction['id']);value if value['status']=='completed' }
    test.check(finished['bid']==1500,'outbid and higher funded bid settle at the final server price')
    marker.call('auction-closed',finished);wait.call('auction-collected')
    second=sdk.create_contract('loan',terms);marker.call('default-loan-open',second)
    wait.call('default-clock-advanced')
    closed=sdk.contract(second['id']);test.check(closed['status']=='defaulted','server expiry settles the agreed collateral default')
    claim_all.call;marker.call('default-loan-closed',closed)
    test.check(trading.wallet['reserved']==0,'completed host flows release all wallet reservations')
  else
    listing=wait.call('partial-listing')
    if !client.profile.account['extras_response_lost']
      original=client.transport.method(:call)
      client.transport.define_singleton_method(:call) do |method,url,*args|
        response=original.call(method,url,*args)
        raise IOError,'injected response loss after committed partial purchase' if url.end_with?('/'+listing['id']+'/buy')
        response
      end
      begin
        trading.buy(trading.listing(listing['id']),3)
        raise 'Expected uncertain purchase'
      rescue KIFMultiplayer::UncertainRequest
        test.check(!!client.profile.account['pending'],'partial purchase response loss keeps its durable operation')
        client.profile.account['extras_response_lost']=true;client.profile.save
        marker.call('guest-restart',{'pid'=>Process.pid});exit!(23)
      end
    end
    claim_all.call
    test.check(trading.wallet['balance']==199700,'new process recovers a partial purchase without a second debit')
    test.check(trading.inventory['items'].find { |i| i['item_id']=='POTION' }['quantity']==33,'partial recovery owns exactly the purchased item quantity')
    marker.call('partial-recovered',{'passed'=>true})
    reverse=trading.sell_item('POTION',3,200);marker.call('reverse-listing',reverse);wait.call('reverse-bought')
    mail=wait.call('mail-sent');collected=sdk.action('mail/'+mail['id'],'claim')['mail'];sdk.action('mail/'+mail['id'],'claim');claim_all.call
    test.check(collected['delivery_ids'].length==2 && trading.assets.count { |a| a['id']==mail['bundle']['asset_ids'][0] }==1,'duplicate mail claim preserves one Pokemon and exact attachment deliveries')
    marker.call('mail-collected',{'passed'=>true})
    auction=wait.call('auction-open');value=sdk.contract_action(sdk.contract(auction['id']),'bid',{'amount'=>1000});marker.call('auction-first-bid',value)
    wait.call('auction-outbid')
    test.check(sdk.notices.any? { |n| n['kind']=='outbid' },'a displaced bidder receives a persistent notification')
    value=sdk.contract_action(sdk.contract(auction['id']),'bid',{'amount'=>1500});marker.call('auction-final-bid',value)
    order=wait.call('item-order');value=sdk.contract_action(sdk.contract(order['id']),'fill',{'quantity'=>2});sdk.contract_action(value,'fill',{'quantity'=>3})
    marker.call('item-order-filled',{'passed'=>true})
    remaining=trading.assets.find { |a| !a['locked'] }
    pokemon_order=sdk.create_contract('buy_order',{'category'=>'pokemon','quantity'=>1,'unit_price'=>1200,'filters'=>{'species'=>wait.call('host-pokemon-offer')['species']},'offer_seconds'=>3600})
    marker.call('pokemon-order',pokemon_order);wait.call('pokemon-order-filled');claim_all.call
    character=mainline.create('扩展代练玩家',0,'SQUIRTLE')
    training=wait.call('training-open');value=sdk.contract_action(sdk.contract(training['id']),'accept')
    asset_id=value['bundle']['asset_ids'][0];before=trading.wallet['balance']
    result=mainline.operate(character['id'],'train',[asset_id],{'count'=>1})
    test.check(result['status']=='completed' && mainline.asset(asset_id)['snapshot']['level']==6,'training worker consumes its own candy through the actual native engine')
    sdk.contract_action(sdk.contract(training['id']),'finish')
    test.check(trading.wallet['balance']==before+3000,'verified training goal pays the promised reward exactly once')
    marker.call('training-complete',{'passed'=>true})
    rental=wait.call('rental-open');value=sdk.contract_action(sdk.contract(rental['id']),'accept');asset_id=value['bundle']['asset_ids'][0]
    character=mainline.character(character['id']);mainline.set_party(character,[asset_id])
    blocked=false
    begin;trading.sell(asset_id,1000);rescue KIFMultiplayer::Error;blocked=true;end
    test.check(blocked,'actual client cannot sell a Pokemon held under a rental')
    $MapFactory.setup(42);$PokemonEncounters.setup(42);$game_player.moveto(5,5)
    previous_scene=$scene;$scene=Scene_Map.new;$game_player.refresh;$scene.createSpritesets
    KIFMultiplayer::OnlineMode.chatting=true
    world=KIFMultiplayer::WorldSession.new(client,client.compatibility);client.wait_update=proc { world.tick }
    test.wait(client,'real world map42 presence') { world.tick;world.map_key }
    8.times { Graphics.update;Input.update;$scene.updateSpritesets }
    bitmap=Graphics.snap_to_bitmap;bitmap.to_file(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'market-rental-map.png'));bitmap.dispose
    test.check($game_map.map_id==42 && !!$scene.map_renderer,'rental client renders its actual compiled encounter map')
    native=mainline.submit('/v1/mainline/characters/'+character['id']+'/jobs',{'operation'=>'battle','asset_ids'=>[asset_id],'params'=>{'kind'=>'wild','map_id'=>42,'belt'=>{}},'compatibility'=>client.compatibility})['job']
    commands=[];deadline=Time.now+120
    loop do
      job=mainline.job(native['id']);break if job['status']=='completed'
      raise "Rental battle failed #{job['error_code']}" if job['status']=='failed' || Time.now>deadline
      if job['prompt'] && !commands.include?(job['prompt']['sequence'])
        prompt=job['prompt'];state=KIFMultiplayer::MainlineBattleUI.new(client).validate_prompt(prompt)
        move=state['moves'].find { |m| m['pp']>0 }
        command=commands.empty? && move ? {'action'=>'move','move_index'=>move['index'],'target'=>move['targets'][0]} : {'action'=>'surrender'}
        command={'action'=>'switch','party_index'=>state['switches'][0]['party_index']} if state['kind']=='switch'
        client.request('POST','/v1/mainline/jobs/'+native['id']+'/commands',{'sequence'=>prompt['sequence'],'command'=>command});commands<<prompt['sequence']
      end
      until_time=Time.now+0.2;client.pump while Time.now<until_time
    end
    mainline.save_intent(nil)
    test.check(!commands.empty?,'rented Pokemon executes legal commands in a real native wild battle')
    world.close;client.wait_update=nil;$scene=previous_scene;KIFMultiplayer::OnlineMode.chatting=false
    sdk.contract_action(sdk.contract(rental['id']),'return')
    test.check(mainline.character(character['id'])['party'].empty?,'rental return removes the temporary Pokemon from the borrower party')
    marker.call('rental-returned',{'passed'=>true})
    collateral=trading.assets.find { |a| !a['locked'] };marker.call('loan-collateral',collateral)
    loan=wait.call('loan-open');value=sdk.contract_action(sdk.contract(loan['id']),'accept',{'asset_id'=>collateral['id']});sdk.contract_action(value,'repay');claim_all.call
    marker.call('loan-repaid',{'passed'=>true});marker.call('auction-close-ready',{'passed'=>true})
    closed=wait.call('auction-closed');claim_all.call;test.check(trading.assets.any? { |a| a['id']==auction['bundle']['asset_ids'][0] },'winning auction transfers the original Pokemon to the funded bidder')
    marker.call('auction-collected',{'passed'=>true})
    second=wait.call('default-loan-open');sdk.contract_action(sdk.contract(second['id']),'accept',{'asset_id'=>collateral['id']});marker.call('default-ready',{'passed'=>true})
    wait.call('default-loan-closed')
    test.check(trading.assets.none? { |a| a['id']==collateral['id'] },'default cannot leave the collateral usable by its former borrower')
    test.check(trading.wallet['reserved']==0,'completed guest flows release all wallet reservations')
  end
  checks=File.readlines(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'feature-smoke.log')).grep(/PASS /).map { |line| line.split('PASS ',2)[1].strip }
  marker.call(role+'-pass',{'passed'=>true,'pid'=>Process.pid,'checks'=>checks,'data_hash'=>client.compatibility['data_hash']})
  passed=true
rescue Exception=>error
  details=error.respond_to?(:details) ? KIFMultiplayer::WireJSON.dump({'code'=>error.code,'details'=>error.details}) : ''
  File.write(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'market-extension-error.log'),"#{error.class}: #{error.message}\n#{details}\n#{(error.backtrace || []).join("\n")}")
ensure
  exit!(passed ? 0 : 1)
end
