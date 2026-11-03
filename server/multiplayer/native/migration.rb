# frozen_string_literal: true
# Input is read from the server's existing v1 registry, never from a player.
module KIFNative
  def self.managed_v1_monster(document, duration)
    pokemon = Pokemon.new(document.fetch("species").to_sym, document.fetch("level"))
    pokemon.nature = :HARDY # v1 always used neutral nature and had no nature field.
    pokemon.ability_index = 0
    pokemon.ability = nil
    pokemon.shiny = false # v1 never awarded shininess.
    pokemon.gender = {"male" => 0, "female" => 1, "none" => 2}.fetch(document.fetch("gender"))
    GameData::Stat.each_main do |stat|
      pokemon.iv[stat.id] = document.fetch("iv").fetch(stat.id.to_s)
      pokemon.ev[stat.id] = document.fetch("ev").fetch(stat.id.to_s)
    end
    minimum = pokemon.growth_rate.minimum_exp_for_level(document.fetch("level"))
    maximum = pokemon.growth_rate.minimum_exp_for_level([document.fetch("level") + 1, GameData::GrowthRate.max_level].min)
    old_span = document.fetch("growth_next") - document.fetch("growth_min")
    progress = old_span > 0 ? [document.fetch("exp") - document.fetch("growth_min"), 0].max.to_f / old_span : 0
    pokemon.exp = minimum + ((maximum - minimum) * [progress, 1.0].min).floor
    pokemon.moves = document.fetch("moves").map do |entry|
      raise ArgumentError, "native_migration_move_unknown" unless GameData::Move::DATA.key?(entry.fetch("id").to_sym)
      move = Pokemon::Move.new(entry.fetch("id").to_sym)
      move.pp = [entry.fetch("pp"), move.total_pp].min
      move
    end
    pokemon.status = document.fetch("status").to_sym
    pokemon.statusCount = document.fetch("sleep", 0)
    pokemon.calc_stats
    old_maximum = document.fetch("max_hp")
    pokemon.hp = document.fetch("hp") > 0 ? [[(document.fetch("hp") * pokemon.totalhp.to_f / old_maximum).ceil, 1].max, pokemon.totalhp].min : 0
    pokemon.instance_variable_set(:@controlled_id, document.fetch("id"))
    pokemon.instance_variable_set(:@controlled_v1_migrated, true)
    pokemon.instance_variable_set(:@controlled_v1_parents, document.fetch("parents", []))
    if document["egg"]
      fraction = [[(document.fetch("hatch_at") - clock).to_f / duration, 0].max, 1].min
      pokemon.steps_to_hatch = [(pokemon.species_data.hatch_steps * fraction).ceil, 1].max
      pokemon.name = _INTL("Egg")
    end
    if document["components"]
      body, head = document.fetch("components")
      pokemon.exp_when_fused_body = managed_v1_monster(body, duration).exp
      pokemon.exp_when_fused_head = managed_v1_monster(head, duration).exp
      pokemon.exp_gained_since_fused = [document.fetch("exp") - document.fetch("fusion_initial_exp"), 0].max
      pokemon.head_gender = {"male" => 0, "female" => 1, "none" => 2}.fetch(head.fetch("gender"))
      pokemon.body_original_ability_index = 0
      pokemon.head_original_ability_index = 0
      pokemon.instance_variable_set(:@controlled_v1_components, [body.fetch("id"), head.fetch("id")])
    end
    pokemon
  end
  def self.migrate_managed_v1(document)
    archive = document.fetch("managed_v1")
    monsters = archive.fetch("monsters").map { |entry| managed_v1_monster(entry, archive.fetch("hatch_seconds")) }
    ids = archive.fetch("progress").fetch("party")
    by_id = monsters.to_h { |pokemon| [pokemon.instance_variable_get(:@controlled_id), pokemon] }
    raise ArgumentError, "native_migration_party_unknown" unless ids.all? { |id| by_id.key?(id) }
    $Trainer.party = ids.map { |id| by_id.fetch(id) }
    monsters.each do |pokemon|
      next if $Trainer.party.include?(pokemon)
      raise ArgumentError, "native_migration_storage_full" if $PokemonStorage.pbStoreCaught(pokemon) < 0
    end
    archive.fetch("inventory").each do |entry|
      item = entry.fetch("item").to_sym
      raise ArgumentError, "native_migration_inventory_capacity" unless GameData::Item::DATA.key?(item) && $PokemonBag.pbStoreItem(item, entry.fetch("quantity"))
    end
    identify
    {"state" => export_state, "view" => world_view}
  end
end
