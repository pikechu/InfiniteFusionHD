require_relative "../../server/multiplayer/native/world"
require_relative "../../server/multiplayer/native/commerce"
require_relative "../../server/multiplayer/native/rollback"
KIFNative.capture_global_baseline
KIFNative.reset(time: 1_792_713_600, seed: 840)
KIFNative.initialize_world
KIFNative.begin_identities(840)
KIFNative.scene = KIFNative::Scene.new
$Trainer.party = [Pokemon.new(:BULBASAUR,20)]
KIFNative.identify
initial = $Trainer.party.first.instance_variable_get(:@controlled_id)
wild = Pokemon.new(:PIDGEY,5)
wild.shiny = true
battle = PokeBattle_SafariZone.new(KIFNative.scene,$Trainer,[wild])
battle.ballCount = 30
fiber = Fiber.new { battle.pbStartBattle }
prompt = fiber.resume
raise "Safari did not use the original command loop" unless prompt["kind"] == "safari_command"
raise "Native Safari projection missing" unless KIFNative.world_view["battle"]["mode"] == "safari"
100.times do
  break unless fiber.alive?
  value = case prompt["kind"]
          when "safari_command" then 0
          when "confirm" then false
          when "name" then "Safari"
          else raise "Unexpected Safari prompt #{prompt}"
          end
  prompt = fiber.resume(value)
end
raise "Original Safari catch did not finish" if fiber.alive?
raise "Original Safari did not catch the wild Pokemon" unless prompt == 4 && $Trainer.party.length == 2 && battle.ballCount < 30
KIFNative.identify
raise "Safari catch duplicated its owner's identity" unless KIFNative.all_monsters.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) }.uniq.length == 2

fiber = Fiber.new { pbHallOfFameEntry }
fiber.resume
fiber.resume(0)
raise "Original Hall of Fame did not record its native team" unless $PokemonGlobal.hallOfFameLastNumber == 1 && $PokemonGlobal.hallOfFame.first.length == 2
raise "Hall snapshots were exposed as tradeable Pokemon" unless KIFNative.all_monsters.length == 2

shadow = Pokemon.new(:PIDGEY,15)
# This KIF data set has no Shadow Rush. A private pre-existing Shadow fixture
# exercises the retained purification model without adding a fabricated move.
shadow.shadow = true
shadow.heart_gauge = Pokemon::HEART_GAUGE_SIZE
normal = Pokemon.new(:RATTATA,20)
$PokemonStorage[0,0], $PokemonStorage[0,1] = shadow, normal
KIFNative.identify
ids = KIFNative.all_monsters.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) }.sort
scene = PurifyChamberScene.new
screen = PurifyChamberScreen.new(scene)
scene.pbStart($PokemonGlobal.purifyChamber)
raise "Native chamber rejected a Shadow Pokemon" unless screen.pbPlacePokemon([0,0],0)
raise "Native chamber rejected a regular Pokemon" unless screen.pbPlacePokemon([0,1],1)
raise "Purification chamber assets disappeared" unless KIFNative.all_monsters.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) }.sort == ids
shadow.heart_gauge = 0
fiber = Fiber.new { screen.pbStartPurify }
prompt = fiber.resume
20.times do
  break unless fiber.alive?
  raise "Unexpected purification prompt #{prompt}" unless prompt["kind"] == "confirm"
  prompt = fiber.resume(false)
end
raise "Original purification did not finish" if fiber.alive?
raise "Original purification failed or duplicated the asset" unless !shadow.shadowPokemon? && KIFNative.all_monsters.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) }.sort == ids
raise "Purification identity changed" unless KIFNative.all_monsters.any? { |pokemon| pokemon.instance_variable_get(:@controlled_id) == initial }
puts "ORIGINAL_ACTIVITIES_SAFARI_HALL_AND_PURIFICATION_PASS"
