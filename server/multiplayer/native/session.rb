# frozen_string_literal: true
require "base64"
require_relative "runtime"
require_relative "scene"

module KIFNativeWalletJournal
  def money=(value)
    before = money
    result = super(value)
    return result unless equal?($Trainer) && KIFNative.scene && money != before
    sites = caller_locations(1, 24)
    paths = sites.map { |site| site.absolute_path.to_s }
    labels = sites.map(&:base_label)
    amount = money - before
    source = if labels.include?("pbGainMoney") then "battle_income"
             elsif labels.include?("pbLoseMoney") then "battle_loss"
             elsif paths.any? { |path| path.end_with?("020_UI_PokeMart.rb") || path.include?("/clothesShop/") }
               amount > 0 ? "npc_sale" : "npc_purchase"
             elsif paths.any? { |path| path.end_with?("TRQuests.rb") } then "quest_reward"
             elsif paths.any? { |path| path.include?("Tutor") } then "tutor_cost"
             elsif paths.any? { |path| path.include?("DayCare") } then "daycare_cost"
             else amount > 0 ? "event_income" : "event_expense"
             end
    site = sites.first
    KIFNative.scene.events << {"kind" => "money", "source" => source, "amount" => amount,
      "before" => before, "after" => money, "map_id" => $game_map&.map_id,
      "rule" => site&.absolute_path.to_s.delete_prefix(KIFNative::ROOT + "/"), "line" => site&.lineno}
    result
  end
end
Player.prepend(KIFNativeWalletJournal)

module KIFNativeReseeding
  def srand(*arguments)
    if arguments.empty? && KIFNative.respond_to?(:identity_seed) && KIFNative.identity_seed
      KIFNative.reseed_counter = (KIFNative.reseed_counter || 0) + 1
      arguments = [Digest::SHA256.hexdigest("#{KIFNative.identity_seed}:reseed:#{KIFNative.reseed_counter}").to_i(16)]
    end
    super(*arguments)
  end
end
Kernel.prepend(KIFNativeReseeding)

