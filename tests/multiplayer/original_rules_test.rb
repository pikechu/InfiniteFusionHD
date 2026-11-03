# frozen_string_literal: true
# Executes the installed native rules, not a reimplementation of their formulas.
require_relative "../../server/multiplayer/native/cultivation"
$checks = 0
def check(value, name)
  raise "ORIGINAL_RULES_FAILED #{name}" unless value
  $checks += 1
end
def fresh
  KIFNative.reset
  srand(123_456)
end
def pokemon(species, level = 50, moves = [:TACKLE])
  result = Pokemon.new(species, level)
  result.moves = moves.map { |move| Pokemon::Move.new(move) }
  result
end
def start(player, enemies, mode = "single")
  $Trainer.party = player
  scene = KIFNative::Scene.new
  KIFNative.scene = scene
  battle = PokeBattle_Battle.new(scene, player, enemies, $Trainer, nil)
  battle.showAnims = false
  battle.setBattleMode(mode)
  fiber = Fiber.new { battle.pbStartBattle }
  prompt = fiber.resume
  [battle, scene, fiber, prompt]
end
def reply(fiber, prompt, value)
  check(fiber.alive?, "PROMPT_ALIVE #{prompt}")
  fiber.resume(value)
end

fresh
catalog = GameData::Move::DATA.values.uniq
check(catalog.length == 680, "ALL_INSTALLED_MOVES_LOADED")
check(GameData::Ability::DATA.values.uniq.length == 233, "ALL_INSTALLED_ABILITIES_LOADED")
check(GameData::Evolution::DATA.length == 60, "ALL_EVOLUTION_METHODS_LOADED")
check(GameData::Item::DATA.values.uniq.length == 725, "ALL_INSTALLED_ITEMS_LOADED")
check(GameData::Species::DATA.values.uniq.length == 590, "RUNTIME_SPECIES_REWRITES_LOADED")
check(GameData::Move.get(:TACKLE).name == "Tackle", "LOCALIZED_DATA_LOADED")
source_hash = KIFNative.source_hash
check(source_hash.match?(/\A[a-f0-9]{64}\z/), "RULES_AND_DATA_HASHED")

# Item and ability effects must run even though their animations are disabled.
fresh
player = pokemon(:GYARADOS)
foe = pokemon(:PIDGEY)
battle, scene, fiber, prompt = start([player], [foe])
check(battle.battlers[1].stages[:ATTACK] == -1, "INTIMIDATE_NATIVE_EFFECT")

fresh
sun = pokemon(:NINETALES)
sun.ability = :DROUGHT
battle, scene, fiber, prompt = start([sun], [pokemon(:PIDGEY)])
check(battle.field.weather == :Sun, "DROUGHT_NATIVE_WEATHER")

fresh
surge = pokemon(:RAICHU)
surge.ability = :ELECTRICSURGE
battle, scene, fiber, prompt = start([surge], [pokemon(:PIDGEY)])
check(battle.field.terrain == :Electric, "SURGE_NATIVE_TERRAIN")

fresh
player = pokemon(:SNORLAX, 50, [:SPLASH])
player.item = :LEFTOVERS
player.hp -= 60
battle, scene, fiber, prompt = start([player], [pokemon(:MAGIKARP, 5, [:SPLASH])])
before = player.hp
check(prompt["kind"] == "command", "NATIVE_COMMAND_PROMPT")
prompt = reply(fiber, prompt, 0)
check(prompt["kind"] == "move", "NATIVE_MOVE_PROMPT")
prompt = reply(fiber, prompt, 0)
check(player.hp > before, "LEFTOVERS_NATIVE_RECOVERY")
check(scene.events.any? { |event| event["kind"] == "hp" }, "STRUCTURED_HP_EVENTS")

# Nature effects are the installed Pokemon class's calculation, not neutrality.
fresh
mon = pokemon(:BULBASAUR)
mon.nature = :HARDY
mon.calc_stats
base_atk, base_spa = mon.attack, mon.spatk
mon.nature = :ADAMANT
mon.calc_stats
check(mon.attack > base_atk && mon.spatk < base_spa, "NATIVE_NATURE_MODIFIERS")

# Native type immunity and a multi-turn move survive the scene replacement.
fresh
player = pokemon(:PIKACHU, 50, [:THUNDERBOLT])
foe = pokemon(:SANDSHREW, 50, [:SPLASH])
battle, scene, fiber, prompt = start([player], [foe])
before = foe.hp
prompt = reply(fiber, prompt, 0)
prompt = reply(fiber, prompt, 0)
check(foe.hp == before, "GROUND_IMMUNITY")

fresh
player = pokemon(:PIDGEOT, 50, [:FLY])
battle, scene, fiber, prompt = start([player], [pokemon(:MAGIKARP, 50, [:SPLASH])])
prompt = reply(fiber, prompt, 0)
prompt = reply(fiber, prompt, 0)
check(battle.turnCount >= 2 || battle.decision > 0, "MULTI_TURN_CONTINUES_WITHOUT_EXTRA_CHOICE")

