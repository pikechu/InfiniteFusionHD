passed = false
begin
  load "scripts/multiplayer/test-bootstrap.rb"
  test = KIFMultiplayerFeatureTest
  $Trainer.name = "云端测试😀"
  {:@clothes => STARTING_OUTFIT, :@hair => "3_" + DEFAULT_OUTFIT_MALE,
   :@unlocked_clothes => [], :@unlocked_hats => [], :@unlocked_hairstyles => []}.each { |key, value| $Trainer.instance_variable_set(key, value) }
  $Trainer.party << test.pokemon(:PIKACHU, [:TACKLE, :THUNDERBOLT])
  $Trainer.party[0].name = "中文伙伴"
  fused = getFusedPokemonIdFromSymbols(:CHARIZARD, :BLASTOISE)
  $Trainer.party << test.pokemon(fused, [:TACKLE])
  $Trainer.party[1].species_data
  $PokemonBag.pbStoreItem(:POTION, 5)
  $game_switches[42] = true
  $game_variables[43] = 12345
  $game_self_switches[[$game_map.map_id, 1, "A"]] = true
  $Trainer.save_slot = "File A"
  before = SaveData.compile_save_hash
  packed = KIFMultiplayer::CloudCodec.pack(before)
  restored = KIFMultiplayer::CloudCodec.unpack(packed)
  test.check(restored[:kuray_player].name == $Trainer.name, "cloud codec preserves Unicode trainer name")
  test.check(restored[:kuray_player].party[0].name == "中文伙伴", "cloud codec preserves party nickname")
  test.check(restored[:kuray_player].party[0].personalID == $Trainer.party[0].personalID, "cloud codec preserves unsigned Pokemon identity")
  test.check(restored[:switches][42] && restored[:variables][43] == 12345, "cloud codec preserves story flags and variables")
  test.check(restored[:self_switches][[$game_map.map_id, 1, "A"]], "cloud codec rehashes restored composite self-switch keys")
  SaveData.mark_values_as_unloaded
  Game.load(restored)
  test.check($Trainer.party[0].species == :PIKACHU && $Trainer.party[0].moves.length == 2, "real engine loads cloud Pokemon with moves")
  test.check($Trainer.party[1].species == fused && $Trainer.party[1].species_data.is_a?(GameData::FusedSpecies), "cloud codec restores fused Pokemon and trusted species cache")
  test.check($game_map.events.is_a?(Hash) && !$game_map.events.empty?, "cloud resume reconstructs installed map events")
  test.check($PokemonBag.pbQuantity(:POTION) == 5, "cloud resume preserves bag")
  $scene.createSpritesets
  5.times { Graphics.update; $scene.updateSpritesets }
  test.log("CLOUD_CODEC_NATIVE_PASS bytes=#{packed['payload'].bytesize}")
  passed = true
rescue Exception => error
  $kif_test_log.call("CLOUD_CODEC_NATIVE_FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}") if $kif_test_log
ensure
  exit!(passed ? 0 : 1)
end
