require_relative "../../server/multiplayer/native/world"
KIFNative.reset
KIFNative.initialize_world
KIFNative.scene = KIFNative::Scene.new
$Trainer.party = [Pokemon.new(:BULBASAUR, 10), Pokemon.new(:PIDGEY, 12)]
$Trainer.party.last.hp = 1
KIFNative.identify
identifiers = KIFNative.all_monsters.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) }.sort

def run_storage(command, values)
  scene = PokemonStorageScene.new
  screen = PokemonStorageScreen.new(scene, $PokemonStorage)
  fiber = Fiber.new { screen.pbStartScreen(command) }
  prompt = fiber.resume
  values.each do |value|
    raise "Storage ended early" unless fiber.alive?
    if prompt["kind"] == "storage" && prompt["held"]
      raise "Held asset disappeared from the owned registry" unless KIFNative.all_monsters.any? { |pokemon| pokemon.instance_variable_get(:@controlled_id) == prompt["held"]["id"] }
    end
    prompt = fiber.resume(value)
  end
  raise "Storage input missing: #{prompt}" if fiber.alive?
end

run_storage(2, [1, 0, 0, 1, 0])
raise "Native deposit did not preserve the party" unless $Trainer.party.length == 1 && $PokemonStorage[0,0].species == :PIDGEY
raise "Native PC deposit did not apply native healing" unless $PokemonStorage[0,0].hp == $PokemonStorage[0,0].totalhp
run_storage(2, [0, 0, 1, 0])
raise "Native PC allowed depositing the last able creature" unless $Trainer.party.length == 1
run_storage(1, [{"box" => 0, "slot" => 0}, 0, {"box" => -3, "slot" => 0}, 0])
raise "Native withdrawal differs" unless $Trainer.party.length == 2 && !$PokemonStorage[0,0]
run_storage(0, [{"box" => -1, "slot" => 1}, 0, {"box" => 0, "slot" => 5}, 0, {"box" => -3, "slot" => 0}, 0])
raise "Native hold/place did not move the creature" unless $Trainer.party.length == 1 && $PokemonStorage[0,5].species == :PIDGEY
raise "Storage changed server asset identities" unless KIFNative.all_monsters.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) }.sort == identifiers
begin
  PokemonStorageScreen.new(PokemonStorageScene.new, $PokemonStorage).pbImportJson(nil, nil)
  raise "PC imported a historical local asset"
rescue ArgumentError => error
  raise unless error.message == "native_offline_only_feature"
end

# Original PC item transfers retain both containers and reject tossing key items.
$PokemonBag.pbStoreItem(:POTION, 3)
$PokemonGlobal.pcItemStorage = PCItemStorage.new
before = $PokemonGlobal.pcItemStorage.pbQuantity(:POTION)
def run_bag(screen, method, values)
  fiber = Fiber.new { screen.send(method) }
  prompt = fiber.resume
  values.each do |value|
    raise "Bag flow ended early" unless fiber.alive?
    prompt = fiber.resume(value)
  end
  raise "Bag input missing: #{prompt}" if fiber.alive?
end
run_bag(PokemonBagScreen.new(PokemonBag_Scene.new, $PokemonBag), :pbDepositItemScreen, [0, 2, -1])
raise "PC item deposit lost quantities" unless $PokemonBag.pbQuantity(:POTION) == 1 && $PokemonGlobal.pcItemStorage.pbQuantity(:POTION) == before + 2
run_bag(PokemonBagScreen.new(WithdrawItemScene.new, $PokemonBag), :pbWithdrawItemScreen, [0, 2, -1])
raise "PC item withdrawal lost quantities" unless $PokemonBag.pbQuantity(:POTION) == 3 && $PokemonGlobal.pcItemStorage.pbQuantity(:POTION) == before

owned = $Trainer.party.dup
rentals = [:MEW, :PIDGEY, :SQUIRTLE, :DITTO].map { |species| Pokemon.new(species, 50) }
scene = BattleSwapScene.new
screen = BattleSwapScreen.new(scene)
fiber = Fiber.new { screen.pbStartRent(rentals) }
prompt = fiber.resume
[0,1,1,1,2,1,true].each { |value| prompt = fiber.resume(value) }
raise "Native rental selection did not finish" if fiber.alive?
selected = prompt
raise "Native rental selection changed its rules" unless selected.length == 3 && selected.all? { |pokemon| pokemon.instance_variable_get(:@controlled_rental) }
challenge = pbBattleChallenge
data = challenge.instance_variable_get(:@bc)
data.instance_variable_set(:@inProgress, true)
data.instance_variable_set(:@oldParty, owned)
$Trainer.party = selected
KIFNative.identify
raise "Rental party hid real owned assets" unless owned.all? { |pokemon| KIFNative.all_monsters.include?(pokemon) }
raise "Rental provenance was lost" unless KIFNative.view["party"].all? { |pokemon| pokemon["borrowed"] }
snapshot = KIFNative.export_state
KIFNative.import_state(snapshot)
raise "Rental reserve was lost on restore" unless KIFNative.all_monsters.count { |pokemon| !pokemon.instance_variable_get(:@controlled_rental) } == identifiers.length
puts "ORIGINAL_STORAGE_DEPOSIT_WITHDRAW_HELD_IDENTITIES_AND_LAST_ABLE_PASS"