fresh
battle, scene, fiber, prompt = start([pokemon(:BULBASAUR), pokemon(:CHARMANDER)], [pokemon(:SQUIRTLE), pokemon(:PIDGEY)], "double")
check(battle.battlers.length == 4 && battle.sideSizes == [2, 2], "NATIVE_DOUBLE_BATTLE")
fresh
battle, scene, fiber, prompt = start([pokemon(:BULBASAUR), pokemon(:CHARMANDER), pokemon(:SQUIRTLE)], [pokemon(:PIDGEY), pokemon(:RATTATA), pokemon(:MAGIKARP)], "triple")
check(battle.battlers.length == 6 && battle.sideSizes == [3, 3], "NATIVE_TRIPLE_BATTLE")

# The original UI only shows owned items; API clients cannot skip that check.
fresh
battle, scene, fiber, prompt = start([pokemon(:BULBASAUR)], [pokemon(:PIDGEY)])
prompt = reply(fiber, prompt, 1)
begin
  fiber.resume({"item" => "MASTERBALL", "target" => 1})
  raise "UNOWNED_ITEM_WAS_ACCEPTED"
rescue ArgumentError => error
  check(error.message == "item_not_owned", "UNOWNED_ITEM_REJECTED")
end

fresh
$PokemonBag.pbStoreItem(:MASTERBALL, 1)
battle, scene, fiber, prompt = start([pokemon(:BULBASAUR)], [pokemon(:PIDGEY)])
prompt = reply(fiber, prompt, 1)
prompt = reply(fiber, prompt, {"item" => "MASTERBALL", "target" => 1})
20.times do
  break unless fiber.alive?
  prompt = reply(fiber, prompt, false)
end
check(battle.decision == 4 && $Trainer.party.length == 2, "NATIVE_CAPTURE_AND_STORAGE")
check($PokemonBag.pbQuantity(:MASTERBALL) == 0, "NATIVE_BALL_CONSUMPTION")

# Use the installed KIF data, which replaces many canonical trade evolutions.
fresh
eevee = pokemon(:EEVEE)
eevee.happiness = 0
check(eevee.check_evolution_on_level_up.nil?, "HAPPINESS_REQUIRED")
check(eevee.check_evolution_on_use_item(:THUNDERSTONE) == :JOLTEON, "ITEM_EVOLUTION")
kadabra = pokemon(:KADABRA, 39)
check(kadabra.check_evolution_on_level_up.nil?, "KIF_KADABRA_LEVEL_39")
kadabra.level = 40
check(kadabra.check_evolution_on_level_up == :ALAKAZAM, "KIF_KADABRA_LEVEL_40")
check(kadabra.check_evolution_on_use_item(:LINKINGCORD) == :ALAKAZAM, "KIF_LINKING_CORD")
check(kadabra.check_evolution_on_trade(nil).nil?, "NO_CANONICAL_TRADE_RULE_SUBSTITUTION")
kadabra.item = :EVERSTONE
check(kadabra.check_evolution_on_level_up.nil?, "EVERSTONE_GUARDS_EVOLUTION")

# Native breeding: Destiny Knot, Everstone, ability/ball/move inheritance.
fresh
mother = pokemon(:PIKACHU, 50, [:THUNDERBOLT, :VOLTTACKLE])
father = pokemon(:PIKACHU, 50, [:THUNDERBOLT, :VOLTTACKLE])
mother.gender = 1
father.gender = 0
mother.item = :EVERSTONE
mother.nature = :MODEST
father.item = :DESTINYKNOT
GameData::Stat.each_main { |stat| mother.iv[stat.id] = father.iv[stat.id] = 31 }
$PokemonGlobal.daycare = [[mother, mother.level], [father, father.level]]
check(pbDayCareGetCompat > 0, "NATIVE_BREEDING_COMPATIBILITY")
pbDayCareGenerateEgg
egg = $Trainer.party.last
check(egg.egg? && egg.species == :PICHU, "NATIVE_BABY_SPECIES")
check(egg.nature.id == :MODEST, "EVERSTONE_NATURE_INHERITANCE")
check(egg.iv.values.count(31) >= 5, "DESTINY_KNOT_FIVE_IVS")
check(egg.steps_to_hatch == egg.species_data.hatch_steps, "NATIVE_HATCH_STEPS")

def run_cultivation(document)
  result = KIFNative.cultivate(document)
  60.times do
    break if result["state"]
    prompt = result.fetch("prompt")
    value = case prompt.fetch("kind")
            when "confirm" then true
            when "pokemon" then 1
            else 0
            end
    document["inputs"] << {"prompt" => prompt, "value" => value}
    result = KIFNative.cultivate(document)
  end
  check(result["state"], "CULTIVATION_FINISHED")
  check(result == KIFNative.cultivate(document), "CULTIVATION_REPLAY_IDENTICAL")
  result
end
def cultivation_document(id, item)
  {"initial" => KIFNative.export_state, "time" => 1_792_713_600, "seed" => 1234,
   "action" => {"kind" => "use_item", "item" => item, "monster_id" => id}, "inputs" => []}
