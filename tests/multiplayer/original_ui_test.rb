# frozen_string_literal: true
require_relative "../../server/multiplayer/native/world"
KIFNative.reset
KIFNative.initialize_world
KIFNative.scene = KIFNative::Scene.new
$Trainer.name = "玩家"
$game_variables[4] = "Pokémon"
raise "Native text substitution lost" unless KIFNative.message_text('Hello \PN: \v[4]!') == "Hello 玩家: Pokémon!"
raise "Native translation encoding differs" unless _INTL("Received {1}.", "Pokémon") == "Received Pokémon."

fiber = Fiber.new { pbMessage('Pick \ch[10,2,One,Two]') }
prompt = fiber.resume
raise "Inline native choice missing" unless prompt["choices"] == ["One", "Two"] && prompt["cancel"] == 2
fiber.resume(-1)
raise "Native cancellation branch lost" unless !fiber.alive? && $game_variables[10] == 1 && $game_map.need_refresh

fiber = Fiber.new { pbMessage("Required", ["One", "Two"]) }
fiber.resume
begin
  fiber.resume(-1)
  raise "Non-cancellable native choice was skipped"
rescue ArgumentError => error
  raise unless error.message == "invalid_native_choice:choice"
end

params = ChooseNumberParams.new
params.setRange(1, 6)
params.setDefaultValue(3)
params.setCancelValue(-1)
fiber = Fiber.new { pbMessageChooseNumber("Amount", params) }
prompt = fiber.resume
raise "Native number bounds lost" unless prompt.values_at("minimum", "maximum", "default", "cancellation") == [1,6,3,-1]
raise "Native number cancellation lost" unless fiber.resume(-1) == -1 && !fiber.alive?

fiber = Fiber.new { pbEnterNPCName("Name", 1, 12) }
fiber.resume
begin
  fiber.resume('\\ch[10,0,One]')
  raise "A name injected native message commands"
rescue ArgumentError => error
  raise unless error.message == "invalid_native_choice:name"
end

$Trainer.party = [Pokemon.new(:BULBASAUR, 5)]
$Trainer.party.first.hp = 0
pbStartOver
raise "Original blackout did not heal" unless $Trainer.party.first.hp == $Trainer.party.first.totalhp
raise "Original blackout did not return home" unless $game_map.map_id == GameData::Metadata.get.home[0]

KIFNative.reset(time: 1_792_713_600, seed: 99)
first_id = $Trainer.id
KIFNative.reset(time: 1_792_713_600, seed: 99)
raise "Character construction used unrecorded entropy" unless $Trainer.id == first_id
KIFNative.initialize_world
KIFNative.scene = KIFNative::Scene.new
raise "Virtual original save failed" unless pbSave(false) && $Trainer.save_slot == "controlled_online" && KIFNative.checkpoint_exists
lottery = lambda do
  KIFNative.clock = 1_792_713_600
  KIFNative.begin_identities(123456)
  srand(123456)
  pbSetLotteryNumber(10)
  [$game_variables[10], Array.new(8) { rand(1_000_000) }]
end
raise "Native lottery reseeding cannot replay" unless lottery.call == lottery.call

$Trainer.party = [Pokemon.new(:BULBASAUR, 10)]
$Trainer.party.first.item = :LEFTOVERS
KIFNative.identify
old_id = $Trainer.party.first.instance_variable_get(:@controlled_id)
fiber = Fiber.new { pbStartTrade(0, :PIDGEY, "Bird", "NPC") }
prompt = fiber.resume
while fiber.alive?
  raise "Unexpected native NPC trade prompt: #{prompt}" unless prompt["kind"] == "confirm"
  prompt = fiber.resume(false)
end
KIFNative.identify
raise "Native NPC trade did not replace the creature" unless $Trainer.party.first.species == :PIDGEY && $Trainer.party.first.instance_variable_get(:@controlled_id) != old_id
raise "Native NPC trade lost its owner or level" unless $Trainer.party.first.owner.name == "NPC" && $Trainer.party.first.level == 10 && $Trainer.party.first.obtain_method == 2
raise "Native NPC trade lost a returned held item" unless $PokemonBag.pbQuantity(:LEFTOVERS) == 1
raise "Native trade did not register the Pokédex" unless $Trainer.pokedex.owned?(:PIDGEY)
raise "Native trade still used a graphical path" unless KIFNative.scene.events.any? { |event| event["kind"] == "npc_trade" }

# The original randomizer saves and reloads compiled tables. These writes must
# remain in the role, including across replay/restart, without changing files.
KIFNative.reset
KIFNative.capture_global_baseline
KIFNative.initialize_world
KIFNative.scene = KIFNative::Scene.new
base_power = GameData::Move.get(:TACKLE).base_damage
GameData::Move.get(:TACKLE).instance_variable_set(:@base_damage, 123)
path = "Data/native_role_isolation_test.dat"
raise "Virtual test path already exists" if File.exist?(File.join(KIFNative::ROOT, path))
save_data({"role" => "one"}, path)
snapshot = KIFNative.export_state
KIFNative.reset_global_baseline
raise "Resource changes leaked into another role" unless GameData::Move.get(:TACKLE).base_damage == base_power && !pbRgssExists?(path)
KIFNative.import_state(snapshot)
raise "Role resource changes were not restored" unless GameData::Move.get(:TACKLE).base_damage == 123 && load_data(path) == {"role" => "one"}
raise "Original resource writer touched the release" if File.exist?(File.join(KIFNative::ROOT, path))
pbRgssOpen(path) { |stream| raise "Virtual RGSS read differs" unless Marshal.load(stream) == {"role" => "one"} }
KIFNative.reset
raise "A new role inherited the previous role's tables" unless GameData::Move.get(:TACKLE).base_damage == base_power

KIFNative.initialize_world
KIFNative.scene = KIFNative::Scene.new
$Trainer.hair_color = 0
fiber = Fiber.new { selectHairColor }
prompt = fiber.resume
[0,4].each { |choice| prompt = fiber.resume(choice) }
raise "Original hair dye confirmation changed" unless !fiber.alive? && prompt == true && $Trainer.hair_color == 10
fiber = Fiber.new { selectHairColor }
fiber.resume
fiber.resume(0)
fiber.resume(5)
raise "Original hair dye cancellation changed" unless $Trainer.hair_color == 10
pool = getCustomSpeciesList(true)
pool.clear
raise "A caller mutated the shared sprite-derived encounter pool" unless getCustomSpeciesList(true).length > 100_000
puts "ORIGINAL_UI_DIALOGUE_INPUT_AND_BLACKOUT_PASS"
