# frozen_string_literal: true
module KIFNative
  def self.prune_restore_assets(ids)
    removed = []
    $Trainer.party.delete_if { |pokemon| ids.include?(pokemon.instance_variable_get(:@controlled_id)) && (removed << pokemon) }
    $PokemonStorage.boxes.each_with_index do |box, box_id|
      box.pokemon.each_with_index do |pokemon, index|
        next unless pokemon && ids.include?(pokemon.instance_variable_get(:@controlled_id))
        removed << pokemon
        $PokemonStorage.pbDelete(box_id,index)
      end
    end
    $PokemonGlobal.daycare.each do |entry|
      next unless entry[0] && ids.include?(entry[0].instance_variable_get(:@controlled_id))
      removed << entry[0]
      entry[0], entry[1] = nil, 0
    end
    selection = $PokemonGlobal.pokemonSelectionOriginalParty
    selection&.delete_if { |pokemon| ids.include?(pokemon.instance_variable_get(:@controlled_id)) }
    contest = $PokemonGlobal.bugContestState
    if contest
      other = contest.instance_variable_get(:@otherparty)
      other&.delete_if { |pokemon| ids.include?(pokemon.instance_variable_get(:@controlled_id)) }
      contest.lastPokemon = nil if contest.lastPokemon && ids.include?(contest.lastPokemon.instance_variable_get(:@controlled_id))
    end
    chamber = $PokemonGlobal.instance_variable_get(:@purifyChamber)
    chamber&.sets&.each do |set|
      if set.shadow && ids.include?(set.shadow.instance_variable_get(:@controlled_id))
        removed << set.shadow
        set.shadow = nil
      end
      (set.length-1).downto(0) do |index|
        next unless ids.include?(set[index].instance_variable_get(:@controlled_id))
        removed << set[index]
        set.insertAt(index,nil)
      end
    end
    removed
  end
  def self.restore_item_delta(item, amount)
    if amount >= 0
      raise ArgumentError, "native_inventory_capacity" unless amount == 0 || $PokemonBag.pbStoreItem(item, amount)
      return
    end
    needed = -amount
    [$PokemonBag, $PokemonGlobal.pcItemStorage].compact.each do |storage|
      quantity = [storage.pbQuantity(item), needed].min
      storage.pbDeleteItem(item, quantity) if quantity > 0
      needed -= quantity
    end
    all_monsters.each do |pokemon|
      next unless needed > 0 && pokemon.item_id == item
      pokemon.item = nil
      needed -= 1
    end
    raise ArgumentError, "native_restore_item_conflict" unless needed == 0
  end
  def self.rollback(document)
    import_state(document.fetch("current"))
    protected = document.fetch("protected")
    foreign = document.fetch("foreign_ids")
    if document["pending"] && !protected.empty?
      pending = document.fetch("pending")
      operation = pending.fetch("document").merge("capture_assets" => true)
      replay = case pending.fetch("operation")
               when "world_step" then world_step(operation)
               when "cultivate" then cultivate(operation)
               when "trade_finish" then trade_finish(operation)
               else raise ArgumentError, "native_restore_pending"
               end
      current = replay.fetch("restore_assets").map { |id, asset| unpack_asset(asset.fetch("blob"),id) }
    else
      current = all_monsters
    end
    current = current.select { |pokemon| !(creature_lineage(pokemon) & protected).empty? && !foreign.include?(pokemon.instance_variable_get(:@controlled_id)) }
    current = Marshal.load(Marshal.dump(current))
    import_state(document.fetch("snapshot"))
    commerce_ready(ignore_events: true)
    had_party = !$Trainer.party.empty?
    blocked = all_monsters.select { |pokemon| !(creature_lineage(pokemon) & protected).empty? || foreign.include?(pokemon.instance_variable_get(:@controlled_id)) }
    removed = prune_restore_assets(blocked.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) })
    current.each { |pokemon| place_asset(pokemon) }
    changes = Hash.new(0)
    removed.each { |pokemon| changes[pokemon.item_id] += 1 if pokemon.item_id }
    current.each { |pokemon| changes[pokemon.item_id] -= 1 if pokemon.item_id }
    document.fetch("external_items").each { |item, amount| changes[item.to_sym] += amount }
    document.fetch("external_held", {}).each { |item, amount| changes[item.to_sym] += amount }
    changes.each { |item, amount| restore_item_delta(item, amount) }
    raise ArgumentError, "native_trade_last_able" if had_party && !$Trainer.party.any?(&:able?)
    wallet_baseline(document)
    self.clock = document.fetch("time")
    ids = all_monsters.map { |pokemon| pokemon.instance_variable_get(:@controlled_id) }
    raise ArgumentError, "native_asset_duplicate" if ids.uniq.length != ids.length || !(ids & foreign).empty?
    {"state" => export_state, "view" => world_view}
  end
end
