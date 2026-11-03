# frozen_string_literal: true
# Original storage screens retain moving, last-able checks, healing, release,
# held items and fusion rules. Rendering and coordinate acquisition live here.
class PokemonStorageScene
  attr_accessor :cursormode
  attr_reader :screen
  def pbStartBox(screen, command)
    @screen, @storage, @native_command = screen, screen.storage, command
    @cursormode = "normal"
    KIFNative.storage_screen = screen
  end
  def pbCloseBox
    KIFNative.storage_screen = nil
  end
  def pbSelectBox(_party)
    selection = KIFNative.scene.ask("storage", {"current_box" => @storage.currentBox,
      "boxes" => @storage.boxes.each_with_index.map do |box, index|
        {"id" => index, "name" => box.name, "size" => @storage.maxPokemon(index),
         "pokemon" => box.pokemon.each_with_index.filter_map { |pokemon, slot| {"slot" => slot, "monster" => {"id" => pokemon.instance_variable_get(:@controlled_id), "name" => pokemon.name, "level" => pokemon.level}} if pokemon }}
      end, "party" => @storage.party.map { |pokemon| KIFNative.monster_view(pokemon) },
      "held" => @screen.heldpkmn && KIFNative.monster_view(@screen.heldpkmn)})
    return [-3,0] if selection["box"] == -3
    return [-4,0] if selection["box"] == -4
    @storage.currentBox = selection["box"] if selection["box"] >= 0
    return [-2,selection["slot"]] if @native_command == 1 && selection["box"] == -1
    [selection["box"], selection["slot"]]
  end
  def pbSelectParty(party)
    value = KIFNative.scene.pbShowCommands("Party", party.map(&:name) + ["Close"])
    value < 0 || value == party.length ? -3 : value
  end
  def pbChooseBox(text)
    KIFNative.scene.pbShowCommands(text, @storage.boxes.map(&:name))
  end
  def pbChooseItem(bag)
    items = GameData::Item::DATA.values.uniq.select { |item| bag.pbQuantity(item.id) > 0 }
    selected = KIFNative.scene.pbShowCommands("Item", items.map { |item| "#{item.name} x#{bag.pbQuantity(item.id)}" })
    selected < 0 ? nil : items.fetch(selected).id
  end
  def pbSummary(selected, held)
    pokemon = held || @storage[selected[0], selected[1]]
    KIFNative.scene.pbShowCommands("#{pokemon.name} Lv.#{pokemon.level}\nHP #{pokemon.hp}/#{pokemon.totalhp}\n#{pokemon.ability.name} / #{pokemon.nature.real_name}\n#{pokemon.moves.map { |move| "#{move.name} #{move.pp}/#{move.total_pp}" }.join("\n")}", ["Back"], 1)
  end
  def pbChooseNumber(text, params); pbMessageChooseNumber(text.to_s, params); end
  def pbBoxName(text, minimum, maximum)
    pbEnterText(text, minimum, maximum)
  end
  def pbDisplay(text); KIFNative.scene.pbDisplay(text); end
  def pbShowCommands(text, choices, *); KIFNative.scene.pbShowCommands(text, choices); end
  def pbConfirm(text); KIFNative.scene.pbConfirm(text); end
  %i[pbRefresh pbHardRefresh pbUpdate pbSetMosaic pbShowPartyTab pbHidePartyTab
     pbHold pbPlace pbSwap pbWithdraw pbStore pbRelease pbSetHeldPokemon
     pbHoldMulti pbPlaceMulti pbReleaseMulti pbUpdateSelectionRect
     pbChangeBackground pbSetFusing pbSetSplicerType pbUpdateOverlay].each { |name| define_method(name) { |*| nil } }
end

# Import/export and free editor operations belong to historical local play.
class PokemonStorageScreen
  %i[pbImportJson pbExport pbExportBox pbExportAll pbExportSelected pbToggleShiny pbCarpFill].each do |name|
    define_method(name) { |*| raise ArgumentError, "native_offline_only_feature" }
  end
end

def pbShowCommandsWithHelp(window, choices, _help, cancel = 0, *)
  pbShowCommands(window, choices, cancel)
end

module KIFNativeBagScene
  def pbStartScene(bag, _choosing = false, filter = nil, *)
    @bag, @native_filter = bag, filter
  end
  def pbChooseItem
    items = GameData::Item::DATA.values.uniq.select { |item| @bag.pbQuantity(item.id) > 0 && (!@native_filter || @native_filter.call(item.id)) }
    selected = KIFNative.scene.pbShowCommands("Items", items.map { |item| "#{item.name} x#{@bag.pbQuantity(item.id)}" })
    selected < 0 ? nil : items.fetch(selected).id
  end
  def pbChooseNumber(text, maximum, initial = 1)
    KIFNative.scene.ask("number", {"text" => text, "minimum" => 0, "maximum" => maximum, "default" => initial})
  end
  def pbDisplay(text, *); KIFNative.scene.pbDisplay(text); end
  def pbConfirm(text); KIFNative.scene.pbConfirm(text); end
  def pbShowCommands(text, choices, *); KIFNative.scene.pbShowCommands(text, choices); end
  %i[pbRefresh pbRefreshFilter pbRefreshIndexChanged pbEndScene pbFadeOutScene pbFadeInScene pbUpdate update].each { |name| define_method(name) { |*| nil } }
end
PokemonBag_Scene.prepend(KIFNativeBagScene)
ItemStorage_Scene.prepend(KIFNativeBagScene)

class BattleSwapScene
  def pbStartRentScene(rentals)
    @rentals, @native_list = rentals, rentals
    rentals.each { |pokemon| pokemon.instance_variable_set(:@controlled_rental, true) }
  end
  def pbStartSwapScene(current, available)
    @currentPokemon, @newPokemon, @native_list = current, available, current
    (current + available).each { |pokemon| pokemon.instance_variable_set(:@controlled_rental, true) }
  end
  def pbChoosePokemon(cancel)
    KIFNative.scene.pbShowCommands("Rental Pokémon", @native_list.map { |pokemon| "#{pokemon.name} Lv.#{pokemon.level}" }, cancel ? -1 : 0)
  end
  def pbShowCommands(choices); KIFNative.scene.pbShowCommands("Rental", choices); end
  def pbConfirm(text); KIFNative.scene.pbConfirm(text); end
  def pbSwapChosen(*); @native_list = @newPokemon; end
  def pbSwapCanceled; @native_list = @currentPokemon; end
  def pbSummary(list, index)
    pokemon = list.fetch(index)
    KIFNative.scene.pbShowCommands("#{pokemon.name} Lv.#{pokemon.level}\n#{pokemon.moves.map(&:name).join(', ')}", ["Back"], 1)
  end
  def pbUpdateChoices(*); end
  def pbEndScene; end
end
