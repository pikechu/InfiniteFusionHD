load File.join(ENV.fetch("KIF_QA_SUPPORT"),"scripts/multiplayer/test-bootstrap.rb")
check=KIFMultiplayerFeatureTest.method(:check)
folder=File.join(ENV.fetch("KIF_ANDROID_FILES"),"diagnostics/android15-fixtures")
Dir.mkdir(folder) unless File.directory?(folder)
$Trainer.name="旧版回归"
$Trainer.money=12345
$Trainer.party=[Pokemon.new(:PIKACHU,17,$Trainer)]
$Trainer.party.first.name="Keepsake"
{:@clothes=>STARTING_OUTFIT,:@hat=>nil,:@hair=>"3_"+DEFAULT_OUTFIT_MALE,:@unlocked_clothes=>[],:@unlocked_hats=>[],:@unlocked_hairstyles=>[]}.each { |key,value| $Trainer.instance_variable_set(key,value) }
$Trainer.quests=Marshal.load(Marshal.dump(QUESTS.values.first(12)))
$Trainer.quests.first.completed=true
expert=$Trainer.quests.find { |quest| quest.name=="Type Experts" }
expert.desc="Defeat all of the Type Experts scattered around the Kanto region (7/12)"
pbSet(VAR_TYPE_EXPERTS_BEATEN,7)
$PokemonSystem.language=2
$MapFactory.setup(43)
$game_player.moveto(3,6)
path=File.join(folder,"android14-save.rxdata")
slot=SaveData::MANUAL_SLOTS.first
check.call(Game.save(slot),"Android14 game code writes through its actual save-slot API")
File.binwrite(path,File.binread(SaveData.get_full_path(slot)))
expected={"marker"=>"ANDROID14_QA_FIXTURE","trainer"=>$Trainer.name,"money"=>$Trainer.money,"nickname"=>$Trainer.party.first.name,"species"=>$Trainer.party.first.species.to_s,"level"=>$Trainer.party.first.level,"quest_names"=>$Trainer.quests.map(&:name),"completed"=>$Trainer.quests.map(&:completed),"map"=>$game_map.map_id,"x"=>$game_player.x,"y"=>$game_player.y,"language"=>$PokemonSystem.language,"save_slot"=>$Trainer.save_slot,"type_experts"=>pbGet(VAR_TYPE_EXPERTS_BEATEN),"save_sha256"=>Digest::SHA256.hexdigest(File.binread(path))}
control=KIFMultiplayer::WireJSON.dump(expected)
check.call(control.bytesize>100,"legacy control encoder returned a nonempty JSON document")
control_path=File.join(folder,"expected.json")
File.open(control_path,"wb") { |file| file.write(control); file.flush; file.fsync }
KIFMultiplayerFeatureTest.log("LEGACY_CONTROL bytes=#{File.size(control_path)} encoded=#{control.bytesize}")
check.call(File.binread(control_path).b==control.b,"legacy control JSON is fully persisted before process exit")
File.open(File.join(folder,"expected.rxdata"),"wb") { |file| Marshal.dump(expected,file); file.flush; file.fsync }
check.call(SaveData.valid?(SaveData.get_data_from_file(path)),"Android14 full save passes its own schema")
KIFMultiplayerFeatureTest.log("LEGACY14_WRITE_PASS quests=#{$Trainer.quests.length} bytes=#{File.size(path)}")
exit!(0)
