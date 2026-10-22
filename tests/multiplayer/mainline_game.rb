# Real client role fork, cloud codec, managed projection and stale save reload.
passed=false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test=KIFMultiplayerFeatureTest
  config=KIFMultiplayer::WireJSON.parse(File.read(ENV.fetch("KIF_MULTIPLAYER_SCENARIO")))
  directory=config.fetch("directory")
  client=KIFMultiplayer::Client.new
  test.log('STEP authenticate')
  client.authenticate("register",config.fetch("username"),"NativeMainlineFixture123")
  cloud=KIFMultiplayer::CloudSession.new(client);cloud.open
  mode=KIFMultiplayer::OnlineMode
  mode.instance_variable_set(:@cloud,cloud);mode.instance_variable_set(:@mode,:online)
  mode.world=KIFMultiplayer::WorldSession.new(client,cloud.compatibility,cloud.session_id)
  $Trainer.name="保留的休闲角色"
  $Trainer.save_slot="File A"
  $Trainer.party << test.pokemon(:PIKACHU,[:TACKLE])
  $PokemonBag.pbStoreItem(:POTION,7)
  $PokemonBag.pbStoreItem(:ESCAPEROPE,2)
  {:@clothes=>STARTING_OUTFIT,:@hair=>"3_"+DEFAULT_OUTFIT_MALE,:@unlocked_clothes=>[],:@unlocked_hats=>[],:@unlocked_hairstyles=>[]}.each { |key,value| $Trainer.instance_variable_set(key,value) }
  module MainlineDiagnosticMessages
    def pbConfirmMessage(*args);true;end
    def pbMessage(message,*args);KIFMultiplayerFeatureTest.log("MESSAGE #{message}");0;end
  end
  Object.prepend(MainlineDiagnosticMessages)
  sdk=KIFMultiplayer::MainlineClient.new(client)
  module PBDebug
    def self.logonerr;yield;end
  end
  test.log('STEP create native character')
  character=sdk.create("在线角色",0,"BULBASAUR")
  test.log('STEP mount native character')
  KIFMultiplayer::Mainline.mount(client,character)
  test.check($Trainer.save_slot=="File B" && KIFMultiplayer::Mainline.active?,"native client mounts authoritative role in independent slot")
  test.check(SaveData.read_from_file(SaveData.get_full_path("File A"))[:player].name=="保留的休闲角色","fork preserves original role save")
  test.check($Trainer.party.length==1 && KIFMultiplayer::Mainline.asset_id($Trainer.party[0])==character['party'][0]['id'],"server identity projects into actual party")
  $PokemonSystem.maxivsmode=1
  test.check($PokemonSystem.maxivsmode==PokemonSystem.new.instance_variable_get(:@maxivsmode),"managed getters ignore local IV cheat option")
  wallet=$Trainer.money;$Trainer.money=999999
  test.check($Trainer.money==wallet,"local money setter cannot replace server wallet")
  before=$PokemonBag.pbQuantity(:POTION);$PokemonBag.pbStoreItem(:POTION,3)
  test.check($PokemonBag.pbQuantity(:POTION)==before,"local item reward remains casual instead of issuing online stock")
  KIFMultiplayer::Mainline.casual_storage do
    test.check($Trainer.party[0].species==:PIKACHU && $PokemonBag.pbQuantity(:POTION)==10,"casual storage exposes preserved local party and items")
    $PokemonBag.pbDeleteItem(:POTION,1)
    $PokemonBag.pbStoreItem(:ESCAPEROPE,1)
  end
  test.check($PokemonBag.pbQuantity(:POTION)==before && $PokemonBag.pbQuantity(:ESCAPEROPE)==3 && $Trainer.instance_variable_get(:@kif_mainline_casual_items)['POTION']==9,"casual storage changes preserve local items and cannot debit online stock")
  old_managed=KIFMultiplayer::BattleIsolation.copy(SaveData.compile_save_hash)
  packed=KIFMultiplayer::CloudCodec.pack(old_managed)
  test.check(KIFMultiplayer::CloudCodec.unpack(packed)[:player].instance_variable_get(:@kif_mainline_character_id)==character['id'],"cloud codec preserves role and asset references")
  $Trainer.heal_party
  test.check($Trainer.party[0].hp==$Trainer.party[0].totalhp,"normal party healing persists through authoritative native operation")
  test.log('STEP deposit server party')
  character=sdk.character(character['id'])
  sdk.set_party(character,[])
  listing=KIFMultiplayer::TradingClient.new(client).sell(character['party'][0]['id'],1000)
  test.log('STEP wait external purchase')
  test.marker(File.join(directory,"mainline-listed.json"),{"listing_id"=>listing['id'],"asset_id"=>character['party'][0]['id'],"owner_id"=>client.player_id})
  test.wait(client,"external buyer commits",90) { File.file?(File.join(directory,"mainline-sold.json")) }
  SaveData.mark_values_as_unloaded
  Game.load(old_managed)
  test.check($Trainer.party.empty?,"loading stale cloud party cannot restore a sold asset")
  test.check($Trainer.money==1900,"loading stale cloud wallet uses current settled balance")
  test.check(cloud.flush,"independent role and original role cloud uploads complete")
  checks=File.readlines(File.join(ENV.fetch("KIF_MULTIPLAYER_SAVE_DIR"),"feature-smoke.log")).grep(/PASS /).map { |line| line.split('PASS ',2)[1].strip }
  test.marker(File.join(directory,"mainline-client-pass.json"),{"passed"=>true,"pid"=>Process.pid,"checks"=>checks,"data_hash"=>client.compatibility['data_hash']})
  cloud.close
  passed=true
rescue Exception=>error
  File.write(File.join(ENV.fetch('KIF_MULTIPLAYER_SAVE_DIR'),'mainline-error.log'),"#{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}")
  KIFMultiplayerFeatureTest.log("FAIL #{error.class}: #{error.message}\n#{(error.backtrace || []).join("\n")}") if defined?(KIFMultiplayerFeatureTest)
ensure
  exit!(passed ? 0 : 1)
end
