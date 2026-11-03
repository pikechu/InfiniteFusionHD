# frozen_string_literal: true
# Private server-to-server asset transport. Public endpoints supply IDs only.
module KIFNative
  def self.pack_asset(pokemon)
    "np1_" + Base64.strict_encode64(Zlib.deflate(Marshal.dump(pokemon)))
  end
  def self.unpack_asset(blob, id)
    raise ArgumentError, "native_asset_format" unless blob.is_a?(String) && blob.start_with?("np1_") && blob.bytesize <= STATE_LIMIT
    inflater, raw = Zlib::Inflate.new, +""
    inflater.inflate(Base64.strict_decode64(blob.delete_prefix("np1_"))) do |chunk|
      raw << chunk
      raise ArgumentError, "native_asset_expansion_limit" if raw.bytesize > 8 * 1024 * 1024
    end
    pokemon = Marshal.load(raw)
    raise ArgumentError, "native_asset_identity" unless pokemon.is_a?(Pokemon) && pokemon.instance_variable_get(:@controlled_id) == id
    pokemon
  ensure
    inflater&.close
  end
  def self.commerce_ready(ignore_events: false)
    raise ArgumentError, "native_world_missing" unless $MapFactory
    challenge = $PokemonGlobal.respond_to?(:challenge) && $PokemonGlobal.challenge
    contest = $PokemonGlobal.bugContestState
    selection = $PokemonGlobal.pokemonSelectionOriginalParty
    waiting = !ignore_events && ($game_temp.common_event_id > 0 || $game_map.events.values.any?(&:starting))
    raise ArgumentError, "native_commerce_busy" if waiting || pbMapInterpreterRunning? || $game_system.menu_disabled || (challenge && challenge.pbInChallenge?) || (contest && contest.inProgress?) || (selection && !selection.empty?)
  end
  def self.remove_asset(id)
    pokemon = $Trainer.party.find { |entry| entry.instance_variable_get(:@controlled_id) == id }
    if pokemon
      raise ArgumentError, "native_borrowed_asset" if pokemon.instance_variable_get(:@controlled_rental)
      $Trainer.party.delete(pokemon)
      return pokemon
    end
    $PokemonStorage.boxes.each_with_index do |box, box_id|
      box.pokemon.each_with_index do |entry, index|
        next unless entry && entry.instance_variable_get(:@controlled_id) == id
        raise ArgumentError, "native_borrowed_asset" if entry.instance_variable_get(:@controlled_rental)
        $PokemonStorage.pbDelete(box_id,index)
        return entry
      end
    end
    raise ArgumentError, "native_trade_asset_unavailable"
  end
  def self.place_asset(pokemon)
    raise ArgumentError, "native_asset_duplicate" if all_monsters.any? { |entry| entry.instance_variable_get(:@controlled_id) == pokemon.instance_variable_get(:@controlled_id) }
    if $Trainer.party.length < Settings::MAX_PARTY_SIZE
      $Trainer.party << pokemon
    else
      raise ArgumentError, "native_trade_storage_full" if $PokemonStorage.pbStoreCaught(pokemon) < 0
    end
    $Trainer.pokedex.register(pokemon)
    $Trainer.pokedex.set_owned(pokemon.species)
  end
  def self.asset_exchange(document)
    result, exports = {}, {}
    document.fetch("roles").each do |id, role|
      import_state(role.fetch("state"))
      self.clock = document.fetch("time")
      wallet_baseline(role)
      commerce_ready
      role.fetch("outgoing_items", []).each do |entry|
        item, quantity = entry.fetch("item").to_sym, entry.fetch("quantity")
        raise ArgumentError, "native_inventory_quantity" unless $PokemonBag.pbQuantity(item) >= quantity && $PokemonBag.pbDeleteItem(item, quantity)
      end
      role.fetch("outgoing", []).each do |identifier|
        pokemon = remove_asset(identifier)
        exports[identifier] = {"blob" => pack_asset(pokemon), "view" => monster_view(pokemon)}
      end
      result[id] = {"state" => export_state}
    end
    document.fetch("roles").each do |id, role|
      import_state(result.fetch(id).fetch("state"))
      self.clock = document.fetch("time")
      role.fetch("incoming", []).each do |asset|
        source = asset["source"] ? exports.fetch(asset.fetch("source")) : asset
        identifier = asset.fetch("id")
        pokemon = unpack_asset(source.fetch("blob"), identifier)
        if asset.fetch("traded", true)
          pokemon.obtain_method = 2
        end
        place_asset(pokemon)
      end
      role.fetch("incoming_items", []).each do |entry|
        raise ArgumentError, "native_inventory_capacity" unless $PokemonBag.pbStoreItem(entry.fetch("item").to_sym, entry.fetch("quantity"))
      end
      raise ArgumentError, "native_trade_last_able" if role.fetch("require_able", true) && !$Trainer.party.any?(&:able?)
      identify
      result[id] = {"state" => export_state, "view" => world_view}
    end
    {"roles" => result, "assets" => exports}
  end
  def self.trade_finish(document)
    import_state(document.fetch("initial"))
    money_before = wallet_baseline(document)
    self.clock = document.fetch("time")
    srand(document.fetch("seed"))
    begin_identities(document.fetch("seed"), Digest::SHA256.hexdigest(document.fetch("initial")))
    self.scene = Scene.new
    fiber = Fiber.new do
      document.fetch("incoming").each do |asset|
        pokemon = all_monsters.find { |entry| entry.instance_variable_get(:@controlled_id) == asset.fetch("id") }
        raise ArgumentError, "native_trade_asset_unavailable" unless pokemon
        counterpart = asset["counterpart"] && unpack_asset(asset["counterpart"].fetch("blob"), asset["counterpart"].fetch("id"))
        species = pokemon.check_evolution_on_trade(counterpart)
        next unless species && (pokemon.kuray_no_evo? == 0 || $PokemonSystem.kuray_no_evo == 0)
        evolution = PokemonEvolutionScene.new
        evolution.pbStartScreen(pokemon, species)
        evolution.pbEvolution(false)
        evolution.pbEndScreen
      end
    end
    prompt = fiber.resume
    document.fetch("inputs").each do |input|
      raise ArgumentError, "native_prompt_conflict" unless fiber.alive? && input.fetch("prompt") == prompt
      self.clock = input.fetch("time", document.fetch("time"))
      prompt = fiber.resume(input.fetch("value"))
    end
    identify
    assets = document.fetch("incoming").to_h do |asset|
      pokemon = all_monsters.find { |entry| entry.instance_variable_get(:@controlled_id) == asset.fetch("id") }
      [asset.fetch("id"), {"blob" => pack_asset(pokemon), "view" => monster_view(pokemon)}]
    end
    {"prompt" => fiber.alive? ? prompt : nil, "state" => fiber.alive? ? nil : export_state, "assets" => assets,
     "view" => world_view, "events" => scene.events, "money_delta" => $Trainer.money - money_before}.tap do |result|
       result["restore_assets"] = all_monsters.to_h { |entry| [entry.instance_variable_get(:@controlled_id), {"blob" => pack_asset(entry)}] } if document["capture_assets"]
     end
  ensure
    self.scene = nil
  end
end