module KIFNative
  class << self; attr_accessor :scene, :clock, :identity_seed, :identity_counter, :original_objects, :active_battle, :reseed_counter, :storage_screen; end
  def self.begin_identities(seed, context = "")
    self.reseed_counter = 0
    self.identity_seed, self.identity_counter = Digest::SHA256.hexdigest("#{seed}:#{context}"), 0
    self.original_objects = all_monsters.to_h { |pokemon| [pokemon.instance_variable_get(:@controlled_id), pokemon.object_id] }
  end
  def self.new_creature_id
    return "cm_" + Random.urandom(16).unpack1("H*") if identity_seed.nil?
    self.identity_counter = (identity_counter || 0) + 1
    "cm_" + Digest::SHA256.hexdigest("native-creature:#{identity_seed}:#{identity_counter}")[0,32]
  end
  STATE_VERSION = 2
  STATE_LIMIT = 8 * 1024 * 1024
  def self.export_state
    value = {"version" => STATE_VERSION, "player" => $Trainer,
      "bag" => $PokemonBag, "global" => $PokemonGlobal, "storage" => $PokemonStorage,
      "switches" => $game_switches, "variables" => $game_variables}
    value["world"] = world_state if respond_to?(:world_state) && $MapFactory
    value["resources"] = resource_changes
    value["virtual_data"] = virtual_data
    value["globals"] = read_globals(game_global_names - RESOURCE_GLOBALS)
    raw = Marshal.dump(value)
    raise ArgumentError, "native_state_expansion_limit" if raw.bytesize > 64 * 1024 * 1024
    blob = "z2_" + Base64.strict_encode64(Zlib.deflate(raw))
    raise ArgumentError, "native_state_limit" if blob.bytesize > STATE_LIMIT
    blob
  end
  # ONLY the Python server's own persisted output is supplied to this method.
  # The public API must never accept opaque state, Marshal, or an encounter spec.
  def self.import_state(blob)
    raise ArgumentError, "native_state_limit" unless blob.is_a?(String) && blob.bytesize <= STATE_LIMIT
    raise ArgumentError, "native_state_format" unless blob.start_with?("z2_")
    inflater = Zlib::Inflate.new
    raw = +""
    inflater.inflate(Base64.strict_decode64(blob.delete_prefix("z2_"))) do |chunk|
      raw << chunk
      raise ArgumentError, "native_state_expansion_limit" if raw.bytesize > 64 * 1024 * 1024
    end
    value = Marshal.load(raw)
    raise ArgumentError, "native_state_version" unless value.fetch("version") == STATE_VERSION
    reset
    restore_resource_changes(value.fetch("resources", {}))
    restore_virtual_data(value.fetch("virtual_data", {}))
    $Trainer, $PokemonBag, $PokemonGlobal, $PokemonStorage, $game_switches, $game_variables =
      value.values_at("player", "bag", "global", "storage", "switches", "variables")
    restore_world_state(value["world"]) if value["world"]
    write_globals(value.fetch("globals"))
  ensure
    inflater&.close
  end
  def self.monster_view(pokemon)
    {"id" => pokemon.instance_variable_get(:@controlled_id), "species" => pokemon.species,
     "lineage" => creature_lineage(pokemon),
     "name" => pokemon.name, "level" => pokemon.level, "exp" => pokemon.exp,
     "hp" => pokemon.hp, "max_hp" => pokemon.totalhp, "status" => pokemon.status,
     "iv" => pokemon.iv, "ev" => pokemon.ev, "nature" => pokemon.nature.id,
     "ability" => pokemon.ability_id, "item" => pokemon.item_id,
     "ability2" => pokemon.ability2_id,
     "form" => pokemon.form, "shiny" => pokemon.shiny?, "happiness" => pokemon.happiness,
     "appearance" => {"hue" => pokemon.instance_variable_get(:@shinyValue) || 0,
       "red" => pokemon.instance_variable_get(:@shinyR) || 0, "green" => pokemon.instance_variable_get(:@shinyG) || 1,
       "blue" => pokemon.instance_variable_get(:@shinyB) || 2, "krs" => pokemon.instance_variable_get(:@shinyKRS) || Array.new(9,0),
       "pif_shiny" => pokemon.instance_variable_get(:@shinyimprovpif), "body_shiny" => pokemon.body_shiny, "head_shiny" => pokemon.head_shiny,
       "scale" => pokemon.instance_variable_get(:@sprite_scale) || 1},
     "borrowed" => pokemon.instance_variable_get(:@controlled_rental) == true,
     "owner" => {"id" => pokemon.owner.id, "name" => pokemon.owner.name, "gender" => pokemon.owner.gender},
     "ball" => pokemon.poke_ball, "obtain_method" => pokemon.obtain_method,
     "gender" => pokemon.gender, "egg_steps" => pokemon.steps_to_hatch,
     "stats" => {"HP" => pokemon.totalhp, "ATTACK" => pokemon.attack, "DEFENSE" => pokemon.defense,
       "SPECIAL_ATTACK" => pokemon.spatk, "SPECIAL_DEFENSE" => pokemon.spdef, "SPEED" => pokemon.speed},
     "moves" => pokemon.moves.map { |move| {"id" => move.id, "pp" => move.pp, "total_pp" => move.total_pp} }}
  end
  def self.creature_lineage(pokemon)
    ((pokemon.instance_variable_get(:@controlled_lineage) || []) +
      (pokemon.instance_variable_get(:@controlled_v1_components) || []) +
      [pokemon.instance_variable_get(:@controlled_id)]).compact.uniq.sort
  end
  def self.all_monsters
    result = $Trainer.party.dup
    $PokemonGlobal.daycare.each { |entry| result << entry[0] if entry[0] }
    $PokemonStorage.boxes.each { |box| box.pokemon.each { |pokemon| result << pokemon if pokemon } }
    if storage_screen
      result << storage_screen.heldpkmn if storage_screen.heldpkmn
      result.concat(storage_screen.multiheldpkmn || [])
    end
    reserves = []
    reserves.concat($PokemonGlobal.pokemonSelectionOriginalParty || [])
    contest = $PokemonGlobal.bugContestState
    if contest && contest.inProgress?
      reserves.concat(contest.instance_variable_get(:@otherparty) || [])
      reserves << contest.lastPokemon if contest.lastPokemon
    end
    chamber = $PokemonGlobal.instance_variable_get(:@purifyChamber)
    chamber&.sets&.each do |set|
      reserves << set.shadow if set.shadow
      reserves.concat(set.list)
    end
    reserves << purify_scene.heldpkmn if respond_to?(:purify_scene) && purify_scene && purify_scene.heldpkmn
    reserves.each { |pokemon| result << pokemon unless result.any? { |existing| existing.equal?(pokemon) } }
    challenge = $PokemonGlobal.respond_to?(:challenge) && $PokemonGlobal.challenge
    data = challenge && challenge.instance_variable_get(:@bc)
    if data && data.inProgress
      (data.instance_variable_get(:@oldParty) || []).each { |pokemon| result << pokemon unless result.any? { |existing| existing.equal?(pokemon) } }
    end
    result
  end
  def self.identify(known = original_objects)
    monsters = all_monsters
    raise "duplicate_creature_reference" unless monsters.map(&:object_id).uniq.length == monsters.length
    monsters.group_by { |pokemon| pokemon.instance_variable_get(:@controlled_id) }.each do |id, group|
      if id && group.length > 1
        original = known && group.find { |pokemon| pokemon.object_id == known[id] }
        raise "ambiguous_creature_identity" unless original
        group.each { |pokemon| pokemon.instance_variable_set(:@controlled_id, new_creature_id) unless pokemon.equal?(original) }
      elsif !id
        group.each { |pokemon| pokemon.instance_variable_set(:@controlled_id, new_creature_id) }
      end
    end
    monsters.each { |pokemon| known[pokemon.instance_variable_get(:@controlled_id)] ||= pokemon.object_id } if known
    monsters.each { |pokemon| pokemon.instance_variable_set(:@controlled_lineage, creature_lineage(pokemon)) }
  end
  def self.view
    inventory = Hash.new(0)
    $PokemonBag.pockets.flatten(1).each { |item, quantity| inventory[item] += quantity }
    {"money" => $Trainer.money, "party" => $Trainer.party.map { |pokemon| monster_view(pokemon) },
     "monsters" => all_monsters.map { |pokemon| monster_view(pokemon) },
     "pc_inventory" => ($PokemonGlobal.pcItemStorage ? $PokemonGlobal.pcItemStorage.items : []).map { |item, quantity| {"item" => item, "quantity" => quantity} },
     "inventory" => inventory.map { |item, quantity| {"item" => item, "quantity" => quantity} }}
  end
  def self.wallet_baseline(document)
    $Trainer.money = document["wallet_balance"] if document.key?("wallet_balance")
    $Trainer.money
  end
  def self.battle(document)
    import_state(document.fetch("initial"))
    money_before = wallet_baseline(document)
    begin_identities(document.fetch("seed"), Digest::SHA256.hexdigest(document.fetch("initial")))
    self.clock = document.fetch("time")
    srand(document.fetch("seed"))
    encounter = document.fetch("encounter")
    opponent = nil
    if encounter.fetch("kind") == "trainer"
      type, name, version = encounter.fetch("trainer")
      opponent = pbLoadTrainer(type.to_sym, name, version)
      raise ArgumentError, "unknown_native_trainer" unless opponent
      enemies = opponent.party
    else
      raise ArgumentError, "invalid_native_encounter" unless encounter.fetch("kind") == "wild"
      # This spec is generated by the server world, never supplied by a player.
      enemies = encounter.fetch("party").map { |entry| Pokemon.new(entry.fetch("species").to_sym, entry.fetch("level")) }
    end
    self.scene = Scene.new
    battle = PokeBattle_Battle.new(scene, $Trainer.party, enemies, $Trainer, opponent)
    battle.items = [opponent.items] if opponent
    battle.showAnims = false
    battle.setBattleMode(encounter.fetch("mode", "single"))
    fiber = Fiber.new { battle.pbStartBattle }
    prompt = fiber.resume
    document.fetch("inputs").each_with_index do |input, index|
      raise ArgumentError, "native_history_after_end" unless fiber.alive?
      raise ArgumentError, "native_prompt_conflict" unless input.fetch("prompt") == prompt
      self.clock = input.fetch("time", document.fetch("time"))
      prompt = fiber.resume(input.fetch("value"))
    end
    finished = !fiber.alive?
    identify if finished
    {"prompt" => finished ? nil : prompt, "decision" => battle.decision, "money_delta" => $Trainer.money - money_before,
     "round" => battle.turnCount, "events" => scene.events, "view" => view,
     "enemies" => enemies.map { |pokemon| monster_view(pokemon) },
     "battlers" => battle.battlers.compact.map { |b| {"index" => b.index, "party_index" => b.pokemonIndex,
       "hp" => b.hp, "status" => b.status, "stages" => b.stages, "ability" => b.ability_id} },
     "weather" => battle.field.weather, "terrain" => battle.field.terrain,
     "state" => finished ? export_state : nil}
  ensure
    self.scene = nil
  end
end

# Replace UI acquisition only. Choice conditions and consequences still run in
# the original method which called the prompt.
def pbMessage(text, choices = nil, cancel = 0, *)
  raise "native_scene_required" unless KIFNative.scene
  choices ? KIFNative.scene.pbShowCommands(text, choices, cancel) : KIFNative.scene.pbDisplayMessage(text)
end
def pbConfirmMessage(text); KIFNative.scene.pbDisplayConfirmMessage(text); end
def pbShowCommands(_window, choices, cancel = 0, *)
  KIFNative.scene.pbShowCommands("", choices, cancel)
end

def pbChooseNumber(_window, params)
  KIFNative.scene.ask("number", {"text" => "Number", "minimum" => params.minNumber,
    "maximum" => params.maxNumber, "cancellation" => params.cancelNumber, "default" => params.initialNumber})
end
def pbMessageChooseNumber(text, params, &block)
  pbMessage(text)
  pbChooseNumber(nil, params, &block)
end