end

fresh
$Trainer.party = [pokemon(:PIKACHU, 5)]
KIFNative.identify
id = KIFNative.view["party"].first["id"]
$PokemonBag.pbStoreItem(:THUNDERSTONE, 1)
result = run_cultivation(cultivation_document(id, "THUNDERSTONE"))
check(result["view"]["party"].first.values_at("id", "species") == [id, :RAICHU], "STONE_EVOLUTION_PRESERVES_ID")
check(result["view"]["inventory"].empty?, "STONE_CONSUMED")
check(result["view"]["money"] == 3000, "NO_V1_EVOLUTION_FEE")
check($Trainer.pokedex.owned?(:RAICHU), "EVOLUTION_POKEDEX_REGISTERED")

fresh
$Trainer.party = [pokemon(:PIKACHU, 5)]
KIFNative.identify
$PokemonBag.pbStoreItem(:FIRESTONE, 1)
result = run_cultivation(cultivation_document(KIFNative.view["party"].first["id"], "FIRESTONE"))
check(result["view"]["party"].first["species"] == :PIKACHU && $PokemonBag.pbQuantity(:FIRESTONE) == 1, "FAILED_EVOLUTION_DOES_NOT_CONSUME")

fresh
$Trainer.party = [pokemon(:BULBASAUR, 10), pokemon(:CHARMANDER, 20)]
$Trainer.party[0].item = :LEFTOVERS
$Trainer.party[1].item = :CHARCOAL
KIFNative.identify
$PokemonBag.pbStoreItem(:DNASPLICERS, 2)
result = run_cultivation(cultivation_document(KIFNative.view["party"].first["id"], "DNASPLICERS"))
check(result["view"]["party"].length == 1, "FUSION_CONSUMES_SECOND_PARENT")
fused = result["view"]["party"].first
check(fused["level"] == 16, "NATIVE_WEIGHTED_FUSION_LEVEL")
check($PokemonBag.pbQuantity(:DNASPLICERS) == 1 && $PokemonBag.pbQuantity(:LEFTOVERS) == 1 && $PokemonBag.pbQuantity(:CHARCOAL) == 1, "FUSION_ITEM_ACCOUNTING")
check(result["view"]["money"] == 3000, "NO_V1_FUSION_FEE")
result = run_cultivation(cultivation_document(fused["id"], "DNASPLICERS"))
check(result["view"]["party"].map { |entry| entry["level"] }.sort == [10, 20], "NATIVE_UNFUSE_LEVELS")
check(result["view"]["party"].map { |entry| entry["id"] }.uniq.length == 2, "UNFUSE_DISTINCT_SERVER_IDS")
check($PokemonBag.pbQuantity(:DNASPLICERS) == 0, "UNFUSE_CONSUMES_SPLICER")

# Native cloning (e.g. Shedinja) must receive a new asset identity.
original = $Trainer.party.first
known = KIFNative.all_monsters.to_h { |entry| [entry.instance_variable_get(:@controlled_id), entry.object_id] }
$Trainer.party << original.clone
KIFNative.identify(known)
check(KIFNative.all_monsters.map { |entry| entry.instance_variable_get(:@controlled_id) }.uniq.length == 3, "CLONED_CREATURE_NEW_ID")

# A suspended battle is rebuilt from trusted state and the same input history.
fresh
$Trainer.party = [pokemon(:BULBASAUR, 25, [:TACKLE])]
KIFNative.identify
document = {"initial" => KIFNative.export_state, "time" => 1_792_713_600, "seed" => 1234,
  "encounter" => {"kind" => "wild", "party" => [{"species" => "PIDGEY", "level" => 3}]}, "inputs" => []}
result = KIFNative.battle(document)
check(result == KIFNative.battle(document), "REPLAY_IDENTICAL_INITIAL_PROMPT")
document["inputs"] << {"prompt" => result["prompt"], "value" => 0}
result = KIFNative.battle(document)
check(result == KIFNative.battle(document), "REPLAY_IDENTICAL_MOVE_PROMPT")
document["inputs"] << {"prompt" => result["prompt"], "value" => 0}
result = KIFNative.battle(document)
check(result == KIFNative.battle(document), "REPLAY_IDENTICAL_SETTLEMENT")
check(result["decision"] == 1 && result["state"], "NATIVE_VICTORY_STATE")
KIFNative.import_state(result["state"])
check($Trainer.party.first.exp > 11_735, "NATIVE_EXPERIENCE_PERSISTED")
check($Trainer.party.first.ev[:SPEED] == 1, "NATIVE_EFFORT_PERSISTED")
document["inputs"][0]["prompt"] = {"kind" => "item"}
begin
  KIFNative.battle(document)
  raise "MISMATCHED_PROMPT_WAS_ACCEPTED"
rescue ArgumentError => error
  check(error.message == "native_prompt_conflict", "REPLAY_PROMPT_CONFLICT")
end

puts "ORIGINAL_RULES_PASS checks=#{$checks} moves=#{catalog.length} rules_hash=#{source_hash}"
